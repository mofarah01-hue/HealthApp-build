import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Night — the pushed screen for one night (UX-SPEC §8.2, §3.1 "dial night arc / Last night → Night"; owner WP-12).
///
/// Scroll order: kicker + title · hero "7 h 08 · of 8 h 10 needed · 1 h 02 short" · (blank reason) · stage-method switch
/// + hypnogram with confidence shading + its methods strip · lanes on the same clock (breathing events, sounds, SpO₂
/// byte, movement, strap sleep flag — as the state carries them) · details grid · regularity · naps today.
/// Pure rendering of `NightState`; every tap is a `UIIntent` through `send`. `theme` is optional: the host normally
/// applies `.mgTheme` above its NavigationStack; pass it when this screen is shown on its own (previews).
struct NightView: View {
    let state: NightState
    let theme: ThemeName?
    let send: (UIIntent) -> Void

    init(state: NightState, theme: ThemeName? = nil, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.theme = theme
        self.send = send
    }

    var body: some View {
        // The content reads the theme from the environment, so the theme goes on above it.
        Group {
            if let theme {
                NightScreenContent(state: state, send: send).mgTheme(theme)
            } else {
                NightScreenContent(state: state, send: send)
            }
        }
    }
}

private struct NightScreenContent: View {
    let state: NightState
    let send: (UIIntent) -> Void

    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.mgNow) private var now

    var body: some View {
        // 0.C-5: the shared window comes from the presenter; the view does no work over the lane marks.
        let clock = state.clockWindow.map { NightClock(window: $0) }
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                header
                hero
                    .padding(.top, 12)
                // The hero already prints the "Not processed yet" reason; the card is for the other blanks.
                if let reason = state.blankReason, state.fill != .notProcessed {
                    Text(reason)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(MGSpace.cardInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mgSurface(.card, radius: MGRadius.card)
                        .padding(.top, 14)
                }
                // Sleep expanded (spec §B 1-10): the breakdown leads the page; it covers the old details grid, regularity and naps.
                if let breakdown = state.breakdown {
                    SleepBreakdownView(state: breakdown)
                        .padding(.top, MGSpace.s)
                }
                if let panel = state.algorithmPanel {        // T100: sleep, tap for HRV, stages and how each method works
                    AlgorithmPanel(state: panel) { send(.selectMethod(groupId: "G-STAGE", variant: $0)) }
                        .padding(.top, MGSpace.section)
                }
                stages(clock)
                lanes(clock)
                if state.breakdown == nil {          // the breakdown already carries these three
                    details
                    regularity
                    naps
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .environment(\.mgSend, send)
    }

    // MARK: Header

    private var nightStart: Date? { state.stages.map(\.start).min() }
    private var nightEnd: Date? { state.stages.map(\.end).max() }
    private var dayDate: Date { nightEnd ?? state.day.start(in: calendar.timeZone).addingTimeInterval(12 * 3600) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(kicker)
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text(title)
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// "SUN 11 OCT · 11:02 PM → 6:52 AM" (the night belongs to its wake day, D13).
    private var kicker: String {
        var s = MGFormat.kickerDate(dayDate, calendar: calendar)
        if let a = nightStart, let b = nightEnd {
            s += " · \(MGFormat.time(a, calendar: calendar)) → \(MGFormat.time(b, calendar: calendar))"
        }
        return s
    }

    /// "Last night" when the screen's now is that wake day; otherwise "Night to Sunday".
    private var title: String {
        if let now, LocalDay(date: now, calendar: calendar) == state.day { return "Last night" }
        return "Night to \(MGFormat.weekdayTitle(dayDate, calendar: calendar))"
    }

    // MARK: Hero (APP-217, 262)

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // Hero text sits in the top glow on Emerald: `topText` (WP-07 contrast rule), not ink2 / mute.
                Text("Slept").mgFont(.kicker).foregroundStyle(colors.topText.color)
                ValueView(state.slept, size: .big)
                // T10011: where the figure comes from, in words (strap data / ours on the phone / ours on the PC).
                if !state.sourceLine.isEmpty {
                    HStack(spacing: 6) {
                        if state.fill == .strapFlag {
                            Circle().fill(colors.mark(.sleep).color).frame(width: 8, height: 8)
                                .accessibilityHidden(true)
                        }
                        Text(state.sourceLine).mgFont(.detail).foregroundStyle(colors.topText.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
                // D-SLEEP-PRIORITY-1: the other sources' totals, beside the headline, each labelled.
                if !state.alsoLine.isEmpty {
                    Text(state.alsoLine).mgFont(.detail).foregroundStyle(colors.topText.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("of").mgFont(.detail).foregroundStyle(colors.topText.color)
                    ValueView(state.needed, size: .small)
                    Text("needed").mgFont(.detail).foregroundStyle(colors.topText.color)
                }
                if let short = state.shortBy {
                    Text(short).mgFont(.detail).foregroundStyle(colors.topText.color)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Stages + methods (G-STAGE)

    @ViewBuilder
    private func stages(_ clock: NightClock?) -> some View {
        // Night 4 (r8g): the dropdown in the Algorithm card above already picks the stage method, and the methods strip
        // below lists every method's total, so the third control (a capsule menu doing the same pick) is gone.
        SectionHeader(state.breakdown == nil ? "Stages" : "Stage methods", note: state.stageMethods?.title)
        if state.breakdown != nil {
            EmptyView()          // the explorer above already draws the headline's hypnogram
        } else if let clock, !state.stages.isEmpty {
            NightStageChart(stages: state.stages, clock: clock)
            if !stageLegend.isEmpty {
                Text(stageLegend)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        } else {
            Text(state.stagesNote ?? "No stages for this night.")
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let clock, state.stageCompare.count > 1 {
            SectionHeader("Strap flag, phone and PC", note: "same clock")
            NightStageCompare(rows: state.stageCompare, clock: clock)
        }
        if let group = state.stageMethods {
            MethodsStrip(state: group, send: send)
        }
    }

    /// Names only the codes this night uses: confidence shading, and the hatched "asleep, stage unknown" bar.
    private var stageLegend: String {
        var parts: [String] = []
        if state.stages.contains(where: { $0.confidence != nil }) {
            parts.append("paler = less sure · dotted outline = under half sure")
        }
        if state.stages.contains(where: { $0.stage == .unstaged }) {
            parts.append("hatched outline = asleep, stage unknown")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Lanes (ALG-023 breathing, ALG-024/025 sounds, ALG-021 SpO₂ byte, ALG-032 movement, strap flag)

    @ViewBuilder
    private func lanes(_ clock: NightClock?) -> some View {
        if !state.lanes.isEmpty {
            SectionHeader("On the same clock")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(state.lanes) { lane in
                    NightLaneRow(lane: lane, clock: clock)
                }
            }
        }
    }

    // MARK: Details grid (APP-261, ALG-150)

    @ViewBuilder
    private var details: some View {
        if !state.details.isEmpty {
            SectionHeader("Details")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .topLeading),
                                GridItem(.flexible(), spacing: 10, alignment: .topLeading)],
                      alignment: .leading, spacing: 10) {
                ForEach(state.details) { item in
                    NightValueCell(item: item, send: send)
                }
            }
        }
    }

    // MARK: Regularity (APP-263, ALG-030) and naps (APP-042)

    private var regularity: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Regularity")
            ValueView(state.regularity, size: .number, showsReceipt: true)
        }
    }

    @ViewBuilder
    private var naps: some View {
        SectionHeader("Naps")
        if state.naps.isEmpty {
            Text("No naps.").mgFont(.detail).foregroundStyle(colors.ink2.color)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(state.naps) { item in
                    NightValueCell(item: item, send: send)
                }
            }
        }
    }
}

/// One labelled value in Night's grid or nap list; tappable when the state gives an intent.
struct NightValueCell: View {
    let item: LabeledValue
    let send: (UIIntent) -> Void

    @Environment(\.mgColors) private var colors

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(item.label)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            ValueView(item.value, size: .number)
            if let caption = item.caption {
                Text(caption).mgFont(.receipt).foregroundStyle(colors.mute.color)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: MGSpace.rowMinHeight, alignment: .topLeading)
        .mgSurface(.card, radius: MGRadius.chip)

        if let intent = item.intent {
            Button { send(intent) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}
