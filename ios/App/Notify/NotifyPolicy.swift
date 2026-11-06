import Foundation
import MGContext

// WP-24 — the notification policy and the pure function that applies it (ARCHITECTURE.md §4.11, UX-SPEC §5, APP-363,
// PLAN §2 "Quiet"). Mirrored line for line in scratchpad/wp24/notify_mirror.py, which runs the edge cases on this PC.

/// The notification policy. EVERY value is a PLACEHOLDER: the contract's `notificationPolicy` is `TODO(human)`
/// (PLAN §9 decision 19). Mo sets them; nothing here is his preference.
struct NotifyPolicy: Equatable, Sendable {
    /// PLACEHOLDER: Mo sets (contract notificationPolicy TODO). Quiet hours start this long before tonight's bedtime B
    /// and end at the wake after it (UX §5 "from B − 30 min to wake").
    var quietStartsBeforeBedtime: TimeInterval = 30 * 60
    /// PLACEHOLDER: Mo sets (contract notificationPolicy TODO). UX §5 "daily cap 6". Counts prompts only — the contract
    /// TODO asks for "the daily cap on prompts" — per local calendar day.
    var dailyPromptCap: Int = 6
    /// PLACEHOLDER: Mo sets (contract notificationPolicy TODO). UX §5: only the smart-wake alarm may break quiet hours.
    /// (An alarm kind always does, whatever this set says: the wake window lies inside quiet hours.)
    var mayBreakQuietHours: Set<NotifyKind> = [.smartWakeRing]
    /// PLACEHOLDER: Mo sets (contract notificationPolicy TODO). APP-037: alerts arrive "at wake / on sync by default;
    /// immediate during sleep if you switch that on". true = alerts join the kinds that break quiet hours.
    var alertsImmediate: Bool = false
    /// PLACEHOLDER: Mo sets. PLAN §2 "hourly receipts are batched into one": at most one receipt an hour.
    var receiptMinSpacing: TimeInterval = 3600
    /// PLACEHOLDER: Mo sets. UX §4.2 / PLAN §2: the reminder needs data waiting for more than 6 h …
    var reminderUnsyncedAfter: TimeInterval = 6 * 3600
    /// PLACEHOLDER: Mo sets. … and the PC unreachable for at least 60 min (ARCHITECTURE §4.11) …
    var reminderUnreachableFor: TimeInterval = 3600
    /// PLACEHOLDER: Mo sets. … and comes at most every 6 h, never in quiet hours.
    var reminderMinSpacing: TimeInterval = 6 * 3600
    /// PLACEHOLDER: Mo sets. A Tailscale reminder that can't go out now is not saved for later (its facts go stale);
    /// the next sync attempt checks again.
    var reminderLifetime: TimeInterval = 60

    /// true while every value above is a stand-in; Settings shows them as "PLACEHOLDER — Mo sets".
    var isPlaceholder: Bool = true

    static let placeholder = NotifyPolicy()

    func breaksQuietHours(_ kind: NotifyKind) -> Bool {
        if kind.priority == .alarm || mayBreakQuietHours.contains(kind) { return true }
        return kind.priority == .alert && alertsImmediate
    }

    /// T57: a medication time is Mo's own schedule, not a question; it is neither held by the cap nor counted in it.
    func countsTowardCap(_ kind: NotifyKind) -> Bool { kind.priority == .prompt && kind != .medReminder }

    /// Minimum time between two notifications of this kind (either side), or nil.
    func minSpacing(_ kind: NotifyKind) -> TimeInterval? {
        switch kind {
        case .syncReceipt: return receiptMinSpacing
        case .tailscaleReminder: return reminderMinSpacing
        default: return nil
        }
    }
}

/// Quiet hours as wall-clock times that repeat every day (the contract TODO asks for "quiet-hours start and end
/// (HH:MM)"). start > end spans midnight (22:30 → 07:00); start == end means no quiet hours. Start is inclusive, end
/// exclusive.
struct NotifyQuietWindow: Codable, Equatable, Sendable {
    /// Seconds into the local day.
    var startSeconds: Int
    var endSeconds: Int

    init(startSeconds: Int, endSeconds: Int) {
        self.startSeconds = ((startSeconds % 86_400) + 86_400) % 86_400
        self.endSeconds = ((endSeconds % 86_400) + 86_400) % 86_400
    }

