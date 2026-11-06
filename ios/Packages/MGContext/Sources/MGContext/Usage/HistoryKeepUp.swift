import Foundation

/// Wave W11 (2026-10-11, Mo 9:30 PM: "every time I open it it's syncing or fetching strap history … it should be doing
/// that without me opening the app"; it was 3 h 18 min behind). Strap history used to come down only when a connection
/// was made, and a connection kept up for hours in the background brought nothing. Now:
/// - while the strap is connected (app open or not), history is pulled every `pullEvery`;
/// - in the background, live HR (the sanctioned realtime toggle, CLAUDE.md rule 5) stays on so iOS keeps waking the
///   app (bluetooth-central) — the same mechanism wave 4 uses for its night windows — bounded by the phone's and the
///   strap's battery and by the wrist;
/// - BGTasks pull too when iOS grants time (App side).
/// Settings › Usage shows what it cost (`usageSection`).
public enum HistoryKeepUp {
    public static let pullEvery: TimeInterval = 15 * 60
    /// Below this phone battery (not charging) the background keep-awake stops; pulls still run when the app wakes.
    public static let minPhoneBattery = 0.20
    /// Below this strap battery (percent) the keep-awake stops: live HR costs strap battery.
    public static let minStrapBattery = 15.0

    public struct Input: Equatable, Sendable {
        public var enabled: Bool
        public var sample: Bool
        public var appActive: Bool
        /// Handshake done (ready or downloading).
        public var connected: Bool
        public var downloading: Bool
        /// When the last history download (any trigger) finished.
        public var lastPullAt: Date?
        public var now: Date
        /// 0…1, nil = unknown.
        public var phoneBattery: Double?
        public var phoneCharging: Bool?
        /// Percent, nil = unknown.
        public var strapBattery: Double?
        public var offWrist: Bool

        public init(enabled: Bool, sample: Bool, appActive: Bool, connected: Bool, downloading: Bool, lastPullAt: Date?,
                    now: Date, phoneBattery: Double?, phoneCharging: Bool?, strapBattery: Double?, offWrist: Bool) {
            self.enabled = enabled
            self.sample = sample
            self.appActive = appActive
            self.connected = connected
            self.downloading = downloading
            self.lastPullAt = lastPullAt
            self.now = now
            self.phoneBattery = phoneBattery
            self.phoneCharging = phoneCharging
            self.strapBattery = strapBattery
            self.offWrist = offWrist
        }
    }

    public struct Decision: Equatable, Sendable {
        /// Start a history download now.
        public var pull: Bool
        /// Keep live HR on in the background so iOS keeps the app awake.
        public var keepAwake: Bool
        /// Why the keep-awake is off (nil while it is on, or while the app is open and needs none).
        public var keepAwakeOff: String?
    }

    public static func decide(_ i: Input) -> Decision {
        guard i.enabled else { return Decision(pull: false, keepAwake: false, keepAwakeOff: "switched off") }
        guard !i.sample else { return Decision(pull: false, keepAwake: false, keepAwakeOff: "sample data is on") }
        let due = i.lastPullAt.map { i.now.timeIntervalSince($0) >= pullEvery || i.now < $0 } ?? true
        let pull = i.connected && !i.downloading && due
        var off: String?
        if i.appActive {
            off = nil
        } else if let b = i.phoneBattery, b < minPhoneBattery, i.phoneCharging != true {
            off = "phone battery \(Int((b * 100).rounded())) % (below \(Int(minPhoneBattery * 100)) %, not charging)"
        } else if let s = i.strapBattery, s < minStrapBattery {
            off = "strap battery \(Int(s.rounded())) % (below \(Int(minStrapBattery)) %)"
        } else if i.offWrist {
            off = "strap off the wrist"
        }
        return Decision(pull: pull, keepAwake: !i.appActive && off == nil, keepAwakeOff: off)
    }

    /// Today's cost, kept across launches (App: kv), rolled over at local midnight.
    public struct Stats: Codable, Equatable, Sendable {
        public var day: String
        public var pulls: Int = 0
        public var backgroundPulls: Int = 0
        public var records: Int = 0
        public var pullSeconds: Double = 0
        public var keepAwakeSeconds: Double = 0
        public var lastPullAt: Date?
        public var lastResult: String?

        public init(day: String) { self.day = day }

        public mutating func roll(to day: String) {
            if day != self.day { self = Stats(day: day) }
        }
    }

