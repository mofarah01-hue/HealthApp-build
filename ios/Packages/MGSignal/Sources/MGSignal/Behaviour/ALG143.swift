import Foundation
import MGDomain

/// ALG-143 v1 — medication-in-body curve from the LABEL's pharmacokinetics, as context for sleep, HR, alerts and the
/// crash finder. **Never dosing advice.** One compartment with first-order absorption whose k_a is the value that puts
/// the single-dose peak at the label's Tmax for the label's half-life (solved by 200-step bisection). The output is
/// RELATIVE: 1.0 = the peak after one dose of the reference dose; it is not a blood level (no bioavailability or volume
/// is used). Parameters are editable and come with the "to re-check" flag.
/// Python reference: app/pclab/mglab/ref/behaviour.py `med_ka` / `med_level` / `med_curve`;
/// goldens app/shared/golden/behaviour/ALG-143.json.
public enum ALG143 {
    public static let method = "ALG-143@1 label-pk-relative"
    public static let citation = "TGA Product Information (lisdexamfetamine): d-amphetamine Tmax 3.8 h fasted adults; "
        + "DrugBank DB01255: half-life 10–11.3 h adults"
    /// One-compartment limit: Tmax < t½ / ln 2 (1.4427 t½); stay clear of it.
    public static let maxTmaxOverHalfLife = 1.4
    static let bisectIterations = 200

    /// Label parameters for one drug (hours). Editable; the preset is flagged "to re-check".
    public struct PK: Sendable, Hashable {
        public var name: String
        public var tmaxH: Double
        public var halfLifeH: Double

        public init(name: String, tmaxH: Double, halfLifeH: Double) {
            self.name = name
            self.tmaxH = tmaxH
            self.halfLifeH = halfLifeH
        }
    }

    /// Lisdexamfetamine → d-amphetamine. TGA Product Information: Tmax 3.8 h in fasted adults (4.7 h after a high-fat meal,
    /// about 3.5 h in fasted children); DrugBank DB01255: d-amphetamine half-life 10–11.3 h in healthy adults (midpoint
    /// 10.5 h). TO RE-CHECK against the current label (ALG-143).
    public static let lisdexamfetamineDAmphetamine = PK(name: "lisdexamfetamine (as d-amphetamine)", tmaxH: 3.8,
                                                        halfLifeH: 10.5)

    /// A logged dose. `mg == nil` (logged without a dose) makes the result Missing (R6).
    public struct Dose: Sendable, Hashable {
        public var at: Date
        public var mg: Double?

        public init(at: Date, mg: Double?) {
            self.at = at
            self.mg = mg
        }
    }

    public struct Level: Sendable, Equatable {
        /// Relative level: 1.0 = the peak after one dose of the reference dose.
        public var level: Double
        public var kaPerH: Double

        public init(level: Double, kaPerH: Double) {
            self.level = level
            self.kaPerH = kaPerH
        }
    }

    public struct Sample: Sendable, Equatable {
        public var at: Date
        public var level: Double

        public init(at: Date, level: Double) {
            self.at = at
            self.level = level
        }
    }

    /// ALG-143 v1 — the k_a (per hour) whose Bateman peak falls at `tmaxH` for this half-life. Missing outside the
    /// one-compartment limit or for non-positive input.
    public static func absorptionRate(tmaxH: Double, halfLifeH: Double) -> Computed<Double> {
        guard tmaxH.isFinite, tmaxH > 0, halfLifeH.isFinite, halfLifeH > 0 else {
            return .missing("Tmax and half-life must be positive hours")
        }
        if tmaxH > maxTmaxOverHalfLife * halfLifeH {
            return .missing("Tmax is too long for this half-life for a one-compartment curve")
        }
        let ke = log(2.0) / halfLifeH

        // Tmax of a Bateman curve with this k_a; decreasing in k_a from 1/k_e (k_a → k_e) to 0.
        func peakTime(_ ka: Double) -> Double {
            let d = ka - ke
            return log1p(d / ke) / d
        }

        var lo = ke * (1.0 + 1e-9)
        var hi = ke * 2.0
        var bracketed = false
        for _ in 0..<80 {
            if peakTime(hi) < tmaxH {
                bracketed = true
                break
            }
            hi *= 2.0
        }
        if !bracketed { return .missing("could not bracket k_a for this Tmax") }
        for _ in 0..<bisectIterations {
            let mid = 0.5 * (lo + hi)
            if peakTime(mid) > tmaxH { lo = mid } else { hi = mid }
        }
        return .success(0.5 * (lo + hi))
    }

    /// ALG-143 v1 — relative level at `at` from `doses`; 1.0 = the peak after one dose of `referenceMg` (default: the largest logged
    /// dose). Missing without doses, with a dose without mg, or with unusable label parameters.
    public static func level(at: Date, doses: [Dose], pk: PK, referenceMg: Double? = nil) -> Computed<Level> {
        guard !doses.isEmpty else { return .missing("no doses logged") }
        let ka: Double
        switch absorptionRate(tmaxH: pk.tmaxH, halfLifeH: pk.halfLifeH) {
        case .success(let v): ka = v
        case .failure(let m): return .failure(m)
        }
        let ke = log(2.0) / pk.halfLifeH
        var largest = 0.0
        for d in doses {
            guard let mg = d.mg, mg.isFinite, mg >= 0 else { return .missing("a dose has no mg") }
            largest = max(largest, mg)
        }
        let ref = referenceMg ?? largest
        guard ref > 0, ref.isFinite else { return .missing("reference dose must be positive") }
        let peak = exp(-ke * pk.tmaxH) - exp(-ka * pk.tmaxH)
        let t = BehaviourClock.seconds(at)
        var level = 0.0
        for d in doses {
            let doseTime = BehaviourClock.seconds(d.at)
            if t < doseTime { continue }
            let tau = (t - doseTime) / BehaviourClock.hourSeconds
            level += (d.mg ?? 0.0) / ref * (exp(-ke * tau) - exp(-ka * tau)) / peak
        }
        return .success(Level(level: level, kaPerH: ka))
    }

    /// ALG-143 v1 — relative level sampled at `from`, `from + step`, … ≤ `to`.
    public static func curve(from: Date, to: Date, step: TimeInterval, doses: [Dose], pk: PK,
                             referenceMg: Double? = nil) -> Computed<[Sample]> {
        let t0 = BehaviourClock.seconds(from)
        let t1 = BehaviourClock.seconds(to)
        guard step > 0, t1 >= t0 else { return .missing("curve needs step > 0 and end >= start") }
        let n = Int(((t1 - t0) / step + 1e-9).rounded(.down)) + 1
        var out: [Sample] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let at = BehaviourClock.date(t0 + Double(i) * step)
            switch level(at: at, doses: doses, pk: pk, referenceMg: referenceMg) {
            case .success(let l): out.append(Sample(at: at, level: l.level))
            case .failure(let m): return .failure(m)
            }
        }
        return .success(out)
    }
}
