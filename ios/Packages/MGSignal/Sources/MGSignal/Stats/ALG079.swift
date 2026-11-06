import Foundation

/// ALG-079 v1 — agreement statistics for any pair of comparison-group members (Bland–Altman, ICC, Pearson, Spearman,
/// share within tolerance) and the correlation matrix of APP-104 (D14 "trend matrices"): Spearman ρ per pair of
/// metrics with one Benjamini–Hochberg family over the tested cells. Python reference: app/pclab/mglab/ref/stats.py;
/// goldens app/shared/golden/stats/ALG-079.json (known answers: BH 1995's worked example, Shrout & Fleiss 1979 Table 2,
/// hand-computed ρ, scipy as an independent check). Values only — the Explore view (WP-19) never computes them.
public enum ALG079 {
    public static let citation = "Spearman 1904; Benjamini & Hochberg 1995 JRSS-B 57:289; Bland & Altman 1986; "
        + "Shrout & Fleiss 1979 Psychol Bull 86:420"
    /// UX / WP-19: cells with fewer than 14 paired days are blank "too few days".
    public static let matrixMinPairs = 14
    public static let matrixFDR = 0.05

    /// Index-aligned pairs where both values exist and are finite.
    static func pairs(_ x: [Double?], _ y: [Double?]) -> ([Double], [Double]) {
        var xs: [Double] = []
        var ys: [Double] = []
        for i in 0..<min(x.count, y.count) {
            guard let a = x[i], let b = y[i], a.isFinite, b.isFinite else { continue }
            xs.append(a)
            ys.append(b)
        }
        return (xs, ys)
    }

    // MARK: ranks, Pearson, Spearman

    /// 1-based ranks; ties get the mean of the ranks they span (scipy rankdata "average").
    public static func rankdata(_ x: [Double]) -> [Double] {
        let idx = x.indices.sorted { x[$0] < x[$1] }
        var r = [Double](repeating: 0, count: x.count)
        var i = 0
        while i < idx.count {
            var j = i
            while j + 1 < idx.count && x[idx[j + 1]] == x[idx[i]] { j += 1 }
            let avg = Double(i + j) / 2.0 + 1.0
            for k in i...j { r[idx[k]] = avg }
            i = j + 1
        }
        return r
    }

    static func pearsonR(_ x: [Double], _ y: [Double]) -> Computed<Double> {
        let mx = SignalMath.mean(x)
        let my = SignalMath.mean(y)
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for v in x { sxx += (v - mx) * (v - mx) }
        for v in y { syy += (v - my) * (v - my) }
        guard sxx > 0, syy > 0 else { return .missing("one of the two has no spread: correlation undefined") }
        for i in 0..<x.count { sxy += (x[i] - mx) * (y[i] - my) }
        return .success(max(-1.0, min(1.0, sxy / (sxx * syy).squareRoot())))
    }

