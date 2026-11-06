import Foundation
import MGBLE
import MGContext
import MGDomain
import MGHealth
import MGSignal
import MGStore
import MGSync
import UserNotifications
#if canImport(MGCoreRust)
import MGCoreRust
#endif

// WP-23a — the service graph (ARCHITECTURE §4.2: every port wired). R8o (audit §2.7): the database is opened and migrated
// off the main thread (`openStore`), the graph is built on the main actor right after (`make(store:)`), and the pieces iOS
// needs before launch finishes (background task handlers, notification delegate, the Bluetooth central) are registered
// synchronously in MGApp.init by LaunchGate.swift, so they no longer wait for the database:
//   MGStore (Application Support/MG/mg.sqlite; the only way to open the DB, BRIEF WP-05 row)
//   SyncEngine (MGStore conformances, Keychain credentials, ledger in kv, SAMPLE blocks sync) + WP-24's
//     BackgroundSyncCoordinator (every §5.7 trigger) and NotifyCenter (MGSync's notifier)
//   HealthReader / HealthMirror (mirror off by default, D12), NightSounds (WP-26), ComputeCoordinator (WP-22 hook)
//   StrapCoordinator (MGBLE, StrapPolicy.b1) — the link itself is built once the install salt is read.
//
// WRITTEN, NOT COMPILED.

/// Selects the signal core once (ARCHITECTURE §7.4; WP-20): Rust when `project-rust.yml` links MGCoreRust (any non-zero
/// Rust status falls back to the Swift answer), else Swift.
enum SignalCoreSelection {
    static func install() {
        #if canImport(MGCoreRust)
        Signal.core = RustSignalCore(fallback: SwiftSignalCore())
        #else
        Signal.core = SwiftSignalCore()
        #endif
    }
}

/// Bundle facts the composition needs (never machine-specific: all from Info.plist at run time, R7).
enum AppBundle {
    /// "0.1.0 (1)".
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static var bundleId: String { Bundle.main.bundleIdentifier ?? "mgapp" }

    /// The un-suffixed bundle id (`$(BUNDLE_ID_PREFIX).mgapp`, D1): sideload tools append a suffix after `mgapp`, so
    /// everything up to and including the `mgapp` component (BRIEF WP-14 row: `OwnSourceRule.familyBundleId`).
    static var familyBundleId: String? {
        let parts = bundleId.split(separator: ".")
        guard let i = parts.lastIndex(where: { $0.lowercased() == "mgapp" }) else { return nil }
        return parts[...i].joined(separator: ".")
    }

    static var deviceName: String { "MG app" }
}

/// Lets services built before the model call back into it.
@MainActor
final class ModelLink {
    weak var model: AppModel?
}

/// The raw-upload gate for MGSync (#74, 2026-10-11): the engine is built before the coordinator that watches the
/// network, so it asks through this. No coordinator yet = the network state isn't known: raw waits.
final class RawGateRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _coordinator: BackgroundSyncCoordinator?

    var coordinator: BackgroundSyncCoordinator? {
        get { lock.lock(); defer { lock.unlock() }; return _coordinator }
        set { lock.lock(); _coordinator = newValue; lock.unlock() }
    }

    func decision() async -> RawUploadPolicy.Decision {
        guard let c = coordinator else { return RawUploadPolicy.decide(nil) }
        return await c.rawDecision()
    }
}

@MainActor
final class AppServices {
    let store: MGStore
    let calendar: Calendar
    let clock: any MGDomain.Clock
    let live: ContextLiveBox
    let storeSource: StoreDayDataSource
    let sampleSource: SampleDayDataSource
    let kv: AppSettingsStore
    let notifyCenter: NotifyCenter
    let sync: SyncEngine
    let syncCoordinator: BackgroundSyncCoordinator
    let compute: ComputeCoordinator
    let health: HealthReader?
    /// T9739: reads every Health type it may and sends new samples to the PC on its own (nil without HEALTHKIT).
    let healthAuto: HealthAutoSync?
    let mirror: HealthMirror?
    let nightSounds: NightSoundsController
    let strap: StrapCoordinator
    /// WHOOP4-LINK (D-WHOOP4-LINK-1): the WHOOP 4.0 link, next to the 5/MG one; Settings picks which of the two runs.
    let whoop4: Whoop4Coordinator
    let intents: IntentsDrainer?
    let link: ModelLink
    let unlockPresenter: UnlockConfirmPresenter
    let pairing: PairingController

