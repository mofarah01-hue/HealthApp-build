import Foundation
import MGDomain

/// ALG-061 v1 — "No more caffeine after HH:MM": the latest time a drink of `nextMg` (sipped over `drinkSeconds`,
/// default 40 min) can END so that the mg on board at bedtime stays within a limit. This is the first member of the
/// G-CAFF comparison group (the others are ALG-126:33mg and ALG-126:drake6h; `ALG126.group` returns all three).
///
/// Probabilistic variant (ALGORITHM-REQUIREMENTS ALG-061, ARCHITECTURE §8.1): the half-life used is the 90th percentile
/// of the population prior — so P(bedtime mg > limit) < 10 % — and the limit is "your learned limit" (33 mg until
/// ALG-062 has data: PLAN §4.3, derived from Gardiner 2023 as ≈ 32–35 mg left at bedtime with t½ 5 h).
/// The prior is OURS and flagged: lognormal with median 5 h whose 97.5th percentile is 9.5 h (the upper end of the IOM
/// 2001 range 1.5–9.5 h): σ = ln(9.5/5)/1.96 = 0.3275, 90th percentile = 7.607 h.
///
/// The mg on board at bedtime is monotone in the drink's end time, so the cut-off is found by 100-step bisection over
/// the 240 h before bed; the returned time satisfies the limit. Python reference: app/pclab/mglab/ref/behaviour.py
/// `caffeine_cutoff` / `caffeine_allowance`; goldens app/shared/golden/behaviour/ALG-061.json.
public enum ALG061 {
    public static let method = "ALG-061@1 p90-half-life-bisection"
    public static let citation = "Gardiner et al. 2023, Sleep Med Rev 69:101764 (33 mg derived in PLAN §4.3); "
        + "Drake et al. 2013, J Clin Sleep Med 9:1195; IOM 2001"
    public static let paramsVersion = "p90 t7.61h limit33mg drink40min"

    /// PLAN §4.3 deterministic back-solve limit, also the starting value of the learned limit.
    public static let defaultLimitMg = 33.0
    public static let priorMedianH = 5.0
    /// IOM 2001 upper end of 1.5–9.5 h, read as the prior's 97.5th percentile (ours).
    public static let priorUpperH = 9.5
    static let z975 = 1.959963984540054   // standard normal quantiles, constants: no inverse-normal needed on the phone
    static let z90 = 1.2815515655446004
    public static let priorSigma = log(priorUpperH / priorMedianH) / z975
    /// 90th percentile of the half-life prior, hours (7.607).
    public static let halfLifeP90H = priorMedianH * exp(z90 * priorSigma)
    /// The search never needs a drink earlier than this before bed.
    static let lookbackSeconds = 240.0 * 3600.0
    static let bisectIterations = 100

    public enum Outcome: String, Sendable, Equatable {
        /// `cutoff` is the last end time that fits.
        case at = "at"
        /// Even a drink ending at bedtime fits; `cutoff` = bedtime.
        case noLimitBeforeBed = "no_limit_before_bed"
        /// The doses already logged put bedtime over the limit: no further drink fits (`cutoff` is nil).
        case alreadyOver = "already_over"
    }

    /// A cut-off. `passed` = the cut-off is before `now` (so "no more caffeine" applies already).
    public struct Cutoff: Sendable, Equatable {
        public var outcome: Outcome
        public var cutoff: Date?
        /// `cutoff` floored to the whole minute — show this one, so the limit still holds.
        public var cutoffMinute: Date?
        public var passed: Bool
        /// mg already on board at bedtime from the logged doses (nil for the fixed Drake rule).
        public var bedtimeMgExisting: Double?
        public var halfLifeH: Double?
        public var limitMg: Double?
        public var nextMg: Double?

        public init(outcome: Outcome, cutoff: Date?, cutoffMinute: Date?, passed: Bool, bedtimeMgExisting: Double? = nil,
                    halfLifeH: Double? = nil, limitMg: Double? = nil, nextMg: Double? = nil) {
            self.outcome = outcome
            self.cutoff = cutoff
            self.cutoffMinute = cutoffMinute
            self.passed = passed
            self.bedtimeMgExisting = bedtimeMgExisting
            self.halfLifeH = halfLifeH
            self.limitMg = limitMg
            self.nextMg = nextMg
        }
    }

    /// mg you could still finish drinking NOW without the bedtime mg passing the limit (floored at 0).
    public struct Allowance: Sendable, Equatable {
        public var allowanceMg: Double
        public var bedtimeMgExisting: Double
        public var limitMg: Double

        public init(allowanceMg: Double, bedtimeMgExisting: Double, limitMg: Double) {
            self.allowanceMg = allowanceMg
            self.bedtimeMgExisting = bedtimeMgExisting
            self.limitMg = limitMg
        }
    }

