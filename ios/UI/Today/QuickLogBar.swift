import SwiftUI
import MGContext
import MGDesign

/// UX §3.2 row 8 (0.6, P05): one-tap logs — the same pills all day (BRIEF default 9) as 44 pt tonal capsules with
/// their symbol, then "More ›" → Log tab. Detected vape hits waiting for a yes/no (ALG-046; never a pop-up) show as a
/// count badge on "More". A tap logs "happened now" with a light haptic, none at Night / Late night (UX §1.4).
struct QuickLogBar: View {
    let state: QuickLogState
    let send: (UIIntent) -> Void

    init(state: QuickLogState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.mgQuietHaptics) private var quietHaptics
    @State private var logTaps = 0
    /// r9v (UI-SCRUB T5): the pill just tapped, shown with Undo for 5 s (then it clears itself; no timer runs otherwise).
    @State private var justLogged: (id: Int, title: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Log", note: "one tap · happened now")
            FlowLayout(spacing: MGSpace.s, lineSpacing: MGSpace.s) {
                ForEach(state.pills) { pill in
                    Pill(pill.title, systemImage: pill.systemImage, weight: .tonal) {
                        logTaps += 1
                        justLogged = (logTaps, pill.title)
                        send(pill.intent)
                    }
                    .accessibilityHint("Logs it now")
                }
                Pill("More ›", weight: .tonal) { send(state.moreIntent) }
                    .overlay(alignment: .topTrailing) {
                        if state.confirmCount > 0 { confirmBadge.offset(x: 4, y: -4) }
                    }
                    .accessibilityLabel(state.confirmCount > 0
                                        ? "More logging options, \(state.confirmCount) to confirm"
                                        : "More logging options")
                    .accessibilityHint(state.confirmCount > 0 ? "Opens the Log tab to confirm detected entries" : "")
            }
            .padding(.top, 4)   // room for the badge
            if let logged = justLogged {
                HStack(spacing: MGSpace.s) {
                    Text("Logged \(logged.title)")
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                    Spacer(minLength: 0)
                    Button("Undo") {
                        send(.undoLastLog)
                        justLogged = nil
                    }
                    .mgFont(.body)
                    .foregroundStyle(colors.ink.color)
                    .underline()
                    .frame(minWidth: MGSpace.tapTarget, minHeight: MGSpace.tapTarget)
                    .contentShape(Rectangle())
                    .accessibilityHint("Removes the entry you just logged")
                }
                .padding(.top, MGSpace.xs)
                .accessibilityElement(children: .contain)
            }
        }
        .task(id: justLogged?.id) {
            guard justLogged != nil else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            justLogged = nil
        }
        .mgLogHaptic(trigger: logTaps, quiet: quietHaptics)
    }

    /// A body-colour dot with the number of detected entries waiting for a yes / no.
    private var confirmBadge: some View {
        Text("\(state.confirmCount)")
            .mgFont(MGTextStyle(family: .sans, size: 12, lineHeight: 14, weight: .semibold, relativeTo: .caption,
                                maxScale: 1.6))
            .foregroundStyle(colors.buttonText.color)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(colors.body.color))
            .accessibilityHidden(true)
    }
}
