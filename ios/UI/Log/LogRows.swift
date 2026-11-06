import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Badge letter and accent per Log row (prototype `LOGI`). The list never reorders (UX §7).
enum LogItemStyle {
    static func badge(_ item: LogItemID) -> RowBadge {
        switch item {
        case .vape: return RowBadge("V", accent: .body)
        case .medication: return RowBadge("Rx", accent: .ink2)
        case .caffeine: return RowBadge("C", accent: .caffeine)
        case .supplements: return RowBadge("S", accent: .focus)
        case .food: return RowBadge("F", accent: .ink2)
        case .symptom: return RowBadge("Sy", accent: .body)
        case .sleepy: return RowBadge("Z", accent: .sleep)
        case .alcohol: return RowBadge("A", accent: .caffeine)
        case .water: return RowBadge("W", accent: .body)
        case .sore: return RowBadge("So", accent: .body)
        case .note: return RowBadge("N", accent: .ink2)
        case .more: return RowBadge("?", accent: .ink2)
        }
    }

    static func tone(_ item: LogItemID) -> InkTone {
        badge(item).accent
    }

    /// A lone plus is a quiet add affordance; labelled quick actions stay primary.
    static func usesTonalAction(_ title: String) -> Bool {
        title == "+"
    }
}

/// The toast text for a one-tap log ("Vape hit 10:42"). nil = the button opens a form instead of logging.
enum LogToastText {
    static func message(for intent: UIIntent, now: Date, calendar: Calendar) -> String? {
        guard case .quickLog(let action) = intent else { return nil }
        let t = LogText.time(now, calendar)
        switch action {
        case .vapeHit: return "Vape hit \(t)"
        case .medication(let name): return "\(name) taken \(t)"
        case .drinkStart(let preset): return "\(preset) started \(t)"
        case .drinkFinish: return "Drink finished \(t)"
        case .supplementsStack: return "Supplements logged \(t)"
        case .food, .symptom, .sleepy, .alcohol, .note, .more: return nil
        }
    }
}

/// One Log row: collapsed text + right-side one-tap button; tap the row = open in place. Open/closed is state-driven
/// (`.toggleRow`), never local (BRIEF interface clarification WP-07).
struct LogItemRowView: View {
    let row: LogItemRow
    let catalogue: LogCatalogue
    let canLog: Bool
    let spine: [SpineEntry]
    let send: (UIIntent) -> Void
    let announce: (LogToast) -> Void

    init(row: LogItemRow, catalogue: LogCatalogue, canLog: Bool, spine: [SpineEntry],
         send: @escaping (UIIntent) -> Void, announce: @escaping (LogToast) -> Void) {
        self.row = row
        self.catalogue = catalogue
        self.canLog = canLog
        self.spine = spine
        self.send = send
        self.announce = announce
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mgQuietHaptics) private var quietHaptics
    @Environment(\.calendar) private var calendar
    @State private var logTaps = 0
    @State private var saves = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(MGMotion.expand(reduceMotion: reduceMotion)) { send(.toggleRow(id: row.id)) }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        let badge = LogItemStyle.badge(row.item)
                        LetterBadge(badge.letter, accent: badge.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .mgFont(.rowTitle)
                                .foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                            if !row.collapsedText.isEmpty {
                                Text(row.collapsedText)
                                    .mgFont(.body)
                                    .foregroundStyle(colors.ink2.color)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // r8h E4: chevron inside the Button so the arrow is a live tap.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(colors.mute.color)
                            .rotationEffect(.degrees(row.isOpen ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(row.isOpen ? "open" : "closed")
                .accessibilityHint(row.isOpen ? "Closes this row" : "Opens this row in place")

                if let action = rowAction {
                    actionButton(action)
                }
            }
            .frame(minHeight: MGSpace.logRowHeight)

            if row.isOpen {
                LogRowContent(ctx: context)
                    .formScope()    // r8h K1: no tap-away keyboard drop between two fields
                    .padding(MGSpace.cardInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous)
                            .fill(colors.chip.color)
                    }
                    .padding(.leading, 50)
                    .padding(.bottom, MGSpace.m)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
        .animation(MGMotion.expand(reduceMotion: reduceMotion), value: row.isOpen)
        .mgLogHaptic(trigger: logTaps, quiet: quietHaptics)
        .mgSavedHaptic(trigger: saves, quiet: quietHaptics)
    }

    @Environment(\.mgColors) private var colors

    @ViewBuilder
    private func actionButton(_ action: RowAction) -> some View {
        if LogItemStyle.usesTonalAction(action.title) {
            Button(action: action.action) {
                Text(action.title)
                    .mgFont(.button)
                    .foregroundStyle(colors.ink.color)
                    .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                    .background(Circle().fill(colors.chip.color))
                    .contentShape(Circle())
            }
            .buttonStyle(MGPressButtonStyle())
            .accessibilityLabel("Add \(row.title)")
        } else {
            MGButton(action.title, weight: .filled, action: action.action)
        }
    }

    private var context: LogFormContext {
        LogFormContext(row: row, catalogue: catalogue, canLog: canLog, spine: spine, send: send,
                       saved: { message, undo in
                           saves += 1
                           announce(LogToast(message: message, undo: undo))
                       })
    }

    /// The right-side one-tap button. Absent while SAMPLE data is on (the open row says why) or when the presenter
    /// disabled it (its reason shows when the row is open).
    private var rowAction: RowAction? {
        guard canLog, let button = row.primaryButton, button.enabled, let intent = button.intent else { return nil }
        return RowAction(button.title) {
            logTaps += 1
            send(intent)
            if let message = LogToastText.message(for: intent, now: Date(), calendar: calendar) {
                announce(LogToast(message: message, undo: [.undoLastLog]))
            }
        }
    }
}

/// What a Log row shows when open: the presenter's lines / chart / switches / actions / methods strip, then the form.
struct LogRowContent: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.m) {
            if !ctx.canLog {
                LogHint(LogIntents.sampleReason)
            }
            if let button = ctx.row.primaryButton, !button.enabled, let why = button.disabledReason {
                LogHint("\(button.title): \(why)")
            }
            if let expansion = ctx.row.expansion {
                LogExpansionBlock(expansion: expansion, tone: LogItemStyle.tone(ctx.row.item), canAct: ctx.canLog,
                                  send: ctx.send)
            }
            form
        }
    }

    @ViewBuilder private var form: some View {
        switch ctx.row.item {
        case .vape: LogVapeForm(ctx: ctx)
        case .medication: LogMedicationForm(ctx: ctx)
        case .caffeine: LogCaffeineForm(ctx: ctx)
        case .supplements: LogSupplementsForm(ctx: ctx)
        case .food: LogFoodForm(ctx: ctx)
        case .symptom: LogSymptomForm(ctx: ctx)
        case .sleepy: LogSleepyForm(ctx: ctx)
        case .alcohol: LogAlcoholForm(ctx: ctx)
        case .water: LogWaterForm(ctx: ctx)
        case .sore: LogSoreForm(ctx: ctx)
        case .note: LogNoteForm(ctx: ctx)
        case .more: LogMoreForm(ctx: ctx)
        }
    }
}

