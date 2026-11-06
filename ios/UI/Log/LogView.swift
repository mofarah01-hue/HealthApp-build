import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Log tab (UX-SPEC §7, WP-18). Pure rendering of `LogState` (built by WP-23's presenter); every tap is a `UIIntent`
// sent through `send`. Owner: WP-18.
//
// Scroll order: SampleBanner (pinned, SAMPLE mode only) · LogHeader · ConfirmList · LogItemList (stable order, only each
// row's button changes) · DaySpine · MonthGrid (collapsed). Overlay: an 8 s toast with Undo.
//
// Theme: RootView applies `.mgTheme(...)` above this view (LogState has no ThemeName), and may set `\.mgNow`.
// SAMPLE mode (ARCHITECTURE §4.12): every control that would write is disabled with its reason.

struct LogView: View {
    let state: LogState
    let catalogue: LogCatalogue
    let send: (UIIntent) -> Void

    init(state: LogState, catalogue: LogCatalogue = .standard, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.catalogue = catalogue
        self.send = send
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.mgNow) private var envNow
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @State private var toast: LogToast?
    /// R9f (G5): entries removed from the spine, newest first, so Restore outlasts the toast.
    @State private var removed: [LogRemovedEntry] = []

    private var canLog: Bool { !state.sample }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                LogHeader(now: envNow ?? Date(), confirmCount: state.confirmCount)
                    .padding(.top, 12)
                    .padding(.bottom, 14)

                if state.sample {
                    LogHint(LogIntents.sampleReason)
                        .padding(.bottom, 10)
                }

                if !state.confirmList.isEmpty {
                    LogConfirmList(items: state.confirmList, canAct: canLog, send: send)
                        .padding(.bottom, 10)
                }

                itemList

                SectionHeader("Today", note: "time it happened · time you logged it, if different")
                LogSpineView(entries: state.spine, canAct: canLog, send: send, announce: show)

                LogRecentlyRemovedView(items: removed, canAct: canLog) { item in
                    send(.undoRemove(id: item.id))
                    removed.removeAll { $0.id == item.id }
                }

                LogMonthGridView(grid: state.monthGrid, send: send)
            }
            .padding(.bottom, 96)   // room for the toast above the tab bar
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                LogToastView(toast: toast) { undo(toast) }
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Each toast lives 8 s (20 s with VoiceOver); a newer one replaces it (and restarts the clock).
        .task(id: toast?.id) {
            guard let current = toast else { return }
            let seconds = voiceOverOn ? LogToast.lifetimeVoiceOver : LogToast.lifetime
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, toast?.id == current.id else { return }
            withAnimation(MGMotion.moment(reduceMotion: reduceMotion)) { toast = nil }
        }
        .environment(\.mgSend, send)
        // r8h G2/K1: forms scroll without losing the keyboard on the first touch, and a Done key closes it.
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneBar()
    }

    // MARK: Rows

    /// Rows keep their order; each is a LogItemRow from the state, never re-sorted here.
    private var itemList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.items) { row in
                LogItemRowView(row: row, catalogue: catalogue, canLog: canLog, spine: state.spine, send: send,
                               announce: show)
            }
        }
        .overlay(alignment: .top) {
            if !state.items.isEmpty { Rectangle().fill(colors.rule.color).frame(height: 1) }
        }
    }

    // MARK: Toast

    private func show(_ new: LogToast) {
        withAnimation(MGMotion.moment(reduceMotion: reduceMotion)) { toast = new }
        if let gone = LogRemovedEntry(toast: new) { removed = LogRemovedEntry.adding(gone, to: removed) }
        AccessibilityNotification.Announcement(new.message).post()
    }

    private func undo(_ current: LogToast) {
        for intent in current.undo { send(intent) }
        if let gone = LogRemovedEntry(toast: current) { removed.removeAll { $0.id == gone.id } }
        withAnimation(MGMotion.moment(reduceMotion: reduceMotion)) { toast = nil }
    }
}

/// UX §7 row 1: the date and time in the kicker, "Log" in the serif title, "{n} to confirm" as a chip.
/// Header text uses `topText` (it sits on the brightest part of the Emerald glow).
struct LogHeader: View {
    let now: Date
    let confirmCount: Int

    init(now: Date, confirmCount: Int) {
        self.now = now
        self.confirmCount = confirmCount
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(MGFormat.kickerDate(now, calendar: calendar)) · \(LogText.time(now, calendar))")
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            HStack(alignment: .center, spacing: 8) {
                Text("Log")
                    .mgFont(.title)
                    .foregroundStyle(colors.ink.color)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if confirmCount > 0 {
                    // r8h G3: a plain label chip (it was a filled capsule in the button colour that did nothing).
                    Text("\(confirmCount) to confirm")
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink.color)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(Capsule().fill(colors.chip.color))
                        .accessibilityLabel("\(confirmCount) detected \(confirmCount == 1 ? "entry" : "entries") to confirm")
                }
            }
        }
    }
}
