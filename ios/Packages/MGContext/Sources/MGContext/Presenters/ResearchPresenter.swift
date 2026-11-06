import Foundation
import MGDomain

/// Live › research (W10, tracker #91, 2026-10-11; they said "isn't built in this version yet"): three small read-outs.
/// - inspector: the newest decoded records (R18 seconds, HR, R-R, strap events, raw frames) with time and key fields;
///   raw counts stay counts.
/// - capture: a labelled capture session — a `marker` event "capture: <label>" from start to stop, using the raw
///   switches that are already on (raw optical 107/108, raw motion 81/106 — CLAUDE.md rule 5, off by default; this
///   screen never turns one on); its raw frames are pinned at stop and counted by packet type.
/// - retention: what raw is on the phone, what the PC confirmed, and when it goes (confirmed AND older than
///   `RawUploadPolicy.phoneKeepSeconds`, at the first sync after; never before the PC confirms).
public enum ResearchAction: Equatable, Sendable {
    case refresh
    case startCapture(label: String)
    case stopCapture
    /// Decode lab (T122): mark and keep the raw frames of the last `ResearchPresenter.decodeWindowMinutes` minutes.
    /// Phone-side only: a marker plus pinned frames, so they go to the PC with the next sync. Sends nothing to the strap.
    case saveRecent
}

/// What the app read for one research screen (MGStore ResearchReads, settings, the log).
public struct ResearchInput: Equatable, Sendable {
    public struct Record: Equatable, Sendable {
        public var kind: String
        public var at: Date
        public var fields: [String]

        public init(kind: String, at: Date, fields: [String]) {
            self.kind = kind
            self.at = at
            self.fields = fields
        }
    }

    public struct Capture: Equatable, Sendable {
        public var label: String
        public var start: Date
        public var end: Date?

        public init(label: String, start: Date, end: Date?) {
            self.label = label
            self.start = start
            self.end = end
        }
    }

    /// One raw packet type seen in the Decode lab window (T122).
    public struct Stream: Equatable, Sendable {
        public var packetType: Int
        public var frames: Int
        public var last: Date

        public init(packetType: Int, frames: Int, last: Date) {
            self.packetType = packetType
            self.frames = frames
            self.last = last
        }
    }

    public struct PerSecond: Equatable, Sendable {
        public var name: String
        public var rows: Int
        public var oldest: Date?

        public init(name: String, rows: Int, oldest: Date?) {
            self.name = name
            self.rows = rows
            self.oldest = oldest
        }
    }

    /// T90 Decode lab "Strap vs ours": what the strap reports on-chip next to what our code computes. nil = no section.
    public struct StrapVsOurs: Equatable, Sendable {
        public struct Value: Equatable, Sendable {
            public var mean: Double
            public var n: Int

            public init(mean: Double, n: Int) {
                self.mean = mean
                self.n = n
            }
        }

        public struct Pair: Equatable, Sendable {
            public var strap: Value?
            public var ours: Value?

            public init(strap: Value? = nil, ours: Value? = nil) {
                self.strap = strap
                self.ours = ours
            }
        }

        public var hr: Pair
        public var rr: Pair
        public var battery: Double?
        public var skinTempRaw: Value?
        public var spo2Byte: Value?

        public init(hr: Pair = Pair(), rr: Pair = Pair(), battery: Double? = nil, skinTempRaw: Value? = nil,
                    spo2Byte: Value? = nil) {
            self.hr = hr
            self.rr = rr
            self.battery = battery
            self.skinTempRaw = skinTempRaw
            self.spo2Byte = spo2Byte
        }
    }

    public var kind: String
    public var now: Date
    public var sample: Bool
    public var problem: String?
    public var records: [Record] = []
    public var capture: Capture?
    public var rawOpticalOn = false
    public var rawMotionOn = false
    public var ecgOn = false
    public var streams: [Stream] = []
    public var frameCounts: [Int: Int] = [:]
    public var rawFrames = 0
    public var rawBytes: Int64 = 0
    public var rawUnconfirmed = 0
    public var oldestRaw: Date?
    public var oldestConfirmedRaw: Date?
    public var oldestUnconfirmedRaw: Date?
    public var perSecond: [PerSecond] = []
    public var strapVsOurs: StrapVsOurs?
    public var lastCleanupAt: Date?
    public var lastCleanupFrames: Int?
    /// r9v (UI-SCRUB L14): the last "read history without deleting" test result and whether it is running (shown in Decode lab).
    public var historyReadTest: [String] = []
    public var historyReadTestRunning = false

