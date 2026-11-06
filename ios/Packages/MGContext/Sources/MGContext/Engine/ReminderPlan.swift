import Foundation
import MGDomain

/// The reminders the app posts by itself (wave 2, 2026-10-11; audit §3: the medication and caffeine-limit categories had
/// no sender and the wind-down toggle was read by nothing). Pure: which notification, when, and its words; the app's
/// NotifyCenter then applies quiet hours, the daily cap and the strap's "asleep" spans (NotifyPolicy), so Mo's quiet
/// hours always hold. Each reminder has a stable id per occurrence and a `slot` ("med|meda|2026-10-11|07:15"): the app
/// posts an id once, and withdraws the old id when a slot's time moves (a new bedtime moves the wind-down).
public struct PlannedReminder: Equatable, Sendable {
    public enum Kind: String, Sendable { case medication, caffeineLimit, windDown, stressSummary }

    public var kind: Kind
    /// The notification request id.
    public var id: String
    /// What occurrence this is (kind, schedule, day, time) — one live id per slot.
    public var slot: String
    public var at: Date
    /// After this it is pointless.
    public var expiresAt: Date
    public var title: String
    public var body: String
    /// Medication only: the schedule's name and id (the TOOK / SKIP buttons log against them).
    public var name: String?
    public var scheduleId: String?

    public init(kind: Kind, id: String, slot: String, at: Date, expiresAt: Date, title: String, body: String,
                name: String? = nil, scheduleId: String? = nil) {
        self.kind = kind
        self.id = id
        self.slot = slot
        self.at = at
        self.expiresAt = expiresAt
        self.title = title
        self.body = body
        self.name = name
        self.scheduleId = scheduleId
    }
}

public enum ReminderPlan {
    /// A dose logged this long before the scheduled time counts as that dose (taken early).
    public static let earlyWindow: TimeInterval = 2 * 3600
    /// A medication reminder is useful for this long after its time.
    public static let medicationLifetime: TimeInterval = 3 * 3600
    /// UX-SPEC §8 WindDownToggle: "reminder at B − 60 min".
    public static let windDownBefore: TimeInterval = 3600
    /// T57: medication times are handed to iOS this many days ahead (today included), so they still fire when the app
    /// is not opened for a day or two (iOS keeps at most 64 pending requests; 3 days of a few doses stays far below).
    public static let medicationDays = 3
    /// T31: the daily stress summary goes out at 5:00 PM local (a default, switchable in Settings) and is
    /// useful for 3 hours after.
    public static let stressSummaryHour = 17
    public static let stressSummaryLifetime: TimeInterval = 3 * 3600

    /// - schedules: Settings › Medications (`reminder` false = off; nil counts as on, as the editor's default).
    /// - events: today's and yesterday's log (medication doses, caffeine).
    /// - bedtime: tonight's B (the context anchors).
    /// - caffeineCutoff: today's G-CAFF read member (`caffeine_cutoff`, unix s); nil = none.
    /// - stressToday: today's daytime stress (`stress`, ALG-123:daytime, 0–3, note says band and peak); nil or no value
    ///   = no summary. The id carries the score, so a changed score replaces the waiting notification.
    public static func plan(now: Date, calendar: Calendar, schedules: [MedSchedule], events: [EventRecord],
                            windDownOn: Bool, bedtime: Date, caffeineCutoff: Date?, limitMg: Double?,
                            stressSummaryOn: Bool = true, stressToday: Metric? = nil) -> [PlannedReminder] {
        var out: [PlannedReminder] = []
        let today = calendar.startOfDay(for: now)
        let horizon = (0..<medicationDays).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }

        // medication: the next `medicationDays` days' times still ahead (so iOS holds them even if the app stays closed)
        // a stopped or as-needed entry of the medications list has no reminders (tracker #42, 2026-10-11)
        for s in schedules where (s.reminder ?? true) && s.asNeeded != true && s.stopped == nil {
            for dayStart in horizon {
                if let days = s.days, !days.contains(weekday(dayStart, calendar)) { continue }
                for hm in s.times ?? [] {
                    guard let at = time(hm, on: dayStart, calendar), at > now.addingTimeInterval(-60) else { continue }
                    if taken(s, near: at, events: events) { continue }
                    let dayISO = LocalDay(date: dayStart, calendar: calendar).iso
                    let slot = "med|\(s.id)|\(dayISO)|\(hm)"
                    out.append(PlannedReminder(
                        kind: .medication, id: "mg.med.\(s.id).\(dayISO).\(hm.replacingOccurrences(of: ":", with: ""))",
                        slot: slot, at: at, expiresAt: at.addingTimeInterval(medicationLifetime),
                        title: "\(PresenterSnapshot.scheduleTitle(s)) · \(MGFormat.time(at, calendar: calendar))",
                        body: "Your scheduled time. Took it or skip — one tap logs it. Reminder only, no dosing advice.",
                        name: s.name, scheduleId: s.id))
                }
            }
        }

