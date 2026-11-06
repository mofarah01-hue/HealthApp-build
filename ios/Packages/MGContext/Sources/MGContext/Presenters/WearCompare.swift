import Foundation
import MGDomain

/// ALG-042 wear location, per-location compare (W10, tracker #99, 2026-10-11; Mo 10-10: "left wrist right bicept left
/// bicept or underwear/tailbone"). The location is asked when the strap comes back on (the wear peek) and stored on
/// `wear` events; this sorts a metric's days by where the strap was worn and gives each place its median, so a
/// metric screen can say "Left wrist · 52 ms · 21 days / Right bicep · 58 ms · 5 days". A day counts for a place only
/// when the strap was on that place for the whole day (no change of place that day); mixed days are left out and
/// counted. Ours v0: no baseline model per place yet, just the split.
public enum WearCompare {
    public static let method = "ALG-042 v0 per-location split"

    public struct Row: Equatable, Sendable {
        public var location: WearLocation
        public var median: Double
        public var days: Int

        public init(location: WearLocation, median: Double, days: Int) {
            self.location = location
            self.median = median
            self.days = days
        }
    }

    public struct Result: Equatable, Sendable {
        public var rows: [Row]
        /// Days with a value whose place is unknown or changed during the day.
        public var leftOut: Int

        public init(rows: [Row], leftOut: Int) {
            self.rows = rows
            self.leftOut = leftOut
        }
    }

    /// The place worn for the whole of each day in `days`: the last located wear event before the day, unchanged by
    /// any located event inside it. Events without a location (wrist on, not yet answered) do not change the place.
    public static func dayLocations(events: [EventRecord], days: [LocalDay], calendar: Calendar) -> [LocalDay: WearLocation] {
        let located = events.filter { $0.type == .wear && !$0.removed && $0.wearLocation != nil
            && $0.wearLocation != .unknown }.sorted { $0.at < $1.at }
        var out: [LocalDay: WearLocation] = [:]
        for d in days {
            let start = d.start(in: calendar.timeZone)
            let end = d.adding(days: 1).start(in: calendar.timeZone)
            guard let before = located.last(where: { $0.at < start })?.wearLocation else { continue }
            let changed = located.contains { $0.at >= start && $0.at < end && $0.wearLocation != before }
            if !changed { out[d] = before }
        }
        return out
    }

    public static func split(points: [DayPoint], locations: [LocalDay: WearLocation]) -> Result {
        var byPlace: [WearLocation: [Double]] = [:]
        var leftOut = 0
        for p in points {
            guard let v = p.value, v.isFinite else { continue }
            if let loc = locations[p.day] { byPlace[loc, default: []].append(v) } else { leftOut += 1 }
        }
        let rows = byPlace.map { Row(location: $0.key, median: median($0.value), days: $0.value.count) }
            .sorted { $0.days != $1.days ? $0.days > $1.days : $0.location.rawValue < $1.location.rawValue }
        return Result(rows: rows, leftOut: leftOut)
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// The metric screen's lines ("Left wrist · 52 ms · 21 days"), or nil when no day has a place.
    static func lines(_ r: Result, format: (Double) -> String) -> [String]? {
        guard !r.rows.isEmpty else { return nil }
        var out = r.rows.map { "\(TodayPresenter.wearName($0.location)) · \(format($0.median)) · \($0.days) day\($0.days == 1 ? "" : "s")" }
        if r.rows.count == 1 { out.append("Every day here on one place — wear it elsewhere to compare.") }
        if r.leftOut > 0 { out.append("\(r.leftOut) day\(r.leftOut == 1 ? "" : "s") left out: place unknown or changed that day.") }
        return out
    }
}
