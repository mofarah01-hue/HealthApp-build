import Foundation

/// B-6 (Mo, Oct 14 2026: "the app drains my battery"): a small per-day tally of what the app itself starts, so
/// Settings › Usage can show what costs battery. Counts and durations only, from hooks at places that already run
/// (a compute run, a sync attempt, the live heart-rate stream, raw optical); nothing here starts any work.
/// Day = the local calendar day. A thing that is "on" (stream, raw optical) is a start/stop pair; an interval open when
/// the app is killed is dropped at the next launch (its end is unknown), so durations can only under-count.
public struct ActivityTally: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case compute, sync, bleStream, rawOptical
    }

    public var day: String
    public var counts: [String: Int]
    public var seconds: [String: Double]
    public var openSince: [String: Date]

    public init(day: String = "", counts: [String: Int] = [:], seconds: [String: Double] = [:],
                openSince: [String: Date] = [:]) {
        self.day = day
        self.counts = counts
        self.seconds = seconds
        self.openSince = openSince
    }

    static func dayKey(_ now: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// New local day: the counts start again; an interval still on carries over from midnight.
    mutating func roll(_ now: Date, _ calendar: Calendar) {
        let key = Self.dayKey(now, calendar)
        guard key != day else { return }
        day = key
        counts = [:]
        seconds = [:]
        let midnight = calendar.startOfDay(for: now)
        openSince = openSince.mapValues { _ in midnight }
    }

    /// One finished run / attempt (compute, sync) of `duration` seconds.
    public mutating func record(_ kind: Kind, duration: Double, now: Date, calendar: Calendar) {
        roll(now, calendar)
        counts[kind.rawValue, default: 0] += 1
        seconds[kind.rawValue, default: 0] += max(0, duration.isFinite ? duration : 0)
    }

    /// A stream / switch turned on or off. Turning on twice or off twice changes nothing.
    public mutating func setOn(_ kind: Kind, _ on: Bool, now: Date, calendar: Calendar) {
        roll(now, calendar)
        let k = kind.rawValue
        if on {
            guard openSince[k] == nil else { return }
            openSince[k] = now
            counts[k, default: 0] += 1
        } else if let since = openSince.removeValue(forKey: k) {
            seconds[k, default: 0] += max(0, now.timeIntervalSince(since))
        }
    }

    /// App launch: an interval open from the last run has no known end; drop it (never invent a duration).
    public mutating func dropOpenIntervals() { openSince = [:] }

    /// Today's count and seconds for one kind (an interval still on counts up to `now`). nil-day tallies read as zero.
    public func total(_ kind: Kind, now: Date, calendar: Calendar) -> (count: Int, seconds: Double, on: Bool) {
        guard day == Self.dayKey(now, calendar) else {
            // stored for an earlier day: only an interval still on (carried over midnight) counts
            let open = openSince[kind.rawValue].map { _ in max(0, now.timeIntervalSince(calendar.startOfDay(for: now))) } ?? 0
            return (0, open, openSince[kind.rawValue] != nil)
        }
        let k = kind.rawValue
        let open = openSince[k].map { max(0, now.timeIntervalSince($0)) } ?? 0
        return (counts[k] ?? 0, (seconds[k] ?? 0) + open, openSince[k] != nil)
    }
}

public enum ActivityUsage {
    /// The "What's running today" section. A count of 0 is a real zero (the hook ran, nothing started); a hook that
    /// does not exist in this build says so instead.
    public static func section(tally: ActivityTally, runs: [BackgroundRunRecord], now: Date,
                               calendar: Calendar) -> UsageState.Section {
        func row(_ id: String, _ title: String, _ kind: ActivityTally.Kind, unit: String, detail: String) -> UsageState.Row {
            let t = tally.total(kind, now: now, calendar: calendar)
            let value = t.count == 0 && !t.on
                ? "none today"
                : "\(t.count) \(unit) · \(UsageMath.seconds(t.seconds))" + (t.on ? " · on now" : "")
            return UsageState.Row(id: id, title: title, value: value, detail: detail)
        }
        var rows = [
            row("act.compute", "Computing (night, day and fitness numbers)", .compute, unit: "runs",
                detail: "Each run reads stored strap data and writes the day's numbers: the main CPU cost. Time is wall-clock, not CPU."),
            row("act.sync", "Sync attempts to the PC", .sync, unit: "attempts",
                detail: "Every try, including ones that found the PC unreachable. Each wakes the network."),
            row("act.ble", "Live heart-rate stream from the strap", .bleStream, unit: "times on",
                detail: "While on, the strap sends data every second and the radio stays busy. Duration is time switched on."),
            row("act.raw", "Raw optical (PPG research) on", .rawOptical, unit: "times on",
                detail: "Raw optical is the heaviest stream the strap can send. Duration is time switched on."),
        ]
        let today = runs.filter { calendar.isDate($0.start, inSameDayAs: now) }
        let secs = today.compactMap { r in r.end.map { $0.timeIntervalSince(r.start) } }.reduce(0, +)
        let cpu = today.compactMap(\.cpuSeconds).reduce(0, +)
        rows.append(UsageState.Row(
            id: "act.bg", title: "Background tasks iOS started",
            value: today.isEmpty ? "none today" : "\(today.count) runs · \(UsageMath.seconds(secs))",
            detail: today.isEmpty ? nil : "CPU used in them: \(UsageMath.seconds(cpu)). Runs that never wrote an end (app killed) add no time."))
        return UsageState.Section(
            id: "activity", title: "What's running today",
            note: "Counts since midnight (Pacific). They start counting when this build first ran, so earlier today may be missing. A switch left on when the app was killed is not counted, so times can only be too low.",
            rows: rows)
    }

}
