import Foundation

/// T9819 / C11 / C12: "is the app alive in the background, and when does iOS kill it".
///
/// iOS never tells a process it is about to be killed (a swipe-away is a SIGKILL, T157), so the answer is inferred:
/// every event and a heartbeat every `heartbeatEvery` (while the process runs) refresh `lastSeen`. A heartbeat stops
/// when the app is suspended, so on the next cold launch the old `lastSeen` is the last moment the app is KNOWN to have
/// been running; the kill happened between it and the launch. A same-process resume never reaches `inferLaunch`
/// (it only shows as phase events). The log cannot tell a swipe-away from an iOS memory kill; the phase before the
/// gap and the memory-warning events next to it are the hint.
public enum AppLifecycle {
    public static let heartbeatEvery: TimeInterval = 5 * 60
    public static let maxEvents = 400
    public static let batchLimit = 200
    public static let maxBatterySamples = 600

    public enum Kind: String, Codable, Sendable {
        case launch, phase, heartbeat, bleRestore, bgTask, memoryWarning, lowPower, chargeState
    }

    public struct Event: Codable, Equatable, Sendable {
        public var at: Date
        public var kind: Kind
        /// Plain words, e.g. "active", "background", "killed in background, last seen 2:10 AM".
        public var detail: String
        /// A second moment the words refer to (for a launch: when the app was last seen running). Sent as ISO 8601 with
        /// the phone's offset like `at`; the PC formats both as 12-hour Pacific. No clock text is put in `detail`.
        public var ref: Date?
        /// Stable, increasing per event (assigned by `record` / `ensureIDs`; nil only in files from before this field).
        /// The ping's send cursor: positions shift when the capped log drops its oldest events, ids never do.
        public var id: Int?
        public init(at: Date, kind: Kind, detail: String, ref: Date? = nil, id: Int? = nil) {
            self.at = at; self.kind = kind; self.detail = detail; self.ref = ref; self.id = id
        }
    }

    public struct BatterySample: Codable, Equatable, Sendable {
        public var at: Date
        /// 0...1.
        public var level: Double
        public var charging: Bool
        public init(at: Date, level: Double, charging: Bool) { self.at = at; self.level = level; self.charging = charging }
    }

    public struct State: Codable, Equatable, Sendable {
        /// Last moment the process is known to have been running (any event or heartbeat).
        public var lastSeen: Date?
        /// "active", "inactive" or "background" at `lastSeen`.
        public var lastPhase: String?
        public var events: [Event] = []
        public var battery: [BatterySample] = []
        /// Markers written at every launch so the next one can tell WHY the process ended (optional: older files lack them).
        /// When the phone booted (kern.boottime) and the app version of the previous run.
        public var bootTime: Date?
        public var appVersion: String?
        /// Highest event id handed out so far.
        public var lastEventID: Int?
        public init() {}
    }

    public enum Launch: Equatable, Sendable {
        /// No earlier run is on record.
        case first
        /// A new build was installed since the previous run (the install ends the old process).
        case afterUpdate(from: String, to: String, lastSeen: Date?)
        /// The phone started up again since the previous run. `batteryLow`: the last battery sample was nearly empty and
        /// not charging, so it most likely ran flat (a power-off); otherwise a restart or a power-off cannot be told apart.
        case afterReboot(lastSeen: Date, bootedAt: Date, batteryLow: Bool)
        /// The previous process ended without a clean exit and the phone did not restart: killed by iOS or swiped away.
        case afterKill(lastSeen: Date, lastPhase: String, gap: TimeInterval)

        /// Plain words for the log; no clock text (the PC formats `ref`, see `refDate`).
        public var words: String {
            switch self {
            case .first: return "first launch on record"
            case .afterUpdate(let from, let to, _): return "relaunched after an app update (\(from) to \(to)); not a kill"
            case .afterReboot(_, _, let low):
                return low ? "relaunched after the phone powered off (battery was nearly empty) and started again; not a kill"
                           : "relaunched after the phone restarted or was powered off; not a kill"
            case .afterKill(_, let phase, _):
                let where_ = phase == "background" ? "while in the background" : "while on screen"
                return "relaunched after the app ended \(where_) (swipe-away and iOS kill look the same); ref = last seen running"
            }
        }

