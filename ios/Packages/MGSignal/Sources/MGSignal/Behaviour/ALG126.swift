import Foundation
import MGDomain

/// ALG-126 v1 — caffeine cut-off variants, the other two members of the G-CAFF comparison group (every method is
/// shown side by side; Mo marks keep / drop later, drop hides, never deletes):
///   * `ALG-126:33mg`   deterministic back-solve: your half-life (prior median 5 h until ALG-062 has data) and a fixed
///                      33 mg limit at bedtime (PLAN §4.3, derived from Gardiner 2023);
///   * `ALG-126:drake6h` a fixed rule: no caffeine in the 6 h before bed, whatever the dose (Drake et al. 2013,
///                      J Clin Sleep Med 9:1195 — 400 mg taken 6 h before bed still cost more than an hour of sleep;
///                      one study at one dose, 12 people).
/// plus ALG-061 (probabilistic) first, as ranked in ALGORITHM-COMPARISON. Python reference:
/// app/pclab/mglab/ref/behaviour.py `drake_cutoff` / `cutoff_group`; goldens app/shared/golden/behaviour/ALG-126.json.
public enum ALG126 {
    public static let method33mg = "ALG-126@1 deterministic-33mg"
    public static let methodDrake = "ALG-126@1 drake-6h"
    public static let citation = "Drake et al. 2013, J Clin Sleep Med 9:1195; Gardiner et al. 2023, Sleep Med Rev 69:101764"
    public static let drakeHours = 6.0

    public static let variantProbabilistic = "ALG-061"
    public static let variant33mg = "ALG-126:33mg"
    public static let variantDrake = "ALG-126:drake6h"

    /// ALG-126 v1, `ALG-126:drake6h` — cut-off = bedtime − 6 h. Missing when bedtime is not after `now`.
    public static func drake(now: Date, bedtime: Date) -> Computed<ALG061.Cutoff> {
        let nowS = BehaviourClock.seconds(now)
        let bed = BehaviourClock.seconds(bedtime)
        guard bed > nowS else { return .missing("bedtime has already passed: no cut-off to compute") }
        let c = bed - drakeHours * BehaviourClock.hourSeconds
        return .success(ALG061.Cutoff(outcome: .at, cutoff: BehaviourClock.date(c),
                                      cutoffMinute: BehaviourClock.date(BehaviourClock.floorMinute(c)),
                                      passed: c < nowS))
    }

    /// ALG-126 v1, `ALG-126:33mg` — the deterministic back-solve: `params.halfLifeH` as given, limit fixed at 33 mg.
    public static func cutoff33mg(doses: [ALG060.Dose], now: Date, bedtime: Date, nextMg: Double?,
                                  params: ALG060.Params = .population) -> Computed<ALG061.Cutoff> {
        ALG061.cutoff(doses: doses, now: now, bedtime: bedtime, nextMg: nextMg, params: params,
                      limitMg: ALG061.defaultLimitMg)
    }

    /// One member of the G-CAFF group: its variant id, a plain label, and its cut-off or why it is blank (R6).
    public struct Member: Sendable, Equatable {
        public var variant: String
        public var label: String
        public var result: Computed<ALG061.Cutoff>

        public init(variant: String, label: String, result: Computed<ALG061.Cutoff>) {
            self.variant = variant
            self.label = label
            self.result = result
        }
    }

    public struct Group: Sendable, Equatable {
        /// Always three members, in this order: ALG-061, ALG-126:33mg, ALG-126:drake6h.
        public var members: [Member]

        public init(members: [Member]) {
            self.members = members
        }
    }

    /// ALG-126 v1 / G-CAFF — every cut-off method, side by side. `params.halfLifeH` is your half-life (ALG-126:33mg);
    /// `halfLifeP90H` the 90th-percentile half-life for the probabilistic member (the population prior's, until a
    /// personal posterior exists); `learnedLimitMg` its limit (33 mg until learned).
    public static func group(doses: [ALG060.Dose], now: Date, bedtime: Date, nextMg: Double?,
                             params: ALG060.Params = .population, learnedLimitMg: Double = ALG061.defaultLimitMg,
                             halfLifeP90H: Double = ALG061.halfLifeP90H) -> Group {
        let p90 = ALG060.Params(halfLifeH: halfLifeP90H, kaPerH: params.kaPerH, drinkSeconds: params.drinkSeconds)
        return Group(members: [
            Member(variant: variantProbabilistic, label: "Probabilistic (90th-percentile half-life)",
                   result: ALG061.cutoff(doses: doses, now: now, bedtime: bedtime, nextMg: nextMg, params: p90,
                                         limitMg: learnedLimitMg)),
            Member(variant: variant33mg, label: "33 mg at bedtime (your half-life)",
                   result: cutoff33mg(doses: doses, now: now, bedtime: bedtime, nextMg: nextMg, params: params)),
            Member(variant: variantDrake, label: "6 hours before bed (Drake 2013)",
                   result: drake(now: now, bedtime: bedtime)),
        ])
    }

    /// `caffeine_cutoff` / ALG-126:33mg.
    public static let spec33mg = MetricSpec(
        key: .caffeineCutoff, unit: "unix_s", group: "G-CAFF", variant: variant33mg, method: method33mg, tier: .estimate,
        source: "caffeine log", window: "day", citation: citation, paramsVersion: "limit33mg drink40min")

    /// `caffeine_cutoff` / ALG-126:drake6h.
    public static let specDrake = MetricSpec(
        key: .caffeineCutoff, unit: "unix_s", group: "G-CAFF", variant: variantDrake, method: methodDrake, tier: .estimate,
        source: "bedtime", window: "day", citation: citation, paramsVersion: "6h")
}
