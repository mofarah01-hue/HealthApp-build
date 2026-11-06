import Foundation
import MGDomain

/// ALG-054 v2 — autonomic load (G-STRESS rank 1, ours): HR, lnRMSSD and breathing rate against your own baseline for
/// the same hour of the day, exercise masked. A personal "stress" label needs your quick stress taps (later); this is
/// the load. Python reference: app/pclab/mglab/ref/hrv.py `autonomic_baseline`, `autonomic_load`, `autonomic_day`;
/// goldens app/shared/golden/hrv/ALG-054.json.
///
/// v2 (R9m, D-POP-PRIOR): HR and lnRMSSD start from the published POPULATION value and move toward the person's own as days
/// of data grow, `w = days / (days + k)`, k = 14 days (ours: the same k as the app's trends). Population values, checked
/// 2026-10-17 against secondary sources (not the papers' full text): HR 65.5 ± 7.7 bpm (Quer et al. 2020, PLOS ONE
/// 15(2):e0227709, 92,457 adults, resting HR mostly from sleep); RMSSD 42 ± 15 ms (Nunan, Sandercock & Brodie 2010, PACE
/// 33(11):1407-17, short-term healthy adults; numbers from Shaffer & Ginsberg 2017, Front Public Health 5:258, Table 6),
/// turned into lnRMSSD as a log-normal with that mean and SD (ours). Neither paper's text gives age / sex means, so one
/// value for everyone. Reference: `hrv.py` `_shrunk`, `autonomic_load(days=)`; golden ALG-054 cases "no days of your own",
/// "14 days of your own", "many days".
public enum ALG054 {
    public static let citation = "ours (ALGORITHM-REQUIREMENTS ALG-054); circadian baseline per hour of day; "
        + "population prior: Quer 2020 PLOS ONE 15:e0227709 (HR), Nunan 2010 PACE 33:1407 (RMSSD)"
    /// k of `w = days / (days + k)`.
    public static let priorK = 14.0
    /// Population mean and SD of resting HR, bpm (Quer et al. 2020).
    public static let populationHR: (mean: Double, sd: Double) = (65.5, 7.7)
    /// Population lnRMSSD: log-normal with RMSSD mean 42 ms and SD 15 ms (Nunan 2010); mu = ln 42 − σ²/2.
    public static let populationLnRmssd: (mean: Double, sd: Double) = {
        let sigma = (log(1.0 + (15.0 / 42.0) * (15.0 / 42.0))).squareRoot()
        return (log(42.0) - sigma * sigma / 2.0, sigma)
    }()
    static func population(_ f: Feature) -> (mean: Double, sd: Double)? {
        switch f {
        case .hr: return populationHR
        case .lnRmssd: return populationLnRmssd
        case .resp: return nil
        }
    }

    /// "population" while none of your own days back the baseline, else "yours (N days)" (blended with the population
    /// until about a month of days); nil when the baseline carries no day count (the v1 behaviour).
    public static func basisLabel(days: Int?) -> String? {
        guard let days else { return nil }
        return days <= 0 ? "population" : "yours (\(days) day\(days == 1 ? "" : "s"))"
    }
    public static let minBaselineWindows = 10
    public static let minFeatures = 2
    public static let dayMinWindows = 3

    public enum Feature: String, Sendable, CaseIterable {
        case hr = "hr"
        case lnRmssd = "ln_rmssd"
        case resp = "resp"

        /// Load direction: HR up, RMSSD down, breathing up.
        var sign: Double { self == .lnRmssd ? -1.0 : 1.0 }
    }

    /// One 5-min window's features. `hour` = local hour of day 0…23 (the caller applies the time zone).
    public struct Sample: Sendable, Equatable {
        public var hour: Int
        public var hr: Double?
        public var lnRmssd: Double?
        /// Breathing rate from a G-RESP member (WP-09), br/min; nil when not available.
        public var resp: Double?
        /// Workout or movement in this window (ALG-041 / activity class): masked, "exercise response".
        public var exercise: Bool

