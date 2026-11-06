import Foundation

// Settings › Usage (tracker #40, Mo 2026-10-11: "metrics in the settings for what compute it's using on my phone …
// storage on my phone and desktop … compute desktop used or in use"). The inputs the app reads (file sizes, the
// background-run log, process counters, the PC's GET /v1/usage answer) and the accounting the page shows. Pure; the
// failure modes are in UsageMathTests.

/// One file in the app's container, path relative to the container ("Library/Application Support/MG/mg.sqlite").
public struct UsageFile: Equatable, Sendable {
    public var path: String
    public var bytes: Int64

    public init(path: String, bytes: Int64) {
        self.path = path
        self.bytes = bytes
    }
}

/// What the phone's storage numbers come from.
public struct PhoneStorageInput: Equatable, Sendable {
    /// Every regular file in the app container (Documents, Library, tmp).
    public var files: [UsageFile]
    /// The database's path in `files` ("…/MG/mg.sqlite"); its "-wal" and "-shm" companions belong to it.
    public var databasePath: String
    /// Inside the database: raw strap frames (SUM(length(bytes)) of `raw_frame`) and their count.
    public var rawFrameBytes: Int64?
    public var rawFrames: Int?
    /// Raw frames the PC has not confirmed yet (they stay on the phone until it has, MGStore phoneKeepSeconds).
    public var rawFramesUnconfirmed: Int?
    /// Inside the database: compressed copies of drops kept for re-sending (outbox_file.blob).
    public var outboxBytes: Int64?
    /// Inside the database: per-second PPG / R20 optical records.
    public var opticalBytes: Int64?
    /// Free space for important data (iOS `volumeAvailableCapacityForImportantUsage`) and the volume's size.
    public var deviceFreeBytes: Int64?
    public var deviceTotalBytes: Int64?

    public init(files: [UsageFile], databasePath: String, rawFrameBytes: Int64? = nil, rawFrames: Int? = nil,
                rawFramesUnconfirmed: Int? = nil, outboxBytes: Int64? = nil, opticalBytes: Int64? = nil,
                deviceFreeBytes: Int64? = nil, deviceTotalBytes: Int64? = nil) {
        self.files = files
        self.databasePath = databasePath
        self.rawFrameBytes = rawFrameBytes
        self.rawFrames = rawFrames
        self.rawFramesUnconfirmed = rawFramesUnconfirmed
        self.outboxBytes = outboxBytes
        self.opticalBytes = opticalBytes
        self.deviceFreeBytes = deviceFreeBytes
        self.deviceTotalBytes = deviceTotalBytes
    }
}

/// One background-task run (App/Background/BackgroundRunLog.swift writes them).
public struct BackgroundRunRecord: Codable, Equatable, Sendable {
    /// The task's role: "sync", "compute", "rawupload", "healthread".
    public var role: String
    public var start: Date
    /// nil = no end was written: still running, or the app ended during the run.
    public var end: Date?
    /// "finished" · "expired" (iOS took the time back).
    public var outcome: String?
    /// What the job itself said ("skipped: Raw strap frames are waiting: Low Data Mode is on…").
    public var note: String?
    /// CPU seconds (user + system) the process used during the run.
    public var cpuSeconds: Double?

    public init(role: String, start: Date, end: Date? = nil, outcome: String? = nil, note: String? = nil,
                cpuSeconds: Double? = nil) {
        self.role = role
        self.start = start
        self.end = end
        self.outcome = outcome
        self.note = note
        self.cpuSeconds = cpuSeconds
    }
}

/// The app process's own counters since it launched (getrusage / task_info).
public struct ProcessUsageSample: Equatable, Sendable {
    public var launchedAt: Date
    public var cpuUserSeconds: Double
    public var cpuSystemSeconds: Double
    /// Memory iOS charges the app with (task_vm_info phys_footprint).
    public var memoryBytes: Int64?
    /// Energy-relevant wake-ups (TASK_POWER_INFO): interrupt wake-ups and wake-ups from package idle.
    public var interruptWakeups: Int64?
    public var idleWakeups: Int64?
    /// "nominal" · "fair" · "serious" · "critical".
    public var thermalState: String?
    public var lowPowerMode: Bool?

