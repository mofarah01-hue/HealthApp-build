import Foundation
import MGDomain

/// ALG-135 v2 — hydration (G-HYDRATION), r9p, D-LOAD-WALK-2 (Mo 2026-10-17). Python reference:
/// app/pclab/mglab/ref/insights.py `hydration_goal`, `hydration_status`, `sweat_loss`, `sweat_rate`; goldens
/// app/shared/golden/day/ALG-135.json.
///
/// v1 was the whoop-rs goal (3700 / 2700 ml plus a strain bump, no published basis). v2 is three plain readouts and no
/// judgement: the EFSA reference (adequate intake of TOTAL water, drinks and food, 2.5 L men / 2.0 L women: EFSA Journal
/// 2010;8(3):1459), the drinks Mo logged next to it, and the sweat loss of a session from his weights before and after
/// (change in body mass + fluid drunk, 1 kg ~ 1 L: ACSM position stand, Sawka et al., Med Sci Sports Exerc 2007;39(2):377-390).
/// Never a "dehydrated" claim and nothing inferred from heart rate, HRV or temperature (D-RECOV-WALK-2).
/// D-POP-PRIOR: the sweat rate starts at the population value and moves to Mo's own as sessions are logged.
public enum ALG135 {
    public static let citation = "EFSA Journal 2010;8(3):1459 (water DRV); Sawka et al., Med Sci Sports Exerc 2007;39(2):377-390"
    /// EFSA adequate intake of total water, ml per day.
    public static let efsaMen = 2500.0
    public static let efsaWomen = 2000.0
    /// One logged drink above this is a typo and is not counted (ours).
    public static let drinkMaxMl = 5000.0
    public static let weightRange: ClosedRange<Double> = 30.0...250.0
    public static let maxMassLossKg = 6.0
    public static let mlPerKg = 1000.0
    /// D-POP-PRIOR: the population sweat rate (ours: the midpoint of the typical 0.5-2.0 L/h range of the ACSM 2007 stand) and
    /// the weight of that value in sessions (ours: three of Mo's own sessions weigh as much as the population value).
    public static let sweatRatePriorLPerH = 1.0
    public static let sweatPriorK = 3.0
    public static let sweatMinMinutes = 10.0

    public struct Goal: Sendable, Equatable {
        public var goalMl: Double

        public init(goalMl: Double) {
            self.goalMl = goalMl
        }
    }

    /// The EFSA adequate intake of total water. Men and women only; no sex set is a blank, never a blended number.
    public static func goal(sex: Profile.Sex?) -> Computed<Goal> {
        switch sex {
        case .some(.male): return .success(Goal(goalMl: efsaMen))
        case .some(.female): return .success(Goal(goalMl: efsaWomen))
        case .some(.other): return .missing("the EFSA reference is published for men and women only")
        case .none: return .missing("the EFSA reference is published for men and women: set sex in the profile")
        }
    }

    public struct Status: Sendable, Equatable {
        public var intakeMl: Double
        public var referenceMl: Double
        /// intake / reference; 1.0 = the reference.
        public var share: Double
        public var drinks: Int
        public var ignored: Int

        public init(intakeMl: Double, referenceMl: Double, share: Double, drinks: Int, ignored: Int) {
            self.intakeMl = intakeMl
            self.referenceMl = referenceMl
            self.share = share
            self.drinks = drinks
            self.ignored = ignored
        }
    }

    /// The day's logged drinks (ml each) next to the reference. Drinks that are not a number in (0, 5000] are not counted.
    public static func status(drinksMl: [Double?], sex: Profile.Sex?) -> Computed<Status> {
        goal(sex: sex).map { g in
            let good = drinksMl.compactMap { v -> Double? in
                guard let v, v.isFinite, v > 0, v <= drinkMaxMl else { return nil }
                return v
            }
            let intake = good.reduce(0, +)
            return Status(intakeMl: intake, referenceMl: g.goalMl, share: intake / g.goalMl, drinks: good.count,
                          ignored: drinksMl.count - good.count)
        }
    }

    public struct Sweat: Sendable, Equatable {
        public var sweatMl: Double
        public var massLossKg: Double
        /// The weight change as a percent of the starting weight (shown, never judged against a threshold).
        public var massLossPct: Double
        public var drinkMl: Double

        public init(sweatMl: Double, massLossKg: Double, massLossPct: Double, drinkMl: Double) {
            self.sweatMl = sweatMl
            self.massLossKg = massLossKg
            self.massLossPct = massLossPct
            self.drinkMl = drinkMl
        }
    }

    /// Sweat loss of one session = (weight before - weight after) + fluid drunk during it, 1 kg ~ 1 L.
    public static func sweatLoss(preKg: Double?, postKg: Double?, drinkMl: Double? = nil) -> Computed<Sweat> {
        guard let preKg, let postKg, preKg.isFinite, postKg.isFinite else {
            return .missing("needs the weight before and after the session")
        }
        guard weightRange.contains(preKg), weightRange.contains(postKg) else {
            return .missing("a weight outside 30 to 250 kg: check the weights")
        }
        let drink = (drinkMl.map { $0.isFinite && $0 > 0 ? $0 : 0.0 }) ?? 0.0
        let mass = preKg - postKg
        if mass > maxMassLossKg { return .missing("more than 6 kg lost in one session: check the weights") }
        let sweat = mass * mlPerKg + drink
        if sweat < 0 { return .missing("the weight rose by more than the fluid logged: check the weights") }
        return .success(Sweat(sweatMl: sweat, massLossKg: mass, massLossPct: mass / preKg * 100.0, drinkMl: drink))
    }