    init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.init(startSeconds: startHour * 3600 + startMinute * 60, endSeconds: endHour * 3600 + endMinute * 60)
    }

    init(start: TimeOfDay, end: TimeOfDay) {
        self.init(startSeconds: start.secondsIntoDay, endSeconds: end.secondsIntoDay)
    }

    /// Before the app has worked out any anchors (first launch): PhaseClock's own fallbacks — bedtime 23:00 (UX §2
    /// "else 23:00") and wake 07:00 (WP-06 fallback chain) — with the placeholder 30 min → 22:30–07:00.
    static let beforeFirstAnchors = NotifyQuietWindow(startHour: 22, startMinute: 30, endHour: 7, endMinute: 0)

    /// PLACEHOLDER rule (UX §5): tonight's bedtime B − `quietStartsBeforeBedtime` → the wake after it. The wake is Mo's
    /// "must be up by" L when set (Settings → Sleep & wake), else today's wake W (detected or assumed; PhaseClock's
    /// fallback chain ends at 07:00).
    static func placeholder(anchors: PhaseAnchors, policy: NotifyPolicy, calendar: Calendar) -> NotifyQuietWindow {
        let start = TimeOfDay(of: anchors.bedtime.addingTimeInterval(-policy.quietStartsBeforeBedtime), calendar: calendar)
        let end = TimeOfDay(of: anchors.latestWake ?? anchors.wake, calendar: calendar)
        return NotifyQuietWindow(start: start, end: end)
    }

    /// Is `date` inside quiet hours? A strap-detected wake inside the current occurrence ends it early (Mo is up).
    func isQuiet(at date: Date, wokeAt: Date?, calendar: Calendar) -> Bool {
        guard insideWallClock(NotifyClock.secondsIntoDay(date, calendar: calendar)) else { return false }
        if let wokeAt, let start = occurrenceStart(containing: date, calendar: calendar),
           start <= wokeAt, wokeAt <= date {
            return false
        }
        return true
    }

    /// The next end of quiet hours strictly after `date` (absolute instant; DST-safe through the calendar).
    func end(after date: Date, calendar: Calendar) -> Date {
        if let e = NotifyClock.wallClock(endSeconds, onDayOf: date, calendar: calendar), e > date { return e }
        let next = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        return NotifyClock.wallClock(endSeconds, onDayOf: next, calendar: calendar) ?? next
    }

    private func insideWallClock(_ s: Int) -> Bool {
        if startSeconds == endSeconds { return false }
        if startSeconds < endSeconds { return startSeconds <= s && s < endSeconds }
        return s >= startSeconds || s < endSeconds
    }

    /// Start instant of the occurrence that contains `date` (caller checked it is inside).
    private func occurrenceStart(containing date: Date, calendar: Calendar) -> Date? {
        if NotifyClock.secondsIntoDay(date, calendar: calendar) >= startSeconds {
            return NotifyClock.wallClock(startSeconds, onDayOf: date, calendar: calendar)
        }
        guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { return nil }
        return NotifyClock.wallClock(startSeconds, onDayOf: previous, calendar: calendar)
    }
}

/// Wall-clock helpers shared by the policy (one place for the DST behaviour).
enum NotifyClock {
    static func secondsIntoDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    /// `seconds` into the local day of `date`. A time that falls in a spring-forward gap moves to the next valid time;
    /// a repeated (fall-back) time takes its first occurrence.
    static func wallClock(_ seconds: Int, onDayOf date: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: seconds / 3600, minute: (seconds % 3600) / 60, second: seconds % 60, of: date,
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    static func startOfNextDay(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }
}

/// A notification that went out or is scheduled, at the time it fires. The cap and the spacing count these.
struct NotifyLedgerEntry: Codable, Equatable, Sendable {
    var id: String
    var kind: NotifyKind
    var at: Date
}

/// What else keeps Mo from being disturbed right now, pushed in by the app (WP-23) from the context engine.
struct NotifyContext: Equatable, Sendable {
    /// Tonight's quiet hours (`NotifyQuietWindow.placeholder(anchors:…)`); nil = none.
    var quiet: NotifyQuietWindow?
    /// Today's strap-detected wake (not an assumed one): quiet hours end once he is up.
    var wokeAt: Date?
    /// Extra quiet spans: a running nap timer, the strap saying he is asleep.
    var extraQuiet: [DateInterval]
    /// T9841: the kinds Mo chose to skip (Settings › Notifications). An alarm kind is never dropped by this.
    var skipped: Set<NotifyKind>

