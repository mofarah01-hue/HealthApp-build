import Foundation
import MGDomain

/// T84: tasks from the Jabarin dashboard (Mo's Personal OS) through the PC Lab, the day's stress total sent back, and
/// the shape a task takes as an iPhone Reminder. Pure mapping only: the network calls are MGSync `PCLabTasks`, the
/// EventKit write is App/Tasks/RemindersWriter.swift. The PC side is pclab/mglab/jabarin_link.py (GET and POST
/// /v1/tasks, POST /v1/stress-day). Stress is an estimate from heart rate and HRV; cortisol cannot be measured from the
/// wrist (your morning cortisol is a blood test, T14), and stress next to tasks is a pattern hint, not proof of cause.

/// One open task as the PC sends it (`tasks.v1.json`). Dates are `YYYY-MM-DD`.
public struct LinkedTask: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var due: String?
    public var scheduled: String?
    public var priority: String?
    public var domain: String?
    public var status: String?

    /// The day it belongs on: the deadline, else the planned day; nil when neither is a real date.
    public var day: LocalDay? { (due ?? scheduled).flatMap { LocalDay(iso: $0) } }
}

/// The task list as the Tasks screen shows it: late, today, later, and the ones with no day.
public struct TaskList: Equatable, Sendable {
    public var overdue: [LinkedTask] = []
    public var today: [LinkedTask] = []
    public var later: [LinkedTask] = []
    public var undated: [LinkedTask] = []

    /// A planned day is when you mean to do it, never a deadline, so a planned day in the past is not overdue.
    public init(tasks: [LinkedTask], today day: LocalDay) {
        for t in tasks {
            guard let d = t.day else { undated.append(t); continue }
            if d == day { today.append(t) }
            else if d > day { later.append(t) }
            else if t.due != nil { overdue.append(t) }
            else { today.append(t) }
        }
    }
}

/// What the Reminders writer needs from a task.
public struct ReminderDraft: Equatable, Sendable {
    public var title: String
    public var dueDay: LocalDay?
    public var notes: String
}

public enum JabarinLink {
    private struct Answer: Decodable { var tasks: [LinkedTask] }

    /// The tasks in a `GET /v1/tasks` answer.
    public static func tasks(from data: Data) throws -> [LinkedTask] {
        try JSONDecoder().decode(Answer.self, from: data).tasks
    }

    /// The `POST /v1/tasks` body for a new task; nil for a blank title or a due date that is not `YYYY-MM-DD`.
    public static func newTaskBody(title: String, due: String?, priority: String?) -> Data? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, due.map({ LocalDay(iso: $0) != nil }) ?? true else { return nil }
        var body = ["title": name]
        if let due { body["due"] = due }
        if let priority { body["priority"] = priority }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func reminderDraft(for task: LinkedTask) -> ReminderDraft {
        ReminderDraft(title: task.title, dueDay: task.day,
                      notes: "From Jabarin" + (task.priority.map { " (\($0) priority)" } ?? "") + ".")
    }

    /// Low under 1, medium under 2, high from 2 (D-042-T31's bands for the daytime score).
    static func band(_ value: Double) -> String { value < 1 ? "low" : value < 2 ? "medium" : "high" }

    /// Today's stress total (`PresenterKit.dayStress`) rounded to 2 decimals; nil when it has no value.
    private static func total(_ s: PresenterSnapshot) -> Double? {
        guard let v = s.dayStress()?.value, v.isFinite else { return nil }
        return (v * 100).rounded() / 100
    }

    /// The `POST /v1/stress-day` body: date, value, band and the label "estimate" (the PC refuses anything else).
    public static func stressBody(_ s: PresenterSnapshot) -> Data? {
        guard let v = total(s) else { return nil }
        var body: [String: Any] = ["date": s.day.iso, "value": v, "scale": "0-3", "band": band(v), "label": "estimate"]
        if let note = s.dayStress()?.note, !note.isEmpty { body["note"] = note }
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// The one-line message shown next to the task list; nil when there is no score.
    public static func stressLine(_ s: PresenterSnapshot) -> String? {
        guard let v = total(s) else { return nil }
        return "Body arousal today: \(MGFormat.number(v, decimals: 1)) of 3 (\(band(v))), a physiological estimate from heart rate and HRV, not mood and not cortisol."
    }
}