    public init(kind: String, now: Date, sample: Bool) {
        self.kind = kind
        self.now = now
        self.sample = sample
    }
}

public enum ResearchPresenter {
    public static let kinds = ["inspector", "capture", "retention", "decode"]
    /// Decode lab (T122): how far back the stream list looks and what "save" keeps.
    public static let decodeWindowMinutes = 10

    public static func make(_ i: ResearchInput, calendar: Calendar) -> InfoScreenState {
        func when(_ d: Date) -> String {
            calendar.isDate(d, inSameDayAs: i.now) ? MGFormat.time(d, calendar: calendar)
                : "\(MGFormat.shortDate(d, calendar: calendar)) \(MGFormat.time(d, calendar: calendar))"
        }
        let refresh = ActionState(id: "refresh", title: "Read again", intent: .research(.refresh))
        switch i.kind {
        case "capture": return capture(i, when: when, refresh: refresh)
        case "decode": return decode(i, when: when, refresh: refresh)
        case "retention": return retention(i, when: when, calendar: calendar, refresh: refresh)
        default: return inspector(i, when: when, refresh: refresh)
        }
    }

    static func inspector(_ i: ResearchInput, when: (Date) -> String, refresh: ActionState) -> InfoScreenState {
        let rows = i.records.enumerated().map { n, r in
            InfoScreenState.Row(id: "\(n)", title: "\(r.kind) · \(when(r.at))", lines: [r.fields.joined(separator: " · ")])
        }
        let empty = InfoScreenState.Row(id: "none", title: "No decoded records on the phone yet",
                                        lines: [i.problem ?? "Wear the strap with the app connected, or pull down on Today."])
        return InfoScreenState(sample: i.sample, kicker: "RESEARCH", title: "Record inspector",
                               summary: "The newest \(i.records.count) decoded records, newest first. Raw counts are "
                                   + "counts, not units.",
                               sections: [.init(id: "records", title: "Records", note: "\(i.records.count)",
                                                rows: rows.isEmpty ? [empty] : rows)],
                               actions: [refresh])
    }

    static func capture(_ i: ResearchInput, when: (Date) -> String, refresh: ActionState) -> InfoScreenState {
        var streams: [String] = []
        if i.rawOpticalOn { streams.append("raw optical") }
        if i.rawMotionOn { streams.append("raw motion") }
        let running = i.capture.map { $0.end == nil } ?? false
        var rows: [InfoScreenState.Row] = []
        if let c = i.capture {
            let span = c.end.map { "\(when(c.start))–\(when($0))" } ?? "since \(when(c.start))"
            let total = i.frameCounts.values.reduce(0, +)
            var lines = ["\(MGFormat.duration((c.end ?? i.now).timeIntervalSince(c.start))) · \(total) raw frames"]
            for (type, n) in i.frameCounts.sorted(by: { $0.key < $1.key }) { lines.append("packet type \(type): \(n)") }
            if c.end != nil { lines.append("Frames pinned on the phone; they go to the PC with the next sync.") }
            rows.append(.init(id: "session", title: "\(running ? "Recording" : "Last session"): \(c.label) · \(span)",
                              lines: lines))
        }
        rows.append(.init(id: "streams", title: streams.isEmpty ? "No raw stream is on"
                                : "Recording uses: " + streams.joined(separator: " and "),
                          lines: ["Raw optical and raw motion are switched in Strap & sync (off by default; they use "
                                  + "strap battery). This screen never turns one on."]))
        var actions: [ActionState] = []
        var prompt: String?
        if running {
            actions.append(ActionState(id: "stop", title: "Stop and keep", intent: .research(.stopCapture)))
        } else if streams.isEmpty || i.sample {
            actions.append(ActionState(id: "start", title: "Start a capture", intent: nil, enabled: false,
                                       disabledReason: i.sample ? "Sample data is on."
                                           : "Turn on raw optical or raw motion in Strap & sync first."))
        } else {
            prompt = "Label, e.g. resting, walk, test 1"
        }
        actions.append(refresh)
        return InfoScreenState(sample: i.sample, kicker: "RESEARCH", title: "Capture session",
                               summary: "A labelled span of raw data: start, do the thing, stop. The span is a marker "
                                   + "in your log and its raw frames are kept.",
                               sections: [.init(id: "capture", title: "Session", rows: rows)], actions: actions,
                               textPrompt: prompt)
    }

