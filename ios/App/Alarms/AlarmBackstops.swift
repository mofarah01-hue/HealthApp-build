import Foundation
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

// The iPhone side of Mo's strap alarms (added 2026-10-11): one fixed-time alarm per occurrence that has a `backstopAt`
// (the Fajr wake at its latest time + 3 min, timers and custom alarms just after theirs). They are scheduled days ahead,
// so they ring even when the app is dead — the safe failure — and are cancelled only on awake evidence ("I'm up",
// walking, heart rate + movement) or a Stop for a timer / plain alarm. AlarmKit (iOS 26+) rings through Silent and
// Focus; without it (or refused) a time-sensitive notification with sound stands in, repeated each minute 4 times.
// AlarmKit here is Stop-only, like the smart wake's (a snooze button needs a widget extension — xtool #313/#145).

@MainActor
final class AlarmBackstops {
    enum Kind: String, Codable, Sendable {
        case alarmKit, notification
    }

    /// What one scheduled backstop is, for cancelling after an app restart.
    struct Scheduled: Codable, Equatable, Sendable {
        var occurrenceId: String
        var at: Date
        var kind: Kind
        var ids: [String]
    }

    private let center = UNUserNotificationCenter.current()
    /// Wave W11 (2026-10-11): AlarmKit's last refusal in its own words (type, domain, code, text) and when; nil after an
    /// AlarmKit alarm was scheduled. A refusal no longer drops the backstop: that alarm goes to the notification layer.
    private(set) var alarmKitProblem: String?
    private(set) var alarmKitProblemAt: Date?
    /// The notification layer's last failure (then nothing is armed on the iPhone for that alarm).
    private(set) var notificationProblem: String?

    /// AlarmKit when the SDK, the OS and Mo allow it; asks once. A "no" is kept as the AlarmKit reason.
    func preferredKind() async -> Kind {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return .alarmKit
            case .denied:
                noteAlarmKit("not allowed (iOS Settings › MG › Alarms)")
                return .notification
            case .notDetermined:
                let state = try? await AlarmManager.shared.requestAuthorization()
                if state == .authorized { return .alarmKit }
                noteAlarmKit("not allowed when asked")
                return .notification
            @unknown default: return .notification
            }
        }
        #endif
        return .notification
    }

    /// AlarmKit first; when it refuses (or is not allowed), a time-sensitive notification series for the same alarm.
    /// nil only when the notification layer failed too (`notificationProblem` says why).
    func schedule(occurrenceId: String, at: Date, title: String) async -> Scheduled? {
        if await preferredKind() == .alarmKit {
            #if canImport(AlarmKit)
            if #available(iOS 26.0, *) {
                do {
                    let id = try await scheduleAlarmKit(at: at, title: title)
                    alarmKitProblem = nil
                    alarmKitProblemAt = nil
                    return Scheduled(occurrenceId: occurrenceId, at: at, kind: .alarmKit, ids: [id])
                } catch {
                    noteAlarmKit(Self.words(error))
                }
            }
            #endif
        }
        do {
            let ids = try await scheduleNotifications(occurrenceId: occurrenceId, at: at, title: title)
            notificationProblem = nil
            return Scheduled(occurrenceId: occurrenceId, at: at, kind: .notification, ids: ids)
        } catch {
            notificationProblem = Self.words(error)
            return nil
        }
    }

    /// One immediate notification for Settings > Tests. nil means iOS accepted the request.
    func scheduleTestAlert() async -> String? {
        do {
            try await prepareNotifications()
            let content = UNMutableNotificationContent()
            content.title = "Alarm test"
            content.body = "The iPhone alarm alert works."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            // The app's notification delegate presents alarm-priority requests even while Settings is in front.
            content.userInfo[NotifyKey.kind] = NotifyKind.smartWakeRing.rawValue
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: "alarms.test.\(UUID().uuidString)", content: content,
                                                trigger: trigger)
            try await center.add(request)
            return nil
        } catch {
            return Self.words(error)
        }
    }

    private func noteAlarmKit(_ why: String) {
        if why != alarmKitProblem { alarmKitProblemAt = Date() }
        alarmKitProblem = why
    }

    /// The error as the framework gave it: its case / description plus domain and code (Mo saw only "a widget error").
    static func words(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "HealthApp.alarms" { return ns.localizedDescription }
        let described = String(describing: error)
        let code = " [\(ns.domain) \(ns.code)]"
        if described.hasPrefix("Error Domain=") || described == ns.localizedDescription {
            return ns.localizedDescription + code
        }
        return "\(described) — \(ns.localizedDescription)" + code
    }

    func cancel(_ s: Scheduled) async {
        switch s.kind {
        case .alarmKit:
            #if canImport(AlarmKit)
            if #available(iOS 26.0, *) {
                for raw in s.ids {
                    guard let id = UUID(uuidString: raw) else { continue }
                    try? AlarmManager.shared.stop(id: id)     // silences one that is ringing
                    try? AlarmManager.shared.cancel(id: id)   // removes one still scheduled
                }
            }
            #endif
        case .notification:
            center.removePendingNotificationRequests(withIdentifiers: s.ids)
            center.removeDeliveredNotifications(withIdentifiers: s.ids)
        }
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private func scheduleAlarmKit(at date: Date, title: String) async throws -> String {
        let id = UUID()
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop)
        let attributes = AlarmAttributes<SmartWakeAlarmMetadata>(presentation: AlarmPresentation(alert: alert),
                                                                 metadata: SmartWakeAlarmMetadata(),
                                                                 tintColor: Color(red: 0.118, green: 0.580, blue: 0.400))
        let configuration = AlarmManager.AlarmConfiguration<SmartWakeAlarmMetadata>(
            countdownDuration: nil, schedule: .fixed(date), attributes: attributes, stopIntent: nil,
            secondaryIntent: nil)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        return id.uuidString
    }
    #endif

    private func scheduleNotifications(occurrenceId: String, at: Date, title: String) async throws -> [String] {
        try await prepareNotifications()
        var ids: [String] = []
        let stamp = Int64(at.timeIntervalSince1970)
        for k in 0..<5 {
            let fireAt = at.addingTimeInterval(Double(k) * 60)
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = k == 0 ? "Your strap alarm's iPhone backstop." : "Still ringing — open the app and tap I'm up."
            content.sound = .default           // critical alerts need an entitlement a free account cannot sign
            content.interruptionLevel = .timeSensitive
            let id = "alarms.backstop.\(occurrenceId).\(stamp).\(k)"
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireAt.timeIntervalSinceNow), repeats: false)
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            ids.append(id)
        }
        return ids
    }

    private func prepareNotifications() async throws {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        if await center.notificationSettings().authorizationStatus == .denied {
            throw NSError(domain: "HealthApp.alarms", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "notifications are off for MG (iOS Settings › MG › Notifications)"])
        }
    }
}