    /// The store failed to open: the app shows why instead of crashing.
    struct OpenFailure: Error, CustomStringConvertible {
        var description: String
    }

    /// R8o: opens the database file and runs the migrations on a background thread, so the first frame is not behind them.
    /// The store is a thread-safe pool; nothing else is touched here.
    nonisolated static func openStore() async -> Result<MGStore, OpenFailure> {
        await Task.detached(priority: .userInitiated) { () -> Result<MGStore, OpenFailure> in
            do {
                let store = try MGStore(url: try MGStore.defaultURL(), clock: SystemClock(),
                                        calendar: Calendar.autoupdatingCurrent, appVersion: AppBundle.version)
                return .success(store)
            } catch {
                return .failure(OpenFailure(description: "The app's database couldn't be opened: \(error)"))
            }
        }.value
    }

    /// Builds the service graph around an open store (main actor; objects only, no database work).
    static func make(store: MGStore) -> AppServices {
        AppServices(store: store, calendar: Calendar.autoupdatingCurrent, clock: SystemClock())
    }

    private init(store: MGStore, calendar: Calendar, clock: any MGDomain.Clock) {
        self.store = store
        self.calendar = calendar
        self.clock = clock
        let live = ContextLiveBox()
        self.live = live
        let link = ModelLink()
        self.link = link
        storeSource = StoreDayDataSource(store: store, live: live, calendar: calendar)
        sampleSource = SampleDayDataSource(live: live, calendar: calendar)
        kv = AppSettingsStore(store: store)

        // Notifications (WP-24): one centre, also MGSync's notifier (it batches the receipts).
        let center = NotifyCenter(poster: NotifySystemPoster(), clock: clock, calendar: calendar,
                                  onPosted: { [weak link] kind in   // T53: notification buzz by app
                                      await link?.model?.buzzForNotification(source: "mg." + kind.rawValue, person: nil)
                                  })
        notifyCenter = center

        // Sync (WP-14): SAMPLE mode blocks it (§4.12) — the engine asks the live box before every run.
        let gate = RawGateRef()
        // T83: file uploads (PUT) go through a background URLSession so they finish after the app is suspended.
        let uploads = BackgroundUploadTransport(
            configuration: BackgroundUploadTransport.appConfiguration(
                identifier: (Bundle.main.bundleIdentifier ?? "mgapp") + ".upload"),
            fallback: URLSessionPCLabTransport(),
            // Nov 5 2026: Apple Health bodies also go through the background session (they finish after the wake ends)
            backgroundPostPaths: ["/v1/health-samples"])
        uploads.eventsCompletion = { BackgroundSessionEvents.eventsFinished() }    // Hup2: handleEventsForBackgroundURLSession
        // 2026-11-05: a name that does not resolve (tunnel not up in a background wake) is retried on the PC's 100.x address.
        let engine = SyncEngine(transport: AddressFallbackTransport(inner: uploads, credentials: KeychainCredentialStore()),
                                credentials: KeychainCredentialStore(),
                                days: store, streams: store, outbox: store, results: store, notifier: center,
                                clock: clock, strapIds: store, raw: store,
                                isSampleMode: { await live.sampleData }, ledger: StoreKV.syncLedger(store),
                                calendar: calendar, appVersion: AppBundle.version,
                                // wave 2: Settings › Profile goes to the PC when it changes (MS-01..04, PhenoAge age);
                                // since tracker #42 (2026-10-11) with the medications list = the schedules (v0.5)
                                profile: {
                                    var p = ((try? await store.profile()) ?? nil) ?? Profile()
                                    let appSettings = await live.get().settings
                                    let meds = appSettings.schedules
                                    p.medications = meds.isEmpty ? nil : meds
                                    p.fitzpatrickSkinType = appSettings.fitzpatrickSkinType
                                    p.vitaminDLocation = appSettings.vitaminDLocation
                                    // T9918: the newest tape sizes go with the profile (not stored in it)
                                    let sizes = ProfileSizes.latest(from: (try? await store.events(ofTypes: [.scan])) ?? [], calendar: calendar)
                                    p.bodySizes = sizes.isEmpty ? nil : sizes
                                    return p
                                },
                                progress: { [weak link] p in await link?.model?.syncProgress(p) },
                                // #74 (2026-10-11): raw goes with every sync on any connection outside Low Data Mode
                                rawGate: { [gate] in await gate.decision() },
                                // round 8: a results cursor restart / missing bundle route goes to Settings > Usage > Compute log
                                log: { ComputeLog.shared.append(.note, "sync: " + $0, at: Date()) })
        sync = engine
        // 0.6.0.10: Watch recordings (.mgw) arrive by WatchConnectivity and go to PC Lab. Activated here, at launch,
        // because queued files are delivered only to an activated session (watch/INTEGRATION.md).
        WatchReceiver.shared.upload = { name, data, sha in
            try await engine.uploadWatchFile(name: name, data: data, sha256: sha)
        }
        WatchReceiver.shared.log = { ComputeLog.shared.append(.note, "watch: " + $0, at: Date()) }
        WatchReceiver.shared.activate()
        // After every sync: delete what the PC has confirmed and the phone has kept 30 days, and the stored copies of
        // drops delivered 30 days ago (2026-10-11, Mo; MGStore `pruneConfirmed` — unconfirmed data is never deleted).
        // Not in SAMPLE mode: nothing is written then (§4.12).
        let coordinator = BackgroundSyncCoordinator(sync: { t, b in
                                                        let outcome = await engine.sync(t, budget: b)
                                                        WatchReceiver.shared.uploadInbox()   // 0.6.0.10: after each sync
                                                        if !(await live.sampleData) { _ = await store.pruneConfirmed(maxBatches: 20) }   // r8: bounded, light
                                                        return outcome
                                                    },
                                                    status: { await engine.status }, notify: center, clock: clock)
        syncCoordinator = coordinator
        gate.coordinator = coordinator

        // Compute (WP-22 behind ComputeRunning; the default computes nothing and says so).
        compute = ComputeCoordinator(
            runner: ComputeRunners.current(store: store, clock: clock), calendar: calendar, clock: clock,
            isSample: { await live.sampleData },
            settings: {
                let l = await live.get()
                let profile = ((try? await store.effectiveProfile()) ?? nil) ?? Profile()   // P9745: Me + PC
                return l.settings.computeSettings(profile: profile, timeZone: calendar.timeZone)
            },
            onDone: { [weak link] report in await link?.model?.computeFinished(report) },
            progress: { [weak link] reason, days in await link?.model?.computeProgress(reason, days: days) },
            backgroundOnBattery: { [weak link] in await link?.model?.computeBackgroundOnBattery() ?? false },
            inBackground: { [weak link] in await link?.model?.computeInBackground() ?? false },
            build: AppBundle.version)

        // Apple Health (WP-14): read with the own-source rule; the mirror stays off (D12, no Settings row in B1).
        // HEALTHKIT is defined only for a paid Apple Developer account (xtool Package.swift swiftSettings): a free
        // account cannot sign the HealthKit entitlement, so Health goes through Shortcuts instead (2026-10-11).
        #if HEALTHKIT && canImport(HealthKit) && os(iOS)
        let own = OwnSourceRule(bundleId: AppBundle.bundleId, familyBundleId: AppBundle.familyBundleId)
        health = HealthReader(provider: HealthKitProvider(), sink: store, removal: StoreHealthRemoval(store: store),
                              own: own, clock: clock)
        mirror = HealthMirror(source: StoreMirrorSource(store: store), writer: HealthKitMirrorWriter(),
                              settings: MirrorSwitch(live: live), state: StoreKV.mirrorState(store),
                              device: { MirrorDevice(firmwareVersion: nil, softwareVersion: AppBundle.version) },
                              clock: clock, calendar: calendar)
        let autoProvider = HealthKitAutoProvider()
        let auto = HealthAutoSync(provider: autoProvider, storage: StoreKV.healthAuto(store), queue: StoreKV.healthQueue(store),
                                  uploader: PCHealthUploader(transport: AddressFallbackTransport(
                                      inner: uploads, credentials: KeychainCredentialStore()),
                                      inFlight: { await uploads.inFlightDescriptions() }),
                                  clock: clock, timeZone: { calendar.timeZone },
                                  enabled: { !(await live.sampleData) })
        healthAuto = auto
        // Hup2: the PC's answer to an upload nobody waited for (detached at the run's limit, or after a relaunch) still counts:
        // 200/201 records the batches as sent and removes them. Answers that came before this line are held and delivered here.
        uploads.onLateCompletion = { description, status in
            guard status == 200 || status == 201 else { return }
            let keys = HealthAutoPayload.keys(inTaskDescription: description)
            if !keys.isEmpty { Task { await auto.recordAccepted(keys: keys) } }
        }
        // 0.6.0.7: the observer queries are registered at every launch in MGApp.init (HealthObserverLaunch, LaunchGate.swift)
        // and call `healthObserved`; was R8o's `startHealthObservers()` after the first screen, never on a background relaunch.
        #else
        health = nil
        mirror = nil
        healthAuto = nil
        #endif

        // Night sounds (WP-26): opt-in per night; audio never leaves the phone and no clip store is given, so no
        // audio is ever written to disk.
        nightSounds = NightSoundsController(listener: NightSoundsListener(clock: clock),
                                            sink: StoreNightSoundsSink(store: store, live: live),
                                            sessions: NightSoundsFileSessionLog.standard(), clock: clock)

        // Strap (WP-04 + WP-13's confirm sheet as the StrapWriteConfirmer).
        let confirmer = UnlockConfirmPresenter()
        unlockPresenter = confirmer
        let strapCoordinator = StrapCoordinator(store: store, clock: clock, confirmer: confirmer)
        strap = strapCoordinator
        whoop4 = Whoop4Coordinator(store: store, clock: clock)

        // PC pairing (WP-13's controller → SyncEngine.pair; refuses non-Tailscale hosts, BRIEF WP-14 row).
        pairing = PairingController(pair: { payload in
            try await engine.pair(payload, deviceName: AppBundle.deviceName)
        })

        // App Intents / widgets queue (WP-24): applied through the same save path as the Log.
        let drainer = IntentsQueue.shared.map { queue in
            IntentsDrainer(queue: queue, handler: IntentsAppHandler(hooks: IntentsAppHooks(
                isSampleMode: { await live.sampleData },
                save: { event in _ = try await EventSaving.save(event, now: clock.now, store: store) },
                recentEvents: { from, to in try await store.events(from: from, to: to) },
                startNap: { [weak link] minutes, at in await link?.model?.startNap(minutes: minutes, at: at) ?? false },
                syncNow: { await coordinator.syncNow() })))
        }
        intents = drainer

        // Every stored property is set: calls on them may start now.
        if let drainer {
            IntentsRuntime.shared.install(drainer: drainer, syncNow: { await coordinator.syncNow() })
        }
        if StrapCoordinator.wasPaired { strapCoordinator.prepareTransport() }   // BLE state restoration: central early
    }