    /// T122 Decode lab: raw packet types seen in the last 10 minutes (count, newest frame), the three raw switches as
    /// read-only rows that open Strap & sync (this screen never switches one, and has no command box: CLAUDE.md rule 5),
    /// and one button that keeps those frames (marker + pin; they reach the PC on the next sync).
    static func decode(_ i: ResearchInput, when: (Date) -> String, refresh: ActionState) -> InfoScreenState {
        let minutes = decodeWindowMinutes
        var rows = i.streams.sorted { $0.packetType < $1.packetType }.map {
            InfoScreenState.Row(id: "type\($0.packetType)", title: "packet type \($0.packetType)",
                                value: MGFormat.grouped($0.frames), lines: ["last frame \(when($0.last))"])
        }
        if rows.isEmpty {
            rows = [.init(id: "none", title: "No raw frames in the last \(minutes) minutes",
                          lines: [i.problem ?? "Turn on a raw stream in Strap & sync and wear the strap connected."])]
        }
        func sw(_ id: String, _ name: String, _ on: Bool) -> InfoScreenState.Row {
            .init(id: id, title: name, value: on ? "on" : "off", lines: ["Change it in Strap & sync."], intent: .openStrapSync)
        }
        let save = ActionState(id: "save", title: "Keep the last \(minutes) minutes", intent: i.streams.isEmpty || i.sample
                                   ? nil : .research(.saveRecent),
                               enabled: !i.streams.isEmpty && !i.sample,
                               disabledReason: i.sample ? "Sample data is on." : i.streams.isEmpty ? "No raw frames to keep." : nil)
        var sections: [InfoScreenState.Section] = [
            .init(id: "streams", title: "Streams, last \(minutes) minutes", rows: rows),
            .init(id: "switches", title: "Raw switches",
                  rows: [sw("optical", "Raw optical", i.rawOpticalOn),
                         sw("motion", "Raw motion", i.rawMotionOn),
                         sw("ecg", "ECG", i.ecgOn)])]
        sections.append(researchTools(i))      // r9v (L14); the "Strap vs ours" section stays last
        if let v = i.strapVsOurs { sections.append(strapVsOurs(v)) }
        return InfoScreenState(sample: i.sample, kicker: "RESEARCH", title: "Decode lab",
                               summary: "Raw strap frames by packet type. Kept frames go to your PC "
                                   + "with the next sync, where they can be read and decoded. Counts are counts, not units.",
                               sections: sections, actions: [save, refresh])
    }

    /// r9v (UI-SCRUB L14): the research links and the history test, moved here from the Live tab (Live links back to this screen).
    static func researchTools(_ i: ResearchInput) -> InfoScreenState.Section {
        let testLines: [String]
        if i.historyReadTestRunning { testLines = ["Running — the normal history download waits until it ends."] }
        else if !i.historyReadTest.isEmpty { testLines = i.historyReadTest }
        else { testLines = ["Needs the strap connected. Reads the strap's history and acknowledges nothing, so nothing is deleted."] }
        let canRun = !i.sample && !i.historyReadTestRunning
        return .init(id: "tools", title: "Research tools", rows: [
            .init(id: "inspector", title: "Record inspector", lines: ["The newest decoded records."],
                  intent: .openResearch("inspector")),
            .init(id: "capture", title: "Capture session", lines: ["Record a labelled stretch of raw frames."],
                  intent: .openResearch("capture")),
            .init(id: "retention", title: "Raw retention", lines: ["How many raw frames the phone keeps."],
                  intent: .openResearch("retention")),
            .init(id: "historyReadTest", title: "Test: read history without deleting",
                  lines: i.sample ? ["Sample data is on — the strap is not asked."] : testLines,
                  intent: canRun ? .openResearch("historyReadTest") : nil),
        ])
    }

