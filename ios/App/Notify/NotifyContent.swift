import Foundation
import MGContext
import MGDomain
import MGHealth

// WP-24 — what each notification says (pure; NotifySystem turns a spec into UNMutableNotificationContent).
// Wording comes from PLAN §2 (receipt, reminder), UX-SPEC §4.2 / §5.2 (questions, alert, data waiting) and §8.1
// (smart wake). Times are 24 h and durations "7 h 08" (MGFormat, UX §1.3).

enum NotifySound: String, Equatable, Sendable {
    case none = "none"
    case standard = "standard"
    /// The longer ringtone sound, for the smart-wake ring (`UNNotificationSound.defaultRingtone`).
    case ringtone = "ringtone"
}

enum NotifyLevel: String, Equatable, Sendable {
    case passive = "passive"
    case active = "active"
    /// Needs the time-sensitive entitlement, which free Apple IDs can't sign (project.yml); iOS then delivers it as
    /// `.active` (ARCHITECTURE §4.11 "falls back to .active").
    case timeSensitive = "time_sensitive"
}

/// One notification's content, free of UserNotifications so it can be tested and mirrored.
struct NotifyContentSpec: Equatable, Sendable {
    var kind: NotifyKind
    var title: String
    var subtitle: String?
    var body: String
    /// Carried in `content.userInfo`; always has "kind". Strings only (read back by NotifyResponseMap).
    var userInfo: [String: String]
    var threadId: String
    var sound: NotifySound
    var level: NotifyLevel

    var category: NotifyCategoryID { kind.category }
}

/// Nov 5 2026: the app's own name in notification text ("Open HealthApp to ..."). It said "MG" (the app's first name) whatever
/// the installed app is called, and read as the strap.
enum NotifyApp {
    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "HealthApp"
    }
}

/// userInfo keys.
enum NotifyKey {
    static let kind = "kind"
    static let question = "question"
    static let previous = "previous"
    static let name = "name"
    static let scheduleId = "schedule_id"
    static let alertId = "alert_id"
}

/// Tailscale's Shortcuts action behind the reminder's "Connect" button (PLAN §2: our app can't switch Tailscale on;
/// Tailscale's own Shortcuts "Connect" action can).
enum NotifyTailscale {
    /// Mo makes a Shortcut with Tailscale's "Connect" action and names it this (ARCHITECTURE §4.11). One constant for
    /// every Shortcut name (MGHealth ShortcutNames, 2026-10-11; was the placeholder "Connect Tailscale").
    static let shortcutName = ShortcutNames.tailscale

    /// `shortcuts://run-shortcut?name=HealthApp%20Tailscale` (the notification button). `UIIntent.openTailscale` runs the
    /// same Shortcut with x-callback-url instead (AppModel+AppleHealth.swift), so a missing one is reported.
    static var connectShortcutURL: URL? {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "run-shortcut"
        c.queryItems = [URLQueryItem(name: "name", value: shortcutName)]
        return c.url
    }
}

enum NotifyText {
    /// "412 KB", "1.2 MB", "999 B" — decimal units, as iOS shows file sizes.
    static func bytes(_ n: Int) -> String {
        if n < 1000 { return "\(max(0, n)) B" }
        let kb = (Double(n) / 1000).rounded()
        if kb < 1000 { return "\(Int(kb)) KB" }
        if n < 1_000_000_000 { return String(format: "%.1f MB", Double(n) / 1e6) }
        return String(format: "%.1f GB", Double(n) / 1e9)
    }

    /// "3 h 20 min", "3 h", "40 min", "2 days" (wave W11, Mo 2026-10-11: never "71 h 59"). It used to be
    /// MGFormat.duration without a trailing " 00" ("3 h 20").
    static func span(_ seconds: TimeInterval) -> String { HumanDuration.text(seconds) }

    /// "PC got 3 h 20 of data (412 KB)." — or, when the receipts carry no time span, the file count.
    static func receiptBody(_ batch: NotifyReceiptBatch) -> String {
        let size = bytes(batch.bytes)
        if batch.coveredSeconds >= 60 {
            return "PC got \(span(batch.coveredSeconds)) of data (\(size))."
        }
        return "PC got \(batch.files) \(batch.files == 1 ? "file" : "files") (\(size))."
    }
}

