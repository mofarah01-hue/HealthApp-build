import Foundation
import MGDomain

/// ALG-036 v1 — strain 0–21, CTL / ATL / TSB, Nes 2011 VO₂max (G-LOAD, G-VO2). Recovery components in band and the illness
/// CUSUM are in ALG036Recovery.swift (same namespace). Python reference: `per_minute_hr`, `daily_quiet_hrr`,
/// `personal_quiet_hrr`, `trimp_banister`, `net_trimp_above_quiet`, `strain_from_net`, `day_strain`, `workout_strain`,
/// `ctl_atl_tsb`, `rhr_7d_median`, `nes_vo2max`, `pa_index_v0`; goldens app/shared/golden/day/ALG-036.json.
///
/// Show components, not one magic score (ALGORITHM-REQUIREMENTS ALG-036): every result struct carries the pieces.
/// Sources: Banister TRIMP weights, Morton, Fitz-Clarke & Banister 1990; "net TRIMP above the quiet-waking level",
/// the 40 % HRR exercise floor, the personal quiet level and the 0–21 map: OpenStrap/analytics load_trimp.dart (main
/// branch, checked 2026-10-11) — TRIMP is published, the 0–21 mapping is not validated; CTL 42 d / ATL 7 d seeded with the
/// mean of the first 7 observed days: OpenStrap ctlAtlTsb; Nes et al., Med Sci Sports Exerc 2011;43(11):2024-2030
/// (waist variant, coefficients as tabulated in JAHA 2020, PMC7428991).
public enum ALG036 {
    public static let method = "ALG-036@1 banister-net-trimp"
    public static let citation = "Morton RH, Fitz-Clarke JR, Banister EW. J Appl Physiol 1990;69(3):1171-1177"
    public static let paramsVersion = "1"

    // MARK: Constants (mirrors of the Python reference)

    /// Net TRIMP that maps to the top of the 0–21 scale (OpenStrap maximalNetTrimp).
    public static let maxNetTrimp = 400.0
    /// Curvature of the 0–21 map (OpenStrap strainCurvature).
    public static let strainCurvature = 15.0
    public static let strainMax = 21.0
    /// ACSM moderate-intensity floor; minutes at or above it are exercise. Also the largest "quiet waking" level.
    public static let exerciseFloorHRR = 0.40
    public static let maxQuietHRR = 0.40
    /// A minute counts as worn with this many on-skin samples (ours).
    public static let minuteMinSamples = 30
    public static let dailyQuietMinMinutes = 60
    /// A day with fewer worn waking minutes has no day strain (ours).
    public static let dayStrainMinMinutes = 60
    public static let quietMinDays = 3
    public static let quietSettledDays = 7
    public static let quietWindowDays = 28
    public static let bpmMaxValid = 250.0
    public static let ctlTauDays = 42.0
    public static let atlTauDays = 7.0
    public static let loadMinDays = 14
    public static let loadPrimeDays = 7
    /// ALG-036:fit, mirrors of STRAIN_FIT_* in the Python reference: strain = a + b·x_mean + c·x_peak, fitted to the
    /// account's exported WHOOP day strain. Refit 2026-10-17 (r9n, D-LOAD-WALK-1 item 1) with the max HR of item 6 and a split by
    /// date: fit on the older 623 days, tested on the newest 208 — in-sample MAE 1.35 / r 0.92, held-out MAE 1.27 / r 0.95; the
    /// constants are the same form fitted on all 831 days (MAE 1.33, r 0.93). One person's fit. Was -7.9 / 25.5 / 21.7 (T19).
    public static let strainFitIntercept = -7.87
    public static let strainFitMean = 26.12
    public static let strainFitPeak = 22.25
    /// The one wording for the fitted 0–21 number (Mo, D-LOAD-WALK-1 item 1): the headline is the TRIMP; this is the scale for people
    /// who know WHOOP's.
    public static let fitLabel = "WHOOP-style strain (estimate)"

    // MARK: Metric specs for WP-22

