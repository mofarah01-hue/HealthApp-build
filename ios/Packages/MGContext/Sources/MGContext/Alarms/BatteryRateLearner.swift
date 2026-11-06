import Foundation
import MGDomain

// MARK: - Learned extra battery drain per strap feature (T9981, 2026-10-17)
//
// `BatteryLoadModel.assumedExtraPercentPerHour` is a guess. This file measures it from what the app already logs: the
// feature on/off spans (`FeatureLogRecorder`) beside the stored battery readings. Model, per stretch of readings:
//
//     percent dropped = hours x base + sum over features (hours the feature was on x its extra %/h)
//
// fitted by non-negative least squares (exact: every active set of the 1 + 4 unknowns is tried), with a Huber re-weighting
// so one odd reading cannot drag it. Charging stretches, rises and long gaps are left out; readings are grouped into
// bins of at least an hour so whole-percent steps do not matter.
//
// A feature's learned value replaces the guess only when the data holds at least `minOnHours` with it on AND
// `minOffHours` with it off (otherwise "on" cannot be told apart from the base rate). Even then it is shrunk toward the
// guess as if `priorHours` of on-time had been seen at the guess, so thin data stays near the guess.

/// One feature's extra drain: the value used, how many on-hours it rests on, and whether it was measured (else the guess).
public struct LearnedFeatureRate: Codable, Equatable, Sendable {
    public var feature: StrapFeature
    public var percentPerHour: Double
    public var hours: Double
    public var measured: Bool

    public init(feature: StrapFeature, percentPerHour: Double, hours: Double, measured: Bool) {
        self.feature = feature
        self.percentPerHour = percentPerHour
        self.hours = hours
        self.measured = measured
    }
}

/// What the fitter learned. Persisted (kv `app.battery_learned_rates`) so it survives the 7-day window rolling on.
public struct BatteryLearnedRates: Codable, Equatable, Sendable {
    /// Idle (no feature) drain in %/h; nil until there are `BatteryRateLearner.minBaseHours` of usable discharge.
    public var basePercentPerHour: Double?
    public var baseHours: Double
    public var features: [LearnedFeatureRate]
    public var fittedAt: Date?

    public init(basePercentPerHour: Double?, baseHours: Double, features: [LearnedFeatureRate], fittedAt: Date?) {
        self.basePercentPerHour = basePercentPerHour
        self.baseHours = baseHours
        self.features = features
        self.fittedAt = fittedAt
    }
}

public enum BatteryRateLearner {
    public static let windowHours: Double = 168
    public static let minOnHours: Double = 3
    public static let minOffHours: Double = 3
    public static let minBaseHours: Double = 6
    /// Shrinkage: as if this many on-hours had been seen at the guess.
    public static let priorHours: Double = 3
    static let binHours: Double = 1
    /// Longer gaps between readings are not trusted (the app may have been dead and the span log wrong).
    static let maxGapHours: Double = 14
    /// A rise bigger than this between two readings is not discharge.
    static let maxRisePoints: Double = 0.3
    static let minScalePoints: Double = 0.25

    struct Bin {
        var drop: Double
        var dt: Double
        var on: [StrapFeature: Double]
    }

    public static func learn(readings: [BatteryReading], spans: [FeatureSpan], now: Date,
                             prior: BatteryLearnedRates? = nil) -> BatteryLearnedRates {
        let nowT = now.timeIntervalSince1970
        var r = readings.filter { Double($0.ts) >= nowT - windowHours * 3600 && Double($0.ts) <= nowT + 60
            && $0.percent.isFinite && (0...100).contains($0.percent) }
        r.sort { $0.ts < $1.ts }
        let bins = makeBins(r, spans: spans, now: now)
        let fresh = fit(bins, now: now)
        return merged(fresh, prior: prior)
    }