    /// Raw motion (100 Hz) for the same page: whether it streams, what it stores, what the strap battery did.
    public struct MotionCost: Equatable, Sendable {
        public var switchOn: Bool
        public var streaming: Bool
        public var secondsToday: Int
        public var storedSeconds: Int
        public var storedBytes: Int64
        /// Strap battery % per hour over the last 24 h while not charging (nil = too few readings).
        public var strapDrainPerHour: Double?

        public init(switchOn: Bool, streaming: Bool, secondsToday: Int, storedSeconds: Int, storedBytes: Int64,
                    strapDrainPerHour: Double?) {
            self.switchOn = switchOn
            self.streaming = streaming
            self.secondsToday = secondsToday
            self.storedSeconds = storedSeconds
            self.storedBytes = storedBytes
            self.strapDrainPerHour = strapDrainPerHour
        }
    }

    /// Settings › Usage › "Strap in the background".
    public static func usageSection(stats: Stats, decision: Decision?, appActive: Bool, newestStored: Date?,
                                    motion: MotionCost?, now: Date, calendar: Calendar) -> UsageState.Section {
        typealias Row = UsageState.Row
        let hm = { (d: Date) in Clock12.hm(d, calendar: calendar) }
        var rows: [Row] = []
        if let n = newestStored {
            let behind = max(0, now.timeIntervalSince(n))
            rows.append(Row(id: "keepup.newest", title: "Strap history up to", value: hm(n),
                            detail: behind < 60 ? "current" : "\(MGFormat.duration(behind)) behind"))
        } else {
            rows.append(Row(id: "keepup.newest", title: "Strap history up to", value: "nothing stored yet"))
        }
        let last = stats.lastPullAt.map { "last \(hm($0))" + (stats.lastResult.map { " · \($0)" } ?? "") }
        rows.append(Row(id: "keepup.pulls", title: "History pulls today", value: "\(stats.pulls)",
                        detail: ["\(stats.backgroundPulls) in the background", "\(stats.records) records",
                                 "\(UsageMath.seconds(stats.pullSeconds)) of radio", last]
                            .compactMap { $0 }.joined(separator: " · ")))
        let state: String
        if appActive {
            state = "not needed while the app is open"
        } else if let d = decision {
            state = d.keepAwake ? "on" : "off — \(d.keepAwakeOff ?? "not wanted")"
        } else {
            state = "not decided yet"
        }
        rows.append(Row(id: "keepup.awake", title: "Live HR keep-awake today", value: UsageMath.seconds(stats.keepAwakeSeconds),
                        detail: "Now \(state). Keeps the app running in the background so history is pulled every "
                            + "\(Int(pullEvery / 60)) min; stops below \(Int(minPhoneBattery * 100)) % phone battery "
                            + "(not charging), below \(Int(minStrapBattery)) % strap battery, or off the wrist."))
        if let m = motion {
            let value = !m.switchOn ? "off" : (m.streaming ? "streaming" : "on, not streaming now")
            var parts = ["\(UsageMath.seconds(Double(m.secondsToday))) today",
                         "\(UsageMath.bytes(m.storedBytes)) stored (\(m.storedSeconds) s)",
                         "about \(UsageMath.bytes(Int64(2_500 * 86_400))) a day while worn (1 Hz rows + raw frames)"]
            if let d = m.strapDrainPerHour {
                parts.append("strap battery \(MGFormat.number(d, decimals: 1)) % / h over the last 24 h")
            }
            rows.append(Row(id: "keepup.motion", title: "Raw motion (100 Hz)", value: value,
                            detail: parts.joined(separator: " · ")
                                + ". Raw stays on the phone 30 days and until the PC confirms it; the 1 Hz summaries stay."))
        }
        return UsageState.Section(id: "keepup", title: "Strap in the background",
                                  note: "Measured on this phone; counts reset at midnight.", rows: rows)
    }

    /// Strap battery % lost per hour over readings while not charging (nil with fewer than 2 readings or < 1 h).
    public static func drainPerHour(_ readings: [(ts: Int64, percent: Double, charging: Bool?)]) -> Double? {
        var lost = 0.0
        var seconds = 0.0
        for (a, b) in zip(readings, readings.dropFirst()) where a.charging != true && b.charging != true {
            let dt = Double(b.ts - a.ts)
            guard dt > 0, dt < 6 * 3600, b.percent <= a.percent else { continue }
            lost += a.percent - b.percent
            seconds += dt
        }
        return seconds >= 3600 ? lost / (seconds / 3600) : nil
    }
}
