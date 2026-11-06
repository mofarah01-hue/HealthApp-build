import Foundation
import MGDomain

// MARK: - Mo's alarms (added 2026-10-11)
//
// Mo's words (2026-10-11): "WHOOP alarms I set or timers with a WHOOP vibration … I pray Fajr so a Fajr-type wake-up,
// then I pray, I usually go back to sleep, then I wake up again — similar wake-up in a window (10 min before Fajr — need
// to be able to change; city; turn this on or off) and at the latest 15 min before it ends. Some alarms I do multiple if
// it doesn't detect I'm moving — for all wake-up ones, scheduled alarms or custom — on/off or a one-day or two-day or
// week-long different setting. Two total wake-ups: Fajr and normal wake-up. Fajr is harder locked than normal. If it
// detects I stay awake, the second alarm never fires — we'll use motion; the ability to turn that feature on or off.
// Other alarms/timers, maybe reminder or calendar vibrations."
//
// Everything here is plain data, stored as one JSON document (the app's kv key `AlarmsSettings.storeKey`). Decoding is
// field-by-field tolerant so a later build can add fields without losing what an earlier build stored.

/// Calendar weekday numbers, 1 = Sunday … 7 = Saturday (the same numbering as AppSettings.latestWakeMinutes).
public typealias WeekdayNumber = Int

public enum AlarmKind: String, Codable, Equatable, Hashable, Sendable {
    case fajr, normal, custom, timer
}

/// The Fajr wake: a window from `minutesBeforeFajr` before Fajr to `minutesBeforeSunrise` before sunrise, at Mo's
/// location, with the method he follows. "Harder locked": re-buzzes every `repeatEveryMinutes` until awake evidence
/// (a double-tap alone never counts), the iPhone backstop cannot be switched off, and "I'm up" needs a second tap.
public struct FajrWakeSettings: Codable, Equatable, Sendable {
    public var on: Bool = false
    public var weekdays: Set<WeekdayNumber> = Set(1...7)
    public var minutesBeforeFajr: Int = 10
    public var minutesBeforeSunrise: Int = 15
    public var method: PrayerMethod = .northAmerica
    /// Mo's own fine-tune on top of the method (adhan `adjustments.fajr`), minutes.
    public var fajrAdjustMinutes: Int = 0
    public var pulses: Int = 8
    public var repeatEveryMinutes: Int = 2
    /// The iPhone alarm (AlarmKit) rings this long after the latest time.
    public var backstopDelayMinutes: Int = 3

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FajrWakeSettings()
        on = c.tolerant(.on, d.on)
        weekdays = c.tolerant(.weekdays, d.weekdays)
        minutesBeforeFajr = c.tolerant(.minutesBeforeFajr, d.minutesBeforeFajr)
        minutesBeforeSunrise = c.tolerant(.minutesBeforeSunrise, d.minutesBeforeSunrise)
        method = c.tolerant(.method, d.method)
        fajrAdjustMinutes = c.tolerant(.fajrAdjustMinutes, d.fajrAdjustMinutes)
        pulses = c.tolerant(.pulses, d.pulses)
        repeatEveryMinutes = c.tolerant(.repeatEveryMinutes, d.repeatEveryMinutes)
        backstopDelayMinutes = c.tolerant(.backstopDelayMinutes, d.backstopDelayMinutes)
    }
}

