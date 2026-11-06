import Foundation
import MGDomain

/// One line of the alarm page's strap log: a strap event (56–60, 100, 14) or an alarm write, with its time.
public struct AlarmLogLine: Equatable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    public var text: String

    public init(id: String, at: Date, text: String) {
        self.id = id
        self.at = at
        self.text = text
    }
}

/// A calendar or reminders list the phone has (EventKit), for the picker.
public struct AlarmsSource: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Everything the alarm page shows (added 2026-10-11).
public struct AlarmsInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var sample: Bool
    public var settings: AlarmsSettings
    public var normal: NormalWakeInput
    public var plan: AlarmPlan
    /// Occurrence id → why it ended ("awake 05:47 (walking …)", "stopped").
    public var finished: [String: String]
    public var slot: StrapSlotState
    /// Event 56 (STRAP_DRIVEN_ALARM_SET) after the last arm.
    public var slotConfirmedAt: Date?
    /// The last slot write in words ("armed for 06:35 — ok", "not armed: strap not connected").
    public var lastSlotResult: String?
    public var rings: [String: RingState]
    /// The latest awake-evidence verdict per occurrence, in words.
    public var awakeNotes: [String: String]
    /// The Fajr "I'm up" was tapped once for this occurrence.
    public var imUpAskedFor: String?
    public var connected: Bool
    public var log: [AlarmLogLine]
    public var locationNote: String?
    public var match: PrayerTimesCalculator.MethodMatch?
    public var calendarAccess: String
    public var remindersAccess: String
    public var calendars: [AlarmsSource]
    public var reminderLists: [AlarmsSource]
    /// Wave W11: `IPhoneAlarmLayer.line`, built by the app from what it scheduled.
    public var iphoneLine: String? = nil

    public init(now: Date, calendar: Calendar, sample: Bool, settings: AlarmsSettings, normal: NormalWakeInput,
                plan: AlarmPlan, finished: [String: String], slot: StrapSlotState, slotConfirmedAt: Date?,
                lastSlotResult: String?, rings: [String: RingState], awakeNotes: [String: String],
                imUpAskedFor: String?, connected: Bool, log: [AlarmLogLine], locationNote: String?,
                match: PrayerTimesCalculator.MethodMatch?, calendarAccess: String, remindersAccess: String,
                calendars: [AlarmsSource], reminderLists: [AlarmsSource]) {
        self.now = now
        self.calendar = calendar
        self.sample = sample
        self.settings = settings
        self.normal = normal
        self.plan = plan
        self.finished = finished
        self.slot = slot
        self.slotConfirmedAt = slotConfirmedAt
        self.lastSlotResult = lastSlotResult
        self.rings = rings
        self.awakeNotes = awakeNotes
        self.imUpAskedFor = imUpAskedFor
        self.connected = connected
        self.log = log
        self.locationNote = locationNote
        self.match = match
        self.calendarAccess = calendarAccess
        self.remindersAccess = remindersAccess
        self.calendars = calendars
        self.reminderLists = reminderLists
    }
}

public enum AlarmsPresenter {
    public static let reliability = [
        "Reliable: the iPhone alarm (AlarmKit) rings through Silent and Focus even when this app is closed — the Fajr "
            + "wake's at its latest time + 3 min, the normal wake's at its time (smart wake), timers and alarms 1 min "
            + "after theirs.",
        "Experimental: the strap's own alarm (slot 1) holds the next alarm's latest time and fires on the strap's clock "
            + "with no phone. One firing was seen on MG firmware 50.41; none has been shown on 50.42 yet. Off the wrist "
            + "it reportedly does not fire.",
        "Best-effort: the buzz at a light-sleep moment, the repeat buzzes and the awake check need this app running "
            + "(Bluetooth keeps it alive in the background) and the strap connected. Movement reaches the phone with the "
            + "strap's history, pulled every few minutes, so \"awake\" can lag 3–5 min.",
        "Every wake alarm buzzes until you double-tap the strap or silence it from the phone. A double-tap never counts as "
            + "awake (it can be a reflex).",
        "Calendar and Reminders buzz only while the app runs and the strap is connected; the app only reads them.",
    ]

