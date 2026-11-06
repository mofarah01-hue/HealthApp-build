import Foundation
import MGDomain

/// ALG-138 v1 — percentile of you and personal records: where today sits in your own history. Python reference:
/// app/pclab/mglab/ref/insights.py `percentile_of_you`; goldens app/shared/golden/day/ALG-138.json.
///
/// Port of OpenStrap/analytics human/percentile_of_you.dart @ 458ba36: midrank percentile = (earlier days below + half
/// the ties) / n × 100 against your own earlier values (≥ 14), worded on the GOOD axis (higher-is-better, lower-is-better,
/// or position words only); a personal record only when today beats your prior extreme by more than the MDC
/// (1.96·√2·1.4826·MAD), never on a metric without a good end. Within-you only, never a population rank. Window: the 90
/// stored days before today (ours).
public enum ALG138 {
    public static let citation = "OpenStrap percentile_of_you.dart @ 458ba36 (n-of-1 order statistics, MDC-gated records)"
    public static let minN = 14

    /// (registry name, variant read, window, label, direction: +1 higher is better, −1 lower, 0 neither).
    public static let metricsRead: [(name: String, variant: String, window: String, label: String, better: Int)] = [
        ("hrv_rmssd", "ALG-010", "night", "HRV", 1),
        ("rhr", "ALG-012", "night", "resting HR", -1),
        ("sleep_performance", "ALG-150", "night", "sleep performance", 1),
        ("resp_rate", "ALG-121", "night", "breathing rate", 0),
    ]

    public struct Rank: Sendable, Equatable {
        public var percentile: Double
        public var label: String
        public var record: Bool
        public var n: Int
    }

    public static func rank(value: Double?, history: [Double?], better: Int) -> Computed<Rank> {
        let h = history.compactMap { v -> Double? in
            guard let v, v.isFinite else { return nil }
            return v
        }
        guard let value, value.isFinite else { return .missing("no value today") }
        guard h.count >= minN else { return .missing("needs \(minN) earlier days of your own (have \(h.count))") }
        let below = h.filter { $0 < value }.count
        let equal = h.filter { $0 == value }.count
        let pct = 100.0 * (Double(below) + 0.5 * Double(equal)) / Double(h.count)
        let label: String
        if better == 0 {
            label = pct >= 90 ? "among your highest" : pct >= 70 ? "higher than usual" : pct > 30 ? "typical for you"
                : pct > 10 ? "lower than usual" : "among your lowest"
        } else {
            let good = better > 0 ? pct : 100.0 - pct
            label = good >= 90 ? "among your best" : good >= 70 ? "better than usual" : good > 30 ? "typical for you"
                : good > 10 ? "worse than usual" : "among your worst"
        }
        var record = false
        if better != 0 {
            let s = ALG075.mad(h)
            if s > 0 {
                let gate = 1.96 * 2.0.squareRoot() * s
                let prior = better > 0 ? h.max()! : h.min()!
                let beats = better > 0 ? value - prior : prior - value
                record = beats > gate
            }
        }
        return .success(Rank(percentile: pct, label: label, record: record, n: h.count))
    }

    public static func spec(_ name: String) -> MetricSpec {
        MetricSpec(key: .percentileSelf, unit: "%", group: nil, variant: "ALG-138:\(name)", method: "ALG-138@1 midrank-percentile",
                   tier: .estimate, source: name, window: "90d", citation: citation, paramsVersion: "min14 mdc1.96sqrt2 win90")
    }

    public static func metric(name: String, label: String, _ r: Computed<Rank>, at: Date) -> Metric {
        spec(name).metric(r.map(\.percentile), at: at, note: r.value.map {
            "\(label) \($0.label) (\($0.n) days)" + ($0.record ? "; a personal record" : "")
        })
    }
}