    public struct SweatRate: Sendable, Equatable {
        /// What the app uses and shows: the population value moved toward yours.
        public var rateLPerH: Double
        public var populationLPerH: Double
        /// Your own mean; nil with no session yet (the value is then the population one alone).
        public var ownLPerH: Double?
        public var n: Int
        /// n / (n + k): the share of the shown value that is yours.
        public var weightOwn: Double

        public init(rateLPerH: Double, populationLPerH: Double, ownLPerH: Double?, n: Int, weightOwn: Double) {
            self.rateLPerH = rateLPerH
            self.populationLPerH = populationLPerH
            self.ownLPerH = ownLPerH
            self.n = n
            self.weightOwn = weightOwn
        }
    }

    /// D-POP-PRIOR: rate = (n x your mean + k x population) / (n + k), k = 3. `sessions` = (sweat ml, minutes) per session.
    public static func sweatRate(sessions: [(sweatMl: Double, minutes: Double)]) -> SweatRate {
        let rates = sessions.compactMap { s -> Double? in
            guard s.sweatMl.isFinite, s.minutes.isFinite, s.sweatMl >= 0, s.minutes >= sweatMinMinutes else { return nil }
            return s.sweatMl / 1000.0 / (s.minutes / 60.0)
        }
        let n = Double(rates.count)
        let own: Double? = rates.isEmpty ? nil : rates.reduce(0, +) / n
        let shown = (n * (own ?? 0.0) + sweatPriorK * sweatRatePriorLPerH) / (n + sweatPriorK)
        return SweatRate(rateLPerH: shown, populationLPerH: sweatRatePriorLPerH, ownLPerH: own, n: rates.count,
                         weightOwn: n / (n + sweatPriorK))
    }

    // MARK: Metric specs (key hydration_goal: variants ALG-135 = the reference, :intake = logged drinks, :sweat = per workout)

    public static let spec = MetricSpec(
        key: .hydrationGoal, unit: "ml", group: "G-HYDRATION", variant: "ALG-135", method: "ALG-135@2 efsa-total-water",
        tier: .estimate, source: "profile", window: "day", citation: citation, paramsVersion: "efsa2010 men2500 women2000")
    public static let intakeSpec = MetricSpec(
        key: .hydrationGoal, unit: "ml", group: "G-HYDRATION", variant: "ALG-135:intake", method: "ALG-135@2 logged-drinks",
        tier: .high, source: "log", window: "day", citation: citation, paramsVersion: "drink<=5000ml")
    public static let sweatSpec = MetricSpec(
        key: .hydrationGoal, unit: "ml", group: "G-HYDRATION", variant: "ALG-135:sweat", method: "ALG-135@2 weight-change-sweat-loss",
        tier: .estimate, source: "log", window: "workout", citation: citation, paramsVersion: "1kg=1L max6kg 30-250kg")

    /// Your sweat rate in ml per hour (D-POP-PRIOR): the population value until you log sessions, then moved toward yours.
    public static let sweatRateSpec = MetricSpec(
        key: .hydrationGoal, unit: "ml_h", group: "G-HYDRATION", variant: "ALG-135:sweat_rate",
        method: "ALG-135@2 sweat-rate-shrunk-to-population", tier: .estimate, source: "log", window: "day",
        citation: citation, paramsVersion: "prior1000ml_h k3")

    public static func sweatRateMetric(_ r: SweatRate, at: Date) -> Metric {
        let basis = r.n == 0
            ? "population value (no session with both weights logged yet)"
            : "yours (\(r.n) session day\(r.n == 1 ? "" : "s")) blended with the population value, "
                + "\(Int((r.weightOwn * 100).rounded())) % yours"
        return sweatRateSpec.metric(.success(r.rateLPerH * 1000.0), at: at, note: basis)
    }

    public static func metric(_ g: Computed<Goal>, at: Date) -> Metric {
        spec.metric(g.map(\.goalMl), at: at,
                    note: "EFSA adequate intake of total water (drinks and food; about 20 % of it comes from food)")
    }

    public static func intakeMetric(_ s: Computed<Status>, at: Date) -> Metric {
        intakeSpec.metric(s.map(\.intakeMl), at: at,
                          note: s.value.map {
            "\($0.drinks) logged drink\($0.drinks == 1 ? "" : "s")" + ($0.ignored > 0 ? "; \($0.ignored) not counted" : "")
        })
    }

    public static func sweatMetric(_ s: Computed<Sweat>, at: Date) -> Metric {
        sweatSpec.metric(s.map(\.sweatMl), at: at, note: s.value.map {
            String(format: "weight change %.1f kg (%.1f %% of body weight) + %d ml drunk; estimate", $0.massLossKg, $0.massLossPct,
                   Int($0.drinkMl.rounded()))
        })
    }
}
