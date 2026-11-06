import Foundation
import MGContext
import MGDomain
import MGSync
import UIKit

// T9819 (C11 / C12): the file and the observers behind the pure `MGContext.AppLifecycle`. One small JSON file
// (`MG/app-lifecycle.json`, atomic writes, capped by AppLifecycle itself, never deleted by the app) holds the event log,
// battery samples and the last-seen time; the PC gets the newest events and a status blob with each ping (every
// heartbeat, and at every phase change). Heartbeats run only while the process runs, which is the point: when they stop
// and a later cold launch finds an old `lastSeen`, `AppLifecycle.inferLaunch` reports "ended at about <time>".

private final class LifecycleInbox: @unchecked Sendable {
    struct Pending: Sendable { var at: Date; var kind: AppLifecycle.Kind; var detail: String }
    private let lock = NSLock()
    private var items: [Pending] = []
    func append(_ p: Pending) { lock.lock(); items.append(p); lock.unlock() }
    func takeAll() -> [Pending] { lock.lock(); defer { lock.unlock() }; let r = items; items = []; return r }
}

private let lifecycleInbox = LifecycleInbox()

@MainActor
final class LifecycleRecorder {
    /// Events from outside the main actor (BGTask start / expiry, BLE restoration) wait here until the recorder has
    /// inferred the launch; `note` may be called from any thread, even before the recorder exists.
    private static weak var current: LifecycleRecorder?

    nonisolated static func note(_ kind: AppLifecycle.Kind, _ detail: String) {
        lifecycleInbox.append(LifecycleInbox.Pending(at: Date(), kind: kind, detail: detail))
        Task { @MainActor in current?.drainInbox() }
    }

    private func drainInbox() {
        guard started else { return }
        for p in lifecycleInbox.takeAll() { add(p.kind, p.detail, at: p.at) }
    }

    /// kern.boottime: when the phone last started (sleep time included), unlike ProcessInfo.systemUptime.
    private static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// False until `start()` has inferred how the last run ended: a scene callback that arrives first (iOS delivers
    /// `.inactive` early) must not refresh `lastSeen` and make a first launch or a kill look like a resume.
    private var started = false
    private var pendingPhase: String?
    private var state: AppLifecycle.State
    private let url: URL?
    private let clock: any MGDomain.Clock
    private var heartbeat: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var phase = "inactive"
    /// Id of the last event the PC acknowledged (200); the next ping starts after it.
    private var sentUpToID: Int?
    /// Filled by AppModel: what the status blob reports besides the log.
    var snapshot: () -> (ble: Bool?, lastFrame: Date?, lastSync: Date?, queue: Int?) = { (nil, nil, nil, nil) }
    /// T10010: the Raw night line, the launch timing line and the battery learner state, sent with every ping.
    var extras: () -> StatusExtras = { StatusExtras() }
    /// T10012: the PC's answer to a ping said debug commands are waiting for this phone (the number).
    var onPendingCommands: (Int) -> Void = { _ in }
    /// T9992 (r9d): how this launch came about, once, right after it is inferred (AppModel posts the "app was away" notice).
    var onLaunch: (AppLifecycle.Launch) -> Void = { _ in }
    /// T10009: iOS asked the app to free memory; AppModel drops its display caches.
    var onMemoryWarning: () -> Void = {}

    init(clock: any MGDomain.Clock) {
        self.clock = clock
        let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        url = dir?.appendingPathComponent("MG", isDirectory: true).appendingPathComponent("app-lifecycle.json")
        if let url, let data = try? Data(contentsOf: url),
           let s = try? MGJSON.decoder().decode(AppLifecycle.State.self, from: data) { state = s } else { state = .init() }
        AppLifecycle.ensureIDs(&state)
    }

    private func add(_ kind: AppLifecycle.Kind, _ detail: String, phase p: String? = nil, at: Date? = nil, ref: Date? = nil) {
        if let p { phase = p }
        AppLifecycle.record(&state, .init(at: at ?? clock.now, kind: kind, detail: detail, ref: ref), phase: p)
        save()
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? MGJSON.encoder().encode(state) { try? data.write(to: url, options: .atomic) }
    }

