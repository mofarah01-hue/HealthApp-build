import Foundation
import MGDomain

/// ALG-051 self-check v1 — does the predicted alertness (a model estimate) track Mo? (D-HRV-WALK-2, Oct 17 2026.)
///
/// Mo runs the app's 3-minute reaction test (ALG-050, PVT-B) a few times a day for two weeks. Each test stores the
/// model's prediction at its start (`ReactionTestFields.predictedAlertness`, written by the app). The agreement is the
/// Spearman rank correlation between the prediction and the NEGATIVE mean reaction time (a more alert you reacts faster,
/// so a positive number means the model tracks you). Spearman because the model's score is not linear in reaction time
/// and one slow test must not dominate (Spearman 1904). The 95 % range uses Fisher's z with the Spearman variance
/// 1.06 / (n − 3) (Fieller, Hartley & Pearson 1957, Biometrika 44:470–481). "Tracks you" = the lower end of that range
/// is above 0 (ours, a plain stated rule). Enough = 10 checks on 5 different local days within the last 14 days (ours).
/// The published error of the model is for group averages (Ramakrishnan 2016: 6–27 %); for one person it is unproven,
/// which is what this check is for. Python reference: app/pclab/mglab/ref/behaviour.py `alertness_agreement`,
/// `spearman`; goldens app/shared/golden/behaviour/ALG-051-check.json.
public enum AlertnessCheck {
    public static let method = "ALG-051@2 self-check spearman fisher-z"
    public static let citation = "Spearman 1904; Fieller, Hartley & Pearson 1957 Biometrika 44:470-481; "
        + "Basner, Mollicone & Dinges 2011 Acta Astronaut 69:949-959 (the reaction test)"
    public static let minChecks = 10
    public static let minDays = 5
    public static let windowDays = 14
    public static let varianceK = 1.06

    public struct Check: Sendable, Equatable {
        public var at: Date
        /// ALG-051 alertness score 0–100 at the start of the test.
        public var predicted: Double
        public var meanRtMs: Double
        public var lapses: Int?

        public init(at: Date, predicted: Double, meanRtMs: Double, lapses: Int? = nil) {
            self.at = at
            self.predicted = predicted
            self.meanRtMs = meanRtMs
            self.lapses = lapses
        }
    }

    public struct Agreement: Sendable, Equatable {
        public var rho: Double
        public var low: Double
        public var high: Double
        public var n: Int
        public var days: Int
        /// The lower end of the 95 % range is above 0.
        public var tracks: Bool
    }

    /// The reaction tests that carry a prediction, newest last; events without one (taken before the field existed, or
    /// while the model had no value) and removed events are not checks.
    public static func checks(from events: [EventRecord]) -> [Check] {
        var out: [Check] = []
        for e in events where !e.removed {
            guard case .reactionTest(let f) = e.payload, let p = f.predictedAlertness, p.isFinite,
                  f.meanRtMs.isFinite, f.meanRtMs > 0 else { continue }
            out.append(Check(at: e.at, predicted: p, meanRtMs: f.meanRtMs, lapses: f.lapses))
        }
        return out.sorted { $0.at < $1.at }
    }

    /// The model's alertness at `at`: the curve sample nearest to it, if one lies within `maxGapSeconds` (the curve is
    /// sampled every few minutes); nil when the curve does not reach that time (no prediction is stored then).
    public static func prediction(curve: [(at: Date, value: Double)], at: Date, maxGapSeconds: TimeInterval = 20 * 60) -> Double? {
        let near = curve.filter { $0.value.isFinite }.min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) }
        guard let n = near, abs(n.at.timeIntervalSince(at)) <= maxGapSeconds else { return nil }
        return n.value
    }

    /// Average ranks (1-based; ties share the mean of the ranks they span).
    static func ranks(_ x: [Double]) -> [Double] {
        let order = x.indices.sorted { x[$0] < x[$1] }
        var ranks = [Double](repeating: 0, count: x.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && x[order[j + 1]] == x[order[i]] { j += 1 }
            let r = Double(i + j) / 2.0 + 1.0
            for k in i...j { ranks[order[k]] = r }
            i = j + 1
        }
        return ranks
    }

    /// Spearman rank correlation = Pearson on average ranks; missing when a side has no spread.
    public static func spearman(_ x: [Double], _ y: [Double]) -> Computed<Double> {
        guard x.count == y.count, x.count >= 3 else { return .missing("needs two equal lists of at least 3 values") }
        let rx = ranks(x)
        let ry = ranks(y)
        let mx = SignalMath.mean(rx)
        let my = SignalMath.mean(ry)
        var sxy = 0.0
        var sxx = 0.0
        var syy = 0.0
        for k in rx.indices {
            sxy += (rx[k] - mx) * (ry[k] - my)
            sxx += (rx[k] - mx) * (rx[k] - mx)
            syy += (ry[k] - my) * (ry[k] - my)
        }
        guard sxx > 0, syy > 0 else { return .missing("one side has no spread, so there is no correlation") }
        return .success(sxy / (sxx * syy).squareRoot())
    }

    /// The agreement of `predicted` with `meanRtMs`; `dayKeys` is one local-day number per check.
    public static func agreement(predicted: [Double], meanRtMs: [Double], dayKeys: [Int]) -> Computed<Agreement> {
        let n = predicted.count
        guard meanRtMs.count == n, dayKeys.count == n else {
            return .missing("needs one prediction, one reaction time and one day per check")
        }
        guard n >= minChecks else { return .missing("\(n) of \(minChecks) checks so far") }
        let days = Set(dayKeys).count
        guard days >= minDays else {
            return .missing("\(n) checks, but on \(days) of \(minDays) different days so far")
        }
        switch spearman(predicted, meanRtMs.map { -$0 }) {
        case .failure(let why):
            return .failure(why)
        case .success(let rho):
            let z = atanh(max(-0.999999, min(0.999999, rho)))
            let se = (varianceK / Double(n - 3)).squareRoot()
            let low = tanh(z - 1.96 * se)
            let high = tanh(z + 1.96 * se)
            return .success(Agreement(rho: rho, low: low, high: high, n: n, days: days, tracks: low > 0))
        }
    }

    /// The agreement over the last `windowDays` days ending at `now`, from stored reaction-test events.
    public static func agreement(events: [EventRecord], now: Date, timeZone: TimeZone) -> Computed<Agreement> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let from = now.addingTimeInterval(-Double(windowDays) * 86400)
        let used = checks(from: events).filter { $0.at >= from && $0.at <= now }
        let keys = used.map { c -> Int in
            let d = cal.dateComponents([.year, .month, .day], from: c.at)
            return (d.year ?? 0) * 10_000 + (d.month ?? 0) * 100 + (d.day ?? 0)
        }
        return agreement(predicted: used.map(\.predicted), meanRtMs: used.map(\.meanRtMs), dayKeys: keys)
    }

    /// How many usable checks exist in the window, and on how many different days (for "6 of 10 checks so far").
    public static func progress(events: [EventRecord], now: Date, timeZone: TimeZone) -> (checks: Int, days: Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let from = now.addingTimeInterval(-Double(windowDays) * 86400)
        let used = checks(from: events).filter { $0.at >= from && $0.at <= now }
        return (used.count, Set(used.map { cal.startOfDay(for: $0.at) }).count)
    }
}