    /// Continued fraction of the incomplete beta function (modified Lentz; Numerical Recipes in C, 2nd ed., §6.4).
    static func betacf(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let fpmin = 1e-300
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
            if abs(de - 1.0) < 1e-15 { break }
        }
        return h
    }

    /// Regularised incomplete beta I_x(a, b) (Numerical Recipes §6.4).
    public static func betai(_ a: Double, _ b: Double, _ x: Double) -> Double {
        if x <= 0.0 { return 0.0 }
        if x >= 1.0 { return 1.0 }
        // Split into typed steps: Xcode's type-checker timed out on the one-line form (first CI run, 2026-10-11).
        // Same left-to-right order of additions as before, so the result is bit-identical.
        let lnBeta: Double = lgamma(a + b) - lgamma(a) - lgamma(b)
        let withA: Double = lnBeta + a * log(x)
        let bt: Double = exp(withA + b * log(1.0 - x))
        if x < (a + 1.0) / (a + b + 2.0) { return bt * betacf(a, b, x) / a }
        return 1.0 - bt * betacf(b, a, 1.0 - x) / b
    }

    /// Two-sided p of Student's t: I_{df/(df + t²)}(df/2, 1/2).
    public static func tTwoSidedP(_ t: Double, df: Double) -> Double {
        if t.isInfinite { return 0.0 }
        return betai(df / 2.0, 0.5, df / (df + t * t))
    }

    static func corrP(_ r: Double, n: Int) -> Double {
        if abs(r) >= 1.0 { return 0.0 }
        let df = Double(n - 2)
        return tTwoSidedP(r * (df / (1.0 - r * r)).squareRoot(), df: df)
    }

    public struct Correlation: Sendable, Equatable {
        /// Pearson r or Spearman ρ.
        public var r: Double
        public var n: Int
        /// Two-sided, t approximation with n − 2 df (as scipy).
        public var p: Double

        public init(r: Double, n: Int, p: Double) {
            self.r = r
            self.n = n
            self.p = p
        }
    }

    /// ALG-079 v1 Pearson r on the pairs where both exist. Missing below 3 pairs or with no spread.
    public static func pearson(_ x: [Double?], _ y: [Double?]) -> Computed<Correlation> {
        let (xs, ys) = pairs(x, y)
        guard xs.count >= 3 else { return .missing("needs 3 paired values (have \(xs.count))") }
        return pearsonR(xs, ys).map { Correlation(r: $0, n: xs.count, p: corrP($0, n: xs.count)) }
    }

    /// ALG-079 v1 Spearman ρ = Pearson r of the average ranks of the pairs where both exist; p by the t approximation
    /// (as scipy.stats.spearmanr). Missing below 3 pairs or when either side is constant.
    public static func spearman(_ x: [Double?], _ y: [Double?]) -> Computed<Correlation> {
        let (xs, ys) = pairs(x, y)
        guard xs.count >= 3 else { return .missing("needs 3 paired values (have \(xs.count))") }
        return pearsonR(rankdata(xs), rankdata(ys)).map { Correlation(r: $0, n: xs.count, p: corrP($0, n: xs.count)) }
    }

    /// Spearman of x[t] against y[t + lag] (index-aligned by day; lag ≥ 0 = y later). The Compare view (WP-19).
    public static func spearmanLagged(_ x: [Double?], _ y: [Double?], lag: Int) -> Computed<Correlation> {
        if lag < 0 { return spearmanLagged(y, x, lag: -lag) }
        guard lag > 0 else { return spearman(x, y) }
        let xs = Array(x.prefix(max(0, x.count - lag)))
        let ys = Array(y.dropFirst(min(lag, y.count)))
        return spearman(xs, ys)
    }

    // MARK: Benjamini–Hochberg

    /// Benjamini & Hochberg 1995 step-up adjusted p-values (q), in the input order: q_(i) = min over j ≥ i of
    /// (m / j) p_(j), capped at 1.
    public static func bhAdjust(_ p: [Double]) -> [Double] {
        let m = p.count
        let idx = p.indices.sorted { p[$0] < p[$1] }
        var q = [Double](repeating: 0, count: m)
        var running = 1.0
        var rank = m
        while rank >= 1 {
            let i = idx[rank - 1]
            running = min(running, p[i] * Double(m) / Double(rank))
            q[i] = min(running, 1.0)
            rank -= 1
        }
        return q
    }

    /// BH 1995 at FDR `alpha`: reject where q ≤ alpha (= the k smallest p, k = largest i with p_(i) ≤ i/m · alpha).
    public static func bhReject(_ p: [Double], alpha: Double = 0.05) -> [Bool] {
        bhAdjust(p).map { $0 <= alpha }
    }

    // MARK: correlation matrix (APP-104)

    public struct MatrixCell: Sendable, Equatable {
        public var rho: Double
        public var n: Int
        /// nil on the diagonal.
        public var p: Double?
        /// BH-adjusted p over the tested cells; nil on the diagonal.
        public var q: Double?
        public var significant: Bool?

        public init(rho: Double, n: Int, p: Double? = nil, q: Double? = nil, significant: Bool? = nil) {
            self.rho = rho
            self.n = n
            self.p = p
            self.q = q
            self.significant = significant
        }
    }

    public struct Matrix: Sendable, Equatable {
        public var names: [String]
        /// cells[i][j]; symmetric; blank (Missing "too few days") when undefined or under the pair minimum.
        public var cells: [[Computed<MatrixCell>]]
        /// Cells in the BH family (upper triangle with a value).
        public var tested: Int

        public init(names: [String], cells: [[Computed<MatrixCell>]], tested: Int) {
            self.names = names
            self.cells = cells
            self.tested = tested
        }
    }

    /// ALG-079 v1 matrix for APP-104. `columns[name]` = one value per day (index-aligned, nil = no value). Off-diagonal:
    /// Spearman on the days both have; blank under `minPairs` pairs or when undefined. The tested cells (upper
    /// triangle) are ONE BH family: q = BH-adjusted p, significant = q ≤ alpha. Diagonal: ρ 1 with n = that metric's
    /// days. A name with no column counts as an empty column.
    public static func spearmanMatrix(names: [String], columns: [String: [Double?]],
                                      minPairs: Int = ALG079.matrixMinPairs,
                                      alpha: Double = ALG079.matrixFDR) -> Matrix {
        let k = names.count
        var cells: [[Computed<MatrixCell>]] = Array(
            repeating: Array(repeating: Computed<MatrixCell>.missing("not computed"), count: k), count: k)
        var tested: [(Int, Int)] = []
        for i in 0..<k {
            let ci = columns[names[i]] ?? []
            let nI = ci.filter { $0.map(\.isFinite) ?? false }.count
            cells[i][i] = .success(MatrixCell(rho: 1.0, n: nI))
            for j in (i + 1)..<max(i + 1, k) {
                let (xs, ys) = pairs(ci, columns[names[j]] ?? [])
                let c: Computed<MatrixCell>
                if xs.count < minPairs {
                    c = .missing("too few days (\(xs.count) paired, needs \(minPairs))")
                } else {
                    c = spearman(xs, ys).map { MatrixCell(rho: $0.r, n: $0.n, p: $0.p) }
                    if c.value != nil { tested.append((i, j)) }
                }
                cells[i][j] = c
                cells[j][i] = c
            }
        }
        let q = bhAdjust(tested.map { cells[$0.0][$0.1].value?.p ?? 1.0 })
        for (t, qv) in zip(tested, q) {
            guard var cell = cells[t.0][t.1].value else { continue }
            cell.q = qv
            cell.significant = qv <= alpha
            cells[t.0][t.1] = .success(cell)
            cells[t.1][t.0] = .success(cell)
        }
        return Matrix(names: names, cells: cells, tested: tested.count)
    }

    // MARK: agreement

    public struct BlandAltman: Sendable, Equatable {
        public var bias: Double
        public var sd: Double
        public var loaLow: Double
        public var loaHigh: Double
        public var n: Int

        public init(bias: Double, sd: Double, loaLow: Double, loaHigh: Double, n: Int) {
            self.bias = bias
            self.sd = sd
            self.loaLow = loaLow
            self.loaHigh = loaHigh
            self.n = n
        }
    }

    /// ALG-079 v1 Bland & Altman 1986: d = a − b on the pairs; bias = mean d, SD ddof 1, limits bias ± 1.96 SD.
    public static func blandAltman(_ a: [Double?], _ b: [Double?]) -> Computed<BlandAltman> {
        let (xs, ys) = pairs(a, b)
        guard xs.count >= 3 else { return .missing("needs 3 paired values (have \(xs.count))") }
        let d = (0..<xs.count).map { xs[$0] - ys[$0] }
        let bias = SignalMath.mean(d)
        let sd = SignalMath.sampleSD(d)
        return .success(BlandAltman(bias: bias, sd: sd, loaLow: bias - 1.96 * sd, loaHigh: bias + 1.96 * sd,
                                    n: d.count))
    }

    public struct ICC: Sendable, Equatable {
        /// ICC(1,1), one-way.
        public var icc1: Double
        /// ICC(2,1), two-way random, absolute agreement (McGraw & Wong ICC(A,1)).
        public var icc2: Double
        /// ICC(3,1), two-way mixed, consistency (ICC(C,1)).
        public var icc3: Double
        public var n: Int
        public var k: Int

        public init(icc1: Double, icc2: Double, icc3: Double, n: Int, k: Int) {
            self.icc1 = icc1
            self.icc2 = icc2
            self.icc3 = icc3
            self.n = n
            self.k = k
        }
    }

    /// ALG-079 v1 intraclass correlation (Shrout & Fleiss 1979) of n targets × k raters from the two-way ANOVA mean
    /// squares BMS, JMS, EMS, WMS. Rows with a missing value are dropped. Missing below 2 complete rows or 2 raters, or
    /// with no variance between targets.
    public static func icc(_ rows: [[Double?]]) -> Computed<ICC> {
        let full: [[Double]] = rows.compactMap { r -> [Double]? in
            let v = r.compactMap { $0 }.filter(\.isFinite)
            return v.count == r.count ? v : nil
        }
        guard full.count >= 2, full[0].count >= 2 else { return .missing("needs at least 2 complete targets and 2 raters") }
        let n = full.count
        let k = full[0].count
        let nd = Double(n)
        let kd = Double(k)
        var total = 0.0
        for r in full { for v in r { total += v } }
        let grand = total / (nd * kd)
        let rowM = full.map { r -> Double in
            var s = 0.0
            for v in r { s += v }
            return s / kd
        }
        let colM = (0..<k).map { j -> Double in
            var s = 0.0
            for i in 0..<n { s += full[i][j] }
            return s / nd
        }
        var ssTotal = 0.0
        for r in full { for v in r { ssTotal += (v - grand) * (v - grand) } }
        var ssRows = 0.0
        for m in rowM { ssRows += (m - grand) * (m - grand) }
        ssRows *= kd
        var ssCols = 0.0
        for m in colM { ssCols += (m - grand) * (m - grand) }
        ssCols *= nd
        let ssErr = ssTotal - ssRows - ssCols
        let bms = ssRows / (nd - 1)
        let jms = ssCols / (kd - 1)
        let ems = ssErr / ((nd - 1) * (kd - 1))
        let wms = (ssTotal - ssRows) / (nd * (kd - 1))
        let d1 = bms + (kd - 1) * wms
        let d2 = bms + (kd - 1) * ems + kd * (jms - ems) / nd
        let d3 = bms + (kd - 1) * ems
        guard d1 > 0, d2 > 0, d3 > 0 else { return .missing("no variance between targets: ICC undefined") }
        return .success(ICC(icc1: (bms - wms) / d1, icc2: (bms - ems) / d2, icc3: (bms - ems) / d3, n: n, k: k))
    }

    /// Share of pairs with |a − b| ≤ tol.
    public static func withinTolerance(_ a: [Double?], _ b: [Double?], tol: Double) -> Computed<Double> {
        let (xs, ys) = pairs(a, b)
        guard !xs.isEmpty else { return .missing("no paired values") }
        let hits = (0..<xs.count).filter { abs(xs[$0] - ys[$0]) <= tol }.count
        return .success(Double(hits) / Double(xs.count))
    }

    public struct Agreement: Sendable, Equatable {
        public var blandAltman: Computed<BlandAltman>
        /// ICC(2,1) absolute agreement.
        public var iccA1: Computed<Double>
        public var pearson: Computed<Correlation>
        public var spearman: Computed<Correlation>
        public var withinTol: Computed<Double>

        public init(blandAltman: Computed<BlandAltman>, iccA1: Computed<Double>, pearson: Computed<Correlation>,
                    spearman: Computed<Correlation>, withinTol: Computed<Double>) {
            self.blandAltman = blandAltman
            self.iccA1 = iccA1
            self.pearson = pearson
            self.spearman = spearman
            self.withinTol = withinTol
        }
    }

    /// ALG-079 v1 for one pair of members of a comparison group (e.g. G-RESP ALG-121 vs MS-07), index-aligned by
    /// night or day. Each part is Missing on its own.
    public static func agreement(_ a: [Double?], _ b: [Double?], tol: Double) -> Agreement {
        let (xs, ys) = pairs(a, b)
        let rows: [[Double?]] = (0..<xs.count).map { [xs[$0], ys[$0]] }
        return Agreement(blandAltman: blandAltman(a, b), iccA1: icc(rows).map(\.icc2), pearson: pearson(a, b),
                         spearman: spearman(a, b), withinTol: withinTolerance(a, b, tol: tol))
    }
}
