import Foundation
import MGContext
import UserNotifications

// T9992 (r9d, 2026-10-17) — iOS never relaunches an app the user swiped away, so a raw night can have a hole where the app was
// gone. The strap keeps its own copy of what it recorded, and it comes with the next history download. When the app comes back
// after such a gap while a raw stream was wanted, say so once: a local notification (and the in-app notice when the app is
// open). Wording and rules: `AppLifecycle.gapNoticeWords` (MGContext, tested).

extension AppModel {
    func gapNotice(_ launch: AppLifecycle.Launch) {
        let rawWanted = !isSample && (settings.rawOpticalOn || settings.rawMotionOn)
        guard let words = AppLifecycle.gapNoticeWords(launch: launch, rawWanted: rawWanted, now: clock.now, calendar: calendar) else {
            return
        }
        ComputeLog.shared.append(.note, "gap notice: " + words, at: clock.now)
        if appActive { showNotice(words) }
        Task {
            guard await NotifySystem.isAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = "Raw data gap"
            content.body = words
            content.threadIdentifier = "mg.rawGap"
            content.interruptionLevel = .passive
            let request = UNNotificationRequest(identifier: "mg.rawGapNotice", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
