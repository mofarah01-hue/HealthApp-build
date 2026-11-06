import Foundation

// WP-24 — the notification vocabulary: kinds, priority classes, category and action ids.
// Source of the ids: ARCHITECTURE.md §4.11 category table. Answer wording: UX-SPEC §5.2 and §4.2.
// Pure data, no UserNotifications import (NotifySystem.swift turns it into UNNotificationCategory).

/// How urgent a kind is; `NotifyPolicy.decide` lets each class through differently (APP-363 "priority classes").
enum NotifyPriority: String, Codable, Sendable, CaseIterable {
    /// The smart-wake fallback ring (iOS < 26, ARCHITECTURE §4.11). An alarm always gets past quiet hours: it rings
    /// inside the wake window, which lies inside quiet hours by definition.
    case alarm = "alarm"
    /// Health alerts (ALG-023 breathing disturbance, ALG-013 possible AF, ALG-112 anomaly). Held by quiet hours unless
    /// Mo switches alerts to "immediate" (APP-037). Not a prompt, so the daily cap does not apply.
    case alert = "alert"
    /// A question with answer buttons. Quiet hours and the daily cap apply (contract `notificationPolicy` TODO: "the
    /// daily cap on prompts").
    case prompt = "prompt"
    /// Information. Quiet hours and the kind's own spacing apply; not a prompt.
    case info = "info"
    /// Delivered with no sound. The quiet-hours window does not hold it (it can't disturb, and the one kind, the
    /// night-sounds prompt, is due at bedtime — inside the window, which starts at B − 30 min); a strap "asleep" span
    /// still does. Not a prompt.
    case silent = "silent"
}

/// Every notification the app can post.
enum NotifyKind: String, Codable, Sendable, CaseIterable {
    /// "PC got 3 h of data (412 KB)" — batched (PLAN §2).
    case syncReceipt = "sync_receipt"
    /// "Turn on Tailscale to sync" (PLAN §2, UX §4.2 "Data waiting").
    case tailscaleReminder = "tailscale_reminder"
    /// "Where's the strap now?" after WRIST_ON with the app closed (APP-008).
    case wearLocation = "wear_location"
    /// "Nap 14:05–14:31?" (ALG-033 nap ended, APP-042).
    case napConfirm = "nap_confirm"
    /// "Workout 17:32–18:20 — right?" (ALG-041 workout ended, APP-051).
    case workoutConfirm = "workout_confirm"
    /// KSS 60 / 120 min after a logged meal (APP-061).
    case mealCheckin = "meal_checkin"
    /// "No more caffeine today" (ALG-061).
    case caffeineLimit = "caffeine_limit"
    /// A medication schedule time (APP-076).
    case medReminder = "med_reminder"
    /// A health alert (UX §4.2 "Alert").
    case alert = "alert"
    /// Smart-wake fallback ring when AlarmKit is not available (iOS < 26, WP-11 schedules it).
    case smartWakeRing = "smart_wake_ring"
    /// "Open MG to start night sounds": iOS may refuse to START the microphone in the background (WP-26). Added for
    /// WP-26 with main's OK, 2026-10-11 (not in the §4.11 table).
    case nightSoundsPrompt = "night_sounds_prompt"
    /// The nap timer Mo started has ended (UX §4.2 "Nap timer running"; iPhone only, strap buzz off — BRIEF default 4).
    /// An alarm: he set it, so quiet hours don't hold it. Added for WP-23's NotifyHook.
    case napTimerRing = "nap_timer_ring"
    /// "Remind me in 30 min" on the strap-off Moment card (UX §4.2). Added for WP-23's NotifyHook.
    case strapOffReminder = "strap_off_reminder"
    /// "Wind down from 21:30" at bedtime − 60 min (UX-SPEC §8 WindDownToggle; wave 2, 2026-10-11: the toggle was read by
    /// nothing). Information: quiet hours start after it (B − 30 min).
    case windDown = "wind_down"
    /// T31: "Body arousal today: 1.7 of 3" at 5:00 PM (ReminderPlan). Information; a tap opens Today.
    case stressSummary = "stress_summary"
    /// T9993: "Your PC numbers are in" - the wake chain (history, upload, the PC's night models, results back) finished.
    /// Silent: it must not wake or startle Mo just after he got up; quiet hours do not hold a silent kind.
    case pcNumbersIn = "pc_numbers_in"
    /// r9q: "Workout?" Yes / No while the raw streams have switched on for a workout that looks likely. Information, not a
    /// prompt: the daily prompt cap would move a question about the last 20 minutes to tomorrow.
    case workoutLikely = "workout_likely"

