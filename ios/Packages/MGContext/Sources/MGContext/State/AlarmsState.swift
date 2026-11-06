import Foundation

/// The alarm page (added 2026-10-11). Built by `AlarmsPresenter` from `AlarmsInput`; drawn by UI/Alarms/AlarmsView.
public struct AlarmsState: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String?

        public init(id: String, title: String, detail: String? = nil) {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    /// An alarm that is ringing (or whose window is open) right now.
    public struct Ringing: Equatable, Sendable {
        public var id: String
        public var title: String
        public var detail: String
        /// Fajr: harder locked ("I'm up" needs a second tap).
        public var locked: Bool
        /// The first "I'm up" was tapped: show "Yes, I'm up for Fajr".
        public var askConfirm: Bool
        /// Wake alarms stop only on awake evidence / "I'm up"; others have "Stop".
        public var isWake: Bool

        public init(id: String, title: String, detail: String, locked: Bool, askConfirm: Bool, isWake: Bool) {
            self.id = id
            self.title = title
            self.detail = detail
            self.locked = locked
            self.askConfirm = askConfirm
            self.isWake = isWake
        }
    }

    public struct Source: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var picked: Bool

        public init(id: String, title: String, picked: Bool) {
            self.id = id
            self.title = title
            self.picked = picked
        }
    }

    public var sample: Bool
    public var settings: AlarmsSettings
    /// The normal wake (shared with Tonight's smart wake).
    public var normalOn: Bool
    public var normalWeekly: [WeekdayWake]
    public var normalWindowMinutes: Int
    public var ringing: Ringing?
    public var next: String
    public var strapSlot: String
    public var fajrToday: String?
    public var fajrNotes: [String]
    public var normalNotes: [String]
    public var upcoming: [Row]
    public var skipped: [Row]
    public var location: String
    public var match: String?
    public var matchMethod: PrayerMethod?
    public var overrides: [Row]
    public var custom: [CustomAlarm]
    public var timers: [Row]
    public var log: [Row]
    public var calendarAccess: String
    public var remindersAccess: String
    public var calendars: [Source]
    public var reminderLists: [Source]
    public var reliability: [String]
    /// Wave W11: which iPhone layer is armed (AlarmKit / notification) and AlarmKit's own reason when it refused.
    public var iphoneLine: String? = nil

    public init(sample: Bool, settings: AlarmsSettings, normalOn: Bool, normalWeekly: [WeekdayWake],
                normalWindowMinutes: Int, ringing: Ringing?, next: String, strapSlot: String, fajrToday: String?,
                fajrNotes: [String], normalNotes: [String], upcoming: [Row], skipped: [Row], location: String,
                match: String?, matchMethod: PrayerMethod?, overrides: [Row], custom: [CustomAlarm], timers: [Row],
                log: [Row], calendarAccess: String, remindersAccess: String, calendars: [Source],
                reminderLists: [Source], reliability: [String]) {
        self.sample = sample
        self.settings = settings
        self.normalOn = normalOn
        self.normalWeekly = normalWeekly
        self.normalWindowMinutes = normalWindowMinutes
        self.ringing = ringing
        self.next = next
        self.strapSlot = strapSlot
        self.fajrToday = fajrToday
        self.fajrNotes = fajrNotes
        self.normalNotes = normalNotes
        self.upcoming = upcoming
        self.skipped = skipped
        self.location = location
        self.match = match
        self.matchMethod = matchMethod
        self.overrides = overrides
        self.custom = custom
        self.timers = timers
        self.log = log
        self.calendarAccess = calendarAccess
        self.remindersAccess = remindersAccess
        self.calendars = calendars
        self.reminderLists = reminderLists
        self.reliability = reliability
    }
}
