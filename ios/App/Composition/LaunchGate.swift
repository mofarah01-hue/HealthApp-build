import Foundation
import UIKit
import UserNotifications
#if HEALTHKIT && canImport(HealthKit) && os(iOS)
import MGHealth
#endif

// R8o (audit §2.7, T23) — what iOS wants registered before launch finishes, without waiting for the database.
//
// Background task handlers (BGTaskScheduler) and the notification delegate must be set while the app is still launching, but
// the services they use are now built a moment later (the database opens off the main thread). So they are registered here,
// synchronously from MGApp.init, and each job waits on `LaunchGate` for the model (a few hundred milliseconds at most) when
// iOS runs it. The Bluetooth central is created at the same moment (StrapCoordinator.createEarlyTransportIfPaired).
//
// WRITTEN, NOT COMPILED.

/// Hands the model to work that started before it existed.
@MainActor
final class LaunchGate {
    static let shared = LaunchGate()

    private(set) var model: AppModel?
    private var failed = false
    private var waiters: [CheckedContinuation<AppModel?, Never>] = []

    func ready(_ model: AppModel) {
        self.model = model
        let pending = waiters
        waiters = []
        for w in pending { w.resume(returning: model) }
    }

    /// The database could not be opened: everything waiting gets nil and does nothing.
    func fail() {
        failed = true
        let pending = waiters
        waiters = []
        for w in pending { w.resume(returning: nil) }
    }

    func waitForModel() async -> AppModel? {
        if let model { return model }
        if failed { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

enum AppLaunch {
    /// BG task handlers, notification categories and delegate. Needs no service: each job asks the gate for the model.
    @MainActor
    static func registerHandlers() {
        let gate = LaunchGate.shared
        let healthRead: (@Sendable () async -> Void)?
        #if HEALTHKIT && canImport(HealthKit) && os(iOS)
        healthRead = {
            guard let model = await gate.waitForModel() else { return }
            await model.services.runHealthRead()
        }
        #else
        healthRead = nil
        #endif
        let work = BackgroundWork(
            sync: {
                guard let model = await gate.waitForModel() else { return }
                await model.wakeStrap("background task: sync")      // T9994: reconnect first if the link is down
                // Wave W11 (2026-10-11): the `.sync` BGTask pulls strap history first when the strap is connected.
                await model.backgroundHistoryPull()
                await model.services.syncCoordinator.backgroundRefreshTask()
                await model.wakeChainCheck(trigger: "background refresh")      // T10007: any refresh after the strap flag woke
            },
            rawUpload: {
                guard let model = await gate.waitForModel() else { return }
                await model.wakeStrap("background task: raw upload")   // T9994
                await model.services.syncCoordinator.rawUploadTask()
            },
            // T9995 (2026-10-17): the model decides (nothing while raw streams keep the app awake, else the PC runs last
            // night, else last night only on the phone).
            compute: {
                guard let model = await gate.waitForModel() else { return }
                await model.wakeStrap("background task: compute")   // T9994
                await model.backgroundComputeJob()
            },
            healthRead: healthRead)
        BackgroundTasks.register(work: work)
        HealthObserverLaunch.register(gate: gate)
        ReopenNoticeScheduler.install()      // Nov 5 2026: "closed from the app switcher" notice; the last run's is removed here
        NotifySystem.registerCategories()
        UNUserNotificationCenter.current().delegate = NotifySystem.delegate
        NotifySystem.delegate.onResponse = { response in
            guard let model = await gate.waitForModel() else { return }
            await model.handle(notification: response)
        }
    }
}

/// 0.6.0.7 (Oct 28 2026): the HealthKit observer queries, registered here at EVERY launch, background relaunches included,
/// before launch finishes (Apple's pattern for background delivery). R8o registered them only after the first screen and
/// never on a background relaunch, so iOS relaunched the app for a delivery with no observer waiting, the completion was
/// never called and iOS backed off: no heart rate reached the PC Oct 27-28 while the app stayed closed. Each callback
/// waits for the model, then runs only the light observed read (HealthAutoSync.runObserved); the provider calls the
/// completion when that returns or after its cap. Unlocking the phone reads the types that were locked.
@MainActor
enum HealthObserverLaunch {
    struct Record {
        var at: Date?
        var launchKind: String?
        var typeCount: Int?
    }

    /// This process's registration (for the remote debug status).
    private(set) static var record = Record()
    private(set) static var unlockRuns = 0
    /// Keeps the provider (and its HKHealthStore with the running queries) alive for the process.
    private static var provider: AnyObject?
    private static var unlockToken: NSObjectProtocol?

    static func register(gate: LaunchGate) {
        #if HEALTHKIT && canImport(HealthKit) && os(iOS)
        guard provider == nil else { return }
        let kind = UIApplication.shared.applicationState == .background ? "background relaunch" : "foreground launch"
        let p = HealthKitAutoProvider()
        provider = p
        let ids = p.startObserving { typeID in
            guard let model = await gate.waitForModel() else { return }
            await model.services.healthObserved(typeID)
        }
        record = Record(at: Date(), launchKind: kind, typeCount: ids.count)
        unlockToken = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                unlockRuns += 1
                guard let model = await gate.waitForModel() else { return }
                await model.services.healthAtUnlock()
            }
        }
        #endif
    }
}