    init(quiet: NotifyQuietWindow?, wokeAt: Date? = nil, extraQuiet: [DateInterval] = [], skipped: Set<NotifyKind> = []) {
        self.quiet = quiet
        self.wokeAt = wokeAt
        self.extraQuiet = extraQuiet
        self.skipped = skipped
    }
}

/// Why a notification was not let out. The constraint named is the one that pushed it past its expiry.
enum NotifyDropReason: String, Equatable, Sendable {
    case expired = "expired"
    case quietHours = "quiet_hours"
    case asleep = "asleep"
    case dailyCap = "daily_cap"
    case spacing = "spacing"
    case capIsZero = "cap_is_zero"
    /// The search for a free time did not settle (should not happen; a flag rather than a loop forever).
    case noSlot = "no_slot"
    /// T9841: Mo chose to skip this kind (Settings › Notifications).
    case skipped = "skipped"
}

enum NotifyDecision: Equatable, Sendable {
    /// Post it now.
    case now
    /// Schedule it for this instant (quiet hours end, the next day under the cap, the next free hour…).
    case at(Date)
    /// Don't post it.
    case drop(NotifyDropReason)

    /// nil when it goes out (now or later); otherwise a sentence for the screen that asked for it.
    var whyNot: String? {
        guard case .drop(let reason) = self else { return nil }
        switch reason {
        case .expired: return "It would come too late to be useful."
        case .quietHours: return "It would land in quiet hours, after it stops being useful."
        case .asleep: return "You'd be asleep by then."
        case .dailyCap: return "Today's notification limit is used up."
        case .spacing: return "A notification like it went out a short while ago."
        case .capIsZero: return "Questions by notification are switched off."
        case .noSlot: return "No time was found for it."
        case .skipped: return "You chose to skip this kind of notification."
        }
    }
}

extension NotifyPolicy {
    /// The earliest moment a notification may go out, or why it may not.
    ///
    /// - `id`: this notification's request id. Ledger entries with the same id are this notification (an earlier
    ///   schedule of it, e.g. a receipt batch being re-decided) and are not counted against it.
    /// - `wanted`: the earliest time it should go out (a med schedule time, a backstop alarm); nil = now.
    /// - `expiresAt`: after this it is pointless (a nap question expires 3 h after the nap, UX §4.2); it must go out
    ///   strictly before.
    ///
    /// Rules, in order, repeated until nothing moves: quiet hours (unless the kind may break them or is silent) → extra
    /// quiet, e.g. the strap says asleep (unless the kind may break quiet hours) →
    /// the daily cap on prompts (full day → the next day) → the kind's spacing (one receipt an hour, one reminder per
    /// 6 h). Pure: same inputs, same answer.
    static func decide(kind: NotifyKind, id: String, now: Date, wanted: Date? = nil, expiresAt: Date? = nil,
                       context: NotifyContext, ledger: [NotifyLedgerEntry], policy: NotifyPolicy,
                       calendar: Calendar) -> NotifyDecision {
        if let expiresAt, expiresAt <= now { return .drop(.expired) }
        // T9841: a kind Mo skips is never posted. An alarm is the exception (a skipped alarm he forgot would leave him asleep).
        if kind.priority != .alarm, context.skipped.contains(kind) { return .drop(.skipped) }
        let breaks = policy.breaksQuietHours(kind)
        let ignoresWindow = breaks || kind.priority == .silent
        let capped = policy.countsTowardCap(kind)
        if capped && policy.dailyPromptCap <= 0 { return .drop(.capIsZero) }

        var t = max(now, wanted ?? now)
        func pastExpiry(_ x: Date) -> Bool { expiresAt.map { x >= $0 } ?? false }

        var settled = false
        for _ in 0..<16 {
            var moved = false
            if !ignoresWindow, let quiet = context.quiet,
               quiet.isQuiet(at: t, wokeAt: context.wokeAt, calendar: calendar) {
                t = quiet.end(after: t, calendar: calendar)
                moved = true
                if pastExpiry(t) { return .drop(.quietHours) }
            }
            if !breaks {
                for span in context.extraQuiet where span.start <= t && t < span.end {
                    t = span.end
                    moved = true
                    if pastExpiry(t) { return .drop(.asleep) }
                }
            }
            if capped {
                let day = t
                let used = ledger.filter {
                    $0.id != id && policy.countsTowardCap($0.kind) && calendar.isDate($0.at, inSameDayAs: day)
                }.count
                if used >= policy.dailyPromptCap {
                    t = NotifyClock.startOfNextDay(t, calendar: calendar)
                    moved = true
                    if pastExpiry(t) { return .drop(.dailyCap) }
                }
            }
            if let gap = policy.minSpacing(kind) {
                let probe = t
                let conflicts = ledger.filter {
                    $0.id != id && $0.kind == kind && abs(probe.timeIntervalSince($0.at)) < gap
                }.map(\.at)
                if let last = conflicts.max() {
                    t = last.addingTimeInterval(gap)
                    moved = true
                    if pastExpiry(t) { return .drop(.spacing) }
                }
            }
            if !moved {
                settled = true
                break
            }
        }
        if !settled { return .drop(.noSlot) }
        return t <= now ? .now : .at(t)
    }
}