        /// The moment `words` refers to (last seen running), if any.
        public var refDate: Date? {
            switch self {
            case .first: return nil
            case .afterUpdate(_, _, let seen): return seen
            case .afterReboot(let seen, _, _): return seen
            case .afterKill(let seen, _, _): return seen
            }
        }
    }

    /// T9992 (r9d): the words of the "app was away" notification, or nil when there is nothing to say. Only after a kill
    /// (swipe-away or iOS) while a raw stream was wanted, and only when the gap is `gapNoticeMinimum` or longer; the strap
    /// kept its own copy of what it recorded, so the raw data of the gap comes with the next history download.
    public static let gapNoticeMinimum: TimeInterval = 10 * 60

    public static func gapNoticeWords(launch: Launch, rawWanted: Bool, now: Date, calendar: Calendar) -> String? {
        guard rawWanted, case .afterKill(let seen, _, let gap) = launch, gap >= gapNoticeMinimum else { return nil }
        let from = MGFormat.time(seen, calendar: calendar)
        let to = MGFormat.time(now, calendar: calendar)
        var fromText = from
        if !calendar.isDate(seen, inSameDayAs: now) {       // a gap over midnight names the day it began
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = "EEE"
            fromText = "\(from) \(f.string(from: seen))"
        }
        return "The app was away from \(fromText) to \(to). Raw data for that gap comes with the next history download."
    }

    /// A boot time read twice differs by a second or two; only a clear step forward means the phone restarted.
    public static let bootTolerance: TimeInterval = 120
    /// Last battery sample at or below this and not charging = probably ran flat.
    public static let flatBatteryLevel = 0.03

    /// Call once per process start, before recording the launch event. `bootTime` = now - uptime incl. sleep (kern.boottime);
    /// `appVersion` = the running build. Order: first run, update, restart/power-off, otherwise a kill.
    public static func inferLaunch(previous: State, now: Date, bootTime: Date? = nil, appVersion: String? = nil) -> Launch {
        guard let seen = previous.lastSeen, let phase = previous.lastPhase else { return .first }
        if let old = previous.appVersion, let new = appVersion, old != new {
            return .afterUpdate(from: old, to: new, lastSeen: seen)
        }
        if let oldBoot = previous.bootTime, let boot = bootTime, boot.timeIntervalSince(oldBoot) > bootTolerance {
            let last = previous.battery.last
            let low = last.map { $0.level <= flatBatteryLevel && !$0.charging } ?? false
            return .afterReboot(lastSeen: seen, bootedAt: boot, batteryLow: low)
        }
        return .afterKill(lastSeen: seen, lastPhase: phase, gap: max(0, now.timeIntervalSince(seen)))
    }

    /// After inferring: remember this run's markers for the next launch.
    public static func markLaunch(_ state: inout State, bootTime: Date?, appVersion: String?) {
        if let bootTime { state.bootTime = bootTime }
        if let appVersion { state.appVersion = appVersion }
    }

    /// Records an event and refreshes `lastSeen`; the log is capped (oldest dropped).
    public static func record(_ state: inout State, _ event: Event, phase: String? = nil) {
        var event = event
        let id = (state.lastEventID ?? 0) + 1
        state.lastEventID = id
        event.id = id
        state.events.append(event)
        if state.events.count > maxEvents { state.events.removeFirst(state.events.count - maxEvents) }
        state.lastSeen = max(state.lastSeen ?? event.at, event.at)
        if let phase { state.lastPhase = phase }
    }

    /// Gives events from older files (no id) ids in log order, so the send cursor covers them too.
    public static func ensureIDs(_ state: inout State) {
        for i in state.events.indices where state.events[i].id == nil {
            let id = (state.lastEventID ?? 0) + 1
            state.lastEventID = id
            state.events[i].id = id
        }
    }

