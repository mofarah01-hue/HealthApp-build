import SwiftUI
import MGContext

// WP-23a — the app's entry point (ARCHITECTURE D1: target MGApp, display name "MG"). R8o (audit §2.7, T23): launch no longer
// builds the service graph before the first frame. Synchronously here: the Bluetooth central (state restoration needs it
// early), the background task handlers and the notification delegate (iOS requires them before launch finishes). Then the
// first frame shows the saved last front page (or a skeleton) while the database opens off the main thread; the live model
// replaces it when it is ready. `mgapp://pair?…` links open the pairing sheet; the scene phase drives the foreground /
// background triggers (ARCHITECTURE §5.7).
//
// WRITTEN, NOT COMPILED.

@main
struct MGApp: App {
    @UIApplicationDelegateAdaptor(MGAppDelegate.self) private var appDelegate
    @StateObject private var holder: AppHolder
    @Environment(\.scenePhase) private var scenePhase

    init() {
        LaunchTimer.mark()
        SignalCoreSelection.install()
        StrapCoordinator.createEarlyTransportIfPaired()   // BLE state restoration: the central must exist at launch
        Whoop4Coordinator.createEarlyTransportIfSelected()  // WHOOP4-LINK: same, only when the 4.0 is the selected device
        AppLaunch.registerHandlers()                       // BG tasks + notification delegate: before launch finishes
        let holder = AppHolder()
        _holder = StateObject(wrappedValue: holder)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch holder.state {
                case .starting(let preview):
                    StartupView(preview: preview)
                case .ready(let model):
                    RootView(model: model)
                        .onOpenURL { url in model.handle(url: url) }
                case .failed(let reason):
                    RootFailureView(reason: reason)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard case .ready(let model) = holder.state else { return }
            switch phase {
            case .active: Task { await model.scenePhaseChanged(active: true) }
            case .background: Task { await model.scenePhaseChanged(active: false) }
            case .inactive: model.lifecycle.phaseChanged("inactive")
            @unknown default: break
            }
        }
    }
}

/// Hup2 (Nov 6 2026): iOS wakes the app for a finished background transfer and hands over a completion handler
/// (`handleEventsForBackgroundURLSession`); it must be called once the session has delivered its events
/// (`BackgroundUploadTransport.eventsCompletion`, wired in AppWiring). The two can arrive in either order, so whichever comes
/// second makes the call. Main queue only.
final class MGAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundSessionEvents.setHandler(completionHandler)
    }
}

enum BackgroundSessionEvents {
    nonisolated(unsafe) private static var handler: (() -> Void)?
    nonisolated(unsafe) private static var eventsDone = false

    static func setHandler(_ h: @escaping () -> Void) {
        DispatchQueue.main.async {
            if eventsDone { eventsDone = false; h() } else { handler = h }
        }
    }

    /// The session has delivered everything queued for it.
    static func eventsFinished() {
        DispatchQueue.main.async {
            if let h = handler { handler = nil; h() } else { eventsDone = true }
        }
    }
}

/// Holds the composition root for the scene's lifetime.
@MainActor
final class AppHolder: ObservableObject {
    enum State {
        /// The database is opening; the saved front page (nil on a background relaunch or when none is fresh).
        case starting(LaunchPreview?)
        case ready(AppModel)
        case failed(String)
    }

    @Published private(set) var state: State

    init() {
        // `.background` only: a normal launch is `.inactive` until the scene is active.
        let background = UIApplication.shared.applicationState == .background
        state = .starting(background ? nil : LaunchPreviewFile.load(now: Date()))
        Task { @MainActor [weak self] in await self?.bootstrap(background: background) }
    }

    private func bootstrap(background: Bool) async {
        switch await AppServices.openStore() {
        case .failure(let failure):
            LaunchGate.shared.fail()
            state = .failed(failure.description)
        case .success(let store):
            LaunchTimer.reached(.dbOpen)
            let services = AppServices.make(store: store)
            let model = AppModel(services: services)
            LaunchTimer.reached(.servicesReady)
            LaunchGate.shared.ready(model)
            state = .ready(model)
            model.logLaunchStages(background: background)
            // Wave W11 (2026-10-11): start now, not when the window first shows. A CoreBluetooth state-restoration or BGTask
            // relaunch happens in the background with no window. R8o: such a relaunch starts only the strap link and ingest
            // (AppModel.start(background:)); RootView's `.task` start() then does the rest the first time the app opens.
            await model.start(background: background)
        }
    }
}
