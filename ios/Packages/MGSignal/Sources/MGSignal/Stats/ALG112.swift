import Foundation
import MGDomain

/// ALG-112 v1 — multivariate anomaly: robust Mahalanobis distance of tonight's {RHR, HRV, skin temperature, breathing}
/// from the previous ≤ 28 nights (OpenStrap analytics wellness/anomaly.dart @0441ef9; Mahalanobis 1936). Research
/// tier, NO flag: a χ² gate on a MAD baseline this short over-fires (OpenStrap measured 0.197 false candidates per night
/// at n = 10), so the distance is shown and the gate waits for a calibration on Mo's data. Python reference:
/// app/pclab/mglab/ref/stats.py `mahalanobis_anomaly`; goldens app/shared/golden/stats/ALG-112.json.
public enum ALG112 {
    public static let citation = "OpenStrap analytics wellness/anomaly.dart @0441ef9; Mahalanobis 1936"
    public static let baselineNights = 28
    /// OpenStrap multivariateAnomalyMinBaseline.
    public static let minBaseline = 10
    public static let minFeatures = 2
    /// OpenStrap ridge: R' = 0.9 R + 0.1 I.
    public static let ridge = 0.1
    /// Off-diagonals need 10 complete baseline nights, else they are 0 (ours).
    public static let minCorrRows = 10
    public static let madK = 1.4826

    /// The four features; sign +1 = the illness direction is UP (HRV is flipped: a drop is the illness direction).
    public enum Feature: String, Sendable, CaseIterable {
        case rhr = "rhr"
        case hrv = "hrv"
        case temp = "temp"
        case resp = "resp"

        public var sign: Double { self == .hrv ? -1.0 : 1.0 }
    }

    /// One night's features: RHR (bpm), HRV (lnRMSSD or RMSSD — one choice for the whole history), skin temperature
    /// (ALG-110 raw night median), breathing (br/min). nil = no value that night.
    public struct Night: Sendable, Equatable {
        public var rhr: Double?
        public var hrv: Double?
        public var temp: Double?
        public var resp: Double?

        public init(rhr: Double? = nil, hrv: Double? = nil, temp: Double? = nil, resp: Double? = nil) {
            self.rhr = rhr
            self.hrv = hrv
            self.temp = temp
            self.resp = resp
        }

        public func value(_ f: Feature) -> Double? {
            let v: Double?
            switch f {
            case .rhr: v = rhr
            case .hrv: v = hrv
            case .temp: v = temp
            case .resp: v = resp
            }
            guard let x = v, x.isFinite else { return nil }
            return x
        }
    }

    public struct Anomaly: Sendable, Equatable {
        public var d: Double
        public var d2: Double
        /// Features used.
        public var k: Int
        /// Sign-oriented robust z per feature; nil when the feature was not used.
        public var z: [Feature: Double]
        /// Baseline nights complete in every used feature (the correlation sample).
        public var corrRows: Int

        public init(d: Double, d2: Double, k: Int, z: [Feature: Double], corrRows: Int) {
            self.d = d
            self.d2 = d2
            self.k = k
            self.z = z
            self.corrRows = corrRows
        }
    }

    /// Solve A x = b for symmetric positive-definite A (Cholesky, then two triangular solves).
    static func choleskySolve(_ a: [[Double]], _ b: [Double]) -> [Double] {
        let n = a.count
        var l = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var acc = 0.0
                for k in 0..<j { acc += l[i][k] * l[j][k] }
                let s = a[i][j] - acc
                l[i][j] = i == j ? s.squareRoot() : s / l[j][j]
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var acc = 0.0
            for k in 0..<i { acc += l[i][k] * y[k] }
            y[i] = (b[i] - acc) / l[i][i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var acc = 0.0
            for k in (i + 1)..<n { acc += l[k][i] * x[k] }
            x[i] = (y[i] - acc) / l[i][i]
        }
        return x
    }

    /// ALG-112 v1. `nights` oldest → newest, last = tonight. Per feature: z = sign · (x − median) / (1.4826 · MAD) over
    /// its baseline values; a feature counts when tonight has it, its baseline holds ≥ 10 values and MAD > 0 (never
    /// imputed, never floored). Needs ≥ 2 features. R = Pearson correlation of the sign-oriented features over baseline
    /// nights complete in all counted features (≥ 10 such nights, else off-diagonals 0); R' = 0.9 R + 0.1 I;
    /// D² = zᵀ R'⁻¹ z.
    public static func anomaly(nights: [Night]) -> Computed<Anomaly> {
        guard let tonight = nights.last else { return .missing("no nights") }
        let base = Array(nights.dropLast().suffix(baselineNights))
        var used: [Feature] = []
        var z: [Feature: Double] = [:]
        for f in Feature.allCases {
            let vals = base.compactMap { $0.value(f) }
            guard let v = tonight.value(f), vals.count >= minBaseline else { continue }
            let med = SignalMath.median(vals)
            let mad = SignalMath.median(vals.map { abs($0 - med) })
            guard mad > 0 else { continue }
            z[f] = f.sign * (v - med) / (madK * mad)
            used.append(f)
        }
        guard used.count >= minFeatures else {
            return .missing("needs at least \(minFeatures) of RHR, HRV, temperature, breathing with \(minBaseline) "
                            + "baseline nights and some spread")
        }
        let rows: [[Double]] = base.compactMap { night -> [Double]? in
            let r = used.compactMap { f in night.value(f).map { f.sign * $0 } }
            return r.count == used.count ? r : nil
        }
        let k = used.count
        var r = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        for i in 0..<k { r[i][i] = 1.0 }
        if rows.count >= minCorrRows {
            for i in 0..<k {
                for j in (i + 1)..<max(i + 1, k) {
                    let c = ALG079.pearsonR(rows.map { $0[i] }, rows.map { $0[j] }).value ?? 0.0
                    r[i][j] = c
                    r[j][i] = c
                }
            }
        }
        let rr = (0..<k).map { i in (0..<k).map { j in (1.0 - ridge) * r[i][j] + (i == j ? ridge : 0.0) } }
        let zv = used.map { z[$0]! }
        let sol = choleskySolve(rr, zv)
        var d2 = 0.0
        for i in 0..<k { d2 += zv[i] * sol[i] }
        return .success(Anomaly(d: d2.squareRoot(), d2: d2, k: k, z: z, corrRows: rows.count))
    }

    public static let spec = MetricSpec(
        key: .anomaly, unit: "z", group: nil, variant: "ALG-112", method: "ALG-112@1 robust-mahalanobis",
        tier: .research, source: "rhr+hrv+temp+resp", window: "night", citation: citation,
        paramsVersion: "base28 min10 ridge0.1 corr10 mad1.4826")

    /// `anomaly` = D (a distance in robust-z units); the note names the features used.
    public static func metric(_ res: Computed<Anomaly>, at: Date) -> Metric {
        let note = res.value.map { r in
            "distance over " + Feature.allCases.filter { r.z[$0] != nil }.map(\.rawValue).joined(separator: ", ")
                + "; research, no alert threshold yet"
        }
        return spec.metric(res.map(\.d), at: at, note: note)
    }
}
