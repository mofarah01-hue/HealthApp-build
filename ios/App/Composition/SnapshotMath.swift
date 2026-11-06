import Foundation
import MGContext
import MGDomain
import MGSignal
import MGStore

// WP-23a — the statistics the presenters need, computed with MGSignal (main's split, 2026-10-11 ~04:00: presenters do
// no statistics; MGContext does not depend on MGSignal). Each function names the algorithm it calls. Missing input →
// nil / a blank with the reason, never a stand-in number (R6).
//
// WRITTEN, NOT COMPILED.

/// One metric name across days, one value per day (the member Mo reads, else the primary, else the first stored).
struct DailyColumn {
    var days: [LocalDay]
    var values: [Double?]
    var metrics: [Metric?]

    var nonNil: [Double] { values.compactMap { $0 } }
}

enum SnapshotMath {
    // MARK: Picking one value per day

    /// The member of a comparison group shown by default: Mo's read choice, else `primary`, else the first stored.
    /// Imported history (`ImportedHistory`) is picked only on a day with no value of the app's own.
    static func pick(_ candidates: [Metric], variant: String?, choices: [String: GroupChoice]) -> Metric? {
        let valued = candidates.filter { $0.value?.isFinite == true }
        if let variant { return valued.first { $0.variant == variant } }
        let own = valued.filter { !ImportedHistory.isImported($0) }
        let pool = own.isEmpty ? valued.sorted { ImportedHistory.rank($0) < ImportedHistory.rank($1) } : own
        if let g = pool.first?.group, let read = choices[g]?.readVariant,
           let m = pool.first(where: { $0.variant == read }) { return m }
        return pool.first { $0.primary == true } ?? pool.first
    }

    static func column(_ rows: [(day: LocalDay, metric: Metric)], days: [LocalDay], variant: String?,
                       choices: [String: GroupChoice]) -> DailyColumn {
        var byDay: [LocalDay: [Metric]] = [:]
        // Bug 4: a day-window measure and per-workout measures under one name never mix in one daily series.
        for r in DailyWindow.dailyRows(rows, metric: { $0.metric }) { byDay[r.day, default: []].append(r.metric) }
        let picked = days.map { pick(byDay[$0] ?? [], variant: variant, choices: choices) }
        return DailyColumn(days: days, values: picked.map { $0?.value }, metrics: picked)
    }

    static func days(endingAt end: LocalDay, count: Int) -> [LocalDay] {
        guard count > 0 else { return [] }
        return (0..<count).map { end.adding(days: $0 - count + 1) }
    }

    /// Days a period covers (MGContext PCHistoryPlan, which also knows 2 y / 5 y / All; tracker #7). `.all` without
    /// an `earliest` day reads as 30 d here; Explore passes the first day with a value.
    static func periodDays(_ p: ExplorePeriod, today: LocalDay = LocalDay(iso: "1970-01-01")!,
                           earliest: LocalDay? = nil) -> Int {
        PCHistoryPlan.periodDays(p, today: today, earliest: earliest)
    }

    // MARK: Recovery (ALG-160 readiness, D-RECOV-WALK-2)

