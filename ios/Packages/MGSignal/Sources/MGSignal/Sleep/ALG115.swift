import Foundation
import MGDomain

/// ALG-115 v2 — sleep need, debt and the recommended bedtime / wake (Tonight sheet, UX-SPEC 8.1; phase anchor B, UX 2).
/// v2 (2026-10-17, D-SLEEP-WALK-1 items 4/5, builder r9c) replaces v1's constants fitted to Mo's WHOOP export (0.64 carry,
/// 127 min cap, 78 min strain bonus, 7–9.5 h and 6–11 h clamps) with published methods on the strap's own sleep totals:
///  - need = mean TST on free nights (no "must be up by" that morning) over the last 28 nights = the MCTQ free-day sleep
///    duration SDf (Roenneberg, Wirz-Justice & Merrow 2003, J Biol Rhythms 18:80; Roenneberg et al. 2004, Curr Biol
///    14:R1038); Kitamura et al. 2016, Sci Rep 6:35812: sleep with an unrestricted opportunity estimates the individual's
///    optimal sleep duration (habitual home sleep sits below it).
///  - debt = cumulative net deficit against that need over the last 14 nights, floored at 0 (Van Dongen, Maislin,
///    Mullington & Dinges 2003, Sleep 26:117: cumulative restriction, 14-day protocol; Kitamura 2016).
///  - 'learning' until 7 free nights (need) / 7 of the last 14 nights (debt): the standard error of a mean of n nights
///    with a night-to-night SD of about 1 h is 1 h / √n = 23 min at 7, and a 2 h lie-in among 3 nights moves it 40 min.
/// No population 8 h default (BRIEF). Python: `mglab.ref.sleep` baseline_need … plan_tonight.
public enum ALG115 {
    static let needMinFreeNights = 7                  // learning threshold (see above)
    static let debtWindow = 14                        // Van Dongen 2003: 14-day protocol
    static let debtMinNights = 7                      // half the window
    static let planMinNights = 3                      // ours v1: efficiency / latency / typical wake medians need 3 nights
    static let effClamp = (0.75, 0.99)                // OpenStrap _inBedMin
    public static let citation = "Roenneberg et al. 2003 J Biol Rhythms 18:80 and 2004 Curr Biol 14:R1038 (MCTQ free-day sleep); "
        + "Kitamura et al. 2016 Sci Rep 6:35812; Van Dongen et al. 2003 Sleep 26:117; OpenStrap coaching.dart (bedtime plan)"

    public enum NeedSource: String, Sendable {
        case setting = "setting"
        case personal = "personal"
    }

    public struct BaselineNeed: Sendable, Equatable {
        public var minutes: Double
        public var source: NeedSource
        /// How many free nights the mean was taken over (personal only).
        public var freeNights: Int?

        public init(minutes: Double, source: NeedSource, freeNights: Int?) {
            self.minutes = minutes
            self.source = source
            self.freeNights = freeNights
        }
    }

    public struct Debt: Sendable, Equatable {
        public var debtMin: Double
        public var nights: Int

        public init(debtMin: Double, nights: Int) {
            self.debtMin = debtMin
            self.nights = nights
        }
    }

    /// Tonight's need and the parts the Tonight sheet shows (baseline − nap credit).
    public struct NeedTonight: Sendable, Equatable {
        public var needMin: Double
        public var baselineMin: Double
        /// ≤ 0 (a credit).
        public var napCreditMin: Double

        public init(needMin: Double, baselineMin: Double, napCreditMin: Double) {
            self.needMin = needMin
            self.baselineMin = baselineMin
            self.napCreditMin = napCreditMin
        }
    }

    public enum WakeAnchor: String, Sendable {
        case mustBeUpBy = "must_be_up_by"
        case typicalWake = "typical_wake"
    }

    public struct Plan: Sendable, Equatable {
        public var bedtime: Double
        public var inBedMin: Double
        public var efficiencyUsed: Double
        public var wakeAnchor: Double
        public var anchor: WakeAnchor
        /// "asleep ≈ 22:44" = bedtime + median latency.
        public var asleepAround: Computed<Double>
        public var windowStart: Computed<Double>
        public var windowEnd: Computed<Double>
        public var recommendedWake: Computed<Double>
        public var needMetBeforeWindow: Computed<Bool>

        public init(bedtime: Double, inBedMin: Double, efficiencyUsed: Double, wakeAnchor: Double, anchor: WakeAnchor,
                    asleepAround: Computed<Double>, windowStart: Computed<Double>, windowEnd: Computed<Double>,
                    recommendedWake: Computed<Double>, needMetBeforeWindow: Computed<Bool>) {
            self.bedtime = bedtime
            self.inBedMin = inBedMin
            self.efficiencyUsed = efficiencyUsed
            self.wakeAnchor = wakeAnchor
            self.anchor = anchor
            self.asleepAround = asleepAround
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.recommendedWake = recommendedWake
            self.needMetBeforeWindow = needMetBeforeWindow
        }
    }

