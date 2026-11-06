import Foundation
import MGContext
import MGSignal
import UserNotifications
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

/// How smart wake makes a sound on the iPhone (the strap buzz / slot-1 alarm for the same wake is App/Alarms since
/// CLAUDE.md rule 5 changed on 2026-10-11; before, 66–69 were forbidden in
/// MGBLE). iOS 26+: AlarmKit (rings through Silent and Focus). Older iOS or AlarmKit refused: a time-sensitive
/// notification with sound, repeated each minute until Stop — which may not wake Mo on Silent (the Tonight sheet says
/// so). Notification categories and the delegate belong to WP-24 (App/Notify); STOP / SNOOZE_9 come back through it
/// as `SmartWakeControlling.stop()` / `snooze(minutes:)`.
@MainActor
public protocol SmartWakeRinging: AnyObject {
    var kind: SmartWakeBlockState.Ringer { get }
    /// Asks once (AlarmKit authorization / notification permission). false → this ringer cannot ring.
    func authorize() async -> Bool
    /// The backstop at L, scheduled at arming so it rings even if the app is killed. Returns the ids to cancel later.
    func scheduleBackstop(plan: SmartWakePlan) async throws -> [String]
    /// Ring as soon as possible (the fire rule rang). Returns ids.
    func ringNow(plan: SmartWakePlan, outcome: SmartWakeOutcome) async throws -> [String]
    /// Ring again in `minutes` (notification SNOOZE_9). Returns ids.
    func snooze(minutes: Int, plan: SmartWakePlan) async throws -> [String]
    /// Cancel scheduled rings that have not fired and silence ones that are ringing.
    func cancel(ids: [String]) async
}

@MainActor
public enum SmartWakeRingers {
    /// AlarmKit when the SDK and the OS have it and Mo allows it; otherwise notifications.
    public static func make(config: SmartWakeConfig = .standard) async -> any SmartWakeRinging {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let alarm = SmartWakeAlarmKitRinger()
            if await alarm.authorize() { return alarm }
        }
        #endif
        return SmartWakeNotificationRinger(config: config)
    }

    /// What the Tonight sheet should promise before any authorization is asked.
    public static var preferredKind: SmartWakeBlockState.Ringer {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return .alarmKit }
        #endif
        return .notification
    }
}

// MARK: - AlarmKit (iOS 26+)

#if canImport(AlarmKit)
/// AlarmKit metadata for our alarms (none needed beyond the presentation).
@available(iOS 26.0, *)
public struct SmartWakeAlarmMetadata: AlarmMetadata {
    public init() {}
}

/// AlarmKit ringer (`NSAlarmKitUsageDescription` is in project.yml). A fixed-date alarm: the backstop at L, or "now +
/// 5 s" when the fire rule rings (ARCHITECTURE 4.11). Stop only: an AlarmKit snooze needs a countdown Live Activity
/// (a widget extension, WP-27), so it is not offered yet.
@available(iOS 26.0, *)
@MainActor
public final class SmartWakeAlarmKitRinger: SmartWakeRinging {
    public let kind: SmartWakeBlockState.Ringer = .alarmKit
    private let leadSeconds: Double

    public init(leadSeconds: Double = SmartWakeConfig.standard.ringLeadSeconds) {
        self.leadSeconds = leadSeconds
    }

    public func authorize() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            let state = try? await AlarmManager.shared.requestAuthorization()
            return state == .authorized
        @unknown default:
            return false
        }
    }

    // Wave W11 (2026-10-11): when AlarmKit refuses a schedule, the same ring goes out as the notification series
    // instead of failing the smart wake (Mo: "a widget error every time"). Notification ids are not UUIDs, so `cancel`
    // tells them apart.
    private lazy var fallback = SmartWakeNotificationRinger()
    public private(set) var lastRefusal: String?

    public func scheduleBackstop(plan: SmartWakePlan) async throws -> [String] {
        let at = Date(timeIntervalSince1970: TimeInterval(plan.backstopAt))
        do {
            return [try await schedule(at: at, title: "Wake up \u{2014} smart wake backstop")]
        } catch {
            lastRefusal = AlarmBackstops.words(error)
            return try await fallback.scheduleBackstop(plan: plan)
        }
    }

    public func ringNow(plan: SmartWakePlan, outcome: SmartWakeOutcome) async throws -> [String] {
        let title = outcome.stageAtWake == .wake ? "Good morning \u{2014} you were stirring"
            : "Good morning \u{2014} light sleep, a good moment"
        do {
            return [try await schedule(at: Date().addingTimeInterval(leadSeconds), title: title)]
        } catch {
            lastRefusal = AlarmBackstops.words(error)
            return try await fallback.ringNow(plan: plan, outcome: outcome)
        }
    }

    public func snooze(minutes: Int, plan: SmartWakePlan) async throws -> [String] {
        do {
            return [try await schedule(at: Date().addingTimeInterval(Double(minutes) * 60), title: "Wake up \u{2014} snoozed")]
        } catch {
            lastRefusal = AlarmBackstops.words(error)
            return try await fallback.snooze(minutes: minutes, plan: plan)
        }
    }

    public func cancel(ids: [String]) async {
        var other: [String] = []
        for raw in ids {
            guard let id = UUID(uuidString: raw) else {
                other.append(raw)
                continue
            }
            try? AlarmManager.shared.stop(id: id)     // silences one that is ringing
            try? AlarmManager.shared.cancel(id: id)   // removes one still scheduled
        }
        if !other.isEmpty { await fallback.cancel(ids: other) }
    }

    private func schedule(at date: Date, title: String) async throws -> String {
        let id = UUID()
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stop)
        let attributes = AlarmAttributes<SmartWakeAlarmMetadata>(presentation: AlarmPresentation(alert: alert),
                                                                 metadata: SmartWakeAlarmMetadata(),
                                                                 tintColor: Color(red: 0.118, green: 0.580, blue: 0.400))
        let configuration = AlarmManager.AlarmConfiguration<SmartWakeAlarmMetadata>(
            countdownDuration: nil, schedule: .fixed(date), attributes: attributes, stopIntent: nil,
            secondaryIntent: nil)   // sound: the system alarm sound (default)
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        return id.uuidString
    }
}
#endif

