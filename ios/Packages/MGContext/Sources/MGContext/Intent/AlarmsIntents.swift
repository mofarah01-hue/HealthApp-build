import Foundation

/// The alarm page (added 2026-10-11, Mo's strap alarms). Every tap on it is one of these, sent as `UIIntent.alarms(_:)`.
/// The normal wake's time, window and on/off use the existing intents (`.setSmartWake`, `.setWakeWindow`,
/// `.setLatestWake`): one source of truth with Tonight.
public enum AlarmsAction: Equatable, Sendable {
    /// Settings › Alarms row, or the alarm chip on Today: push the page.
    case open
    case edit(AlarmsEdit)
    /// Read the phone's location once (when-in-use permission) and keep it for offline days.
    case useMyLocation
    /// "Match Pillars": today's Fajr as Pillars shows it, minutes after local midnight.
    case matchPillars(fajrMinutes: Int)
    /// Use the method the match found.
    case useMethod(PrayerMethod)
    /// "I'm up" while an alarm rings. The Fajr wake is harder locked: the first tap asks, `confirmed: true` ends it.
    case imUp(confirmed: Bool)
    /// "Stop" for a timer or a plain custom alarm (a wake alarm stops only on awake evidence or "I'm up").
    case stop
    /// Stop every app re-buzz loop and ask the strap to stop its current haptics.
    case silence
    /// "Test buzz": one buzz of `pulses` now.
    case testBuzz(pulses: Int)
    /// Settings test: one 4-pulse strap buzz and one immediate iPhone alert, saved in the test-run log.
    case testAlarm
    /// Read slot 1 back from the strap (GET_ALARM_TIME, read-only).
    case readStrapAlarm
    // startTimer / cancelTimer retired (T153, 2026-10-12): timers are `TimersAction` (Intent/TimerIntents.swift).
    /// Add (new id) or update a custom alarm.
    case saveCustom(CustomAlarm)
    case deleteCustom(UUID)
    /// A one-day / two-day / week-long change, starting today or tomorrow.
    case addOverride(target: AlarmTarget, startsTomorrow: Bool, days: Int, action: OverrideAction)
    case deleteOverride(UUID)
    /// Ask iOS for full read access to Calendar / Reminders (EventKit; the app never writes them).
    case requestCalendarAccess
    case requestRemindersAccess
    case pickCalendar(id: String, on: Bool)
    case pickReminderList(id: String, on: Bool)
}

/// One field of `AlarmsSettings`, applied to the CURRENT settings (two quick taps never undo each other).
public enum AlarmsEdit: Equatable, Sendable {
    case fajrOn(Bool)
    case fajrWeekday(Int, Bool)
    case fajrBeforeFajr(Int)
    case fajrBeforeSunrise(Int)
    case fajrMethod(PrayerMethod)
    case fajrAdjust(Int)
    case fajrPulses(Int)
    case fajrRepeatEvery(Int)
    case normalStrap(Bool)
    case normalRepeat(Bool)
    case normalSkipAfterFajr(Bool)
    case normalPulses(Int)
    case strapSlot(Bool)
    case calendarEvents(Bool)
    case calendarReminders(Bool)
    case calendarPulses(Int)
    case calendarLead(Int)
    /// T53: notification buzz by app and person (D-039). The master switch.
    case notificationsOn(Bool)
    /// Sets one app row's pulses (0 = off; the Settings row stores a default of 3 when switched on).
    case notificationApp(id: String, pulses: Int)
    /// Sets one person row's pulses (0 = off). The name is normalized here (trim + lower-case) to match how
    /// `NotificationBuzzPlanner.normal()` looks it up — storing it any other way would silently never match.
    case notificationPerson(name: String, pulses: Int)

    /// Applies the edit, clamping numbers to what the page offers (minutes 0–120, pulses 1–8, repeat 1–10 min,
    /// adjust ±30 min, lead 0–60 min).
    public func apply(to s: inout AlarmsSettings) {
        func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(r.upperBound, max(r.lowerBound, v)) }
        switch self {
        case .fajrOn(let on): s.fajr.on = on
        case .fajrWeekday(let d, let on):
            guard (1...7).contains(d) else { return }
            if on { s.fajr.weekdays.insert(d) } else { s.fajr.weekdays.remove(d) }
        case .fajrBeforeFajr(let m): s.fajr.minutesBeforeFajr = clamp(m, AlarmPlanner.minuteRange)
        case .fajrBeforeSunrise(let m): s.fajr.minutesBeforeSunrise = clamp(m, AlarmPlanner.minuteRange)
        case .fajrMethod(let m): s.fajr.method = m
        case .fajrAdjust(let m): s.fajr.fajrAdjustMinutes = clamp(m, -30...30)
        case .fajrPulses(let n): s.fajr.pulses = clamp(n, 1...8)
        case .fajrRepeatEvery(let m): s.fajr.repeatEveryMinutes = clamp(m, 1...10)
        case .normalStrap(let on): s.normal.strapOn = on
        case .normalRepeat(let on): s.normal.repeatUntilMoving = on
        case .normalSkipAfterFajr(let on): s.normal.skipIfAwakeAfterFajr = on
        case .normalPulses(let n): s.normal.pulses = clamp(n, 1...8)
        case .strapSlot(let on): s.strapSlotOn = on
        case .calendarEvents(let on): s.calendar.eventsOn = on
        case .calendarReminders(let on): s.calendar.remindersOn = on
        case .calendarPulses(let n): s.calendar.pulses = clamp(n, 1...8)
        case .calendarLead(let m): s.calendar.leadMinutes = clamp(m, 0...60)
        case .notificationsOn(let on): s.notifications.on = on
        case .notificationApp(let id, let n):
            let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            s.notifications.apps[key] = clamp(n, 0...8)
        case .notificationPerson(let name, let n):
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return }
            s.notifications.people[key] = clamp(n, 0...8)
        }
    }
}
