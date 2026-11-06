import Foundation
import MGDomain

// MARK: - From settings to concrete alarm instants (added 2026-10-11)
//
// Pure: settings + the normal wake's inputs + now → every alarm occurrence of the next days, the refusals (a window
// that cannot work, no location …) and, through `StrapSlotPolicy` / `RingPolicy`, what the strap should be told.
// Precedence for a day: an override covering it (the newest one when several do) beats the weekly schedule; a master
// switch that is off beats both. Instants are absolute (`Date`), so a DST day changes the wall-clock labels, never the
// window's length.

/// The normal wake's time and window come from the existing smart wake settings (AppSettings): one source of truth.
public struct NormalWakeInput: Equatable, Sendable {
    /// Tonight's smart wake switch (AppSettings.smartWakeOn).
    public var on: Bool
    /// "Must be up by" per weekday (AppSettings.latestWake).
    public var weekly: [WeekdayNumber: TimeOfDay]
    /// AppSettings.wakeWindowMinutes (10…45).
    public var windowMinutes: Int

    public init(on: Bool, weekly: [WeekdayNumber: TimeOfDay], windowMinutes: Int) {
        self.on = on
        self.weekly = weekly
        self.windowMinutes = windowMinutes
    }
}

/// One alarm on one day.
public struct AlarmOccurrence: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// "fajr:2026-10-12", "normal:2026-10-12", "custom:<uuid>:2026-10-12", "timer:<uuid>".
    public var id: String
    public var kind: AlarmKind
    public var label: String
    /// The wake day, "YYYY-MM-DD".
    public var day: String
    /// When the smart window opens (custom alarms and timers: = `latest`).
    public var windowStart: Date
    /// The latest time: the strap's own alarm (slot 1) is armed for this instant.
    public var latest: Date
    /// This occurrence's own iPhone alarm (AlarmKit). nil for the normal wake — the smart wake controller owns its iPhone
    /// ring — and for a custom alarm / timer whose iPhone backstop Mo switched off.
    public var backstopAt: Date?
    public var repeatUntilMoving: Bool
    /// Fajr: harder locked (always repeats, the backstop cannot be switched off, "I'm up" needs a second tap).
    public var locked: Bool
    public var pulses: Int
    public var repeatEveryMinutes: Int
    /// The strap's own alarm (slot 1) may carry this occurrence's latest time.
    public var strapSlot: Bool
    /// The app buzzes the strap for it at all.
    public var strapBuzz: Bool
    public var fajr: Date?
    public var sunrise: Date?

    /// A wake alarm keeps re-buzzing until awake evidence or an acknowledgement; acknowledgement is never awake evidence.
    public var isWake: Bool { kind == .fajr || kind == .normal || repeatUntilMoving }
    public var repeats: Bool { isWake && (repeatUntilMoving || locked) }
}

/// An alarm that cannot be planned for a day, in words for the page.
public struct AlarmRefusal: Equatable, Hashable, Sendable {
    public var target: AlarmKind
    public var day: String
    public var reason: String

    public init(target: AlarmKind, day: String, reason: String) {
        self.target = target
        self.day = day
        self.reason = reason
    }
}

public struct AlarmPlan: Equatable, Sendable {
    /// Sorted by `latest`. Wake occurrences stay present after their latest time so they can keep ringing.
    public var occurrences: [AlarmOccurrence]
    public var refusals: [AlarmRefusal]
    /// Occurrences left out on purpose (an override, or "you stayed up after Fajr"), id → reason.
    public var skipped: [String: String]

    public init(occurrences: [AlarmOccurrence], refusals: [AlarmRefusal], skipped: [String: String]) {
        self.occurrences = occurrences
        self.refusals = refusals
        self.skipped = skipped
    }

    /// The first occurrence not finished whose latest is still ahead.
    public func nextDue(after now: Date, finished: Set<String> = []) -> AlarmOccurrence? {
        occurrences.first { $0.latest > now && !finished.contains($0.id) }
    }

    /// The normal wake planned for `day`, if any.
    public func normal(on day: String) -> AlarmOccurrence? {
        occurrences.first { $0.kind == .normal && $0.day == day }
    }
}

