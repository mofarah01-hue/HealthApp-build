import Foundation
import MGDomain

/// ALG-060 v1 — caffeine in the body: two compartments (gut A_g, body A_b), first-order absorption and elimination,
/// the dose spread evenly between "start" and "finish" (an infusion), or one gulp when the drink took under a minute.
///
///     dA_g/dt = u(t) − k_a·A_g      dA_b/dt = k_a·A_g − k_e·A_b      k_e = ln 2 / t½
///
/// "Caffeine in you" (UX-SPEC §7, `caffeine_now`, `caffeine_bedtime`) is the mg still on board = A_g + A_b
/// (`State.totalMg`): everything taken and not yet eliminated. `bodyMg` alone is reported too.
/// Closed forms (superposition of the unit response k_a/(k_a−k_e)·(e^−k_e·τ − e^−k_a·τ)); the Python reference and
/// gen_behaviour.py check them against analytic Bateman curves and an independent RK4 integration of the ODEs.
/// Python reference: app/pclab/mglab/ref/behaviour.py `caffeine_state` / `caffeine_curve`;
/// goldens app/shared/golden/behaviour/ALG-060.json.
///
/// Constants — **flagged for Mo**: t½ prior 5 h (PLAN §4.3; Institute of Medicine 2001: 1.5–9.5 h). k_a 2.72 /h is the
/// absorption rate of a caffeinated beverage in Sadek et al. 2017 (J Caffeine Res, n = 16); PLAN does not give one. It
/// puts the PLAN §4.3 worked example at 68.8 mg at 01:00 instead of PLAN's "about 65 mg" (which assumes instant
/// absorption: 65.3 mg with k_a → ∞). A drink with no finish time is read as 40 min long (PLAN §4.3), fully drunk —
/// the cautious side for a cut-off.
public enum ALG060 {
    public static let method = "ALG-060@1 caffeine-two-compartment"
    public static let citation = "Institute of Medicine 2001 (Caffeine for the Sustainment of Mental Task Performance); "
        + "Sadek et al. 2017, J Caffeine Res (k_a); Bateman 1910"
    public static let paramsVersion = "t5h ka2.72 drink40min"

    /// PLAN §4.3 prior; IOM 2001 range 1.5–9.5 h.
    public static let defaultHalfLifeH = 5.0
    /// Sadek et al. 2017 (coffee beverage, n = 16). Ours as a prior for any drink.
    public static let defaultKaPerH = 2.72
    /// PLAN §4.3 "a drink sipped over 40 min"; used when a drink has no finish time yet.
    public static let defaultDrinkSeconds = 2400.0
    /// Start → finish under a minute is one gulp: an impulse into the gut at `start`.
    public static let bolusMaxSeconds = 60.0
    /// |k_a − k_e| below this makes the closed form divide by ~0: refused.
    static let minKaGap = 1e-6

    /// One drink. `finish == nil` = still drinking. `mg == nil` = logged without mg → the whole result is Missing (R6).
    public struct Dose: Sendable, Hashable {
        public var start: Date
        public var finish: Date?
        public var mg: Double?

        public init(start: Date, finish: Date? = nil, mg: Double?) {
            self.start = start
            self.finish = finish
            self.mg = mg
        }
    }

    public struct Params: Sendable, Hashable {
        public var halfLifeH: Double
        public var kaPerH: Double
        public var drinkSeconds: Double

        public init(halfLifeH: Double = ALG060.defaultHalfLifeH, kaPerH: Double = ALG060.defaultKaPerH,
                    drinkSeconds: Double = ALG060.defaultDrinkSeconds) {
            self.halfLifeH = halfLifeH
            self.kaPerH = kaPerH
            self.drinkSeconds = drinkSeconds
        }

        /// The population prior (t½ 5 h).
        public static let population = Params()
    }

    public struct State: Sendable, Equatable {
        public var gutMg: Double
        public var bodyMg: Double
        /// gut + body: the mg still on board.
        public var totalMg: Double

        public init(gutMg: Double, bodyMg: Double, totalMg: Double) {
            self.gutMg = gutMg
            self.bodyMg = bodyMg
            self.totalMg = totalMg
        }
    }

    public struct Sample: Sendable, Equatable {
        public var at: Date
        public var totalMg: Double

        public init(at: Date, totalMg: Double) {
            self.at = at
            self.totalMg = totalMg
        }
    }

    // MARK: kernel (unix seconds; shared with ALG-061 / ALG-126)

    struct Item: Sendable, Equatable {
        var start: Double
        var duration: Double
        var mg: Double
    }

    struct Rates: Sendable, Equatable {
        var ke: Double
        var ka: Double
    }

    static func rates(_ p: Params) -> Computed<Rates> {
        guard p.halfLifeH.isFinite, p.halfLifeH > 0 else {
            return .missing("half-life must be a positive number of hours")
        }
        guard p.kaPerH.isFinite, p.kaPerH > 0 else {
            return .missing("absorption rate must be a positive number per hour")
        }
        let ke = log(2.0) / p.halfLifeH
        if abs(p.kaPerH - ke) < minKaGap {
            return .missing("absorption rate equals the elimination rate: pick a different half-life or k_a")
        }
        return .success(Rates(ke: ke, ka: p.kaPerH))
    }

