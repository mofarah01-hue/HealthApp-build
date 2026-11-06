import Foundation
import MGContext
import MGDomain

// WP-23a — runs the phone pipelines over stored history (ARCHITECTURE §11 WP-23): after history is stored, hourly while
// the app is awake, at wake (a new detected wake), after a log save, and from the `.compute` BGProcessingTask (WP-24).
// Requests close together are coalesced (one run after a short pause). SAMPLE mode never computes: sample data is never
// written (§4.12). The pipelines themselves are behind `ComputeRunning` (CompositionHooks.swift).
//
// WRITTEN, NOT COMPILED.

actor ComputeCoordinator {
    /// Requests within this pause become one run (a history download stores many chunks in a row).
    static let debounce: Duration = .seconds(3)
    static let hourly: Duration = .seconds(3600)

    private let runner: any ComputeRunning
    private let calendar: Calendar
    private let clock: any MGDomain.Clock
    private let isSample: @Sendable () async -> Bool
    private let settings: @Sendable () async -> ComputeSettings
    private let onDone: @Sendable (ComputeReport) async -> Void
    /// Wave 2: a run starts (why, how many days) / ends (nil) — the "Working on…" line.
    private let progress: (@Sendable (String?, Int) async -> Void)?
    /// T140: true while the app is in the background and the phone is not on power (a run then has a CPU limit).
    private let backgroundOnBattery: @Sendable () async -> Bool
    /// T9995: true while the app is in the background (charging or not).
    private let inBackground: @Sendable () async -> Bool
    /// T9995: days a light background run did the night pipeline for only; the next foreground (or BGProcessing) run does
    /// their day pipeline too.
    private var nightOnly: Set<String> = []

    private var waiting: Set<String> = []
    private var reasons: [ComputeReason] = []
    /// T134: which days have new or changed inputs; hourly and foreground requests run only these.
    private var dirty = DirtyDays()
    private var lastHistoryEnd: Date?
    private var timer: Task<Void, Never>?
    private var running = false
    /// T9710 (2026-10-14): Today said "Computing has been running since 2:40 AM" at 9:11 AM. A run that iOS froze in
    /// the background (or that hung) kept `running` true, so every later request queued behind it and Today kept the
    /// stale bedtime. A run older than this is abandoned (its task cancelled, its days queued again) by the next request.
    static let staleRunAfter: TimeInterval = 20 * 60
    private var runStartedAt: Date?
    private var runDays: [LocalDay] = []
    private var current: Task<ComputeReport, Never>?
    private var currentWriteLease: ComputeWriteLease?
    private var generation = 0
    private var abandoning = false
    static let cancellationAcknowledgementWait: Duration = .milliseconds(500)
    private var hourlyTask: Task<Void, Never>?
    private var lastWake: Date?
    /// The last runs, newest last, for diagnostics (nothing swallowed).
    private(set) var log: [String] = []
    /// T9737: the persistent copy of the log (MG/compute-log.txt) and the install check (a new build re-runs today).
    private let fileLog: ComputeLog
    private let defaults: UserDefaults
    private let build: String
    static let lastBuildKey = "compute.lastBuild"
    static let installPendingKey = "compute.installRerunPending"
    /// True from the first launch of a new build until a run that included today finished for it.
    private var installRerunPending = false

    init(runner: any ComputeRunning, calendar: Calendar, clock: any MGDomain.Clock,
         isSample: @escaping @Sendable () async -> Bool, settings: @escaping @Sendable () async -> ComputeSettings,
         onDone: @escaping @Sendable (ComputeReport) async -> Void,
         progress: (@Sendable (String?, Int) async -> Void)? = nil,
         backgroundOnBattery: @escaping @Sendable () async -> Bool = { false },
         inBackground: @escaping @Sendable () async -> Bool = { false },
         fileLog: ComputeLog = .shared, defaults: UserDefaults = .standard, build: String = "unknown") {
        self.fileLog = fileLog
        self.defaults = defaults
        self.build = build
        self.backgroundOnBattery = backgroundOnBattery
        self.inBackground = inBackground
        self.progress = progress
        self.runner = runner
        self.calendar = calendar
        self.clock = clock
        self.isSample = isSample
        self.settings = settings
        self.onDone = onDone
    }

    /// A strap download finished (T134). Nothing new stored = no compute; otherwise only the days those records fall in
    /// (and the night that ends next morning). The same summary delivered twice counts once.
    func noteHistory(recordsInserted: Int, firstTs: Int64?, lastTs: Int64?, endedAt: Date) {
        if lastHistoryEnd == endedAt { return }
        lastHistoryEnd = endedAt
        let today = LocalDay(date: clock.now, calendar: calendar)
        let days = dirty.markHistory(recordsInserted: recordsInserted, firstTs: firstTs, lastTs: lastTs, today: today,
                                     calendar: calendar)
        if days.isEmpty {
            note("history download stored no new records: no compute scheduled")
            return
        }
        request(.historyStored, days: days)
    }

    /// Ask for a run soon. `days` nil = yesterday and today (yesterday's day metrics settle after midnight; today's
    /// night belongs to today, D13) — except hourly and foreground requests (`runsOnlyOnNewData`), which run only the
    /// days with new or changed inputs, or a day that rolled over (T134).
    func request(_ reason: ComputeReason, days: [LocalDay]? = nil) {
        let today = LocalDay(date: clock.now, calendar: calendar)
        if days == nil, reason.runsOnlyOnNewData {
            if installRerunPending { dirty.markChanged([today]) }      // T9737: a new build has not computed today yet
            let due = dirty.due(today: today)
            guard !due.isEmpty || runIsStale else {
                note("compute (\(reason.rawValue)) skipped: no new or changed data")
                return
            }
            for d in due { waiting.insert(d.iso) }
        } else {
            for d in days ?? [today.adding(days: -1), today] { waiting.insert(d.iso) }
        }
        reasons.append(reason)
        scheduleFlush()
    }

    private func scheduleFlush() {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: ComputeCoordinator.debounce)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// T9737: once per app launch, before the launch run. Writes the launch line to the persistent log, finds a run the
    /// previous process never finished (killed or frozen by iOS) and, on the first launch of a new build, marks today and
    /// the two days before as changed so every request (not only the launch run) keeps asking until today is computed.
    func noteLaunch() {
        let died = fileLog.noteLaunch(build: build, at: clock.now)
        let today = LocalDay(date: clock.now, calendar: calendar)
        let recent = [today.adding(days: -2), today.adding(days: -1), today]
        let last = defaults.string(forKey: Self.lastBuildKey)
        if last != build {
            defaults.set(build, forKey: Self.lastBuildKey)
            defaults.set(true, forKey: Self.installPendingKey)
            note("new build \(build) (was \(last ?? "none")): today is computed again until a run for it finishes")
        }
        installRerunPending = defaults.bool(forKey: Self.installPendingKey)
        if installRerunPending || died != nil { dirty.markChanged(recent) }
    }

    /// Runs now and waits (the `.compute` background task; launch).
    @discardableResult
    func runNow(_ reason: ComputeReason, days: [LocalDay]? = nil) async -> ComputeReport {
        let today = LocalDay(date: clock.now, calendar: calendar)
        // T9995 (2026-10-17): the power-gated background task is last night only (today holds it, D13), never three days of
        // full pipelines; older days stay due for the foreground.
        let defaultDays = reason == .background ? [today] : [today.adding(days: -2), today.adding(days: -1), today]
        for d in days ?? defaultDays { waiting.insert(d.iso) }
        reasons.append(reason)
        timer?.cancel()
        return await flush()
    }

    /// V3 (2026-10-15): the launch run in two steps so Today's own numbers come first. Step 1 is today (which holds last
    /// night, D13). Step 2 is the older days, and only those whose inputs changed or that rolled over (yesterday after
    /// midnight, a new build, a run the last process never finished); an unchanged older day is not computed again.
    /// Returns the step-1 report; step 2 runs after it and is logged like any run.
    @discardableResult
    func runLaunch() async -> ComputeReport {
        let today = LocalDay(date: clock.now, calendar: calendar)
        let first = await runNow(.launch, days: [today])
        let older = dirty.due(today: today).filter { $0 != today }
        if !older.isEmpty {
            dirty.claim([today.adding(days: -1), today], today: today)   // settles the new local day; older days run next
            _ = await runNow(.launch, days: older)
        }
        return first
    }

    /// A detected wake that wasn't seen before → compute last night (the morning verdict needs it).
    func noteWake(_ wake: Date?) {
        guard let wake, wake != lastWake else { return }
        let first = lastWake == nil
        lastWake = wake
        if !first { request(.wake) }
    }

    func startHourly() {
        guard hourlyTask == nil else { return }
        hourlyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ComputeCoordinator.hourly)
                if Task.isCancelled { break }
                await self?.hourlyTick()
            }
        }
    }

    /// T9737: the hourly timer drops a stale run itself (before, only the next request did, and only through
    /// `request`'s own check), then queues its days again; the usual new-data request follows.
    func hourlyTick() async {
        if runIsStale {
            await abandonStaleRun()
            scheduleFlush()
        }
        request(.hourly)
    }

    /// True when a run has been going longer than `staleRunAfter` (frozen by iOS or hung).
    var runIsStale: Bool {
        guard running, let s = runStartedAt else { return false }
        return clock.now.timeIntervalSince(s) >= Self.staleRunAfter
    }

    /// Drops a stale run: cancels its task (the runner stops taking days), queues its days again, clears the
    /// "Working on" line. When the old run returns its result is only logged.
    private func abandonStaleRun() async {
        guard runIsStale, !abandoning, let s = runStartedAt else { return }
        abandoning = true
        generation += 1
        let task = current
        let lease = currentWriteLease
        await lease?.invalidate()
        task?.cancel()
        let acknowledged = await lease?.waitForAcknowledgement(for: Self.cancellationAcknowledgementWait) ?? true
        current = nil
        currentWriteLease = nil
        running = false
        runStartedAt = nil
        for d in runDays { waiting.insert(d.iso) }
        runDays = []
        abandoning = false
        let line = "compute run started \(RFC3339.format(s, timeZone: calendar.timeZone)) abandoned after "
            + "\(Int(clock.now.timeIntervalSince(s) / 60)) min (frozen in the background or hung): write lease invalidated"
            + (acknowledged ? "; runner stopped" : "; runner did not stop within 500 ms") + "; starting a fresh one"
        note(line)
        fileLog.append(.runAbandoned, line, at: clock.now)
        await progress?(nil, 0)
    }

    @discardableResult
    private func flush() async -> ComputeReport {
        await abandonStaleRun()
        let requested = waiting.sorted().compactMap(LocalDay.init(iso:))
        let why = reasons.last ?? .manual
        waiting.removeAll()
        reasons.removeAll()
        guard !requested.isEmpty else {
            return ComputeReport(ran: false, days: [], metricsWritten: 0, line: "compute: nothing waiting")
        }
        if await isSample() {
            let r = ComputeReport(ran: false, days: requested, metricsWritten: 0,
                                  line: "compute (\(why.rawValue)) skipped: sample data is on")
            note(r.line)
            return r
        }
        if running {
            // One run at a time: put the days back and try again after the current one.
            for d in requested { waiting.insert(d.iso) }
            reasons.append(why)
            timer = Task { [weak self] in
                try? await Task.sleep(for: ComputeCoordinator.debounce)
                await self?.flush()
            }
            return ComputeReport(ran: false, days: requested, metricsWritten: 0, line: "compute queued behind a running one")
        }
        // T9995: in the background (not an explicit Sync/Compute now) a run is light: the night pipeline of today (which
        // holds last night) only. Older days wait for the foreground; a day whose night was done this way gets its day
        // pipeline with the next full run (`nightOnly`). 2026-10-17: the power-gated `.background` task is light too (it was
        // exempt, and was the heaviest run; its CPU use is what iOS cut off).
        let light = await inBackground() && why != .manual
        let days: [LocalDay]
        if light {
            let today = LocalDay(date: clock.now, calendar: calendar)
            let others = requested.filter { $0 != today }
            if !others.isEmpty { dirty.markChanged(others) }
            guard requested.contains(today) else {
                let r = ComputeReport(ran: false, days: requested, metricsWritten: 0,
                                      line: "compute (\(why.rawValue)) held: the app is in the background; \(requested.count) day(s) wait for the foreground")
                note(r.line)
                return r
            }
            days = [today]
        } else if !nightOnly.isEmpty {
            let extra = nightOnly.compactMap(LocalDay.init(iso:))
            nightOnly.removeAll()
            days = Array(Set(requested).union(extra)).sorted()
        } else {
            days = requested
        }
        // The days leave the dirty set when the run starts; a day marked during the run stays for the next one.
        dirty.claim(days, today: LocalDay(date: clock.now, calendar: calendar))
        running = true
        runStartedAt = clock.now
        runDays = days
        fileLog.append(.runStart, "\(why.rawValue), \(days.count) day(s): \(days.map(\.iso).joined(separator: ", "))",
                       at: clock.now)
        generation += 1
        let gen = generation
        await progress?(why.rawValue, days.count)
        var runSettings = await settings()
        let onBattery = await backgroundOnBattery()
        runSettings.backgroundOnBattery = onBattery
        runSettings.lightBackground = light
        let runner = self.runner
        let settingsForRun = runSettings
        let lease = ComputeWriteLease()
        let task = Task {
            let report = await runner.run(days: days, settings: settingsForRun, reason: why, writeLease: lease)
            await lease.acknowledge()
            return report
        }
        current = task
        currentWriteLease = lease
        // T10008 (2026-10-17): the run is an unstructured Task, so cancelling the caller (the BGTask expiration handler
        // cancels the background job) never reached it. Pass the cancel on: stop the runner (it checks between days and
        // slices) and invalidate the write lease so nothing more is written.
        let report = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { await lease.invalidate() }
        }
        ActivityLog.record(.compute, duration: clock.now.timeIntervalSince(runStartedAt ?? clock.now), now: clock.now,
                           calendar: calendar)        // B-6: Settings › Usage › What's running today
        guard gen == generation else {
            note("abandoned run returned: \(report.line)")
            fileLog.append(.note, "the dropped run returned late: \(report.line)", at: clock.now)
            return report
        }
        fileLog.append(.runEnd, report.line, at: clock.now)
        // T9737: a run for this build that took today and did not fail or defer it ends the install re-run.
        let todayDay = LocalDay(date: clock.now, calendar: calendar)
        if installRerunPending, report.ran, days.contains(todayDay), !report.failedDays.contains(todayDay),
           !report.deferredDays.contains(todayDay), !report.nightOnlyDays.contains(todayDay) {
            installRerunPending = false
            defaults.set(false, forKey: Self.installPendingKey)
        }
        running = false
        runStartedAt = nil
        runDays = []
        current = nil
        currentWriteLease = nil
        // A day whose pipeline threw is marked again so the next hourly or foreground request retries it (nothing hidden).
        // Days the run left for its background CPU limit (T140) wait the same way, for the foreground or power.
        if !report.failedDays.isEmpty { dirty.markChanged(report.failedDays) }
        if !report.deferredDays.isEmpty { dirty.markChanged(report.deferredDays) }
        for d in report.nightOnlyDays { nightOnly.insert(d.iso) }
        await progress?(nil, 0)
        note(report.line)
        // D-SLEEP-LOW-2: a night that was not finished (or not published for that reason) stays marked, so a later hourly /
        // foreground / history-stored request runs it again even if the 15-minute timer below dies with the process.
        if !report.provisionalDays.isEmpty { dirty.markChanged(report.provisionalDays); scheduleProvisional(report.provisionalDays) }
        await onDone(report)
        return report
    }

    /// WP-22: a night whose period ends within 5 min of the last strap record may still be going — run it again.
    static let provisionalRetry: Duration = .seconds(15 * 60)
    private var provisionalTask: Task<Void, Never>?

    private func scheduleProvisional(_ days: [LocalDay]) {
        provisionalTask?.cancel()
        provisionalTask = Task { [weak self] in
            try? await Task.sleep(for: ComputeCoordinator.provisionalRetry)
            guard !Task.isCancelled else { return }
            await self?.request(.provisional, days: days)
        }
    }

    private func note(_ line: String) {
        // routine "nothing new" skips (each foreground / hourly check) would push the useful lines out of the file
        if !line.contains("skipped: no new or changed data") { fileLog.append(.note, line, at: clock.now) }
        log.append("\(RFC3339.format(clock.now, timeZone: calendar.timeZone)) \(line)")
        if log.count > 50 { log.removeFirst(log.count - 50) }
    }
}