/// A Fajr window on one day.
public struct FajrWindow: Equatable, Sendable {
    public var fajr: Date
    public var sunrise: Date
    public var start: Date
    public var latest: Date
}

public enum AlarmPlanner {
    public static let pastGraceMinutes = 90
    public static let minuteRange = 0...120

    public static func plan(settings s: AlarmsSettings, normal: NormalWakeInput, now: Date, calendar cal: Calendar,
                            horizonDays: Int = 7, suppressed: [String: String] = [:]) -> AlarmPlan {
        var occ: [AlarmOccurrence] = []
        var refusals: [AlarmRefusal] = []
        var skipped: [String: String] = [:]
        let today = LocalDay(date: now, calendar: cal)
        for k in -1...max(0, horizonDays) {
            let day = today.adding(days: k)
            let weekday = Self.weekday(day, cal)
            // Fajr
            if s.fajr.on {
                let ov = override(.fajr, day, s.overrides)
                var before = s.fajr.minutesBeforeFajr
                var beforeSunrise = s.fajr.minutesBeforeSunrise
                var on = s.fajr.weekdays.contains(weekday)
                switch ov?.action {
                case .off?: on = false; skipped["fajr:\(day.iso)"] = "off for this day (your change)"
                case .on?: on = true
                case .fajrWindow(let b, let m)?: on = true; before = b; beforeSunrise = m
                case .time?, nil: break
                }
                if on {
                    switch fajrWindow(day: day, beforeFajr: before, beforeSunrise: beforeSunrise, method: s.fajr.method,
                                      fajrAdjustMinutes: s.fajr.fajrAdjustMinutes, location: s.location, calendar: cal) {
                    case .success(let w):
                        occ.append(AlarmOccurrence(
                            id: "fajr:\(day.iso)", kind: .fajr, label: "Fajr wake", day: day.iso, windowStart: w.start,
                            latest: w.latest,
                            backstopAt: w.latest.addingTimeInterval(TimeInterval(max(0, s.fajr.backstopDelayMinutes)) * 60),
                            repeatUntilMoving: true, locked: true, pulses: clampPulses(s.fajr.pulses),
                            repeatEveryMinutes: max(1, s.fajr.repeatEveryMinutes), strapSlot: s.strapSlotOn,
                            strapBuzz: true, fajr: w.fajr, sunrise: w.sunrise))
                    case .failure(let why):
                        refusals.append(AlarmRefusal(target: .fajr, day: day.iso, reason: why.text))
                    }
                }
            }
            // Normal wake (time and window from the smart wake settings)
            if normal.on {
                let ov = override(.normal, day, s.overrides)
                var minutes = normal.weekly[weekday].map { $0.hour * 60 + $0.minute }
                var on = minutes != nil
                switch ov?.action {
                case .off?: on = false; skipped["normal:\(day.iso)"] = "off for this day (your change)"
                case .on?:
                    on = true
                    if minutes == nil {
                        refusals.append(AlarmRefusal(target: .normal, day: day.iso, reason: "Your change turns the "
                            + "normal wake on, but this weekday has no wake time — set one, or change the time instead."))
                        on = false
                    }
                case .time(let m)?: on = true; minutes = m
                case .fajrWindow?, nil: break
                }
                if on, let m = minutes, let latest = instant(day, minutes: m, cal) {
                    let id = "normal:\(day.iso)"
                    if let why = suppressed[id] {
                        skipped[id] = why
                    } else {
                        let window = min(45, max(10, normal.windowMinutes))
                        occ.append(AlarmOccurrence(
                            id: id, kind: .normal, label: "Wake", day: day.iso,
                            windowStart: latest.addingTimeInterval(-TimeInterval(window) * 60), latest: latest,
                            backstopAt: nil, repeatUntilMoving: s.normal.repeatUntilMoving, locked: false,
                            pulses: clampPulses(s.normal.pulses), repeatEveryMinutes: max(1, s.normal.repeatEveryMinutes),
                            strapSlot: s.strapSlotOn && s.normal.strapOn, strapBuzz: s.normal.strapOn, fajr: nil,
                            sunrise: nil))
                    }
                }
            }
            // Custom alarms
            for a in s.custom where a.on {
                let ov = override(.custom(a.id), day, s.overrides)
                var on = a.weekdays.isEmpty ? a.day == day.iso : a.weekdays.contains(weekday)
                var minutes = a.minutes
                switch ov?.action {
                case .off?: on = false
                case .on?: on = true
                case .time(let m)?: on = true; minutes = m
                case .fajrWindow?, nil: break
                }
                guard on, let latest = instant(day, minutes: minutes, cal) else { continue }
                occ.append(AlarmOccurrence(
                    id: "custom:\(a.id.uuidString):\(day.iso)", kind: .custom, label: a.label.isEmpty ? "Alarm" : a.label,
                    day: day.iso, windowStart: latest, latest: latest,
                    backstopAt: a.phoneBackstop ? latest.addingTimeInterval(a.repeatUntilMoving ? 180 : 60) : nil,
                    repeatUntilMoving: a.repeatUntilMoving, locked: false, pulses: clampPulses(a.pulses),
                    repeatEveryMinutes: 1, strapSlot: s.strapSlotOn, strapBuzz: true, fajr: nil, sunrise: nil))
            }
        }
        for t in s.timers {
            occ.append(AlarmOccurrence(
                id: "timer:\(t.id.uuidString)", kind: .timer, label: t.label.isEmpty ? "Timer" : t.label,
                day: LocalDay(date: t.fireAt, calendar: cal).iso, windowStart: t.fireAt, latest: t.fireAt,
                backstopAt: t.phoneBackstop ? t.fireAt.addingTimeInterval(60) : nil, repeatUntilMoving: false,
                locked: false, pulses: clampPulses(t.pulses), repeatEveryMinutes: 3, strapSlot: s.strapSlotOn,
                strapBuzz: true, fajr: nil, sunrise: nil))
        }
        let horizonEnd = now.addingTimeInterval(TimeInterval(horizonDays + 1) * 86_400)
        let pastLimit = now.addingTimeInterval(-TimeInterval(pastGraceMinutes) * 60)
        occ = occ.filter { ($0.isWake || $0.latest >= pastLimit) && $0.latest <= horizonEnd }
        occ.sort { $0.latest != $1.latest ? $0.latest < $1.latest : $0.id < $1.id }
        let today0 = today.adding(days: 0)
        refusals = refusals.filter { (LocalDay(iso: $0.day) ?? today0) >= today0 }
        return AlarmPlan(occurrences: occ, refusals: refusals, skipped: skipped)
    }

