import Foundation
import MGDomain

/// ALG-036 part 2 (r9p, D-LOAD-WALK-2, Mo 2026-10-17): the plain week comparison, the load score of one session against
/// your own history, and session-RPE load. Python reference: app/pclab/mglab/ref/load.py (`week_vs_average`,
/// `session_load_score`, `srpe_load`); goldens app/shared/golden/day/ALG-036-load.json.
///
/// * Week: "this week vs your 4-week average" - the last 7 calendar days of plain Banister TRIMP against the mean week of
///   the last 28 days (this week included). A day with no strap data is skipped, never a 0 rest day. Two numbers and the
///   percent difference ONLY: no ratio, no band, no injury claim (the acute:chronic ratio does not stand up as an injury
///   predictor: Impellizzeri et al., Int J Sports Physiol Perform 2020;15(6):907-913). The 7 : 28 windows are the
///   convention of Gabbett, Br J Sports Med 2016;50(5):273-280.
/// * Load score (replaces Training Effect, dropped by Mo): where this session's TRIMP sits among your earlier sessions of
///   the same type - the mid-rank percentile (the ALG-138 rule) and the z of ln TRIMP. Within you only. Needs 5 sessions.
/// * sRPE: Foster et al., J Strength Cond Res 2001;15(1):109-115 - the CR-10 rating of the whole session x its minutes.
extension ALG036 {
    public static let weekDays = 7
    public static let weekBaseDays = 28
    public static let weekMinObserved = 4
    public static let weekBaseMinObserved = 14
    public static let scoreMinSessions = 5
    public static let rpeMax = 10.0

    public static let weekCitation = "Banister TRIMP (Morton, Fitz-Clarke & Banister 1990); 7:28 windows as Gabbett, Br J Sports Med 2016;50:273"
    public static let scoreCitation = "Banister TRIMP; mid-rank percentile within your own sessions (ALG-138 rule)"
    public static let srpeCitation = "Foster C et al. J Strength Cond Res 2001;15(1):109-115"

    /// This week's TRIMP (last 7 days).
    public static let weekSpec = MetricSpec(
        key: .loadWeek, unit: "au", group: "G-LOAD", variant: "ALG-036:week", method: "ALG-036@1 week-vs-4-week-average",
        tier: .estimate, source: "R18", window: "day", producer: .ours, citation: weekCitation, paramsVersion: "7d 28d min4 min14")
    /// The mean week of the last 28 days.
    public static let week4Spec = MetricSpec(
        key: .loadWeek, unit: "au", group: "G-LOAD", variant: "ALG-036:week4", method: "ALG-036@1 week-vs-4-week-average",
        tier: .estimate, source: "R18", window: "day", producer: .ours, citation: weekCitation, paramsVersion: "7d 28d min4 min14")
    /// This week's session-RPE load (sum over the sessions Mo rated in the last 7 days).
    public static let srpeWeekSpec = MetricSpec(
        key: .loadWeek, unit: "au", group: "G-LOAD", variant: "ALG-036:srpe_week", method: "ALG-036@1 session-rpe",
        tier: .estimate, source: "log", window: "day", producer: .ours, citation: srpeCitation, paramsVersion: "cr10 x min")
    /// One session's load score: the percentile of its TRIMP among your earlier sessions of the same type.
    public static let loadScoreSpec = MetricSpec(
        key: .loadSession, unit: "percentile", group: "G-LOAD", variant: "ALG-036:score",
        method: "ALG-036@1 session-load-percentile", tier: .estimate, source: "R18", window: "workout", producer: .ours,
        citation: scoreCitation, paramsVersion: "min5 midrank")
    /// One session's session-RPE load (rating x minutes).
    public static let srpeSpec = MetricSpec(
        key: .loadSession, unit: "au", group: "G-LOAD", variant: "ALG-036:srpe", method: "ALG-036@1 session-rpe",
        tier: .estimate, source: "log", window: "workout", producer: .ours, citation: srpeCitation, paramsVersion: "cr10 x min")

