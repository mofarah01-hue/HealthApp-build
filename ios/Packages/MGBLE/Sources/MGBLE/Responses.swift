import Foundation
import MGDomain
import WhoopProtocol

/// COMMAND_RESPONSE result byte (whoop_protocol.json `CommandResult`; noop:docs/PROTOCOL_TRANSPORT.md
/// "Responses and correlation": 0 failure, 1 success, 2 pending, 3 unsupported, other = keep the number).
public enum CommandResult: Equatable, Sendable {
    case failure, success, pending, unsupported
    case unknown(UInt8)

    public init(byte: UInt8) {
        switch byte {
        case 0: self = .failure
        case 1: self = .success
        case 2: self = .pending
        case 3: self = .unsupported
        default: self = .unknown(byte)
        }
    }

    public var label: String {
        switch self {
        case .failure: return "FAILURE"
        case .success: return "SUCCESS"
        case .pending: return "PENDING"
        case .unsupported: return "UNSUPPORTED"
        case .unknown(let b): return "RESULT_\(b)"
        }
    }
}

/// One decoded 5/MG COMMAND_RESPONSE. Layout (noop:docs/PROTOCOL_TRANSPORT.md "Responses and correlation",
/// firmware 50.42.1.0; same offsets as noop Interpreter `decodeWhoop5CommandResponse`): type 36 at 8, response
/// sequence at 9, command at 10, ORIGINATING request sequence at 11, result at 12, body from 13 to the CRC32
/// trailer (may end in pad-to-4 zeros). Puffin type 38 is accepted as the same thing (noop `PuffinPacketType`).
public struct CommandResponse: Equatable, Sendable {
    public let command: UInt8
    public let originSeq: UInt8
    public let result: CommandResult
    public let body: [UInt8]
    public let frame: [UInt8]

    /// nil unless the frame passes the full integrity check (header CRC16, payload CRC32, exact length) and is
    /// long enough to hold the result byte. Bad bytes never drive state.
    public static func parse(_ frame: [UInt8]) -> CommandResponse? {
        guard frame.count >= 13 + 4, frame[8] == 36 || frame[8] == 38 else { return nil }
        guard verifyFrame(frame, family: .whoop5).ok else { return nil }
        let bodyEnd = frame.count - 4
        return CommandResponse(command: frame[10], originSeq: frame[11], result: CommandResult(byte: frame[12]),
                               body: bodyEnd > 13 ? Array(frame[13..<bodyEnd]) : [], frame: frame)
    }
}

/// A GET_FF_VALUE (128) reply judged against the key that was asked for. Layout (noop:docs/PROTOCOL_CONFIGURATION.md
/// "Configuration reads — commands 121 and 128", fw 50.42.1.0; openwhoop / OpenStrap agree): a 65-byte body
/// `[revision 1][key, 32 bytes NUL-padded][value text, 32 bytes NUL-terminated]`, FAILURE replies included — they echo
/// the key with a zero value field, so the key echo alone proves nothing (noop PR #2193). A value is accepted only when
/// the result is SUCCESS (1), the revision is 1 and the 32-byte key field is exactly the requested key NUL-padded.
/// DECODED from those sources and checked against frames built here; not yet observed from Mo's strap.
public enum FeatureFlagValueReply {
    public static let bodyLength = 65
    public static let fieldLength = 32
    /// Keys longer than this cannot be asked for: the field keeps a terminating NUL (same source: "at most 31 key bytes").
    public static let maxKeyLength = 31

    /// The 32-byte key field for `key`, or nil when the key is empty, longer than 31 bytes or not printable ASCII.
    public static func keyField(_ key: String) -> [UInt8]? {
        let bytes = Array(key.utf8)
        guard !bytes.isEmpty, bytes.count <= maxKeyLength, bytes.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            return nil
        }
        return bytes + [UInt8](repeating: 0, count: fieldLength - bytes.count)
    }

    /// `command` is 128 (GET_FF_VALUE) or, for a device-config key, 121 (GET_DEVICE_CONFIG_VALUE, same reply layout).
    public static func reading(key: String, response: CommandResponse?, command: UInt8 = 128) -> StrapFlagReading {
        guard let response else { return StrapFlagReading(key: key, value: nil, status: "no reply") }
        guard response.command == command else {
            return StrapFlagReading(key: key, value: nil, status: "not decoded: reply to command \(response.command)")
        }
        switch response.result {
        case .success: break
        case .failure: return StrapFlagReading(key: key, value: nil, status: "FAILURE")
        case .unsupported: return StrapFlagReading(key: key, value: nil, status: "UNSUPPORTED")
        default: return StrapFlagReading(key: key, value: nil, status: response.result.label)
        }
        let body = response.body
        guard body.count >= bodyLength else {
            return StrapFlagReading(key: key, value: nil, status: "not decoded: body \(body.count) bytes, expected 65")
        }
        guard body[0] == 0x01 else {
            return StrapFlagReading(key: key, value: nil, status: "not decoded: revision \(body[0])")
        }
        guard let field = keyField(key), Array(body[1...fieldLength]) == field else {
            return StrapFlagReading(key: key, value: nil, status: "key not echoed")
        }
        let valueField = body[(1 + fieldLength)..<bodyLength]
        let text = valueField.prefix { $0 != 0 }
        guard text.allSatisfy({ (0x20...0x7E).contains($0) }) else {
            return StrapFlagReading(key: key, value: nil, status: "not decoded: value is not text (\(Array(text).hexLower))")
        }
        if text.isEmpty { return StrapFlagReading(key: key, value: "", status: "empty value field") }
        return StrapFlagReading(key: key, value: String(decoding: text, as: UTF8.self), status: "ok")
    }
}

