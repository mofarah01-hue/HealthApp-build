import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Alcohol, opened in place (UX §7, APP-311): a drink preset → standard drinks, how many, when.
/// 1 standard drink = 14 g alcohol (US; NIAAA: 12 oz beer, 5 oz wine, 1.5 oz spirits).
/// The contract (v0.4) has no units field on substanceEvent, so the amount is written into `product` and `note`
/// (flagged for contract v0.5 in the WP-18 report).
struct LogAlcoholForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.calendar) private var calendar
    @State private var presetID: String?
    @State private var count: Double = 1
    @State private var customName = ""
    @State private var customUnits = ""
    @State private var when = LogHappenedAt()

    private static let customID = "__custom__"

    private var options: [(id: String, label: String)] {
        ctx.catalogue.alcohol.map { (id: $0.id, label: "\($0.name) \($0.portion)") }
            + [(id: LogAlcoholForm.customID, label: "Custom units")]
    }

    /// product text + total standard drinks, or nil while incomplete.
    private var chosen: (product: String, drinks: Double)? {
        if presetID == LogAlcoholForm.customID {
            guard let units = LogText.parse(customUnits), units > 0 else { return nil }
            return (LogText.clean(customName) ?? "Alcohol", units)
        }
        guard let presetID, let item = ctx.catalogue.alcohol.first(where: { $0.id == presetID }) else { return nil }
        return ("\(item.name) \(item.portion)", item.standardDrinks * count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("What you drank")
            LogChoiceChips(options: options, selection: $presetID, clearable: false)
            if presetID == LogAlcoholForm.customID {
                LogTextField("Name (optional)", text: $customName)
                HStack(spacing: 8) {
                    LogTextField("Standard drinks", text: $customUnits, decimal: true)
                    LogUnitLabel("units")
                }
            } else if presetID != nil {
                LogStepperRow(title: "How many", valueText: LogText.number(count), value: $count,
                              range: 0.5...12, step: 0.5)
            }
            LogHint("1 standard drink = 14 g of alcohol (US).")
            LogHappenedAtControl(choice: $when)
            LogSaveBar(title: saveTitle, enabled: ctx.canLog && chosen != nil, reason: reason, action: save)
        }
    }

    private var saveTitle: String {
        guard let chosen else { return "Log drink" }
        return "Log \(LogText.number(chosen.drinks)) standard \(chosen.drinks == 1 ? "drink" : "drinks")"
    }

    private var reason: String? {
        if !ctx.canLog { return LogIntents.sampleReason }
        if chosen == nil { return presetID == LogAlcoholForm.customID ? "Enter the standard drinks." : "Pick a drink." }
        return nil
    }

    private func save() {
        guard let chosen else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        let event = LogEvents.alcohol(product: chosen.product, standardDrinks: chosen.drinks, at: at, loggedAt: now)
        ctx.commit([event], message: "\(chosen.product) logged \(LogText.time(at, calendar))")
    }
}
