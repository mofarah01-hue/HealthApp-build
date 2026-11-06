import Foundation
import MGDomain

/// ALG-102 v2 — what a logged behaviour does to YOUR next-morning HRV, as a regression with a confidence interval
/// (D-RECOV-WALK-2, Mo 2026-10-17: the Shapley shares of an inferred recovery score were made-up percentages).
/// Python reference: app/pclab/mglab/ref/effects.py `behaviour_effect`, `rows_from_days`; goldens
/// app/shared/golden/day/ALG-102.json (hand regression, noise-free series, gates, 80 noisy nights).
///
/// Model, one behaviour at a time, on your nights t that have a night t−1 and a known exposure on day t−1:
///
///     ln RMSSD_t = a + b · exposed_{t−1} + c · ln RMSSD_{t−1} + error
///
/// c is the AR(1) adjustment (nightly HRV is autocorrelated; ignoring it makes the interval too narrow). Shown as the
/// % change exp(b) − 1 with the 95 % interval exp(b ± t·se) − 1 (ordinary least squares, t quantile for n − 3 degrees of
/// freedom). Association, not cause. Design after Pietilä 2018 (JMIR Ment Health 5:e23, within-person alcohol vs
/// non-alcohol days, ln RMSSD of the first 3 h of sleep); the minimum of 10 exposed and 20 unexposed nights and the AR(1)
/// form are ours (audit/RESEARCH-RECOVERY.md §5). Below the minimum the answer is "learning …", never a number.
public enum ALG102 {
    public static let citation = "Pietilä 2018 JMIR Ment Health 5:e23 (within-person design); ln RMSSD regression with an "
        + "AR(1) term and 95 % CI; gate 10 exposed / 20 unexposed nights (ours)"
    public static let minExposed = 10
    public static let minUnexposed = 20

    /// The behaviours read from the log: id (variant suffix), words, and what counts as exposed on a day.
    public enum Behaviour: String, CaseIterable, Sendable {
        case alcohol
        case lateCaffeine = "late_caffeine"
        case vape
        case workout

        public var label: String {
            switch self {
            case .alcohol: return "Alcohol"
            case .lateCaffeine: return "Caffeine after 2 PM"
            case .vape: return "Vaping"
            case .workout: return "A workout"
            }
        }
    }

    public struct Row: Sendable, Equatable {
        public var y: Double
        public var yPrev: Double
        public var exposed: Bool

        public init(y: Double, yPrev: Double, exposed: Bool) {
            self.y = y
            self.yPrev = yPrev
            self.exposed = exposed
        }
    }

    public struct Effect: Sendable, Equatable {
        /// % change in next-morning RMSSD, its 95 % interval.
        public var pct: Double
        public var lo: Double
        public var hi: Double
        public var beta: Double
        public var se: Double
        /// The AR(1) coefficient on last night's ln RMSSD.
        public var ar: Double
        public var df: Int
        public var n: Int
        public var nExposed: Int
        public var nUnexposed: Int

        /// The interval excludes 0: the only case worded "linked with".
        public var clear: Bool { lo > 0 || hi < 0 }
    }

    /// Two-sided 95 % t quantiles for 1…30 degrees of freedom, then 40, 60, 120 (standard table).
    static let t975Table: [Double] = [12.7062, 4.3027, 3.1824, 2.7764, 2.5706, 2.4469, 2.3646, 2.3060, 2.2622, 2.2281,
                                      2.2010, 2.1788, 2.1604, 2.1448, 2.1314, 2.1199, 2.1098, 2.1009, 2.0930, 2.0860,
                                      2.0796, 2.0739, 2.0687, 2.0639, 2.0595, 2.0555, 2.0518, 2.0484, 2.0452, 2.0423]

    public static func t975(_ df: Int) -> Double {
        if df < 1 { return t975Table[0] }
        if df <= 30 { return t975Table[df - 1] }
        if df <= 40 { return 2.0211 }
        if df <= 60 { return 2.0003 }
        if df <= 120 { return 1.9799 }
        return 1.9600
    }

    /// Gauss–Jordan with partial pivoting on the 3×3 normal equations: (solution, inverse) or nil when singular.
    static func solve3(_ a: [[Double]], _ b: [Double]) -> (x: [Double], inv: [[Double]])? {
        var m: [[Double]] = (0..<3).map { i in a[i] + (0..<3).map { $0 == i ? 1.0 : 0.0 } + [b[i]] }
        for col in 0..<3 {
            var piv = col
            for r in col..<3 where abs(m[r][col]) > abs(m[piv][col]) { piv = r }
            if abs(m[piv][col]) < 1e-12 { return nil }
            m.swapAt(col, piv)
            let p = m[col][col]
            m[col] = m[col].map { $0 / p }
            for r in 0..<3 where r != col {
                let f = m[r][col]
                m[r] = zip(m[r], m[col]).map { $0 - f * $1 }
            }
        }
        return ((0..<3).map { m[$0][6] }, (0..<3).map { i in (0..<3).map { m[i][3 + $0] } })
    }