    /// Why a Fajr window cannot be used, in words.
    public struct Refusal: Error, Equatable, Sendable {
        public let text: String
    }

    /// [Fajr − `beforeFajr`, sunrise − `beforeSunrise`] on `day` at the saved location.
    public static func fajrWindow(day: LocalDay, beforeFajr: Int, beforeSunrise: Int, method: PrayerMethod,
                                  fajrAdjustMinutes: Int, location: SavedLocation?, calendar cal: Calendar)
        -> Result<FajrWindow, Refusal> {
        guard let loc = location, loc.coordinates.isPlausible else {
            return .failure(Refusal(text: "No location yet: tap “Use my location” (it is kept for offline days)."))
        }
        guard minuteRange.contains(beforeFajr), minuteRange.contains(beforeSunrise) else {
            return .failure(Refusal(text: "The minutes before Fajr and before sunrise must each be 0–120."))
        }
        guard let t = PrayerTimesCalculator.fajrSunrise(year: day.year, month: day.month, day: day.day,
                                                        coordinates: loc.coordinates, method: method,
                                                        fajrAdjustMinutes: fajrAdjustMinutes) else {
            return .failure(Refusal(text: "No Fajr or sunrise at this location on \(day.iso) (the sun does not rise or "
                                    + "set normally there) — no Fajr wake."))
        }
        let start = t.fajr.addingTimeInterval(-TimeInterval(beforeFajr) * 60)
        let latest = t.sunrise.addingTimeInterval(-TimeInterval(beforeSunrise) * 60)
        let hm = { (d: Date) in MGFormat.time(d, calendar: cal) }
        if start >= latest {
            return .failure(Refusal(text: "Window inverted: it would open at \(hm(start)) (Fajr \(hm(t.fajr)) − "
                + "\(beforeFajr) min) but end at \(hm(latest)) (sunrise \(hm(t.sunrise)) − \(beforeSunrise) min). "
                + "Make one of the two smaller — not armed."))
        }
        if latest <= t.fajr {
            return .failure(Refusal(text: "The latest time \(hm(latest)) (sunrise \(hm(t.sunrise)) − \(beforeSunrise) "
                + "min) is not after Fajr \(hm(t.fajr)): you would be woken before Fajr begins. Make the minutes before "
                + "sunrise smaller — not armed."))
        }
        return .success(FajrWindow(fajr: t.fajr, sunrise: t.sunrise, start: start, latest: latest))
    }

