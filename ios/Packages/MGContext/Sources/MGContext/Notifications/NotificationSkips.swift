import Foundation

/// T9841 (R-098, R-099): every notification the app can post has a "skip" choice in Settings › Notifications. A skipped
/// kind is dropped before it is posted (the app's `NotifyPolicy.decide` returns `.drop(.skipped)`), so nothing about it
/// reaches the lock screen or the strap. The ids are `NotifyKind` raw values (App target); this list is the Settings side
/// of the same vocabulary, and a test keeps the two in step.
///
/// Safe default (listed in DECISIONS): an alarm (the smart-wake ring, the nap-timer ring) can NOT be skipped here, because
/// a skipped alarm that Mo forgot about would leave him asleep; he switches those off where he set them (Alarms, Tonight).
public enum NotificationSkips {
    public struct Kind: Equatable, Sendable, Identifiable {
        /// `NotifyKind.rawValue`.
        public var id: String
        public var title: String
        public var detail: String
        public var canSkip: Bool
    }

    public static let alarmReason = "An alarm can't be skipped here: switch it off in Alarms."

    public static let all: [Kind] = [
        Kind(id: "med_reminder", title: "Medication reminders", detail: "At each scheduled medication time.", canSkip: true),
        Kind(id: "meal_checkin", title: "Meal check-ins", detail: "How alert you feel, 1 and 2 hours after a logged meal.",
             canSkip: true),
        Kind(id: "nap_confirm", title: "Nap questions", detail: "\"Nap 2:05–2:31 PM?\" after a detected nap.", canSkip: true),
        Kind(id: "workout_confirm", title: "Workout questions", detail: "\"Workout ended, right?\" after a detected workout.",
             canSkip: true),
        Kind(id: "wear_location", title: "Where is the strap now?", detail: "When the strap goes on and the app is closed.",
             canSkip: true),
        Kind(id: "strap_off_reminder", title: "Strap-off reminder", detail: "\"Remind me in 30 minutes\" from the strap-off card.",
             canSkip: true),
        Kind(id: "caffeine_limit", title: "Caffeine limit", detail: "\"No more caffeine today.\"", canSkip: true),
        Kind(id: "wind_down", title: "Wind-down", detail: "An hour before your bedtime.", canSkip: true),
        Kind(id: "stress_summary", title: "Stress summary", detail: "Today's stress at 5:00 PM.", canSkip: true),
        Kind(id: "night_sounds_prompt", title: "Night sounds prompt", detail: "\"Open the app to start night sounds.\"", canSkip: true),
        Kind(id: "alert", title: "Health alerts", detail: "Breathing disturbance, possible AF, heart-rate anomaly.", canSkip: true),
        Kind(id: "sync_receipt", title: "Sync receipts", detail: "What your PC received.", canSkip: true),
        Kind(id: "tailscale_reminder", title: "Tailscale reminder", detail: "\"Turn on Tailscale to sync.\"", canSkip: true),
        Kind(id: "pc_numbers_in", title: "PC numbers are in", detail: "Silent, after the morning chain finishes.", canSkip: true),
        Kind(id: "smart_wake_ring", title: "Smart-wake ring", detail: "The wake alarm.", canSkip: false),
        Kind(id: "nap_timer_ring", title: "Nap timer ring", detail: "The nap timer you started.", canSkip: false),
    ]

    public static func canSkip(_ id: String) -> Bool { all.first { $0.id == id }?.canSkip ?? false }

    /// One switch per kind, "Skip <title>", on = skipped. Alarm rows are shown, off and disabled, with the reason.
    public static func toggles(skipped: Set<String>) -> [ToggleState] {
        all.map { k in
            let on = k.canSkip && skipped.contains(k.id)
            return ToggleState(id: "skip." + k.id, title: "Skip: " + k.title, detail: k.detail, isOn: on, enabled: k.canSkip,
                               disabledReason: k.canSkip ? nil : alarmReason,
                               intent: .editSetting(.notificationSkip(kind: k.id, skip: !on)))
        }
    }
}