    public static let strainSpec = MetricSpec(
        key: .strain, unit: "score_0_21", group: "G-LOAD", variant: "ALG-036", method: method, tier: .estimate,
        source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    public static let workoutStrainSpec = MetricSpec(
        key: .strain, unit: "score_0_21", group: "G-LOAD", variant: "ALG-036", method: method, tier: .estimate,
        source: "R18", window: "workout", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    /// The strain HEADLINE (D-LOAD-WALK-1 item 1): the day's plain Banister TRIMP in its own units (not 0–21). A new variant of
    /// `strain` with unit "au" (the registry already holds au variants for MS-01 / MS-02).
    public static let trimpSpec = MetricSpec(
        key: .strain, unit: "au", group: "G-LOAD", variant: "ALG-036:trimp", method: "ALG-036@1 banister-trimp-day",
        tier: .estimate, source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    /// All-day strain fitted to the exported WHOOP days: an estimate, not WHOOP's number.
    public static let strainFitSpec = MetricSpec(
        key: .strain, unit: "score_0_21", group: "G-LOAD", variant: "ALG-036:fit", method: "ALG-036@1 day-strain-fit",
        tier: .estimate, source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    public static let ctlSpec = MetricSpec(
        key: .ctl, unit: "au", group: "G-LOAD", variant: "ALG-036", method: method, tier: .estimate,
        source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    public static let atlSpec = MetricSpec(
        key: .atl, unit: "au", group: "G-LOAD", variant: "ALG-036", method: method, tier: .estimate,
        source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    public static let tsbSpec = MetricSpec(
        key: .tsb, unit: "au", group: "G-LOAD", variant: "ALG-036", method: method, tier: .estimate,
        source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    public static let acwrSpec = MetricSpec(
        key: .acwr, unit: "ratio", group: "G-LOAD", variant: "ALG-036", method: method, tier: .estimate,
        source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    /// Research tier: the physical-activity index scale of the Nes model could not be confirmed (see `paIndexV0`).
    public static let vo2maxSpec = MetricSpec(
        key: .vo2max, unit: "ml_kg_min", group: "G-VO2", variant: "ALG-036", method: "ALG-036@1 nes-2011-waist",
        tier: .research, source: "profile", window: "day", producer: .ours,
        citation: "Nes BM et al. Med Sci Sports Exerc 2011;43(11):2024-2030", paramsVersion: paramsVersion)

    /// HR-ratio VO2max estimate (Uth 2004): 15.3 x HRmax / HRrest. Needs no waist and no activity index, so the calories
    /// row with VO2max never waits on one optional input (Mo 2026-10-14, bug 7). Estimate tier.
    public static let vo2maxUthSpec = MetricSpec(
        key: .vo2max, unit: "ml_kg_min", group: "G-VO2", variant: "ALG-036:uth", method: "ALG-036@1 uth-hr-ratio",
        tier: .estimate, source: "R18", window: "day", producer: .ours,
        citation: "Uth N et al. Eur J Appl Physiol 2004;91(1):111-115 (VO2max = 15.3 x HRmax / HRrest)",
        paramsVersion: paramsVersion)

    // MARK: Per-minute heart rate

    public struct MinuteHR: Sendable, Equatable {
        /// Start of each worn minute (unix s, a multiple of 60).
        public var minuteTs: [Int]
        /// Mean on-skin heart rate of that minute (bpm).
        public var hr: [Double]

        public init(minuteTs: [Int], hr: [Double]) {
            self.minuteTs = minuteTs
            self.hr = hr
        }
    }

    /// ALG-036 v1 — 1 Hz on-skin heart rate → mean HR per worn minute. A sample is on-skin when finite and 0 < bpm ≤ 250
    /// (0 = off-wrist); a minute (floor(ts / 60)) counts when it holds at least 30 such samples.
    public static func perMinuteHR(ts: [Int], bpm: [Double]) -> MinuteHR {
        let (t, b) = DayKit.validPairs(ts: ts, vals: bpm)
        var groups: [Int: [Double]] = [:]
        for i in 0..<t.count where b[i] > 0 && b[i] <= bpmMaxValid {
            groups[DayKit.floorDiv(t[i], 60), default: []].append(b[i])
        }
        let keys = groups.filter { $0.value.count >= minuteMinSamples }.keys.sorted()
        return MinuteHR(minuteTs: keys.map { $0 * 60 }, hr: keys.map { DayKit.mean(groups[$0]!) })
    }

    // MARK: Banister TRIMP

    static func banisterY(_ x: Double, _ sex: DayKit.Sex) -> Double {
        let w = DayKit.banister(sex)
        return w.c * exp(w.b * x)
    }

    /// Fraction of heart-rate reserve, clamped to 0…1.
    static func hrrFraction(_ hr: Double, rhr: Double, hrmax: Double) -> Double {
        min(1.0, max(0.0, (hr - rhr) / (hrmax - rhr)))
    }

    /// ALG-036 v1 — plain Banister TRIMP = Σ over worn minutes of x·y(x), x = %HRR clamped 0…1, y = c·e^(b·x).
    public static func trimp(hrMinutes: [Double], rhr: Double?, hrmax: Double?, sex: Profile.Sex?) -> Computed<Double> {
        DayKit.compute { () throws -> Double in
            let sx = try DayKit.sex(sex).get()
            let a = try DayKit.requireAnchors(rhr: rhr, hrmax: hrmax)
            let vals = hrMinutes.filter { $0.isFinite && $0 > 0 }
            try DayKit.require(!vals.isEmpty, "no worn minutes")
            return trimpSum(vals, a.rhr, a.hrmax, sx)
        }
    }

    static func trimpSum(_ vals: [Double], _ rhr: Double, _ hrmax: Double, _ sx: DayKit.Sex) -> Double {
        var s = 0.0
        for h in vals {
            let x = hrrFraction(h, rhr: rhr, hrmax: hrmax)
            s += x * banisterY(x, sx)
        }
        return s
    }

    public struct DayTrimp: Sendable, Equatable {
        /// Σ x·y(x) over the worn waking minutes, in TRIMP units.
        public var trimp: Double
        public var wornMinutes: Int

        public init(trimp: Double, wornMinutes: Int) {
            self.trimp = trimp
            self.wornMinutes = wornMinutes
        }
    }

    /// ALG-036:trimp — the strain headline: the day's plain Banister TRIMP over its worn WAKING minutes, in its own units. Needs 60
    /// worn minutes; no quiet-level history, so it exists from the first day. Python reference: `day_trimp`.
    public static func dayTrimp(hrMinutes: [Double], rhr: Double?, hrmax: Double?, sex: Profile.Sex?) -> Computed<DayTrimp> {
        DayKit.compute { () throws -> DayTrimp in
            let sx = try DayKit.sex(sex).get()
            let a = try DayKit.requireAnchors(rhr: rhr, hrmax: hrmax)
            let worn = hrMinutes.filter { $0.isFinite && $0 > 0 }
            try DayKit.require(worn.count >= dayStrainMinMinutes,
                               "needs \(dayStrainMinMinutes) worn waking minutes (have \(worn.count))")
            return DayTrimp(trimp: trimpSum(worn, a.rhr, a.hrmax, sx), wornMinutes: worn.count)
        }
    }

    // MARK: Quiet-waking level

    /// ALG-036 v1 — this day's quiet-waking level = the MEDIAN %HRR over its worn waking minutes. Missing under
    /// `minMinutes`, and when the median is 0 or above 0.40.
    public static func dailyQuietHRR(hrMinutes: [Double], rhr: Double?, hrmax: Double?,
                                     minMinutes: Int = ALG036.dailyQuietMinMinutes) -> Computed<Double> {
        DayKit.compute { () throws -> Double in
            let a = try DayKit.requireAnchors(rhr: rhr, hrmax: hrmax)
            let xs = hrMinutes.filter { $0.isFinite && $0 > 0 }.map { hrrFraction($0, rhr: a.rhr, hrmax: a.hrmax) }
            try DayKit.require(xs.count >= minMinutes, "needs \(minMinutes) worn waking minutes (have \(xs.count))")
            let q = DayKit.median(xs)
            try DayKit.require(q > 0 && q <= maxQuietHRR, "the day's median heart rate is not a quiet-waking level")
            return q
        }
    }

    public struct QuietLevel: Sendable, Equatable {
        public var q: Double
        public var days: Int
        /// True from 7 days.
        public var settled: Bool

        public init(q: Double, days: Int, settled: Bool) {
            self.q = q
            self.days = days
            self.settled = settled
        }
    }

    /// ALG-036 v1 — the trait: median of the last ≤ 28 valid daily levels (finite, 0 < q ≤ 0.40), oldest first. Needs 3
    /// days. Never falls back to a population constant.
    public static func personalQuietHRR(dailyLevels: [Double?]) -> Computed<QuietLevel> {
        var valid: [Double] = []
        for v in dailyLevels {
            if let v, v.isFinite, v > 0, v <= maxQuietHRR { valid.append(v) }
        }
        if valid.count > quietWindowDays { valid = Array(valid.suffix(quietWindowDays)) }
        if valid.count < quietMinDays {
            return .missing("Learning your quiet-waking level: \(valid.count) of \(quietMinDays) days so far")
        }
        return .success(QuietLevel(q: DayKit.median(valid), days: valid.count, settled: valid.count >= quietSettledDays))
    }

    // MARK: Net TRIMP above the quiet level, and the 0–21 map

    public struct NetTrimp: Sendable, Equatable {
        public var net: Double
        public var exercise: Double
        public var living: Double
        public var minutes: Int
        public var exerciseMinutes: Int

        public init(net: Double, exercise: Double, living: Double, minutes: Int, exerciseMinutes: Int) {
            self.net = net
            self.exercise = exercise
            self.living = living
            self.minutes = minutes
            self.exerciseMinutes = exerciseMinutes
        }
    }

    /// ALG-036 v1 — TRIMP earned ABOVE the quiet-waking level. Every worn minute is charged what quiet waking would
    /// cost, c = x·y(x) − q·y(q). Minutes at or above 40 % HRR are exercise and always add; the rest are living, whose
    /// total is floored at 0 as a block, so quiet minutes can never cancel exercise credit. net = exercise + max(0, living).
    public static func netTrimpAboveQuiet(hrMinutes: [Double], rhr: Double?, hrmax: Double?, sex: Profile.Sex?,
                                          q: Double?) -> Computed<NetTrimp> {
        DayKit.compute { () throws -> NetTrimp in
            let sx = try DayKit.sex(sex).get()
            let a = try DayKit.requireAnchors(rhr: rhr, hrmax: hrmax)
            guard let q, q.isFinite, q > 0, q <= maxQuietHRR else {
                throw Missing("needs a quiet-waking level above 0 and at most 0.40")
            }
            let charge = q * banisterY(q, sx)
            var exercise = 0.0
            var living = 0.0
            var nEx = 0
            var n = 0
            for h in hrMinutes where h.isFinite && h > 0 {
                let x = hrrFraction(h, rhr: a.rhr, hrmax: a.hrmax)
                let c = x * banisterY(x, sx) - charge
                n += 1
                if x >= exerciseFloorHRR {
                    exercise += c
                    nEx += 1
                } else {
                    living += c
                }
            }
            try DayKit.require(n > 0, "no worn minutes")
            return NetTrimp(net: exercise + max(0.0, living), exercise: exercise, living: living, minutes: n,
                            exerciseMinutes: nEx)
        }
    }

    /// ALG-036 v1 — 0…21 strain = 21·ln(1 + 14u)/ln 15 with u = min(1, net/400); 0 for net ≤ 0. The mapping is
    /// OpenStrap's and is not validated.
    public static func strain(fromNet net: Double) -> Double {
        if !net.isFinite || net <= 0 { return 0.0 }
        let u = min(1.0, net / maxNetTrimp)
        let s = strainMax * log(1.0 + u * (strainCurvature - 1.0)) / log(strainCurvature)
        return min(strainMax, max(0.0, s))
    }

    public struct DayStrain: Sendable, Equatable {
        public var strain: Double
        public var netTrimp: Double
        /// Plain Banister TRIMP of the same minutes, shown beside the strain so the maths can be checked.
        public var trimp: Double
        public var quietHRR: Double
        public var quietDays: Int
        public var quietSettled: Bool
        public var exerciseMinutes: Int
        public var wornMinutes: Int

        public init(strain: Double, netTrimp: Double, trimp: Double, quietHRR: Double, quietDays: Int, quietSettled: Bool,
                    exerciseMinutes: Int, wornMinutes: Int) {
            self.strain = strain
            self.netTrimp = netTrimp
            self.trimp = trimp
            self.quietHRR = quietHRR
            self.quietDays = quietDays
            self.quietSettled = quietSettled
            self.exerciseMinutes = exerciseMinutes
            self.wornMinutes = wornMinutes
        }
    }

    /// ALG-036 v1 — day strain 0…21 from the day's worn WAKING minutes (the caller excludes sleep) against the personal
    /// quiet-waking level of the PREVIOUS days (`quietHistory`, oldest first; today's own level is not used, so a day
    /// spent walking cannot subtract its own effort). Needs 60 worn minutes and 3 earlier quiet levels.
    public static func dayStrain(hrMinutes: [Double], rhr: Double?, hrmax: Double?, sex: Profile.Sex?,
                                 quietHistory: [Double?]) -> Computed<DayStrain> {
        DayKit.compute { () throws -> DayStrain in
            let sx = try DayKit.sex(sex).get()
            let a = try DayKit.requireAnchors(rhr: rhr, hrmax: hrmax)
            let worn = hrMinutes.filter { $0.isFinite && $0 > 0 }
            try DayKit.require(worn.count >= dayStrainMinMinutes,
                               "needs \(dayStrainMinMinutes) worn waking minutes (have \(worn.count))")
            let pq = try personalQuietHRR(dailyLevels: quietHistory).get()
            let nt = try netTrimpAboveQuiet(hrMinutes: worn, rhr: a.rhr, hrmax: a.hrmax, sex: sex, q: pq.q).get()
            return DayStrain(strain: strain(fromNet: nt.net), netTrimp: nt.net, trimp: trimpSum(worn, a.rhr, a.hrmax, sx),
                             quietHRR: pq.q, quietDays: pq.days, quietSettled: pq.settled,
                             exerciseMinutes: nt.exerciseMinutes, wornMinutes: nt.minutes)
        }
    }

    public struct WorkoutStrain: Sendable, Equatable {
        public var strain: Double
        public var netTrimp: Double
        public var minutes: Int
        public var exerciseMinutes: Int

        public init(strain: Double, netTrimp: Double, minutes: Int, exerciseMinutes: Int) {
            self.strain = strain
            self.netTrimp = netTrimp
            self.minutes = minutes
            self.exerciseMinutes = exerciseMinutes
        }
    }

    /// ALG-036 v1 — the same net-above-quiet maths and 0…21 map on one workout's minutes (a session and a day share a
    /// scale).
    public static func workoutStrain(hrMinutes: [Double], rhr: Double?, hrmax: Double?, sex: Profile.Sex?,
                                     q: Double?) -> Computed<WorkoutStrain> {
        DayKit.compute { () throws -> WorkoutStrain in
            let nt = try netTrimpAboveQuiet(hrMinutes: hrMinutes, rhr: rhr, hrmax: hrmax, sex: sex, q: q).get()
            return WorkoutStrain(strain: strain(fromNet: nt.net), netTrimp: nt.net, minutes: nt.minutes,
                                 exerciseMinutes: nt.exerciseMinutes)
        }
    }

    public static func strainFit(meanHR: Double, peakHR: Double, rhr: Double, hrmax: Double) -> Double {
        let s = strainFitIntercept + strainFitMean * hrrFraction(meanHR, rhr: rhr, hrmax: hrmax)
            + strainFitPeak * hrrFraction(peakHR, rhr: rhr, hrmax: hrmax)
        return min(strainMax, max(0.0, s))
    }

    public struct DayStrainFit: Sendable, Equatable {
        public var strain: Double
        public var meanHR: Double
        public var peakHR: Double
        public var wornMinutes: Int

        public init(strain: Double, meanHR: Double, peakHR: Double, wornMinutes: Int) {
            self.strain = strain
            self.meanHR = meanHR
            self.peakHR = peakHR
            self.wornMinutes = wornMinutes
        }
    }

    /// ALG-036:fit v1 — all-day 0…21 estimate from the day's worn minutes (sleep included, as WHOOP's day average is).
    /// Needs 60 worn minutes, resting HR and HRmax; no sex, no quiet-level history and no workout, so a rest day is not 0.
    public static func dayStrainFit(hrMinutes: [Double], rhr: Double?, hrmax: Double?) -> Computed<DayStrainFit> {
        DayKit.compute { () throws -> DayStrainFit in
            let a = try DayKit.requireAnchors(rhr: rhr, hrmax: hrmax)
            let worn = hrMinutes.filter { $0.isFinite && $0 > 0 }
            try DayKit.require(worn.count >= dayStrainMinMinutes, "needs \(dayStrainMinMinutes) worn minutes (have \(worn.count))")
            let mean = DayKit.mean(worn)
            let peak = worn.max() ?? mean
            return DayStrainFit(strain: strainFit(meanHR: mean, peakHR: peak, rhr: a.rhr, hrmax: a.hrmax), meanHR: mean,
                                peakHR: peak, wornMinutes: worn.count)
        }
    }

    // MARK: CTL / ATL / TSB

    /// λ = 1 − e^(−1/τ) for a time constant in days.
    public static func lambda(tauDays: Double) -> Double {
        1.0 - exp(-1.0 / tauDays)
    }

    public struct Load: Sendable, Equatable {
        public var ctl: Double
        public var atl: Double
        public var tsb: Double
        /// ATL / CTL; nil when CTL is not above 0.
        public var acwr: Double?
        public var observedDays: Int
        /// Share of the last ≤ 42 calendar days that carried a value.
        public var coverage42d: Double

        public init(ctl: Double, atl: Double, tsb: Double, acwr: Double?, observedDays: Int, coverage42d: Double) {
            self.ctl = ctl
            self.atl = atl
            self.tsb = tsb
            self.acwr = acwr
            self.observedDays = observedDays
            self.coverage42d = coverage42d
        }
    }

    /// ALG-036 v1 — Banister fitness-fatigue: CTL (42-day) and ATL (7-day) exponentially weighted means of the daily
    /// load, λ = 1 − e^(−1/τ); TSB = CTL − ATL; ACWR = ATL / CTL. `dailyLoad` = one entry per CALENDAR day, oldest first
    /// (net TRIMP above quiet, au); nil = the strap gave no information that day, and the day is SKIPPED (the average
    /// carries over) rather than counted as a 0-load rest day. Both averages start at the mean of the first 7 observed days.
    public static func ctlAtlTsb(dailyLoad: [Double?], tauCTL: Double = ALG036.ctlTauDays, tauATL: Double = ALG036.atlTauDays,
                                 minDays: Int = ALG036.loadMinDays, primeDays: Int = ALG036.loadPrimeDays) -> Computed<Load> {
        var obs: [Double] = []
        for v in dailyLoad {
            if let v, v.isFinite, v >= 0 { obs.append(v) }
        }
        if obs.count < minDays { return .missing("Learning your load: \(obs.count) of \(minDays) days so far") }
        let seed = DayKit.mean(Array(obs.prefix(primeDays)))
        let lc = lambda(tauDays: tauCTL)
        let la = lambda(tauDays: tauATL)
        var ctl = seed
        var atl = seed
        for v in obs.dropFirst(primeDays) {
            ctl = ctl + lc * (v - ctl)
            atl = atl + la * (v - atl)
        }
        let tail = Array(dailyLoad.suffix(42))
        var have = 0
        for v in tail {
            if let v, v.isFinite, v >= 0 { have += 1 }
        }
        return .success(Load(ctl: ctl, atl: atl, tsb: ctl - atl, acwr: ctl > 0 ? atl / ctl : nil,
                             observedDays: obs.count, coverage42d: Double(have) / Double(tail.count)))
    }

    // MARK: Nes 2011 VO₂max

    struct NesCoefficients {
        let intercept: Double
        let age: Double
        let pa: Double
        let waist: Double
        let rhr: Double
        let see: Double
    }

    static func nes(_ sex: DayKit.Sex) -> NesCoefficients {
        switch sex {
        case .male: return NesCoefficients(intercept: 100.27, age: 0.296, pa: 0.226, waist: 0.369, rhr: 0.155, see: 5.70)
        case .female: return NesCoefficients(intercept: 74.736, age: 0.247, pa: 0.198, waist: 0.259, rhr: 0.114, see: 5.14)
        }
    }

    /// The HUNT3 Fitness Study adults the model was fitted on.
    public static let nesAgeRange: ClosedRange<Double> = 20.0...90.0

    /// ALG-036 v1 — resting HR for the Nes model = median of the last 7 nights, needing at least 4 valid ones.
    public static func rhr7dMedian(nights: [Double?]) -> Computed<Double> {
        var valid: [Double] = []
        for v in nights.suffix(7) {
            if let v, v.isFinite, v > 0 { valid.append(v) }
        }
        if valid.count < 4 { return .missing("needs resting HR on 4 of the last 7 nights (have \(valid.count))") }
        return .success(DayKit.median(valid))
    }

    static func nesInputs(age: Double?, sex: Profile.Sex?, rhr: Double?, paIndex: Double?) throws
        -> (sex: DayKit.Sex, age: Double, rhr: Double, pa: Double) {
        let sx = try DayKit.sex(sex).get()
        guard let age, age.isFinite, nesAgeRange.contains(age) else { throw Missing("the Nes model was fitted on ages 20 to 90") }
        guard let rhr, rhr.isFinite, rhr >= 30, rhr <= 120 else { throw Missing("needs resting heart rate between 30 and 120 bpm") }
        guard let pa = paIndex, pa.isFinite, pa >= 0 else { throw Missing("needs a physical-activity index") }
        return (sx, age, rhr, pa)
    }

    public struct Vo2max: Sendable, Equatable {
        /// ml·kg⁻¹·min⁻¹.
        public var vo2max: Double
        /// The model's standard error of estimate, the honest spread.
        public var see: Double

        public init(vo2max: Double, see: Double) {
            self.vo2max = vo2max
            self.see = see
        }
    }

    /// ALG-036 v1 — Uth 2004 HR-ratio VO2max: 15.3 x HRmax / HRrest (ml/kg/min). Estimate, accurate to roughly 10 to 15 %.
    public static func uthVO2max(hrmax: Double?, rhr: Double?) -> Computed<Double> {
        guard let hrmax, let rhr, hrmax.isFinite, rhr.isFinite, rhr >= 30, rhr <= 120, hrmax > rhr, hrmax <= 250 else {
            return .missing("needs resting heart rate (30 to 120 bpm) and a max heart rate above it")
        }
        return .success(15.3 * hrmax / rhr)
    }

    /// ALG-036 v1 — Nes 2011 non-exercise VO₂max, waist variant. Missing until the profile has a waist circumference.
    public static func nesVO2max(age: Double?, sex: Profile.Sex?, rhr: Double?, paIndex: Double?, waistCm: Double?)
        -> Computed<Vo2max> {
        DayKit.compute { () throws -> Vo2max in
            let i = try nesInputs(age: age, sex: sex, rhr: rhr, paIndex: paIndex)
            guard let waistCm, waistCm.isFinite, waistCm >= 50, waistCm <= 200 else {
                throw Missing("needs waist circumference (cm) - add it in Settings")
            }
            let c = nes(i.sex)
            return Vo2max(vo2max: c.intercept - c.age * i.age + c.pa * i.pa - c.waist * waistCm - c.rhr * i.rhr, see: c.see)
        }
    }

    /// ALG-036 v0 (ours, research tier) — a stand-in for the HUNT questionnaire index = frequency × intensity × duration,
    /// from measured weekly numbers, with noop's category weights. Frequency (active days of the last 7): 0 → 0, 1 → 0.5,
    /// 2 → 1, 3–4 → 2.5, 5+ → 5. Intensity (share of active time in HR zones 4–5): < 0.15 → 1, < 0.5 → 2, else 3.
    /// Duration (mean active minutes per active day): < 15 → 0.10, < 30 → 0.38, < 60 → 0.75, else 1.0.
    /// UNVERIFIED: the questionnaire's published scale could not be confirmed (noop uses 0–15, its own doc says 0–7.5,
    /// JAHA 2020 tabulates the HUNT scale as 0–45), so anything built on this index stays research tier.
    public static func paIndexV0(activeDays: Double?, avgActiveMin: Double?, highIntensityFraction: Double?) -> Computed<Double> {
        guard let activeDays, let avgActiveMin, let highIntensityFraction, activeDays.isFinite, avgActiveMin.isFinite,
              highIntensityFraction.isFinite else {
            return .missing("needs active days, minutes per active day and the high-intensity share")
        }
        if activeDays < 1 { return .success(0.0) }
        let freq = activeDays < 2 ? 0.5 : activeDays < 3 ? 1.0 : activeDays < 5 ? 2.5 : 5.0
        let inten = highIntensityFraction < 0.15 ? 1.0 : highIntensityFraction < 0.5 ? 2.0 : 3.0
        let dur = avgActiveMin < 15 ? 0.10 : avgActiveMin < 30 ? 0.38 : avgActiveMin < 60 ? 0.75 : 1.0
        return .success(freq * inten * dur)
    }
}
