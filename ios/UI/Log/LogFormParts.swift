import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import MGContext
import MGDesign
import MGDomain

// Small building blocks shared by every Log entry form. Names start with "Log" because every file under UI/
// compiles into one module. Every view with private wrapper properties has an explicit init: a synthesized memberwise
// init would be private and unusable from the other files.

/// What a form needs from the row that opened it.
struct LogFormContext {
    let row: LogItemRow
    let catalogue: LogCatalogue
    /// false while SAMPLE data is on (ARCHITECTURE §4.12): every control that would write is disabled.
    let canLog: Bool
    let spine: [SpineEntry]
    let send: (UIIntent) -> Void
    /// Toast text + the intents that undo it (one `.undoLastLog` per saved event).
    let saved: (String, [UIIntent]) -> Void

    /// Sends one `saveEvent` per event, announces it, then closes the row (state-driven: `.toggleRow`).
    func commit(_ events: [EventRecord], message: String) {
        guard canLog, !events.isEmpty else { return }
        for event in events { send(LogIntents.save(event)) }
        LogDrafts.shared.clear(row: row.id)    // r8h G1: saved, so the kept draft goes
        saved(message, events.map { _ in UIIntent.undoLastLog })
        send(.toggleRow(id: row.id))
    }
}

/// Small mono caption above a group of controls.
struct LogFormLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        Text(text)
            .mgFont(.kicker)
            .foregroundStyle(colors.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet sentence under controls.
struct LogHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        Text(text)
            .mgFont(.detail)
            .foregroundStyle(colors.mute.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A unit beside a field ("mg").
struct LogUnitLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        Text(text).mgFont(.body).foregroundStyle(colors.ink2.color)
    }
}

/// − value + with 44 pt targets.
struct LogStepperRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(title: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
        self.title = title
        self.valueText = valueText
        self._value = value
        self.range = range
        self.step = step
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(spacing: MGSpace.s) {
            Text(title)
                .mgFont(.body)
                .foregroundStyle(colors.ink.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            stepButton("minus", delta: -step, label: "Less")
            Text(valueText)
                .mgFont(.number)
                .foregroundStyle(colors.ink.color)
                .frame(minWidth: 44)
            stepButton("plus", delta: step, label: "More")
        }
        .accessibilityElement(children: .contain)
    }

    private func stepButton(_ symbol: String, delta: Double, label: String) -> some View {
        Button {
            value = min(range.upperBound, max(range.lowerBound, value + delta))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(colors.ink.color)
                .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                .background(Circle().fill(colors.chip.color))
                .contentShape(Circle())
        }
        .buttonStyle(MGPressButtonStyle())
        .accessibilityLabel("\(label) \(title)")
    }
}

/// The form's save button; disabled with its reason shown (never a silent dead button).
struct LogSaveBar: View {
    let title: String
    let enabled: Bool
    /// Why it is disabled (shown under the button).
    let reason: String?
    let action: () -> Void

    init(title: String, enabled: Bool, reason: String?, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.reason = reason
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.xs) {
            MGButton(title, style: .filled, action: action)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
            if !enabled, let reason {
                LogHint(reason)
            }
        }
    }
}

/// A themed single-line text field.
struct LogTextField: View {
    let title: String
    @Binding var text: String
    let decimal: Bool

    init(_ title: String, text: Binding<String>, decimal: Bool = false) {
        self.title = title
        self._text = text
        self.decimal = decimal
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        TextField(text: $text, prompt: Text(title).foregroundStyle(colors.mute.color)) {
            Text(title)
        }
        .mgFont(.body)
        .foregroundStyle(colors.ink.color)
        #if canImport(UIKit)
        .keyboardType(decimal ? .decimalPad : .default)
        #endif
        .formSubmit()                             // r8h K1 / r9v: the Return key says Next, or Done on the last field
        .padding(.horizontal, 12)
        .frame(minHeight: MGSpace.tapTarget)
        .background(RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous).fill(colors.chip.color))
        .accessibilityLabel(title)
    }
}

