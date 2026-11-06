import Foundation
import MGDomain

/// ALG-075 v1 — roll-ups on the phone: robust z, normal band, EWMA, two-sided CUSUM change points, week / month summaries
/// (G-CP). Python reference: `robust_z`, `normal_band`, `ewma`, `lam_from_tau`, `cusum_change_points`, `window_summary`;
/// goldens app/shared/golden/day/ALG-075.json. Bayesian online change points and PELT (ALG-131) are PC-tier / later.
///
/// robust z = (x − median) / (1.4826·MAD) against the last ≤ 28 earlier values; CUSUM after Page 1954, standardised
/// against the median / MAD of the points before it (OpenStrap/analytics wellness/changepoint.dart, constants checked
/// 2026-10-11: k 0.5, h 5, 10 baseline points).
public enum ALG075 {
    public static let method = "ALG-075@1 robust-z-ewma-cusum"
    public static let paramsVersion = "1"
    /// MAD → SD for normal data.
    public static let madToSD = 1.4826
    public static let robustWindowDays = 28
    public static let robustMinDays = 14
    public static let cusumK = 0.5
    public static let cusumH = 5.0
    public static let cusumMinBaseline = 10

    /// Median absolute deviation about the median, × 1.4826 when `scaled`. Requires a non-empty array.
    public static func mad(_ x: [Double], scaled: Bool = true) -> Double {
        let med = DayKit.median(x)
        let raw = DayKit.median(x.map { abs($0 - med) })
        return scaled ? raw * madToSD : raw
    }

    static func cleaned(_ history: [Double?], window: Int) -> [Double] {
        var out: [Double] = []
        for v in history {
            if let v, v.isFinite { out.append(v) }
        }
        return out.count > window ? Array(out.suffix(window)) : out
    }

    // MARK: Robust z and the normal band

    public enum Basis: String, Sendable {
        /// Scale = 1.4826·MAD.
        case mad = "mad"
        /// MAD was 0 (a quantised baseline): scale = sample SD.
        case sd = "sd"
    }

    public struct RobustZ: Sendable, Equatable {
        public var z: Double
        public var median: Double
        public var scale: Double
        public var basis: Basis
        public var n: Int

        public init(z: Double, median: Double, scale: Double, basis: Basis, n: Int) {
            self.z = z
            self.median = median
            self.scale = scale
            self.basis = basis
            self.n = n
        }
    }

    /// ALG-075 v1 — robust z of `x` against the last ≤ `window` earlier values; needs `minN` (14). A quantised baseline
    /// can have MAD 0: the scale then falls back to the sample SD (basis `.sd`); no spread at all is Missing, and
    /// `quantum` (the measurement step, e.g. 1 bpm) refuses a baseline whose SD is below it — 0.27 bpm of SD on whole-bpm
    /// data is rounding, not spread.
    public static func robustZ(history: [Double?], x: Double?, window: Int = ALG075.robustWindowDays,
                               minN: Int = ALG075.robustMinDays, quantum: Double? = nil) -> Computed<RobustZ> {
        guard let x, x.isFinite else { return .missing("no value today") }
        let h = cleaned(history, window: window)
        if h.count < minN { return .missing("Learning your normal: \(h.count) of \(minN) days so far") }
        if h.isEmpty { return .missing("no spread in the baseline") }
        let med = DayKit.median(h)
        var scale = mad(h)
        var basis = Basis.mad
        if scale <= 0 {
            scale = h.count >= 2 ? DayKit.sampleSD(h) : 0.0
            basis = .sd
        }
        if !(scale > 0) { return .missing("no spread in the baseline") }
        if let quantum, DayKit.sampleSD(h) < quantum { return .missing("the baseline spread is below the measurement step") }
        return .success(RobustZ(z: (x - med) / scale, median: med, scale: scale, basis: basis, n: h.count))
    }

    public struct NormalBand: Sendable, Equatable {
        public var low: Double
        public var high: Double
        public var median: Double
        public var scale: Double
        public var n: Int

        public init(low: Double, high: Double, median: Double, scale: Double, n: Int) {
            self.low = low
            self.high = high
            self.median = median
            self.scale = scale
            self.n = n
        }
    }

    /// ALG-075 v1 — the normal band on Explore = median ± 1.4826·MAD of the last ≤ 28 values (UX §11).
    public static func normalBand(history: [Double?], window: Int = ALG075.robustWindowDays,
                                  minN: Int = ALG075.robustMinDays) -> Computed<NormalBand> {
        let h = cleaned(history, window: window)
        if h.count < minN || h.isEmpty { return .missing("Learning your normal: \(h.count) of \(minN) days so far") }
        let med = DayKit.median(h)
        let scale = mad(h)
        return .success(NormalBand(low: med - scale, high: med + scale, median: med, scale: scale, n: h.count))
    }

