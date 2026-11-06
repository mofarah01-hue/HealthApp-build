import Foundation
import MGDomain

/// T104: the Sundial's rings, outside to inside, each behind its own Settings switch (`DialLayer.rings`; strain, recovery,
/// sleep and stress start on). Burn = OUR day's calories against `settings.calorieGoalKcal`: ALG-048 active (Keytel, from the
/// strap's heart rate) plus Mifflin basal for the part of the day gone (T9985, 2026-10-15). It used to read `calories_total`,
/// which only WHOOP's export writes (history up to Oct 11), so the ring could only show WHOOP's cloud number. WHOOP's
/// total and Apple's active energy appear only as labelled comparisons in the ring's detail line;
/// eaten = today's food entries that carry calories, against the burn; stress and strain = the day totals the Today
/// strip shows, strain with today's target range; recovery = readiness inputs in range of those scored; sleep = last
/// night's total against the need.
enum DialRingsPresenter {
    static func make(_ s: PresenterSnapshot) -> [DialRing] {
        let on = s.settings.frontPage.shows
        let burned = ownBurn(s).kcal
        var rings: [DialRing] = []
        if on(.ringStrain) { rings.append(strain(s)) }
        if on(.ringRecovery) { rings.append(recovery(s)) }
        if on(.ringSleep) { rings.append(sleep(s)) }
        if on(.ringStress) {
            let m = s.dayStress()
            rings.append(DialRing(kind: .stress, title: "Arousal", value: s.display(m), fraction: scale(m, [
                "score_0_3": 3, "score_0_100": 100])))
        }
        if on(.ringBurn) { rings.append(burn(s, burned: burned)) }
        if on(.ringEaten) { rings.append(eaten(s, burn: burned)) }
        return rings
    }

    private static func strain(_ s: PresenterSnapshot) -> DialRing {
        let m = s.dayStrain()
        let g = WorkoutGuidance.make(s)
        let target = g.targetLow.flatMap { lo in g.targetHigh.map { lo / 21...$0 / 21 } }
        return DialRing(kind: .strain, title: "Strain", value: s.display(m), fraction: scale(m, ["score_0_21": 21]),
                        target: target)
    }

    /// ALG-160 readiness 1-100 (r9h), not a WHOOP percentage. Learning or too little: no fill, the reading's own reason.
    private static func recovery(_ s: PresenterSnapshot) -> DialRing {
        guard let r = s.recovery, r.status == .ok, let score = r.score else {
            let reason = VerdictRules.recovery(s.recovery).sentence ?? "No recovery reading yet."
            return DialRing(kind: .recovery, title: "Recovery", value: .blank(reason: reason, receipt: nil), fraction: nil)
        }
        return DialRing(kind: .recovery, title: "Recovery",
                        value: s.worded("\(score)", unit: "/100", receipt: s.phoneReceipt(at: r.at, method: "ALG-160")),
                        fraction: clamp(Double(score) / 100.0),
                        detail: [VerdictRules.hrvWord(r), VerdictRules.shortBaselineLabel(r)].compactMap { $0 }
                            .joined(separator: " · "))
    }

    /// Last night's sleep against the need; the need is an estimate (ALG-115) unless Settings overrides it. T10011: the
    /// minutes are the night's `sleepFill` (blank "Not processed yet" until the strap-flag night is in). §0.B-3: with no
    /// need row yet the ring still fills, against the Settings need or a labelled default (`defaultNeedMinutes`), and the default is
    /// used only while ALG-115 is still learning the need (7 free nights).
    private static func sleep(_ s: PresenterSnapshot) -> DialRing {
        let f = s.sleepFill()
        guard let slept = f.minutes, slept.isFinite else {
            return DialRing(kind: .sleep, title: "Sleep", value: f.display, fraction: nil,
                            detail: f.fill == .notProcessed ? "not processed yet" : nil)
        }
        let given = TonightPresenter.needMinutes(s).flatMap { $0 > 0 ? $0 : nil }
        let need = given ?? TonightPresenter.defaultNeedMinutes
        let needWords = given != nil ? "of \(MetricText.minutes(need)) need, est." : "of \(MetricText.minutes(need)) default need (learning yours)"
        // §0.B-4: the source is named when it is not the ordinary phone figure (the strap flag's count, or the PC's night
        // replacing the phone's), so the ring never jumps from one to the other without saying so.
        let named = f.fill == .phone || f.sourceLine.isEmpty ? nil : f.sourceLine
        return DialRing(kind: .sleep, title: "Sleep", value: f.display, fraction: clamp(slept / need),
                        detail: [needWords, named, PresenterSnapshot.alsoLine(f.also)].compactMap { $0 }.joined(separator: " · "))
    }

    static let activeVariants = ["ALG-048:keytel", "ALG-048:keytel_vo2"]
    static let burnNeeds = "Burned needs strap heart rate and your weight, height, age and sex (Preferences › Profile)."