    /// Discharge-only bins of at least `binHours`; charging readings, rises (and the interval after a charge-sized
    /// rise) and long gaps break the chain.
    static func makeBins(_ r: [BatteryReading], spans: [FeatureSpan], now: Date) -> [Bin] {
        guard r.count >= 2 else { return [] }
        var out: [Bin] = []
        var start: Int?
        var skipNext = false
        for i in 1..<r.count {
            let a = r[i - 1]
            let b = r[i]
            let dt = Double(b.ts - a.ts) / 3600
            let rise = b.percent - a.percent
            let wasSkip = skipNext
            skipNext = rise >= BatteryEstimator.chargeJumpPoints
            let usable = !wasSkip && dt > 0 && dt <= maxGapHours && a.charging != true && b.charging != true
                && rise <= maxRisePoints
            guard usable else {
                start = nil
                continue
            }
            if start == nil { start = i - 1 }
            let s = r[start!]
            let spanH = Double(b.ts - s.ts) / 3600
            let drop = s.percent - b.percent
            if spanH >= binHours && (drop >= 1 || spanH >= 3) {
                let from = Date(timeIntervalSince1970: Double(s.ts))
                let to = Date(timeIntervalSince1970: Double(b.ts))
                out.append(Bin(drop: max(0, drop), dt: spanH, on: onHours(spans, from: from, to: to, now: now)))
                start = nil
            }
        }
        return out
    }

    static func onHours(_ spans: [FeatureSpan], from: Date, to: Date, now: Date) -> [StrapFeature: Double] {
        var out: [StrapFeature: Double] = [:]
        for s in spans {
            let a = max(s.from, from)
            let b = min(s.to ?? now, to)
            if b > a { out[s.feature, default: 0] += b.timeIntervalSince(a) / 3600 }
        }
        let span = to.timeIntervalSince(from) / 3600
        for (f, h) in out where h > span { out[f] = span }
        return out
    }

    static func fit(_ bins: [Bin], now: Date) -> BatteryLearnedRates {
        let guesses = BatteryLoadModel.assumedExtraPercentPerHour
        let totalDt = bins.reduce(0) { $0 + $1.dt }
        let totalDrop = bins.reduce(0) { $0 + $1.drop }
        var onTotal: [StrapFeature: Double] = [:]
        for f in StrapFeature.allCases { onTotal[f] = bins.reduce(0) { $0 + ($1.on[f] ?? 0) } }
        let learnable = StrapFeature.allCases.filter {
            (onTotal[$0] ?? 0) >= minOnHours && totalDt - (onTotal[$0] ?? 0) >= minOffHours
        }

        func guessEntries() -> [LearnedFeatureRate] {
            StrapFeature.allCases.map {
                LearnedFeatureRate(feature: $0, percentPerHour: guesses[$0] ?? 0, hours: onTotal[$0] ?? 0, measured: false)
            }
        }
        guard totalDt >= minBaseHours, totalDrop >= BatteryEstimator.minDropPoints else {
            return BatteryLearnedRates(basePercentPerHour: nil, baseHours: totalDt, features: guessEntries(), fittedAt: now)
        }

        // Rows: [dt, on-hours of each learnable feature]; target: drop minus the guessed load of the fixed features.
        var rows: [[Double]] = []
        var y: [Double] = []
        for bin in bins {
            rows.append([bin.dt] + learnable.map { bin.on[$0] ?? 0 })
            var target = bin.drop
            for f in StrapFeature.allCases where !learnable.contains(f) { target -= (guesses[f] ?? 0) * (bin.on[f] ?? 0) }
            y.append(target)
        }
        let priors = learnable.map { guesses[$0] ?? 0 }
        var w = [Double](repeating: 1, count: bins.count)
        var coef = [Double](repeating: 0, count: 1 + learnable.count)
        for _ in 0..<6 {
            guard let c = solveNNLS(rows, y, w, priors: priors) else { break }
            coef = c
            let res = zip(rows, y).map { row, t in t - zip(row, coef).reduce(0) { $0 + $1.0 * $1.1 } }
            let scale = max(1.4826 * median(res.map { abs($0) }), minScalePoints)
            let k = 1.345 * scale
            w = res.map { abs($0) <= k ? 1 : k / abs($0) }
        }

        var features = guessEntries()
        for (j, f) in learnable.enumerated() {
            if let i = features.firstIndex(where: { $0.feature == f }) {
                features[i].percentPerHour = coef[1 + j]
                features[i].measured = true
            }
        }
        return BatteryLearnedRates(basePercentPerHour: coef[0], baseHours: totalDt, features: features, fittedAt: now)
    }

