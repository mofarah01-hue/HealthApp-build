import EventKit
import Foundation
import MGContext

// Calendar and Reminders, READ-ONLY (added 2026-10-11). The app asks for full access because iOS 17+ gives reading
// only with it (NSCalendarsFullAccessUsageDescription, NSRemindersFullAccessUsageDescription), and then only reads:
// this file is the only place that touches EventKit, and it never saves, removes or commits anything
// (tools/check_strap_safety.py rule EVENTKIT-WRITE fails the build if any file importing EventKit does).
// Mo's dashboard calendar reaches iOS Calendar as a subscribed ICS calendar (docs: the alarm page says how).

@MainActor
final class AlarmsCalendarReader {
    private let store = EKEventStore()

    func access(_ type: EKEntityType) -> String {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return "allowed"
        case .writeOnly: return "write-only — the app needs read access (iOS Settings › Privacy & Security)"
        case .denied: return "not allowed — iOS Settings › Privacy & Security › \(type == .event ? "Calendars" : "Reminders")"
        case .restricted: return "restricted on this phone"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    func canRead(_ type: EKEntityType) -> Bool {
        EKEventStore.authorizationStatus(for: type) == .fullAccess
    }

    func requestEvents() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func requestReminders() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    /// Calendars (or reminder lists) the phone has, for the picker.
    func sources(_ type: EKEntityType) -> [AlarmsSource] {
        guard canRead(type) else { return [] }
        return store.calendars(for: type).map { AlarmsSource(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Events starting in [from, to) in the picked calendars, and incomplete reminders due then in the picked lists.
    func items(from: Date, to: Date, settings: CalendarBuzzSettings) async -> [CalendarBuzzItem] {
        var out: [CalendarBuzzItem] = []
        if settings.eventsOn, canRead(.event) {
            let cals = store.calendars(for: .event).filter { settings.calendarIds.contains($0.calendarIdentifier) }
            if !cals.isEmpty {
                let predicate = store.predicateForEvents(withStart: from, end: to, calendars: cals)
                for e in store.events(matching: predicate) where e.startDate >= from && e.startDate < to {
                    out.append(CalendarBuzzItem(id: e.eventIdentifier ?? e.calendarItemIdentifier,
                                                title: e.title ?? "Event", at: e.startDate, source: .event,
                                                containerId: e.calendar.calendarIdentifier, allDay: e.isAllDay))
                }
            }
        }
        if settings.remindersOn, canRead(.reminder) {
            let lists = store.calendars(for: .reminder).filter { settings.reminderListIds.contains($0.calendarIdentifier) }
            if !lists.isEmpty {
                let predicate = store.predicateForIncompleteReminders(withDueDateStarting: from, ending: to,
                                                                      calendars: lists)
                let found: [CalendarBuzzItem] = await withCheckedContinuation { c in
                    store.fetchReminders(matching: predicate) { reminders in
                        let items = (reminders ?? []).compactMap { r -> CalendarBuzzItem? in
                            guard let comps = r.dueDateComponents, let due = Calendar.current.date(from: comps) else {
                                return nil
                            }
                            let allDay = comps.hour == nil
                            return CalendarBuzzItem(id: r.calendarItemIdentifier, title: r.title ?? "Reminder", at: due,
                                                    source: .reminder, containerId: r.calendar.calendarIdentifier,
                                                    allDay: allDay)
                        }
                        c.resume(returning: items)
                    }
                }
                out += found
            }
        }
        return out
    }
}