    /// T10012 `logs`: the event log as text, oldest first, times with the phone's offset.
    func logText() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return state.events.map { e in
            "\(f.string(from: e.at)) | \(e.kind.rawValue) | \(e.detail)" + (e.ref.map { " | ref \(f.string(from: $0))" } ?? "")
        }.joined(separator: "\n")
    }

    /// Once per process start (AppModel.start): infers how the last run ended, then starts watching.
    func start() {
        guard !started else { return }
        let version = AppBundle.version
        let launch = AppLifecycle.inferLaunch(previous: state, now: clock.now, bootTime: Self.bootTime(), appVersion: version)
        AppLifecycle.markLaunch(&state, bootTime: Self.bootTime(), appVersion: version)
        let bg = UIApplication.shared.applicationState == .background
        started = true
        Self.current = self
        add(.launch, launch.words + (bg ? "; started in the background (strap reconnect, refresh or similar)" : ""),
            phase: bg ? "background" : "inactive", ref: launch.refDate)
        if let p = pendingPhase { pendingPhase = nil; add(.phase, p, phase: p) }
        onLaunch(launch)
        drainInbox()
        sampleBattery()
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.add(.memoryWarning, "iOS asked the app to free memory (a kill can follow); memory \(MemoryFootprint.text())")
                    self.onMemoryWarning()      // T10009: give memory back now (caches, live buffers, raw drops paused)
                }
            },
            nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.add(.lowPower, ProcessInfo.processInfo.isLowPowerModeEnabled ? "Low Power Mode on" : "Low Power Mode off")
                }
            },
        ]
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppLifecycle.heartbeatEvery))
                guard let self, !Task.isCancelled else { return }
                self.add(.heartbeat, "alive, \(self.phase), memory \(MemoryFootprint.text())")
                self.sampleBattery()
                await self.ping()
            }
        }
        Task { await ping() }
    }

    func phaseChanged(_ name: String) {
        guard started else { pendingPhase = name; return }
        guard name != phase else { return }                  // a repeated callback is not a change
        add(.phase, name, phase: name)
        drainInbox()
        sampleBattery()
        Task { await ping() }
    }

    /// Battery monitoring is switched on only for the moment of the read (it keeps the radio-side bookkeeping running)
    /// and put back as it was found, so another subsystem that had it on keeps it. A charge-state change shows up as
    /// the difference from the previous sample.
    private func sampleBattery() {
        let d = UIDevice.current
        let wasEnabled = d.isBatteryMonitoringEnabled
        d.isBatteryMonitoringEnabled = true
        defer { d.isBatteryMonitoringEnabled = wasEnabled }
        guard d.batteryLevel >= 0 else { return }       // -1 = unknown (simulator): no sample, not a fake 0
        let charging = d.batteryState == .charging || d.batteryState == .full
        if let last = state.battery.last, last.charging != charging {
            add(.chargeState, charging ? "charging" : "not charging")
        }
        AppLifecycle.recordBattery(&state, .init(at: clock.now, level: Double(d.batteryLevel), charging: charging))
        save()
    }

    /// The debug ping: one POST, best effort; events go again until the PC answers 200.
    func ping() async {
        let snap = snapshot()
        let batch = AppLifecycle.nextBatch(state.events, after: sentUpToID)    // oldest first, at most 200
        let blob = AppLifecycle.StatusBlob(appVersion: AppBundle.version, sentAt: clock.now, scenePhase: phase,
                                           bleConnected: snap.ble, lastStrapFrameAt: snap.lastFrame,
                                           lastSyncAt: snap.lastSync, queueDepth: snap.queue, lastEvent: state.events.last,
                                           drain: AppLifecycle.drain(state.battery), events: batch, extras: extras())
        guard let body = try? MGJSON.encoder().encode(blob) else { return }
        let posted = await PCLabAppStatus.postWithReply(body, credentials: KeychainCredentialStore())
        if posted.ok {
            sentUpToID = batch.last?.id ?? sentUpToID                     // only through what was acknowledged
            let pending = RemoteDebug.pendingCommands(inStatusReply: posted.reply)
            if pending > 0 { onPendingCommands(pending) }                 // T10012: a phone that is not long-polling picks them up here
            if batch.count == AppLifecycle.batchLimit { Task { await ping() } }   // more waiting: send the next batch now
        }
    }
}
