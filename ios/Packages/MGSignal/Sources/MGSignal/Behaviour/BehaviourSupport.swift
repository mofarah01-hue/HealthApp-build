import Foundation

/// Special functions for the habit statistics (ALG-125): the regularised incomplete beta function and the Student-t /
/// F tail probabilities built on it. Python mirror: `mglab.ref.behaviour` `betainc_reg`, `t_two_sided_p`, `f_upper_p`
/// (modified Lentz continued fraction, Numerical Recipes 6.4). Checked against scipy.stats by gen_behaviour.py.
public enum BehaviourMath {
    /// Continued fraction for the incomplete beta (modified Lentz).
    public static func betaContinuedFraction(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let fpmin = 1e-300
        let eps = 3e-16
        let qab = a + b
        let qap = a + 1.0
        let qam = a - 1.0
        var c = 1.0
        var d = 1.0 - qab * x / qap
        if abs(d) < fpmin { d = fpmin }
        d = 1.0 / d
        var h = d
        for m in 1...300 {
            let md = Double(m)
            let m2 = 2.0 * md
            var aa = md * (b - md) * x / ((qam + m2) * (a + m2))
            d = 1.0 + aa * d
            if abs(d) < fpmin { d = fpmin }
            c = 1.0 + aa / c
            if abs(c) < fpmin { c = fpmin }
            d = 1.0 / d
            h *= d * c
            aa = -(a + md) * (qab + md) * x / ((a + m2) * (qap + m2))
            d = 1.0 + aa * d
            if abs(d) < fpmin { d = fpmin }
            c = 1.0 + aa / c
            if abs(c) < fpmin { c = fpmin }
            d = 1.0 / d
            let de = d * c
            h *= de
            if abs(de - 1.0) < eps { break }
        }
        return h
    }

    /// Regularised incomplete beta function I_x(a, b).
    public static func betaIncReg(_ a: Double, _ b: Double, _ x: Double) -> Double {
        if x <= 0.0 { return 0.0 }
        if x >= 1.0 { return 1.0 }
        let bt = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log1p(-x))
        if x < (a + 1.0) / (a + b + 2.0) {
            return bt * betaContinuedFraction(a, b, x) / a
        }
        return 1.0 - bt * betaContinuedFraction(b, a, 1.0 - x) / b
    }

    /// Two-sided p of Student's t with `df` degrees of freedom: I_{df/(df+t²)}(df/2, 1/2).
    public static func tTwoSidedP(t: Double, df: Double) -> Double {
        betaIncReg(df / 2.0, 0.5, df / (df + t * t))
    }

    /// Upper-tail p of the F distribution: I_{d2/(d2+d1·F)}(d2/2, d1/2).
    public static func fUpperP(f: Double, d1: Double, d2: Double) -> Double {
        betaIncReg(d2 / 2.0, d1 / 2.0, d2 / (d2 + d1 * f))
    }
}

/// Seconds ↔ Date for the behaviour family. Every algorithm computes in unix seconds (Double) and only its public
/// surface speaks `Date`; the same arithmetic runs in the Python reference.
enum BehaviourClock {
    static let hourSeconds = 3600.0

    static func seconds(_ d: Date) -> Double { d.timeIntervalSince1970 }

    static func date(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    /// Floor to a whole minute (so a displayed cut-off never lies on the wrong side of the limit).
    static func floorMinute(_ s: Double) -> Double { (s / 60.0).rounded(.down) * 60.0 }
}
