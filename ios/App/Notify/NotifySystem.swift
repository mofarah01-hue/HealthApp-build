import Foundation
import UserNotifications

// WP-24 — the thin layer over UserNotifications: category registration, posting, the delegate.
// iOS has ONE category set (`setNotificationCategories` replaces it) and ONE delegate per app: both are set here only.
// WP-23 at launch (before `application(_:didFinishLaunchingWithOptions:)` returns, i.e. in MGApp.init):
//     NotifySystem.registerCategories()
//     UNUserNotificationCenter.current().delegate = NotifySystem.delegate
//     NotifySystem.delegate.onResponse = { response in await appModel.handle(response) }
// and asks for permission at a moment that explains itself (e.g. after pairing): `await NotifySystem.requestAuthorization()`.

enum NotifySystem {
    static let delegate = NotifyDelegate()

    static func registerCategories(center: UNUserNotificationCenter = .current()) {
        let categories = NotifyCategories.all.map { spec -> UNNotificationCategory in
            let actions = spec.actions.map { a -> UNNotificationAction in
                var options: UNNotificationActionOptions = []
                if a.opensApp { options.insert(.foreground) }
                if a.destructive { options.insert(.destructive) }
                return UNNotificationAction(identifier: a.id.rawValue, title: a.title, options: options)
            }
            return UNNotificationCategory(identifier: spec.id.rawValue, actions: actions, intentIdentifiers: [],
                                          options: [])
        }
        center.setNotificationCategories(Set(categories))
    }

    /// Alerts, sounds and badges. Returns whether Mo allowed them.
    static func requestAuthorization(center: UNUserNotificationCenter = .current()) async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func isAuthorized(center: UNUserNotificationCenter = .current()) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    static func makeContent(_ spec: NotifyContentSpec) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = spec.title
        if let subtitle = spec.subtitle { c.subtitle = subtitle }
        c.body = spec.body
        c.categoryIdentifier = spec.category.rawValue
        c.threadIdentifier = spec.threadId
        c.userInfo = spec.userInfo
        switch spec.sound {
        case .none: c.sound = nil
        case .standard: c.sound = .default
        case .ringtone: c.sound = .defaultRingtone
        }
        switch spec.level {
        case .passive: c.interruptionLevel = .passive
        case .active: c.interruptionLevel = .active
        case .timeSensitive: c.interruptionLevel = .timeSensitive
        }
        return c
    }

    /// Posts now (`at` nil or not in the future) or at an absolute time. Same id → replaces.
    static func post(_ spec: NotifyContentSpec, id: String, at: Date?,
                     center: UNUserNotificationCenter = .current()) async throws {
        var trigger: UNNotificationTrigger?
        if let at {
            let wait = at.timeIntervalSinceNow
            if wait >= 1 { trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false) }
        }
        let request = UNNotificationRequest(identifier: id, content: makeContent(spec), trigger: trigger)
        try await center.add(request)
    }
}

/// `NotifyPosting` over the real notification centre.
struct NotifySystemPoster: NotifyPosting {
    func post(_ spec: NotifyContentSpec, id: String, at: Date?) async throws {
        try await NotifySystem.post(spec, id: id, at: at)
    }

    func remove(ids: [String]) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// The app's only UNUserNotificationCenterDelegate.
final class NotifyDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Set by WP-23. Called for every tap / button; the completion is held until it returns, so an answer is stored
    /// before iOS suspends the app.
    var onResponse: (@Sendable (NotifyResponse) async -> Void)?

    /// iOS calls this only while the app is in front. Questions then show as peeks, not banners (UX §5:
    /// notifications "only when the app is closed").
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let kind = (notification.request.content.userInfo[NotifyKey.kind] as? String).flatMap(NotifyKind.init(rawValue:))
        completionHandler(NotifyDelegate.foregroundOptions(kind))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        var action = response.actionIdentifier
        if action == UNNotificationDefaultActionIdentifier { action = NotifyActionID.tap.rawValue }
        var info: [String: String] = [:]
        for (k, v) in content.userInfo {
            if let key = k as? String, let value = v as? String { info[key] = value }
        }
        let mapped = NotifyResponseMap.response(category: content.categoryIdentifier, action: action, userInfo: info)
        guard let handler = onResponse else {
            completionHandler()
            return
        }
        Task {
            await handler(mapped)
            completionHandler()
        }
    }

    /// While the app is in front: the alarm rings and alerts show; questions and the Tailscale reminder stay quiet
    /// (the peek and the "data waiting" card show them); receipts only go to the list.
    static func foregroundOptions(_ kind: NotifyKind?) -> UNNotificationPresentationOptions {
        // T57: the reminders Mo set up (dose, caffeine cut-off, wind-down) have no peek or card in the app: show them.
        if let kind, [.medReminder, .caffeineLimit, .windDown].contains(kind) { return [.banner, .list] }
        switch kind?.priority {
        case .alarm?: return [.banner, .sound, .list]
        case .alert?: return [.banner, .list]
        case .info?: return kind == .syncReceipt ? [.list] : []
        case .prompt?, .silent?, nil: return []
        }
    }
}
