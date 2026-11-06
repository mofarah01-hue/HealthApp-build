import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Caffeine, opened in place (UX §7, APP-070): presets (your Drinks list, then Coffee 95 · Espresso 63 · Tea 47 ·
/// Custom), Start with "happened at", Finish when a drink is open. The curve to bedtime with the 33 mg line, "bedtime
/// {31} mg" and the collapsed cut-off group come in `row.expansion` (chart, caption, lines, methods) and are drawn above.
struct LogCaffeineForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @State private var presetName: String?
    @State private var customName = ""
    @State private var customMg = ""
    @State private var builtOunces: Double = 8
    @State private var builtShots: Double = 2
    @State private var overrideMg = ""
    @State private var alreadyFinished = false
    @State private var sippedMinutes: Double = 15
    @State private var when = LogHappenedAt()

    private static let customID = "__custom__"
    private static let builtID = "__built__"

    /// T101: the drink Mo builds (8 oz coffee from a double espresso); an estimate with a range.
    private var built: CaffeineDrink { CaffeineDrinks.homeMade(ounces: builtOunces, espressoShots: Int(builtShots)) }

    /// A drink is open when the row's button is Finish.
    private var isSipping: Bool { ctx.row.primaryButton?.intent == .quickLog(.drinkFinish) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isSipping {
                finishBlock
            } else {
                startBlock
            }
        }
    }

    // MARK: Finish

    private var finishBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogFormLabel("Drink in progress")
            LogHint("Tap Finish when the last sip is done. The drink is logged from the Start time to now.")
            LogSaveBar(title: "Finish now", enabled: ctx.canLog, reason: ctx.canLog ? nil : LogIntents.sampleReason) {
                guard ctx.canLog else { return }
                let now = Date()
                ctx.send(.quickLog(.drinkFinish))
                ctx.saved("Drink finished \(LogText.time(now, calendar))", [.undoLastLog])
                ctx.send(.toggleRow(id: ctx.row.id))
            }
        }
    }

    // MARK: Start

    private var drinkOptions: [(id: String, label: String)] {
        ctx.catalogue.drinks.map { (id: $0.name, label: $0.chipLabel) } + [(id: LogCaffeineForm.builtID, label: "Build a drink"), (id: LogCaffeineForm.customID, label: "Custom")]
    }

    private var chosen: (name: String, mg: Double)? {
        if presetName == LogCaffeineForm.customID {
            guard let name = LogText.clean(customName), let mg = LogText.parse(customMg), mg > 0 else { return nil }
            return (name, mg)
        }
        if presetName == LogCaffeineForm.builtID {
            return (built.name, LogText.parse(overrideMg).flatMap { $0 > 0 ? $0 : nil } ?? built.mid)
        }
        guard let presetName, let drink = ctx.catalogue.drinks.first(where: { $0.name == presetName }) else { return nil }
        return (drink.name, drink.caffeineMg)
    }

    private var startBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("What are you drinking")
            LogFromYourList(items: ctx.catalogue.presetLists.drinks.filter { $0.hasCaffeine }, label: { $0.title }) {
                presetName = $0.name
            }
            LogChoiceChips(options: drinkOptions, selection: $presetName, clearable: false)
            if presetName == LogCaffeineForm.builtID {
                LogStepperRow(title: "Size", valueText: "\(Int(builtOunces)) oz", value: $builtOunces, range: 2...24, step: 1)
                LogStepperRow(title: "Espresso shots", valueText: "\(Int(builtShots))", value: $builtShots, range: 0...4, step: 1)
                LogHint("About \(LogText.number(built.mid)) mg (estimate, \(LogText.number(built.low))–\(LogText.number(built.high))). A shot varies by beans and machine; type your own below to replace it.")
                HStack(spacing: 8) {
                    LogTextField("Your number (optional)", text: $overrideMg, decimal: true)
                    LogUnitLabel("mg")
                }
            }
            if presetName == LogCaffeineForm.customID {
                LogTextField("Name (Cold brew…)", text: $customName)
                HStack(spacing: 8) {
                    LogTextField("Caffeine", text: $customMg, decimal: true)
                    LogUnitLabel("mg")
                }
            }
            LogHappenedAtControl(choice: $when, title: "Started · minutes ago")
            Toggle("Already finished", isOn: $alreadyFinished)
                .mgFont(.detail)
                .foregroundStyle(colors.ink.color)
                .tint(colors.focus.color)
                .frame(minHeight: MGSpace.tapTarget)
            if alreadyFinished {
                LogStepperRow(title: "Sipped over", valueText: "\(Int(sippedMinutes)) min", value: $sippedMinutes,
                              range: 5...120, step: 5)
            }
            LogSaveBar(title: startTitle, enabled: ctx.canLog && chosen != nil, reason: reason, action: save)
        }
    }

    private var startTitle: String {
        guard let chosen else { return alreadyFinished ? "Log drink" : "Start drink" }
        return (alreadyFinished ? "Log " : "Start ") + "\(chosen.name) \(LogText.number(chosen.mg)) mg"
    }

    private var reason: String? {
        if !ctx.canLog { return LogIntents.sampleReason }
        if chosen == nil {
            return presetName == LogCaffeineForm.customID ? "Enter a name and the caffeine in mg." : "Pick a drink."
        }
        return nil
    }

    private func save() {
        guard let chosen else { return }
        let now = Date()
        let start = when.resolved(now: now, calendar: calendar)
        let finish: Date? = alreadyFinished ? min(now, start.addingTimeInterval(sippedMinutes * 60)) : nil
        let event: EventRecord
        if presetName == LogCaffeineForm.builtID {
            let override = LogText.parse(overrideMg).flatMap { $0 > 0 ? $0 : nil }
            event = LogEvents.caffeine(fields: CaffeineDrinks.fields(built, overrideMg: override, finishedAt: finish),
                                       at: start, loggedAt: now)
        } else if presetName != LogCaffeineForm.customID,
                  let listed = ctx.catalogue.presetLists.drinks.first(where: { $0.name == chosen.name }),
                  let fields = PresetLists.caffeineFields(listed, finishedAt: finish) {
            // A drink from Mo's list keeps its range and source in the event (PresetLists.caffeineFields).
            event = LogEvents.caffeine(fields: fields, at: start, loggedAt: now)
        } else {
            event = LogEvents.caffeine(product: chosen.name, mg: chosen.mg, at: start, finishedAt: finish, loggedAt: now)
        }
        let verb = alreadyFinished ? "logged" : "started"
        ctx.commit([event], message: "\(chosen.name) \(LogText.number(chosen.mg)) mg \(verb) \(LogText.time(start, calendar))")
    }
}
