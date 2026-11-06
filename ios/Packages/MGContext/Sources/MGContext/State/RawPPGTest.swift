import Foundation
import MGDomain

// Settings › Command test › "Raw optical (PPG)" (P9726, Mo Oct 14: "include that test page with toggle on/off for the raw
// PPG I see, so we can figure that out"; R-177..R-180, T122, T124). Pure logic only: the observation record, the measured
// sample rate, the per-slot quality line, motion polling bursts and the "record all night" state. The strap writes, the
// store and the live R20 window are handed in by the app (App/CommandTest/AppModel+CommandTest.swift).

/// What Mo saw on the strap during one test (R-179). nil = not answered: written "?", never as 0 or off.
public struct PPGObservation: Equatable, Sendable {
    public enum Brightness: String, CaseIterable, Equatable, Sendable {
        case low, medium = "med", high
    }

    /// Green LEDs lit: 0, 1, 2 or 3.
    public var greens: Int?
    public var red: Bool?
    public var infrared: Bool?
    public var brightness: Brightness?
    /// T9847 (r9d): the photodiode (the light sensor) seen working / off. Added to the line only when set, so older saved
    /// lines read back unchanged.
    public var photodiode: Bool?
    public var note: String

    public init(greens: Int? = nil, red: Bool? = nil, infrared: Bool? = nil, brightness: Brightness? = nil,
                photodiode: Bool? = nil, note: String = "") {
        self.greens = greens.map { min(max($0, 0), 3) }
        self.red = red
        self.infrared = infrared
        self.brightness = brightness
        self.photodiode = photodiode
        self.note = Self.clean(note)
    }

    public var isEmpty: Bool {
        greens == nil && red == nil && infrared == nil && brightness == nil && photodiode == nil && note.isEmpty
    }

    /// One line, saved with the send it belongs to (`raw_frame` text, so the PC gets it in the next raw drop):
    /// `greens=2 red=on ir=off brightness=med note="..."`.
    public var line: String {
        func onOff(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "?" }
        return "greens=\(greens.map(String.init) ?? "?") red=\(onOff(red)) ir=\(onOff(infrared)) "
            + "brightness=\(brightness?.rawValue ?? "?")" + (photodiode.map { " pd=\($0 ? "on" : "off")" } ?? "")
            + " note=\"\(note)\""
    }

    /// Reads `line` back (the page shows saved observations after a restart).
    public init?(line: String) {
        guard let noteRange = line.range(of: " note=\"") , line.hasSuffix("\"") else { return nil }
        var fields: [String: String] = [:]
        for part in line[..<noteRange.lowerBound].split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        func onOff(_ s: String?) -> Bool? { s == "on" ? true : s == "off" ? false : nil }
        self.init(greens: fields["greens"].flatMap { Int($0) }, red: onOff(fields["red"]), infrared: onOff(fields["ir"]),
                  brightness: fields["brightness"].flatMap(Brightness.init(rawValue:)), photodiode: onOff(fields["pd"]),
                  note: String(line[noteRange.upperBound..<line.index(before: line.endIndex)]))
    }

    /// One line: newlines become spaces, a double quote becomes a single quote (the record ends at its closing quote).
    static func clean(_ text: String) -> String {
        text.map { $0.isNewline ? " " : ($0 == "\"" ? "'" : String($0)) }.joined()
            .trimmingCharacters(in: .whitespaces)
    }
}

/// A saved observation: the send it belongs to (command_test id) and its `PPGObservation.line`.
public struct CommandTestObservation: Equatable, Sendable {
    public var entryID: Int64
    public var line: String

    public init(entryID: Int64, line: String) {
        self.entryID = entryID
        self.line = line
    }
}

/// T124 (parked on the old rule 5, R-177): faster / slower motion polling. whoop_protocol.json names no command that
/// changes the strap's motion sample rate, so the rate of the stream itself stays 100 Hz (81 + 106, the raw-motion
/// switch's own commands); "slower" means short bursts. Nothing is saved: leaving the page's choice for
/// `followSettings` hands raw motion back to the Settings switch.
public enum MotionPolling: String, CaseIterable, Equatable, Sendable {
    case followSettings, every15Min, every5Min, continuous

    public static let burstSeconds: TimeInterval = 60

    public var title: String {
        switch self {
        case .followSettings: return "Settings switch"
        case .every15Min: return "1 min every 15 min"
        case .every5Min: return "1 min every 5 min"
        case .continuous: return "Continuous"
        }
    }

