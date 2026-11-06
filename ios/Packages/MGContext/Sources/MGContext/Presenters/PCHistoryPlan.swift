import Foundation
import MGDomain

// Older periods from the PC, on request (tracker #7, 2026-10-11; Mo: "the long history can be server side … historical
// on server recentish things on phone … raw and processed labeled which algorithm/source"). The phone keeps its window
// (the 12 published months plus its own data); when Explore's period reaches further back the app asks the PC
// (MGSync PCLabHistory, GET /v1/history) for the days it lacks and shows them labelled "from the PC". Pure: the rules
// (which range to ask for, how the two parts join, how many days the screen covers) and the bounded cache live here so
// they are tested without a phone or a PC.

/// What the PC part of a period is doing, for the sentence under the period picker.
public struct PCHistoryNote: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case loading
        case loaded
        /// No answer (Tailscale off, PC asleep, PC Lab not running): the reason as MGSync gave it.
        case unreachable(String)
        /// An answer that is not history (an older PC Lab, a bad request).
        case refused(String)
        case notPaired
        /// Sample data: the PC is not asked.
        case sample
    }

    public var state: State
    /// The PC part of the period, both days included (`to` = the day before the phone's oldest stored day).
    public var from: LocalDay
    public var to: LocalDay
    /// Days of the PC part with a value, and how many came from each source label ("WHOOP export": 900).
    public var days: Int
    public var sources: [String: Int]
    /// The PC cut its answer at its limit: days before this did not come.
    public var cutBefore: LocalDay?
    /// T109: the PC did not answer now, so the values shown are the last ones it sent, received at this time.
    public var lastReceived: Date?

    public init(state: State, from: LocalDay, to: LocalDay, days: Int = 0, sources: [String: Int] = [:],
                cutBefore: LocalDay? = nil, lastReceived: Date? = nil) {
        self.state = state
        self.from = from
        self.to = to
        self.days = days
        self.sources = sources
        self.cutBefore = cutBefore
        self.lastReceived = lastReceived
    }

    /// The PC part is on screen: fresh from the PC, or (T109) the last values it sent while it does not answer.
    public var isShown: Bool { state == .loaded || (lastReceived != nil && days > 0) }
}

public enum PCHistoryPlan {
    /// "All" asks from here; the PC answers with what its imports hold (Mo's Apple Health starts in 2015).
    public static let farthestBack = LocalDay(iso: "2005-01-01")!
    /// One request covers at most this many days (the PC refuses more than 9200, mglab/history.py RANGE_MAX_DAYS).
    public static let maxSpanDays = 9000

    /// Days a period covers. `.all` = from `earliest` (the first day with a value, phone or PC) to today, at least 30.
    public static func periodDays(_ p: ExplorePeriod, today: LocalDay, earliest: LocalDay? = nil) -> Int {
        switch p {
        case .today: return 1
        case .days7: return 7
        case .days30: return 30
        case .days90: return 90
        case .year1: return 365
        case .years2: return 730
        case .years5: return 1826
        case .all: return max(30, (earliest.map { $0.days(to: today) + 1 }) ?? 30)
        case .custom(let r):
            // T9822: the picked days (end cut at today). No range picked yet = the last 30 days, labelled on screen.
            guard let r else { return customDefaultDays }
            return max(1, r.start.days(to: min(r.end, today)) + 1)
        }
    }

    /// Custom chosen but no range picked yet: the last 30 days (the screen says so, `customNoneNote`).
    public static let customDefaultDays = 30
    public static let customNoneNote = "No custom range picked yet: showing the last 30 days."

    /// The last day of a period: today, or the picked end of a custom range (never after today).
    public static func periodEnd(_ p: ExplorePeriod, today: LocalDay) -> LocalDay {
        if let r = p.customRange { return min(r.end, today) }
        return today
    }

    /// The first day of a period (`.all`: `farthestBack`); it ends at `periodEnd`.
    public static func periodStart(_ p: ExplorePeriod, today: LocalDay) -> LocalDay {
        p == .all ? farthestBack : periodEnd(p, today: today).adding(days: -(periodDays(p, today: today) - 1))
    }

    /// The range the phone lacks: [periodStart, phoneOldest − 1], at most `maxSpanDays` long (the newest part kept);
    /// nil when the phone holds the whole period. `phoneOldest` nil = the phone holds nothing for it: ask for it all.
    ///
    /// `fillMissingDays` (bug 11, Mo 2026-10-14: 846 of 847 WHOOP strain days exist on the PC but only days before the phone's
    /// oldest strain row were fetched): the range runs to today, so days the phone cannot rebuild are fetched too.
    ///
    /// `periodEnd` (T9822): a custom range ending before today never asks past its last day.
    public static func remoteRange(periodStart: LocalDay, phoneOldest: LocalDay?, today: LocalDay,
                                   fillMissingDays: Bool = false, periodEnd: LocalDay? = nil) -> ClosedRange<LocalDay>? {
        let cap = min(periodEnd ?? today, today)
        let end = min(fillMissingDays ? cap : (phoneOldest.map { $0.adding(days: -1) } ?? cap), cap)
        guard periodStart <= end else { return nil }
        let start = max(periodStart, end.adding(days: -(maxSpanDays - 1)))
        return start...end
    }