    // MARK: EWMA

    /// ALG-075 v1 — s_t = s_(t−1) + λ·(x_t − s_(t−1)), started at the first valid value; nil entries carry the previous
    /// value forward (nil before the first valid one). λ = `ALG036.lambda(tauDays:)` for a time constant in days.
    public static func ewma(_ values: [Double?], lam: Double) -> [Double?] {
        var out: [Double?] = []
        out.reserveCapacity(values.count)
        var s: Double?
        for v in values {
            if let v, v.isFinite {
                if let cur = s {
                    s = cur + lam * (v - cur)
                } else {
                    s = v
                }
            }
            out.append(s)
        }
        return out
    }

    // MARK: CUSUM change points

    public struct ChangePoint: Sendable, Equatable {
        public var index: Int
        /// +1 up, −1 down.
        public var direction: Int
        public var stat: Double

        public init(index: Int, direction: Int, stat: Double) {
            self.index = index
            self.direction = direction
            self.stat = stat
        }
    }

    /// ALG-075 v1 — two-sided CUSUM change points on a daily series, oldest first. Each point is scored against the
    /// median / 1.4826·MAD of the points BEFORE it back to the start of the current regime (never the whole series, which
    /// would hide a permanent step): z = (x − median) / scale, up = max(0, up + z − k), down = max(0, down − z − k); a
    /// detection fires when either exceeds h, resets both sums and restarts the baseline there. A flat baseline (MAD 0)
    /// holds — no SD fallback, because the SD would be driven by the point under test. `days` = integer day numbers aligned
    /// with `x`: a hole of more than one day resets the regime and both sums (no evidence carries across a gap).
    public static func cusumChangePoints(_ x: [Double], days: [Int]? = nil, k: Double = ALG075.cusumK,
                                         h: Double = ALG075.cusumH, minBaseline: Int = ALG075.cusumMinBaseline) -> [ChangePoint] {
        var out: [ChangePoint] = []
        let n = x.count
        if n <= minBaseline { return out }
        let useDays = days != nil && days!.count == n
        var regime = 0
        var up = 0.0
        var dn = 0.0
        for i in 0..<n {
            if useDays && i > 0 && days![i] - days![i - 1] > 1 {
                up = 0.0
                dn = 0.0
                regime = i
            }
            let base = Array(x[regime..<i])
            if base.count < minBaseline { continue }
            let c = DayKit.median(base)
            let s = mad(base)
            if !(s > 0) { continue }
            let z = (x[i] - c) / s
            up = max(0.0, up + z - k)
            dn = max(0.0, dn - z - k)
            if up > h || dn > h {
                let upward = up > h
                out.append(ChangePoint(index: i, direction: upward ? 1 : -1, stat: upward ? up : dn))
                up = 0.0
                dn = 0.0
                regime = i
            }
        }
        return out
    }

    // MARK: Week / month roll-up

    public struct WindowSummary: Sendable, Equatable {
        public var n: Int
        /// Valid values / expected values (≤ 1); nil when no expected count was given.
        public var coverage: Double?
        public var median: Double
        public var iqr: Double
        public var mean: Double
        public var min: Double
        public var max: Double
        public var slopePerDay: Double

        public init(n: Int, coverage: Double?, median: Double, iqr: Double, mean: Double, min: Double, max: Double,
                    slopePerDay: Double) {
            self.n = n
            self.coverage = coverage
            self.median = median
            self.iqr = iqr
            self.mean = mean
            self.min = min
            self.max = max
            self.slopePerDay = slopePerDay
        }
    }

    /// ALG-075 v1 — roll-up of one week / month, one value per day (nil = none): median, IQR (type-7 quartiles), mean, min,
    /// max, coverage = valid / expected, and the least-squares slope per day over the day index. Needs 3 valid values.
    public static func windowSummary(values: [Double?], expectedN: Int) -> Computed<WindowSummary> {
        var xs: [Double] = []
        var ys: [Double] = []
        for (i, v) in values.enumerated() {
            if let v, v.isFinite {
                xs.append(Double(i))
                ys.append(v)
            }
        }
        if ys.count < 3 { return .missing("needs 3 values (have \(ys.count))") }
        let s = ys.sorted()
        return .success(WindowSummary(
            n: ys.count, coverage: expectedN > 0 ? Swift.min(1.0, Double(ys.count) / Double(expectedN)) : nil,
            median: DayKit.median(ys), iqr: SignalMath.quantileSorted(s, 0.75) - SignalMath.quantileSorted(s, 0.25),
            mean: DayKit.mean(ys), min: s[0], max: s[s.count - 1], slopePerDay: SignalMath.olsSlope(x: xs, y: ys)))
    }
}