enum NotifyContent {
    private static func make(_ kind: NotifyKind, title: String, subtitle: String? = nil, body: String,
                             info: [String: String] = [:], thread: String, sound: NotifySound,
                             level: NotifyLevel = .active) -> NotifyContentSpec {
        var userInfo = info
        userInfo[NotifyKey.kind] = kind.rawValue
        return NotifyContentSpec(kind: kind, title: title, subtitle: subtitle, body: body, userInfo: userInfo,
                                 threadId: thread, sound: sound, level: level)
    }

    /// SYNC_RECEIPT: "PC got 3 h of data (412 KB)." (PLAN §2). Silent — PLACEHOLDER: Mo decides whether a receipt
    /// makes a sound; it still shows as a banner and in Notification Center.
    static func syncReceipt(_ batch: NotifyReceiptBatch) -> NotifyContentSpec {
        let title = batch.pcName.map { "Synced with \($0)" } ?? "Synced with your PC"
        return make(.syncReceipt, title: title, body: NotifyText.receiptBody(batch), thread: "mg.sync", sound: .none)
    }

    /// Wave W11 (2026-10-11): the three sync problems Mo is told about (SyncNotice); routine syncs post nothing.
    static func pcUnreachable(since: Date, lastSynced: Date?, pcName: String?, now: Date) -> NotifyContentSpec {
        let pc = pcName ?? "your PC"
        let gap = HumanDuration.text(now.timeIntervalSince(since))
        let waiting = lastSynced.map { " Data since \(HumanDuration.text(now.timeIntervalSince($0))) ago is waiting." } ?? ""
        return make(.tailscaleReminder, title: "Can't reach \(pc)",
                    body: "Not reachable for \(gap).\(waiting) Tailscale may be off or the PC asleep. "
                        + "Connect runs your Shortcut “\(NotifyTailscale.shortcutName)”.",
                    thread: "mg.sync", sound: .standard)
    }

    static func uploadsFailing(times: Int, last: String?, pcName: String?) -> NotifyContentSpec {
        make(.tailscaleReminder, title: "Uploads to \(pcName ?? "your PC") are failing",
             body: "\(times) tries in a row" + (last.map { ". Last: \($0)" } ?? "") + ". Settings › Usage has the details.",
             thread: "mg.sync", sound: .standard)
    }

    static func storageLow(freeBytes: Int64) -> NotifyContentSpec {
        make(.tailscaleReminder, title: "iPhone storage low",
             body: "\(UsageMath.bytes(freeBytes)) free. Strap data keeps being stored; Settings › Usage shows what "
                + "HealthApp holds.", thread: "mg.sync", sound: .standard)
    }

    /// TAILSCALE_REMINDER (PLAN §2, UX §4.2 "Data waiting"), with the Shortcuts "Connect" hint.
    static func tailscaleReminder(lastSynced: Date, pcName: String?, now: Date) -> NotifyContentSpec {
        let waiting = HumanDuration.text(now.timeIntervalSince(lastSynced))   // wave W11: "2 days", not "71 h 59"
        let pc = pcName ?? "the PC"
        let body = "\(waiting) of data waiting for \(pc). Tailscale is off or the PC is asleep. "
            + "Connect runs your Shortcut “\(NotifyTailscale.shortcutName)”."
        return make(.tailscaleReminder, title: "Turn on Tailscale to sync", body: body, thread: "mg.sync",
                    sound: .standard)
    }