    /// ALG-061 v1 — cut-off for a drink of `nextMg`. `params.halfLifeH` is the half-life used (pass `halfLifeP90H` for the
    /// probabilistic ALG-061 member, your own t½ for ALG-126:33mg); `limitMg` the bedtime limit.
    /// Missing: bedtime not after `now`, no drink size, a bad limit or parameter, or a bad dose.
    public static func cutoff(doses: [ALG060.Dose], now: Date, bedtime: Date, nextMg: Double?,
                              params: ALG060.Params, limitMg: Double = ALG061.defaultLimitMg) -> Computed<Cutoff> {
        let nowS = BehaviourClock.seconds(now)
        let bed = BehaviourClock.seconds(bedtime)
        guard bed > nowS else { return .missing("bedtime has already passed: no cut-off to compute") }
        guard let next = nextMg, next.isFinite, next > 0 else {
            return .missing("no drink size: pick your usual drink to get a cut-off")
        }
        guard limitMg.isFinite, limitMg > 0 else { return .missing("limit must be a positive number of mg") }
        let rates: ALG060.Rates
        switch ALG060.rates(params) {
        case .success(let r): rates = r
        case .failure(let m): return .failure(m)
        }
        let its: [ALG060.Item]
        switch ALG060.items(doses, drinkSeconds: params.drinkSeconds) {
        case .success(let v): its = v
        case .failure(let m): return .failure(m)
        }
        let existing = ALG060.total(at: bed, items: its, rates: rates).totalMg

        func make(_ outcome: Outcome, _ cutoffS: Double?, _ passed: Bool) -> Cutoff {
            Cutoff(outcome: outcome, cutoff: cutoffS.map { BehaviourClock.date($0) },
                   cutoffMinute: cutoffS.map { BehaviourClock.date(BehaviourClock.floorMinute($0)) }, passed: passed,
                   bedtimeMgExisting: existing, halfLifeH: params.halfLifeH, limitMg: limitMg, nextMg: next)
        }

        if existing > limitMg { return .success(make(.alreadyOver, nil, true)) }

        // mg at bedtime if the next drink ends at `end` (sipped over drinkSeconds).
        func atBed(_ end: Double) -> Double {
            let start = end - params.drinkSeconds
            let item = ALG060.Item(start: start, duration: end - start, mg: next)
            return existing + ALG060.total(at: bed, items: [item], rates: rates).totalMg
        }

        if atBed(bed) <= limitMg { return .success(make(.noLimitBeforeBed, bed, false)) }
        var lo = bed - lookbackSeconds
        var hi = bed
        if atBed(lo) > limitMg { return .success(make(.alreadyOver, nil, true)) }
        for _ in 0..<bisectIterations {
            let mid = 0.5 * (lo + hi)
            if atBed(mid) <= limitMg { lo = mid } else { hi = mid }
        }
        return .success(make(.at, lo, lo < nowS))
    }

    /// ALG-061 v1 (helper) — mg you could still finish drinking now. Bedtime mg is linear in the drink size, so
    /// allowance = (limit − existing) / (bedtime mg of 1 mg ending now), floored at 0.
    public static func allowance(doses: [ALG060.Dose], now: Date, bedtime: Date, params: ALG060.Params,
                                 limitMg: Double = ALG061.defaultLimitMg) -> Computed<Allowance> {
        let nowS = BehaviourClock.seconds(now)
        let bed = BehaviourClock.seconds(bedtime)
        guard bed > nowS else { return .missing("bedtime has already passed: no allowance to compute") }
        let rates: ALG060.Rates
        switch ALG060.rates(params) {
        case .success(let r): rates = r
        case .failure(let m): return .failure(m)
        }
        let its: [ALG060.Item]
        switch ALG060.items(doses, drinkSeconds: params.drinkSeconds) {
        case .success(let v): its = v
        case .failure(let m): return .failure(m)
        }
        let existing = ALG060.total(at: bed, items: its, rates: rates).totalMg
        let start = nowS - params.drinkSeconds
        let unitItem = ALG060.Item(start: start, duration: nowS - start, mg: 1.0)
        let unit = ALG060.total(at: bed, items: [unitItem], rates: rates).totalMg
        let left = limitMg - existing
        return .success(Allowance(allowanceMg: max(0.0, left / unit), bedtimeMgExisting: existing, limitMg: limitMg))
    }

    /// `caffeine_cutoff` / ALG-061 (registry variant "ALG-061", group G-CAFF, unit unix_s).
    public static let cutoffSpec = MetricSpec(
        key: .caffeineCutoff, unit: "unix_s", group: "G-CAFF", variant: "ALG-061", method: method, tier: .estimate,
        source: "caffeine log", window: "day", citation: citation, paramsVersion: paramsVersion)
}
