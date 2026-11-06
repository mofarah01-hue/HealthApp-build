import Foundation

/// One WHOOP 4.0 history record (type 47, version 24: one per second) with its raw biometric fields, for the "Raw 4.0" screen
/// (0.6.0.12). Every number is a RAW COUNT, decoded, untested: no calibration, no unit (CLAUDE.md rule 4). Which LED each
/// optical field belongs to is not proven; the names follow the sources.
///
/// Frame-absolute offsets, little-endian (whoop_protocol.json type 47 version 24 = noop `PROTOCOL_SENSORS.md`; `docs/research/
/// WHOOP4-INVENTORY-2026-11-05.md` section 4): unix u32 @11; optical green @33 and red/IR @35 (u16); gravity 3 x f32 @40/44/48;
/// skin-contact byte @55; SpO2-related red @68 and IR @70; skin temperature raw @72; ambient light @74; LED drive @76 and @78;
/// respiration-related raw @80; signal quality @82. Checked against the real on-wrist record in noop's
/// `Whoop4HistoricalV24HardwareTests` (firmware 41.17.6.0) by `Whoop4RawRecordTests`.
public struct Whoop4RawRecord: Equatable, Sendable {
    /// The strap's own clock for the record (unix seconds, as stored; not corrected against the phone's).
    public var unix: Int
    public var opticalGreen: Int
    public var opticalRedIR: Int
    public var gravityX: Double
    public var gravityY: Double
    public var gravityZ: Double
    public var skinContact: Int
    public var spo2Red: Int
    public var spo2IR: Int
    public var skinTempRaw: Int
    public var ambient: Int
    public var ledDrive1: Int
    public var ledDrive2: Int
    public var respRaw: Int
    public var signalQuality: Int

    /// The shortest frame that holds every field (the last one ends at byte 83).
    public static let minimumLength = 84

    /// nil unless `frame` is a WHOOP 4.0 type-47 version-24 record long enough to hold every field.
    public static func decode(frame f: [UInt8]) -> Whoop4RawRecord? {
        guard f.count >= minimumLength, f[0] == 0xAA, f[4] == 47, f[5] == 24 else { return nil }
        func u16(_ o: Int) -> Int { Int(f[o]) | Int(f[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(f[o]) | Int(f[o + 1]) << 8 | Int(f[o + 2]) << 16 | Int(f[o + 3]) << 24 }
        func f32(_ o: Int) -> Double {
            let bits = UInt32(f[o]) | UInt32(f[o + 1]) << 8 | UInt32(f[o + 2]) << 16 | UInt32(f[o + 3]) << 24
            return Double(Float(bitPattern: bits))
        }
        let unix = u32(11)
        guard unix > 0 else { return nil }
        return Whoop4RawRecord(unix: unix, opticalGreen: u16(33), opticalRedIR: u16(35),
                               gravityX: f32(40), gravityY: f32(44), gravityZ: f32(48), skinContact: Int(f[55]),
                               spo2Red: u16(68), spo2IR: u16(70), skinTempRaw: u16(72), ambient: u16(74), ledDrive1: u16(76),
                               ledDrive2: u16(78), respRaw: u16(80), signalQuality: u16(82))
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(unix)) }

    /// The series the Raw 4.0 screen draws, one per row: label, frame offset, and the value of this record.
    public enum Field: String, CaseIterable, Sendable {
        case redIR, green, spo2Red, spo2IR, skinTemp, ambient, ledDrive1, ledDrive2, resp, quality, gravityX, gravityY, gravityZ

        /// "Red/IR raw (frame 35)" ...
        public var title: String {
            switch self {
            case .redIR: return "Red/IR optical raw (frame 35)"
            case .green: return "Green optical raw (frame 33)"
            case .spo2Red: return "SpO₂-related red raw (frame 68)"
            case .spo2IR: return "SpO₂-related IR raw (frame 70)"
            case .skinTemp: return "Skin temperature raw (frame 72)"
            case .ambient: return "Ambient light raw (frame 74)"
            case .ledDrive1: return "LED drive 1 (frame 76)"
            case .ledDrive2: return "LED drive 2 (frame 78)"
            case .resp: return "Respiration-related raw (frame 80)"
            case .quality: return "Signal quality raw (frame 82)"
            case .gravityX: return "Gravity x (frame 40, g)"
            case .gravityY: return "Gravity y (frame 44, g)"
            case .gravityZ: return "Gravity z (frame 48, g)"
            }
        }

        /// Gravity is in g (decoded, untested); everything else is a raw count with no unit.
        public var unit: String? {
            switch self {
            case .gravityX, .gravityY, .gravityZ: return "g"
            default: return nil
            }
        }

        public func value(_ r: Whoop4RawRecord) -> Double {
            switch self {
            case .redIR: return Double(r.opticalRedIR)
            case .green: return Double(r.opticalGreen)
            case .spo2Red: return Double(r.spo2Red)
            case .spo2IR: return Double(r.spo2IR)
            case .skinTemp: return Double(r.skinTempRaw)
            case .ambient: return Double(r.ambient)
            case .ledDrive1: return Double(r.ledDrive1)
            case .ledDrive2: return Double(r.ledDrive2)
            case .resp: return Double(r.respRaw)
            case .quality: return Double(r.signalQuality)
            case .gravityX: return r.gravityX
            case .gravityY: return r.gravityY
            case .gravityZ: return r.gravityZ
            }
        }
    }
}
