import Foundation
import MGDomain

/// Everything Settings › Usage shows (tracker #40), read by the app on open and on "Measure again".
public struct UsageInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var sample: Bool
    /// When the phone numbers were read; nil = not yet.
    public var measuredAt: Date?
    public var phone: PhoneStorageInput?
    /// Why the phone sizes could not be read.
    public var phoneProblem: String?
    public var runs: [BackgroundRunRecord]
    /// The background roles this build registers (BackgroundTaskRole raw values), in display order.
    public var roles: [String]
    /// Registration problems (no permitted id, not wired) — the task will never run.
    public var backgroundProblems: [String]
    public var process: ProcessUsageSample?
    public var pc: PCUsageStatus
    public var refreshing: Bool
    /// Why raw strap frames waited on the newest sync (Low Data Mode; #74, 2026-10-11); nil = they went.
    public var rawHeld: String?
    /// R9f (N4): the last few notices the app showed, newest first. Defaults to the app's own `NoticeLog`; tests set it.
    public var notices: [NoticeLog.Entry] = NoticeLog.shared.recent()

    public init(now: Date, calendar: Calendar, sample: Bool, measuredAt: Date?, phone: PhoneStorageInput?,
                phoneProblem: String?, runs: [BackgroundRunRecord], roles: [String], backgroundProblems: [String],
                process: ProcessUsageSample?, pc: PCUsageStatus, refreshing: Bool) {
        self.now = now
        self.calendar = calendar
        self.sample = sample
        self.measuredAt = measuredAt
        self.phone = phone
        self.phoneProblem = phoneProblem
        self.runs = runs
        self.roles = roles
        self.backgroundProblems = backgroundProblems
        self.process = process
        self.pc = pc
        self.refreshing = refreshing
    }
}

public enum UsagePresenter {
    typealias Row = UsageState.Row
    typealias Section = UsageState.Section

    public static func make(_ i: UsageInput) -> UsageState {
        let measured = i.measuredAt.map { "Measured \(MGFormat.time($0, calendar: i.calendar))" } ?? "Not measured yet"
        var state = UsageState(sample: i.sample, measured: i.refreshing ? "Measuring…" : measured,
                               sections: [phoneSection(i), backgroundSection(i), computeSection(i), pcSection(i), noticesSection(i)],
                               refresh: ActionState(id: "refresh", title: "Measure again", intent: .usage(.refresh),
                                                    enabled: !i.refreshing,
                                                    disabledReason: i.refreshing ? "Measuring now." : nil))
        // U2: not measuring and no time to show means the last try gave nothing. Say so once, with the way to retry.
        if !i.refreshing && i.measuredAt == nil && !i.sample {
            state.failure = "Couldn't measure usage. Pull down to try again."
        }
        return state
    }

    // MARK: Phone storage

    static func phoneSection(_ i: UsageInput) -> Section {
        guard let p = i.phone else {
            return Section(id: "phone", title: "Storage on this iPhone", rows: [],
                           message: i.phoneProblem ?? "Not measured yet.")
        }
        let s = UsageMath.phoneStorage(p)
        var rows = [Row(id: "app", title: "HealthApp in total", value: UsageMath.bytes(s.appBytes))]
        var dbDetail = "Everything the strap sent, your log and the results, in one SQLite file"
        if s.walBytes > 0 { dbDetail += " (write-ahead log \(UsageMath.bytes(s.walBytes)))" }
        rows.append(Row(id: "db", title: "Database", value: UsageMath.bytes(s.databaseBytes), detail: dbDetail + "."))
        if let raw = p.rawFrameBytes {
            var d = p.rawFrames.map { "\(MGFormat.grouped($0)) frames" }
            if let u = p.rawFramesUnconfirmed {
                d = [d, u == 0 ? "all confirmed by the PC" : "\(MGFormat.grouped(u)) not yet confirmed by the PC "
                     + "(kept until it has)"].compactMap { $0 }.joined(separator: " · ")
            }
            if let held = i.rawHeld { d = [d, held].compactMap { $0 }.joined(separator: " · ") }
            rows.append(Row(id: "raw", title: "Raw strap frames", value: UsageMath.bytes(raw), detail: d, isPart: true))
        }
        if let o = p.opticalBytes, o > 0 {
            rows.append(Row(id: "optical", title: "Pulse and optical records", value: UsageMath.bytes(o), isPart: true))
        }
        if let o = p.outboxBytes {
            rows.append(Row(id: "outbox", title: "Copies of uploads", value: UsageMath.bytes(o),
                            detail: "Kept to re-send if the PC asks; removed 30 days after the PC confirms.",
                            isPart: true))
        }
        rows.append(Row(id: "other", title: "Other app files", value: UsageMath.bytes(s.otherBytes),
                        detail: "\(MGFormat.grouped(s.otherFiles)) files: settings, exports, caches."))
        if let free = p.deviceFreeBytes {
            rows.append(Row(id: "free", title: "Free on the iPhone", value: UsageMath.bytes(free),
                            detail: p.deviceTotalBytes.map { "of \(UsageMath.bytes($0))" }))
        }
        return Section(id: "phone", title: "Storage on this iPhone", note: "parts of the database are indented",
                       rows: rows, message: i.phoneProblem)
    }