    /// Exact non-negative ridge-to-prior least squares: tries every active set of the unknowns (at most 2^5) and keeps
    /// the feasible one with the lowest weighted objective. Unknown 0 is the base rate (no prior); the rest have a
    /// ridge of `priorHours` toward `priors`.
    static func solveNNLS(_ rows: [[Double]], _ y: [Double], _ w: [Double], priors: [Double]) -> [Double]? {
        let n = 1 + priors.count
        var best: [Double]?
        var bestObj = Double.infinity
        for mask in 0..<(1 << n) {
            let idx = (0..<n).filter { mask & (1 << $0) != 0 }
            var coef = [Double](repeating: 0, count: n)
            if !idx.isEmpty {
                var a = [[Double]](repeating: [Double](repeating: 0, count: idx.count), count: idx.count)
                var b = [Double](repeating: 0, count: idx.count)
                for (ri, row) in rows.enumerated() {
                    for (p, cp) in idx.enumerated() {
                        b[p] += w[ri] * row[cp] * y[ri]
                        for (q, cq) in idx.enumerated() { a[p][q] += w[ri] * row[cp] * row[cq] }
                    }
                }
                for (p, cp) in idx.enumerated() where cp >= 1 {
                    a[p][p] += priorHours
                    b[p] += priorHours * priors[cp - 1]
                }
                guard let sol = gauss(a, b) else { continue }
                for (p, cp) in idx.enumerated() { coef[cp] = sol[p] }
                if coef.contains(where: { $0 < 0 }) { continue }
            }
            var obj = 0.0
            for (ri, row) in rows.enumerated() {
                let e = y[ri] - zip(row, coef).reduce(0) { $0 + $1.0 * $1.1 }
                obj += w[ri] * e * e
            }
            for (k, g) in priors.enumerated() { obj += priorHours * (coef[1 + k] - g) * (coef[1 + k] - g) }
            if obj < bestObj {
                bestObj = obj
                best = coef
            }
        }
        return best
    }

    static func gauss(_ aIn: [[Double]], _ bIn: [Double]) -> [Double]? {
        var a = aIn
        var b = bIn
        let n = b.count
        for col in 0..<n {
            var piv = col
            for r in col..<n where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            guard abs(a[piv][col]) > 1e-9 else { return nil }
            a.swapAt(col, piv)
            b.swapAt(col, piv)
            for r in (col + 1)..<max(n, col + 1) {
                let f = a[r][col] / a[col][col]
                for c in col..<n { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<max(n, r + 1) { s -= a[r][c] * x[c] }
            x[r] = s / a[r][r]
        }
        return x
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Keeps the saved values when this fit rests on clearly less data (the old nights rolled out of the window).
    static func merged(_ fresh: BatteryLearnedRates, prior: BatteryLearnedRates?) -> BatteryLearnedRates {
        guard let prior else { return fresh }
        var out = fresh
        if fresh.basePercentPerHour == nil || (prior.basePercentPerHour != nil && fresh.baseHours < 0.5 * prior.baseHours) {
            if prior.basePercentPerHour != nil {
                out.basePercentPerHour = prior.basePercentPerHour
                out.baseHours = prior.baseHours
            }
        }
        out.features = fresh.features.map { f in
            guard let old = prior.features.first(where: { $0.feature == f.feature }), old.measured else { return f }
            if !f.measured || f.hours < 0.5 * old.hours { return old }
            return f
        }
        return out
    }
}