    /// A peek question as a notification, for when the app is closed (UX §5: "iOS notification — only when the app
    /// is closed; actionable"). nil for questions that stay in the app (morning check-in, nap + 30 min).
    /// The request id should be `requestID(for:)` so answering in the app can withdraw it.
    static func question(_ q: PendingQuestion, calendar: Calendar) -> NotifyContentSpec? {
        let info = [NotifyKey.question: q.id]
        switch q.kind {
        case .nap(let start, let end):
            // UX §4.2 "Nap detected": "Tell me and the detector learns."
            return make(.napConfirm, title: "Nap \(MGFormat.timeRange(start, end, calendar: calendar))?",
                        body: "Tell me and the detector learns.", info: info, thread: "mg.question", sound: .standard)
        case .workoutConfirm(let start, let end):
            return make(.workoutConfirm,
                        title: "Workout \(MGFormat.timeRange(start, end, calendar: calendar)) — right?",
                        body: "Open \(NotifyApp.name) to edit the times.", info: info, thread: "mg.question", sound: .standard)
        case .wearLocation(_, let previous):
            var i = info
            if let previous { i[NotifyKey.previous] = previous.rawValue }
            let body = previous.map { "Same as before: \(NotifyContent.place($0))." } ?? "Open \(NotifyApp.name) to say where."
            return make(.wearLocation, title: "Where's the strap now?", body: body, info: i, thread: "mg.question",
                        sound: .standard)
        case .mealCheckin(_, let minutesAfter):
            return make(.mealCheckin, title: "Your meal was \(minutesAfter) min ago — how sleepy?",
                        body: "1 extremely alert · 5 neither · 9 fighting sleep", info: info, thread: "mg.question",
                        sound: .standard)
        case .napPlus30, .morningCheckin:
            return nil
        }
    }

    static func requestID(for q: PendingQuestion) -> String { "mg.q.\(q.id)" }

    /// ALERT (UX §4.2: "the alert in one sentence + its evidence"). Request id `"mg.alert.\(alert.id)"` — the id is
    /// stable per pattern, so the same pattern replaces rather than repeats (APP-037).
    static func alert(_ alert: AlertInfo) -> NotifyContentSpec {
        let title: String
        switch alert.kind {
        case .breathingDisturbance: title = "Breathing disturbance"
        case .possibleAF: title = "Possible irregular rhythm"
        case .anomaly: title = "Unusual pattern"
        }
        return make(.alert, title: title, subtitle: alert.evidence, body: alert.sentence,
                    info: [NotifyKey.alertId: alert.id], thread: "mg.alert", sound: .standard)
    }

    enum WakeReason: String, Equatable, Sendable {
        /// Light sleep inside the window (the fire rule of §4.11).
        case lightSleep = "light_sleep"
        /// The backstop at the latest wake L (strap disconnected or never light).
        case backstop = "backstop"
    }

    /// SMART_WAKE fallback ring (iOS < 26; WP-11 schedules it). Ringtone sound, time-sensitive (→ active without the
    /// entitlement). On Silent it may not wake Mo — the Tonight sheet says so (UX §8.1).
    static func smartWakeRing(fireAt: Date, windowStart: Date?, windowEnd: Date, reason: WakeReason,
                              calendar: Calendar) -> NotifyContentSpec {
        let body: String
        switch reason {
        case .lightSleep:
            let window = windowStart.map { " inside \(MGFormat.timeRange($0, windowEnd, calendar: calendar))" } ?? ""
            body = "Light sleep at \(MGFormat.time(fireAt, calendar: calendar))\(window)."
        case .backstop:
            body = "Your latest wake time, \(MGFormat.time(windowEnd, calendar: calendar))."
        }
        return make(.smartWakeRing, title: "Time to get up", body: body, thread: "mg.wake", sound: .ringtone,
                    level: .timeSensitive)
    }

    /// "Open MG to start night sounds" (WP-26): armed for tonight, but iOS would not start the microphone in the
    /// background. Silent. PLACEHOLDER copy: main / Mo may reword. Request id `nightSoundsRequestID` (replaces itself).
    static func nightSoundsNeedsForeground() -> NotifyContentSpec {
        make(.nightSoundsPrompt, title: "Open \(NotifyApp.name) to start night sounds",
             body: "iPhone only lets \(NotifyApp.name) start listening while the app is open. Open it once; it keeps listening after you lock the phone.",
             thread: "mg.nightsounds", sound: .none, level: .active)
    }

    static let nightSoundsRequestID = "mg.nightsounds.needs-foreground"