        // caffeine limit (ALG-061): at today's cut-off, only on a day with caffeine logged
        let dayISO = LocalDay(date: now, calendar: calendar).iso
        let hadCaffeine = events.contains { e in
            guard !e.removed, e.at >= today, e.at <= now, case .substance(let f) = e.payload else { return false }
            return f.kind == .caffeine
        }
        if let cut = caffeineCutoff, hadCaffeine, cut > now.addingTimeInterval(-5 * 60), cut < bedtime {
            let limit = limitMg.map { "\(MGFormat.number($0, decimals: 0)) mg" } ?? "your limit"
            out.append(PlannedReminder(
                kind: .caffeineLimit, id: "mg.caffeine.\(dayISO).\(hhmm(cut, calendar))", slot: "caffeine|\(dayISO)",
                at: cut, expiresAt: bedtime,        // not `max(cut, now)`: a time that moves each refresh re-posts it (T57)
                title: "No more caffeine today",
                body: "Caffeine after \(MGFormat.time(cut, calendar: calendar)) would leave more than \(limit) in you at "
                    + "bedtime (\(MGFormat.time(bedtime, calendar: calendar))). ALG-061 cut-off."))
        }

        // wind-down: B − 60 min
        let wind = bedtime.addingTimeInterval(-windDownBefore)
        if windDownOn, wind > now.addingTimeInterval(-60), bedtime > now {
            let bedDay = LocalDay(date: bedtime, calendar: calendar).iso
            out.append(PlannedReminder(
                kind: .windDown, id: "mg.winddown.\(bedDay).\(hhmm(bedtime, calendar))", slot: "winddown|\(bedDay)",
                at: wind, expiresAt: bedtime,
                title: "Wind down from \(MGFormat.time(wind, calendar: calendar))",
                body: "Bed by \(MGFormat.time(bedtime, calendar: calendar)). Dim the lights, or breathe for 5 min."))
        }

        // stress summary (T31): 5:00 PM, only with a score for today; the time stays 5:00 PM so the app does not re-post it on
        // every refresh, and NotifyPolicy sends one whose time has passed at once until `expiresAt`
        if stressSummaryOn, let score = stressToday?.value, score.isFinite {
            let five = PhaseClock.instant(TimeOfDay(hour: stressSummaryHour, minute: 0), onDayOf: now, calendar: calendar)
            let until = five.addingTimeInterval(stressSummaryLifetime)
            if now < until {
                let shown = MGFormat.number(score, decimals: 1)
                let note = stressToday?.note.map { "Today's body arousal was \($0)." } ?? "Estimate, not WHOOP's number."
                out.append(PlannedReminder(
                    kind: .stressSummary, id: "mg.stress.\(dayISO).\(shown.replacingOccurrences(of: ".", with: ""))",
                    slot: "stress|\(dayISO)", at: five, expiresAt: until,
                    title: "Body arousal today: \(shown) of 3", body: note))
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    static func weekday(_ d: Date, _ calendar: Calendar) -> MedSchedule.Weekday {
        switch calendar.component(.weekday, from: d) {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        default: return .sat
        }
    }

    static func time(_ hm: String, on day: Date, _ calendar: Calendar) -> Date? {
        let p = hm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return PhaseClock.instant(TimeOfDay(hour: p[0], minute: p[1]), onDayOf: day, calendar: calendar)
    }

    static func hhmm(_ d: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// A dose of this schedule (by id or name, not skipped) logged from `earlyWindow` before the time on.
    static func taken(_ s: MedSchedule, near at: Date, events: [EventRecord]) -> Bool {
        events.contains { e in
            guard !e.removed, e.at >= at.addingTimeInterval(-earlyWindow), case .medication(let f) = e.payload else {
                return false
            }
            return (f.scheduleId == s.id || f.name == s.name) && f.status != .skipped
        }
    }
}
