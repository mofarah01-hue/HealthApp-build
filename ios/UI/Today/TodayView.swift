import SwiftUI
import MGContext
import MGDesign

// Today — the first thing Mo sees after waking (UX-SPEC §3.2 scroll order, §4 front and centre, §5 the peek).
// Pure rendering of `TodayState` (built by WP-23's presenter from MGContext's `DayContext`); every tap is a
// `UIIntent` sent through `send`. Owner: WP-07.
//
// Scroll order: SampleBanner (pinned) · TodayHeader · MomentCard? · the cards in Mo's order (Settings › Front page,
// tracker #34; default: verdict · Today so far · Sundial · recovery · focus · Now list · last night · alarm · battery ·
// quick log) · Footer; overlay: PeekCard.

struct TodayView: View {
    let state: TodayState
    let send: (UIIntent) -> Void

    init(state: TodayState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mgPullRefresh) private var pullRefresh      // R8e: the pull waits for the sync
    @State private var peekVisible = false
    /// True while a finger is scrubbing or stepping on the Sundial: the page must not scroll under it (T10021).
    @State private var scrubbing = false

    var body: some View {
        MGScreen(scrollDisabled: scrubbing) {
            // r9v (UI-SCRUB C6/T3): lazy, so cards below the fold are built when scrolled to.
            LazyVStack(alignment: .leading, spacing: 0) {
                TodayHeader(header: state.header, send: send)
                    .padding(.top, MGSpace.m)
                    .padding(.bottom, MGSpace.xl)

                if let moment = state.moment {
                    MomentCard(moment: moment, send: send)
                        .padding(.bottom, MGSpace.xl)
                        .transition(.opacity)
                }

                // Mo's order and choice of cards (Settings › Front page, tracker #34); header, moment card and footer
                // stay fixed.
                ForEach(Array(state.cards.enumerated()), id: \.element.id) { index, card in
                    TodayCardView(card: card, state: state, send: send, scrubbing: $scrubbing)
                        .padding(.top, TodayCardView.topSpacing(card, after: index == 0 ? nil : state.cards[index - 1]))
                }

                TodayFooter(footer: state.footer, send: send)
                    .padding(.top, MGSpace.section)
            }
            // Room under the footer so the peek never hides the last row for good.
            .padding(.bottom, state.peek == nil ? 40 : 230)
            .animation(MGMotion.moment(reduceMotion: reduceMotion), value: state.moment?.kind)
        }
        .refreshable {                    // UX §10: pull down = reconnect strap + try sync; R8e: waits for it (max 20 s)
            if let pullRefresh { await pullRefresh() } else { send(.refresh) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .overlay(alignment: .bottom) {
            if let peek = state.peek, peekVisible {
                PeekCard(state: peek, send: send)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(reduceMotion ? .opacity
                                : .offset(y: MGMotion.peekOffset).combined(with: .opacity))
            }
        }
        // UX §1.4: the peek appears 1.2 s after Today settles; a new question waits again.
        .task(id: state.peek?.kind) {
            peekVisible = false
            guard state.peek != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(MGMotion.peekDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(MGMotion.peek(reduceMotion: reduceMotion)) { peekVisible = true }
        }
        .environment(\.mgNow, state.dial.now)
        .environment(\.mgSend, send)
        .mgTheme(state.theme)
    }
}

/// "Everything else is in Explore ›" (UX §3.2 row 9).
struct TodayFooter: View {
    let footer: FooterState
    let send: (UIIntent) -> Void

    init(footer: FooterState, send: @escaping (UIIntent) -> Void) {
        self.footer = footer
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        Button { send(footer.intent) } label: {
            Text(footer.text)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .frame(maxWidth: .infinity, minHeight: MGSpace.tapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, MGSpace.xs)
        .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
    }
}

/// One quiet line under the verdict: which models aren't producing values today. Tapping opens Model status.
struct TodayModelStatusLine: View {
    let action: ActionState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        Button { if let i = action.intent { send(i) } } label: {
            Text(action.title)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .underline()
                .frame(maxWidth: .infinity, minHeight: MGSpace.tapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the status of every model")
    }
}

/// One front-page card (`TodayCard`). Verdict, dial and quick log draw from `TodayState`'s own fields; the rest carry
/// their state. Contents are their presenters' — this view only places them.
struct TodayCardView: View {
    let card: TodayCard
    let state: TodayState
    let send: (UIIntent) -> Void
    /// Set by the Sundial while a finger is on it; Today turns page scrolling off with it.
    var scrubbing: Binding<Bool> = .constant(false)

    var body: some View {
        switch card {
        case .verdict:
            VStack(alignment: .leading, spacing: 0) {
                VerdictBlock(verdict: state.verdict, send: send)
                if let methods = state.methods {
                    MethodsStrip(state: methods, send: send)
                        .padding(.top, MGSpace.m)
                }
                // "2 models not running · 54 not built or blocked ›" → Model status (Mo 2026-10-11).
                if let line = state.modelStatus {
                    TodayModelStatusLine(action: line, send: send)
                        .padding(.top, MGSpace.xs)
                }
            }
        case .dial:
            // The 24-hour dial is WP-12's view (UI/Sundial). Callout taps reach `send` via \.mgSend.
            SundialView(state: state.dial, scrubbing: scrubbing)
        case .now(let rows):
            NowList(rows: rows, send: send)
        case .strip(let strip):
            TodayStripView(strip: strip, collapsible: true, send: send)
        case .row(let row):
            NowList(rows: [row], send: send)
        case .quickLog:
            QuickLogBar(state: state.quickLog, send: send)
        case .metric(let metric):
            TodayMetricCard(card: metric, send: send)
        }
    }

    /// Space above a card (0.6: one section gap, 28): row cards that follow each other read as one list, picked
    /// metrics stack 8 apart, and the quick log's `SectionHeader` carries its own gap.
    static func topSpacing(_ card: TodayCard, after previous: TodayCard?) -> CGFloat {
        guard let previous else { return 0 }
        switch (card, previous) {
        case (.row, .row), (.row, .now), (.now, .row): return 0
        case (.metric, .metric): return MGSpace.s
        case (.quickLog, _): return 0
        default: return MGSpace.section
        }
    }
}