    /// 0.6.0.7: an observer callback (HealthObserverLaunch): the changed type's newest samples to the PC, kept short.
    /// Nov 5 2026: returns (so HealthKit's completion handler is called) once the samples are queued and the cursor is saved on
    /// the phone, never waiting for the PC. The pass goes on in its own Task: the upload is a background URLSession transfer
    /// (PCHealthUploader), so the PC still gets it after the wake ends; what does not finish is sent at the next wake.
    func healthObserved(_ typeID: String) async {
        guard let auto = healthAuto else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(cont)
            Task {
                _ = await auto.runObserved(typeIDs: [typeID], afterLocal: { once.resume() })
                once.resume()                      // runObserved always calls afterLocal; this only guards a future early exit
                await HealthQueueNote.record(auto, context: "Health observer", at: Date())
            }
        }
    }

    /// 0.6.0.7: the phone was unlocked: the types an observer found locked are read now.
    func healthAtUnlock() async {
        guard let auto = healthAuto else { return }
        _ = await auto.runAtUnlock()
        await HealthQueueNote.record(auto, context: "unlock", at: Date())
    }

    /// The hourly Health task's work (was a closure built in `registerAtLaunch`).
    func runHealthRead() async {
        guard let reader = health else { return }
        _ = await reader.sync()
        if let auto = healthAuto {
            _ = await auto.run(trigger: .automatic)          // T9739: new Health samples to the PC in the hourly refresh too
            await HealthQueueNote.record(auto, context: "hourly refresh", at: Date())      // r9u
        }
    }
}

/// Resumes a continuation exactly once, from whichever caller gets there first.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?

    init(_ cont: CheckedContinuation<Void, Never>) { self.cont = cont }

    func resume() {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume()
    }
}

/// Which compute runner this build has: WP-22's night pipeline over MGStore (PipelineWiring.swift).
/// `PipelinesNotBuiltRunner` (CompositionHooks.swift) stays as the fallback to switch back to.
enum ComputeRunners {
    static func current(store: MGStore, clock: any MGDomain.Clock) -> any ComputeRunning {
        StorePipelineRunner(store: store, clock: clock)
    }
}
