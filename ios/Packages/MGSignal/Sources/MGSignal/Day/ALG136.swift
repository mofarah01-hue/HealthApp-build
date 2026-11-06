import Foundation
import MGDomain

/// ALG-136 v2 — activity cost: what each activity does to your next-morning HRV (D-RECOV-WALK-2, Mo 2026-10-17: the old
/// "recovery points" cost was built on an inferred score). Python reference: app/pclab/mglab/ref/insights.py
/// `activity_cost`; goldens app/shared/golden/day/ALG-136.json.
///
/// Per activity: the ALG-102 regression of next-morning ln RMSSD on "did this activity the day before" (AR(1) term, 95 %
/// interval), gated at 10 sessions and 20 other nights. Rows with a number are ranked by size, intervals that exclude 0
/// first; the rest are named as learning. A day with HRV counts as logged, so an unlogged workout is an unexposed night
/// (said in the note). A description of your own history: hard sessions cluster with late nights and the rest, which
/// nothing here separates.
public enum ALG136 {
    public static let citation = "the ALG-102 regression per activity (ln RMSSD, AR(1), 95 % CI; Pietilä 2018 design); "
        + "replaces the reNOOP ActivityCostEngine cost on MS-18 points"
    public static let historyDays = 90

    public struct Row: Sendable, Equatable {
        public var sport: String
        public var pct: Double
        public var lo: Double
        public var hi: Double
        public var nExposed: Int
        public var nUnexposed: Int
        public var clear: Bool
    }

    public struct Learning: Sendable, Equatable {
        public var sport: String
        public var reason: String
    }

    public struct Cost: Sendable, Equatable {
        public var rows: [Row]
        public var learning: [Learning]
    }

    /// `sportDays` = activity → day numbers it was logged on; `lnByDay` = day number → ln RMSSD of the night ending that
    /// morning.
    public static func cost(sportDays: [String: [Int]], lnByDay: [Int: Double]) -> Computed<Cost> {
        guard !sportDays.isEmpty, !lnByDay.isEmpty else { return .missing("needs logged workouts and nightly HRV") }
        let known = Set(lnByDay.keys)
        var rows: [Row] = []
        var learning: [Learning] = []
        for sport in sportDays.keys.sorted() {
            let r = ALG102.behaviourEffect(rows: ALG102.rows(lnByDay: lnByDay, exposed: Set(sportDays[sport]!), known: known))
            switch r {
            case .failure(let m):
                learning.append(Learning(sport: sport, reason: m.reason))
            case .success(let e):
                rows.append(Row(sport: sport, pct: e.pct, lo: e.lo, hi: e.hi, nExposed: e.nExposed,
                                nUnexposed: e.nUnexposed, clear: e.clear))
            }
        }
        guard !rows.isEmpty else {
            return .missing("learning: no activity has \(ALG102.minExposed) sessions with a next morning and "
                            + "\(ALG102.minUnexposed) other nights yet")
        }
        rows.sort { a, b in
            if a.clear != b.clear { return a.clear }
            if abs(a.pct) != abs(b.pct) { return abs(a.pct) > abs(b.pct) }
            return a.sport < b.sport
        }
        return .success(Cost(rows: rows, learning: learning))
    }

    public static let spec = MetricSpec(
        key: .activityCost, unit: "%", group: nil, variant: "ALG-136", method: "ALG-136@2 ln-rmssd-regression-per-activity",
        tier: .estimate, source: "workout events, nightly ln RMSSD", window: "90d", citation: citation,
        paramsVersion: "ar1 ols t95 min10/20 nights per activity")

    /// One sentence per row, ranked, then the activities still learning.
    static func sentence(_ r: Row) -> String {
        ALG102.sentence(r.sport, .success(ALG102.Effect(pct: r.pct, lo: r.lo, hi: r.hi, beta: 0, se: 0, ar: 0, df: 0,
                                                       n: r.nExposed + r.nUnexposed, nExposed: r.nExposed,
                                                       nUnexposed: r.nUnexposed)))
    }

    public static func metric(_ c: Computed<Cost>, at: Date) -> Metric {
        spec.metric(c.map { $0.rows[0].pct }, at: at, note: c.value.map {
            ($0.rows.map(sentence) + $0.learning.map { "\($0.sport): \($0.reason)" }).joined(separator: " \u{00B7} ")
                + " \u{00B7} association only; a workout you did not log counts as a day without it"
        })
    }
}