/// The normal wake's strap side. Its time, window and on/off are the existing smart wake's (Tonight's switch, the
/// per-weekday "must be up by" and the window minutes in AppSettings) — one source of truth; the iPhone ring stays
/// `SmartWakeController`'s. This adds the strap buzz, the strap slot, repeat-until-moving and the Fajr skip.
public struct NormalWakeSettings: Codable, Equatable, Sendable {
    public var strapOn: Bool = true
    public var repeatUntilMoving: Bool = true
    /// Skip the normal wake when motion/HR show Mo stayed up after the Fajr wake (Mo: "the ability to turn that
    /// feature on or off").
    public var skipIfAwakeAfterFajr: Bool = true
    public var pulses: Int = 8
    public var repeatEveryMinutes: Int = 3

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NormalWakeSettings()
        strapOn = c.tolerant(.strapOn, d.strapOn)
        repeatUntilMoving = c.tolerant(.repeatUntilMoving, d.repeatUntilMoving)
        skipIfAwakeAfterFajr = c.tolerant(.skipIfAwakeAfterFajr, d.skipIfAwakeAfterFajr)
        pulses = c.tolerant(.pulses, d.pulses)
        repeatEveryMinutes = c.tolerant(.repeatEveryMinutes, d.repeatEveryMinutes)
    }
}

/// A custom alarm: weekly on `weekdays`, or once on `day` when `weekdays` is empty.
public struct CustomAlarm: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    /// Minutes after local midnight.
    public var minutes: Int
    public var weekdays: Set<WeekdayNumber>
    /// "YYYY-MM-DD" for a one-off alarm (used only when `weekdays` is empty).
    public var day: String?
    public var on: Bool
    public var pulses: Int
    /// A wake alarm: re-buzz until awake evidence or acknowledgement; a double-tap does not count as awake.
    public var repeatUntilMoving: Bool
    public var phoneBackstop: Bool

    public init(id: UUID = UUID(), label: String, minutes: Int, weekdays: Set<WeekdayNumber> = [], day: String? = nil,
                on: Bool = true, pulses: Int = 4, repeatUntilMoving: Bool = false, phoneBackstop: Bool = true) {
        self.id = id
        self.label = label
        self.minutes = minutes
        self.weekdays = weekdays
        self.day = day
        self.on = on
        self.pulses = pulses
        self.repeatUntilMoving = repeatUntilMoving
        self.phoneBackstop = phoneBackstop
    }

    /// The id prefix of every occurrence of this alarm ("custom:<uuid>:<day>"); the planner builds the ids.
    public static func occurrencePrefix(id: UUID) -> String { "custom:\(id.uuidString):" }

    /// Whether `key` (an occurrence id, e.g. a backstop key or the strap slot's occurrence) belongs to the alarm `id`,
    /// on whatever day. Delete uses this so a backstop whose time already passed is still found (T152).
    public static func owns(_ key: String, id: UUID) -> Bool { key.hasPrefix(occurrencePrefix(id: id)) }

    /// A one-time alarm: no weekdays, one day.
    public var isOneTime: Bool { weekdays.isEmpty && day != nil }
}

/// The wheel/date pickers on the alarm screens use this locale so they show 12-hour AM/PM (T151); the previous
/// `en_GB` showed 24-hour "military" time.
public enum AlarmTimeLocale {
    public static let picker = Locale(identifier: "en_US")
}

/// A simple timer: buzz `pulses` at `startedAt + minutes`.
public struct AlarmTimer: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var minutes: Int
    public var startedAt: Date
    public var pulses: Int
    public var phoneBackstop: Bool

    public init(id: UUID = UUID(), label: String, minutes: Int, startedAt: Date, pulses: Int = 4,
                phoneBackstop: Bool = true) {
        self.id = id
        self.label = label
        self.minutes = minutes
        self.startedAt = startedAt
        self.pulses = pulses
        self.phoneBackstop = phoneBackstop
    }

    public var fireAt: Date { startedAt.addingTimeInterval(TimeInterval(minutes) * 60) }
}

/// What an override applies to.
public enum AlarmTarget: Codable, Equatable, Hashable, Sendable {
    case fajr
    case normal
    case custom(UUID)
}

/// What an override does for its days.
public enum OverrideAction: Codable, Equatable, Hashable, Sendable {
    case off
    /// On for these days even when the weekly schedule says off (uses the weekly time / window).
    case on
    /// Normal or custom: a different time (minutes after local midnight).
    case time(minutes: Int)
    /// Fajr: a different window.
    case fajrWindow(beforeFajr: Int, beforeSunrise: Int)
}