    public static func make(_ i: AlarmsInput) -> AlarmsState {
        let cal = i.calendar
        let hm = { (d: Date) in MGFormat.time(d, calendar: cal) }
        let day = { (d: Date) in MGFormat.shortDate(d, calendar: cal) }
        let finishedIds = Set(i.finished.keys)
        let s = i.settings

        // Ringing: an occurrence whose window is open (or that vibrated) and that has not finished.
        var ringing: AlarmsState.Ringing?
        if let o = i.plan.occurrences.first(where: { o in
            !finishedIds.contains(o.id) && o.windowStart <= i.now
                && (o.isWake || i.rings[o.id]?.lastVibration != nil)
        }) {
            let st = i.rings[o.id]
            var parts: [String] = []
            let n = (st?.buzzes.count ?? 0)
            if n > 0 { parts.append("\(n) buzz\(n == 1 ? "" : "es"), last \(hm(st!.buzzes.last!))") }
            if let f = st?.strapFiredAt { parts.append("strap alarm fired \(hm(f))") }
            if parts.isEmpty {
                parts.append(i.now < o.latest ? "window open until \(hm(o.latest))" : "latest time \(hm(o.latest)) passed")
            }
            if let note = i.awakeNotes[o.id] { parts.append(note) }
            if let taps = st?.doubleTaps.count, taps > 0 { parts.append("\(taps) double-tap\(taps == 1 ? "" : "s") (not counted)") }
            if !i.connected { parts.append("strap not connected") }
            ringing = AlarmsState.Ringing(id: o.id, title: o.label, detail: parts.joined(separator: " · "), locked: o.locked,
                                          askConfirm: i.imUpAskedFor == o.id, isWake: o.isWake)
        }

        let next: String
        if let o = i.plan.nextDue(after: i.now, finished: finishedIds) {
            next = "Next: \(o.label) · \(day(o.latest)) " + (o.windowStart < o.latest ? MGFormat.timeRange(o.windowStart, o.latest, calendar: cal) : hm(o.latest))
        } else {
            next = "No alarm planned in the next 7 days."
        }

        var slot: String
        if !s.strapSlotOn {
            slot = "Strap alarm off: the strap buzzes only while this app runs; the iPhone alarm is the backstop."
        } else if let a = i.slot.armedFor, a > i.now {
            slot = "Strap alarm (slot 1) set for \(day(a)) \(hm(a))"
            if let c = i.slotConfirmedAt { slot += " — the strap confirmed it at \(hm(c))" }
        } else {
            slot = "Strap alarm not set" + (i.lastSlotResult.map { " — \($0)" } ?? (i.connected ? "." : " (strap not connected)."))
        }

        // Fajr today / next
        var fajrToday: String?
        if let f = i.plan.occurrences.first(where: { $0.kind == .fajr && $0.latest > i.now && !finishedIds.contains($0.id) }),
           let fajr = f.fajr, let sunrise = f.sunrise {
            fajrToday = "\(day(f.latest)): Fajr \(hm(fajr)) · sunrise \(hm(sunrise)) (\(s.fajr.method.title)) → wake window "
                + "\(MGFormat.timeRange(f.windowStart, f.latest, calendar: cal))"
                + (f.backstopAt.map { ", iPhone alarm \(hm($0))" } ?? "")
        }
        let today = LocalDay(date: i.now, calendar: cal)
        let soon = Set([today.iso, today.adding(days: 1).iso])
        let fajrNotes = i.plan.refusals.filter { $0.target == .fajr && soon.contains($0.day) }.map { "\($0.day): \($0.reason)" }
        let normalNotes = i.plan.refusals.filter { $0.target == .normal && soon.contains($0.day) }.map { "\($0.day): \($0.reason)" }

        let upcoming = i.plan.occurrences.filter { $0.latest > i.now && !finishedIds.contains($0.id) }.prefix(10).map { o in
            var d: [String] = [o.windowStart < o.latest ? MGFormat.timeRange(o.windowStart, o.latest, calendar: cal) : hm(o.latest)]
            if o.strapBuzz {
                d.append("\(o.pulses) pulse\(o.pulses == 1 ? "" : "s")" + (o.isWake
                    ? ", again every \(max(1, o.repeatEveryMinutes)) min until you double-tap the strap" : ""))
            } else {
                d.append("no strap buzz")
            }
            if let b = o.backstopAt { d.append("iPhone \(hm(b))") } else if o.kind == .normal { d.append("iPhone: smart wake") }
            return AlarmsState.Row(id: o.id, title: "\(day(o.latest)) · \(o.label)", detail: d.joined(separator: " · "))
        }
        var skipped = i.plan.skipped.filter { k, _ in
            soon.contains(String(k.split(separator: ":").last ?? ""))
        }.map { AlarmsState.Row(id: "skip:" + $0.key, title: label(forId: $0.key), detail: $0.value) }
        skipped += i.finished.filter { k, _ in soon.contains(String(k.split(separator: ":").last ?? "")) || k.hasPrefix("timer:") }
            .map { AlarmsState.Row(id: "done:" + $0.key, title: label(forId: $0.key), detail: $0.value) }
        skipped.sort { $0.id < $1.id }

        let location: String
        if let l = s.location {
            location = (l.name ?? "Saved location") + String(format: " · %.2f, %.2f", l.coordinates.latitude,
                                                             l.coordinates.longitude) + " · read \(day(l.at))"
                + (i.locationNote.map { " — \($0)" } ?? "")
        } else {
            location = i.locationNote ?? "No location yet."
        }

        var matchText: String?
        var matchMethod: PrayerMethod?
        if let m = i.match {
            if let b = m.best {
                matchMethod = b.method
                matchText = "\(b.method.title) gives Fajr \(hm(b.fajr)) (\(String(format: "%+.0f", b.minutesOff)) min) — "
                    + (b.method == s.fajr.method ? "already in use." : "tap Use it.")
            } else {
                let close = m.fits.prefix(3).map { "\($0.method.title) \(hm($0.fajr))" }.joined(separator: ", ")
                matchText = "No standard method is within \(Int(m.toleranceMinutes)) min here. Closest: \(close). "
                    + "Check the location, or use Fajr adjust."
            }
        }

        let overrides = s.overrides.sorted { $0.firstDay != $1.firstDay ? $0.firstDay < $1.firstDay : $0.createdAt < $1.createdAt }.map { o in
            let span: String
            if let first = LocalDay(iso: o.firstDay), let last = o.lastDay.flatMap(LocalDay.init(iso:)) {
                let a = MGFormat.shortDate(first.start(in: cal.timeZone).addingTimeInterval(43_200), calendar: cal)
                let b = MGFormat.shortDate(last.start(in: cal.timeZone).addingTimeInterval(43_200), calendar: cal)
                span = o.days == 1 ? a : "\(a) – \(b)"
            } else {
                span = o.firstDay
            }
            return AlarmsState.Row(id: o.id.uuidString, title: "\(targetName(o.target, s)) · \(actionWords(o.action))",
                                   detail: span)
        }

        let timers = s.timers.filter { $0.fireAt > i.now.addingTimeInterval(-3600) }.sorted { $0.fireAt < $1.fireAt }.map { t in
            AlarmsState.Row(id: t.id.uuidString, title: "\(t.label.isEmpty ? "Timer" : t.label) · \(t.minutes) min",
                            detail: t.fireAt > i.now ? "buzzes \(hm(t.fireAt)) (\(MGFormat.countdown(to: t.fireAt, from: i.now)))"
                                : "rang \(hm(t.fireAt))")
        }

        let log = i.log.sorted { $0.at > $1.at }.prefix(20).map {
            AlarmsState.Row(id: $0.id, title: "\(day($0.at)) \(hm($0.at))", detail: $0.text)
        }

        let weekly = (1...7).map { WeekdayWake(weekday: $0, time: i.normal.weekly[$0]) }
        var state = AlarmsState(
            sample: i.sample, settings: s, normalOn: i.normal.on, normalWeekly: weekly,
            normalWindowMinutes: i.normal.windowMinutes, ringing: ringing, next: next, strapSlot: slot,
            fajrToday: fajrToday, fajrNotes: fajrNotes, normalNotes: normalNotes, upcoming: Array(upcoming),
            skipped: skipped, location: location, match: matchText, matchMethod: matchMethod, overrides: overrides,
            custom: s.custom.sorted { $0.minutes < $1.minutes }, timers: timers, log: Array(log),
            calendarAccess: i.calendarAccess, remindersAccess: i.remindersAccess,
            calendars: i.calendars.map { AlarmsState.Source(id: $0.id, title: $0.title,
                                                             picked: s.calendar.calendarIds.contains($0.id)) },
            reminderLists: i.reminderLists.map { AlarmsState.Source(id: $0.id, title: $0.title,
                                                                     picked: s.calendar.reminderListIds.contains($0.id)) },
            reliability: reliability)
        state.iphoneLine = i.iphoneLine
        return state
    }

