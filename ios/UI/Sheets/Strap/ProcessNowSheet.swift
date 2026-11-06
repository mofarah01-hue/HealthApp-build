import SwiftUI
import MGContext
import MGDesign

// "Process now" (Mo, Nov 6 2026: a process button on the sleep card, to force the night to process now). Four steps, each with its
// own line; "Keep going in the background" closes the sheet and the run carries on; a failure says what was kept, names the
// fallback night when the card shows one, and offers Try again and Send details to the PC. The words are `ProcessNowState`'s.
// The screen is kept awake by the app while the sheet is open (AppModel.processSleepNow), and restored when it closes.

struct ProcessNowSheet: View {
    let close: () -> Void
    let tryAgain: () -> Void
    let sendDetails: () async -> Bool

    @ObservedObject private var model = ProcessNowModel.shared
    @Environment(\.mgTheme) private var theme
    @Environment(\.mgColors) private var colors
    @State private var sending = false
    @State private var sentNote: String?

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: MGSpace.m) {
                Text(state.title)
                    .mgFont(.sheetTitle)
                    .foregroundStyle(colors.ink.color)
                    .accessibilityAddTraits(.isHeader)
                if let failure = state.failure {
                    Text(failure).mgFont(.body).foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = state.fallbackLine {
                        Text(line).mgFont(.detail).foregroundStyle(colors.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: MGSpace.s) {
                        ForEach(state.steps) { step in row(step) }
                    }
                }
                actions(state)
                if let note = sentNote {
                    Text(note).mgFont(.detail).foregroundStyle(colors.ink2.color)
                }
            }
            .padding(.horizontal, MGSpace.gutter)
            .padding(.top, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.colors(for: theme).sheet.color.ignoresSafeArea())
        .mgTheme(theme)
        .preferredColorScheme(Theme.colors(for: theme).isDark ? .dark : .light)
        .presentationBackground(Theme.colors(for: theme).sheet.color)
        .presentationCornerRadius(MGRadius.sheet)
        .presentationDragIndicator(.visible)
    }

    private func row(_ step: ProcessNowState.Step) -> some View {
        HStack(alignment: .top, spacing: MGSpace.s) {
            Image(systemName: symbol(step.status))
                .foregroundStyle(step.status == .waiting ? colors.mute.color : colors.ink.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                if let detail = step.detail {
                    Text(detail).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([step.title, label(step.status), step.detail].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder private func actions(_ state: ProcessNowState) -> some View {
        if state.failure != nil {
            // One primary button; the rest are secondary.
            MGButton("Try again", weight: .filled, action: tryAgain)
            MGButton(sending ? "Sending…" : "Send details to the PC", weight: .tonal) {
                guard !sending else { return }
                sending = true
                Task {
                    let ok = await sendDetails()
                    sentNote = ok ? "Sent to the PC." : "The PC could not be reached. Nothing was lost; try again later."
                    sending = false
                }
            }
            MGButton("Close", weight: .tonal, action: close)
        } else if state.running {
            MGButton("Keep going in the background", weight: .tonal, action: close)
        } else {
            MGButton("Done", weight: .filled, action: close)
        }
    }

    private func symbol(_ s: ProcessNowState.Status) -> String {
        switch s {
        case .waiting: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func label(_ s: ProcessNowState.Status) -> String {
        switch s {
        case .waiting: return "waiting"
        case .running: return "in progress"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}
