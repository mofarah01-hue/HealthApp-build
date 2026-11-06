import Foundation
import MGDomain

/// ALG-106 v1 — HRmax variants and heart-rate zones (G-HRMAX). Measured and Tanaka are both returned, labelled; the
/// zone bar shows the primary one with its basis text. Python reference: `tanaka_hrmax`, `observed_hrmax`,
/// `hrmax_variants`, `zone_edges`, `zone_of`, `time_in_zones`; goldens app/shared/golden/day/ALG-106.json.
///
/// D-LOAD-WALK-1 item 6 (2026-10-17, r9n): max HR comes from the person's imported workouts first — the PC derives the highest
/// reliable workout peak (`profile_derive.reliable_highest_peak`: a peak counts only when two other workouts came within 4 bpm
/// below it, so one optical spike cannot be the max) into `profile.hrMaxMeasured` — then the age formula, and the basis text
/// says which ("measured max 190 (workout data)" / "age formula 187 (Tanaka)").
///
/// Sources: Tanaka, Monahan & Seals, J Am Coll Cardiol 2001;37(1):153-156 (HRmax = 208 − 0.7·age); measured = highest
/// rate held for 15 s inside a hard effort (OpenStrap/analytics observed_max_hr.dart, hold-guard idea); zones at
/// 50/60/70/80/90 % of HRmax, Karvonen variant for %HRR (OpenStrap hr_zones.dart). The script's 208 − 0.8·age
/// (MS-05/06) is WP-17's member of the same group.
public enum ALG106 {
    public static let method = "ALG-106@1 hrmax-measured-tanaka"
    public static let citation = "Tanaka H, Monahan KD, Seals DR. J Am Coll Cardiol 2001;37(1):153-156"
    public static let paramsVersion = "1"

