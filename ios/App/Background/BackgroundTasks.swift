import BackgroundTasks
import Foundation
import os

// WP-24 — BGTaskScheduler registration and scheduling (ARCHITECTURE §4.11 background table, §5.7 triggers).
// WP-23 calls `BackgroundTasks.register(work:)` in MGApp.init — iOS requires every handler to be registered before
// the app finishes launching — and `BackgroundTasks.scheduleAll()` when the app goes to the background.

/// What each task does. WP-23 wires these; sync and raw upload come from `BackgroundSyncCoordinator`.
struct BackgroundWork: Sendable {
    var sync: @Sendable () async -> Void
    var rawUpload: @Sendable () async -> Void
    /// ComputeCoordinator (WP-23); nil = not wired → the task is not registered and that is reported.
    var compute: (@Sendable () async -> Void)?
    /// MGHealth background read (WP-14 / WP-23); nil = not wired.
    var healthRead: (@Sendable () async -> Void)?

    func job(for role: BackgroundTaskRole) -> (@Sendable () async -> Void)? {
        switch role {
        case .sync: return sync
        case .rawUpload: return rawUpload
        case .compute: return compute
        case .healthRead: return healthRead
        }
    }
}

enum BackgroundTasks {
    /// §4.11 / §5.7: refresh "requested every ≥ 60 min"; the processing tasks are asked for again after the same gap.
    /// iOS decides the real time. Engineering constant, not one of Mo's preferences.
    static let interval: TimeInterval = 3600

    private static let lock = NSLock()
    private static var registered: [BackgroundTaskRole: String] = [:]
    private static var lastProblems: [String] = []
    private static let log = Logger(subsystem: "mgapp", category: "background")

    /// Settings › Usage (#40): the roles iOS accepted, in BackgroundTaskRole order, and why any other is missing.
    static var registeredRoles: [BackgroundTaskRole] {
        lock.lock()
        defer { lock.unlock() }
        return BackgroundTaskRole.allCases.filter { registered[$0] != nil }
    }

    static var registrationProblems: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lastProblems
    }

    /// Registers a handler for every role that has both a permitted id (Info.plist) and wired work.
    /// Returns the problems (missing ids, unwired work, refusals) — also written to the log; show them in diagnostics.
    @discardableResult
    static func register(ids: BackgroundTaskIDs = .fromMainBundle(), work: BackgroundWork) -> [String] {
        var problems = ids.problems
        for role in BackgroundTaskRole.allCases {
            guard let id = ids.id(for: role) else { continue }
            guard let job = work.job(for: role) else {
                problems.append("\(id): no work wired, not registered")
                continue
            }
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                run(task, role: role, job: job)
            }
            if ok {
                lock.lock()
                registered[role] = id
                lock.unlock()
            } else {
                problems.append("iOS refused to register \(id) (registered twice, or not permitted)")
            }
        }
        for p in problems { log.error("\(p, privacy: .public)") }
        lock.lock()
        lastProblems = problems
        lock.unlock()
        return problems
    }

    /// Submits every registered task (call when the app goes to the background). Returns the failures.
    @discardableResult
    static func scheduleAll(now: Date = Date()) -> [String] {
        BackgroundTaskRole.allCases.compactMap { schedule($0, now: now) }
    }

    /// Submits one task request (replaces a pending one with the same id). nil = submitted or not registered.
    @discardableResult
    static func schedule(_ role: BackgroundTaskRole, now: Date = Date()) -> String? {
        lock.lock()
        let id = registered[role]
        lock.unlock()
        guard let id else { return nil }
        let request: BGTaskRequest
        if role.isProcessing {
            let r = BGProcessingTaskRequest(identifier: id)
            // Raw upload no longer waits for power (#74, 2026-10-11, Mo: "upload always is fine"); compute still does.
            r.requiresExternalPower = role != .rawUpload
            r.requiresNetworkConnectivity = role == .rawUpload
            request = r
        } else {
            request = BGAppRefreshTaskRequest(identifier: id)
        }
        request.earliestBeginDate = now.addingTimeInterval(interval)
        do {
            try BGTaskScheduler.shared.submit(request)
            return nil
        } catch {
            let line = "could not schedule \(id): \(error.localizedDescription)"
            log.error("\(line, privacy: .public)")
            return line
        }
    }

    /// Re-submits first (so the chain survives a run iOS cuts short), runs the work, cancels it on expiry and
    /// completes the task exactly once. Every run goes in BackgroundRunLog (Settings › Usage, #40).
    private static func run(_ task: BGTask, role: BackgroundTaskRole, job: @escaping @Sendable () async -> Void) {
        schedule(role)
        let runId = BackgroundRunLog.begin(role)
        LifecycleRecorder.note(.bgTask, "\(task.identifier) started")
        let work = Task { () -> Bool in
            await job()
            return !Task.isCancelled
        }
        let finisher = Finisher(task: task, runId: runId)
        task.expirationHandler = {
            log.notice("\(task.identifier, privacy: .public) expired; work cancelled")
            LifecycleRecorder.note(.bgTask, "\(task.identifier) expired (iOS took the time back)")
            work.cancel()
            // T10008 (2026-10-17): complete the task NOW. The work can be inside a pipeline slice that cannot be interrupted;
            // waiting for it ran past iOS's deadline, and iOS then ended the app (relaunched only by Bluetooth restore).
            finisher.finish(success: false, outcome: "expired")
        }
        Task {
            let ok = await work.value
            if finisher.finish(success: ok, outcome: ok ? "finished" : "expired"), ok {
                LifecycleRecorder.note(.bgTask, "\(task.identifier) finished")
            }
        }
    }

    /// Completes a BGTask exactly once: the expiration handler and the end of the work both call it, the first one wins
    /// (a second `setTaskCompleted` on the same task is a programming error iOS reports). T10008.
    private final class Finisher: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let task: BGTask
        private let runId: UUID

        init(task: BGTask, runId: UUID) {
            self.task = task
            self.runId = runId
        }

        /// True when this call completed the task; false when an earlier call already had.
        @discardableResult
        func finish(success: Bool, outcome: String) -> Bool {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            guard first else { return false }
            BackgroundRunLog.end(runId, outcome: outcome)
            task.setTaskCompleted(success: success)
            return true
        }
    }
}