        public init(hour: Int, hr: Double?, lnRmssd: Double?, resp: Double? = nil, exercise: Bool = false) {
            self.hour = hour
            self.hr = hr
            self.lnRmssd = lnRmssd
            self.resp = resp
            self.exercise = exercise
        }

        func value(_ f: Feature) -> Double? {
            switch f {
            case .hr: return hr
            case .lnRmssd: return lnRmssd
            case .resp: return resp
            }
        }
    }

    public struct SlotKey: Sendable, Hashable {
        public var hour: Int
        public var feature: Feature

        public init(hour: Int, feature: Feature) {
            self.hour = hour
            self.feature = feature
        }
    }

    public struct SlotStat: Sendable, Equatable {
        public var n: Int
        public var mean: Double
        /// ddof 1; 0 below 2 values.
        public var sd: Double

        public init(n: Int, mean: Double, sd: Double) {
            self.n = n
            self.mean = mean
            self.sd = sd
        }
    }

    public struct Baseline: Sendable, Equatable {
        public var slots: [SlotKey: SlotStat]
        /// Earlier calm windows from the current day, pooled across hours. Used only when that hour has not learned a
        /// historical slot yet, so autonomic load can start on day 1 without a population constant.
        public var sameDayCalm: [Feature: SlotStat]
        /// D-POP-PRIOR: days of the person's own stored data behind `slots`. nil = no population prior (the v1 behaviour:
        /// own baseline only, and blank until it exists); a number (0 included) = blend with the population by days / (days + k).
        public var days: Int?

        public init(slots: [SlotKey: SlotStat], sameDayCalm: [Feature: SlotStat] = [:], days: Int? = nil) {
            self.slots = slots
            self.sameDayCalm = sameDayCalm
            self.days = days
        }
    }

    public struct Load: Sendable, Equatable {
        /// Mean of the available z-scores (positive = more load than usual for this hour).
        public var load: Double
        public var zHr: Double?
        public var zLnRmssd: Double?
        public var zResp: Double?
        /// Days of the person's own data behind the baseline (nil = no prior in use). 0 = population only.
        public var daysOwn: Int?

        public init(load: Double, zHr: Double?, zLnRmssd: Double?, zResp: Double?, daysOwn: Int? = nil) {
            self.load = load
            self.zHr = zHr
            self.zLnRmssd = zLnRmssd
            self.zResp = zResp
            self.daysOwn = daysOwn
        }
    }

    /// ALG-054 v1 circadian baseline: per hour-of-day slot and feature, mean and SD (ddof 1) of past non-exercise
    /// windows.
    public static func baseline(history: [Sample], days: Int? = nil) -> Baseline {
        var values: [SlotKey: [Double]] = [:]
        for h in history where !h.exercise {
            for f in Feature.allCases {
                if let v = h.value(f), v.isFinite { values[SlotKey(hour: h.hour, feature: f), default: []].append(v) }
            }
        }
        var slots: [SlotKey: SlotStat] = [:]
        for (k, v) in values {
            slots[k] = SlotStat(n: v.count, mean: SignalMath.mean(v), sd: v.count >= 2 ? SignalMath.sampleSD(v) : 0)
        }
        return Baseline(slots: slots, days: days)
    }

    /// A fallback made only from earlier calm windows of this day. It is deliberately pooled across clock hours: one
    /// day cannot supply 10 earlier 5-min windows for every hour. No population value or fitted coefficient is used.
    public static func sameDayCalmBaseline(_ calm: [Sample]) -> Baseline {
        var values: [Feature: [Double]] = [:]
        for s in calm where !s.exercise {
            for f in Feature.allCases {
                if let v = s.value(f), v.isFinite { values[f, default: []].append(v) }
            }
        }
        var pooled: [Feature: SlotStat] = [:]
        for (f, v) in values {
            pooled[f] = SlotStat(n: v.count, mean: SignalMath.mean(v), sd: v.count >= 2 ? SignalMath.sampleSD(v) : 0)
        }
        return Baseline(slots: [:], sameDayCalm: pooled)
    }

