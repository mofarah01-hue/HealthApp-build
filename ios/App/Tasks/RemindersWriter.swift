import EventKit
import Foundation
import MGContext

// T84: the one place the app WRITES to the iPhone Reminders, and only a new reminder made from a task Mo taps
// "Add to Reminders" on. It never edits, completes or removes an existing reminder (tools/check_strap_safety.py
// rule EVENTKIT-WRITE allows `save` in this file and nothing else). The permission is asked by `requestAccess()`,
// which the Tasks screen calls only when Mo opens it, never at launch. AlarmsCalendarReader stays read-only.

@MainActor
final class RemindersWriter {
    private let store = EKEventStore()

    var allowed: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func requestAccess() async -> Bool {
        if allowed { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    /// Adds one reminder to the default Reminders list, due on the task's day. Returns nil when it was saved, or a
    /// short reason to show Mo.
    func add(_ draft: ReminderDraft) -> String? {
        guard allowed else { return "Reminders access is off — iOS Settings › Privacy & Security › Reminders." }
        guard let list = store.defaultCalendarForNewReminders() else { return "This iPhone has no default Reminders list." }
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = list
        if let iso = draft.dueDay?.iso, iso.count == 10,
           let y = Int(iso.prefix(4)), let m = Int(iso.dropFirst(5).prefix(2)), let d = Int(iso.suffix(2)) {
            reminder.dueDateComponents = DateComponents(year: y, month: m, day: d)
        }
        do {
            try store.save(reminder, commit: true)
            return nil
        } catch {
            return "Reminders couldn't save it: \(error.localizedDescription)"
        }
    }
}
