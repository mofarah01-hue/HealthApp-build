import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Breathe — the full-screen pacer flow (UX-SPEC §6 ActionGrid "Breathe (pacer + coherence)", §4.1 Night and
/// Late-night "Breathe" rows, Tonight's wind-down [Breathe now]; APP-024, ALG-104). Owner: WP-29.
///
/// Phases (from `BreatheState.phase`): ready (pace and length chips, Start) → running (the pacer, time left, live HR,
/// beats collected, End now) → finished (coherence and the session's values, Again / Done).
/// Pure rendering of `BreatheState`; every tap is a `UIIntent` through `send`:
///   Start / Again → `.guided(.beginBreathe(perMinute:minutes:))`, End now → `.guided(.endNow)`,
///   close (×) / Done → `.guided(.close)` (while running that discards: nothing saved).
/// Haptics: iPhone only, never the strap (BRIEF default 4); on when `state.phoneHaptics` and not `\.mgQuietHaptics`.
/// The screen stays awake while the pacer runs.
///
/// WP-23 presents it with `.fullScreenCover` on `.startBreathe` and applies `.mgTheme(...)` above it (or passes
/// `theme`, as previews do).
struct GuidedBreatheView: View {
    let state: BreatheState
    let theme: ThemeName?
    let send: (UIIntent) -> Void

    init(state: BreatheState, theme: ThemeName? = nil, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.theme = theme
        self.send = send
    }

    var body: some View {
        Group {
            if let theme {
                GuidedBreatheContent(state: state, send: send).mgTheme(theme)
            } else {
                GuidedBreatheContent(state: state, send: send)
            }
        }
    }
}

private struct GuidedBreatheContent: View {
    let state: BreatheState
    let send: (UIIntent) -> Void
    @Environment(\.mgQuietHaptics) private var quietHaptics

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                GuidedTopBar(kicker: kicker, title: "Breathe", closeLabel: closeLabel) {
                    send(.guided(.close))
                }
                .padding(.top, 12)

                switch state.phase {
                case .ready:
                    GuidedBreatheReady(state: state, haptics: haptics, send: send)
                case .running:
                    GuidedBreatheRunning(state: state, haptics: haptics, send: send)
                case .finished:
                    GuidedBreatheFinished(state: state, send: send)
                }
            }
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .environment(\.mgSend, send)
        // A "start" tap when the pacer begins from the ready screen (the first turn comes a few seconds later).
        .sensoryFeedback(trigger: state.startedAt) { old, new in
            haptics && old == nil && new != nil ? .start : nil
        }
        .onChange(of: state.phase, initial: true) { _, phase in
            GuidedIdleTimer.keepAwake(phase == .running)
        }
        .onDisappear { GuidedIdleTimer.keepAwake(false) }
    }

    private var haptics: Bool { state.phoneHaptics && !quietHaptics }

    /// "PACER · 6 /MIN · 5 MIN".
    private var kicker: String {
        "Pacer · \(GuidedText.rate(state.breathsPerMinute)) /min · \(state.minutes) min"
    }

    private var closeLabel: String {
        state.phase == .running ? "Stop and close — nothing is saved" : "Close Breathe"
    }
}

// MARK: - Ready

private struct GuidedBreatheReady: View {
    let state: BreatheState
    let haptics: Bool
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    /// Mo's picks before Start (form input, not expansion); nil = the state's default.
    @State private var rate: Double?
    @State private var minutes: Int?

