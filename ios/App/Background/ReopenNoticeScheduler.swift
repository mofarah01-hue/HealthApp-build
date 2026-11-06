import Foundation
import MGBLE
import MGContext
import UIKit
import UserNotifications

// Nov 5 2026 — "HealthApp was closed — open it again so Apple Health and your strap keep syncing".
//
// Closing the app from the app switcher stops every background launch until the app is opened again (Apple: as designed; no
// override). WHOOP's own app sends a notification then. This schedules ours. Wording and the limits: `ReopenNotice` (MGContext,
// tested). Short version of the limits: iOS calls willTerminate only for an app that is running, not for one suspended in the
// background, so a plain swipe-away of a suspended app may send nothing; a scene that disconnects while the app is in the
// background is treated as closed too, which can be a false alarm when iOS only drops the scene to save memory.
//
// WRITTEN, NOT COMPILED (no Mac in the loop). Device check: close the app from the switcher with the screen on, then lock;
// the notice should arrive within seconds; open the app and it must disappear.

@MainActor
enum ReopenNoticeScheduler {
    private static var tokens: [NSObjectProtocol] = []

    /// From `AppLaunch.registerHandlers` (every launch, before the model exists). Also removes the notice of the last run.
    static func install() {
        guard tokens.isEmpty else { return }
        cancel()
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { schedule() }
        })
        tokens.append(nc.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if UIApplication.shared.applicationState == .background { schedule() } }
        })
        tokens.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { cancel() }
        })
    }

    /// Hands the request to iOS now and waits up to a second for it to be accepted (the process is ending).
    static func schedule() {
        if LaunchGate.shared.model?.isSample == true { return }      // sample data: nothing is syncing
        let content = UNMutableNotificationContent()
        content.title = ReopenNotice.title
        content.body = ReopenNotice.body(
            appName: NotifyApp.name,
            strapName: ReopenNotice.strapName(whoop4Chosen: StrapDeviceChoice.stored == .whoop4, mgPaired: StrapCoordinator.wasPaired))
        content.threadIdentifier = ReopenNotice.threadIdentifier
        content.sound = .default
        content.interruptionLevel = .timeSensitive      // iOS delivers it as active where the entitlement is missing
        let request = UNNotificationRequest(
            identifier: ReopenNotice.identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: ReopenNotice.delay, repeats: false))
        let accepted = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { _ in accepted.signal() }
        _ = accepted.wait(timeout: .now() + 1.0)
    }

    static func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [ReopenNotice.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [ReopenNotice.identifier])
    }
}
