import Foundation
import MGDomain

/// ALG-048 v2 — calories burned (G-CAL): Keytel 2005 heart-rate energy expenditure with and without VO₂max, and Mifflin-St Jeor
/// resting energy, joined by the HR-flex method (Spurr et al. 1988). Python reference: `keytel_kj_per_min`,
/// `mifflin_bmr_kcal_day`, `active_calories`, `flex_day_inputs`, `flex_hr`; goldens
/// app/shared/golden/day/ALG-048.json. Brage branched HR + movement, cadence METs and lean-mass resting energy are X
/// (need the IMU / a body scan).
///
/// Sources: Keytel LR et al., J Sports Sci 2005;23(3):289-297 (equations as printed by selfloops.com and Hexoskin, kJ/min);
/// Mifflin MD et al., Am J Clin Nutr 1990;51(2):241-247.
///
/// v2 (2026-10-17, Mo, D-LOAD-WALK-1 item 4): the 0.40-of-reserve gate (OpenStrap's choice, "not something Keytel prints") is
/// replaced by the published HR-flex method. Spurr GB et al., Am J Clin Nutr 1988;48(3):552-559 and Ceesay SM et al., Br J Nutr
/// 1989;61(2):175-186: below the person's FLEX HR the body is billed resting energy; at or above it the individual HR-energy line.
/// FLEX HR = the mean of the HIGHEST RESTING heart rate and the LOWEST heart rate of the LIGHTEST EXERCISE. Spurr measures both
/// in a calibration session; with the strap's own inputs: resting = worn minutes its activity class calls still (class 0) →
/// 95th percentile (a raw maximum is one optical artefact); lightest exercise = worn minutes it calls walk / run (class 1 / 2) →
/// 5th percentile; each day's pair → median over the days → mean of the two (`flexHR`). The individual line is Keytel with the
/// person's own age / weight / sex (and VO₂max). The 0.40 point stays only as the labelled default while the person's own FLEX HR
/// is still being learned (3 days with each value).
public enum ALG048 {
    public static let method = "ALG-048@1 keytel-hr-flex"
    public static let citation = "Keytel LR et al. J Sports Sci 2005;23(3):289-297"
    public static let paramsVersion = "1"

    /// kJ per kcal.
    public static let kjPerKcal = 4.184
    /// DEFAULT flex point as a fraction of heart-rate reserve (OpenStrap's choice), used only until the person's own FLEX HR exists.
    public static let flexHRR = 0.40
    /// FLEX-HR derivation constants (ours v0, see the header): a minute is still / moving when this share of its classed seconds is.
    public static let flexClassShare = 0.9
    public static let flexMinClassedSeconds = 30
    public static let flexMinRestMinutes = 30
    public static let flexMinExerciseMinutes = 10
    public static let flexRestPercentile = 95.0
    public static let flexExercisePercentile = 5.0
    public static let flexMinDays = 3

