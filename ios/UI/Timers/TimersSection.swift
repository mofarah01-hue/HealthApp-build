import SwiftUI
import MGContext
import MGDesign

// Timers (T153): the list, presets, pulse stepper 1-8, cancel, +5 min. Same shape as `AlarmsTimersSection`: the
// section draws a `TimersState` and calls back through a plain closure; `TimersPanel` is the one-line embed that
// observes the controller and owns the "Other..." sheet. Prefix "Timers" because every file under UI/ compiles into one
// module. Times come from `TimersState` (12-hour).

struct TimersSection: View {
    let state: TimersState
    let send: (TimersAction) -> Void
    let silence: () -> Void
    let openStart: () -> Void
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    init(state: TimersState, send: @escaping (TimersAction) -> Void, silence: @escaping () -> Void,
         openStart: @escaping () -> Void) {
        self.state = state
        self.send = send
        self.silence = silence
        self.openStart = openStart
    }

    var body: some View {
        SettingsSection("Timers", note: "iPhone alert + strap buzz") {
            ForEach(state.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    SettingsRow(row.title, detail: row.detail) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(MGFormat.time(row.endsAt, calendar: calendar))
                                .mgFont(.number)
                                .foregroundStyle(colors.ink.color)
                            if row.running {
                                TimersCountdown(endsAt: row.endsAt)
                            }
                        }
                    }
                    if row.running {
                        TimersRowControls(row: row, send: send)
                    } else if row.ringing {
                        MGButton("Silence the buzz", weight: .tonal) { silence() }
                    } else {
                        Button("Clear") { send(.clear(row.id)) }
                            .buttonStyle(.plain)
                            .mgFont(.body)
                            .foregroundStyle(colors.text(.body).color)
                            .frame(minHeight: MGSpace.tapTarget)
                    }
                }
                .padding(.vertical, 4)
            }
            if let problem = state.problem {
                Text(problem)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(TimersState.presets, id: \.self) { m in
                    Chip("\(m) min") { send(.start(minutes: m, stop: .standard, label: "")) }
                }
                Chip("Other…") { openStart() }
            }
            .padding(.vertical, 8)
        }
    }
}

/// "9:42" left, redrawn every second (the model is not touched).
struct TimersCountdown: View {
    let endsAt: Date
    @Environment(\.mgColors) private var colors

    init(endsAt: Date) {
        self.endsAt = endsAt
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.left(endsAt.timeIntervalSince(context.date)))
                .mgFont(.detail)
                .monospacedDigit()
                .foregroundStyle(colors.ink.color)
        }
    }

    static func left(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Pulse stepper, +5 min and Cancel for one running timer.
struct TimersRowControls: View {
    let row: TimersState.Row
    let send: (TimersAction) -> Void

    init(row: TimersState.Row, send: @escaping (TimersAction) -> Void) {
        self.row = row
        self.send = send
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = row.strapStatus {
                Text(status).mgFont(.detail)     // "armed on strap at 3:05 PM" / "not armed on strap: why" (T9816)
            }
            if row.stop == .doubleTap {
                Text("Strap buzzes until you double-tap it")
                    .mgFont(.detail)
            } else {
                Stepper("Strap buzz: \(row.pulses) \(row.pulses == 1 ? "pulse" : "pulses")",
                        value: Binding(get: { row.pulses }, set: { send(.setPulses(row.id, $0)) }),
                        in: TimerPulses.range)
            }
            HStack(spacing: 8) {
                MGButton("+5 min", weight: .tonal) { send(.extend(row.id, minutes: 5)) }
                MGButton("Cancel", weight: .tonal) { send(.cancel(row.id)) }
            }
        }
    }
}

/// The sheet behind "Other…": minutes, how the strap stops (x buzzes, or double tap), optional name.
struct TimersStartEditor: View {
    let send: (TimersAction) -> Void
    @State private var minutesValue = 25
    @State private var pulses = TimerPulses.standard
    @State private var doubleTap = false
    @State private var label = ""

    init(send: @escaping (TimersAction) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsSheetFrame(title: "Timer", saveTitle: "Start",
                           canSave: TimersBook.minutesRange.contains(minutesValue), reason: nil,
                           onSave: {
                               send(.start(minutes: minutesValue, stop: doubleTap ? .doubleTap : .buzzes(pulses),
                                           label: label.trimmingCharacters(in: .whitespaces)))
                           }) {
            Stepper("\(minutesValue) min", value: $minutesValue, in: TimersBook.minutesRange, step: 1)
            Picker("Strap stops", selection: $doubleTap) {
                Text("x buzzes").tag(false)
                Text("Double tap to stop").tag(true)
            }
            .pickerStyle(.segmented)
            if !doubleTap {
                Stepper("Strap buzz: \(pulses) \(pulses == 1 ? "pulse" : "pulses")", value: $pulses, in: TimerPulses.range)
            }
            TextField("Name (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
            LogHint(doubleTap
                    ? "The iPhone alerts when it ends and the strap buzzes 4 pulses every few seconds until you double-tap it "
                        + "(or tap Silence the buzz here), only while MG is running and the strap is connected."
                    : "The iPhone alerts when it ends and the strap buzzes once, only while MG is running and the strap is "
                        + "connected.")
        }
        .presentationCornerRadius(MGRadius.sheet)
        .presentationDragIndicator(.visible)
    }
}

/// One-line embed for a page. Observes the controller, owns the sheet, and routes Silence through AppModel.
@MainActor
struct TimersPanel: View {
    @ObservedObject private var controller: TimersController
    let silence: () -> Void
    @State private var showStart = false

    init(controller: TimersController? = nil, silence: @escaping () -> Void) {
        self.controller = controller ?? TimersController.shared
        self.silence = silence
    }

    var body: some View {
        TimersSection(state: controller.state,
                      send: { action in Task { await controller.apply(action) } },
                      silence: silence,
                      openStart: { showStart = true })
            .sheet(isPresented: $showStart) {
                TimersStartEditor { action in Task { await controller.apply(action) } }
            }
    }
}