    /// The next ping's events: oldest first, at most `limit`, only those after the acknowledged cursor `after`.
    /// The caller advances the cursor to the last id of THIS batch once the PC answers 200, never past it, so a backlog
    /// larger than `limit` is sent over several pings instead of its older part being skipped.
    public static func nextBatch(_ events: [Event], after: Int?, limit: Int = batchLimit) -> [Event] {
        Array(events.filter { ($0.id ?? 0) > (after ?? 0) }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }.prefix(limit))
    }

    public static func recordBattery(_ state: inout State, _ sample: BatterySample) {
        if let last = state.battery.last, last.at == sample.at { return }
        state.battery.append(sample)
        if state.battery.count > maxBatterySamples { state.battery.removeFirst(state.battery.count - maxBatterySamples) }
    }

    public struct Drain: Equatable, Sendable, Codable {
        /// Percentage points of battery per hour, from unplugged stretches only.
        public var percentPerHour: Double
        public var hoursMeasured: Double
        /// Always "estimate": coarse battery level, the app's own wake-ups are part of what is measured.
        public var label: String
    }

    /// Battery drain per hour over the unplugged stretches between consecutive samples. Gaps over 6 h are skipped
    /// (the phone was probably charged or off between them); needs at least 30 min of unplugged time, else nil
    /// (a blank with a reason on the screen, never a made-up number).
    public static func drain(_ samples: [BatterySample]) -> Drain? {
        var dropPoints = 0.0, hours = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.at.timeIntervalSince(a.at)
            guard !a.charging, !b.charging, dt >= 60, dt <= 6 * 3600, b.level <= a.level else { continue }
            dropPoints += (a.level - b.level) * 100
            hours += dt / 3600
        }
        guard hours >= 0.5 else { return nil }
        return Drain(percentPerHour: dropPoints / hours, hoursMeasured: hours, label: "estimate")
    }

    /// The small blob the app sends the PC with each status post (pclab/mglab/app_status.py reads these keys).
    public struct StatusBlob: Codable, Equatable, Sendable {
        public var appVersion: String
        public var sentAt: Date
        public var scenePhase: String?
        public var bleConnected: Bool?
        public var lastStrapFrameAt: Date?
        public var lastSyncAt: Date?
        /// Days waiting to sync.
        public var queueDepth: Int?
        public var lastEvent: Event?
        public var drain: Drain?
        /// Events since the last post the PC acknowledged (the PC appends them to its lifecycle log, de-duplicated).
        public var events: [Event]
        /// T10010: the morning "Raw night" line, the launch timing line and the battery learner state, so the PC (and
        /// Claude on it) can read them without Mo. nil = not known yet.
        public var rawNight: String?
        public var launchTiming: String?
        public var batteryLearner: String?
        /// r9u: the Apple Health queue (batches, bytes, samples) and the last database maintenance, as one line.
        public var healthQueue: String?

        enum CodingKeys: String, CodingKey {
            case appVersion = "app_version", sentAt = "sent_at", scenePhase = "scene_phase", bleConnected = "ble_connected"
            case lastStrapFrameAt = "last_strap_frame_at", lastSyncAt = "last_sync_at", queueDepth = "queue_depth"
            case lastEvent = "last_event", drain, events
            case rawNight = "raw_night", launchTiming = "launch_timing", batteryLearner = "battery_learner"
            case healthQueue = "health_queue"
        }

        public init(appVersion: String, sentAt: Date, scenePhase: String?, bleConnected: Bool?, lastStrapFrameAt: Date?,
                    lastSyncAt: Date?, queueDepth: Int?, lastEvent: Event?, drain: Drain?, events: [Event],
                    extras: StatusExtras = StatusExtras()) {
            self.appVersion = appVersion; self.sentAt = sentAt; self.scenePhase = scenePhase
            self.bleConnected = bleConnected; self.lastStrapFrameAt = lastStrapFrameAt; self.lastSyncAt = lastSyncAt
            self.queueDepth = queueDepth; self.lastEvent = lastEvent; self.drain = drain; self.events = events
            self.rawNight = extras.rawNight; self.launchTiming = extras.launchTiming
            self.batteryLearner = extras.batteryLearner
            self.healthQueue = extras.healthQueue
        }
    }
}
