import Foundation
import MGDomain

/// ALG-132 v2 — key points of a period (week / month): deterministic, at most 5, never padded. Python reference:
/// app/pclab/mglab/ref/insights.py `key_points`; goldens app/shared/golden/day/ALG-132.json.
///
/// Ours, as ALGORITHM-REQUIREMENTS words it ("biggest movers, threshold crossings, change points, coverage warnings"),
/// on the ALG-075 roll-ups: per metric with any value, a coverage warning when fewer than half the period's days have one;
/// else a mover when the period median sits ≥ 1 robust SD from the 28 days before (ALG075.robustZ), a crossing when at
/// least half the period's days fall outside the ALG-075 normal band on one side, and a change point when ALG-075 CUSUM
/// fires inside the period. Ranked change > crossing > mover > coverage, then size, then metric order.
public enum ALG132 {
    public static let citation = "ours (ALGORITHM-REQUIREMENTS ALG-132) on ALG-075 robust z, normal band and CUSUM"
    public static let metricsRead: [(name: String, variant: String, window: String, label: String)] = [
        ("hrv_rmssd", "ALG-010", "night", "HRV"),
        ("rhr", "ALG-012", "night", "Resting HR"),
        ("sleep_total", "ALG-150", "night", "Sleep"),
        ("resp_rate", "ALG-121", "night", "Breathing rate"),
        ("strain", "ALG-036", "day", "Strain"),
    ]
    public static let baseDays = 28
    public static let moverZ = 1.0
    public static let maxPoints = 5

    public struct Point: Sendable, Equatable {
        public var kind: String
        public var metric: String
        public var text: String
        public var score: Double
    }

    /// " (+15 %, 95 % CI +14 % to +17 %, 7 vs 28 days)": the period mean against the 4 weeks before as a % of that mean, with
    /// the Welch 95 % interval of the difference (t quantile at the Welch degrees of freedom, rounded down). Empty when the
    /// baseline mean is 0 or either side has fewer than 2 values.
    static func moverStat(_ cur: [Double], _ base: [Double]) -> String {
        guard cur.count >= 2, base.count >= 2 else { return "" }
        let mb = SignalMath.mean(base)
        let mc = SignalMath.mean(cur)
        guard mb != 0 else { return "" }
        let v1 = SignalMath.sampleSD(cur) * SignalMath.sampleSD(cur) / Double(cur.count)
        let v2 = SignalMath.sampleSD(base) * SignalMath.sampleSD(base) / Double(base.count)
        let se = (v1 + v2).squareRoot()
        let d = mc - mb
        func s0(_ x: Double) -> String { String(format: "%+.0f", x) }
        if se == 0 { return " (\(s0(d / mb * 100)) %, \(cur.count) vs \(base.count) days)" }
        let df = max(1, Int((v1 + v2) * (v1 + v2) / (v1 * v1 / Double(cur.count - 1) + v2 * v2 / Double(base.count - 1))))
        let t = ALG102.t975(df)
        let lo = (d - t * se) / mb * 100
        let hi = (d + t * se) / mb * 100
        return " (\(s0(d / mb * 100)) %, 95 % CI \(s0(lo)) % to \(s0(hi)) %, \(cur.count) vs \(base.count) days)"
    }

    static let kindOrder = ["change": 0, "crossing": 1, "mover": 2, "coverage": 3]

    /// `series[name]` = values oldest → newest; the last `period` are the period, the 28 before its baseline. Missing when
    /// no metric has a single stored value (nothing to read is not "nothing stood out").
    public static func keyPoints(series: [String: [Double?]], period: Int) -> Computed<[Point]> {
        guard metricsRead.contains(where: { m in (series[m.name] ?? []).contains { $0 != nil } }) else {
            return .missing("no stored days to read yet")
        }
        var pts: [(p: Point, order: Int)] = []
        for (order, m) in metricsRead.enumerated() {
            let v = series[m.name] ?? []
            guard v.contains(where: { $0 != nil }) else { continue }
            let cur = Array(v.suffix(period))
            let base = v.count > period ? Array(v.dropLast(period).suffix(baseDays)) : []
            let cv = cur.compactMap { $0 }
            let need = (period + 1) / 2
            if cv.count < need {
                pts.append((Point(kind: "coverage", metric: m.name, text: "\(m.label): \(cv.count) of \(period) days, "
                                  + "too few to compare", score: 0), order))
                continue
            }
            let mc = SignalMath.median(cv)
            if case .success(let rz) = ALG075.robustZ(history: base, x: mc), abs(rz.z) >= moverZ {
                pts.append((Point(kind: "mover", metric: m.name,
                                  text: "\(m.label) \(rz.z > 0 ? "up" : "down")\(moverStat(cv, base.compactMap { $0 })) "
                                      + "vs the 4 weeks before", score: abs(rz.z)), order))
            }
            if case .success(let band) = ALG075.normalBand(history: base) {
                let above = cv.filter { $0 > band.high }.count
                let below = cv.filter { $0 < band.low }.count
                let (out, side) = above >= below ? (above, "above") : (below, "below")
                if out >= need {
                    pts.append((Point(kind: "crossing", metric: m.name,
                                      text: "\(m.label) \(side) your normal range on \(out) of \(period) days",
                                      score: Double(out) / Double(period)), order))
                }
            }
            let span = Array(v.suffix(period + baseDays))
            var xs: [Double] = []
            var ds: [Int] = []
            for (i, x) in span.enumerated() {
                if let x {
                    xs.append(x)
                    ds.append(i)
                }
            }
            let firstCur = span.count - period
            let cps = ALG075.cusumChangePoints(xs, days: ds).filter { ds[$0.index] >= firstCur }
            if let c = cps.last {
                let ago = span.count - 1 - ds[c.index]
                pts.append((Point(kind: "change", metric: m.name,
                                  text: "\(m.label) shifted \(c.direction > 0 ? "up" : "down") "
                                      + (ago == 0 ? "today" : "\(ago) days ago"), score: c.stat), order))
            }
        }
        pts.sort { a, b in
            let ka = kindOrder[a.p.kind] ?? 9
            let kb = kindOrder[b.p.kind] ?? 9
            if ka != kb { return ka < kb }
            if a.p.score != b.p.score { return a.p.score > b.p.score }
            return a.order < b.order
        }
        return .success(Array(pts.prefix(maxPoints).map(\.p)))
    }

    public static let weekSpec = MetricSpec(
        key: .keyPoints, unit: "count", group: nil, variant: "ALG-132", method: "ALG-132@1 key-points",
        tier: .estimate, source: "stored days", window: "7d", citation: citation, paramsVersion: "base28 z1 half-period welch-ci")
    public static let monthSpec = MetricSpec(
        key: .keyPoints, unit: "count", group: nil, variant: "ALG-132", method: "ALG-132@1 key-points",
        tier: .estimate, source: "stored days", window: "30d", citation: citation, paramsVersion: "base28 z1 half-period welch-ci")

    /// Count of points, the sentences in the note ("nothing stood out" when there are none).
    public static func metric(_ spec: MetricSpec, _ points: Computed<[Point]>, at: Date) -> Metric {
        spec.metric(points.map { Double($0.count) }, at: at, note: points.value.map {
            $0.isEmpty ? "nothing stood out against your usual" : $0.map(\.text).joined(separator: " \u{00B7} ")
        })
    }
}
