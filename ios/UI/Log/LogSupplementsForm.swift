import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// One supplement waiting to be logged.
struct LogSupplementDraft: Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Typed by Mo (true) or from his saved list (false).
    var isCustom: Bool
    /// Input as N pills or as mg (APP-077: the last unit is remembered).
    var inMg: Bool
    var pills: Double
    var mgText: String
    /// Per-pill strength from the saved list ("200 mg"); nil when unknown.
    var strength: Double?
    var strengthUnit: String?

    /// nil = ready; otherwise the reason it is not.
    var problem: String? {
        if LogText.clean(name) == nil { return "Name the supplement." }
        if inMg {
            guard let mg = LogText.parse(mgText), mg > 0 else { return "Enter the amount in mg for \(name)." }
        }
        return nil
    }
}

/// Supplements, opened in place (UX §7, APP-077): his saved list as chips (empty until he adds some), "+ add", N pills
/// or mg per item (the last unit is remembered on this phone), one intake event per item at one time.
/// The one-tap "morning stack" is the row's own button (`.quickLog(.supplementsStack)`).
struct LogSupplementsForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    /// A per-phone convenience, not data (APP-077 "last unit remembered").
    @AppStorage("mg.log.supplementInMg") private var lastInMg = false
    @State private var drafts: [LogSupplementDraft] = []
    @State private var when = LogHappenedAt()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("Your supplements")
            if ctx.catalogue.supplements.isEmpty {
                LogHint("None saved yet. Add what you take; nothing is filled in for you.")
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(ctx.catalogue.supplements) { item in
                    Chip(chipLabel(item), selected: drafts.contains { $0.name == item.name && !$0.isCustom }) {
                        toggle(item)
                    }
                }
                Chip("+ add") { drafts.append(blankDraft()) }
                    .accessibilityLabel("Add a supplement")
            }
            ForEach($drafts) { $draft in
                LogSupplementRow(draft: $draft, onUnitChange: { lastInMg = $0 }, onRemove: { remove(draft.id) })
            }
            if !drafts.isEmpty {
                LogHappenedAtControl(choice: $when)
            }
            LogSaveBar(title: saveTitle, enabled: canSave, reason: reason, action: save)
        }
    }

    // MARK: Drafts

    private func chipLabel(_ item: LogSupplement) -> String {
        var text = item.name
        if let strength = item.strength, let unit = item.strengthUnit {
            text += " \(LogText.number(strength)) \(unit)"
        }
        return text + " ×\(LogText.number(item.defaultPills))"
    }

    private func blankDraft() -> LogSupplementDraft {
        LogSupplementDraft(name: "", isCustom: true, inMg: lastInMg, pills: 1, mgText: "", strength: nil,
                           strengthUnit: nil)
    }

    private func toggle(_ item: LogSupplement) {
        if let index = drafts.firstIndex(where: { $0.name == item.name && !$0.isCustom }) {
            drafts.remove(at: index)
        } else {
            drafts.append(LogSupplementDraft(name: item.name, isCustom: false, inMg: false, pills: item.defaultPills,
                                             mgText: "", strength: item.strength, strengthUnit: item.strengthUnit))
        }
    }

    private func remove(_ id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    // MARK: Save

    private var firstProblem: String? { drafts.compactMap { $0.problem }.first }
    private var canSave: Bool { ctx.canLog && !drafts.isEmpty && firstProblem == nil }
    private var saveTitle: String {
        drafts.count == 1 ? "Log 1 supplement" : "Log \(drafts.count) supplements"
    }
    private var reason: String? {
        if !ctx.canLog { return LogIntents.sampleReason }
        if drafts.isEmpty { return "Pick or add at least one." }
        return firstProblem
    }

    private func save() {
        guard canSave else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        var events: [EventRecord] = []
        for draft in drafts {
            guard let name = LogText.clean(draft.name) else { continue }
            if draft.inMg {
                guard let mg = LogText.parse(draft.mgText) else { continue }
                events.append(LogEvents.supplementMg(name: name, mg: mg, at: at, loggedAt: now))
            } else {
                events.append(LogEvents.medication(
                    name: name, status: .taken, category: .supplement, units: draft.pills, unitKind: .pill,
                    strength: draft.strength, strengthUnit: draft.strengthUnit, withFood: nil, presetId: nil,
                    at: at, loggedAt: now))
            }
        }
        let message = events.count == 1 ? "Supplement logged \(LogText.time(at, calendar))"
                                        : "\(events.count) supplements logged \(LogText.time(at, calendar))"
        ctx.commit(events, message: message)
    }
}

/// One supplement being logged: name (when typed), N pills or mg, remove.
struct LogSupplementRow: View {
    @Binding var draft: LogSupplementDraft
    let onUnitChange: (Bool) -> Void
    let onRemove: () -> Void

    init(draft: Binding<LogSupplementDraft>, onUnitChange: @escaping (Bool) -> Void, onRemove: @escaping () -> Void) {
        self._draft = draft
        self.onUnitChange = onUnitChange
        self.onRemove = onRemove
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if draft.isCustom {
                    LogTextField("Supplement name", text: $draft.name)
                } else {
                    Text(draft.name)
                        .mgFont(.rowTitle)
                        .foregroundStyle(colors.ink.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.ink2.color)
                        .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(draft.name.isEmpty ? "supplement" : draft.name)")
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                Chip("pills", selected: !draft.inMg) {
                    draft.inMg = false
                    onUnitChange(false)
                }
                Chip("mg", selected: draft.inMg) {
                    draft.inMg = true
                    onUnitChange(true)
                }
            }
            if draft.inMg {
                HStack(spacing: 8) {
                    LogTextField("Amount", text: $draft.mgText, decimal: true)
                    LogUnitLabel("mg")
                }
            } else {
                LogStepperRow(title: "Pills", valueText: LogText.number(draft.pills), value: $draft.pills,
                              range: 0.5...20, step: 0.5)
            }
        }
        .padding(12)
        .mgSurface(.chip, radius: MGRadius.chip)
    }
}
