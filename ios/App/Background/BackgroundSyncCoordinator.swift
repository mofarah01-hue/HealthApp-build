import Foundation
import MGDomain
import MGSync
import os
import UIKit

// WP-24 — every sync trigger of ARCHITECTURE §5.7 in one place. MGSync exposes only `sync(trigger, budget:)` (BRIEF,
// WP-14 row); the hourly cadence, the network watcher and the background tasks live here. After every attempt the
// Tailscale reminder is re-checked (PLAN §2).
//
// WP-23 wiring (MGApp / AppModel):
//     let coordinator = BackgroundSyncCoordinator(sync: { t, b in await engine.sync(t, budget: b) },
//                                                 status: { await engine.status }, notify: notifyCenter)
//     BackgroundTasks.register(work: .coordinated(coordinator, compute: { … }, healthRead: { … }))   // in MGApp.init
//     await coordinator.start()                                   // launch: network watcher + hourly loop
//     scenePhase .active     → await coordinator.appDidBecomeActive()
//     scenePhase .background → await coordinator.appDidEnterBackground()
//     history chunk stored / live strap data → await coordinator.strapWoke()
//     pull to refresh, `.refresh` → await coordinator.syncNow()
//     MGSync's `notifier:` = the same NotifyCenter (it batches the receipts).