    /// NAP_TIMER: the nap timer Mo started is over. Ringtone, time-sensitive (→ active without the entitlement).
    static func napTimerRing(minutes: Int) -> NotifyContentSpec {
        make(.napTimerRing, title: "Nap over", body: "Your \(minutes)-min nap timer has ended.", thread: "mg.nap",
             sound: .ringtone, level: .timeSensitive)
    }

    static let napTimerRequestID = "mg.nap.timer"

    /// STRAP_OFF: the "Remind me in 30 min" Mo asked for on the strap-off card (UX §4.2 wording).
    static func strapOffReminder(offSince: Date?, now: Date) -> NotifyContentSpec {
        let since = offSince.map { "Strap off for \(MGFormat.duration(now.timeIntervalSince($0))). " } ?? ""
        return make(.strapOffReminder, title: "Strap still off?",
                    body: "\(since)Nothing records while it's off.", thread: "mg.strap", sound: .standard)
    }

    static let strapOffRequestID = "mg.strap.off-reminder"

    /// MED_REMINDER, CAFFEINE_LIMIT, WIND_DOWN from MGContext's ReminderPlan (wave 2, 2026-10-11: these categories had
    /// no sender). The words are the plan's; medication carries name + schedule id for the TOOK / SKIP buttons.
    static func reminder(_ r: PlannedReminder) -> NotifyContentSpec {
        switch r.kind {
        case .medication:
            var info: [String: String] = [:]
            if let n = r.name { info[NotifyKey.name] = n }
            if let id = r.scheduleId { info[NotifyKey.scheduleId] = id }
            return make(.medReminder, title: r.title, body: r.body, info: info, thread: "mg.med", sound: .standard)
        case .caffeineLimit:
            return make(.caffeineLimit, title: r.title, body: r.body, thread: "mg.caffeine", sound: .standard)
        case .windDown:
            return make(.windDown, title: r.title, body: r.body, thread: "mg.winddown", sound: .standard)
        case .stressSummary:
            return make(.stressSummary, title: r.title, body: r.body, thread: "mg.stress", sound: .standard)
        }
    }

    /// T9993: the wake chain finished: the PC ran the night's models and its results are on the phone. `seconds` = from the
    /// wake to now. Silent; a tap opens Today. One request id per day, so a second run replaces the first.
    static func pcNumbersIn(seconds: TimeInterval) -> NotifyContentSpec {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return make(.pcNumbersIn, title: "PC numbers are in",
                    body: "Your night is on your PC and its numbers are back here, \(minutes) min after you woke.",
                    thread: "mg.pcnumbers", sound: .none)
    }

    static func pcNumbersRequestID(day: String) -> String { "mg.pcnumbers.\(day)" }

    /// Nov 6 2026: the night finished processing. Names the device ("from your WHOOP 4.0"; "strap" when none is chosen, never
    /// "MG" for a 4.0). Silent, a tap opens Today; one request id per day. Reuses the PC-numbers kind (silent, opens Today).
    static func lastNightReady(deviceName: String) -> NotifyContentSpec {
        make(.pcNumbersIn, title: "Last night is ready",
             body: "Your sleep from your \(deviceName) is processed.", thread: "mg.sleepready", sound: .none)
    }

    static func lastNightReadyRequestID(day: String) -> String { "mg.sleepready.\(day)" }

    /// r9q: "Workout?" with Yes / No. Raw sensor streams are already on for it; No puts them back to the saved setting.
    static func workoutLikely(onset: Date, calendar: Calendar) -> NotifyContentSpec {
        make(.workoutLikely, title: "Workout?",
             body: "Your heart rate has been up since \(MGFormat.time(onset, calendar: calendar)). Raw sensor streams are on for it; "
                 + "No puts them back.", thread: "mg.workoutlikely", sound: .standard)
    }

    static let workoutLikelyRequestID = "mg.workout.likely"

    /// "left wrist" from `left_wrist`.
    static func place(_ w: WearLocation) -> String { w.rawValue.replacingOccurrences(of: "_", with: " ") }
}