/// Chips that wrap onto lines. With `clearable`, tapping the selected chip again clears the choice.
struct LogChoiceChips<ID: Hashable>: View {
    let options: [(id: ID, label: String)]
    @Binding var selection: ID?
    let clearable: Bool

    init(options: [(id: ID, label: String)], selection: Binding<ID?>, clearable: Bool = true) {
        self.options = options
        self._selection = selection
        self.clearable = clearable
    }

    var body: some View {
        FlowLayout(spacing: MGSpace.s, lineSpacing: MGSpace.s) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Chip(option.label, selected: selection == option.id) {
                    if selection == option.id, clearable {
                        selection = nil
                    } else {
                        selection = option.id
                    }
                }
            }
        }
    }
}

/// "Happened at" (APP-082): chips now · −5 · −15 · −30 · −60 and a time wheel. Shows both times: happened / logged.
struct LogHappenedAtControl: View {
    @Binding var choice: LogHappenedAt
    let title: String

    init(choice: Binding<LogHappenedAt>, title: String = "Happened · minutes ago") {
        self._choice = choice
        self.title = title
    }
    @Environment(\.calendar) private var calendar
    @State private var wheelOpen = false

    private let offsets = [0, 5, 15, 30, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.s) {
            LogFormLabel(title)
            FlowLayout(spacing: MGSpace.s, lineSpacing: MGSpace.s) {
                ForEach(offsets, id: \.self) { minutes in
                    Chip(minutes == 0 ? "now" : "−\(minutes)",
                         selected: choice.clock == nil && choice.minutesAgo == minutes) {
                        choice.clock = nil
                        choice.minutesAgo = minutes
                        wheelOpen = false
                    }
                    .accessibilityLabel(minutes == 0 ? "Happened now" : "Happened \(minutes) minutes ago")
                }
                Chip("time…", selected: choice.clock != nil || wheelOpen) {
                    wheelOpen.toggle()
                    if wheelOpen, choice.clock == nil { choice.clock = Date() }
                }
                .accessibilityLabel("Pick the time it happened")
            }
            if wheelOpen {
                DatePicker("Time it happened", selection: wheelBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, AlarmTimeLocale.picker)   // 12-hour AM/PM
                    .frame(maxWidth: .infinity, maxHeight: 120)
            }
            LogHint(summary)
        }
    }

    private var wheelBinding: Binding<Date> {
        Binding(get: { choice.clock ?? Date() }, set: { choice.clock = $0 })
    }

    /// r8h G7: the hint never prints a "logged" clock time that could drift from the time actually saved. The entry is
    /// stamped when Save is pressed, so the hint says exactly that: "happened 09:35 · logged when you save".
    private var summary: String {
        if choice.isNow { return "happened now · logged now" }
        if let clock = choice.clock {
            let c = calendar.dateComponents([.hour, .minute], from: clock)
            let shown = calendar.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: clock) ?? clock
            return "happened \(LogText.time(shown, calendar)) · logged when you save"
        }
        return "happened \(choice.minutesAgo) min before you save · logged when you save"
    }
}

/// A switch row inside an opened Log row (strap double-tap logs a hit…). Flipping sends the presenter's intent,
/// which already carries the NEW value (same pattern as Today's toggles).
struct LogToggleRow: View {
    let toggle: ToggleState
    let canAct: Bool
    let send: (UIIntent) -> Void

    init(toggle: ToggleState, canAct: Bool, send: @escaping (UIIntent) -> Void) {
        self.toggle = toggle
        self.canAct = canAct
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        OptimisticToggle(isOn: toggle.isOn, onChange: { _ in send(toggle.intent) }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(toggle.title).mgFont(.body).foregroundStyle(colors.ink.color)
                if let detail = toggle.detail {
                    LogHint(detail)
                }
                if !toggle.enabled, let why = toggle.disabledReason {
                    LogHint(why)
                }
            }
        }
        .tint(colors.focus.color)
        .disabled(!toggle.enabled || !canAct)
        .frame(minHeight: MGSpace.tapTarget)
        .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
    }
}
