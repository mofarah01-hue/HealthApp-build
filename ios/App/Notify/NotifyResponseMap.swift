import Foundation
import MGContext
import MGDomain

// WP-24 — what a tap on a notification (or one of its buttons) means for the app. Pure: NotifySystem's delegate
// turns the UNNotificationResponse into (category, action, userInfo strings) and calls `response(...)`; WP-23 handles
// the result. Answer strings are the ones the peeks send (MGContext TodayPreviews: nap "nap" / "dozed" /
// "quiet_rest_not_asleep" / "no", workout "yes" / "not_workout", wear = WearLocation raw value, meal "kss<n>").

enum NotifySmartWakeAction: Equatable, Sendable {
    case stop
    case snooze(minutes: Int)
    /// The ring's body was tapped (the app opened).
    case opened
}

enum NotifyResponse: Equatable, Sendable {
    /// Send this intent, exactly as if Mo had tapped it in the app.
    case intent(UIIntent)
    /// For SmartWakeControlling (WP-11).
    case smartWake(NotifySmartWakeAction)
    /// MED_REMINDER answer. WP-23: taken → `.quickLog(.medication(name:))` (preset dose); skipped → a medication
    /// event with status `skipped`.
    case medication(name: String, scheduleId: String?, taken: Bool)
    /// r9q: the answer to "Workout?" (Yes / No) while raw streams are on for a likely workout.
    case autoWorkout(yes: Bool)
    /// Nothing to do; the string says why (for the log).
    case none(String)
}

enum NotifyResponseMap {
    static func response(category: String, action: String, userInfo: [String: String]) -> NotifyResponse {
        guard let cat = NotifyCategoryID(rawValue: category) else { return .none("unknown category \(category)") }
        guard let act = NotifyActionID(rawValue: action) else { return .none("unknown action \(action) in \(category)") }
        let today = NotifyResponse.intent(.selectTab(.today))

        switch (cat, act) {
        case (.syncReceipt, .tap):
            return .intent(.openStrapSync)

        case (.tailscaleReminder, .openTailscale):
            return .intent(.openTailscale)
        case (.tailscaleReminder, .tap):
            return today                                  // the "data waiting" Moment card is there

        case (.wearLocation, .same):
            // The previous place, as the in-app "same as before" button sends (TodayPreviews.previewWearLocation).
            return .intent(.answerPeek(.wearLocation, answer: userInfo[NotifyKey.previous] ?? "same"))
        case (.wearLocation, .leftWrist):
            return .intent(.answerPeek(.wearLocation, answer: WearLocation.leftWrist.rawValue))
        case (.wearLocation, .rightWrist):
            return .intent(.answerPeek(.wearLocation, answer: WearLocation.rightWrist.rawValue))
        case (.wearLocation, .tap):
            // R-100 (Mo 2026-10-14): this tap went to Today, where the peek is often held (cap, Night, workout), so it
            // opened "to nothing". Strap & sync shows where the strap is set now, with "Change" for every place; a pick
            // there also answers this question (AppModel+Strap `changeWearLocation`).
            return .intent(.openStrapSync)

        case (.napConfirm, .nap): return .intent(.answerPeek(.nap, answer: "nap"))
        case (.napConfirm, .dozed): return .intent(.answerPeek(.nap, answer: "dozed"))
        case (.napConfirm, .rest): return .intent(.answerPeek(.nap, answer: "quiet_rest_not_asleep"))
        case (.napConfirm, .no): return .intent(.answerPeek(.nap, answer: "no"))
        case (.napConfirm, .tap): return today

        case (.workoutConfirm, .yes): return .intent(.answerPeek(.workoutConfirm, answer: "yes"))
        case (.workoutConfirm, .notWorkout): return .intent(.answerPeek(.workoutConfirm, answer: "not_workout"))
        case (.workoutConfirm, .tap): return .intent(.openWorkout(id: nil))

        case (.mealCheckin, .kss1): return .intent(.answerPeek(.mealCheckin, answer: "kss1"))
        case (.mealCheckin, .kss3): return .intent(.answerPeek(.mealCheckin, answer: "kss3"))
        case (.mealCheckin, .kss5): return .intent(.answerPeek(.mealCheckin, answer: "kss5"))
        case (.mealCheckin, .kss7): return .intent(.answerPeek(.mealCheckin, answer: "kss7"))
        case (.mealCheckin, .kss9): return .intent(.answerPeek(.mealCheckin, answer: "kss9"))
        case (.mealCheckin, .tap): return today

        case (.caffeineLimit, .tap): return today

        case (.medReminder, .took), (.medReminder, .skip):
            guard let name = userInfo[NotifyKey.name], !name.isEmpty else {
                return .none("medication reminder without a name")
            }
            return .medication(name: name, scheduleId: userInfo[NotifyKey.scheduleId], taken: act == .took)
        case (.medReminder, .tap): return .intent(.openLogItem(.medication))

        case (.alert, .open), (.alert, .tap): return today       // the alert is the top Moment card

        case (.smartWake, .stop): return .smartWake(.stop)
        case (.smartWake, .snooze9): return .smartWake(.snooze(minutes: 9))
        case (.smartWake, .tap): return .smartWake(.opened)

        case (.nightSounds, .tap): return .intent(.openTonight)   // opening the app lets the listener start

        case (.napTimer, .stop), (.napTimer, .tap): return .intent(.endNap)
        case (.strapOff, .tap): return today                     // the strap-off Moment card is there
        case (.stressSummary, .tap): return today                // T31: the stress line is on Today
        case (.pcNumbers, .tap): return today                    // T9993: the PC's numbers are on Today

        case (.workoutLikely, .yes): return .autoWorkout(yes: true)
        case (.workoutLikely, .no): return .autoWorkout(yes: false)
        case (.workoutLikely, .tap): return .intent(.selectTab(.live))

        case (.windDown, .breathe): return .intent(.startBreathe)
        case (.windDown, .tap): return .intent(.openTonight)

        default:
            return .none("action \(action) does not belong to \(category)")
        }
    }
}