    /// ALG-160 for the wake day `day`: every column is the app's OWN rows for one variant, `ALG160.historyNights` days ending
    /// on `day` (oldest first; the last element is the wake day). nil when there is no night of HRV at all.
    static func recovery(hrv: DailyColumn, morning: DailyColumn, morningPpg: DailyColumn, sleep: DailyColumn, atl: DailyColumn, ctl: DailyColumn,
                         stress: DailyColumn, day: LocalDay, now: Date) -> RecoveryReading? {
        guard hrv.days.last == day, hrv.values.contains(where: { $0 != nil }) else { return nil }
        func last(_ c: DailyColumn) -> Double? { c.days.last == day ? (c.values.last ?? nil) : nil }
        func before(_ c: DailyColumn, _ n: Int) -> [Double?] { Array(c.values.dropLast().suffix(n)) }
        // This morning's ATL / CTL when the day has them, else the end of yesterday (both or neither): as MorningStage.
        var a = last(atl)
        var c = last(ctl)
        if a == nil || c == nil {
            a = atl.values.dropLast().last ?? nil
            c = ctl.values.dropLast().last ?? nil
        }
        let input = ALG160.Input(lnNights: hrv.values, morningLn: MorningCheck.readinessSeries(ecg: morning.values, ppg: morningPpg.values),
                                 sleepLast: last(sleep), sleepPrev: before(sleep, 2), atl: a, ctl: c,
                                 stressDays: before(stress, 3))
        let r = ALG160.assess(input)
        let at = hrv.metrics.last.flatMap { $0 }?.at ?? now
        let rows = r.rows.map { RecoveryReading.Component(name: $0.name, points: $0.points, weight: $0.weight, reason: $0.reason) }
        let tier: RecoveryReading.Tier = r.tier == .enhanced ? .enhanced : .base
        switch r.status {
        case .ok:
            guard let x = r.reading else { return nil }
            return RecoveryReading(status: .ok, score: x.score, band: RecoveryReading.Band(rawValue: x.band.rawValue),
                                   tier: tier, hrvState: RecoveryReading.HRVState(rawValue: x.hrvState.rawValue),
                                   hrvDistance: x.hrvD, components: rows, hrvNights: x.nBase, recoveryDays: x.recoveryDays,
                                   at: at)
        case .learning:
            return RecoveryReading(status: .learning, tier: tier, components: rows, hrvNights: r.nBase, reason: r.reason, at: at)
        case .tooLittle:
            return RecoveryReading(status: .tooLittle, tier: tier, components: rows, hrvNights: r.nBase, reason: r.reason, at: at)
        }
    }

    // MARK: Strain distribution (UX §12 late-afternoon verdict)

    /// p25 / p75 of the read G-LOAD strain over the 28 days before today; nil under 7 days (too few to say).
    static func strainQuartiles(_ col: DailyColumn) -> Quartiles? {
        let xs = Array(col.values.dropLast()).compactMap { $0 }
        guard xs.count >= 7 else { return nil }
        return Quartiles(p25: SignalMath.quantile(xs, 0.25), p75: SignalMath.quantile(xs, 0.75), n: xs.count)
    }

    // MARK: Caffeine (ALG-060 curve, every 10 min)

    /// mg on board from the first dose of the last 24 h to bedtime (UX §3.3 dial layer); empty when no doses. `params` carries
    /// the half-life (r9t: your ALG-062 value once the PC has one, else the population 5 h).
    static func caffeineCurve(events: [EventRecord], now: Date, bedtime: Date,
                              params: ALG060.Params = .population) -> [TimedValue] {
        let doses = BehaviourEvents.caffeineDoses(from: events)
        guard let first = doses.first(where: { now.timeIntervalSince($0.start) < 24 * 3600 }) else { return [] }
        let end = bedtime > first.start ? bedtime : now.addingTimeInterval(3600)
        guard case .success(let samples) = ALG060.curve(from: first.start, to: end, step: 600, doses: doses, params: params) else {
            return []
        }
        return samples.map { TimedValue(at: $0.at, value: $0.totalMg) }
    }

    // MARK: Explore (ALG-075, ALG-079)