/// A one-day, two-day or week-long change (Mo: "on/off or a one-day or two-day or week-long different setting").
public struct AlarmOverride: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var target: AlarmTarget
    /// First wake day it covers, "YYYY-MM-DD".
    public var firstDay: String
    /// 1, 2 or 7.
    public var days: Int
    public var action: OverrideAction
    public var createdAt: Date

    public init(id: UUID = UUID(), target: AlarmTarget, firstDay: String, days: Int, action: OverrideAction,
                createdAt: Date) {
        self.id = id
        self.target = target
        self.firstDay = firstDay
        self.days = days
        self.action = action
        self.createdAt = createdAt
    }

    public static let allowedSpans = [1, 2, 7]

    public func covers(_ day: LocalDay) -> Bool {
        guard let first = LocalDay(iso: firstDay) else { return false }
        let k = first.days(to: day)
        return k >= 0 && k < max(1, days)
    }

    /// The last wake day it covers.
    public var lastDay: String? { LocalDay(iso: firstDay).map { $0.adding(days: max(1, days) - 1).iso } }
}

/// Calendar and Reminders buzz (read-only EventKit, best-effort: only while the app is awake).
public struct CalendarBuzzSettings: Codable, Equatable, Sendable {
    public var eventsOn: Bool = false
    public var remindersOn: Bool = false
    /// EKCalendar identifiers picked for events / for reminders.
    public var calendarIds: [String] = []
    public var reminderListIds: [String] = []
    public var pulses: Int = 2
    /// Buzz this many minutes before an event starts (0 = at the start). Reminders buzz at their due time.
    public var leadMinutes: Int = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CalendarBuzzSettings()
        eventsOn = c.tolerant(.eventsOn, d.eventsOn)
        remindersOn = c.tolerant(.remindersOn, d.remindersOn)
        calendarIds = c.tolerant(.calendarIds, d.calendarIds)
        reminderListIds = c.tolerant(.reminderListIds, d.reminderListIds)
        pulses = c.tolerant(.pulses, d.pulses)
        leadMinutes = c.tolerant(.leadMinutes, d.leadMinutes)
    }
}

/// The phone's location as last read (when-in-use permission), kept so Fajr works on offline days.
public struct SavedLocation: Codable, Equatable, Sendable {
    public var coordinates: PrayerCoordinates
    /// Reverse-geocoded place name, when the phone could get one ("Los Angeles").
    public var name: String?
    public var timeZoneId: String
    public var at: Date

    public init(coordinates: PrayerCoordinates, name: String?, timeZoneId: String, at: Date) {
        self.coordinates = coordinates
        self.name = name
        self.timeZoneId = timeZoneId
        self.at = at
    }
}

/// Everything on the alarm page.
public struct AlarmsSettings: Codable, Equatable, Sendable {
    public static let storeKey = "alarms.settings.v1"