/// The presenter's part of an opened row: lines, a small chart, switches, actions, optionally a methods strip.
struct LogExpansionBlock: View {
    let expansion: NowRowExpansion
    let tone: InkTone
    let canAct: Bool
    let send: (UIIntent) -> Void

    init(expansion: NowRowExpansion, tone: InkTone, canAct: Bool, send: @escaping (UIIntent) -> Void) {
        self.expansion = expansion
        self.tone = tone
        self.canAct = canAct
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.s) {
            if expansion.chart.compactMap({ $0 }).count >= 2 {
                LogHourBars(values: expansion.chart, tone: tone)
                    .accessibilityHidden(true)
                if let caption = expansion.chartCaption {
                    LogHint(caption)
                }
            }

            ForEach(Array(expansion.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(expansion.toggles) { toggle in
                LogToggleRow(toggle: toggle, canAct: canAct, send: send)
            }

            if !expansion.actions.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(expansion.actions) { action in
                        actionView(action)
                    }
                }
            }

            if let methods = expansion.methods {
                MethodsStrip(state: methods, send: send)
            }

            if let panel = expansion.algorithmPanel {      // T101: caffeine decay model, tap for how each works
                AlgorithmPanel(state: panel) {
                    send(.selectMethod(groupId: CaffeinePanelPresenter.groupID, variant: $0))
                }
            }
        }
    }

    @ViewBuilder
    private func actionView(_ action: ActionState) -> some View {
        if action.enabled, canAct, let intent = action.intent {
            MGButton(action.title, style: .ghost) { send(intent) }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title).mgFont(.button).foregroundStyle(colors.mute.color)
                if let why = action.disabledReason {
                    LogHint(why)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The compact 24-hour chart used inside an expanded Log row.
private struct LogHourBars: View {
    let values: [Double?]
    let tone: InkTone

    @Environment(\.mgColors) private var colors

    var body: some View {
        Canvas { context, size in
            let hours = Array(values.prefix(24))
            guard !hours.isEmpty else { return }
            let maximum = max(hours.compactMap { $0 }.max() ?? 0, 1)
            let gap: CGFloat = 2
            let width = max(1, (size.width - gap * CGFloat(hours.count - 1)) / CGFloat(hours.count))
            for (index, value) in hours.enumerated() {
                let fraction = CGFloat(max(0, min(1, (value ?? 0) / maximum)))
                let height = max(2, size.height * fraction)
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height,
                                  width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                             with: .color(colors.mark(tone).color))
            }
        }
        .frame(height: 48)
    }
}

/// Header chip "{n} to confirm" and the detected-hit cards (UX §7 rows 1–2).
struct LogConfirmList: View {
    let items: [ConfirmItem]
    let canAct: Bool
    let send: (UIIntent) -> Void

    init(items: [ConfirmItem], canAct: Bool, send: @escaping (UIIntent) -> Void) {
        self.items = items
        self.canAct = canAct
        self.send = send
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.mgQuietHaptics) private var quietHaptics
    @State private var logTaps = 0

    var body: some View {
        VStack(spacing: MGSpace.s) {
            ForEach(items) { item in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        text(item)
                        Spacer(minLength: 8)
                        buttons(item)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        text(item)
                        buttons(item)
                    }
                }
                .padding(MGSpace.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: MGRadius.card, style: .continuous)
                        .fill(colors.bodyWash.color)
                }
            }
        }
        .mgLogHaptic(trigger: logTaps, quiet: quietHaptics)
    }

    private func text(_ item: ConfirmItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).mgFont(.body).foregroundStyle(colors.ink.color)
            LogHint("detected · your answer is saved as a label")
        }
    }

    private func buttons(_ item: ConfirmItem) -> some View {
        HStack(spacing: 6) {
            MGButton("Yes", style: .filled) {
                logTaps += 1
                send(item.yes)
            }
                .disabled(!canAct)
                .opacity(canAct ? 1 : 0.4)
                .accessibilityLabel("Yes, \(item.title)")
            MGButton("No", weight: .tonal) {
                logTaps += 1
                send(item.no)
            }
                .disabled(!canAct)
                .opacity(canAct ? 1 : 0.4)
                .accessibilityLabel("No, \(item.title)")
        }
    }
}