    /// One metric over Explore's period: median / IQR / coverage / previous period (SignalMath type 7), the normal band
    /// (ALG-075 `normalBand`, 28 d), EWMA (ALG-075 `ewma`, λ for a 7-day time constant — ours) and CUSUM change days.
    /// `n` = the days shown (PCHistoryPlan.shownDays: the whole period, or the phone's own span when the PC part is
    /// missing); `remoteDays` = days whose rows came from the PC (tracker #7): their imported labels say "from the PC".
    static func analysis(key: String, variant: String?, rows: [(day: LocalDay, metric: Metric)], today: LocalDay,
                         days n: Int, choices: [String: GroupChoice],
                         remoteDays: Set<LocalDay> = []) -> MetricAnalysis {
        let span = days(endingAt: today, count: 2 * n + 28)
        let col = column(rows, days: span, variant: variant, choices: choices)
        let cur = Array(col.values.suffix(n))
        let curDays = Array(span.suffix(n))
        let prev = Array(col.values.dropLast(n).suffix(n)).compactMap { $0 }
        let xs = cur.compactMap { $0 }
        let latest = col.metrics.compactMap { $0 }.last

        var a = MetricAnalysis(key: key, variant: variant ?? latest?.variant,
                               points: zip(curDays, cur).map { DayPoint(day: $0.0, value: $0.1) }, latest: latest,
                               daysWithValue: xs.count, daysInPeriod: n)
        for (d, m) in zip(span.suffix(n), col.metrics.suffix(n)) {
            guard let m, let label = ImportedHistory.sourceLabel(m) else { continue }
            a.importedDays[remoteDays.contains(d) ? label + ", from the PC" : label, default: 0] += 1
        }
        if !xs.isEmpty {
            a.median = SignalMath.median(xs)
            a.q1 = SignalMath.quantile(xs, 0.25)
            a.q3 = SignalMath.quantile(xs, 0.75)
        }
        if !prev.isEmpty { a.previousMedian = SignalMath.median(prev) }
        // T9894 (e-5): the 7 days ending at the period's end, for an empty header ("latest value + 7-day median").
        let week = col.values.suffix(7).compactMap { $0 }
        if week.count >= 3 {
            a.median7 = SignalMath.median(week)
            a.median7Days = week.count
        }
        // Bug 30 (M-202): "your normal" is the 28 days before the day being judged; today is not part of its own band.
        switch ALG075.normalBand(history: Array(col.values.dropLast().suffix(28))) {
        case .success(let band):
            a.bandLow = band.low
            a.bandHigh = band.high
        case .failure(let m):
            a.missingReason = latest == nil ? "Nothing stored for this metric yet." : m.reason
        }
        let lam = ALG036.lambda(tauDays: 7)
        a.ewma = zip(curDays, ALG075.ewma(cur, lam: lam)).map { DayPoint(day: $0.0, value: $0.1) }
        var x: [Double] = []
        var dayNumbers: [Int] = []
        var xDays: [LocalDay] = []
        for (d, v) in zip(curDays, cur) {
            guard let v else { continue }
            x.append(v)
            dayNumbers.append(today.days(to: d))
            xDays.append(d)
        }
        a.changeDays = ALG075.cusumChangePoints(x, days: dayNumbers).compactMap {
            $0.index < xDays.count ? xDays[$0.index] : nil
        }
        return a
    }

    /// Spearman ρ grid (ALG-079 `spearmanMatrix`, one BH family, < 14 pairs blank). The diagonal is ρ = 1 (BRIEF WP-19).
    static func matrix(keys: [String], columns: [String: [Double?]]) -> [[CorrelationInput]] {
        let m = ALG079.spearmanMatrix(names: keys, columns: columns)
        return m.cells.enumerated().map { (i, row) -> [CorrelationInput] in
            row.enumerated().map { (j, cell) -> CorrelationInput in
                switch cell {
                case .success(let c):
                    return CorrelationInput(rho: i == j ? 1 : c.rho, n: c.n, q: c.q)
                case .failure:
                    return CorrelationInput(rho: nil, n: pairedDays(columns[keys[i]] ?? [], columns[keys[j]] ?? []),
                                            q: nil)
                }
            }
        }
    }