    /// The regression above; Missing("learning: …") below the minimum, Missing when the exposure or last night's HRV has
    /// no variation to separate from the intercept.
    public static func behaviourEffect(rows rowsIn: [Row], minExposed: Int = minExposed,
                                       minUnexposed: Int = minUnexposed) -> Computed<Effect> {
        let rows = rowsIn.filter { $0.y.isFinite && $0.yPrev.isFinite }
        let nE = rows.filter(\.exposed).count
        let nU = rows.count - nE
        if nE < minExposed || nU < minUnexposed {
            return .missing("learning: \(nE) exposed night\(nE != 1 ? "s" : "") of \(minExposed) needed, "
                            + "\(nU) unexposed of \(minUnexposed) needed")
        }
        var xtx = [[Double]](repeating: [0, 0, 0], count: 3)
        var xty = [0.0, 0.0, 0.0]
        for r in rows {
            let x = [1.0, r.exposed ? 1.0 : 0.0, r.yPrev]
            for i in 0..<3 {
                xty[i] += x[i] * r.y
                for j in 0..<3 { xtx[i][j] += x[i] * x[j] }
            }
        }
        guard let sol = solve3(xtx, xty) else {
            return .missing("no variation in the exposure or in last night's HRV to separate them")
        }
        let a = sol.x[0], b = sol.x[1], c = sol.x[2]
        var sse = 0.0
        for r in rows {
            let e = r.y - (a + b * (r.exposed ? 1.0 : 0.0) + c * r.yPrev)
            sse += e * e
        }
        let df = rows.count - 3
        let se = max(sse / Double(df) * sol.inv[1][1], 0).squareRoot()
        let t = t975(df)
        return .success(Effect(pct: (exp(b) - 1) * 100, lo: (exp(b - t * se) - 1) * 100, hi: (exp(b + t * se) - 1) * 100,
                               beta: b, se: se, ar: c, df: df, n: rows.count, nExposed: nE, nUnexposed: nU))
    }

    /// Nights t (day numbers) with a night t−1 and a known exposure on day t−1: (ln_t, ln_{t−1}, exposed on t−1).
    public static func rows(lnByDay: [Int: Double], exposed: Set<Int>, known: Set<Int>) -> [Row] {
        var out: [Row] = []
        for d in lnByDay.keys.sorted() {
            if let prev = lnByDay[d - 1], known.contains(d - 1), let y = lnByDay[d] {
                out.append(Row(y: y, yPrev: prev, exposed: exposed.contains(d - 1)))
            }
        }
        return out
    }

    /// The words for one behaviour: "linked with" only when the interval excludes 0; "learning" below the minimum.
    public static func sentence(_ label: String, _ r: Computed<Effect>) -> String {
        switch r {
        case .failure(let m):
            return "\(label): \(m.reason)"
        case .success(let e):
            let span = "\(signed0(e.lo)) % to \(signed0(e.hi)) %"
            let n = "\(e.nExposed) vs \(e.nUnexposed) nights"
            if e.clear {
                return "\(label): next-morning HRV \(e.pct > 0 ? "higher" : "lower") by \(String(format: "%.0f", abs(e.pct))) % "
                    + "(95 % CI \(span), \(n)) - linked with, not proven to cause"
            }
            return "\(label): no clear difference in next-morning HRV (\(signed0(e.pct)) %, 95 % CI \(span), \(n))"
        }
    }

    /// "+14" / "-3" (whole numbers, explicit sign) as Python's f"{x:+.0f}".
    static func signed0(_ x: Double) -> String { String(format: "%+.0f", x) }

    /// Variant "ALG-102:<behaviour>", value = the % change (blank while learning, with the reason).
    public static func spec(_ b: Behaviour) -> MetricSpec {
        MetricSpec(key: .scoreDrivers, unit: "%", group: nil, variant: "ALG-102:\(b.rawValue)",
                   method: "ALG-102@2 ln-rmssd-regression-ar1", tier: .estimate, source: "nightly ln RMSSD, event log",
                   window: "90d", citation: citation, paramsVersion: "ar1 ols t95 min10/20 nights")
    }

    public static func metric(_ b: Behaviour, _ r: Computed<Effect>, at: Date) -> Metric {
        let spec = spec(b)
        return spec.metric(r.map(\.pct), at: at, note: sentence(b.label, r)
            + " · association only; a day you did not log counts as a day without it")
    }
}