    /// A value Mo sets wins; else the mean TST on free nights (no "must be up by" that morning), ≥ 7 of them. No clamp.
    public static func baselineNeed(freeTstMin: [Double], settingMin: Double? = nil) -> Computed<BaselineNeed> {
        if let s = settingMin { return .success(BaselineNeed(minutes: s, source: .setting, freeNights: nil)) }
        guard freeTstMin.count >= needMinFreeNights else {
            return .missing("Learning your sleep need: \(freeTstMin.count) of \(needMinFreeNights) free nights so far "
                            + "(nights with no 'must be up by')")
        }
        return .success(BaselineNeed(minutes: freeTstMin.reduce(0, +) / Double(freeTstMin.count), source: .personal,
                                     freeNights: freeTstMin.count))
    }

    /// Debt = max(0, Σ (need − slept)) over the last 14 nights with sleep (nil / ≤ 0 skipped, never zero-filled), ≥ 7 such
    /// nights. slept = main TST + that day's nap sleep. Surplus nights pay back deficit (net balance); no carry factor and
    /// no cap (both were fitted to WHOOP's numbers). Python `sleep.sleep_debt`.
    public static func debt(sleptMin: [Double?], needMin: Double) -> Computed<Debt> {
        let usable = Array(sleptMin.compactMap { v -> Double? in
            guard let v, v > 0 else { return nil }
            return v
        }.suffix(debtWindow))
        guard usable.count >= debtMinNights else {
            return .missing("Learning your sleep debt: \(usable.count) of \(debtMinNights) nights with sleep so far "
                            + "(of the last \(debtWindow))")
        }
        let net = usable.reduce(0.0) { $0 + (needMin - $1) }
        return .success(Debt(debtMin: Swift.max(0.0, net), nights: usable.count))
    }

    /// Tonight's need = the baseline less today's nap sleep (naps count toward the 24 h the debt is kept in), floored at 0.
    /// No strain bonus and no debt repayment folded in: the debt is its own metric. Python `sleep.need_tonight`.
    public static func needTonight(baseMin: Double, napMin: Double = 0) -> NeedTonight {
        let need = Swift.max(0.0, baseMin - napMin)
        return NeedTonight(needMin: need, baselineMin: baseMin, napCreditMin: need - baseMin)
    }

    /// Wake anchor without a "must be up by": the median local wake time of day of recent nights (≥ 3), at its next
    /// occurrence after `after`.
    public static func typicalWakeAnchor(recentWakes: [Double], utcOffsetSeconds: Int,
                                         after: Double) -> Computed<Double> {
        guard recentWakes.count >= planMinNights else {
            return .missing("needs \(planMinNights) nights with a detected wake (have \(recentWakes.count))")
        }
        let off = Int64(utcOffsetSeconds)
        let tods = recentWakes.map { Double(SleepMath.floorMod(Int64($0.rounded(.down)) + off, 86_400)) }
        let tod = SignalMath.median(tods)
        let a = Int64(after.rounded(.down))
        let day0 = SleepMath.floorDiv(a + off, 86_400) * 86_400 - off
        var t = Double(day0) + tod
        while t <= after { t += 86_400 }
        return .success(t)
    }

    /// T9710 (2026-10-14): a bedtime more than this far round the clock from the usual onset is not tonight's (same
    /// rule as MGContext `PhaseClock.sleepWindowHalfWidth`).
    public static let sleepWindowHalfWidthS: Double = 6 * 3600

    /// True when `bedtimeLocalSeconds` is within 6 h (circular) of the usual onset. Inputs are already local seconds of
    /// day so callers can apply the offset at each instant (important across DST and time-zone changes). With fewer
    /// than 3 onsets either the 23:00 default or the recorded onsets' median passes (a new day sleeper's 09:00 bedtime
    /// is not judged against 23:00 alone); an explicit upcoming wake schedule also authorizes the transition night.
    /// Mo's Today said "Bed by 11:36 AM" because the T5 wake anchor (next occurrence of the last wake's time of day)
    /// sat in the late evening; nothing checked the result.
    public static func inSleepWindow(bedtimeLocalSeconds: Double, recentOnsetLocalSeconds: [Double],
                                     hasExplicitWakeSchedule: Bool = false) -> Bool {
        if hasExplicitWakeSchedule { return true }
        func within(_ usual: Double) -> Bool {
            var d = abs(bedtimeLocalSeconds - usual).truncatingRemainder(dividingBy: 86_400)
            d = Swift.min(d, 86_400 - d)
            return d <= sleepWindowHalfWidthS
        }
        let fallback = 23.0 * 3600
        if recentOnsetLocalSeconds.isEmpty { return within(fallback) }
        let fromNoon = recentOnsetLocalSeconds.map { ($0 + 43_200).truncatingRemainder(dividingBy: 86_400) }
        let median = (SignalMath.median(fromNoon) + 43_200).truncatingRemainder(dividingBy: 86_400)
        return recentOnsetLocalSeconds.count >= planMinNights ? within(median) : (within(median) || within(fallback))
    }

