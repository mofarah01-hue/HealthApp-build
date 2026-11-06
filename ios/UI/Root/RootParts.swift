import SwiftUI
import UIKit
import MGContext
import MGDesign
import MGDomain

// WP-23a — small pieces of the root: the Today tab's sundial glyph (UX §1.4: "circle + hand, as the Sundial mockup
// tab"), the receipt popover (UX §10: long-press any number → method, ALG id, tier, computed on, at, citation), the
// one-line notice, and the waiting / blank / failed screens. Blank screens say why (UX §13), never a stand-in value.
//
// WRITTEN, NOT COMPILED.

enum RootTabGlyph {
    /// A 1.7 pt circle with one hand to the rim and a dot at its end, drawn once as a template image (tab tint applies).
    static let sundial: Image = {
        let size = CGSize(width: 25, height: 25)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.setLineWidth(1.7)
            c.setStrokeColor(UIColor.black.cgColor)
            c.setFillColor(UIColor.black.cgColor)
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            c.strokeEllipse(in: rect)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            // The hand at about 09:40 on a noon-at-the-top dial (UX §3.3): θ = (h − 12) / 24 × 360°.
            let theta = (9.67 - 12) / 24 * 2 * Double.pi
            let r = Double(rect.width / 2) - 2
            let tip = CGPoint(x: centre.x + CGFloat(sin(theta) * r), y: centre.y - CGFloat(cos(theta) * r))
            c.setLineCap(.round)
            c.move(to: centre)
            c.addLine(to: tip)
            c.strokePath()
            c.fillEllipse(in: CGRect(x: tip.x - 1.8, y: tip.y - 1.8, width: 3.6, height: 3.6))
        }
        return Image(uiImage: image.withRenderingMode(.alwaysTemplate))
    }()
}

/// UX §10 "receipt popover": method, ALG id, tier, computed on, at, citation.
struct RootReceiptSheet: View {
    let receipt: Receipt
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Where this number comes from")
                        .mgFont(.headline)
                        .foregroundStyle(colors.ink.color)
                    Spacer(minLength: 8)
                    MGButton("Done", style: .ghost, action: { dismiss() })
                }
                .padding(.top, 20)
                // r9v (UI-SCRUB L12): Mo's four terms (strap data / ours / WHOOP's numbers / Apple's numbers).
                row("Source", receipt.originText)
                row("Tier", receipt.tier.rawValue)
                row("At", "\(MGFormat.shortDate(receipt.at, calendar: calendar)) \(MGFormat.time(receipt.at, calendar: calendar))")
                row("Method", receipt.method ?? "not recorded")
                row("Citation", receipt.citation ?? "none recorded")
            }
            .padding(.bottom, 32)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .mgFont(.kicker)
                .foregroundStyle(colors.mute.color)
            Text(value)
                .mgFont(.body)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What was refused or failed, and why: a raised capsule for a few seconds (never a modal, UX §5), two lines at most.
/// R9f (UI-SCRUB-B N4): a tap shows all of it and keeps it on screen (`held`) until the next tap; the last five are listed in
/// Settings › Usage › Recent messages.
struct RootNotice: View {
    let text: String
    /// Showing in full and not timed out; set by `RootView`, which owns the copy so the 5 s timer cannot remove it.
    var held: Bool = false
    var toggle: () -> Void = {}
    @Environment(\.mgColors) private var colors

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink.color)
                    .multilineTextAlignment(.leading)
                    .lineLimit(held ? nil : 2)
                    .fixedSize(horizontal: false, vertical: held)
                if held {
                    Text("Tap to close")
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MGSpace.l)
            .padding(.vertical, MGSpace.s)
            .frame(minHeight: MGSpace.tapTarget)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(colors.sheet.color))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(colors.rule.color, lineWidth: 1))
            .mgShadow(.raised)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MGSpace.gutter)
        .accessibilityLabel(text)
        .accessibilityHint(held ? "Closes the message" : "Shows the whole message and keeps it open")
        .onAppear { UIAccessibility.post(notification: .announcement, argument: text) }
    }
}

/// While a state is being built (first launch, a push before its data arrived). R8e (N3/E12): a pushed screen passes
/// `giveUpAfter`; when nothing arrived by then it turns into a blank with a reason and a Back button, not an endless spinner.
struct RootLoading: View {
    let text: String
    let giveUpAfter: Double?
    @Environment(\.mgColors) private var colors
    @State private var gaveUp = false

    init(text: String, giveUpAfter: Double? = nil) {
        self.text = text
        self.giveUpAfter = giveUpAfter
    }

    var body: some View {
        if gaveUp {
            RootBlank(title: "Nothing to show yet",
                      reason: "\(text) No data arrived after \(Int(giveUpAfter ?? 0)) seconds. Go back and open it again; "
                      + "if it stays empty, Preferences › Working on says what the app is waiting for.",
                      showBack: true)
        } else {
            MGScreen {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(text)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 140)
            }
            .task {
                guard let limit = giveUpAfter else { return }
                try? await Task.sleep(for: .seconds(limit))
                if !Task.isCancelled { gaveUp = true }
            }
        }
    }
}

/// A screen with nothing to show, and the reason (UX §13). `showBack` adds a Back button (pushed screens).
struct RootBlank: View {
    let title: String
    let reason: String
    let showBack: Bool
    @Environment(\.mgColors) private var colors
    @Environment(\.dismiss) private var dismiss

    init(title: String, reason: String, showBack: Bool = false) {
        self.title = title
        self.reason = reason
        self.showBack = showBack
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .mgFont(.title)
                    .foregroundStyle(colors.ink.color)
                Text(reason)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                if showBack {
                    MGButton("Back", style: .ghost, action: { dismiss() })
                }
            }
            .padding(.top, 24)
        }
    }
}

/// The store could not be opened: say so plainly instead of crashing (Mo's rule: error flags that say what failed).
struct RootFailureView: View {
    let reason: String

    var body: some View {
        RootBlank(title: "MG couldn't start", reason: reason + "\n\nNothing was deleted. Restart the app; if this stays, "
                  + "the database file in the app's storage needs a look on the Mac.")
            .mgTheme(.cream)
    }
}

// MARK: R8e — keys for pushed screens (X1) and the pull-to-refresh hook

/// What a pushed screen is redrawn for (see `EquatableScreen`): its state, plus anything else the screen takes.
struct SettingsScreenKey: Equatable {
    let state: SettingsState
    let workingDetail: WorkingDetailState
    let testRuns: TestRunsState
    /// The strap page drawn as Settings' Device section (nil on Preferences).
    var strap: StrapSyncState?
}

/// A pushed screen that also draws from the theme.
struct ThemedScreenKey<S: Equatable>: Equatable {
    let state: S
    let theme: ThemeName
}

struct MatrixScreenKey: Equatable {
    let state: MatrixState
    let choices: [MatrixMetric]
}

/// Pull-to-refresh on Today: the rebuild and sync the pull waits for (set by `RootEnvironment`).
typealias RootPullRefresh = @MainActor @Sendable () async -> Void

private struct RootPullRefreshKey: EnvironmentKey {
    static let defaultValue: RootPullRefresh? = nil
}

extension EnvironmentValues {
    var mgPullRefresh: RootPullRefresh? {
        get { self[RootPullRefreshKey.self] }
        set { self[RootPullRefreshKey.self] = newValue }
    }
}