    var period: TimeInterval? {
        switch self {
        case .followSettings, .continuous: return nil
        case .every15Min: return 15 * 60
        case .every5Min: return 5 * 60
        }
    }

    /// Whether raw motion should stream `elapsed` seconds after the choice was made; nil = not this page's call.
    public func streams(elapsed: TimeInterval) -> Bool? {
        switch self {
        case .followSettings: return nil
        case .continuous: return true
        case .every15Min, .every5Min:
            guard let p = period else { return nil }
            return max(elapsed, 0).truncatingRemainder(dividingBy: p) < Self.burstSeconds
        }
    }
}

/// Records per second from PHONE ARRIVAL TIMES of live R20 records (not a nominal 25 Hz). Points older than `window`
/// seconds are dropped; a gap longer than `window` (the switch was off, a disconnect) starts again.
public struct PPGRateMeter: Equatable, Sendable {
    public static let window: TimeInterval = 15
    private var points: [(frames: Int, at: Date)] = []

    public init() {}

    public static func == (a: PPGRateMeter, b: PPGRateMeter) -> Bool {
        a.points.map(\.frames) == b.points.map(\.frames) && a.points.map(\.at) == b.points.map(\.at)
    }

    public mutating func note(frames: Int, at: Date) {
        if let last = points.last {
            if frames == last.frames { return }
            if frames < last.frames || at.timeIntervalSince(last.at) > Self.window { points = [] }
        }
        points.append((frames, at))
        points.removeAll { at.timeIntervalSince($0.at) > Self.window }
    }

    public mutating func reset() { points = [] }

    public var recordsPerSecond: Double? {
        guard let first = points.first, let last = points.last, last.frames > first.frames else { return nil }
        let dt = last.at.timeIntervalSince(first.at)
        return dt > 0 ? Double(last.frames - first.frames) / dt : nil
    }
}

/// The "Raw optical (PPG)" section's state, inside `CommandTestState`.
public struct RawPPGState: Equatable, Sendable {
    public struct Strip: Equatable, Identifiable, Sendable {
        public var id: Int
        /// "Block 2 · slot A · raw counts (decoded, untested)"
        public var label: String
        /// Raw counts, clipped samples left out (gaps, never zeros); the view autoscales.
        public var samples: [Double]
        public var rate: String
        public var quality: String
    }

    public struct Observation: Equatable, Identifiable, Sendable {
        public var id: Int
        /// "<the send> : greens=.. red=.. ir=.. brightness=.. note=".."".
        public var text: String
    }

    /// The Settings "Raw optical" switch (the same one; runs in the background until switched off, pausing only for history downloads).
    public var rawOpticalWanted = false
    public var status = "Off. Turn on to see each slot live."
    public var strips: [Strip] = []
    public var motion: MotionPolling = .followSettings
    public var motionStatus = ""
    /// The last ENABLE_OPTICAL_DATA in the send log was ON.
    public var nightBanking = false
    /// T9992: the saved "Keep raw on the strap if the app is closed" switch.
    public var keepRawOnStrap = false
    /// Newest first.
    public var observations: [Observation] = []

    public init() {}
}

/// What the app hands in about once a second while the page is open (from MGBLE `RawOpticalStatus` / `RawMotionStatus`).
public struct RawPPGLive: Equatable, Sendable {
    public var wanted: Bool
    public var on: Bool
    public var frames: Int
    public var lastFrameAt: Date?
    public var stoppedReason: String?
    public var recent: [R20Block]
    /// How many records `recent` holds per slot at most (MGBLE `RawOpticalStatus.recentSeconds`).
    public var windowRecords: Int
    public var motionOn: Bool
    public var motionSeconds: Int
    /// T9992: the saved "keep raw on the strap if the app is closed" switch.
    public var keepRawOnStrap: Bool

    public init(wanted: Bool, on: Bool, frames: Int, lastFrameAt: Date?, stoppedReason: String?, recent: [R20Block],
                windowRecords: Int, motionOn: Bool, motionSeconds: Int, keepRawOnStrap: Bool = false) {
        self.keepRawOnStrap = keepRawOnStrap
        self.wanted = wanted
        self.on = on
        self.frames = frames
        self.lastFrameAt = lastFrameAt
        self.stoppedReason = stoppedReason
        self.recent = recent
        self.windowRecords = windowRecords
        self.motionOn = motionOn
        self.motionSeconds = motionSeconds
    }
}