    /// WP-22 `MatrixPipeline` result → the presenter's cells. A blank cell keeps its paired-day count from the reason
    /// ("too few days (9 paired, needs 14)"); the diagonal is ρ = 1 (BRIEF WP-19 row).
    static func correlationInputs(_ m: ALG079.Matrix) -> [[CorrelationInput]] {
        m.cells.enumerated().map { (i, row) -> [CorrelationInput] in
            row.enumerated().map { (j, cell) -> CorrelationInput in
                switch cell {
                case .success(let c):
                    return CorrelationInput(rho: i == j ? 1 : c.rho, n: c.n, q: c.q)
                case .failure(let missing):
                    return CorrelationInput(rho: nil, n: SnapshotMath.firstInt(missing.reason) ?? 0, q: nil)
                }
            }
        }
    }

    /// The first whole number in a text ("kss7" → 7, "too few days (9 paired…" → 9); nil when there is none.
    static func firstInt(_ s: String) -> Int? {
        Int(String(s.drop { !$0.isNumber }.prefix { $0.isNumber }))
    }

    static func pairedDays(_ a: [Double?], _ b: [Double?]) -> Int {
        zip(a, b).filter { $0.0 != nil && $0.1 != nil }.count
    }

    /// Compare with… (APP-104): x = first metric, y = second (BRIEF WP-19 convention), lag 0–2 days (x[t] vs y[t+lag]).
    static func compare(first: String, second: String?, lag: Int, x: DailyColumn, y: DailyColumn?) -> CompareInput {
        guard let second, let y else { return CompareInput(firstKey: first, lagDays: lag) }
        var pairs: [ComparePair] = []
        let n = min(x.values.count, y.values.count)
        if lag < n {
            for t in 0..<(n - lag) {
                if let a = x.values[t], let b = y.values[t + lag] {
                    pairs.append(ComparePair(day: x.days[t], x: a, y: b))
                }
            }
        }
        let result: CorrelationInput
        switch ALG079.spearmanLagged(x.values, y.values, lag: lag) {
        case .success(let c): result = CorrelationInput(rho: c.r, n: c.n, q: nil)
        case .failure: result = CorrelationInput(rho: nil, n: pairs.count, q: nil)
        }
        return CompareInput(firstKey: first, secondKey: second, lagDays: lag, pairs: pairs, result: result,
                            xUnit: x.metrics.compactMap { $0 }.last?.unit, yUnit: y.metrics.compactMap { $0 }.last?.unit)
    }

    // MARK: Comparison-group choices (APP-117; drop hides, never deletes)

    static func groupChoices(_ marks: [GroupMarkEntry]) -> [String: GroupChoice] {
        var out: [String: GroupChoice] = [:]
        for m in marks.sorted(by: { $0.at < $1.at }) {
            var c = out[m.groupId] ?? GroupChoice()
            switch m.mark {
            case .read:
                c.readVariant = m.variant
                c.readChosenAt = m.at
            case .keep:
                c.kept.insert(m.variant)
                c.dropped.remove(m.variant)
            case .drop:
                c.dropped.insert(m.variant)
                c.kept.remove(m.variant)
            }
            out[m.groupId] = c
        }
        return out
    }

    // MARK: Workout detail (WP-29)