    /// The phone's rows and the PC's, joined so that no day is shown twice: a PC row counts only on a day before the
    /// phone's oldest stored day (`phoneOldest` nil = the phone holds nothing). Ordered by day.
    ///
    /// `fillMissingDays` (bug 11): a PC row also counts on a day the phone holds no value for that metric and variant (the
    /// days the phone cannot rebuild), never beside a phone value of the same variant.
    public static func merge(local: [DatedMetric], remote: [DatedMetric], phoneOldest: LocalDay?,
                             fillMissingDays: Bool = false) -> [DatedMetric] {
        struct Key: Hashable { var day: LocalDay; var name: String; var variant: String }
        func key(_ r: DatedMetric) -> Key { Key(day: r.day, name: r.metric.name, variant: r.metric.variant ?? "") }
        let have = fillMissingDays ? Set(local.filter { $0.metric.value?.isFinite == true }.map(key)) : []
        let older = remote.filter { r in
            (phoneOldest.map { r.day < $0 } ?? true) || (fillMissingDays && !have.contains(key(r)))
        }
        return (older + local).sorted { $0.day < $1.day }
    }

    /// Metrics whose imported history is fetched for every day the phone lacks, not only before its oldest row: WHOOP's daily
    /// strain (bug 11), which the phone cannot rebuild on days it did not wear the strap.
    public static func fillsMissingDays(name: String) -> Bool { name == MetricKey.strain.rawValue }

    /// Bug 11 leftover (round 2, 2026-10-14): a group card (G-LOAD, Strain) asks for the names of the whole group. When one
    /// of them fills missing days (WHOOP strain) the range runs to today, so the WHOOP days between phone rows arrive too.
    public static func groupRemoteRange(periodStart: LocalDay, phoneOldest: LocalDay?, today: LocalDay,
                                        names: [String], periodEnd: LocalDay? = nil) -> ClosedRange<LocalDay>? {
        remoteRange(periodStart: periodStart, phoneOldest: phoneOldest, today: today,
                    fillMissingDays: names.contains(where: fillsMissingDays(name:)), periodEnd: periodEnd)
    }

    /// Bug 11 leftover: `merge` for a group's rows, the fill rule applied per metric name. A strain row fills a day the phone
    /// holds no value of that variant for; every other name keeps the old rule (only days before the phone's oldest row).
    /// `local` must hold the phone's rows of the filling names (it is only used to see which days the phone has).
    public static func mergeGroup(local: [DatedMetric], remote: [DatedMetric], phoneOldest: LocalDay?) -> [DatedMetric] {
        let filling = remote.filter { fillsMissingDays(name: $0.metric.name) }
        let rest = remote.filter { !fillsMissingDays(name: $0.metric.name) }
        return (merge(local: local.filter { fillsMissingDays(name: $0.metric.name) }, remote: filling,
                      phoneOldest: phoneOldest, fillMissingDays: true)
                + merge(local: [], remote: rest, phoneOldest: phoneOldest)).sorted { $0.day < $1.day }
    }

    /// How many days the screen covers. With the PC part shown: the whole period. Without it (asking, unreachable, not
    /// paired, sample): only the phone's own span, so the chart never shows years of empty space that look like "no
    /// data" when the data is simply on a PC that did not answer.
    public static func shownDays(period: ExplorePeriod, today: LocalDay, phoneOldest: LocalDay?, pcShown: Bool,
                                 earliest: LocalDay?) -> Int {
        let full = periodDays(period, today: today, earliest: earliest)
        if pcShown { return full }
        guard let oldest = phoneOldest else { return min(full, 30) }
        return max(1, min(full, oldest.days(to: periodEnd(period, today: today)) + 1))
    }

    /// Every registry metric of a comparison group (G-HRV: 17), for asking the PC about a group.
    public static func groupMetricNames(_ gid: String) -> [String] {
        ExploreCatalogue.allMeasures.flatMap { $0.1 }.filter { $0.group == gid }.map(\.key)
    }
}