/// A clock value read back from the strap.
public struct ClockReading: Equatable, Sendable {
    public let seconds: UInt32
    /// 1/32768 s (147 only); nil for the deprecated 11 reply.
    public let ticks: UInt16?

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(ticks ?? 0) / 32768)
    }

    /// For the write log: "unix 1780916150 (2026-06-08T10:55:50Z)".
    public var text: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return "unix \(seconds) (\(f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))))"
    }

    /// GET_CLOCK (147) body: [revision u8][seconds u32 LE][ticks u16 LE] (noop:docs/PROTOCOL_TRANSPORT.md "Clock
    /// and identity contracts"). Zero seconds is not a valid clock even under SUCCESS (same source: "there is no
    /// independent validity flag"), so it decodes to nil.
    public static func fromGetClock(_ body: [UInt8]) -> ClockReading? {
        guard body.count >= 7 else { return nil }
        let s = u32(body, 1)
        guard s != 0 else { return nil }
        return ClockReading(seconds: s, ticks: UInt16(body[5]) | (UInt16(body[6]) << 8))
    }

    /// Deprecated GET_CLOCK (11) body. The 5/MG reply layout is UNRESOLVED upstream (noop:docs/PROTOCOL_COMMANDS.md
    /// L313 "Current payload/reply unresolved"); this reads the WHOOP 4 layout (seconds u32 at the start of the
    /// body, noop PostHooks `GET_CLOCK` pay[2..6]) moved to the 5/MG body offset. A wrong guess cannot set
    /// anything: it only makes the readback fail the ±2 s check, which is logged as such.
    public static func fromDeprecatedGetClock(_ body: [UInt8]) -> ClockReading? {
        guard body.count >= 4 else { return nil }
        let s = u32(body, 0)
        guard s != 0 else { return nil }
        return ClockReading(seconds: s, ticks: nil)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}

/// Bluetooth SIG Heart Rate Measurement (0x2A37): flags; HR u8 or u16 (bit 0); sensor contact (bits 1–2,
/// decoded by WhoopProtocol's `StandardHRContact`); energy expended u16 when bit 3; R-R u16 in 1/1024 s when
/// bit 4. noop:Strand/BLE/StandardHeartRate.swift reads the same fields.
public struct HeartRateMeasurement: Equatable, Sendable {
    /// nil when the value is 0 or the sensor reports it has no skin contact (R6: no reading is not a reading).
    public let bpm: Int?
    public let contact: StandardHRContact
    public let rrMs: [Double]

    public static func parse(_ data: [UInt8]) -> HeartRateMeasurement? {
        guard let flags = data.first else { return nil }
        var i = 1
        let raw: Int
        if flags & 0x01 != 0 {
            guard data.count >= i + 2 else { return nil }
            raw = Int(data[i]) | (Int(data[i + 1]) << 8)
            i += 2
        } else {
            guard data.count >= i + 1 else { return nil }
            raw = Int(data[i])
            i += 1
        }
        let contact = StandardHRContact.fromMeasurementFlags(flags)
        if flags & 0x08 != 0 { i += 2 }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < data.count {
                let ticks = Int(data[i]) | (Int(data[i + 1]) << 8)
                if ticks > 0 { rr.append(Double(ticks) * 1000.0 / 1024.0) }
                i += 2
            }
        }
        let bpm: Int? = (raw > 0 && contact != .supportedNotDetected) ? raw : nil
        return HeartRateMeasurement(bpm: bpm, contact: contact, rrMs: rr)
    }
}
