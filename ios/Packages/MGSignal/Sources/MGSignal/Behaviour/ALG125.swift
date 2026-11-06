import Foundation

/// ALG-125 v1 — habit-statistics variants, shown beside ALG-067's Cohen's d in the G-HABIT comparison group (many
/// tests side by side means more false alarms: multiple-comparison control, Benjamini–Hochberg, is ALG-079's job):
///   * mean difference (OpenStrap): the plain difference of means and its % of the without-days mean;
///   * Pearson r between the tag indicator (1 with, 0 without) and the outcome (point-biserial) with a two-sided p;
///   * Welch's unequal-variance t test (Welch–Satterthwaite df; p from the exact t distribution);
///   * one-way ANOVA F, p and η² = SS_between / SS_total (Fabi-SPL).
/// p-values come from the regularised incomplete beta function (`BehaviourMath`), checked against scipy.stats by the
/// generator. At least 3 days on each side, else Missing. Python reference: app/pclab/mglab/ref/behaviour.py;
/// goldens app/shared/golden/behaviour/ALG-125.json.
public enum ALG125 {
    public static let method = "ALG-125@1 habit-statistics"
    public static let citation = "OpenStrap analytics (mean difference); Welch 1947; Pearson 1895; Fisher 1925 (ANOVA); Fabi-SPL"

    public struct MeanDifference: Sendable, Equatable {
        public var delta: Double
        public var pctChange: Double?
        public var meanWith: Double
        public var meanWithout: Double
        public var nWith: Int
        public var nWithout: Int

        public init(delta: Double, pctChange: Double?, meanWith: Double, meanWithout: Double, nWith: Int, nWithout: Int) {
            self.delta = delta
            self.pctChange = pctChange
            self.meanWith = meanWith
            self.meanWithout = meanWithout
            self.nWith = nWith
            self.nWithout = nWithout
        }
    }

    public struct Welch: Sendable, Equatable {
        public var t: Double
        public var df: Double
        public var p: Double

        public init(t: Double, df: Double, p: Double) {
            self.t = t
            self.df = df
            self.p = p
        }
    }

    public struct Pearson: Sendable, Equatable {
        public var r: Double
        public var p: Double
        public var n: Int

        public init(r: Double, p: Double, n: Int) {
            self.r = r
            self.p = p
            self.n = n
        }
    }

    public struct Anova: Sendable, Equatable {
        public var f: Double
        public var df1: Int
        public var df2: Int
        public var p: Double
        public var eta2: Double

        public init(f: Double, df1: Int, df2: Int, p: Double, eta2: Double) {
            self.f = f
            self.df1 = df1
            self.df2 = df2
            self.p = p
            self.eta2 = eta2
        }
    }

    /// ALG-125 v1 — the plain difference of means (OpenStrap).
    public static func meanDifference(with w: [Double], without c: [Double]) -> Computed<MeanDifference> {
        if let m = ALG067.groupsMissing(with: w, without: c) { return .failure(m) }
        let m1 = SignalMath.mean(w)
        let m2 = SignalMath.mean(c)
        return .success(MeanDifference(delta: m1 - m2, pctChange: m2 != 0 ? (m1 - m2) / abs(m2) * 100.0 : nil,
                                       meanWith: m1, meanWithout: m2, nWith: w.count, nWithout: c.count))
    }

    /// ALG-125 v1 — Welch's unequal-variance t test.
    public static func welch(with w: [Double], without c: [Double]) -> Computed<Welch> {
        if let m = ALG067.groupsMissing(with: w, without: c) { return .failure(m) }
        let n1 = Double(w.count)
        let n2 = Double(c.count)
        let s1 = SignalMath.sampleSD(w)
        let s2 = SignalMath.sampleSD(c)
        let a = (s1 * s1) / n1
        let b = (s2 * s2) / n2
        guard a + b > 0 else { return .missing("no spread within either group: Welch's t is undefined") }
        let t = (SignalMath.mean(w) - SignalMath.mean(c)) / (a + b).squareRoot()
        let df = (a + b) * (a + b) / ((a * a) / (n1 - 1.0) + (b * b) / (n2 - 1.0))
        return .success(Welch(t: t, df: df, p: BehaviourMath.tTwoSidedP(t: t, df: df)))
    }