    /// ALG-054 v2 — z of each feature against the same hour's baseline, or earlier calm windows today while that slot
    /// is learning (features with ≥ 10 baseline windows and SD > 0), averaged; needs ≥ 2 features. Exercise windows
    /// are missing ("exercise response, not stress").
    public static func load(_ s: Sample, baseline: Baseline) -> Computed<Load> {
        if s.exercise { return .missing("exercise response, not stress (workout or movement in this window)") }
        var z: [Feature: Double] = [:]
        for f in Feature.allCases {
            guard let v = s.value(f), v.isFinite else { continue }
            let hourly = baseline.slots[SlotKey(hour: s.hour, feature: f)]
            let learned = (hourly?.n ?? 0) >= minBaselineWindows && (hourly?.sd ?? 0) > 0
            // D-POP-PRIOR: population value blended in; a score exists from day one.
            if let days = baseline.days, let pop = population(f) {
                let w = Double(days) / (Double(days) + priorK)
                let own = learned ? hourly : nil
                let mean = own.map { w * $0.mean + (1 - w) * pop.mean } ?? pop.mean
                let sd = own.map { (w * $0.sd * $0.sd + (1 - w) * pop.sd * pop.sd).squareRoot() } ?? pop.sd
                z[f] = f.sign * (v - mean) / sd
                continue
            }
            guard let b = learned ? hourly : baseline.sameDayCalm[f],
                  b.n >= minBaselineWindows, b.sd > 0 else { continue }
            z[f] = f.sign * (v - b.mean) / b.sd
        }
        let got = Feature.allCases.compactMap { z[$0] }
        guard got.count >= minFeatures else {
            return .missing("needs at least \(minFeatures) of HR, RMSSD, breathing with \(minBaselineWindows) "
                            + "baseline windows at this hour or earlier calm windows today")
        }
        var sum = 0.0
        for v in got { sum += v }
        return .success(Load(load: sum / Double(got.count), zHr: z[.hr], zLnRmssd: z[.lnRmssd], zResp: z[.resp],
                              daysOwn: baseline.days))
    }

    /// ALG-054 v1 day value: mean load over the day's non-exercise windows that have one (≥ 3). A learned
    /// hour-of-day slot wins. Until it exists, each window is compared only with earlier calm windows from this day;
    /// the point being scored never leaks into its own baseline. `samples` must be chronological (as
    /// `HRVWindows.analyse` / `samples` produce them).
    public static func day(_ samples: [Sample], baseline: Baseline) -> Computed<Double> {
        let loads = windowLoads(samples, baseline: baseline).compactMap { $0 }
        guard loads.count >= dayMinWindows else {
            return .missing("needs \(dayMinWindows) windows with an autonomic load (have \(loads.count))")
        }
        return .success(SignalMath.mean(loads))
    }

    /// The load of each sample (nil = not scored), in the order given. The same-day calm baseline grows only from
    /// earlier non-exercise samples. Shared by `day` and the daytime stress score (T31).
    public static func windowLoads(_ samples: [Sample], baseline: Baseline) -> [Double?] {
        var calm: [Sample] = []
        var loads: [Double?] = []
        for s in samples {
            var available = baseline
            available.sameDayCalm = sameDayCalmBaseline(calm).sameDayCalm
            loads.append(load(s, baseline: available).value?.load)
            if !s.exercise { calm.append(s) }
        }
        return loads
    }

    /// Daytime HRV accepts only R-R intervals whose second has a known strap activity class of 0 (still). Unknown
    /// class is not assumed calm; classes 1 and 2 are walk/run in the decoded R18 convention.
    public static func stillPoints(_ points: [RRPoint], activity: [R18Second]) -> [RRPoint] {
        let still = Set(activity.compactMap { $0.activityClass == 0 ? $0.ts : nil })
        return points.filter { still.contains($0.ts) }
    }