    /// A heart rate counts as reached only when held this long.
    public static let holdSeconds = 15
    /// A hole in the stream bigger than this breaks the hold.
    public static let holdMaxGapSeconds = 2
    /// Above this a held value is a sensor fault, not a heart.
    public static let absurdBpm = 240.0
    /// Floor of zone 1, then the upper edges of zones 1–4 (zone 5 is above the last), as fractions of HRmax (or HRR).
    public static let zoneFractions: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]
    /// Time-in-zone needs a stream with at most this many seconds between samples.
    public static let zoneMaxCadenceSeconds = 60.0

    public static let measuredSpec = MetricSpec(
        key: .hrmax, unit: "bpm", group: "G-HRMAX", variant: "ALG-106:measured", method: method, tier: .estimate,
        source: "R18", window: "profile", producer: .ours, citation: nil, paramsVersion: paramsVersion)
    public static let tanakaSpec = MetricSpec(
        key: .hrmax, unit: "bpm", group: "G-HRMAX", variant: "ALG-106:tanaka", method: method, tier: .estimate,
        source: "profile", window: "profile", producer: .ours, citation: citation, paramsVersion: paramsVersion)

    // MARK: Tanaka

    /// ALG-106 v1 — Tanaka HRmax = 208 − 0.7·age. Missing without an age between 0 and 120.
    public static func tanaka(age: Double?) -> Computed<Double> {
        guard let age, age.isFinite, age > 0, age <= 120 else { return .missing("needs an age between 0 and 120") }
        return .success(208.0 - 0.7 * age)
    }

    // MARK: Measured

    public struct HeldMax: Sendable, Hashable {
        public var bpm: Double
        /// Start of the qualifying hold (unix s) — the date in "highest we've seen".
        public var ts: Int
        public var heldS: Int

        public init(bpm: Double, ts: Int, heldS: Int) {
            self.bpm = bpm
            self.ts = ts
            self.heldS = heldS
        }
    }

    /// The reason shown while there is no measured HRmax.
    public static let noHardEffort = "no hard effort recorded yet"
    /// Ours v0: a held max below this fraction of the Tanaka estimate is not a maximal effort.
    public static let sanityFraction = 0.9

    /// Highest bpm held `hold` consecutive seconds (no hole above 2 s) in time-sorted samples, or nil. Ties keep the earliest start.
    private static func heldMax(_ kt: [Int], _ kb: [Double], hold: Int) -> HeldMax? {
        var best: HeldMax?
        let n = kt.count
        for i in 0..<n {
            var lo = kb[i]
            var j = i + 1
            while j < n {
                if kt[j] - kt[j - 1] > holdMaxGapSeconds { break }
                lo = min(lo, kb[j])
                let span = kt[j] - kt[i]
                if span >= hold {
                    if best == nil || lo > best!.bpm { best = HeldMax(bpm: lo, ts: kt[i], heldS: span) }
                    break
                }
                j += 1
            }
        }
        return best
    }

    /// ALG-106 v1 — measured HRmax: the highest heart rate held `holdSeconds` consecutive seconds (no hole above 2 s) inside a
    /// VIGOROUS logged or detected workout window. A one-sample spike never counts. The label says "highest we've seen",
    /// never "your max".
    ///
    /// Fix 2026-10-11 (found by WP-22): a held max from ANY logged workout used to count, so a 95-bpm walk became HRmax 95 and
    /// then drove strain and MS-01. A window now counts only when (1) it passes the ALG-041 vigorous gate — its mean HR clears
    /// `ALG041.vigorousFloor(rhr:hrmax:)`, with the Tanaka estimate standing in for the HRmax being looked for — and (2) the best
    /// held max over the qualifying windows is at least `sanityFraction` (0.9, ours v0) × Tanaka. Otherwise Missing
    /// ("no hard effort recorded yet") and Tanaka is used, labelled. Needs `rhr` and `age` to judge; windows are judged one at a time.
    public static func observedMax(ts: [Int], bpm: [Double], windows: [DayWindow], rhr: Double? = nil, age: Double? = nil,
                                   holdSeconds hold: Int = ALG106.holdSeconds) -> Computed<HeldMax> {
        if windows.isEmpty { return .missing(noHardEffort) }
        guard let rhr, rhr.isFinite, case .success(let tan) = tanaka(age: age), rhr > 0, rhr < tan else {
            return .missing("needs resting heart rate and age to judge whether a workout was hard")
        }
        let floor = ALG041.vigorousFloor(rhr: rhr, hrmax: tan)
        let (t, b) = DayKit.validPairs(ts: ts, vals: bpm)
        var best: HeldMax?
        for w in windows {
            var kt: [Int] = []
            var kb: [Double] = []
            for i in 0..<t.count where b[i] > 0 && b[i] < absurdBpm && w.start <= t[i] && t[i] <= w.end {
                kt.append(t[i])
                kb.append(b[i])
            }
            if kt.count < 2 || DayKit.mean(kb) < floor { continue }
            if let cand = heldMax(kt, kb, hold: hold), best == nil || cand.bpm > best!.bpm { best = cand }
        }
        guard let found = best, found.bpm >= sanityFraction * tan else { return .missing(noHardEffort) }
        return .success(found)
    }

    // MARK: Both variants

    public struct Variants: Sendable, Equatable {
        public var measured: Computed<Double>
        /// "profile" (typed in) or "observed" (held in a workout); nil when there is no measured value.
        public var measuredSource: String?
        public var tanaka: Computed<Double>
        /// "measured" when there is a measured value, else "tanaka"; nil when neither.
        public var primary: String?
        public var primaryBpm: Double?
        /// What the zone bar shows: "measured max 190 (workout data)" / "age formula 187 (Tanaka)" — the label says which (D-LOAD-WALK-1 item 6).
        public var basis: String?

        public init(measured: Computed<Double>, measuredSource: String?, tanaka: Computed<Double>, primary: String?,
                    primaryBpm: Double?, basis: String?) {
            self.measured = measured
            self.measuredSource = measuredSource
            self.tanaka = tanaka
            self.primary = primary
            self.primaryBpm = primaryBpm
            self.basis = basis
        }
    }

    /// ALG-106 v1 — both HRmax variants, labelled. `profileMeasured` (Profile.hrMaxMeasured, 100…240) wins over
    /// `observed`; the primary for zones is measured when there is one, else Tanaka.
    public static func variants(age: Double?, profileMeasured: Double?, observed: HeldMax?) -> Variants {
        var measured: Computed<Double> = .missing(noHardEffort)
        var source: String?
        if let p = profileMeasured, p.isFinite, p >= 100, p <= 240 {
            measured = .success(p)
            source = "profile"
        } else if let o = observed {
            measured = .success(o.bpm)
            source = "observed"
        }
        let tan = tanaka(age: age)
        var out = Variants(measured: measured, measuredSource: source, tanaka: tan, primary: nil, primaryBpm: nil, basis: nil)
        if case .success(let m) = measured {
            out.primary = "measured"
            out.primaryBpm = m
            out.basis = "measured max \(DayKit.r0(m)) (workout data)"
        } else if case .success(let t) = tan {
            out.primary = "tanaka"
            out.primaryBpm = t
            out.basis = "age formula \(DayKit.r0(t)) (Tanaka)"
        }
        return out
    }

    // MARK: Zones

    public enum ZoneMethod: String, Sendable {
        /// 50/60/70/80/90 % of HRmax.
        case hrmax = "hrmax"
        /// Karvonen: resting + p · (HRmax − resting).
        case hrr = "hrr"
    }

    public struct ZoneEdges: Sendable, Equatable {
        /// Bottom of zone 1.
        public var floor: Double
        /// Upper edges of zones 1–4 (zone 5 is above the last): the shape of `WorkoutModeState.zoneEdgesBpm`.
        public var edges: [Double]

        public init(floor: Double, edges: [Double]) {
            self.floor = floor
            self.edges = edges
        }
    }

    /// ALG-106 v1 — zone edges from HRmax (and a resting HR for the %HRR method).
    public static func zoneEdges(hrmax: Double?, method: ZoneMethod = .hrmax, rhr: Double? = nil) -> Computed<ZoneEdges> {
        guard let hrmax, hrmax.isFinite, hrmax > 0 else { return .missing("needs HRmax") }
        var pts: [Double]
        switch method {
        case .hrmax:
            pts = zoneFractions.map { $0 * hrmax }
        case .hrr:
            guard let rhr, rhr.isFinite, rhr > 0, rhr < hrmax else {
                return .missing("%HRR zones need a resting heart rate below HRmax")
            }
            pts = zoneFractions.map { rhr + $0 * (hrmax - rhr) }
        }
        let floor = pts.removeFirst()
        return .success(ZoneEdges(floor: floor, edges: pts))
    }

    public struct LivingZones: Sendable, Equatable {
        public var edges: ZoneEdges?
        public var hrmax: Double?
        /// Says where the zones come from, e.g. "% of heart-rate reserve: max HR 190 (your data), resting HR 50".
        public var basis: String?
    }

    /// T82 — zones from the person's own data. Max HR from data (`profileMeasured`: typed or the 95th percentile of workout
    /// peaks, D-038) with a resting HR gives %HRR (Karvonen) zones; max HR alone gives % of max. With no max HR from data
    /// they use the Tanaka formula from age and the basis says so.
    public static func livingZones(age: Double?, profileMeasured: Double?, rhr: Double?) -> LivingZones {
        let v = variants(age: age, profileMeasured: profileMeasured, observed: nil)
        guard let hrmax = v.primaryBpm else { return LivingZones(edges: nil, hrmax: nil, basis: nil) }
        if v.primary == "measured" {
            if let rhr, let e = zoneEdges(hrmax: hrmax, method: .hrr, rhr: rhr).value {
                return LivingZones(edges: e, hrmax: hrmax, basis: "% of heart-rate reserve: max HR \(DayKit.r0(hrmax)) (your data), resting HR \(DayKit.r0(rhr))")
            }
            return LivingZones(edges: zoneEdges(hrmax: hrmax).value, hrmax: hrmax, basis: "% of max HR: max HR \(DayKit.r0(hrmax)) (your data)")
        }
        return LivingZones(edges: zoneEdges(hrmax: hrmax).value, hrmax: hrmax,
                           basis: "% of max HR: formula only (\(v.basis ?? "age formula (Tanaka)")); no measured max HR yet")
    }

    /// 0 below zone 1, else 1…5; a zone includes its lower edge.
    public static func zone(of bpm: Double, floor: Double, edges: [Double]) -> Int {
        if bpm < floor { return 0 }
        for (i, e) in edges.enumerated() where bpm < e { return i + 1 }
        return edges.count + 1
    }

    public struct ZoneTime: Sendable, Equatable {
        /// Minutes in zones 1…5.
        public var minutes: [Double]
        public var belowMin: Double
        public var coveredMin: Double

        public init(minutes: [Double], belowMin: Double, coveredMin: Double) {
            self.minutes = minutes
            self.belowMin = belowMin
            self.coveredMin = coveredMin
        }
    }

    /// ALG-106 v1 — minutes per zone from a heart-rate stream (per-sample time = gap to the next sample, capped at the
    /// stream's median step). Needs 2 samples and a cadence of at most 60 s.
    public static func timeInZones(ts: [Int], bpm: [Double], floor: Double, edges: [Double]) -> Computed<ZoneTime> {
        let (t, b) = DayKit.validPairs(ts: ts, vals: bpm)
        var tt: [Int] = []
        var bb: [Double] = []
        for i in 0..<t.count where b[i] > 0 {
            tt.append(t[i])
            bb.append(b[i])
        }
        if tt.count < 2 { return .missing("needs at least two heart-rate samples") }
        let dur = DayKit.sampleDurations(tt)
        if (dur.max() ?? 0) > zoneMaxCadenceSeconds { return .missing("heart-rate samples are more than 60 s apart") }
        var z = [Double](repeating: 0, count: 5)
        var below = 0.0
        for i in 0..<bb.count {
            let k = zone(of: bb[i], floor: floor, edges: edges)
            if k == 0 {
                below += dur[i]
            } else {
                z[k - 1] += dur[i]
            }
        }
        var covered = 0.0
        for d in dur { covered += d }
        return .success(ZoneTime(minutes: z.map { $0 / 60.0 }, belowMin: below / 60.0, coveredMin: covered / 60.0))
    }
}