    /// The override for `target` covering `day`; the newest one when several do.
    public static func override(_ target: AlarmTarget, _ day: LocalDay, _ all: [AlarmOverride]) -> AlarmOverride? {
        all.filter { $0.target == target && $0.covers(day) }
            .max { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    /// Calendar weekday (1 = Sunday) of a local day.
    public static func weekday(_ day: LocalDay, _ cal: Calendar) -> WeekdayNumber {
        cal.component(.weekday, from: day.start(in: cal.timeZone).addingTimeInterval(12 * 3600))
    }

    /// `day` at `minutes` after local midnight (wall clock). On a spring-forward day a missing time moves to the next
    /// valid one (Foundation's rule); on a fall-back day the first of the two instants is used.
    public static func instant(_ day: LocalDay, minutes: Int, _ cal: Calendar) -> Date? {
        guard (0..<(24 * 60)).contains(minutes) else { return nil }
        return cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: minutes / 60,
                                             minute: minutes % 60))
    }

    static func clampPulses(_ n: Int) -> Int { min(8, max(1, n)) }
}

// MARK: - The strap's own alarm (slot 1)

/// What slot 1 holds, as far as the app knows.
public struct StrapSlotState: Codable, Equatable, Sendable {
    public var occurrenceId: String?
    /// The phone-time instant armed (the link converts to the strap clock).
    public var armedFor: Date?
    public var armedAt: Date?
    /// The connection it was armed on (the app counts handshakes): a new connection re-arms (clock drift, RTC loss).
    public var connection: Int?

    public init(occurrenceId: String? = nil, armedFor: Date? = nil, armedAt: Date? = nil, connection: Int? = nil) {
        self.occurrenceId = occurrenceId
        self.armedFor = armedFor
        self.armedAt = armedAt
        self.connection = connection
    }
}

public enum StrapSlotAction: Equatable, Sendable {
    case keep
    case arm(AlarmOccurrence)
    case disable(reason: String)
}

/// Slot 1 carries the latest time of the NEXT due occurrence that allows it, re-armed on every connection; it is cleared
/// only when nothing is due (an occurrence leaves the list only on awake evidence, a stop, an override or a skip).
public enum StrapSlotPolicy {
    /// SET needs a time strictly later than the strap's second; MGBLE refuses under 10 s, the plan keeps 30 s.
    public static let minLead: TimeInterval = 30

    public static func decide(plan: AlarmPlan, finished: Set<String>, slot: StrapSlotState, connection: Int, now: Date,
                              enabled: Bool) -> StrapSlotAction {
        let target = enabled ? plan.occurrences.first {
            $0.strapSlot && !finished.contains($0.id) && $0.latest.timeIntervalSince(now) >= minLead
        } : nil
        guard let t = target else {
            if let a = slot.armedFor, a > now {
                return .disable(reason: enabled ? "nothing due that uses the strap alarm" : "strap alarm switched off")
            }
            return .keep
        }
        if slot.occurrenceId == t.id, slot.armedFor == t.latest, slot.connection == connection { return .keep }
        return .arm(t)
    }
}

// MARK: - Buzzing one occurrence

