import SwiftUI
import MGContext
import MGDesign

// The one standing consent at strap pairing (ARCHITECTURE D6, §4.4.2 step 6): may the app set the strap's clock on
// every connect? Setting it is a write to the strap, so it needs a yes from Mo; with a yes it is covered for good
// (`StrapLinkConfig.clockConsentAt`), with a no the app only reads the clock. Everything else that writes to the
// strap still goes through its own confirm sheet (see UnlockConfirmSheet.swift). Owner: WP-13.
//
// This view is an addition inside WP-13's folder: no work package names the consent screen, and the first-run
// checklist (ARCHITECTURE §9.4) needs one. WP-23 shows it when the pairing flow reaches the clock step, stores the
// time of a yes as `clockConsentAt`, and passes `.pairStrap` results through. `decide(true)` = allow.

struct StrapClockConsentSheet: View {
    let decide: (Bool) -> Void

    @Environment(\.mgTheme) private var theme
    @Environment(\.mgColors) private var colors
    /// r8h T4: set by either button. A swipe-down without a button counts as "Not now" (like the unlock sheet's "declined").
    @State private var decided = false

    init(decide: @escaping (Bool) -> Void) {
        self.decide = decide
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 14) {
                Text("Strap clock")
                    .mgFont(.kicker)
                    .foregroundStyle(colors.topText.color)
                Text("Let the app set the strap's clock?")
                    .mgFont(.title)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("The strap time-stamps every record with its own clock, and that clock drifts. When it connects, "
                     + "the app can write the current time to it, read the time back, and log the old value, the "
                     + "bytes sent and the read-back in the Strap write log.")
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Sent with response, then checked by reading it back; it must agree within 2 seconds.")
                    bullet("Nothing else is written to the strap without its own confirm sheet.")
                    bullet("If you say no, the app only reads the clock, and records keep the strap's own time.")
                }
                // r8h T4: stacked (the two together were wider than the line and wrapped).
                VStack(spacing: 10) {
                    MGButton("Allow clock set", style: .filled) { decided = true; decide(true) }
                    MGButton("Not now — only read it", style: .ghost) { decided = true; decide(false) }
                }
                .padding(.top, 6)
            }
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .onDisappear { if !decided { decided = true; decide(false) } }
        .mgTheme(theme)
        .preferredColorScheme(Theme.colors(for: theme).isDark ? .dark : .light)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").mgFont(.body).foregroundStyle(colors.ink2.color).accessibilityHidden(true)
            Text(text)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