public enum RawPPGPresenter {
    /// Payloads pinned in MGBLE `SanctionedCommand` for 107 / 108: [01 01] on, [01 00] off.
    public static let onPayload: [UInt8] = [1, 1]
    public static let offPayload: [UInt8] = [1, 0]
    public static let streamName = "TOGGLE_OPTICAL_MODE"
    public static let bankingName = "ENABLE_OPTICAL_DATA"

    /// Each R20 slot separately (R-180: a light signal with no green and no red lit is IR, so every slot is drawn).
    static func strips(blocks: [R20Block], frames: Int, windowRecords: Int, recordsPerSecond: Double?) -> [RawPPGState.Strip] {
        var out: [RawPPGState.Strip] = []
        for block in blocks.sorted(by: { $0.index < $1.index }) {
            for (slot, raw) in [block.slotA, block.slotB].enumerated() where !raw.isEmpty {
                out.append(.init(id: block.index * 2 + slot,
                                 label: "Block \(block.index) · slot \(slot == 0 ? "A" : "B") · raw counts (decoded, untested)",
                                 samples: LiveWaves.downsample(raw.filter { $0 != LiveWaves.clippedCount }.map(Double.init)),
                                 rate: rate(count: raw.count, frames: frames, windowRecords: windowRecords,
                                            recordsPerSecond: recordsPerSecond),
                                 quality: quality(raw)))
            }
        }
        return out
    }

    /// Samples a record (the slot's window ÷ records in it, once the window is full) × measured records a second.
    static func rate(count: Int, frames: Int, windowRecords: Int, recordsPerSecond: Double?) -> String {
        guard frames >= windowRecords, windowRecords > 0 else {
            return "rate: measuring (needs \(windowRecords) records, \(frames) so far)"
        }
        guard let rps = recordsPerSecond else { return "rate: measuring (records arriving)" }
        let perRecord = Double(count) / Double(windowRecords)
        let shown = perRecord == perRecord.rounded() ? String(Int(perRecord)) : String(format: "%.1f", perRecord)
        return String(format: "%.1f Hz measured", perRecord * rps)
            + " (\(shown) samples a record × \(String(format: "%.2f", rps)) records/s)"
    }

    /// One line per slot. Raw counts only: no wavelength, no perfusion claim.
    static func quality(_ raw: [Int32]) -> String {
        guard !raw.isEmpty else { return "no samples yet" }
        let clipped = raw.filter { $0 == LiveWaves.clippedCount }.count
        let kept = raw.filter { $0 != LiveWaves.clippedCount }
        guard let lo = kept.min(), let hi = kept.max() else { return "all \(raw.count) samples clipped at full scale" }
        if kept.allSatisfy({ $0 == 0 }) { return "all zero (no signal on this slot)" }
        var line: String
        if lo == hi {
            line = "flat: \(grouped(Int(lo))) counts, no change (no signal on this slot)"
        } else {
            let mean = kept.reduce(0.0) { $0 + Double($1) } / Double(kept.count)
            line = "\(kept.count) samples · \(grouped(Int(lo))) to \(grouped(Int(hi))) counts"
            if mean != 0 { line += String(format: " · swing %.1f %% of level", Double(hi - lo) / abs(mean) * 100) }
        }
        if clipped > 0 { line += " · \(clipped) clipped at full scale" }
        return line
    }

    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// "Record all night" reads the send log: on when the newest ENABLE_OPTICAL_DATA sent was [01 01]. `log` newest first.
    static func nightBankingOn(log: [CommandTestEntry], bankingNumber: Int?) -> Bool {
        guard let n = bankingNumber, let last = log.first(where: { $0.number == n }) else { return false }
        return last.payloadHex == "0101"
    }

    static func status(_ live: RawPPGLive?, now: Date) -> String {
        guard let live, live.wanted else { return "Off. Turn on to see each slot live." }
        if let why = live.stoppedReason { return "Not streaming: \(why)." }
        guard live.on else { return "Waiting: raw optical starts when the strap is connected." }
        guard let at = live.lastFrameAt else { return "On: waiting for the first record." }
        let age = Int(now.timeIntervalSince(at).rounded())
        return "On: \(live.frames) records" + (age > 3 ? ", none for \(age) s" : ", arriving")
    }
}