    /// ALG-125 v1 — point-biserial Pearson r of tag vs outcome.
    public static func pearson(with w: [Double], without c: [Double]) -> Computed<Pearson> {
        if let m = ALG067.groupsMissing(with: w, without: c) { return .failure(m) }
        let y = w + c
        let x = [Double](repeating: 1.0, count: w.count) + [Double](repeating: 0.0, count: c.count)
        let n = y.count
        let mx = SignalMath.mean(x)
        let my = SignalMath.mean(y)
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for v in x { sxx += (v - mx) * (v - mx) }
        for v in y { syy += (v - my) * (v - my) }
        guard syy > 0 else { return .missing("the outcome does not vary: r is undefined") }
        for i in 0..<n { sxy += (x[i] - mx) * (y[i] - my) }
        let r = max(-1.0, min(1.0, sxy / (sxx * syy).squareRoot()))
        let p: Double
        if abs(r) >= 1.0 {
            p = 0.0
        } else {
            p = BehaviourMath.tTwoSidedP(t: r * (Double(n - 2) / (1.0 - r * r)).squareRoot(), df: Double(n - 2))
        }
        return .success(Pearson(r: r, p: p, n: n))
    }

    /// ALG-125 v1 — one-way ANOVA (F, p, η²).
    public static func anova(groups: [[Double]]) -> Computed<Anova> {
        guard groups.count >= 2 else { return .missing("ANOVA needs at least two groups") }
        if groups.contains(where: { $0.count < ALG067.minPerGroup }) {
            return .missing("every group needs at least \(ALG067.minPerGroup) days")
        }
        var all: [Double] = []
        for g in groups { all += g }
        let bigN = all.count
        let k = groups.count
        let gm = SignalMath.mean(all)
        var ssb = 0.0
        var ssw = 0.0
        for g in groups {
            let m = SignalMath.mean(g)
            ssb += Double(g.count) * ((m - gm) * (m - gm))
            var inner = 0.0
            for v in g { inner += (v - m) * (v - m) }
            ssw += inner
        }
        guard ssw > 0 else { return .missing("no spread within the groups: F is undefined") }
        let f = (ssb / Double(k - 1)) / (ssw / Double(bigN - k))
        return .success(Anova(f: f, df1: k - 1, df2: bigN - k,
                              p: BehaviourMath.fUpperP(f: f, d1: Double(k - 1), d2: Double(bigN - k)),
                              eta2: ssb / (ssb + ssw)))
    }

    /// G-HABIT — every method side by side; each member is its result or why it is blank (R6).
    public struct Group: Sendable, Equatable {
        public var cohensD: Computed<ALG067.Effect>
        public var meanDifference: Computed<MeanDifference>
        public var pearson: Computed<Pearson>
        public var welch: Computed<Welch>
        public var anova: Computed<Anova>

        public init(cohensD: Computed<ALG067.Effect>, meanDifference: Computed<MeanDifference>, pearson: Computed<Pearson>,
                    welch: Computed<Welch>, anova: Computed<Anova>) {
            self.cohensD = cohensD
            self.meanDifference = meanDifference
            self.pearson = pearson
            self.welch = welch
            self.anova = anova
        }
    }

    /// ALG-125 v1 — all G-HABIT members (ALG-067 first).
    public static func group(with w: [Double], without c: [Double]) -> Group {
        Group(cohensD: ALG067.cohensD(with: w, without: c), meanDifference: meanDifference(with: w, without: c),
              pearson: pearson(with: w, without: c), welch: welch(with: w, without: c), anova: anova(groups: [w, c]))
    }
}