    // MARK: Background runs

    static func roleTitle(_ role: String) -> String {
        switch role {
        case "sync": return "Sync with the PC"
        case "compute": return "Recompute on charge"
        case "rawupload": return "Raw upload (any connection, not in Low Data Mode)"
        case "healthread": return "Apple Health read"
        default: return role
        }
    }

    static func backgroundSection(_ i: UsageInput) -> Section {
        let launched = i.process?.launchedAt ?? i.now
        let rows = UsageMath.backgroundSummary(i.runs, roles: i.roles, now: i.now, launchedAt: launched,
                                               calendar: i.calendar).map { r -> Row in
            let today = r.runsToday == 1 ? "1 today" : "\(r.runsToday) today"
            guard let last = r.last else {
                return Row(id: r.role, title: roleTitle(r.role), value: "none yet",
                           detail: "iOS picks the time; it runs more once the app is used daily.")
            }
            var parts = ["last \(when(last.start, i))"]
            let took = UsageMath.seconds(last.end.map { $0.timeIntervalSince(last.start) } ?? 0)
            switch r.state {
            case .running: parts.append("running now")
            case .cutOff: parts.append("did not finish (the app ended)")
            case .expired: parts.append("stopped by iOS after \(took)")
            case .finished: parts.append("took \(took)")
            case .never: break
            }
            if let cpu = last.cpuSeconds { parts.append("\(UsageMath.seconds(cpu)) CPU") }
            if let note = last.note, !note.isEmpty { parts.append(note) }
            return Row(id: r.role, title: roleTitle(r.role), value: today, detail: parts.joined(separator: " · "))
        }
        return Section(id: "background", title: "Background runs", note: "iOS decides when", rows: rows,
                       message: i.backgroundProblems.isEmpty ? nil : i.backgroundProblems.joined(separator: " "))
    }

    // MARK: The app's own compute

    static func computeSection(_ i: UsageInput) -> Section {
        guard let p = i.process else {
            return Section(id: "compute", title: "This app's compute", rows: [], message: "Not measured yet.")
        }
        let cpu = p.cpuUserSeconds + p.cpuSystemSeconds
        let up = i.now.timeIntervalSince(p.launchedAt)
        var detail = "user \(UsageMath.seconds(p.cpuUserSeconds)) · system \(UsageMath.seconds(p.cpuSystemSeconds))"
        if let share = UsageMath.coreShare(cpu: cpu, wall: up) { detail += " · \(share) on average" }
        var rows = [Row(id: "cpu", title: "CPU time", value: UsageMath.seconds(cpu), detail: detail)]
        if let m = p.memoryBytes {
            rows.append(Row(id: "memory", title: "Memory now", value: UsageMath.bytes(m)))
        }
        if p.interruptWakeups != nil || p.idleWakeups != nil {
            let total = (p.interruptWakeups ?? 0) + (p.idleWakeups ?? 0)
            rows.append(Row(id: "wakeups", title: "CPU wake-ups", value: MGFormat.grouped(Int(total)),
                            detail: "interrupt \(MGFormat.grouped(Int(p.interruptWakeups ?? 0))) · from idle "
                            + "\(MGFormat.grouped(Int(p.idleWakeups ?? 0))) — each one costs battery"))
        }
        if let t = p.thermalState { rows.append(Row(id: "thermal", title: "Thermal state", value: t)) }
        if let lp = p.lowPowerMode {
            rows.append(Row(id: "lowpower", title: "Low Power Mode", value: lp ? "on" : "off"))
        }
        return Section(id: "compute", title: "This app's compute",
                       note: "since it started \(when(p.launchedAt, i))", rows: rows)
    }

    // MARK: Recent messages

    /// R9f (UI-SCRUB-B N4): the notice capsule shows two lines for 5 s; the whole text of the last five is kept here.
    static func noticesSection(_ i: UsageInput) -> Section {
        let rows = i.notices.prefix(NoticeLog.keep).enumerated().map { k, n in
            Row(id: "notice.\(k)", title: when(n.at, i, seconds: true), value: "", detail: n.text)
        }
        return Section(id: "notices", title: "Recent messages", note: "the last \(NoticeLog.keep) the app showed", rows: rows,
                       message: rows.isEmpty ? "None since the app started." : nil)
    }

    // MARK: PC