    /// The workout's HR map (5-s buckets), zones (ALG-106), per-window avg / peak HR and MS-01 Banister TRIMP.
    static func workoutDetail(event: EventRecord, isLive: Bool, hr: [HRPoint], profile: Profile, rhr: Double?,
                              dayMetrics: [Metric], setsDone: Int, lastSetAt: Date?, now: Date,
                              calendar: Calendar, sleepStarts: [Double] = []) -> WorkoutDetailInput? {
        guard case .workout(let f) = event.payload else { return nil }
        let start = event.at
        let end = isLive ? now : f.end
        let samples = hr.filter { $0.bpm > 0 && Double($0.ts) >= start.timeIntervalSince1970
            && Double($0.ts) <= end.timeIntervalSince1970 }.sorted { $0.ts < $1.ts }

        var map: Series?
        if !samples.isEmpty {
            let step = 5.0
            let count = max(1, Int((end.timeIntervalSince(start) / step).rounded(.up)))
            var sums = [Double](repeating: 0, count: count)
            var ns = [Int](repeating: 0, count: count)
            for s in samples {
                let i = min(count - 1, max(0, Int((Double(s.ts) - start.timeIntervalSince1970) / step)))
                sums[i] += s.bpm
                ns[i] += 1
            }
            let values: [Double?] = zip(sums, ns).map { $0.1 > 0 ? $0.0 / Double($0.1) : nil }
            map = Series(name: "workout_hr", unit: "bpm", start: start, stepS: step, values: values, tier: .strap,
                         computedOn: .phone)
        }

        let zones = WorkoutZones.make(profile: profile, now: now, calendar: calendar)
        var zoneMinutes: [Double] = []
        if let z = zones.edges,
           case .success(let t) = ALG106.timeInZones(ts: samples.map { Int($0.ts) }, bpm: samples.map(\.bpm),
                                                     floor: z.floor, edges: z.edges) {
            zoneMinutes = t.minutes
        }

        var stats: [String: WorkoutWindowStats] = [:]
        let trimpSpec = MetricSpec(key: .strain, unit: "au", group: "G-LOAD", variant: "MS-01",
                                   method: "MS-01 trimp_banister (Loop)", tier: .estimate, source: "hr",
                                   window: "workout_window", producer: .script, paramsVersion: MSCatalogue.paramsVersion)
        for w in (f.windows ?? []).sorted(by: { $0.start < $1.start }) {
            let inside = samples.filter { Double($0.ts) >= w.start.timeIntervalSince1970
                && Double($0.ts) < w.end.timeIntervalSince1970 }.map(\.bpm)
            let avg = inside.isEmpty ? nil : SignalMath.mean(inside)
            let minutes = w.end.timeIntervalSince(w.start) / 60
            let trimp: Metric
            if let avg, let rest = rhr ?? profile.hrRestBaseline, let hrmax = zones.hrmax,
               let sex = profile.sex, sex != .other {
                trimp = trimpSpec.metric(MS01.trimpBanister(durationMin: minutes, hrEx: avg, hrRest: rest, hrMax: hrmax,
                                                            male: sex == .male), at: w.end)
            } else {
                let why = avg == nil ? "no heart rate in this window"
                    : (profile.sex == nil || profile.sex == .other)
                    ? "Banister TRIMP needs sex male or female in the profile (no other equation is published)"
                    : "needs resting HR and HRmax"
                trimp = trimpSpec.blank(why, at: w.end)
            }
            var winZones: [Double]?
            if let z = zones.edges {
                let ws = samples.filter { Double($0.ts) >= w.start.timeIntervalSince1970
                    && Double($0.ts) < w.end.timeIntervalSince1970 }
                winZones = ALG106.timeInZones(ts: ws.map { Int($0.ts) }, bpm: ws.map(\.bpm), floor: z.floor,
                                              edges: z.edges).value?.minutes
            }
            stats[WorkoutDetailWindow.makeID(kind: w.kind, start: w.start)] =
                WorkoutWindowStats(avgHR: avg, peakHR: inside.max(), trimp: trimp, zoneMinutes: winZones)
        }
        let groupMetrics = dayMetrics.filter { ["G-LOAD", "G-CAL"].contains($0.group ?? "") || ["hr_recovery_1min", "hr_recovery_60", "hr_recovery_120", "hr_recovery_tau", "steps", "hrv_rmssd"].contains($0.name) }
        return WorkoutDetailInput(event: event, isLive: isLive, hrMap: map, zoneEdgesBpm: zones.edges?.edges,
                                  zoneBasis: zones.basis, zoneMinutes: zoneMinutes, windowStats: stats,
                                  metrics: groupMetrics, setsDone: setsDone, lastSetAt: lastSetAt,
                                  asleepAfterMin: isLive ? nil
                                      : HRRBaseline.sleepAfterMinutes(endTs: end.timeIntervalSince1970,
                                                                      sleepStartTs: sleepStarts))
    }
}
