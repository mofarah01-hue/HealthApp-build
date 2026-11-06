import Foundation
import MGDomain

/// Errors MGStore raises. Each says what failed and where, so it surfaces in the ack journal / sync state instead of
/// being swallowed (Mo's verification rules: "error flags that say what failed and where").
public enum MGStoreError: Error, Equatable, CustomStringConvertible {
    /// The writer connection is not at `PRAGMA synchronous = FULL` (2). `store(_:)` refuses to commit, so no ack follows.
    case notDurable(synchronous: Int)
    /// A metric failed `Metric.validate()` (R6: value nil needs a reason). Nothing in the batch was written.
    case invalidMetric(name: String, violations: [String])
    /// A JSON document lacked a key the store needs for its natural key.
    case missingKey(what: String, key: String)
    /// `markDelivered` got receipts that do not match the outbox files (§5.5). The drop stays undelivered.
    case receiptMismatch(dropId: String, detail: String)
    /// No event with this id.
    case unknownEvent(UUID)
    /// No outbox drop with this id.
    case unknownDrop(String)
    /// Encoding or decoding through MGJSON failed.
    case coding(String)

    public var description: String {
        switch self {
        case .notDurable(let s): return "MGStore: writer is at PRAGMA synchronous=\(s), need 2 (FULL) before an ack"
        case .invalidMetric(let n, let v): return "MGStore: metric \(n) invalid: \(v.joined(separator: "; "))"
        case .missingKey(let w, let k): return "MGStore: \(w) has no \"\(k)\""
        case .receiptMismatch(let d, let x): return "MGStore: drop \(d) receipt mismatch: \(x)"
        case .unknownEvent(let id): return "MGStore: no event \(id.uuidString)"
        case .unknownDrop(let d): return "MGStore: no outbox drop \(d)"
        case .coding(let x): return "MGStore: coding failed: \(x)"
        }
    }
}

enum Hex {
    static func string(_ data: Data) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return out
    }
}

/// CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) — part of the raw_frame natural key (§4.5).
/// Known answer: CRC-32("123456789") = 0xCBF43926.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// RFC 3339 parsing for contract date-time strings read back out of stored JSON (with or without fractional
/// seconds, `Z` or an offset — what MGJSON.decoder accepts, §4.3).
enum ContractDate {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        plain.date(from: s) ?? fractional.date(from: s)
    }
}

/// JSON helpers. Documents are always produced by `MGJSON.encoder()` (sorted keys, so equal content gives equal bytes)
/// and read by `MGJSON.decoder()`. Natural-key fields are read from the encoded contract keys, so the store depends on
/// the contract's snake_case names rather than on Swift property names of opaque types (Series, LabResult, SyncReceipt).
enum DocJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try MGJSON.encoder().encode(value) } catch { throw MGStoreError.coding("\(T.self): \(error)") }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try MGJSON.decoder().decode(T.self, from: data) } catch {
            throw MGStoreError.coding("\(T.self): \(error)")
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MGStoreError.coding("not a JSON object")
        }
        return obj
    }

    static func string(_ obj: [String: Any], _ key: String, what: String) throws -> String {
        guard let s = obj[key] as? String else { throw MGStoreError.missingKey(what: what, key: key) }
        return s
    }

    static func int(_ obj: [String: Any], _ key: String) -> Int? {
        (obj[key] as? NSNumber)?.intValue
    }
}

extension Date {
    var unix: Double { timeIntervalSince1970 }
}