    /// T90: every on-chip value the decoder really produces (HR, R-R, battery, skin-temp count, SpO2 byte), the strap's
    /// value next to ours. A missing side reads "none today"; a difference (ours - strap) only when both exist. The
    /// strap's own scores are not decoded, so that row says so rather than showing anything. Raw counts keep their
    /// D-025 labels and are never given a unit.
    static func strapVsOurs(_ s: ResearchInput.StrapVsOurs) -> InfoScreenState.Section {
        func pair(_ id: String, _ title: String, _ unit: String, _ decimals: Int,
                  _ p: ResearchInput.StrapVsOurs.Pair) -> InfoScreenState.Row {
            func text(_ v: ResearchInput.StrapVsOurs.Value?) -> String {
                v.map { "\(MGFormat.number($0.mean, decimals: decimals)) \(unit) (n \(MGFormat.grouped($0.n)))" } ?? "none today"
            }
            var lines = ["strap: \(text(p.strap))", "ours: \(text(p.ours))"]
            if let a = p.strap, let b = p.ours {
                let d = b.mean - a.mean
                lines.append("difference: \(d > 0 ? "+" : "")\(MGFormat.number(d, decimals: decimals)) \(unit) (ours - strap)")
            }
            return .init(id: id, title: title, lines: lines)
        }
        func strapOnly(_ id: String, _ title: String, _ strap: String?) -> InfoScreenState.Row {
            .init(id: id, title: title, lines: ["strap: \(strap ?? "none today")", "ours: none today"])
        }
        return .init(id: "strapVsOurs", title: "Strap vs ours",
                     note: "Strap: its own on-chip numbers, last 24 hours. Ours: computed here (heart rate is last night's median), so the periods differ.",
                     rows: [pair("hr", "Heart rate", "bpm", 0, s.hr),
                            pair("rr", "R-R intervals", "ms", 1, s.rr),
                            strapOnly("battery", "Battery", s.battery.map { "\(MGFormat.number($0, decimals: 0))%" }),
                            strapOnly("skinTemp", "Skin temperature", s.skinTempRaw.map {
                                "raw \(MGFormat.number($0.mean, decimals: 0)) (count; decoded, untested)" }),
                            strapOnly("spo2", "SpO2", s.spo2Byte.map {
                                "byte \(MGFormat.number($0.mean, decimals: 0)) (estimate, not checked against WHOOP)" }),
                            .init(id: "scores", title: "Sleep, recovery and strain scores",
                                  lines: ["strap: none today (no decoded packet carries one)"])])
    }

    static func retention(_ i: ResearchInput, when: (Date) -> String, calendar: Calendar,
                          refresh: ActionState) -> InfoScreenState {
        let keepDays = Int(RawUploadPolicy.phoneKeepSeconds / 86_400)
        var raw: [String] = ["\(MGFormat.grouped(i.rawFrames)) frames · \(mb(i.rawBytes))",
                             "\(MGFormat.grouped(i.rawFrames - i.rawUnconfirmed)) confirmed by the PC · "
                                 + "\(MGFormat.grouped(i.rawUnconfirmed)) not yet"]
        if let o = i.oldestRaw { raw.append("oldest received \(when(o))") }
        var prune: [String] = []
        if let oc = i.oldestConfirmedRaw {
            let due = oc.addingTimeInterval(RawUploadPolicy.phoneKeepSeconds)
            prune.append(due <= i.now
                ? "Confirmed frames older than \(keepDays) days go at the next sync (the oldest arrived \(when(oc)))."
                : "The oldest confirmed frame (\(when(oc))) goes at the first sync after \(when(due)).")
        } else {
            prune.append("Nothing is confirmed by the PC yet, so nothing is deleted.")
        }
        if let ou = i.oldestUnconfirmedRaw {
            prune.append("Unconfirmed frames stay until the PC confirms them (oldest \(when(ou))).")
        }
        if let at = i.lastCleanupAt {
            prune.append("Last clean-up \(when(at)): \(MGFormat.grouped(i.lastCleanupFrames ?? 0)) frames removed.")
        }
        let per = i.perSecond.map { p in
            InfoScreenState.Row(id: p.name, title: p.name, value: MGFormat.grouped(p.rows),
                                lines: [p.oldest.map { "oldest \(when($0))" } ?? "none"])
        }
        return InfoScreenState(sample: i.sample, kicker: "RESEARCH", title: "Raw retention",
                               summary: "Every raw frame goes to your PC. The phone deletes only what the PC confirmed "
                                   + "and has kept \(keepDays) days.",
                               sections: [.init(id: "raw", title: "Raw frames on the phone",
                                                rows: [.init(id: "raw", title: "Raw strap frames", lines: raw)]),
                                          .init(id: "prune", title: "When it goes",
                                                rows: [.init(id: "prune", title: "Deletion rule", lines: prune)]),
                                          .init(id: "seconds", title: "Per-second rows", rows: per)],
                               actions: [refresh])
    }

    static func mb(_ bytes: Int64) -> String {
        let m = Double(bytes) / 1_048_576
        return m >= 10 ? "\(MGFormat.number(m, decimals: 0)) MB" : "\(MGFormat.number(m, decimals: 1)) MB"
    }
}
