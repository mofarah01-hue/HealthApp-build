import Foundation
import MGDomain

/// T101: what a drink holds, how it is stored, and the lines the Log caffeine row shows for the day.
/// Every figure is a published reference value or a can's label, never a measurement of Mo's cup.
public struct CaffeineDrink: Equatable, Sendable {
    public var name: String
    public var low: Double
    public var mid: Double
    public var high: Double
    /// Where the figure comes from (shown to Mo, who confirms label figures against the can).
    public var source: String
    /// A home-made drink is an estimate; a label figure is not.
    public var isEstimate: Bool
    /// Stays false until Mo has checked the label himself (T101: "I look each up and show the source").
    public var confirmedByMo: Bool

    public var mg: Double { mid }
}

public enum CaffeineDrinks {
    /// Mayo Clinic caffeine chart: espresso 63 mg per 1 fl oz; brewed 8 fl oz 96 mg. Mayo News Network gives the
    /// spread: espresso (restaurant) 47–75 mg per oz, brewed 95–200 mg per 8 oz. Estimates, not label figures.
    static let espressoShot = (low: 47.0, mid: 63.0, high: 75.0)
    static let brewedPerOunce = (low: 95.0 / 8, mid: 96.0 / 8, high: 200.0 / 8)
    static let mayo = "Mayo Clinic, Caffeine content for coffee, tea, soda and more (reference values, not your cup)"

    /// T9973: no branded can presets here any more. A can's label figure is an entry of the user's own Drinks list
    /// (seeded from his local file, `LocalPresetFile`); `label(...)` builds the same value from such an entry.
    public static func label(_ name: String, _ mg: Double, _ source: String) -> CaffeineDrink {
        CaffeineDrink(name: name, low: mg, mid: mg, high: mg, source: source, isEstimate: false, confirmedByMo: false)
    }

    /// "8 oz coffee made from a double espresso shot" = `homeMade(ounces: 8, espressoShots: 2)`: with shots the
    /// caffeine is the shots' (water adds none); with none it is brewed coffee by the ounce.
    public static func homeMade(ounces: Double, espressoShots: Int) -> CaffeineDrink {
        let oz = MGFormat.number(ounces, decimals: ounces == ounces.rounded() ? 0 : 1)
        if espressoShots > 0 {
            let n = Double(espressoShots)
            let shots = "\(espressoShots) espresso \(espressoShots == 1 ? "shot" : "shots")"
            return CaffeineDrink(name: "\(oz) oz coffee from \(shots)", low: n * espressoShot.low,
                                 mid: n * espressoShot.mid, high: n * espressoShot.high, source: mayo,
                                 isEstimate: true, confirmedByMo: false)
        }
        return CaffeineDrink(name: "\(oz) oz brewed coffee", low: ounces * brewedPerOunce.low,
                             mid: ounces * brewedPerOunce.mid, high: ounces * brewedPerOunce.high, source: mayo,
                             isEstimate: true, confirmedByMo: false)
    }

    /// The stored fields: `caffeineMg` is the override when Mo typed one, else the middle of the range.
    public static func fields(_ drink: CaffeineDrink, overrideMg: Double?, finishedAt: Date?) -> SubstanceFields {
        SubstanceFields(kind: .caffeine, product: drink.name, caffeineMg: overrideMg ?? drink.mid,
                        finishedAt: finishedAt, caffeineMgLow: drink.low, caffeineMgHigh: drink.high,
                        caffeineMgOverridden: overrideMg == nil ? nil : true)
    }

    // MARK: The day's lines

    static func lines(_ s: PresenterSnapshot) -> [String] {
        let start = s.calendar.startOfDay(for: s.now)
        let end = s.calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let drinks = s.events.filter { $0.at >= start && $0.at < end && !$0.removed }.sorted { $0.at < $1.at }
            .compactMap { e -> (EventRecord, SubstanceFields)? in
                guard case let .substance(f) = e.payload, f.kind == .caffeine else { return nil }
                return (e, f)
            }
        guard !drinks.isEmpty else { return [] }
        var out = drinks.map { e, f -> String in
            let when = f.finishedAt.map { s.range(e.at, $0) } ?? "\(s.hm(e.at)), stop time to add"
            return [when, f.product ?? "Caffeine", mgText(f)].joined(separator: " · ")
        }
        let total = drinks.reduce(0.0) { $0 + ($1.1.caffeineMg ?? 0) }
        out.append("Today: \(MGFormat.number(total, decimals: 0)) mg in \(drinks.count) \(drinks.count == 1 ? "drink" : "drinks")")
        return out
    }

    static func mgText(_ f: SubstanceFields) -> String {
        guard let mg = f.caffeineMg else { return "mg not set" }
        let text = "\(MGFormat.number(mg, decimals: 0)) mg"
        guard let low = f.caffeineMgLow, let high = f.caffeineMgHigh else { return text }
        let range = "\(MGFormat.number(low, decimals: 0))–\(MGFormat.number(high, decimals: 0))"
        if f.caffeineMgOverridden == true {
            return text + (low == high ? " (your number; label says \(MGFormat.number(low, decimals: 0)))" : " (your number; estimate was \(range))")
        }
        return low == high ? text : text + " (estimate, \(range))"
    }

    /// r9t (D-POP-PRIOR): the half-life the curve uses, 'population 5 h' until the PC has fitted one from his own nights and
    /// reaction tests, then 'yours 4.2 h (23 logs)' beside the population value.
    static func halfLifeLine(_ s: PresenterSnapshot) -> String {
        CaffeineHalfLife.from(s.metrics).line
    }

    /// The link to sleep is one person's pattern, never proof (T101).
    static func sleepLine(_ s: PresenterSnapshot) -> String {
        if let m = s.metric(.caffeineSleepSensitivity), let v = m.value, v.isFinite {
            return "Sleep link: \(MGFormat.number(v, decimals: 0)) min of sleep per 100 mg, from your own nights, a pattern, not proof."
        }
        return "Sleep link: needs more nights with caffeine and sleep logged; when it appears it is a pattern, not proof."
    }
}

/// Decay model dropdown for the Log caffeine row (same panel as Strain and Sleep). ALG-060 is the default:
/// a population-average half-life (5 h prior) with absorption; ALG-062 learns a personal half-life from Mo's nights.
public enum CaffeinePanelPresenter {
    public static let defaultAlgorithmID = "ALG-060"
    public static let groupID = "G-CAFF-DECAY"

    static let specs = [
        PanelOptionSpec("ALG-060", "Population half-life, gut + body",
                        metrics: [("caffeine_now", "ALG-060"), ("caffeine_bedtime", "ALG-060")]),
        PanelOptionSpec("ALG-062", "Your half-life and sleep link",
                        metrics: [("caffeine_half_life", "ALG-062"), ("caffeine_sleep_sensitivity", "ALG-062")]),
        PanelOptionSpec("ALG-061", "Cut-off for tonight", metrics: [("caffeine_cutoff", "ALG-061")]),
    ]

    public static func make(_ snapshot: PresenterSnapshot) -> AlgorithmPanelState {
        AlgorithmPanelBuilder.make(
            snapshot, title: "Caffeine decay",
            summary: "How the mg in you falls through the evening.",
            defaultID: defaultAlgorithmID, selectedID: snapshot.groupChoices[groupID]?.readVariant, specs: specs,
            note: "Half-life is a population average until your own nights say otherwise. mg for home-made drinks is an estimate.")
    }
}
