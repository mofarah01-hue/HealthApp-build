import Foundation
import WhoopProtocol

/// One read of the WHOOP 4.0's optical front-end settings (0.6.0.12; Mo Nov 5 2026), read-only: GET_LED_DRIVE (40), GET_TIA_GAIN (42)
/// and GET_BIAS_OFFSET (44), body `00` each, one send each, never retried with another body, and NEVER a SET (39, 41, 43). The
/// reply is kept as raw hex with the time and the wear state, because nobody has published what the bytes mean
/// (`WHOOP4-REDIR-LED-ALGORITHMS-2026-11-05.md` section 2: "layout unknown"; the safe order is to record GETs in each state and compare
/// them with the history records' LED drive at frame 76/78). Nothing here interprets the bytes: raw counts, decoded, untested.
public struct Whoop4LedRead: Equatable, Sendable, Identifiable {
    public static let commands: [UInt8] = [40, 42, 44]
    /// The payload of every read (the form johnmiddleton12's probe script uses).
    public static let body: [UInt8] = [0x00]
    /// `raw_frame.packet_type` of the stored note line: not a strap packet type, the bytes are ASCII text.
    public static let notePacketType: UInt8 = 0xFD

    public static func name(_ command: UInt8) -> String {
        switch command {
        case 40: return "GET_LED_DRIVE"
        case 42: return "GET_TIA_GAIN"
        case 44: return "GET_BIAS_OFFSET"
        default: return "command \(command)"
        }
    }

    public var at: Date
    public var command: UInt8
    /// WRIST_ON / WRIST_OFF as the link knew it at the send; nil = no wrist event seen yet.
    public var worn: Bool?
    /// The reply's result word ("SUCCESS", "UNSUPPORTED", ...), "no reply", or "failed".
    public var result: String
    /// The whole reply frame as lowercase hex ("" when none came).
    public var replyHex: String
    /// Why there was no reply, in words.
    public var error: String?

    public var id: String { "\(Int(at.timeIntervalSince1970))-\(command)" }
    public var title: String { "\(Self.name(command)) (\(command))" }

    public init(at: Date, command: UInt8, worn: Bool?, result: String, replyHex: String, error: String? = nil) {
        self.at = at
        self.command = command
        self.worn = worn
        self.result = result
        self.replyHex = replyHex
        self.error = error
    }

    /// The one ASCII line stored (raw archive, so the PC gets it too) and shown after a relaunch:
    /// `ledread cmd=40 at=1780930000 worn=1 result=SUCCESS reply=aa..`; `worn=?` when unknown; an error adds ` error=<words>` last.
    public var line: String {
        let w = worn.map { $0 ? "1" : "0" } ?? "?"
        var s = "ledread cmd=\(command) at=\(Int(at.timeIntervalSince1970)) worn=\(w) result=\(result.replacingOccurrences(of: " ", with: "_")) reply=\(replyHex)"
        if let error { s += " error=\(error)" }
        return s
    }

    public static func parse(line: String) -> Whoop4LedRead? {
        guard line.hasPrefix("ledread ") else { return nil }
        var errorText: String?
        var head = line
        if let r = line.range(of: " error=") {
            errorText = String(line[r.upperBound...])
            head = String(line[..<r.lowerBound])
        }
        var fields: [String: String] = [:]
        for part in head.dropFirst("ledread ".count).split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        guard let c = fields["cmd"].flatMap(UInt8.init), let t = fields["at"].flatMap(TimeInterval.init),
              let result = fields["result"], let reply = fields["reply"] else { return nil }
        let worn: Bool? = fields["worn"] == "1" ? true : (fields["worn"] == "0" ? false : nil)
        return Whoop4LedRead(at: Date(timeIntervalSince1970: t), command: c, worn: worn,
                             result: result.replacingOccurrences(of: "_", with: " "), replyHex: reply, error: errorText)
    }
}

/// When the overnight read is due (pure, so a test can pin it): every 30 minutes while connected, from 10 PM to 8 AM on the phone's
/// clock or while the app believes Mo is asleep. A first read is due as soon as the window opens.
public enum Whoop4LedSchedule {
    public static let interval: TimeInterval = 30 * 60
    public static let startHour = 22
    public static let endHour = 8

    public static func inWindow(hour: Int, asleep: Bool) -> Bool {
        asleep || hour >= startHour || hour < endHour
    }

    public static func due(now: Date, lastAt: Date?, connected: Bool, hour: Int, asleep: Bool) -> Bool {
        guard connected, inWindow(hour: hour, asleep: asleep) else { return false }
        guard let lastAt else { return true }
        return now.timeIntervalSince(lastAt) >= interval
    }
}