    public var fajr = FajrWakeSettings()
    public var normal = NormalWakeSettings()
    public var custom: [CustomAlarm] = []
    public var timers: [AlarmTimer] = []
    public var overrides: [AlarmOverride] = []
    public var calendar = CalendarBuzzSettings()
    public var notifications = NotificationBuzzSettings()
    public var location: SavedLocation?
    /// Use the strap's own alarm (slot 1) as the app-dead fallback for the next due alarm. Experimental: one strap-driven
    /// wake was seen on MG fw 50.41.1.0 (noop #864), none shown on 50.42 — the iPhone alarm is the real backstop.
    public var strapSlotOn: Bool = true
    /// When Mo last changed anything here — the standing consent the strap write log records for alarm writes.
    public var consentAt: Date?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlarmsSettings()
        fajr = c.tolerant(.fajr, d.fajr)
        normal = c.tolerant(.normal, d.normal)
        custom = c.tolerant(.custom, d.custom)
        timers = c.tolerant(.timers, d.timers)
        overrides = c.tolerant(.overrides, d.overrides)
        calendar = c.tolerant(.calendar, d.calendar)
        notifications = c.tolerant(.notifications, d.notifications)
        location = try? c.decodeIfPresent(SavedLocation.self, forKey: .location)
        strapSlotOn = c.tolerant(.strapSlotOn, d.strapSlotOn)
        consentAt = try? c.decodeIfPresent(Date.self, forKey: .consentAt)
    }

    /// Drops timers and one-off custom alarms that ended more than a day ago, and overrides whose last day has passed.
    public mutating func prune(now: Date, calendar cal: Calendar) {
        let today = LocalDay(date: now, calendar: cal)
        timers.removeAll { now.timeIntervalSince($0.fireAt) > 86_400 }
        custom.removeAll { a in
            guard a.weekdays.isEmpty, let d = a.day.flatMap(LocalDay.init(iso:)) else { return false }
            return d < today.adding(days: -1)
        }
        overrides.removeAll { o in o.lastDay.flatMap(LocalDay.init(iso:)).map { $0 < today } ?? true }
    }

    /// Seconds after the alarm's time that a one-time alarm is kept so its own iPhone backstop can still ring and be
    /// cancelled by the normal tick (the backstop is 60 s after, or 180 s for "again until moving"), plus this grace.
    static let oneTimeGraceSeconds: TimeInterval = 120
    /// An unfinished one-time wake alarm is eventually removed from the list, but this never limits its buzz schedule.
    static let oneTimeUnfinishedCleanupSeconds: TimeInterval = 12 * 60 * 60

    /// T152: removes the one-time alarms (no weekdays, `on`) whose time, backstop and grace have all passed, and returns
    /// them. Without this a fired one-time alarm stayed on the list armed with a past time until `prune` dropped it a day
    /// later. An unfinished one-time wake alarm stays available to ring until `finished` holds its occurrence id, with a
    /// 12-hour list-cleanup limit after its fire time. That cleanup limit does not cap buzzing. Pure: the caller cancels
    /// the iPhone backstops and the strap slot of what is returned.
    @discardableResult
    public mutating func expireOneTime(now: Date, calendar cal: Calendar, finished: Set<String>) -> [CustomAlarm] {
        let today = LocalDay(date: now, calendar: cal)
        var gone: [CustomAlarm] = []
        custom.removeAll { a in
            guard a.on, a.isOneTime, let iso = a.day, let day = LocalDay(iso: iso) else { return false }
            // A later-day change on this alarm can make it fire again, so it stays.
            if overrides.contains(where: { o in
                o.target == .custom(a.id) && (LocalDay(iso: o.firstDay).map { $0 > day } ?? false)
                    && (o.lastDay.flatMap(LocalDay.init(iso:)).map { $0 >= today } ?? false)
            }) { return false }
            var minutes = a.minutes
            if case .time(let m)? = AlarmPlanner.override(.custom(a.id), day, overrides)?.action { minutes = m }
            guard let fire = AlarmPlanner.instant(day, minutes: minutes, cal) else { return false }
            let backstop: TimeInterval = a.phoneBackstop ? (a.repeatUntilMoving ? 180 : 60) : 0
            var settled = fire.addingTimeInterval(backstop + Self.oneTimeGraceSeconds)
            if a.repeatUntilMoving, !finished.contains(CustomAlarm.occurrencePrefix(id: a.id) + iso) {
                settled = fire.addingTimeInterval(Self.oneTimeUnfinishedCleanupSeconds)
            }
            guard now >= settled else { return false }
            gone.append(a)
            return true
        }
        return gone
    }
}

extension KeyedDecodingContainer {
    /// The stored value, or `fallback` when the key is missing or does not decode (tolerant settings decode).
    func tolerant<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
