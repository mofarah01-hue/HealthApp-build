import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// The guided MG ECG reading (APP-033; wave W8, 2026-10-11). Phases from `EcgReadingState.phase`: ready (how to hold
/// it, Start) → starting (the strap is asked: wrist, outputs, start) → recording (countdown, the live waveform, the
/// strap's contact / progress, Stop now) → result (HR from our R-peaks, research tier; the strap's own screen with its
/// code; tracker #89 removed "not a diagnosis"); what was saved; Again / Done) · blocked (why it cannot run, Close).
/// Pure rendering; every tap is `.ecgMotion(…)` through `send`. Samples are raw counts: the waveform has no voltage axis.
struct GuidedECGView: View {
    let state: EcgReadingState
    let theme: ThemeName?
    let send: (UIIntent) -> Void

    var body: some View {
        Group {
            if let theme {
                GuidedECGContent(state: state, send: send).mgTheme(theme)
            } else {
                GuidedECGContent(state: state, send: send)
            }
        }
    }
}

private struct GuidedECGContent: View {
    let state: EcgReadingState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                GuidedTopBar(kicker: "ECG · \(state.wrist) wrist · research", title: "ECG reading",
                             closeLabel: state.phase == .recording ? "Stop, save and close" : "Close ECG") {
                    send(.ecgMotion(.closeECG))
                }
                .padding(.top, 12)
                switch state.phase {
                case .ready: ready
                case .starting: GuidedNote("Asking the strap: wrist, then the ECG outputs, then start…").padding(.top, 20)
                case .recording: recording
                case .result: result
                case .blocked: blocked
                }
            }
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .environment(\.mgSend, send)
        .onChange(of: state.phase, initial: true) { _, phase in
            GuidedIdleTimer.keepAwake(phase == .recording || phase == .starting)
        }
        .onDisappear { GuidedIdleTimer.keepAwake(false) }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(state.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1).").mgFont(.rowTitle).foregroundStyle(colors.ink2.color)
                    Text(step).mgFont(.body).foregroundStyle(colors.ink.color).fixedSize(horizontal: false, vertical: true)
                }
            }
            MGButton("Start: 5 s countdown, then \(state.seconds) s") { send(.ecgMotion(.beginECG)) }
                .padding(.top, 12)
        }
        .padding(.top, 16)
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let n = state.leadInSecondsLeft {
                Text("Recording starts in \(n) s").mgFont(.bigNumber).foregroundStyle(colors.ink.color).padding(.top, 24)
                GuidedNote("Rest the fingertip on the sensor and stay still. Nothing from this countdown is kept.")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    GuidedCountdown(start: state.startedAt, end: state.endsAt, plannedMinutes: 1)
                    Text("left").mgFont(.detail).foregroundStyle(colors.ink2.color)
                }
                .padding(.top, 24)
            }
            MGCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(state.liveHeartRate ?? "— bpm").mgFont(.bigNumber).foregroundStyle(colors.ink.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live heart rate · our R-peaks · research").mgFont(.receipt).foregroundStyle(colors.mute.color)
                            if let why = state.liveHeartRateReason { Text(why).mgFont(.receipt).foregroundStyle(colors.mute.color) }
                        }
                    }
                    if let c = state.contactLine { GuidedNote(c) }
                    if state.trace.count > 1 {
                        Button { send(.ecgMotion(.setEcgExpanded(!state.expanded))) } label: {
                            RawTraceLine(values: state.trace).frame(height: state.expanded ? 280 : 140)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Live ECG waveform, tap to \(state.expanded ? "shrink" : "expand")")
                        Text(state.expanded ? "The whole recording so far · tap to shrink" : "Last 8 s · tap to expand")
                            .mgFont(.receipt).foregroundStyle(colors.mute.color)
                    } else {
                        GuidedNote("Waiting for the first ECG record… keep the fingertip resting on the sensor.")
                    }
                    Text(state.traceLabel).mgFont(.receipt).foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = state.statusLine { GuidedNote(line) }
                    Text("\(state.packets) record(s) kept · raw counts are decoded, untested")
                        .mgFont(.receipt).foregroundStyle(colors.mute.color)
                }
            }
            .padding(.top, 16)
            MGButton(state.filtered ? "Show unfiltered counts" : "Show filtered", style: .ghost) {
                send(.ecgMotion(.setEcgFiltered(!state.filtered)))
            }
            .padding(.top, 12)
            MGButton("Stop now and save", style: .ghost) { send(.ecgMotion(.finishECG)) }
                .padding(.top, 18)
        }
    }

    @ViewBuilder private var result: some View {
        if let r = state.result {
            VStack(alignment: .leading, spacing: 0) {
                MGCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Heart rate from the R-peaks").mgFont(.kicker).foregroundStyle(colors.ink2.color)
                        Text(r.heartRate ?? "—").mgFont(.bigNumber).foregroundStyle(colors.ink.color)
                        if let why = r.heartRateReason { GuidedNote(why) }
                        Text(r.heartRateNote).mgFont(.receipt).foregroundStyle(colors.mute.color)
                            .fixedSize(horizontal: false, vertical: true)
                        if let s = r.strapHeartRate { GuidedNote(s) }
                    }
                }
                .padding(.top, 16)
                if !r.breakdown.isEmpty {
                    MGCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("The reading in words").mgFont(.kicker).foregroundStyle(colors.ink2.color)
                            ForEach(r.breakdown, id: \.label) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.label).mgFont(.label).foregroundStyle(colors.ink2.color)
                                    Text(row.value).mgFont(.body).foregroundStyle(colors.ink.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let note = row.note {
                                        Text(note).mgFont(.receipt).foregroundStyle(colors.mute.color)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 12)
                }
                MGCard { GuidedNote(r.strapScreen) }.padding(.top, 12)
                if r.trace.count > 1 {
                    let useFiltered = state.filtered && r.filteredTrace.count > 1
                    SectionHeader("The recording", note: useFiltered ? "filtered, display only" : "raw counts · decoded, untested")
                    RawTraceLine(values: useFiltered ? r.filteredTrace : r.trace).frame(height: 120)
                    MGButton(useFiltered ? "Show unfiltered counts" : "Show filtered", style: .ghost) {
                        send(.ecgMotion(.setEcgFiltered(!state.filtered)))
                    }
                    .padding(.top, 8)
                }
                ForEach(r.together, id: \.self) { GuidedNote($0).padding(.top, 8) }
                GuidedNote(r.saved).padding(.top, 8)
                HStack(spacing: 12) {
                    MGButton("Again") { send(.ecgMotion(.beginECG)) }
                    MGButton("Done", style: .ghost) { send(.ecgMotion(.closeECG)) }
                }
                .padding(.top, 18)
            }
        }
    }

    private var blocked: some View {
        VStack(alignment: .leading, spacing: 12) {
            MGCard { GuidedNote(state.blankReason ?? "The reading can't run now.") }
            MGButton("Close", style: .ghost) { send(.ecgMotion(.closeECG)) }
        }
        .padding(.top, 16)
    }
}

/// A raw waveform drawn between its own min and max (no unit, no axis): ECG samples or accelerometer magnitude counts.
struct RawTraceLine: View {
    let values: [Double]
    @Environment(\.mgColors) private var colors

    var body: some View {
        GeometryReader { geo in
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let span = max(hi - lo, 1e-9)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                    let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(colors.body.color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
