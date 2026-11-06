import Foundation

/// 0.6.0.5 "Ring lab": frames for the MoYoung ring and a label for what comes back. Pure, no Bluetooth.
/// Frame = `FD DA 10 <len> <cmd> <sub> <payload>`, len = the whole frame's size (payload + 6). Sources: ring-re/ in the repo
/// root (PHASE0-RESEARCH.md); every decode below is "decoded, untested" until checked on Mo's ring.
public enum RingFrames {
    public static func bytes(hex: String) -> [UInt8]? {
        let s = hex.filter { !$0.isWhitespace }.lowercased()
        guard !s.isEmpty, s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let n = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<n], radix: 16) else { return nil }
            out.append(b)
            i = n
        }
        return out
    }

    public static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    public static func spaced(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

    /// `cmd sub payload...` -> the whole frame.
    public static func frame(_ body: [UInt8]) -> [UInt8] { [0xFD, 0xDA, 0x10, UInt8(body.count + 4)] + body }

    /// What a user may type: a whole frame (starts FD DA 10, sent exactly as typed so the guard can judge its length) or just
    /// `cmd sub payload...` (wrapped here). nil = not hex.
    public static func fromTyped(_ text: String) -> [UInt8]? {
        guard let b = bytes(hex: text) else { return nil }
        if b.count >= 3, b[0] == 0xFD, b[1] == 0xDA, b[2] == 0x10 { return b }
        return frame(b)
    }

    // The frames of every Ring lab control (body = cmd, sub, payload).
    public static func measure(sub: UInt8, on: Bool) -> [UInt8] { frame([0x01, sub, on ? 1 : 0]) }
    /// Automatic monitoring interval, 0...12 (0 = off): HR 0x06, HRV 0x07, SpO2 0x08, stress 0x27.
    public static func autoInterval(sub: UInt8, n: Int) -> [UInt8] { frame([0x01, sub, UInt8(min(max(n, 0), 12))]) }
    public static func temperatureAuto(_ on: Bool) -> [UInt8] { frame([0x01, 0x0D, on ? 1 : 0]) }
    public static let readCurrentSubs: [UInt8] = [0x06, 0x07, 0x08, 0x2D, 0x15]
    public static func readSetting(sub: UInt8) -> [UInt8] { frame([0x02, sub]) }
    public static let firmware = frame([0x03, 0x03])
    public static func vibrationLevel(_ level: Int) -> [UInt8] { frame([0x09, 0x00, 0x00, UInt8(min(max(level, 0), 3))]) }
    public static let readVibration = frame([0x09, 0x00, 0x01])
    public static func findRing(_ on: Bool) -> [UInt8] { frame([0x09, 0x02, on ? 1 : 0]) }
    public static func notificationBuzz(type: Int) -> [UInt8] { frame([0x01, 0x12, UInt8(min(max(type, 0), 15))]) }
    public static func gestures(_ on: Bool) -> [UInt8] { frame([0x01, 0x21, on ? 1 : 0]) }
    public static let readGestures = frame([0x02, 0x26])
    public static let readLED = frame([0x03, 0x1F, 0x02])
    public static func ledSwitch(_ on: Bool) -> [UInt8] { frame([0x03, 0x1F, 0x01, on ? 1 : 0]) }
    public static func ledEffect(_ e: Int) -> [UInt8] { frame([0x03, 0x1F, 0x00, UInt8(min(max(e, 0), 7))]) }

    // MARK: Labels

    /// A short plain-English label for something the ring sent, or nil when the frame is not known at all.
    /// `char` is the short characteristic id: "2a37", "2a19", "fdd1", "fdd3".
    public static func describe(char: String, bytes b: [UInt8]) -> String? {
        switch char.lowercased() {
        case "2a37":
            guard b.count >= 2 else { return nil }
            let bpm = b[0] & 1 == 1 ? (b.count >= 3 ? Int(b[1]) | Int(b[2]) << 8 : nil) : Int(b[1])
            return bpm.map { "heart rate \($0) bpm" }
        case "2a19":
            guard let v = b.first else { return nil }
            return "battery \(v) %"
        case "fdd1":
            guard b.count >= 6 else { return nil }
            let steps = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
            let metres = Int(b[3]) | Int(b[4]) << 8 | Int(b[5]) << 16
            return "steps \(steps), distance \(metres) m"
        case "fdd3":
            return describeReply(b)
        default:
            return nil
        }
    }

    private static func describeReply(_ b: [UInt8]) -> String? {
        guard b.count >= 6, b[0] == 0xFD, b[1] == 0xDA, b[2] == 0x10 else { return nil }
        let cmd = b[4], sub = b[5]
        let p = Array(b.dropFirst(6))
        let tag = String(format: "%02x %02x", cmd, sub)
        switch (cmd, sub) {
        case (0x01, 0x09): return "heart rate " + oneByte(p, unit: "bpm", valid: 30...230)
        case (0x01, 0x0A):
            if p.count >= 2 { return p[0] == 0xFF && p[1] == 0xFF ? "HRV: no reading" : "HRV \(Int(p[0]) | Int(p[1]) << 8) ms" }
            return "HRV " + oneByte(p, unit: "", valid: 1...255)
        case (0x01, 0x0B): return "SpO2 " + oneByte(p, unit: "% (estimate)", valid: 1...100)
        case (0x01, 0x0E): return "stress " + oneByte(p, unit: "(estimate)", valid: 1...100)
        case (0x01, 0x20):
            if p.count >= 2 {
                if p[0] == 0xFF && p[1] == 0xFF { return "skin temperature: no reading" }
                return String(format: "skin temperature %.1f °C (decoded, untested)", Double(Int(p[0]) | Int(p[1]) << 8) / 10)
            }
            return "skin temperature " + oneByte(p, unit: "", valid: 1...255)
        case (0x01, 0x19):
            if p.count >= 2 {
                if p[0] == 0xFF || p[1] == 0xFF { return "blood pressure: no reading" }
                return "blood pressure \(p[0])/\(p[1]) (wellness estimate)"
            }
            return "blood pressure " + oneByte(p, unit: "", valid: 1...255)
        case (0x01, 0x12): return "notification buzz acknowledged"
        case (0x01, 0x21): return "gestures " + ack(p)
        case (0x01, 0x06), (0x01, 0x07), (0x01, 0x08), (0x01, 0x27), (0x01, 0x0D): return "setting \(tag) acknowledged"
        case (0x01, 0x01): return "clock set"
        case (0x02, _):
            let names: [UInt8: String] = [0x06: "automatic HR", 0x07: "automatic HRV", 0x08: "automatic SpO2",
                                          0x2D: "setting 2d (stress?)", 0x15: "setting 15 (temperature?)",
                                          0x26: "gestures state"]
            return "\(names[sub] ?? "setting \(tag)"): " + (p.isEmpty ? "(empty)" : spaced(p))
        case (0x03, 0x03):
            let text = String(decoding: p.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            return "firmware \"\(text)\""
        case (0x03, 0x07): return p.first == 0 ? "wear: not on finger" : "wear: on finger"
        case (0x03, 0x17): return "gesture" + (p.isEmpty ? "" : " " + spaced(p))
        case (0x03, 0x1F): return "LED " + (p.isEmpty ? "(empty)" : spaced(p))
        case (0x09, 0x00): return p.count >= 2 ? "vibration level \(p[1])" : "vibration " + (p.isEmpty ? "(empty)" : spaced(p))
        case (0x09, 0x02): return "find ring " + ack(p)
        default: return "command \(tag)" + (p.isEmpty ? "" : " " + spaced(p)) + " (not decoded)"
        }
    }

    private static func ack(_ p: [UInt8]) -> String {
        guard let v = p.first else { return "(empty)" }
        return v == 0 ? "off (acknowledged)" : v == 1 ? "on (acknowledged)" : spaced(p)
    }

    private static func oneByte(_ p: [UInt8], unit: String, valid: ClosedRange<Int>) -> String {
        guard let v = p.first else { return "(empty)" }
        if v == 0xFF { return "no reading" }
        if p.count == 1, v == 0 || v == 1 { return ack(p) }
        let u = unit.isEmpty ? "" : " " + unit
        return valid.contains(Int(v)) ? "\(v)\(u)" : "value \(v) (outside \(valid.lowerBound)-\(valid.upperBound))"
    }

    /// "cmd sub" in hex of an FDDA frame, or nil.
    public static func commandKey(_ b: [UInt8]) -> String? {
        guard b.count >= 6, b[0] == 0xFD, b[1] == 0xDA, b[2] == 0x10 else { return nil }
        return String(format: "%02x %02x", b[4], b[5])
    }
}