    public struct WeekLoad: Sendable, Equatable {
        public var thisWeek: Double
        public var avgWeek: Double
        /// (thisWeek / avgWeek - 1) x 100.
        public var pctChange: Double
        public var observedWeek: Int
        public var observed4wk: Int

        public init(thisWeek: Double, avgWeek: Double, pctChange: Double, observedWeek: Int, observed4wk: Int) {
            self.thisWeek = thisWeek
            self.avgWeek = avgWeek
            self.pctChange = pctChange
            self.observedWeek = observedWeek
            self.observed4wk = observed4wk
        }
    }

    /// ALG-036:week - `dailyTrimp` = one entry per CALENDAR day, oldest first, the last = today; nil = the strap gave no
    /// information that day. Uses the last 28 entries (all when fewer are given). Each side is scaled to a week from its
    /// observed days: mean(observed) x 7.
    public static func weekVsAverage(dailyTrimp: [Double?]) -> Computed<WeekLoad> {
        let base = Array(dailyTrimp.suffix(weekBaseDays))
        let week = Array(base.suffix(weekDays))
        let wk = week.compactMap { v -> Double? in
            guard let v, v.isFinite, v >= 0 else { return nil }
            return v
        }
        let bs = base.compactMap { v -> Double? in
            guard let v, v.isFinite, v >= 0 else { return nil }
            return v
        }
        if wk.count < weekMinObserved {
            return .missing("Learning your week: \(wk.count) of the last \(weekDays) days have data, needs \(weekMinObserved)")
        }
        if bs.count < weekBaseMinObserved {
            return .missing("Learning your 4-week average: \(bs.count) of \(weekBaseMinObserved) days so far")
        }
        let thisWeek = DayKit.mean(wk) * Double(weekDays)
        let avgWeek = DayKit.mean(bs) * Double(weekDays)
        if avgWeek <= 0 { return .missing("no training load in the last 4 weeks, so there is nothing to compare with") }
        return .success(WeekLoad(thisWeek: thisWeek, avgWeek: avgWeek, pctChange: (thisWeek / avgWeek - 1.0) * 100.0,
                                 observedWeek: wk.count, observed4wk: bs.count))
    }

    public struct SessionScore: Sendable, Equatable {
        /// 0...100 among your earlier sessions of this type.
        public var percentile: Double
        /// z of ln TRIMP; nil when your earlier sessions are all equal (no spread).
        public var z: Double?
        public var n: Int

        public init(percentile: Double, z: Double?, n: Int) {
            self.percentile = percentile
            self.z = z
            self.n = n
        }
    }

    /// ALG-036:score - `history` = the TRIMP of your EARLIER sessions of the same type (this session is not in it).
    public static func sessionLoadScore(trimp: Double?, history: [Double?]) -> Computed<SessionScore> {
        guard let trimp, trimp.isFinite, trimp > 0 else { return .missing("this session has no TRIMP") }
        let h = history.compactMap { v -> Double? in
            guard let v, v.isFinite, v > 0 else { return nil }
            return v
        }
        if h.count < scoreMinSessions {
            return .missing("Learning this kind of session: \(h.count) of \(scoreMinSessions) earlier ones so far")
        }
        let below = h.filter { $0 < trimp }.count
        let equal = h.filter { $0 == trimp }.count
        let pct = 100.0 * (Double(below) + 0.5 * Double(equal)) / Double(h.count)
        let ln = h.map { log($0) }
        let sd = DayKit.sampleSD(ln)
        let z: Double? = sd > 0 ? (log(trimp) - DayKit.mean(ln)) / sd : nil
        return .success(SessionScore(percentile: pct, z: z, n: h.count))
    }

    /// ALG-036:srpe - Foster 2001: session RPE (CR-10, 0 to 10) x session minutes. 0 is a real rating (rest).
    public static func srpeLoad(rpe: Double?, minutes: Double?) -> Computed<Double> {
        guard let rpe, rpe.isFinite, rpe >= 0, rpe <= rpeMax else { return .missing("the rating must be between 0 and 10") }
        guard let minutes, minutes.isFinite, minutes > 0 else { return .missing("the session has no length") }
        return .success(rpe * minutes)
    }
}