    static func items(_ doses: [Dose], drinkSeconds: Double) -> Computed<[Item]> {
        guard drinkSeconds.isFinite, drinkSeconds >= 0 else {
            return .missing("drink length must be zero or more seconds")
        }
        var out: [Item] = []
        out.reserveCapacity(doses.count)
        for (i, d) in doses.enumerated() {
            guard let mg = d.mg, mg.isFinite, mg >= 0 else {
                return .missing("dose \(i + 1): caffeine mg is missing or negative")
            }
            let s = BehaviourClock.seconds(d.start)
            let dur: Double
            if let f = d.finish {
                let fs = BehaviourClock.seconds(f)
                if fs < s { return .missing("dose \(i + 1): finish is before start") }
                dur = fs - s
            } else {
                dur = drinkSeconds
            }
            out.append(Item(start: s, duration: dur, mg: mg))
        }
        return .success(out)
    }

    /// (gut mg, body mg) at time `t` from ONE dose; zero before `start`.
    static func amounts(at t: Double, item: Item, rates r: Rates) -> (gut: Double, body: Double) {
        let ke = r.ke
        let ka = r.ka
        let mg = item.mg
        if mg == 0.0 || t < item.start { return (0.0, 0.0) }
        let a = (t - item.start) / BehaviourClock.hourSeconds
        if item.duration < bolusMaxSeconds {
            let gut = mg * exp(-ka * a)
            let body = mg * ka / (ka - ke) * (exp(-ke * a) - exp(-ka * a))
            return (gut, body)
        }
        let b = max(0.0, (t - (item.start + item.duration)) / BehaviourClock.hourSeconds)
        let u = mg / (item.duration / BehaviourClock.hourSeconds)
        let gut = u / ka * (exp(-ka * b) - exp(-ka * a))
        let body = u * ka / (ka - ke) * ((exp(-ke * b) - exp(-ke * a)) / ke - (exp(-ka * b) - exp(-ka * a)) / ka)
        return (gut, body)
    }

    static func total(at t: Double, items: [Item], rates: Rates) -> State {
        var gut = 0.0
        var body = 0.0
        for item in items {
            let a = amounts(at: t, item: item, rates: rates)
            gut += a.gut
            body += a.body
        }
        return State(gutMg: gut, bodyMg: body, totalMg: gut + body)
    }

    // MARK: public surface

    /// ALG-060 v1 — caffeine on board at `at`. Doses starting after `at` add nothing. Missing for a bad parameter or a
    /// dose without mg / with its finish before its start.
    public static func state(at: Date, doses: [Dose], params: Params = .population) -> Computed<State> {
        let rates: Rates
        switch Self.rates(params) {
        case .success(let r): rates = r
        case .failure(let m): return .failure(m)
        }
        let its: [Item]
        switch items(doses, drinkSeconds: params.drinkSeconds) {
        case .success(let v): its = v
        case .failure(let m): return .failure(m)
        }
        return .success(total(at: BehaviourClock.seconds(at), items: its, rates: rates))
    }

    /// ALG-060 v1 — mg on board sampled at `from`, `from + step`, … ≤ `to` (UX-SPEC §4.1: every 10 min).
    public static func curve(from: Date, to: Date, step: TimeInterval, doses: [Dose],
                             params: Params = .population) -> Computed<[Sample]> {
        let t0 = BehaviourClock.seconds(from)
        let t1 = BehaviourClock.seconds(to)
        guard step > 0, t1 >= t0 else { return .missing("curve needs step > 0 and end >= start") }
        let rates: Rates
        switch Self.rates(params) {
        case .success(let r): rates = r
        case .failure(let m): return .failure(m)
        }
        let its: [Item]
        switch items(doses, drinkSeconds: params.drinkSeconds) {
        case .success(let v): its = v
        case .failure(let m): return .failure(m)
        }
        let n = Int(((t1 - t0) / step + 1e-9).rounded(.down)) + 1
        var out: [Sample] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let t = t0 + Double(i) * step
            out.append(Sample(at: BehaviourClock.date(t), totalMg: total(at: t, items: its, rates: rates).totalMg))
        }
        return .success(out)
    }

    // MARK: metrics

    /// `caffeine_now`: mg on board at one instant (registry: ALG-060, window "instant").
    public static let nowSpec = MetricSpec(
        key: .caffeineNow, unit: "mg", group: nil, variant: "ALG-060", method: method, tier: .estimate,
        source: "caffeine log", window: "instant", citation: citation, paramsVersion: paramsVersion)

    /// `caffeine_bedtime`: mg on board at the usual bedtime (registry: group G-CAFF, window "night").
    public static let bedtimeSpec = MetricSpec(
        key: .caffeineBedtime, unit: "mg", group: "G-CAFF", variant: "ALG-060", method: method, tier: .estimate,
        source: "caffeine log", window: "night", citation: citation, paramsVersion: paramsVersion)
}
