import Foundation

/// Classic Lomb–Scargle periodogram (Lomb 1976; Scargle 1982 eq. 10) on a FIXED frequency grid, shared by ALG-011,
/// ALG-104 and WP-09's ALG-121. Python mirror: `mglab.ref.ls_psd` / `band_power` (cross-checked there against
/// scipy.signal.lombscargle, max relative difference ~1e-14).
///
/// Grid: f_k = k · 0.001 Hz, k = 1…kMax; array index k − 1. Band edges are INTEGER k, half-open [kLo, kHi):
/// LF = [40, 150) = 0.04–0.15 Hz, HF = [150, 400) = 0.15–0.40 Hz (Task Force 1996 bands).
/// PSD is one-sided in input-units²/Hz: PSD = 2·P / fs with fs = (N − 1) / (t_last − t_first), so the sum of
/// PSD · 0.001 over a band approximates that band's variance (a sine of amplitude A gives A²/2).
public enum LombScargle {
    public static let gridStepHz = 0.001

    /// PSD at k = 1…kMax. `times` in seconds (any origin), `values` already de-meaned or detrended.
    /// Returns [] when there are fewer than 2 points, the lengths differ, or the times do not advance.
    public static func psd(times: [Double], values: [Double], kMax: Int) -> [Double] {
        let n = times.count
        guard n >= 2, values.count == n, kMax >= 1 else { return [] }
        let t0 = times[0]
        let tt = times.map { $0 - t0 }
        let span = tt[n - 1] - tt[0]
        guard span > 0 else { return [] }
        let fs = Double(n - 1) / span
        let eps = 1e-12 * Double(n)
        var out = [Double](repeating: 0, count: kMax)
        for k in 1...kMax {
            let w = 2.0 * Double.pi * Double(k) * gridStepHz
            var s2 = 0.0
            var c2 = 0.0
            for t in tt {
                s2 += sin(2.0 * w * t)
                c2 += cos(2.0 * w * t)
            }
            let tau = atan2(s2, c2) / (2.0 * w)
            var yc = 0.0
            var ys = 0.0
            var cc = 0.0
            var ss = 0.0
            for i in 0..<n {
                let a = w * (tt[i] - tau)
                let c = cos(a)
                let s = sin(a)
                yc += values[i] * c
                ys += values[i] * s
                cc += c * c
                ss += s * s
            }
            var p = 0.0
            if cc > eps { p += yc * yc / cc }
            if ss > eps { p += ys * ys / ss }
            out[k - 1] = 2.0 * (0.5 * p) / fs
        }
        return out
    }

    /// Σ PSD[k] over k in [kLo, kHi), times the grid step. 0 for an empty or out-of-range band.
    public static func bandPower(psd: [Double], kLo: Int, kHi: Int) -> Double {
        let lo = max(kLo, 1)
        let hi = min(kHi, psd.count + 1)
        guard hi > lo else { return 0 }
        var s = 0.0
        for k in lo..<hi { s += psd[k - 1] }
        return s * gridStepHz
    }
}
