import Foundation

/// Shared statistics, one definition for every family (Python mirror: `mglab.ref` mean / sample_sd / quantile …).
/// Sums run left to right, as the Python reference does, so parity holds to the last few bits.
/// Callers check counts first: these functions assume non-empty input (documented per function).
public enum SignalMath {
    /// Arithmetic mean. Requires `x.count > 0`.
    public static func mean(_ x: [Double]) -> Double {
        var s = 0.0
        for v in x { s += v }
        return s / Double(x.count)
    }

    /// Standard deviation with ddof = 1 (n − 1). Requires `x.count >= 2`.
    public static func sampleSD(_ x: [Double]) -> Double {
        let m = mean(x)
        var ss = 0.0
        for v in x { ss += (v - m) * (v - m) }
        return (ss / Double(x.count - 1)).squareRoot()
    }

    /// Standard deviation with ddof = 0; 0 for fewer than 2 values (noop StressMath.std).
    public static func populationSD(_ x: [Double]) -> Double {
        guard x.count >= 2 else { return 0 }
        let m = mean(x)
        var ss = 0.0
        for v in x { ss += (v - m) * (v - m) }
        return (ss / Double(x.count)).squareRoot()
    }

    /// Type-7 quantile (numpy default, linear interpolation) of an already sorted, non-empty array.
    public static func quantileSorted(_ s: [Double], _ q: Double) -> Double {
        let h = Double(s.count - 1) * q
        let lo = Int(h.rounded(.down))
        if lo + 1 >= s.count { return s[s.count - 1] }
        return s[lo] + (h - Double(lo)) * (s[lo + 1] - s[lo])
    }

    /// Type-7 quantile of a non-empty array.
    public static func quantile(_ x: [Double], _ q: Double) -> Double {
        quantileSorted(x.sorted(), q)
    }

    /// Median (mean of the two middle values for an even count). Requires `x.count > 0`.
    public static func median(_ x: [Double]) -> Double {
        quantileSorted(x.sorted(), 0.5)
    }

    /// Residuals of the least-squares line y = a + b·t; with no spread in t, y minus its mean.
    public static func linearDetrend(t: [Double], y: [Double]) -> [Double] {
        let tm = mean(t)
        let ym = mean(y)
        var stt = 0.0
        for v in t { stt += (v - tm) * (v - tm) }
        if stt <= 0 { return y.map { $0 - ym } }
        var sty = 0.0
        for i in 0..<t.count { sty += (t[i] - tm) * (y[i] - ym) }
        let b = sty / stt
        return (0..<y.count).map { y[$0] - (ym + b * (t[$0] - tm)) }
    }

    /// Least-squares slope of y on x. Requires at least two distinct x.
    public static func olsSlope(x: [Double], y: [Double]) -> Double {
        let xm = mean(x)
        let ym = mean(y)
        var sxy = 0.0
        var sxx = 0.0
        for i in 0..<x.count {
            sxy += (x[i] - xm) * (y[i] - ym)
            sxx += (x[i] - xm) * (x[i] - xm)
        }
        return sxy / sxx
    }
}