actor BackgroundSyncCoordinator {
    typealias SyncRun = @Sendable (SyncTrigger, Duration) async -> SyncOutcome

    /// Time budgets. §5.7 sets background refresh 25 s and BLE wake 20 s; the rest are ours (not Mo's preferences).
    enum Budget {
        static let foreground: Duration = Budget.drain
        /// A path change can arrive in a short BLE background window: same as a BLE wake.
        static let pathChange: Duration = .seconds(20)
        static let bleWake: Duration = .seconds(20)
        static let backgroundRefresh: Duration = .seconds(25)
        /// Sync now from an App Intent or pull to refresh (an intent has about 30 s to answer).
        static let manual: Duration = .seconds(25)
        /// T9988 (2026-10-15): a sync Mo can see (app opened, Sync now, pull to refresh) goes on until the queue is empty
        /// instead of stopping at 25-30 s; it runs inside a background task (`SyncGrace`), so leaving the app does not
        /// freeze it. A 15 min ceiling only guards against a PC that answers forever.
        static let drain: Duration = .seconds(900)
        /// The `.rawupload` processing task runs for minutes, not seconds (raw also goes with every other sync, #74).
        static let rawUpload: Duration = .seconds(240)
    }

    /// PLAN §2 "every hour".
    static let hourly: TimeInterval = 3600
    /// Cadence triggers (hourly loop, BG refresh, strap wake) skip when a run started less than this ago (jitter room).
    static let cadenceGap: TimeInterval = 55 * 60
    /// A VPN coming up sends several path updates in a row; one sync after they settle.
    static let pathDebounce: Duration = .seconds(3)

    private let sync: SyncRun
    private let status: @Sendable () async -> SyncStatus
    private let notify: NotifyCenter
    private let clock: any MGDomain.Clock
    private var watcher: BackgroundPathWatcher?
    private var hourlyTask: Task<Void, Never>?
    private var pathTask: Task<Void, Never>?
    private var lastRunAt: Date?
    private(set) var lastOutcome: SyncOutcome?
    /// Why raw frames waited on the newest sync that had raw to send (Low Data Mode); nil = they went (#74).
    private(set) var rawHeld: String?
    /// T10009: set by a memory warning; `rawDecision` says wait until then.
    private var rawPausedUntil: Date?
    private let log = Logger(subsystem: "mgapp", category: "sync-triggers")

    init(sync: @escaping SyncRun, status: @escaping @Sendable () async -> SyncStatus, notify: NotifyCenter,
         clock: any MGDomain.Clock = SystemClock()) {
        self.sync = sync
        self.status = status
        self.notify = notify
        self.clock = clock
    }

    /// Once at launch: the network watcher and the hourly loop. The loop keeps running in the background: while the
    /// strap keeps the app awake (bluetooth-central), an overdue hour fires at the next wake.
    func start() {
        if watcher == nil {
            let w = BackgroundPathWatcher { [weak self] previous, current in
                guard BackgroundNetRule.shouldSync(previous: previous, current: current) else { return }
                Task { await self?.networkBecameUsable() }
            }
            watcher = w
            w.start()
        }
        if hourlyTask == nil {
            hourlyTask = Task { [weak self] in
                while !Task.isCancelled {
                    // T9988: not a fixed hour from launch (a tick that landed inside the 55 min gap skipped, and the next
                    // one was an hour away): the next try is due when the gap since the last run is over.
                    let wait = await self?.secondsUntilNextCadence() ?? BackgroundSyncCoordinator.hourly
                    try? await Task.sleep(for: .seconds(wait))
                    if Task.isCancelled { break }
                    await self?.cadence(.backgroundRefresh, Budget.backgroundRefresh)
                }
            }
        }
    }

    /// The latest network snapshot (for the raw-upload gate and diagnostics).
    var network: BackgroundNetSnapshot? { watcher?.latest }

    /// The raw-upload gate MGSync asks before every sync (#74): any connection outside Low Data Mode.
    /// T10009: and not while a memory warning's pause runs (building a raw drop reads and deflates a lot of frames).
    func rawDecision() -> RawUploadPolicy.Decision {
        if let until = rawPausedUntil, clock.now < until {
            return .wait("paused for a minute after iOS asked the app to free memory")
        }
        return BackgroundNetRule.rawDecision(network: watcher?.latest)
    }

    /// T10009: raw drops are not built for `seconds` (a memory warning); the next sync after that builds them as usual.
    func pauseRawDrops(for seconds: TimeInterval) {
        let until = clock.now.addingTimeInterval(seconds)
        if rawPausedUntil.map({ until > $0 }) ?? true { rawPausedUntil = until }
    }

    // MARK: Triggers

    /// §5.7 "App to foreground": probe, then sync.
    @discardableResult
    func appDidBecomeActive() async -> SyncOutcome { await run(.foreground, Budget.foreground) }

    /// Ask iOS for the background tasks (BGTaskScheduler keeps one request per id; this replaces them).
    func appDidEnterBackground() {
        BackgroundTasks.scheduleAll()
    }

    /// §5.7 "BLE wake after a history chunk is stored". Cheap to call on any strap delivery: it runs at most once per
    /// `cadenceGap` (MGSync also refuses a BLE-wake sync within 60 min of the last attempt).
    func strapWoke() async {
        await cadence(.bleWake, Budget.bleWake)
    }

    /// Sync now (App Intent, pull to refresh, `.refresh`): no cadence gate, no backoff (MGSync's `.manual`).
    @discardableResult
    func syncNow() async -> SyncOutcome { await run(.manual, Budget.manual) }

    /// T9988: Sync now / pull to refresh in the app: no cadence gate, no backoff, and no 25 s stop (an App Intent keeps
    /// `syncNow`, it has to answer in about 30 s).
    @discardableResult
    func syncUntilDrained() async -> SyncOutcome { await run(.manual, Budget.drain) }

    /// The `.sync` BGAppRefreshTask. What it did goes in BackgroundRunLog (Settings › Usage, #40).
    func backgroundRefreshTask() async {
        if inCadenceGap {
            let last = lastRunAt ?? clock.now
            let minutes = Int(clock.now.timeIntervalSince(last) / 60)
            BackgroundRunLog.note(.sync, "skipped: synced \(minutes) min ago")
            return
        }
        let outcome = await run(.backgroundRefresh, Budget.backgroundRefresh)
        BackgroundRunLog.note(.sync, "sync: \(outcome.result.rawValue.replacingOccurrences(of: "_", with: " "))")
    }

    /// The `.rawupload` BGProcessingTask: a long window for raw drops (#74, 2026-10-11: any connection outside Low Data
    /// Mode, charging or not; it used to skip with "not on Wi-Fi + charging" — D11).
    func rawUploadTask() async {
        if case .wait(let why) = rawDecision() {
            log.notice("raw upload skipped: \(why, privacy: .public)")
            BackgroundRunLog.note(.rawUpload, "skipped: " + why)
            return
        }
        let outcome = await run(.rawUpload, Budget.rawUpload)
        BackgroundRunLog.note(.rawUpload, "upload: \(outcome.result.rawValue.replacingOccurrences(of: "_", with: " "))"
                              + (outcome.rawHeld.map { " · " + $0 } ?? ""))
    }

    // MARK: Internals

    private func networkBecameUsable() {
        pathTask?.cancel()
        pathTask = Task { [weak self] in
            try? await Task.sleep(for: BackgroundSyncCoordinator.pathDebounce)
            guard !Task.isCancelled else { return }
            await self?.run(.pathChange, Budget.pathChange)
        }
    }

    /// Inside the 55 min gap since the last run? Not after a run that could not reach the PC (or was refused): then the
    /// engine's own 1/2/5/15/60 min ladder decides (P9734), so a background wake retries instead of sleeping an hour.
    /// Not after a run that stopped with work left either (T9988): the backlog goes on at the next wake.
    private var inCadenceGap: Bool {
        guard let last = lastRunAt, clock.now.timeIntervalSince(last) < BackgroundSyncCoordinator.cadenceGap else { return false }
        if let r = lastOutcome?.result, r == .offline || r == .error || r == .partial { return false }
        return true
    }

    /// Seconds the hourly loop sleeps: 5 min after a run that left work or could not reach the PC (the engine's own ladder
    /// and gaps decide whether anything is sent), else until 55 min after the last run, never less than a minute.
    func secondsUntilNextCadence() -> TimeInterval {
        guard let last = lastRunAt else { return BackgroundSyncCoordinator.hourly }
        if let r = lastOutcome?.result, r == .offline || r == .error || r == .partial { return 300 }
        let due = last.addingTimeInterval(BackgroundSyncCoordinator.cadenceGap + 5).timeIntervalSince(clock.now)
        return min(BackgroundSyncCoordinator.hourly, max(60, due))
    }

    private func cadence(_ trigger: SyncTrigger, _ budget: Duration) async {
        if inCadenceGap { return }
        await run(trigger, budget)
    }

    @discardableResult
    private func run(_ trigger: SyncTrigger, _ budget: Duration) async -> SyncOutcome {
        lastRunAt = clock.now
        let began = clock.now
        let syncRun = sync
        let outcome = await SyncGrace.run("mg.sync") { await syncRun(trigger, budget) }       // T9988: survives leaving the app
        ActivityLog.record(.sync, duration: clock.now.timeIntervalSince(began), now: clock.now)     // B-6
        lastOutcome = outcome
        if outcome.result != .offline && outcome.result != .notSetUp && outcome.result != .skipped || outcome.rawHeld != nil {
            rawHeld = outcome.rawHeld
        }
        let s = await status()
        // Wave W11 (2026-10-11): problems only (PC unreachable > 12 h with data waiting, uploads failing 3 times in a
        // row, storage low) — it used to be the Tailscale reminder (1 h unreachable, 6 h unsynced) next to a receipt
        // banner for every delivery.
        let free = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        await notify.syncAttempted(outcome, status: s, freeBytes: free)
        log.notice("sync \(String(describing: trigger), privacy: .public): \(outcome.result.rawValue, privacy: .public)")
        return outcome
    }

    /// nil = unknown (battery monitoring gives `.unknown` on the first read in some states).
    @MainActor
    private static func chargingNow() -> Bool? {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        switch device.batteryState {
        case .charging, .full: return true
        case .unplugged: return false
        case .unknown: return nil
        @unknown default: return nil
        }
    }
}

extension BackgroundWork {
    /// The usual wiring: sync and raw upload through the coordinator; compute and Health read from WP-23.
    static func coordinated(_ coordinator: BackgroundSyncCoordinator,
                            compute: (@Sendable () async -> Void)?,
                            healthRead: (@Sendable () async -> Void)?) -> BackgroundWork {
        BackgroundWork(sync: { await coordinator.backgroundRefreshTask() },
                       rawUpload: { await coordinator.rawUploadTask() },
                       compute: compute, healthRead: healthRead)
    }
}