    /// Our calories for the day so far: the chosen ALG-048 active member (Keytel, or with VO₂max when Mo picked it) plus
    /// Mifflin basal for the share of the local day gone (all of it for a day that is over). Nil + the reason when either part
    /// is blank. Never reads `calories_total`.
    static func ownBurn(_ s: PresenterSnapshot) -> (kcal: Double?, reason: String?, at: Date?) {
        let chosen = s.groupChoices["G-CAL"]?.readVariant
        let variant = chosen.flatMap { activeVariants.contains($0) ? $0 : nil } ?? activeVariants[0]
        let active = s.metric(.caloriesActive, variant: variant, window: "day")
        let basal = restingBasal(s)
        guard let a = active?.value, a.isFinite else { return (nil, active?.note ?? burnNeeds, nil) }
        guard let b = basal?.value, b.isFinite else { return (nil, basal?.note ?? burnNeeds, nil) }
        return (a + b * elapsedShare(s), nil, active?.at)
    }

    /// D-LOAD-WALK-2: resting energy for the whole day: Cunningham from the body-composition scan when the day has one (flagged
    /// 'from scan'), else Mifflin-St Jeor.
    static func restingBasal(_ s: PresenterSnapshot) -> Metric? {
        let scan = s.metric(.caloriesBasal, variant: "ALG-048:cunningham", window: "day")
        if let v = scan?.value, v.isFinite { return scan }
        return s.metric(.caloriesBasal, variant: "ALG-048:mifflin", window: "day")
    }

    /// How much of the snapshot's day has gone: the part since local midnight for today, 1 for any other day.
    private static func elapsedShare(_ s: PresenterSnapshot) -> Double {
        guard s.day == LocalDay(date: s.now, calendar: s.calendar),
              let span = s.calendar.dateInterval(of: .day, for: s.now), span.duration > 0 else { return 1 }
        return Swift.min(1, Swift.max(0, s.now.timeIntervalSince(span.start) / span.duration))
    }

    private static func burn(_ s: PresenterSnapshot, burned: Double?) -> DialRing {
        let goal = s.settings.calorieGoalKcal.flatMap { $0 > 0 ? $0 : nil }
        let fraction = burned.flatMap { v in goal.map { clamp(v / $0) } }
        var parts = [goal.map { "of \(MGFormat.grouped(Int($0.rounded()))) kcal goal" } ?? "no goal set"]
        // Comparisons, named for what they are; neither one is the ring's value.
        if let w = s.metric(.caloriesTotal, variant: ImportedHistory.whoopExport)?.value, w.isFinite {
            parts.append("WHOOP cloud \(MGFormat.grouped(Int(w.rounded()))) kcal (comparison)")
        }
        if let a = s.metric(.caloriesActive, variant: "apple", window: "day")?.value, a.isFinite {
            parts.append("Apple Health active \(MGFormat.grouped(Int(a.rounded()))) kcal (comparison)")
        }
        let own = ownBurn(s)
        let value: DisplayValue
        if let total = own.kcal {
            value = s.worded(MGFormat.grouped(Int(total.rounded())), unit: "kcal",
                             receipt: s.phoneReceipt(.estimate, at: own.at, method: "ALG-048 + Mifflin"))
        } else {
            value = .blank(reason: own.reason ?? burnNeeds, receipt: nil)
        }
        return DialRing(kind: .burn, title: "Burned", value: value, fraction: fraction,
                        detail: parts.joined(separator: " · "))
    }

    private static func eaten(_ s: PresenterSnapshot, burn: Double?) -> DialRing {
        let foods: [FoodFields] = s.eventsOf(.food).filter { s.calendar.isDate($0.at, inSameDayAs: s.now) }
            .compactMap { if case let .food(f) = $0.payload { return f } else { return nil } }
        let kcal = foods.compactMap(\.kcal)
        func grams(_ label: String, _ pick: (FoodFields) -> Double?) -> String? {
            let sum = foods.compactMap(pick).reduce(0, +)
            return sum > 0 ? "\(label) \(MGFormat.number(sum, decimals: 0)) g" : nil
        }
        let macros = [grams("protein", \.proteinG), grams("carbs", \.carbG), grams("fat", \.fatG)].compactMap { $0 }
        guard !kcal.isEmpty else {
            return DialRing(kind: .eaten, title: "Eaten",
                            value: .blank(reason: "No food with calories logged today.", receipt: nil), fraction: nil)
        }
        let total = kcal.reduce(0, +)
        return DialRing(kind: .eaten, title: "Eaten",
                        value: s.worded(MGFormat.grouped(Int(total.rounded())), unit: "kcal", receipt: s.phoneReceipt()),
                        fraction: burn.flatMap { $0 > 0 ? clamp(total / $0) : nil },
                        detail: macros.isEmpty ? nil : macros.joined(separator: " · "))
    }

    /// Value over the maximum its unit has; nil for a unit with no fixed maximum (TRIMP "au") or no value.
    private static func scale(_ m: Metric?, _ max: [String: Double]) -> Double? {
        guard let m, let v = m.value, v.isFinite, let top = max[m.unit] else { return nil }
        return clamp(v / top)
    }

    private static func clamp(_ x: Double) -> Double { Swift.min(Swift.max(x, 0), 1) }
}
