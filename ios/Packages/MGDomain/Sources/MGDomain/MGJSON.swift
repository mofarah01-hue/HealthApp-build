import Foundation

/// One encoder / decoder for every file the app writes or reads (ARCHITECTURE.md 4.3).
public enum MGJSON {
    /// Sorted keys, unescaped slashes, dates as RFC 3339 `yyyy-MM-dd'T'HH:mm:ssXXXXX` in the phone's time zone
    /// (whole seconds; a zero offset is written `Z`).
    public static func encoder() -> JSONEncoder { encoder(timeZone: .current) }

    /// Same as `encoder()` with an explicit zone (tests; UTC for content hashes).
    public static func encoder(timeZone: TimeZone) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(RFC3339.format(date, timeZone: timeZone))
        }
        return e
    }

    /// Accepts RFC 3339 date-times with or without fractional seconds (any number of digits), `Z` or an offset.
    /// A date-time without an offset is rejected: local wall time is ambiguous across zones and DST.
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = RFC3339.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an RFC 3339 date-time with an offset: \(s)")
            }
            return date
        }
        return d
    }

    /// JSON Lines (`events.jsonl`): one compact object per line, `\n` after each.
    public static func encodeLines<T: Encodable>(_ items: [T], encoder: JSONEncoder = MGJSON.encoder()) throws -> Data {
        var out = Data()
        for item in items {
            out.append(try encoder.encode(item))
            out.append(0x0A)
        }
        return out
    }

    /// Reads JSON Lines; blank lines are skipped, `\r\n` is accepted. A bad line throws `LineError` with its number.
    public static func decodeLines<T: Decodable>(_ type: T.Type, from data: Data,
                                                 decoder: JSONDecoder = MGJSON.decoder()) throws -> [T] {
        var result: [T] = []
        var lineNumber = 0
        for var line in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            lineNumber += 1
            if line.last == 0x0D { line = line.dropLast() }
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { continue }
            do {
                result.append(try decoder.decode(T.self, from: Data(line)))
            } catch {
                throw LineError(line: lineNumber, underlying: error)
            }
        }
        return result
    }

    public struct LineError: Error, CustomStringConvertible {
        public let line: Int
        public let underlying: Error
        public var description: String { "JSON Lines: line \(line): \(underlying)" }
    }
}

/// RFC 3339 date-times without Calendar or DateFormatter, so parsing never rolls an impossible date over
/// (Feb 30 -> Mar 2) and formatting never depends on the user's calendar or locale.
///
/// Failure modes handled (tests: RFC3339Tests): `Z`/`z`/`+hh:mm`/`-hh:mm`/`+hhmm` offsets; fractional seconds of any
/// length (Python writes 6 digits, JavaScript 3); `T`, `t` or space separator; no offset -> nil; impossible fields
/// (month 13, Feb 29 in a non-leap year, hour 24, minute 60, second 60) -> nil; trailing text -> nil; DST: the offset
/// written is the zone's offset at that instant; pre-1970 instants floor correctly; an offset that is not whole minutes
/// (historic local mean time) is written as UTC `Z` rather than truncated.
public enum RFC3339 {
    public static func parse(_ s: String) -> Date? {
        let b = Array(s.utf8)
        func digits(_ i: Int, _ n: Int) -> Int? {
            guard i >= 0, i + n <= b.count else { return nil }
            var v = 0
            for k in i..<(i + n) {
                let c = b[k]
                guard c >= 0x30, c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        func byte(_ i: Int) -> UInt8? { i < b.count ? b[i] : nil }
        guard b.count >= 20,
              let year = digits(0, 4), byte(4) == 0x2D,
              let month = digits(5, 2), byte(7) == 0x2D,
              let day = digits(8, 2),
              let sep = byte(10), sep == 0x54 || sep == 0x74 || sep == 0x20,
              let hour = digits(11, 2), byte(13) == 0x3A,
              let minute = digits(14, 2), byte(16) == 0x3A,
              let second = digits(17, 2)
        else { return nil }
        var i = 19
        var fraction = 0.0
        if byte(i) == 0x2E {
            i += 1
            let start = i
            while let c = byte(i), c >= 0x30, c <= 0x39 { i += 1 }
            guard i > start, let f = Double("0." + String(decoding: b[start..<i], as: UTF8.self)) else { return nil }
            fraction = f
        }
        var offset = 0
        guard let z = byte(i) else { return nil }                 // an offset is required
        if z == 0x5A || z == 0x7A {
            i += 1
        } else if z == 0x2B || z == 0x2D {
            i += 1
            guard let oh = digits(i, 2) else { return nil }
            i += 2
            if byte(i) == 0x3A { i += 1 }
            guard let om = digits(i, 2), oh <= 23, om <= 59 else { return nil }
            i += 2
            offset = (z == 0x2D ? -1 : 1) * (oh * 3600 + om * 60)
        } else {
            return nil
        }
        guard i == b.count,
              (1...12).contains(month), day >= 1, day <= CivilDate.daysIn(year: year, month: month),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }
        let days = CivilDate.daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    public static func format(_ date: Date, timeZone: TimeZone) -> String {
        var offset = timeZone.secondsFromGMT(for: date)
        if offset % 60 != 0 { offset = 0 }
        let t = Int(date.timeIntervalSince1970.rounded(.down)) + offset
        let days = CivilDate.floorDiv(t, 86_400)
        let secs = t - days * 86_400
        let (y, m, d) = CivilDate.civilFromDays(days)
        var s = CivilDate.pad(y, 4) + "-" + CivilDate.pad(m, 2) + "-" + CivilDate.pad(d, 2) + "T"
        s += CivilDate.pad(secs / 3600, 2) + ":" + CivilDate.pad((secs % 3600) / 60, 2) + ":" + CivilDate.pad(secs % 60, 2)
        if offset == 0 { return s + "Z" }
        let a = abs(offset)
        return s + (offset < 0 ? "-" : "+") + CivilDate.pad(a / 3600, 2) + ":" + CivilDate.pad((a % 3600) / 60, 2)
    }
}

/// Proleptic Gregorian date arithmetic (H. Hinnant, "chrono-compatible low-level date algorithms").
enum CivilDate {
    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }

    static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}
