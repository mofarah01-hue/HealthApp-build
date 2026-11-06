import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// MedA 20 mg (and any scheduled medication), opened in place (UX §7, APP-075/076):
/// Took it now · Earlier (time) · Skipped, with / without food, dose editable. The label pharmacokinetics line comes
/// from the presenter (`row.expansion.lines`) and is context only, never a level; no dosing advice (ALG-143).
struct LogMedicationForm: View {
    let ctx: LogFormContext

    enum Mode: String {
        case now, earlier, skipped
    }

    private let preset: LogMedication?

    init(ctx: LogFormContext) {
        self.ctx = ctx
        let p = ctx.catalogue.medication(matching: ctx.row.title)
        self.preset = p
        _units = State(initialValue: p?.units ?? 1)
        _strengthText = State(initialValue: p?.strength.map { LogText.number($0) } ?? "")
    }
    @Environment(\.calendar) private var calendar
    @State private var mode: Mode? = .now
    @State private var withFood: Bool?
    @State private var units: Double
    @State private var strengthText: String
    @State private var when = LogHappenedAt()
    @State private var pillName = ""
    @State private var pillMg = ""
    /// From "From your list": replaces the row's preset name / strength / unit for this log.
    @State private var pickedID: String?
    @State private var pickedName: String?
    @State private var pickedUnit: String?

    private var unitName: String {
        let kind = preset?.unitKind ?? .capsule
        return kind == .capsule ? "capsule" : kind.rawValue
    }

    private var strengthUnit: String { pickedUnit ?? preset?.strengthUnit ?? "mg" }
    private var strength: Double? { LogText.parse(strengthText) }

    private var doseLine: String {
        guard let strength else { return "Dose not set" }
        return "\(LogText.number(units * strength)) \(strengthUnit) in total"
    }

    var body: some View {
        if ctx.row.title == "Pills" {
            pillForm
        } else {
            medicationForm
        }
    }

    private var pillForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("Pill")
            LogFromYourList(items: ctx.catalogue.presetLists.medications + ctx.catalogue.presetLists.supplements,
                            label: { $0.title }) { entry in
                pillName = entry.name
                pillMg = entry.amount.map { LogText.number($0) } ?? ""
            }
            LogTextField("Name", text: $pillName)
            HStack(spacing: 8) {
                LogTextField("Amount (optional)", text: $pillMg, decimal: true)
                LogUnitLabel("mg")
            }
            LogHappenedAtControl(choice: $when, title: "Taken · minutes ago")
            LogHint("This only tracks and reminds. Any prescription cut-down target is yours and your prescriber's.")
            LogSaveBar(title: "Log pill", enabled: ctx.canLog && LogText.clean(pillName) != nil,
                       reason: pillReason, action: savePill)
        }
    }

    private var pillReason: String? {
        if !ctx.canLog { return LogIntents.sampleReason }
        if LogText.clean(pillName) == nil { return "Enter the pill name." }
        return nil
    }

    private func savePill() {
        guard let name = LogText.clean(pillName) else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        let mg = LogText.parse(pillMg).flatMap { $0 > 0 ? $0 : nil }
        ctx.commit([LogEvents.pill(name: name, mg: mg, at: at, loggedAt: now)],
                   message: "\(name) logged \(LogText.time(at, calendar))")
    }

    private var medicationForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("What happened")
            LogFromYourList(items: ctx.catalogue.presetLists.medications, label: { $0.title }) { entry in
                pickedID = entry.id
                pickedName = entry.name
                pickedUnit = entry.unit
                strengthText = entry.amount.map { LogText.number($0) } ?? ""
            }
            if let pickedName { LogHint("Logging \(pickedName) from your list.") }
            LogChoiceChips(options: [(id: Mode.now, label: "Took it now"), (id: Mode.earlier, label: "Earlier…"),
                                     (id: Mode.skipped, label: "Skipped")],
                           selection: $mode, clearable: false)
            if mode == .earlier {
                LogHappenedAtControl(choice: $when, title: "Took it · minutes ago")
            }
            if mode != .skipped {
                LogFormLabel("With food?")
                LogChoiceChips(options: [(id: true, label: "with food"), (id: false, label: "without food")],
                               selection: $withFood)
                LogFormLabel("Dose")
                LogStepperRow(title: "How many \(unitName)s", valueText: LogText.number(units), value: $units,
                              range: 0.5...6, step: 0.5)
                HStack(spacing: 8) {
                    LogTextField("Strength of one \(unitName)", text: $strengthText, decimal: true)
                    LogUnitLabel(strengthUnit)
                }
                LogHint(doseLine)
            }
            LogHint("This only tracks and reminds. Any prescription cut-down target is yours and your prescriber's.")
            LogSaveBar(title: mode == .skipped ? "Log skipped" : "Log it", enabled: canSave, reason: reason,
                       action: save)
        }
    }

    private var canSave: Bool { ctx.canLog && mode != nil }
    private var reason: String? {
        if !ctx.canLog { return LogIntents.sampleReason }
        if mode == nil { return "Pick what happened." }
        return nil
    }

    private func save() {
        guard let mode else { return }
        let now = Date()
        let at = mode == .earlier ? when.resolved(now: now, calendar: calendar) : now
        let status: MedicationFields.Status = mode == .skipped ? .skipped : .taken
        let name = pickedName ?? preset?.name ?? ctx.row.title
        let event = LogEvents.medication(
            name: name, status: status, category: preset?.category,
            units: mode == .skipped ? nil : units, unitKind: mode == .skipped ? nil : preset?.unitKind,
            strength: mode == .skipped ? nil : strength, strengthUnit: strengthUnit,
            withFood: mode == .skipped ? nil : withFood, presetId: pickedID ?? preset?.id, at: at, loggedAt: now)
        let verb = mode == .skipped ? "skipped" : "taken"
        ctx.commit([event], message: "\(name) \(verb) \(LogText.time(at, calendar))")
    }
}