    public init(launchedAt: Date, cpuUserSeconds: Double, cpuSystemSeconds: Double, memoryBytes: Int64? = nil,
                interruptWakeups: Int64? = nil, idleWakeups: Int64? = nil, thermalState: String? = nil,
                lowPowerMode: Bool? = nil) {
        self.launchedAt = launchedAt
        self.cpuUserSeconds = cpuUserSeconds
        self.cpuSystemSeconds = cpuSystemSeconds
        self.memoryBytes = memoryBytes
        self.interruptWakeups = interruptWakeups
        self.idleWakeups = idleWakeups
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
    }
}

/// The PC's GET /v1/usage answer, as the page needs it (the app maps MGSync's `PCUsageReport` onto this).
public struct PCUsageInput: Equatable, Sendable {
    public struct Area: Equatable, Sendable {
        public var id: String
        public var label: String
        public var bytes: Int64
        public var files: Int

        public init(id: String, label: String, bytes: Int64, files: Int) {
            self.id = id
            self.label = label
            self.bytes = bytes
            self.files = files
        }
    }

    public var at: Date
    public var pcName: String?
    public var dataDir: String?
    public var totalBytes: Int64
    public var areas: [Area]
    public var diskFreeBytes: Int64?
    public var diskTotalBytes: Int64?
    public var uptimeSeconds: Double
    public var cpuSeconds: Double
    public var memoryBytes: Int64?
    public var threads: Int?
    /// The model running now and its date / start; nil = none.
    public var currentModel: String?
    public var currentDate: String?
    public var currentSince: Date?
    public var busy: Bool
    public var queuedDates: [String]
    public var models: Int?
    public var loadErrors: [String]
    public var pluginsWatching: Bool
    public var pluginsIntervalSeconds: Double?
    public var pluginsLastCheck: Date?
    public var pluginsRunning: [String]
    /// T9827: the PC pipeline's last-pass sentence (nil from an older PC).
    public var lastPassLine: String?

    public init(at: Date, pcName: String?, dataDir: String?, totalBytes: Int64, areas: [Area], diskFreeBytes: Int64?,
                diskTotalBytes: Int64?, uptimeSeconds: Double, cpuSeconds: Double, memoryBytes: Int64?, threads: Int?,
                currentModel: String?, currentDate: String?, currentSince: Date?, busy: Bool, queuedDates: [String],
                models: Int?, loadErrors: [String], pluginsWatching: Bool, pluginsIntervalSeconds: Double?,
                pluginsLastCheck: Date?, pluginsRunning: [String], lastPassLine: String? = nil) {
        self.at = at
        self.pcName = pcName
        self.dataDir = dataDir
        self.totalBytes = totalBytes
        self.areas = areas
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
        self.uptimeSeconds = uptimeSeconds
        self.cpuSeconds = cpuSeconds
        self.memoryBytes = memoryBytes
        self.threads = threads
        self.currentModel = currentModel
        self.currentDate = currentDate
        self.currentSince = currentSince
        self.busy = busy
        self.queuedDates = queuedDates
        self.models = models
        self.loadErrors = loadErrors
        self.pluginsWatching = pluginsWatching
        self.pluginsIntervalSeconds = pluginsIntervalSeconds
        self.pluginsLastCheck = pluginsLastCheck
        self.pluginsRunning = pluginsRunning
        self.lastPassLine = lastPassLine
    }
}

/// Where the PC half of the page stands.
public enum PCUsageStatus: Equatable, Sendable {
    case notAsked
    case reading
    case notPaired
    case answered(PCUsageInput)
    /// No answer this time; `last` is the previous answer, shown with its own time.
    case notReachable(reason: String, last: PCUsageInput?)
}

