import Foundation
import MGContext
import MGDomain
import MGSignal
import MGSync

// Older periods from the PC, on request (tracker #7, 2026-10-11; Mo: "the long history can be server side … historical
// on server recentish things on phone … raw and processed labeled which algorithm/source"). When Explore's period
// reaches before the phone's oldest stored day, the metric detail, the open group and "Every measure" ask the PC
// (MGSync PCLabHistory, GET /v1/history) for the days the phone lacks. The answer lives only in `PCHistoryCenter`'s
// bounded cache (MGContext PCHistoryCache: 6 answers, 60 000 values, fresh for 10 minutes); nothing is written to the
// store. T109: the cache also keeps the last answer per request, in a purgeable Caches file, so that when the PC does
// not answer the screen shows those last values with the date they came (PCHistoryText.sentence), and only a request
// never answered shows the phone's own days only (PCHistoryPlan.shownDays). A fetch runs in the background; the
// screen says "asking the PC…".

/// The fetches and their answers (memory only).
@MainActor
final class PCHistoryCenter {
    var cache: PCHistoryCache
    private let file: URL?
    private(set) var inFlight: Set<PCHistoryCache.Key> = []
    /// The last failure per request; asked again after `retryAfter`.
    private(set) var failures: [PCHistoryCache.Key: (state: PCHistoryNote.State, at: Date)] = [:]
    static let retryAfter: TimeInterval = 60

    static let defaultFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("pc-history-last.json")

    init(file: URL? = PCHistoryCenter.defaultFile) {
        self.file = file
        cache = file.flatMap { try? Data(contentsOf: $0) }.map { PCHistoryCache(restoring: $0) } ?? PCHistoryCache()
    }

    /// Explore closed: forget the failures. The cache stays: it holds the last values the PC sent (T109).
    func clear() { failures = [:] }

    func begin(_ key: PCHistoryCache.Key) -> Bool { inFlight.insert(key).inserted }

    func finish(_ key: PCHistoryCache.Key, _ result: PCHistoryResult, now: Date) {
        inFlight.remove(key)
        switch result {
        case .history(let reply):
            failures[key] = nil
            let rows = reply.rows().map { DatedMetric(day: $0.day, metric: $0.metric, fromPC: true) }
            cache.put(key, rows: rows, cutBefore: reply.truncated ? reply.cutBefore : nil, now: now)
            // a file that cannot be written only costs the last values after a restart
            if let file, let data = try? cache.encoded() { try? data.write(to: file, options: .atomic) }
        case .notPaired:
            failures[key] = (.notPaired, now)
        case .unreachable(let why):
            failures[key] = (.unreachable(why + "; is Tailscale on and the PC awake?"), now)
        case .refused(let why):
            failures[key] = (.refused(why), now)
        }
    }

    func failure(_ key: PCHistoryCache.Key, now: Date) -> PCHistoryNote.State? {
        guard let f = failures[key], now.timeIntervalSince(f.at) < PCHistoryCenter.retryAfter else { return nil }
        return f.state
    }
}

/// What one lookup gave: the PC's rows (empty unless loaded) and the note's state.
struct PCHistoryLookup {
    var rows: [DatedMetric]
    var state: PCHistoryNote.State
    var cutBefore: LocalDay?
    /// T109: when the rows were received; with a state other than `.loaded` they are the last known ones.
    var receivedAt: Date?
    /// Rows to draw: fresh from the PC, or the last ones it sent.
    var shown: Bool { state == .loaded || !rows.isEmpty }
}

extension AppModel {
    /// Any Explore screen open (the tab, a metric detail or a group): otherwise the PC's answers are dropped.
    var exploreOnScreen: Bool { tab == .explore || detailKey != nil || groupId != nil }