    /// in bed = need ÷ median efficiency (≥ 3 nights, clamped 0.75–0.99); bedtime = anchor − in bed; asleep around =
    /// bedtime + median latency (≥ 3); with a "must be up by" L: window [L − window, L] and recommended wake = asleep
    /// around + need clamped into it; without L: no window (no wake plan, BRIEF default 3), recommended wake = asleep
    /// around + need.
    public static func planTonight(needMin: Double, wakeAnchor: Double, anchorIsMustBeUp: Bool, efficiencies: [Double],
                                   latenciesMin: [Double], windowMin: Double = 30) -> Computed<Plan> {
        guard efficiencies.count >= planMinNights else {
            return .missing("needs \(planMinNights) nights with a sleep efficiency (have \(efficiencies.count))")
        }
        let eff = Swift.min(effClamp.1, Swift.max(effClamp.0, SignalMath.median(efficiencies)))
        let inBed = needMin / eff
        let bed = wakeAnchor - inBed * 60.0
        let ws = wakeAnchor - windowMin * 60.0
        let noWindow = "no 'must be up by' for tomorrow: no wake window"
        var plan = Plan(bedtime: bed, inBedMin: inBed, efficiencyUsed: eff, wakeAnchor: wakeAnchor,
                        anchor: anchorIsMustBeUp ? .mustBeUpBy : .typicalWake,
                        asleepAround: .missing(""), windowStart: anchorIsMustBeUp ? .success(ws) : .missing(noWindow),
                        windowEnd: anchorIsMustBeUp ? .success(wakeAnchor) : .missing(noWindow),
                        recommendedWake: .missing(""), needMetBeforeWindow: .missing(""))
        guard latenciesMin.count >= planMinNights else {
            let reason = "needs \(planMinNights) nights with a sleep latency (have \(latenciesMin.count))"
            plan.asleepAround = .missing(reason)
            plan.recommendedWake = .missing(reason)
            plan.needMetBeforeWindow = .missing(reason)
            return .success(plan)
        }
        let asleep = bed + SignalMath.median(latenciesMin) * 60.0
        let target = asleep + needMin * 60.0
        plan.asleepAround = .success(asleep)
        if anchorIsMustBeUp {
            plan.recommendedWake = .success(Swift.min(wakeAnchor, Swift.max(ws, target)))
            plan.needMetBeforeWindow = .success(target < ws)
        } else {
            plan.recommendedWake = .success(target)
            plan.needMetBeforeWindow = .missing("no wake window")
        }
        return .success(plan)
    }

    // MARK: metrics

    public static let needSpec = MetricSpec(
        key: .sleepNeed, unit: "min", group: nil, variant: "ALG-115", method: "ALG-115@2 free-night-mean-less-nap",
        tier: .estimate, source: "derived", window: "night", citation: citation,
        paramsVersion: "mean-free28 n7")
    public static let debtSpec = MetricSpec(
        key: .sleepDebt, unit: "min", group: nil, variant: "ALG-115", method: "ALG-115@2 net-deficit-14n",
        tier: .estimate, source: "derived", window: "night", citation: citation, paramsVersion: "n14 min7")
    public static let bedtimeSpec = MetricSpec(
        key: .bedtimeRecommended, unit: "unix_s", group: nil, variant: "ALG-115",
        method: "ALG-115@2 anchor-minus-need-over-efficiency", tier: .estimate, source: "derived", window: "night",
        citation: citation, paramsVersion: "eff-median3 clamp0.75-0.99")

    /// sleep_need, sleep_debt, bedtime_recommended for tonight (`at` = when computed).
    public static func metrics(need: Computed<NeedTonight>, debt: Computed<Debt>, plan: Computed<Plan>,
                               at: Date) -> [Metric] {
        [
            needSpec.metric(need.map(\.needMin), at: at),
            debtSpec.metric(debt.map(\.debtMin), at: at),
            bedtimeSpec.metric(plan.map(\.bedtime), at: at),
        ]
    }
}