    public static let keytelSpec = MetricSpec(
        key: .caloriesActive, unit: "kcal", group: "G-CAL", variant: "ALG-048:keytel", method: method, tier: .estimate,
        source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    /// The with-VO₂max member. A new variant name (addition only): the registry needs `ALG-048:keytel_vo2` for `calories_active`.
    public static let keytelVO2Spec = MetricSpec(
        key: .caloriesActive, unit: "kcal", group: "G-CAL", variant: "ALG-048:keytel_vo2", method: method, tier: .estimate,
        source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    public static let mifflinSpec = MetricSpec(
        key: .caloriesBasal, unit: "kcal", group: "G-CAL", variant: "ALG-048:mifflin", method: "ALG-048@1 mifflin-st-jeor",
        tier: .estimate, source: "profile", window: "day", producer: .ours,
        citation: "Mifflin MD et al. Am J Clin Nutr 1990;51(2):241-247", paramsVersion: paramsVersion)
    /// v3 (D-LOAD-WALK-2): resting energy from the fat-free mass of a body-composition scan.
    public static let cunninghamSpec = MetricSpec(
        key: .caloriesBasal, unit: "kcal", group: "G-CAL", variant: "ALG-048:cunningham", method: "ALG-048@3 cunningham",
        tier: .estimate, source: "profile", window: "day", producer: .ours,
        citation: "Cunningham JJ. Am J Clin Nutr 1980;33(11):2372-2374", paramsVersion: paramsVersion)
    /// v3: the LOW end of the active-calories range — only minutes where heart rate AND the strap's motion agree.
    public static let keytelMotionSpec = MetricSpec(
        key: .caloriesActive, unit: "kcal", group: "G-CAL", variant: "ALG-048:keytel_motion", method: "ALG-048@3 keytel+motion",
        tier: .estimate, source: "R18", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)

    /// D-POP-PRIOR: the population flex point counts as this many days of evidence (ours v0).
    public static let flexShrinkK = 7.0

    /// ALG-048 v3 — the flex HR used: the population point until the person's own FLEX HR has days behind it, then
    /// (n x own + k x prior) / (n + k).
    public static func shrinkFlex(own: Double?, days: Int, prior: Double) -> Computed<Double> {
        DayKit.compute { () throws -> Double in
            try DayKit.require(prior.isFinite, "needs the population flex point (resting and max heart rate)")
            guard let o = own, o.isFinite, days > 0 else { return prior }
            return (Double(days) * o + flexShrinkK * prior) / (Double(days) + flexShrinkK)
        }
    }

    public static let cunninghamIntercept = 500.0
    public static let cunninghamPerKgFFM = 22.0

    /// ALG-048 v3 — Cunningham 1980 resting energy, kcal/day: 500 + 22 x fat-free mass (kg).
    public static func cunninghamBMR(ffmKg: Double?) -> Computed<Double> {
        DayKit.compute { () throws -> Double in
            try DayKit.require(ffmKg.map { $0.isFinite && $0 > 0 } ?? false, "needs fat-free mass")
            return cunninghamIntercept + cunninghamPerKgFFM * (ffmKg ?? 0)
        }
    }

    /// ALG-048 v1 — Keytel 2005 gross energy expenditure in kJ/min (≥ 0). With `vo2max` (ml·kg⁻¹·min⁻¹) the second
    /// published equation is used (r 0.913 against 0.857 without). Men and women only — the caller has checked the sex.
    static func keytelKJPerMin(hr: Double, weightKg: Double, age: Double, sex: DayKit.Sex, vo2max: Double?) -> Double {
        let ee: Double
        if let v = vo2max {
            switch sex {
            case .male: ee = -95.7735 + 0.634 * hr + 0.404 * v + 0.394 * weightKg + 0.271 * age
            case .female: ee = -59.3954 + 0.450 * hr + 0.380 * v + 0.103 * weightKg + 0.274 * age
            }
        } else {
            switch sex {
            case .male: ee = -55.0969 + 0.6309 * hr + 0.1988 * weightKg + 0.2017 * age
            case .female: ee = -20.4022 + 0.4472 * hr + -0.1263 * weightKg + 0.074 * age
            }
        }
        return max(0.0, ee)
    }

    /// ALG-048 v1 — Keytel energy expenditure, kJ/min. Missing for sex "other" / unset.
    public static func keytelKJPerMin(hr: Double, weightKg: Double, age: Double, sex: Profile.Sex?, vo2max: Double? = nil)
        -> Computed<Double> {
        DayKit.compute { () throws -> Double in
            let sx = try DayKit.sex(sex).get()
            return keytelKJPerMin(hr: hr, weightKg: weightKg, age: age, sex: sx, vo2max: vo2max)
        }
    }

    /// ALG-048 v1 — Mifflin-St Jeor resting energy, kcal/day: 10·W + 6.25·H − 5·A + 5 (men) / − 161 (women). No value for
    /// "other": noop and OpenStrap average the two constants (−78), which is nobody's equation.
    public static func mifflinBMR(weightKg: Double?, heightCm: Double?, age: Double?, sex: Profile.Sex?) -> Computed<Double> {
        DayKit.compute { () throws -> Double in
            let sx = try DayKit.sex(sex).get()
            guard let w = weightKg, let h = heightCm, let a = age, w.isFinite, h.isFinite, a.isFinite, w > 0, h > 0, a > 0 else {
                throw Missing("needs weight, height and age")
            }
            let base = 10.0 * w + 6.25 * h - 5.0 * a
            return max(0.0, base + (sx == .male ? 5.0 : -161.0))
        }
    }

    // MARK: FLEX HR (Spurr 1988)

    /// Value at nearest rank round(pct/100·(n−1)) (round half up) of the sorted values. Mirrors `_pct_sorted`.
    static func percentile(_ vals: [Double], _ pct: Double) -> Double {
        let v = vals.sorted()
        return v[Int((pct / 100.0 * Double(v.count - 1) + 0.5).rounded(.down))]
    }

    public struct FlexDay: Sendable, Equatable {
        /// 95th percentile of the day's still worn minutes (nil under 30 such minutes).
        public var restHigh: Double?
        /// 5th percentile of the day's walk / run worn minutes (nil under 10).
        public var exerciseLow: Double?
        public var restMinutes: Int
        public var exerciseMinutes: Int

        public init(restHigh: Double?, exerciseLow: Double?, restMinutes: Int, exerciseMinutes: Int) {
            self.restHigh = restHigh
            self.exerciseLow = exerciseLow
            self.restMinutes = restMinutes
            self.exerciseMinutes = exerciseMinutes
        }
    }

    /// ALG-048 v2 — one day's two FLEX-HR ingredients. `minuteTs` / `minuteHR` = worn minutes (`ALG036.perMinuteHR`), `classTs` /
    /// `classes` = the strap's per-second activity class (0 still, 1 walk, 2 run). A minute is still (moving) when at least 90 % of
    /// its classed seconds are, and it has 30 of them.
    public static func flexDay(minuteTs: [Int], minuteHR: [Double], classTs: [Int], classes: [Int]) -> FlexDay {
        var per: [Int: (still: Int, moving: Int, all: Int)] = [:]
        for i in 0..<min(classTs.count, classes.count) {
            let k = DayKit.floorDiv(classTs[i], 60)
            var row = per[k] ?? (0, 0, 0)
            row.all += 1
            if classes[i] == 0 { row.still += 1 } else if classes[i] == 1 || classes[i] == 2 { row.moving += 1 }
            per[k] = row
        }
        var rest: [Double] = []
        var ex: [Double] = []
        for i in 0..<min(minuteTs.count, minuteHR.count) {
            guard let row = per[DayKit.floorDiv(minuteTs[i], 60)], row.all >= flexMinClassedSeconds,
                  minuteHR[i].isFinite, minuteHR[i] > 0 else { continue }
            if Double(row.still) >= flexClassShare * Double(row.all) {
                rest.append(minuteHR[i])
            } else if Double(row.moving) >= flexClassShare * Double(row.all) {
                ex.append(minuteHR[i])
            }
        }
        return FlexDay(restHigh: rest.count >= flexMinRestMinutes ? percentile(rest, flexRestPercentile) : nil,
                       exerciseLow: ex.count >= flexMinExerciseMinutes ? percentile(ex, flexExercisePercentile) : nil,
                       restMinutes: rest.count, exerciseMinutes: ex.count)
    }

    public struct Flex: Sendable, Equatable {
        public var flexBpm: Double
        public var restHigh: Double
        public var exerciseLow: Double
        public var restDays: Int
        public var exerciseDays: Int

        public init(flexBpm: Double, restHigh: Double, exerciseLow: Double, restDays: Int, exerciseDays: Int) {
            self.flexBpm = flexBpm
            self.restHigh = restHigh
            self.exerciseLow = exerciseLow
            self.restDays = restDays
            self.exerciseDays = exerciseDays
        }
    }

    /// ALG-048 v2 — the person's FLEX HR (Spurr 1988): mean of the highest resting HR and the lowest exercise HR, each the median of
    /// the daily values (oldest first, nil = a day without one); needs 3 days of each. If the lightest exercise sits at or below
    /// the highest resting HR the flex point is the resting one.
    public static func flexHR(restHighs: [Double?], exerciseLows: [Double?]) -> Computed<Flex> {
        let rv = restHighs.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        let ev = exerciseLows.compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        guard rv.count >= flexMinDays, ev.count >= flexMinDays else {
            return .missing("learning your flex heart rate: \(rv.count) resting and \(ev.count) walking days of \(flexMinDays) so far")
        }
        let rest = DayKit.median(rv)
        let ex = DayKit.median(ev)
        return .success(Flex(flexBpm: ex > rest ? (rest + ex) / 2.0 : rest, restHigh: rest, exerciseLow: ex,
                             restDays: rv.count, exerciseDays: ev.count))
    }

    public struct Calories: Sendable, Equatable {
        public var activeKcal: Double
        public var basalKcal: Double
        public var totalKcal: Double
        /// Seconds billed at the Keytel rate.
        public var billedS: Double
        /// Seconds the heart-rate samples cover.
        public var coveredS: Double
        /// The HR-flex gate actually used: the person's FLEX HR, else the default rhr + 0.40·(hrmax − rhr).
        public var gateBpm: Double

        public init(activeKcal: Double, basalKcal: Double, totalKcal: Double, billedS: Double, coveredS: Double, gateBpm: Double) {
            self.activeKcal = activeKcal
            self.basalKcal = basalKcal
            self.totalKcal = totalKcal
            self.billedS = billedS
            self.coveredS = coveredS
            self.gateBpm = gateBpm
        }
    }

    /// ALG-048 v2 — active and basal kcal over a heart-rate stream (a workout window or a day). HR-flex (Spurr 1988): a sample at or
    /// above the flex point is billed the Keytel rate (HR capped at HRmax) MINUS the Mifflin basal rate of the same time (≥ 0 per
    /// sample); samples below it bill nothing active (resting energy only). The flex point is `flexBpm` (`flexHR`) when given and
    /// below HRmax, else the labelled default rhr + 0.40·(hrmax − rhr). basal = Mifflin kcal/day / 1440 × `windowMinutes`
    /// (default: the time the samples cover). `vo2max` selects the with-VO₂max equation (Missing when not > 0).
    public static func activeCalories(hrTs: [Int], hrBpm: [Double], rhr: Double?, hrmax: Double?, weightKg: Double?,
                                      heightCm: Double?, age: Double?, sex: Profile.Sex?, vo2max: Double? = nil,
                                      windowMinutes: Double? = nil, flexBpm: Double? = nil,
                                      movingMinutes: Set<Int>? = nil, bmrKcalDay: Double? = nil) -> Computed<Calories> {
        DayKit.compute { () throws -> Calories in
            let sx = try DayKit.sex(sex).get()
            let a = try DayKit.requireAnchors(rhr: rhr, hrmax: hrmax)
            let bmr = try bmrKcalDay ?? mifflinBMR(weightKg: weightKg, heightCm: heightCm, age: age, sex: sex).get()
            if let v = vo2max { try DayKit.require(v.isFinite && v > 0, "needs VO2max for the with-VO2max equation") }
            let (t, b) = DayKit.validPairs(ts: hrTs, vals: hrBpm)
            var tt: [Int] = []
            var bb: [Double] = []
            for i in 0..<t.count where b[i] > 0 {
                tt.append(t[i])
                bb.append(b[i])
            }
            try DayKit.require(tt.count >= 2, "needs at least two heart-rate samples")
            let dur = DayKit.sampleDurations(tt)
            try DayKit.require((dur.max() ?? 0) <= ALG106.zoneMaxCadenceSeconds, "heart-rate samples are more than 60 s apart")
            var gate = a.rhr + flexHRR * (a.hrmax - a.rhr)
            if let f = flexBpm, f.isFinite, f > 0, f < a.hrmax { gate = f }
            let basalPerMin = bmr / 1440.0
            var active = 0.0
            var billed = 0.0
            for i in 0..<bb.count where bb[i] >= gate {
                if let mm = movingMinutes, !mm.contains(Int((Double(tt[i]) / 60.0).rounded(.down))) { continue }
                let kcalMin = keytelKJPerMin(hr: min(bb[i], a.hrmax), weightKg: weightKg ?? 0, age: age ?? 0, sex: sx,
                                             vo2max: vo2max) / kjPerKcal
                active += max(0.0, kcalMin - basalPerMin) * (dur[i] / 60.0)
                billed += dur[i]
            }
            var covered = 0.0
            for d in dur { covered += d }
            let winMin = windowMinutes ?? (covered / 60.0)
            let basal = basalPerMin * winMin
            return Calories(activeKcal: active, basalKcal: basal, totalKcal: active + basal, billedS: billed, coveredS: covered,
                            gateBpm: gate)
        }
    }
}