/// What happened so far for one occurrence (persisted, so an app restart mid-alarm carries on).
public struct RingState: Codable, Equatable, Sendable {
    public var occurrenceId: String
    /// App buzzes sent (write acknowledged).
    public var buzzes: [Date] = []
    /// The strap's own alarm fired (event 57; or 60 within a minute of the armed time).
    public var strapFiredAt: Date?
    /// The light-sleep moment inside the window (smart wake), when one was seen.
    public var smartAt: Date?
    public var awakeAt: Date?
    public var awakeWhy: String?
    /// A tap / Silence stopped it (D-031: any alarm, wake included - which does NOT make it awake): a strap double-tap or Stop.
    public var acknowledgedAt: Date?
    /// Double-taps seen while it rang (shown; never awake evidence).
    public var doubleTaps: [Date] = []
    public var finishedAt: Date?
    public var finishReason: String?

    public init(occurrenceId: String) {
        self.occurrenceId = occurrenceId
    }

    /// The last time the strap vibrated for this occurrence (an app buzz or the strap's own alarm).
    public var lastVibration: Date? { [buzzes.last, strapFiredAt].compactMap { $0 }.max() }
}

public enum RingAction: Equatable, Sendable {
    case wait
    case buzz(pulses: Int, why: String)
    case finish(String)
}

/// When to buzz. Rules (Mo 2026-10-11 + noop PROTOCOL_ALARMS.md):
/// - a wake alarm stops on awake evidence, or on a tap / Silence (`acknowledgedAt`, D-031; never counted as awake);
/// - in the window: one buzz at the light-sleep moment, if one was seen;
/// - at the latest: when slot 1 holds this time, wait `strapGrace` for the strap's own alarm first;
/// - never buzz within `strapRun` after, or `preStrapQuiet` before, the strap's own alarm (noop PROTOCOL_ALARMS.md:
///   "While a haptic is active, a newly due alarm can be cleared without starting a second vibration");
/// - after the latest time, every wake alarm repeats every `repeatEveryMinutes` until acknowledged or awake; alarms with
///   repeat-until-moving enabled may also repeat inside their smart window;
/// - a timer or plain custom alarm buzzes once.
public enum RingPolicy {
    /// Wait this long after the latest time for the strap's own alarm (event 57) before the app buzzes.
    public static let strapGrace: TimeInterval = 25
    /// The strap's alarm runs ~24-30 s (OpenStrap commands.dart: ~24 s, ended by event 100; repeat 7, duration 30 s).
    public static let strapRun: TimeInterval = 90
    /// No app buzz this close before slot 1's time: a vibration in progress can make the due alarm clear silently.
    public static let preStrapQuiet: TimeInterval = 45

    public static func next(_ o: AlarmOccurrence, _ st: RingState, now: Date, slotHoldsThis: Bool) -> RingAction {
        if let why = st.finishReason, st.finishedAt != nil { return .finish(why) }
        if o.isWake, st.awakeAt != nil { return .finish("awake") }
        // D-031 (2026-10-12): a double tap / Silence stops ANY alarm, wake included (awake evidence above still wins and
        // a tap never sets awakeAt). Before this, the wake alarms ignored it.
        if st.acknowledgedAt != nil { return .finish("stopped") }
        if !o.strapBuzz { return now >= o.latest ? .finish("no strap buzz for this alarm") : .wait }
        if now < o.windowStart { return .wait }
        if let fired = st.strapFiredAt, now < fired.addingTimeInterval(strapRun) { return .wait }
        if slotHoldsThis, now < o.latest, o.latest.timeIntervalSince(now) < preStrapQuiet { return .wait }
        let latestDone = st.strapFiredAt != nil || st.buzzes.contains { $0 >= o.latest }
        if !latestDone && now >= o.latest {
            if slotHoldsThis && now < o.latest.addingTimeInterval(strapGrace) { return .wait }
            return .buzz(pulses: o.pulses, why: "latest time")
        }
        if st.buzzes.isEmpty && st.strapFiredAt == nil {
            return st.smartAt != nil && now < o.latest ? .buzz(pulses: o.pulses, why: "light sleep in the window") : .wait
        }
        guard o.isWake else { return latestDone ? .finish("buzzed") : .wait }
        if !o.repeats && now < o.latest { return .wait }
        let repeatSeconds = TimeInterval(max(1, o.repeatEveryMinutes)) * 60
        if let last = st.lastVibration, now >= last.addingTimeInterval(repeatSeconds) {
            return .buzz(pulses: o.pulses, why: "no movement yet")
        }
        return .wait
    }
}
