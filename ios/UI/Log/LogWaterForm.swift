import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Water, opened in place (r9p, D-LOAD-WALK-2): millilitres drunk, a preset or typed, and when. Each entry is a substance event
/// of kind `drink` with `volume_ml`. The day's total is shown next to the EFSA reference (population value, total water);
/// the app never calls anyone dehydrated. Weights before and after a workout are logged on the workout itself.
struct LogWaterForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.calendar) private var calendar
    @State private var preset: Double?
    @State private var custom = ""
    @State private var product = ""
    @State private var when = LogHappenedAt()

    private static let presets: [Double] = [150, 250, 330, 500, 750, 1000]
    private static let maxMl = 5000.0

    private var options: [(id: Double, label: String)] {
        LogWaterForm.presets.map { (id: $0, label: "\(LogText.number($0)) ml") }
    }

    /// The typed number wins over a chip; nil while neither is a usable volume.
    private var millilitres: Double? {
        if let typed = LogText.parse(custom), typed > 0, typed <= LogWaterForm.maxMl { return typed }
        return custom.isEmpty ? preset : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("How much")
            LogChoiceChips(options: options, selection: $preset)
            HStack(spacing: 8) {
                LogTextField("Or type the amount", text: $custom, decimal: true)
                LogUnitLabel("ml")
            }
            LogTextField("What (water by default)", text: $product)
            LogHint("Counts toward the day's fluid. The reference is the EFSA adequate intake of total water (drinks and food).")
            LogHappenedAtControl(choice: $when)
            LogSaveBar(title: millilitres.map { "Log \(LogText.number($0)) ml" } ?? "Log drink",
                       enabled: ctx.canLog && millilitres != nil, reason: reason, action: save)
        }
    }

    private var reason: String? {
        if !ctx.canLog { return LogIntents.sampleReason }
        if !custom.isEmpty, millilitres == nil { return "Enter an amount between 1 and 5000 ml." }
        return millilitres == nil ? "Pick or type how much." : nil
    }

    private func save() {
        guard let ml = millilitres else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        let event = LogEvents.drink(ml: ml, product: LogText.clean(product), at: at, loggedAt: now)
        ctx.commit([event], message: "\(LogText.number(ml)) ml logged \(LogText.time(at, calendar))")
    }
}