    static func pcSection(_ i: UsageInput) -> Section {
        switch i.pc {
        case .notAsked:
            return Section(id: "pc", title: "PC", rows: [], message: "Not asked yet.")
        case .reading:
            return Section(id: "pc", title: "PC", rows: [], message: "Asking the PC…")
        case .notPaired:
            return Section(id: "pc", title: "PC", rows: [],
                           message: "No PC paired. Pair your PC Lab in Settings › PC Lab to see its storage and "
                           + "compute.")
        case .answered(let pc):
            return Section(id: "pc", title: pc.pcName.map { "PC · \($0)" } ?? "PC",
                           note: "as of \(when(pc.at, i, seconds: true))", rows: pcRows(pc, i))
        case let .notReachable(reason, last):
            var msg = "PC not reachable — \(reason)."
            if let last { msg += " Below: its last answer, \(when(last.at, i, seconds: true))." }
            return Section(id: "pc", title: last?.pcName.map { "PC · \($0)" } ?? "PC", note: "not reachable",
                           rows: last.map { pcRows($0, i) } ?? [], message: msg)
        }
    }

    static func pcRows(_ pc: PCUsageInput, _ i: UsageInput) -> [Row] {
        var rows = [Row(id: "pc.total", title: "PC Lab data", value: UsageMath.bytes(pc.totalBytes),
                        detail: pc.dataDir.map { "folder “\($0)”" })]
        for a in pc.areas where a.files > 0 {
            rows.append(Row(id: "pc.area.\(a.id)", title: a.label, value: UsageMath.bytes(a.bytes),
                            detail: a.files == 1 ? "1 file" : "\(MGFormat.grouped(a.files)) files", isPart: true))
        }
        if let free = pc.diskFreeBytes {
            rows.append(Row(id: "pc.free", title: "Free on the PC's disk", value: UsageMath.bytes(free),
                            detail: pc.diskTotalBytes.map { "of \(UsageMath.bytes($0))" }))
        }
        if let model = pc.currentModel {
            var d = [pc.currentDate.map { "for \($0)" }, pc.currentSince.map { "since \(when($0, i, seconds: true))" }]
                .compactMap { $0 }.joined(separator: " ")
            if d.isEmpty { d = "running" }
            rows.append(Row(id: "pc.now", title: "Running now", value: model, detail: d))
        } else {
            rows.append(Row(id: "pc.now", title: "Running now", value: pc.busy ? "starting" : "idle",
                            detail: pc.models.map { "\($0) models wait for new days" }))
        }
        if !pc.queuedDates.isEmpty {
            let n = pc.queuedDates.count
            rows.append(Row(id: "pc.queue", title: "Waiting to run", value: n == 1 ? "1 day" : "\(n) days",
                            detail: pc.queuedDates.prefix(5).joined(separator: ", ") + (n > 5 ? " …" : "")))
        }
        if let line = pc.lastPassLine { rows.append(Row(id: "pc.lastpass", title: "PC passes", value: "", detail: line)) }   // T9827
        var plug: [String] = []
        if let s = pc.pluginsIntervalSeconds, pc.pluginsWatching { plug.append("looks every \(Int(s)) s") }
        if let at = pc.pluginsLastCheck { plug.append("last look \(when(at, i))") }
        if !pc.pluginsRunning.isEmpty { plug.append("running " + pc.pluginsRunning.joined(separator: ", ")) }
        let plugValue = !pc.pluginsRunning.isEmpty ? "running" : (pc.pluginsWatching ? "watching" : "not watched")
        rows.append(Row(id: "pc.plugins", title: "Your plugins", value: plugValue,
                        detail: plug.isEmpty ? "Watched only while `python -m mglab serve` runs."
                                             : plug.joined(separator: " · ")))
        var proc = ["up \(MGFormat.duration(pc.uptimeSeconds))"]
        if let share = UsageMath.coreShare(cpu: pc.cpuSeconds, wall: pc.uptimeSeconds) { proc.append(share) }
        if let m = pc.memoryBytes { proc.append("\(UsageMath.bytes(m)) memory") }
        if let t = pc.threads { proc.append("\(t) threads") }
        rows.append(Row(id: "pc.cpu", title: "PC Lab CPU time", value: UsageMath.seconds(pc.cpuSeconds),
                        detail: proc.joined(separator: " · ")))
        for (k, e) in pc.loadErrors.enumerated() {
            rows.append(Row(id: "pc.err.\(k)", title: "Model didn't load", value: "", detail: e))
        }
        return rows
    }

    /// "2:05 PM" today, "Fri 9 Oct 10:01 PM" on another day; "1:50:07 PM" with seconds.
    static func when(_ d: Date, _ i: UsageInput, seconds: Bool = false) -> String {
        var t = MGFormat.time(d, calendar: i.calendar)
        if seconds {
            let c = i.calendar.dateComponents([.hour, .minute, .second], from: d)
            t = ClockText.hms(hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
        }
        return i.calendar.isDate(d, inSameDayAs: i.now) ? t : "\(MGFormat.shortDate(d, calendar: i.calendar)) \(t)"
    }
}