    /// The alarm chip on Today: the next alarm's time ("Fajr 05:32"), or nil when none is planned within 24 h.
    public static func chip(plan: AlarmPlan, finished: Set<String>, now: Date, calendar: Calendar) -> String? {
        guard let o = plan.nextDue(after: now, finished: finished),
              o.latest.timeIntervalSince(now) < 24 * 3600 else { return nil }
        let name = o.kind == .fajr ? "Fajr" : (o.kind == .normal ? "Wake" : o.label)
        return "\(name) \(MGFormat.time(o.windowStart, calendar: calendar))"
    }

    static func label(forId id: String) -> String {
        if id.hasPrefix("fajr:") { return "Fajr wake " + id.dropFirst(5) }
        if id.hasPrefix("normal:") { return "Wake " + id.dropFirst(7) }
        if id.hasPrefix("timer:") { return "Timer" }
        return "Alarm " + (id.split(separator: ":").last.map(String.init) ?? "")
    }

    static func targetName(_ t: AlarmTarget, _ s: AlarmsSettings) -> String {
        switch t {
        case .fajr: return "Fajr wake"
        case .normal: return "Wake"
        case .custom(let id): return s.custom.first { $0.id == id }?.label ?? "Alarm"
        }
    }

    static func actionWords(_ a: OverrideAction) -> String {
        switch a {
        case .off: return "off"
        case .on: return "on"
        case .time(let m): return "at " + ClockText.hm(hour: m / 60, minute: m % 60)
        case .fajrWindow(let b, let m): return "\(b) min before Fajr – \(m) min before sunrise"
        }
    }
}
