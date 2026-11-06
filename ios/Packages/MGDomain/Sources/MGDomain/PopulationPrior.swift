import Foundation

/// D-POP-PRIOR (Mo, 2026-10-17): a personal parameter starts at the published population value and moves toward Mo's own as his
/// data grows. One rule, one place: the estimate is a weighted mean, weight on his own = n / (n + k) (shrinkage toward the
/// prior; the same form as the Bayesian posterior mean of a normal mean with prior strength k observations). `k` is the number
/// of his own observations (days) that count as much as the population value; the caller states and cites it, or says why it
/// chose it. With no published population value there is no prior: the parameter stays blank until `n` is enough, and the
/// label says "yours" only.
public enum PopulationPrior {
    public struct Estimate: Equatable, Sendable {
        public var value: Double
        /// Weight on his own value, 0 (all population) ... 1 (all his).
        public var ownWeight: Double
        public var days: Int
        /// "population" / "population, moving to yours (12 days)" / "yours (60 days)".
        public var label: String
    }

    /// `prior` nil = no published population value. `own` nil or `n` 0 = nothing of his yet. Returns nil when neither exists.
    public static func blend(prior: Double?, own: Double?, n: Int, k: Double) -> Estimate? {
        let days = max(0, n)
        guard days > 0, let o = own else {
            guard let p = prior else { return nil }
            return Estimate(value: p, ownWeight: 0, days: 0, label: "population")
        }
        guard let p = prior else {
            return Estimate(value: o, ownWeight: 1, days: days, label: "yours (\(days) days)")
        }
        let w = k > 0 ? Double(days) / (Double(days) + k) : 1
        let label = w >= 0.9 ? "yours (\(days) days)" : "population, moving to yours (\(days) days)"
        return Estimate(value: (1 - w) * p + w * o, ownWeight: w, days: days, label: label)
    }
}
