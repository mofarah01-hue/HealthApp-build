import Foundation
import MGDomain

/// One activity's line on the "Workout average HR" screen (T56). The PC writes one `workout_hr_avg` row per WHOOP
/// workout with the window `workout:<activity-slug>:<start HHMM>`; this groups them by activity so Running and
/// Weightlifting are never one line. WHOOP's own number, in bpm.
public struct WorkoutActivityTrend: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// One point per workout, oldest first; empty when the line is blank.
    public var points: [DayPoint]
    public var n: Int
    public var latest: Double?
    /// Latest minus the oldest workout within the 30 days up to the latest; nil with no earlier workout in those days.
    public var change30: Double?
    /// Why the line is blank; nil when it is drawn.
    public var blankReason: String?
    /// "6 workouts · latest 152 bpm · +4 bpm over 30 days", or the blank reason.
    public var summary: String
}

public enum WorkoutTrends {
    /// A trend needs this many workouts of one activity.
    public static let minWorkouts = 3

    /// The activity slug of a window `workout:<slug>:<HHMM>`; nil for anything else.
    static func slug(_ window: String?) -> String? {
        guard let w = window else { return nil }
        let parts = w.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "workout", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// One series per activity, the one with most workouts first; each sorted by day then start time.
    public static func series(_ rows: [DatedMetric]) -> [WorkoutActivityTrend] {
        var bySlug: [String: [DatedMetric]] = [:]
        for r in rows {
            guard let s = slug(r.metric.window), let v = r.metric.value, v.isFinite else { continue }
            bySlug[s, default: []].append(r)
        }
        return bySlug.map { slug, list in
            let sorted = list.sorted { $0.day != $1.day ? $0.day < $1.day : $0.metric.at < $1.metric.at }
            return trend(slug: slug, sorted)
        }.sorted { $0.n != $1.n ? $0.n > $1.n : $0.id < $1.id }
    }

    private static func trend(slug: String, _ sorted: [DatedMetric]) -> WorkoutActivityTrend {
        let name = slug.replacingOccurrences(of: "-", with: " ")
        let title = name.prefix(1).uppercased() + name.dropFirst()
        let n = sorted.count
        guard n >= minWorkouts else {
            let why = "\(n) \(n == 1 ? "workout" : "workouts") so far: a trend needs \(minWorkouts)."
            return WorkoutActivityTrend(id: slug, title: title, points: [], n: n, latest: nil, change30: nil,
                                        blankReason: why, summary: why)
        }
        let points = sorted.map { DayPoint(day: $0.day, value: $0.metric.value) }
        let last = sorted[n - 1]
        let latest = last.metric.value ?? 0
        let window = sorted.dropLast().filter { $0.day.days(to: last.day) <= 30 }
        let change = window.first?.metric.value.map { latest - $0 }
        var parts = ["\(n) workouts", "latest \(MGFormat.number(latest, decimals: 0)) bpm"]
        if let c = change {
            let r = c.rounded()
            parts.append((r == 0 ? "no change" : (r > 0 ? "+" : "−") + MGFormat.number(abs(r), decimals: 0) + " bpm")
                         + " over 30 days")
        } else {
            parts.append("no earlier workout in the last 30 days to compare")
        }
        return WorkoutActivityTrend(id: slug, title: title, points: points, n: n, latest: latest, change30: change,
                                    blankReason: nil, summary: parts.joined(separator: " · "))
    }
}