    /// The PC's rows for `key`: from the cache, else the recent failure, else a fetch is started (the screen refreshes
    /// when it lands) and the state is `.loading`. SAMPLE: never asked.
    func pcHistory(_ key: PCHistoryCache.Key, sample: Bool) -> PCHistoryLookup {
        if sample { return PCHistoryLookup(rows: [], state: .sample) }
        let now = clock.now
        if let e = pcHistoryCenter.cache.get(key, now: now) {
            return PCHistoryLookup(rows: e.rows, state: .loaded, cutBefore: e.cutBefore)
        }
        let kept = pcHistoryCenter.cache.lastKnown(key)
        func lookup(_ state: PCHistoryNote.State) -> PCHistoryLookup {
            PCHistoryLookup(rows: kept?.rows ?? [], state: state, cutBefore: kept?.cutBefore, receivedAt: kept?.storedAt)
        }
        if let f = pcHistoryCenter.failure(key, now: now) { return lookup(f) }
        if pcHistoryCenter.begin(key) {
            Task { [weak self] in
                let result = await PCLabHistory.fetch(credentials: KeychainCredentialStore(), from: key.from,
                                                      to: key.to, names: key.names, latest: key.latest)
                guard let self else { return }
                self.pcHistoryCenter.finish(key, result, now: self.clock.now)
                await self.refresh()
            }
        }
        return lookup(.loading)
    }

    /// The note for a PC part: which range, how many days came, from which sources (labels as on screen).
    static func pcNote(_ lookup: PCHistoryLookup, range: ClosedRange<LocalDay>, used: [DatedMetric]) -> PCHistoryNote {
        var sources: [String: Int] = [:]
        var days = Set<LocalDay>()
        for r in used where r.fromPC {
            days.insert(r.day)
            sources[ImportedHistory.sourceLabel(r.metric) ?? "computed on PC", default: 0] += 1
        }
        return PCHistoryNote(state: lookup.state, from: range.lowerBound, to: range.upperBound, days: days.count,
                             sources: sources, cutBefore: lookup.cutBefore, lastReceived: lookup.receivedAt)
    }

    /// One metric over Explore's period, the PC's older days joined in when the period reaches before the phone's
    /// oldest stored day of that metric (else of any metric).
    func exploreAnalysis(src: any SnapshotReading, key: String, variant: String?, today: LocalDay,
                         period: ExplorePeriod, choices: [String: GroupChoice],
                         askPC: Bool) async throws -> MetricAnalysis {
        let phoneOldest: LocalDay?
        if let o = try await src.oldestDay(name: key) { phoneOldest = o } else { phoneOldest = try await src.oldestDay(name: nil) }
        let start = PCHistoryPlan.periodStart(period, today: today)
        let end = PCHistoryPlan.periodEnd(period, today: today)      // T9822: a custom range may end before today
        let readFrom = period == .all ? (phoneOldest ?? today) : start
        let nFull = PCHistoryPlan.periodDays(period, today: today, earliest: phoneOldest)
        // the period and the one before it (vs previous) + 28 days of band, as before
        let local = try await src.metricDays(name: key, from: min(readFrom, end.adding(days: -(2 * nFull + 27))),
                                             to: end).map { DatedMetric(day: $0.day, metric: $0.metric) }
        let fill = PCHistoryPlan.fillsMissingDays(name: key)
        guard askPC, let range = PCHistoryPlan.remoteRange(periodStart: start, phoneOldest: phoneOldest, today: today,
                                                           fillMissingDays: fill, periodEnd: end)
        else {
            let n = PCHistoryPlan.shownDays(period: period, today: today, phoneOldest: phoneOldest,
                                            pcShown: phoneOldest.map { $0 <= start } ?? false,
                                            earliest: phoneOldest)
            var a = SnapshotMath.analysis(key: key, variant: variant, rows: local.map { ($0.day, $0.metric) },
                                          today: end, days: n, choices: choices)
            if key == MetricKey.workoutHrAvg.rawValue { a.workoutRows = local }      // T56: all workouts, not one per day
            return a
        }
        let lookup = pcHistory(PCHistoryCache.Key(names: [key], from: range.lowerBound, to: range.upperBound,
                                                  latest: false), sample: src.isSample)
        let merged = PCHistoryPlan.merge(local: local, remote: lookup.rows, phoneOldest: phoneOldest, fillMissingDays: fill)
        let shown = lookup.shown
        let earliest = merged.first { $0.metric.value?.isFinite == true }?.day ?? phoneOldest
        let n = PCHistoryPlan.shownDays(period: period, today: today, phoneOldest: phoneOldest, pcShown: shown,
                                        earliest: earliest)
        var a = SnapshotMath.analysis(key: key, variant: variant, rows: merged.map { ($0.day, $0.metric) },
                                      today: end, days: n, choices: choices,
                                      remoteDays: Set(merged.filter(\.fromPC).map(\.day)))
        a.pcHistory = Self.pcNote(lookup, range: range, used: merged)
        if key == MetricKey.workoutHrAvg.rawValue { a.workoutRows = merged }      // T56
        return a
    }

