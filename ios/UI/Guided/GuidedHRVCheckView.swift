import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// HRV spot check — guided 1–5 min reading with a countdown (UX-SPEC §6 ActionGrid "HRV check (1–5 min)"; APP-025;
/// ALG-010 RMSSD / lnRMSSD, ALG-104 coherence, ALG-004 artefact gate). Owner: WP-29.
///
/// Phases (from `HRVCheckState.phase`): ready (1–5 min chips — a tap starts) → measuring (time left, progress, live HR,
/// live R-R count, the quality gate, End now) → result (RMSSD, lnRMSSD, coherence, the gate's last word, Again / Done)
/// · blocked (strap off / not connected: the reason, Close).
/// Pure rendering of `HRVCheckState`; every tap is a `UIIntent` through `send`:
///   a length chip / Again → `.startHRVCheck(minutes:)`, End now → `.guided(.endNow)`,
///   close (×) / Done → `.guided(.close)` (while measuring that discards: nothing saved).
/// No haptics (UX §1.4: nothing else in-app). The screen stays awake while measuring.
///
/// WP-23 presents it with `.fullScreenCover` on `.startHRVCheck(minutes:)` and applies `.mgTheme(...)` above it.
struct GuidedHRVCheckView: View {
    let state: HRVCheckState
    let theme: ThemeName?
    let send: (UIIntent) -> Void

    init(state: HRVCheckState, theme: ThemeName? = nil, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.theme = theme
        self.send = send
    }

    var body: some View {
        Group {
            if let theme {
                GuidedHRVCheckContent(state: state, send: send).mgTheme(theme)
            } else {
                GuidedHRVCheckContent(state: state, send: send)
            }
        }
    }
}

private struct GuidedHRVCheckContent: View {
    let state: HRVCheckState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                GuidedTopBar(kicker: "HRV check · \(state.minutes) min", title: "HRV check", closeLabel: closeLabel) {
                    send(.guided(.close))
                }
                .padding(.top, 12)

                switch state.phase {
                case .ready:
                    ready
                case .measuring:
                    measuring
                case .result:
                    result
                case .blocked:
                    blocked
                }
            }
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .environment(\.mgSend, send)
        .onChange(of: state.phase, initial: true) { _, phase in
            GuidedIdleTimer.keepAwake(phase == .measuring)
        }
        .onDisappear { GuidedIdleTimer.keepAwake(false) }
    }

    private var closeLabel: String {
        state.phase == .measuring ? "Cancel and close — nothing is saved" : "Close HRV check"
    }

    // MARK: Ready

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.instruction)
                .mgFont(.body)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            SectionHeader("How long", note: "a tap starts it")
            lengthChips
            heartRateCard
                .padding(.top, 16)
        }
    }

    private var lengthChips: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(minuteChoices, id: \.self) { m in
                Chip("\(m) min") { send(.startHRVCheck(minutes: m)) }
                    .accessibilityHint("Starts a \(m)-minute reading")
            }
        }
    }

    private var minuteChoices: [Int] {
        let base = state.minuteOptions.filter { HRVCheckState.minuteRange.contains($0) }
        return base.isEmpty ? Array(HRVCheckState.minuteRange) : base
    }

    // MARK: Measuring

    private var measuring: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                GuidedCountdown(start: state.startedAt, end: state.endsAt, plannedMinutes: state.minutes)
                Text("left")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
            }
            .padding(.top, 24)
            if let start = state.startedAt, let end = state.endsAt, start < end {
                ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(colors.ink.color)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
            GuidedNote(state.instruction)
                .padding(.top, 12)

            heartRateCard
                .padding(.top, 16)

            gateCard
                .padding(.top, 12)

            MGButton("End now", style: .ghost) { send(.guided(.endNow)) }
                .padding(.top, 18)
                .accessibilityHint("Stops and shows what the beats so far give")
        }
    }

    private var heartRateCard: some View {
        MGCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text("Heart rate")
                        .mgFont(.rowTitle)
                        .foregroundStyle(colors.ink.color)
                    Spacer(minLength: 8)
                    ValueView(state.heartRate, size: .number, showsReceipt: true)
                        .frame(maxWidth: 170, alignment: .trailing)
                }
                if let beats = state.beats {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(beats)")
                            .mgFont(.number)
                            .foregroundStyle(colors.ink.color)
                        Text(beatsCaption(beats))
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// "R-R beats so far · 1 flagged (ALG-004)".
    private func beatsCaption(_ beats: Int) -> String {
        let noun = beats == 1 ? "R-R beat so far" : "R-R beats so far"
        guard let flagged = state.flagged else { return noun }
        return "\(noun) · \(flagged) flagged (ALG-004)"
    }

    private var gateCard: some View {
        MGCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    GuidedStatusDot(tone: state.gate.tone)
                    Text(gateTitle)
                        .mgFont(.rowTitle)
                        .foregroundStyle(colors.ink.color)
                }
                GuidedNote(state.gate.line)
                Text(state.gate.rule)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var gateTitle: String {
        switch state.gate.status {
        case .waiting: return "Quality: collecting"
        case .passing: return "Quality: passing"
        case .failing: return "Quality: not passing"
        }
    }

    // MARK: Result

    @ViewBuilder private var result: some View {
        if let r = state.result {
            VStack(alignment: .leading, spacing: 0) {
                MGCard {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RMSSD")
                                .mgFont(.kicker)
                                .foregroundStyle(colors.ink2.color)
                            ValueView(r.rmssd, size: .big, showsReceipt: true)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                secondary("lnRMSSD", r.lnRmssd)
                                secondary("Coherence", r.coherence)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                secondary("lnRMSSD", r.lnRmssd)
                                secondary("Coherence", r.coherence)
                            }
                        }
                        if let comparison = r.comparison {
                            Text(comparison)
                                .mgFont(.body)
                                .foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            GuidedStatusDot(tone: r.passed ? .good : .warn)
                            GuidedNote(r.qualityLine)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 16)

                if !r.rows.isEmpty {
                    SectionHeader("This reading")
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(r.rows) { GuidedValueRow(item: $0) }
                    }
                }
                if let saved = r.savedNote {
                    GuidedNote(saved).padding(.top, 12)
                }
                again
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                MGCard { GuidedNote("Nothing was measured this time.") }
                    .padding(.top, 16)
                again
            }
        }
    }

    private func secondary(_ title: String, _ value: DisplayValue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .mgFont(.kicker)
                .foregroundStyle(colors.ink2.color)
            ValueView(value, size: .number, showsReceipt: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var again: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Again", note: "a tap starts it")
            lengthChips
            MGButton("Done", style: .filled) { send(.guided(.close)) }
                .padding(.top, 18)
        }
    }

    // MARK: Blocked

    private var blocked: some View {
        VStack(alignment: .leading, spacing: 0) {
            MGCard {
                Text(state.blankReason ?? "Can't measure right now (no reason given).")
                    .mgFont(.body)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)
            MGButton("Close", style: .filled) { send(.guided(.close)) }
                .padding(.top, 18)
        }
    }
}