/// The PC's answers, small and never written to the phone's store. At most `maxEntries` answers and `maxRows` values
/// in all (the least recently used go first). An answer counts as fresh for `maxAge`; after that it is only the last
/// known one (T109): shown, with the date it came, while the PC does not answer. The app keeps the cache in a purgeable
/// file (`encoded()` / `init(restoring:)`) so it survives a restart.
public struct PCHistoryCache: Sendable {
    public struct Key: Hashable, Codable, Sendable {
        /// Sorted; nil = every metric.
        public var names: [String]?
        public var from: LocalDay
        public var to: LocalDay
        public var latest: Bool

        public init(names: [String]?, from: LocalDay, to: LocalDay, latest: Bool) {
            self.names = names?.sorted()
            self.from = from
            self.to = to
            self.latest = latest
        }
    }

    public struct Entry: Equatable, Codable, Sendable {
        public var rows: [DatedMetric]
        public var cutBefore: LocalDay?
        public var storedAt: Date
        public var usedAt: Date
    }

    public static let maxEntries = 6
    public static let maxRows = 60_000
    public static let maxAge: TimeInterval = 10 * 60

    public private(set) var entries: [Key: Entry] = [:]

    public init() {}

    public var rowCount: Int { entries.values.reduce(0) { $0 + $1.rows.count } }

    public mutating func get(_ key: Key, now: Date) -> Entry? {
        guard var e = entries[key] else { return nil }
        if now.timeIntervalSince(e.storedAt) > PCHistoryCache.maxAge { return nil }
        e.usedAt = now
        entries[key] = e
        return e
    }

    public mutating func put(_ key: Key, rows: [DatedMetric], cutBefore: LocalDay?, now: Date) {
        entries[key] = Entry(rows: Array(rows.suffix(PCHistoryCache.maxRows)), cutBefore: cutBefore, storedAt: now,
                             usedAt: now)
        while entries.count > PCHistoryCache.maxEntries || rowCount > PCHistoryCache.maxRows {
            guard let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.usedAt < $1.value.usedAt })?.key
            else { break }
            entries[oldest] = nil
        }
    }

    /// The answer last received for `key`, however old (T109); `storedAt` is when it came.
    public func lastKnown(_ key: Key) -> Entry? { entries[key] }

    public mutating func clear() { entries = [:] }

    private struct Stored: Codable { var key: Key; var entry: Entry }

    /// The cache as JSON (a struct key cannot be a JSON object key, so a list of pairs).
    public func encoded() throws -> Data {
        try JSONEncoder().encode(entries.map { Stored(key: $0.key, entry: $0.value) })
    }

    /// Empty when `data` is not what `encoded()` wrote: a damaged file only costs the last known values.
    public init(restoring data: Data) {
        let stored = (try? JSONDecoder().decode([Stored].self, from: data)) ?? []
        entries = Dictionary(stored.map { ($0.key, $0.entry) }, uniquingKeysWith: { a, _ in a })
    }
}

enum PCHistoryText {
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "12 Oct 2025".
    static func day(_ d: LocalDay) -> String { "\(d.day) \(months[d.month - 1]) \(d.year)" }

    /// The sentence under the period picker; nil when the period needs nothing from the PC.
    static func sentence(_ n: PCHistoryNote?, calendar: Calendar) -> String? {
        guard let n else { return nil }
        let since = day(n.to.adding(days: 1))
        var phoneOnly = "Showing \(since) – today from the phone only."
        if let at = n.lastReceived, n.days > 0, n.state != .loaded {
            let c = calendar.dateComponents([.year, .month, .day], from: at)
            let when = "\(c.day ?? 1) \(months[(c.month ?? 1) - 1]) \(c.year ?? 0), \(MGFormat.time(at, calendar: calendar))"
            phoneOnly = "Showing the values last received from the PC on \(when)."
        }
        switch n.state {
        case .loaded:
            guard n.days > 0 else {
                return "Before \(since): the PC has nothing for this period either (asked \(day(n.from)) – \(day(n.to)))."
            }
            let parts = n.sources.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { "\($0.key) \(MGFormat.grouped($0.value))" }
            var s = "Before \(since): \(MGFormat.grouped(n.days)) days from the PC (\(parts.joined(separator: ", "))). "
                + "Fetched for this screen, not kept on the phone."
            if let cut = n.cutBefore { s += " The PC sent its newest days only; nothing before \(day(cut))." }
            return s
        case .loading:
            return "Before \(since): asking the PC… " + phoneOnly
        case .unreachable(let why):
            return "Before \(since) is on the PC, which isn't reachable (\(why)). " + phoneOnly
        case .refused(let why):
            return "Before \(since) is on the PC, which didn't send it (\(why)). " + phoneOnly
        case .notPaired:
            return "Before \(since) is on the PC. Pair the PC Lab (Strap & sync) to see it. " + phoneOnly
        case .sample:
            return "Sample data: older years are not asked from the PC."
        }
    }
}