    /// Baseline samples from stored days: the 5-min `hr_5min` / `hrv_ln_rmssd_5min` series DayPipeline writes (exercise
    /// already masked there), one sample per 5 min that has both. Shared by DayPipeline and the live tile (W10 #94).
    public static func history(series: [LocalDay: [Series]], days: [LocalDay], hourOf: (Int64) -> Int) -> [Sample] {
        var out: [Sample] = []
        for d in days {
            guard let hs = series[d]?.first(where: { $0.name == Baselines.hr5min }),
                  let ls = series[d]?.first(where: { $0.name == Baselines.lnRmssd5min }) else { continue }
            let s0 = Int64(hs.start.timeIntervalSince1970)
            for i in 0..<min(hs.values.count, ls.values.count) {
                guard let hr = hs.values[i], let ln = ls.values[i] else { continue }
                out.append(Sample(hour: hourOf(s0 + Int64(i) * 300), hr: hr, lnRmssd: ln))
            }
        }
        return out
    }

    /// How many of `days` have the stored 5-min HR and lnRMSSD series (the days behind `history`), for `baseline(days:)`.
    public static func historyDays(series: [LocalDay: [Series]], days: [LocalDay]) -> Int {
        days.filter { d in
            series[d]?.contains(where: { $0.name == Baselines.hr5min }) == true
                && series[d]?.contains(where: { $0.name == Baselines.lnRmssd5min }) == true
        }.count
    }

    /// The live load (W10 #94, Live tab; it said "not computed live yet"): the last 5 min of beats as one window —
    /// ALG-004 corrected, refused above 5 % corrected (ALG-004 B) or under ALG-010's minimum beats — HR and lnRMSSD
    /// against the same hour's baseline. A running workout is "exercise response, not stress".
    public static func liveLoad(rrMs: [Double], hour: Int, exercise: Bool, baseline: Baseline) -> Computed<Load> {
        if exercise { return .missing("exercise response, not stress (a workout is running)") }
        guard rrMs.count >= ALG010.minBeats else {
            return .missing("needs a few minutes of clean beats (have \(rrMs.count))")
        }
        let c = ALG004.correct(rrMs: rrMs)
        guard c.correctedFraction <= ALG004.windowMaxArtefactFraction else {
            return .missing("\(Int((c.correctedFraction * 100).rounded())) % of beats were noisy")
        }
        guard let t = ALG010.time(rrMs: c.rrMs).value else { return .missing("no RMSSD from these beats") }
        return load(Sample(hour: hour, hr: 60_000.0 / t.meanRR, lnRmssd: t.lnRmssd), baseline: baseline)
    }

    /// Features of each clean window of a set: HR = 60000 / mean R-R, lnRMSSD from ALG-010. `hourOf` maps a window
    /// start (unix s) to the local hour; `resp` and `exercise` come from the other families / activity.
    public static func samples(_ set: HRVWindowSet, hourOf: (Int64) -> Int, resp: (Int64) -> Double? = { _ in nil },
                               exercise: (Int64) -> Bool = { _ in false }) -> [Sample] {
        set.cleanWindows.compactMap { w in
            guard let t = w.time else { return nil }
            return Sample(hour: hourOf(w.start), hr: 60000.0 / t.meanRR, lnRmssd: t.lnRmssd, resp: resp(w.start),
                          exercise: exercise(w.start))
        }
    }

    public static let spec = MetricSpec(
        key: .stress, unit: "z", group: "G-STRESS", variant: "ALG-054", method: "ALG-054@2 autonomic-load",
        tier: .estimate, source: "rr", window: "day", citation: citation,
        paramsVersion: "hour-slots+population-prior k14 min10 features>=2 day>=3")
}
