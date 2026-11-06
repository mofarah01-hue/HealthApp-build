import Foundation

/// ALG-067 v1 — the cost of a habit: an outcome (sleep, HRV, resting HR) on days WITH a tag vs days WITHOUT it, as
/// Cohen's d with the pooled SD, d = (mean_with − mean_without) / sqrt(((n₁−1)s₁² + (n₂−1)s₂²) / (n₁+n₂−2)).
/// Pattern from noop's Behaviour Effects (StrandAnalytics BehaviorInsights.swift), including its fix: days where the
/// tag was NOT logged either way are not controls (an unanswered day is not a "No"). A day in both sets counts as a
/// tag day. This is a hypothesis only — the cause finder (ALG-064 / ALG-124) tests it. Sibling methods in the same
/// G-HABIT group: ALG-125 (`ALG125.group` returns all of them).
/// Ours: at least 3 days on each side, else Missing (noop computes from 1 day); `enoughN` is noop's min(n) ≥ 5 gate.
/// Python reference: app/pclab/mglab/ref/behaviour.py `cohens_d` / `split_days`; goldens
/// app/shared/golden/behaviour/ALG-067.json.
public enum ALG067 {
    public static let method = "ALG-067@1 cohens-d-pooled"
    public static let citation = "noop Behaviour Effects (BehaviorInsights.swift); Cohen J. Statistical Power Analysis, 1988"
    public static let minPerGroup = 3
    public static let enoughPerGroup = 5

    public struct Effect: Sendable, Equatable {
        /// Signed: negative = lower on tag days.
        public var d: Double
        public var meanWith: Double
        public var meanWithout: Double
        public var delta: Double
        /// % of |mean without|; nil when that mean is 0.
        public var pctChange: Double?
        public var nWith: Int
        public var nWithout: Int
        /// min(nWith, nWithout) ≥ 5.
        public var enoughN: Bool

        public init(d: Double, meanWith: Double, meanWithout: Double, delta: Double, pctChange: Double?, nWith: Int,
                    nWithout: Int, enoughN: Bool) {
            self.d = d
            self.meanWith = meanWith
            self.meanWithout = meanWithout
            self.delta = delta
            self.pctChange = pctChange
            self.nWith = nWith
            self.nWithout = nWithout
            self.enoughN = enoughN
        }
    }

    /// Outcome values on tag days and on control days, in sorted day order. A day in neither set is dropped; a day in
    /// both counts as a tag day. Day keys are `LocalDay.iso` strings ("2026-10-10").
    public static func splitDays(withDays: Set<String>, controlDays: Set<String>,
                                 outcomeByDay: [String: Double]) -> (with: [Double], without: [Double]) {
        var w: [Double] = []
        var c: [Double] = []
        for day in outcomeByDay.keys.sorted() {
            guard let v = outcomeByDay[day] else { continue }
            if withDays.contains(day) {
                w.append(v)
            } else if controlDays.contains(day) {
                c.append(v)
            }
        }
        return (w, c)
    }

    /// Missing unless both groups have at least `minPerGroup` days.
    static func groupsMissing(with w: [Double], without c: [Double]) -> Missing? {
        if w.count < minPerGroup || c.count < minPerGroup {
            return Missing("needs at least \(minPerGroup) days with and \(minPerGroup) without (have \(w.count) and \(c.count))")
        }
        return nil
    }

    /// ALG-067 v1 on two lists of outcome values.
    public static func cohensD(with w: [Double], without c: [Double]) -> Computed<Effect> {
        if let m = groupsMissing(with: w, without: c) { return .failure(m) }
        let n1 = w.count
        let n2 = c.count
        let m1 = SignalMath.mean(w)
        let m2 = SignalMath.mean(c)
        let s1 = SignalMath.sampleSD(w)
        let s2 = SignalMath.sampleSD(c)
        let v1 = s1 * s1
        let v2 = s2 * s2
        let pooled = (((Double(n1) - 1.0) * v1 + (Double(n2) - 1.0) * v2) / Double(n1 + n2 - 2)).squareRoot()
        guard pooled > 0 else { return .missing("no spread within either group: the effect size is undefined") }
        let delta = m1 - m2
        return .success(Effect(d: delta / pooled, meanWith: m1, meanWithout: m2, delta: delta,
                               pctChange: m2 != 0 ? delta / abs(m2) * 100.0 : nil, nWith: n1, nWithout: n2,
                               enoughN: min(n1, n2) >= enoughPerGroup))
    }

    /// ALG-067 v1 from day sets and a per-day outcome.
    public static func effect(withDays: Set<String>, controlDays: Set<String>,
                              outcomeByDay: [String: Double]) -> Computed<Effect> {
        let s = splitDays(withDays: withDays, controlDays: controlDays, outcomeByDay: outcomeByDay)
        return cohensD(with: s.with, without: s.without)
    }
}
