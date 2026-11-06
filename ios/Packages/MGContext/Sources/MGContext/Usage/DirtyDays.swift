import Foundation
import MGDomain

/// Which local days need the phone pipelines again (T134 / T108, 2026-10-12; Mo's D-014: only new or changed data runs).
///
/// Before this, every finished strap download and every 15-minute pull asked for yesterday and today, new data or not,
/// and so did the hourly and foreground requests. Now a download marks only the days its new records fall in (plus the
/// night that ends the next morning), and an hourly or foreground request runs only what is marked, or a day that rolled
/// over since the last run (yesterday's numbers settle after midnight). Pure arithmetic, so it is tested on Linux;
/// `ComputeCoordinator` holds one and decides under its actor.
public struct DirtyDays: Sendable, Equatable {
    /// The most days one download can mark: a month of backfill computes the newest two weeks now; older days wait for
    /// the launch run or a log/settings change (they were never computed by a download before either).
    public static let maxSpanDays = 14

    /// Days whose inputs changed and were not yet claimed by a run.
    public private(set) var pending: Set<LocalDay> = []
    /// The local day on which yesterday and today were last claimed together.
    public private(set) var settledOn: LocalDay?

    public init() {}

    /// A download finished. `recordsInserted` is what the store reported as actually new; 0 means nothing changed, so
    /// nothing is marked and nothing is returned (the caller schedules no compute). Otherwise the local days from the
    /// first to the last new record, plus the day after (the night that ends next morning), never past `today`, at
    /// most `maxSpanDays` of them (the newest). Missing times mean "we do not know which days": yesterday and today.
    @discardableResult
    public mutating func markHistory(recordsInserted: Int, firstTs: Int64?, lastTs: Int64?, today: LocalDay,
                                     calendar: Calendar) -> [LocalDay] {
        guard recordsInserted > 0 else { return [] }
        let days = Self.affected(firstTs: firstTs, lastTs: lastTs, today: today, calendar: calendar)
        pending.formUnion(days)
        return days
    }

    /// Something other than strap records changed these days (a log, a failed earlier run).
    public mutating func markChanged(_ days: [LocalDay]) {
        pending.formUnion(days)
    }

    /// What an hourly or foreground request may run now: the marked days, and yesterday + today when a new local day
    /// has started since they were last claimed together. Empty = nothing to do.
    public func due(today: LocalDay) -> [LocalDay] {
        var out = pending
        if settledOn != today { out.formUnion([today.adding(days: -1), today]) }
        return out.sorted()
    }

    /// A run starts on `days`. They leave the pending set now, so days marked while the run is going are kept for the
    /// next one. Yesterday and today both in `days` settles the new local day.
    public mutating func claim(_ days: [LocalDay], today: LocalDay) {
        pending.subtract(days)
        if days.contains(today), days.contains(today.adding(days: -1)) { settledOn = today }
    }

    /// The local days new records between `firstTs` and `lastTs` (strap unix seconds) can change.
    static func affected(firstTs: Int64?, lastTs: Int64?, today: LocalDay, calendar: Calendar) -> [LocalDay] {
        func day(_ t: Int64) -> LocalDay {
            min(LocalDay(date: Date(timeIntervalSince1970: TimeInterval(t)), calendar: calendar), today)
        }
        let yesterday = today.adding(days: -1)
        guard let a = firstTs ?? lastTs, let b = lastTs ?? firstTs else { return [yesterday, today] }
        var first = day(min(a, b))
        let last = day(max(a, b))
        // the night that ends the next morning belongs to the next day (never past today)
        let end = min(last.adding(days: 1), today)
        // a nonsense start (strap clock never set: 1970) must not produce thousands of days
        let floor = end.adding(days: -(maxSpanDays - 1))
        if first < floor { first = floor }
        var out: [LocalDay] = []
        var d = first
        while d <= end {
            out.append(d)
            d = d.adding(days: 1)
        }
        return out
    }
}