// MARK: - Notification fallback (iOS < 26, or AlarmKit refused)

/// Time-sensitive notification with sound (falls back to `.active` when the entitlement is absent — free Apple IDs
/// cannot sign it, ARCHITECTURE 9.2), repeated each minute `notificationRepeats` extra times until Stop, plus a
/// best-effort vibration burst while the app is alive. The content comes from WP-24
/// (`NotifyContent.smartWakeRing`, category SMART_WAKE with STOP / SNOOZE_9); this class only schedules requests —
/// it never registers categories or sets the delegate (WP-24 owns both).
@MainActor
public final class SmartWakeNotificationRinger: SmartWakeRinging {
    public let kind: SmartWakeBlockState.Ringer = .notification
    private let config: SmartWakeConfig
    private let center = UNUserNotificationCenter.current()
    private let calendar: Calendar

    public init(config: SmartWakeConfig = .standard, calendar: Calendar = .current) {
        self.config = config
        self.calendar = calendar
    }

    public func authorize() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    public func scheduleBackstop(plan: SmartWakePlan) async throws -> [String] {
        let at = Date(timeIntervalSince1970: TimeInterval(plan.backstopAt))
        return try await scheduleSeries(first: at, plan: plan, reason: .backstop, prefix: "smartwake.backstop")
    }

    public func ringNow(plan: SmartWakePlan, outcome: SmartWakeOutcome) async throws -> [String] {
        let ids = try await scheduleSeries(first: Date().addingTimeInterval(1), plan: plan,
                                           reason: outcome.stageAtWake == .wake ? .awake : .lightSleep,
                                           prefix: "smartwake.ring")
        vibrateBurst()
        return ids
    }

    public func snooze(minutes: Int, plan: SmartWakePlan) async throws -> [String] {
        try await scheduleSeries(first: Date().addingTimeInterval(Double(minutes) * 60), plan: plan,
                                 reason: .snooze(minutes: minutes), prefix: "smartwake.snooze")
    }

    public func cancel(ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    enum RingReason: Equatable {
        case lightSleep, awake, backstop
        case snooze(minutes: Int)
    }

    private func scheduleSeries(first: Date, plan: SmartWakePlan, reason: RingReason, prefix: String) async throws
        -> [String] {
        var ids: [String] = []
        let stamp = Int64(first.timeIntervalSince1970)
        for k in 0...max(0, config.notificationRepeats) {
            let fireAt = first.addingTimeInterval(Double(k) * 60)
            let id = "\(prefix).\(stamp).\(k)"
            let content = SmartWakeNotificationRinger.ringContent(fireAt: fireAt, plan: plan, reason: reason,
                                                                  calendar: calendar)
            let interval = max(1, fireAt.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            ids.append(id)
        }
        return ids
    }

    /// The one place that touches WP-24's content builder (category SMART_WAKE, ringtone sound, time-sensitive level):
    /// `NotifyContent.smartWakeRing` → `NotifySystem.makeContent`. Only the body is reworded for the two cases WP-24's
    /// two reasons do not cover (already stirring, snooze), so the ring never says "light sleep" when it wasn't.
    static func ringContent(fireAt: Date, plan: SmartWakePlan, reason: RingReason, calendar: Calendar)
        -> UNNotificationContent {
        let ws = Date(timeIntervalSince1970: TimeInterval(plan.windowStart))
        let we = Date(timeIntervalSince1970: TimeInterval(plan.windowEnd))
        let wakeReason: NotifyContent.WakeReason = reason == .lightSleep || reason == .awake ? .lightSleep : .backstop
        let spec = NotifyContent.smartWakeRing(fireAt: fireAt, windowStart: ws, windowEnd: we, reason: wakeReason,
                                               calendar: calendar)
        let content = NotifySystem.makeContent(spec)
        switch reason {
        case .awake:
            content.body = "You were already stirring at \(MGFormat.time(fireAt, calendar: calendar))."
        case .snooze(let minutes):
            content.body = "Snoozed \(minutes) min."
        case .lightSleep, .backstop:
            break
        }
        return content
    }

    /// Best effort: vibrations while the app is alive (BLE keeps it running overnight). iOS may ignore them in the
    /// background; the notification's own sound is the real ring.
    private func vibrateBurst() {
        #if canImport(UIKit)
        if UIApplication.shared.applicationState == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        #endif
        #if canImport(AudioToolbox)
        Task { @MainActor in
            for _ in 0..<6 {
                AudioServicesPlayAlertSound(SystemSoundID(kSystemSoundID_Vibrate))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        #endif
    }
}