    var body: some View {
        let chosenRate = rate ?? state.breathsPerMinute
        let chosenMinutes = minutes ?? state.minutes
        VStack(alignment: .leading, spacing: 0) {
            Text("Follow the circle: in as it grows, out as it shrinks.")
                .mgFont(.body)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            SectionHeader("Pace", note: split(for: chosenRate))
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(rateChoices, id: \.self) { r in
                    Chip("\(GuidedText.rate(r)) /min", selected: r == chosenRate) { rate = r }
                        .accessibilityLabel("\(GuidedText.rate(r)) breaths a minute")
                }
            }

            SectionHeader("Length")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(minuteChoices, id: \.self) { m in
                    Chip("\(m) min", selected: m == chosenMinutes) { minutes = m }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                GuidedNote(GuidedText.haptics(preference: state.phoneHaptics, quiet: !haptics && state.phoneHaptics))
                if let cue = state.cueNote { GuidedNote(cue) }
                if let note = state.strapNote { GuidedNote(note) }
            }
            .padding(.top, 18)

            MGButton("Start", style: .filled) {
                send(.guided(.beginBreathe(perMinute: chosenRate, minutes: chosenMinutes)))
            }
            .padding(.top, 20)
            .accessibilityHint("Starts the pacer at \(GuidedText.rate(chosenRate)) breaths a minute for \(chosenMinutes) minutes")
        }
    }

    /// The presenter's choices; the current value is always among them.
    private var rateChoices: [Double] {
        let base = state.rateOptions.filter { $0.isFinite && $0 > 0 }
        return base.contains(state.breathsPerMinute) || !(state.breathsPerMinute > 0)
            ? base : (base + [state.breathsPerMinute]).sorted()
    }

    private var minuteChoices: [Int] {
        let base = state.minuteOptions.filter { $0 > 0 }
        return base.contains(state.minutes) || state.minutes <= 0 ? base : (base + [state.minutes]).sorted()
    }

    /// "5 s in · 5 s out" for a rate, from the state's own arithmetic.
    private func split(for perMinute: Double) -> String {
        var s = state
        s.breathsPerMinute = perMinute
        return "\(GuidedText.seconds(s.inhaleSeconds)) in · \(GuidedText.seconds(s.exhaleSeconds)) out"
    }
}

// MARK: - Running

private struct GuidedBreatheRunning: View {
    let state: BreatheState
    let haptics: Bool
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuidedPacer(state: state, haptics: haptics)
                .padding(.top, 24)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                GuidedCountdown(start: state.startedAt, end: state.endsAt, plannedMinutes: state.minutes)
                Text("left")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                Spacer(minLength: 8)
                Text("\(GuidedText.seconds(state.inhaleSeconds)) in · \(GuidedText.seconds(state.exhaleSeconds)) out")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
            }
            .padding(.top, 20)

            MGCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Text("Heart rate")
                            .mgFont(.rowTitle)
                            .foregroundStyle(colors.ink.color)
                        Spacer(minLength: 8)
                        ValueView(state.heartRate, size: .number, showsReceipt: true)
                            .frame(maxWidth: 170, alignment: .trailing)
                    }
                    if let beats = state.beatsCollected {
                        GuidedNote(beats == 1 ? "1 beat collected · coherence shows at the end"
                                              : "\(beats) beats collected · coherence shows at the end")
                    }
                    if let note = state.strapNote { GuidedNote(note) }
                }
            }
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 6) {
                GuidedNote(GuidedText.haptics(preference: state.phoneHaptics, quiet: !haptics && state.phoneHaptics))
                if let cue = state.cueNote { GuidedNote(cue) }
            }
            .padding(.top, 14)

            MGButton("End now", style: .ghost) { send(.guided(.endNow)) }
                .padding(.top, 18)
                .accessibilityHint("Stops the pacer and shows what was measured")
        }
    }
}

// MARK: - Finished

private struct GuidedBreatheFinished: View {
    let state: BreatheState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let result = state.result {
                MGCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Coherence")
                            .mgFont(.kicker)
                            .foregroundStyle(colors.ink2.color)
                        ValueView(result.coherence, size: .big, showsReceipt: true)
                        if let word = result.coherenceWord {
                            Text(word)
                                .mgFont(.body)
                                .foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let line = result.resonanceLine { GuidedNote(line) }
                        GuidedNote("Ratio of the heart-rhythm peak to everything else (ALG-104, McCraty & Zayas 2014).")
                    }
                }
                .padding(.top, 16)

                if !result.rows.isEmpty {
                    SectionHeader("This session")
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(result.rows) { GuidedValueRow(item: $0) }
                    }
                }
                if let note = result.note {
                    GuidedNote(note).padding(.top, 12)
                }
            } else {
                MGCard {
                    GuidedNote("Nothing was measured this time.")
                }
                .padding(.top, 16)
            }

            HStack(spacing: 10) {
                MGButton("Again", style: .ghost) {
                    send(.guided(.beginBreathe(perMinute: state.breathsPerMinute, minutes: state.minutes)))
                }
                MGButton("Done", style: .filled) { send(.guided(.close)) }
            }
            .padding(.top, 20)
        }
    }
}