    var priority: NotifyPriority {
        switch self {
        case .smartWakeRing, .napTimerRing: return .alarm
        case .alert: return .alert
        case .wearLocation, .napConfirm, .workoutConfirm, .mealCheckin, .medReminder: return .prompt
        case .syncReceipt, .tailscaleReminder, .caffeineLimit, .strapOffReminder, .windDown, .stressSummary, .workoutLikely: return .info
        case .nightSoundsPrompt, .pcNumbersIn: return .silent
        }
    }

    var category: NotifyCategoryID {
        switch self {
        case .syncReceipt: return .syncReceipt
        case .tailscaleReminder: return .tailscaleReminder
        case .wearLocation: return .wearLocation
        case .napConfirm: return .napConfirm
        case .workoutConfirm: return .workoutConfirm
        case .mealCheckin: return .mealCheckin
        case .caffeineLimit: return .caffeineLimit
        case .medReminder: return .medReminder
        case .alert: return .alert
        case .smartWakeRing: return .smartWake
        case .nightSoundsPrompt: return .nightSounds
        case .napTimerRing: return .napTimer
        case .strapOffReminder: return .strapOff
        case .windDown: return .windDown
        case .stressSummary: return .stressSummary
        case .pcNumbersIn: return .pcNumbers
        case .workoutLikely: return .workoutLikely
        }
    }
}

/// `UNNotificationCategory` identifiers, exactly as ARCHITECTURE §4.11.
enum NotifyCategoryID: String, Sendable, CaseIterable {
    case syncReceipt = "SYNC_RECEIPT"
    case tailscaleReminder = "TAILSCALE_REMINDER"
    case wearLocation = "WEAR_LOCATION"
    case napConfirm = "NAP_CONFIRM"
    case workoutConfirm = "WORKOUT_CONFIRM"
    case mealCheckin = "MEAL_CHECKIN"
    case caffeineLimit = "CAFFEINE_LIMIT"
    case medReminder = "MED_REMINDER"
    case alert = "ALERT"
    case smartWake = "SMART_WAKE"
    /// Addition for WP-26 (main's OK, 2026-10-11): no buttons; a tap opens the app, which starts listening.
    case nightSounds = "NIGHT_SOUNDS"
    /// Additions for WP-23's NotifyHook (UX §4.2 nap timer and strap-off card).
    case napTimer = "NAP_TIMER"
    case strapOff = "STRAP_OFF"
    /// Wave 2: the wind-down reminder, with "Breathe now".
    case windDown = "WIND_DOWN"
    /// T31: the 5:00 PM body-arousal summary (was "stress"), no buttons.
    case stressSummary = "STRESS_SUMMARY"
    /// T9993: the wake chain's "PC numbers are in", no buttons.
    case pcNumbers = "PC_NUMBERS"
    /// r9q: the "Workout?" question while raw streams are on for a likely workout.
    case workoutLikely = "WORKOUT_LIKELY"
}

/// `UNNotificationAction` identifiers, exactly as ARCHITECTURE §4.11. `tap` is ours: the notification body was
/// tapped (NotifySystem maps `UNNotificationDefaultActionIdentifier` to it, so the pure layer needs no framework).
enum NotifyActionID: String, Sendable, CaseIterable {
    case tap = "TAP"
    case openTailscale = "OPEN_TAILSCALE"
    case same = "SAME"
    case leftWrist = "LEFT_WRIST"
    case rightWrist = "RIGHT_WRIST"
    case nap = "NAP"
    case dozed = "DOZED"
    case rest = "REST"
    case no = "NO"
    case yes = "YES"
    case notWorkout = "NOT_WORKOUT"
    case kss1 = "KSS_1"
    case kss3 = "KSS_3"
    case kss5 = "KSS_5"
    case kss7 = "KSS_7"
    case kss9 = "KSS_9"
    case took = "TOOK"
    case skip = "SKIP"
    case open = "OPEN"
    case stop = "STOP"
    case snooze9 = "SNOOZE_9"
    /// Wave 2: wind-down → the 5-min pacer.
    case breathe = "BREATHE"
}