public enum UsageMath {
    /// Phone storage, each byte counted once: the database is its file plus "-wal" and "-shm"; "other app files" is
    /// the rest of the container; raw frames, drop copies and optical records are parts OF the database, never added.
    public struct PhoneStorage: Equatable, Sendable {
        public var appBytes: Int64
        public var databaseBytes: Int64
        public var walBytes: Int64
        public var otherBytes: Int64
        public var otherFiles: Int
    }

    public static func phoneStorage(_ input: PhoneStorageInput) -> PhoneStorage {
        let db = input.databasePath
        var dbBytes: Int64 = 0
        var wal: Int64 = 0
        var other: Int64 = 0
        var otherFiles = 0
        for f in input.files {
            let bytes = max(0, f.bytes)
            if f.path == db || f.path == db + "-shm" {
                dbBytes += bytes
            } else if f.path == db + "-wal" {
                dbBytes += bytes
                wal += bytes
            } else {
                other += bytes
                otherFiles += 1
            }
        }
        return PhoneStorage(appBytes: dbBytes + other, databaseBytes: dbBytes, walBytes: wal, otherBytes: other,
                            otherFiles: otherFiles)
    }

    /// Per background role: the newest run, how many started today (the calendar's day of `now`), and how the newest
    /// one ended. A run with no end that started before this launch did not finish (the app ended mid-run); one that
    /// started in this launch is running now.
    public struct RoleSummary: Equatable, Sendable {
        public var role: String
        public var last: BackgroundRunRecord?
        public var runsToday: Int
        public var state: RunState
    }

    public enum RunState: Equatable, Sendable {
        case never
        case running
        case finished
        case expired
        case cutOff
    }

    public static func backgroundSummary(_ runs: [BackgroundRunRecord], roles: [String], now: Date,
                                         launchedAt: Date, calendar: Calendar) -> [RoleSummary] {
        roles.map { role in
            let mine = runs.filter { $0.role == role }
            let last = mine.max { $0.start < $1.start }
            let today = mine.filter { calendar.isDate($0.start, inSameDayAs: now) }.count
            let state: RunState
            if let last {
                if last.end == nil {
                    state = last.start >= launchedAt ? .running : .cutOff
                } else {
                    state = last.outcome == "expired" ? .expired : .finished
                }
            } else {
                state = .never
            }
            return RoleSummary(role: role, last: last, runsToday: today, state: state)
        }
    }

    // MARK: Words

    /// Decimal units like iOS Settings › Storage: "0 bytes", "812 bytes", "12 KB", "8.4 MB", "1.5 GB", "2.1 TB".
    /// One decimal below 10 of a unit, whole numbers above (never "1,000 KB": it rolls over to the next unit).
    public static func bytes(_ n: Int64) -> String {
        if n < 1000 { return n <= 0 ? "0 bytes" : "\(n) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        func shown(_ x: Double) -> Double { x < 10 ? (x * 10).rounded() / 10 : x.rounded() }
        var x = Double(n) / 1000
        var i = 0
        while i < units.count - 1, shown(x) >= 1000 {
            x /= 1000
            i += 1
        }
        let r = shown(x)
        let text = r < 10 && r != r.rounded() ? MGFormat.number(r, decimals: 1) : String(Int(r))
        return "\(text) \(units[i])"
    }

    /// CPU / run time: "0.4 s", "14 s", "2 min 13 s", "1 h 05 min".
    public static func seconds(_ s: Double) -> String {
        guard s.isFinite else { return "—" }
        let v = max(0, s)
        if v < 10 { return "\(MGFormat.number(v, decimals: 1)) s" }
        if v < 60 { return "\(Int(v.rounded())) s" }
        let whole = Int(v.rounded())
        if whole < 3600 { return "\(whole / 60) min \(whole % 60) s" }
        return String(format: "%d h %02d min", whole / 3600, (whole % 3600) / 60)
    }

    /// Average share of one CPU core over `wall` seconds: "0.4 % of one core".
    public static func coreShare(cpu: Double, wall: Double) -> String? {
        guard wall > 0, cpu.isFinite else { return nil }
        let pct = cpu / wall * 100
        return "\(MGFormat.number(pct, decimals: pct < 10 ? 1 : 0)) % of one core"
    }
}