    /// The open group's older years from the PC: one summary per (metric, variant) — median (SignalMath), days, span.
    func groupPCInput(src: any SnapshotReading, gid: String, today: LocalDay,
                      period: ExplorePeriod) async throws -> GroupPCInput? {
        let names = PCHistoryPlan.groupMetricNames(gid)
        guard !names.isEmpty else { return nil }
        var oldest: LocalDay?
        for n in names {
            if let o = try await src.oldestDay(name: n) { oldest = min(oldest ?? o, o) }
        }
        if oldest == nil { oldest = try await src.oldestDay(name: nil) }
        let start = PCHistoryPlan.periodStart(period, today: today)
        // Bug 11 leftover: a group holding strain (G-LOAD) fetches WHOOP's days the phone cannot rebuild too.
        let end = PCHistoryPlan.periodEnd(period, today: today)
        guard let range = PCHistoryPlan.groupRemoteRange(periodStart: start, phoneOldest: oldest, today: today,
                                                         names: names, periodEnd: end) else {
            return nil
        }
        var local: [DatedMetric] = []
        for n in names where PCHistoryPlan.fillsMissingDays(name: n) {
            local += try await src.metricDays(name: n, from: range.lowerBound, to: range.upperBound)
                .map { DatedMetric(day: $0.day, metric: $0.metric) }
        }
        let lookup = pcHistory(PCHistoryCache.Key(names: names, from: range.lowerBound, to: range.upperBound,
                                                  latest: false), sample: src.isSample)
        let rows = PCHistoryPlan.mergeGroup(local: local, remote: lookup.rows, phoneOldest: oldest)
            .filter(\.fromPC)
        var groups: [String: [DatedMetric]] = [:]
        for r in rows where r.metric.value?.isFinite == true {
            groups["\(r.metric.name)|\(r.metric.variant ?? "")", default: []].append(r)
        }
        let summary = groups.values.compactMap { list -> GroupPCInput.Row? in
            guard let m = list.first?.metric, let first = list.first?.day, let last = list.last?.day else { return nil }
            let values = list.compactMap(\.metric.value)
            return GroupPCInput.Row(name: m.name, variant: m.variant ?? "",
                                    label: ImportedHistory.sourceLabel(m) ?? (m.variant ?? m.source), unit: m.unit,
                                    median: SignalMath.median(values), days: Set(list.map(\.day)).count,
                                    first: first, last: last)
        }.sorted { ($0.name, $0.variant) < ($1.name, $1.variant) }
        return GroupPCInput(note: Self.pcNote(lookup, range: range, used: rows), rows: summary)
    }

    /// "Every measure" with a period reaching before the phone's window: the PC's newest value of every metric in the
    /// older part (`latest`), added to `latest` as `fromPC` rows (a phone row, newer, still wins).
    func measuresPC(src: any SnapshotReading, today: LocalDay, period: ExplorePeriod,
                    latest: inout [String: [DatedMetric]]) async throws -> PCHistoryNote? {
        let oldest = try await src.oldestDay(name: nil)
        let start = PCHistoryPlan.periodStart(period, today: today)
        guard let range = PCHistoryPlan.remoteRange(periodStart: start, phoneOldest: oldest, today: today,
                                                    periodEnd: PCHistoryPlan.periodEnd(period, today: today)) else {
            return nil
        }
        let lookup = pcHistory(PCHistoryCache.Key(names: nil, from: range.lowerBound, to: range.upperBound,
                                                  latest: true), sample: src.isSample)
        let rows = PCHistoryPlan.merge(local: [], remote: lookup.rows, phoneOldest: oldest)
        for r in rows { latest[r.metric.name, default: []].append(r) }
        return Self.pcNote(lookup, range: range, used: rows)
    }
}