/// One answer button on a notification.
struct NotifyActionSpec: Equatable, Sendable {
    var id: NotifyActionID
    var title: String
    /// Brings the app to the front (needed when the action must open a URL, e.g. the Tailscale shortcut).
    /// Answers that only store something run in the background without opening the app.
    var opensApp: Bool = false
    var destructive: Bool = false
}

struct NotifyCategorySpec: Equatable, Sendable {
    var id: NotifyCategoryID
    var actions: [NotifyActionSpec]
}

enum NotifyCategories {
    /// Every category of ARCHITECTURE §4.11. iOS keeps ONE category set per app (`setNotificationCategories`
    /// replaces it), so this list is the only registration: other modules (WP-11 smart wake) use these ids.
    static let all: [NotifyCategorySpec] = [
        NotifyCategorySpec(id: .syncReceipt, actions: []),
        // "Connect" opens the app, which opens the Tailscale Shortcut (an action can't open a URL by itself).
        NotifyCategorySpec(id: .tailscaleReminder, actions: [
            NotifyActionSpec(id: .openTailscale, title: "Connect", opensApp: true),
        ]),
        // UX §4.2 "Strap back on": "same as before" is the default; the rarer places need the app (tap).
        NotifyCategorySpec(id: .wearLocation, actions: [
            NotifyActionSpec(id: .same, title: "Same as before"),
            NotifyActionSpec(id: .leftWrist, title: "Left wrist"),
            NotifyActionSpec(id: .rightWrist, title: "Right wrist"),
        ]),
        // UX §5.2 nap answers.
        NotifyCategorySpec(id: .napConfirm, actions: [
            NotifyActionSpec(id: .nap, title: "Nap"),
            NotifyActionSpec(id: .dozed, title: "Dozed"),
            NotifyActionSpec(id: .rest, title: "Rest, awake"),
            NotifyActionSpec(id: .no, title: "No"),
        ]),
        NotifyCategorySpec(id: .workoutConfirm, actions: [
            NotifyActionSpec(id: .yes, title: "Yes"),
            NotifyActionSpec(id: .notWorkout, title: "Not a workout"),
        ]),
        // UX §5.2: KSS with its meaning on each button; §4.11 keeps the odd steps for a notification.
        NotifyCategorySpec(id: .mealCheckin, actions: [
            NotifyActionSpec(id: .kss1, title: "1 · extremely alert"),
            NotifyActionSpec(id: .kss3, title: "3 · alert"),
            NotifyActionSpec(id: .kss5, title: "5 · neither"),
            NotifyActionSpec(id: .kss7, title: "7 · sleepy"),
            NotifyActionSpec(id: .kss9, title: "9 · fighting sleep"),
        ]),
        NotifyCategorySpec(id: .caffeineLimit, actions: []),
        NotifyCategorySpec(id: .medReminder, actions: [
            NotifyActionSpec(id: .took, title: "Took it"),
            NotifyActionSpec(id: .skip, title: "Skip"),
        ]),
        NotifyCategorySpec(id: .alert, actions: [
            NotifyActionSpec(id: .open, title: "Open", opensApp: true),
        ]),
        NotifyCategorySpec(id: .smartWake, actions: [
            NotifyActionSpec(id: .stop, title: "Stop", destructive: true),
            NotifyActionSpec(id: .snooze9, title: "Snooze 9 min"),
        ]),
        NotifyCategorySpec(id: .nightSounds, actions: []),
        NotifyCategorySpec(id: .napTimer, actions: [NotifyActionSpec(id: .stop, title: "Stop", destructive: true)]),
        NotifyCategorySpec(id: .strapOff, actions: []),
        NotifyCategorySpec(id: .windDown, actions: [NotifyActionSpec(id: .breathe, title: "Breathe now", opensApp: true)]),
        NotifyCategorySpec(id: .stressSummary, actions: []),
        NotifyCategorySpec(id: .pcNumbers, actions: []),
        NotifyCategorySpec(id: .workoutLikely, actions: [
            NotifyActionSpec(id: .yes, title: "Yes"),
            NotifyActionSpec(id: .no, title: "No"),
        ]),
    ]
}
