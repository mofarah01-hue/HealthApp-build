import Foundation

// MARK: - Calendar and Reminders buzz (added 2026-10-11; best-effort)
//
// Mo: "maybe reminder or calendar vibrations — integrate the calendar from my personal-operating-system dashboard and
// reminders from the iPhone". The app reads iOS Calendar and Reminders READ-ONLY (EventKit; the app target never
// saves or removes — tools/check_strap_safety.py rule EVENTKIT-WRITE) and buzzes the strap when an event in a picked
// calendar starts, or a reminder in a picked list is due. His dashboard reaches iOS Calendar as a subscribed ICS calendar
// (Settings › Calendar › Accounts › Add Subscribed Calendar). Best-effort: it buzzes only while the app is running
// (the BLE link keeps it alive in the background, but iOS may still suspend it) and the strap is connected.

public struct CalendarBuzzItem: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case event, reminder
    }

    public var id: String
    public var title: String
    /// Event start, or reminder due time.
    public var at: Date
    public var source: Source
    /// The EKCalendar identifier (a calendar, or a reminders list).
    public var containerId: String
    public var allDay: Bool

    public init(id: String, title: String, at: Date, source: Source, containerId: String, allDay: Bool) {
        self.id = id
        self.title = title
        self.at = at
        self.source = source
        self.containerId = containerId
        self.allDay = allDay
    }

    /// Buzzed once per item AND time: a moved event buzzes again at its new time.
    public var key: String { "\(source.rawValue):\(id):\(Int64(at.timeIntervalSince1970))" }
}

public enum CalendarBuzzPlanner {
    /// An item is still buzzed this long after its time (the app may wake a little late); later than that it is let go.
    public static let lateWindow: TimeInterval = 90

    public static func fireAt(_ item: CalendarBuzzItem, settings: CalendarBuzzSettings) -> Date {
        item.source == .event ? item.at.addingTimeInterval(-TimeInterval(max(0, settings.leadMinutes)) * 60) : item.at
    }

    /// Items to buzz now: in a picked calendar / list with that kind switched on, not all-day, not buzzed yet, and
    /// due within the last `lateWindow` seconds.
    public static func due(_ items: [CalendarBuzzItem], settings: CalendarBuzzSettings, now: Date,
                           buzzed: Set<String>) -> [CalendarBuzzItem] {
        items.filter { item in
            guard selected(item, settings), !item.allDay, !buzzed.contains(item.key) else { return false }
            let at = fireAt(item, settings: settings)
            return at <= now && now.timeIntervalSince(at) <= lateWindow
        }
        .sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
    }

    /// The next instant something is due (so the app can wake its timer then), or nil.
    public static func nextFire(_ items: [CalendarBuzzItem], settings: CalendarBuzzSettings, now: Date,
                                buzzed: Set<String>) -> Date? {
        items.filter { selected($0, settings) && !$0.allDay && !buzzed.contains($0.key) }
            .map { fireAt($0, settings: settings) }
            .filter { $0 > now }
            .min()
    }

    static func selected(_ item: CalendarBuzzItem, _ s: CalendarBuzzSettings) -> Bool {
        switch item.source {
        case .event: return s.eventsOn && s.calendarIds.contains(item.containerId)
        case .reminder: return s.remindersOn && s.reminderListIds.contains(item.containerId)
        }
    }
}
