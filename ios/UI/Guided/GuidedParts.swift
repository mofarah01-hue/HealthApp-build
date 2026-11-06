import SwiftUI
import MGContext
import MGDesign
import MGDomain
#if canImport(UIKit)
import UIKit
#endif

// Shared pieces of the two guided flows (Breathe pacer, HRV spot check). Owner: WP-29.
// Pure rendering: wording and layout only; every value comes from the flow's state.

/// Kicker + serif title on the left, a round close button on the right (the flows are full-screen covers).
struct GuidedTopBar: View {
    let kicker: String
    let title: String
    /// VoiceOver label of the close button ("Close" / "Stop and close — nothing is saved").
    let closeLabel: String
    let onClose: () -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // Top of the screen sits in the Emerald glow: `topText`, never mute (WP-07 contrast rule).
                Text(kicker)
                    .mgFont(.kicker)
                    .foregroundStyle(colors.topText.color)
                Text(title)
                    .mgFont(.title)
                    .foregroundStyle(colors.ink.color)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.ink.color)
                    .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                    .background(Circle().fill(colors.chip.color))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(closeLabel)
        }
    }
}

/// One labelled value as a row: label (+ caption) left, the value with its receipt right. Blank shows "—" + reason.
struct GuidedValueRow: View {
    let item: LabeledValue
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = item.caption {
                    Text(caption)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            ValueView(item.value, size: .number, showsReceipt: true)
                .frame(maxWidth: 170, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .frame(minHeight: MGSpace.rowMinHeight, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small status dot (gate status, quality).
struct GuidedStatusDot: View {
    let tone: StatusTone
    @Environment(\.mgColors) private var colors

    var body: some View {
        Circle()
            .fill(colors.status(tone).color)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

/// A quiet paragraph in ink2 (instructions, notes).
struct GuidedNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    @Environment(\.mgColors) private var colors

    var body: some View {
        Text(text)
            .mgFont(.detail)
            .foregroundStyle(colors.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The countdown "4:12" to `end`, drawn by the system timer text (no clock maths in the view). Falls back to the
/// planned length when the flow has no clock yet.
struct GuidedCountdown: View {
    let start: Date?
    let end: Date?
    let plannedMinutes: Int
    @Environment(\.mgColors) private var colors

    var body: some View {
        Group {
            if let start, let end, start <= end {
                Text(timerInterval: start...end, countsDown: true, showsHours: false)
            } else {
                Text("\(plannedMinutes):00")
            }
        }
        .mgFont(.bigNumber)
        .foregroundStyle(colors.ink.color)
        .accessibilityLabel("Time left")
    }
}

/// Wording shared by the flows.
enum GuidedText {
    /// 6 → "6", 5.5 → "5.5" (a pacer rate).
    static func rate(_ perMinute: Double) -> String {
        guard perMinute.isFinite else { return "—" }
        let whole = perMinute.rounded() == perMinute
        return MGFormat.number(perMinute, decimals: whole ? 0 : 1)
    }

    /// 5 → "5 s", 4.6 → "4.6 s".
    static func seconds(_ s: Double?) -> String {
        guard let s, s.isFinite else { return "—" }
        let whole = (s * 10).rounded() == s.rounded() * 10
        return MGFormat.number(s, decimals: whole ? 0 : 1) + " s"
    }

    /// What the haptics do now, in words: Mo's preference, then the quiet hours (UX §1.4).
    static func haptics(preference: Bool, quiet: Bool) -> String {
        if !preference { return "Haptics off — follow the circle." }
        if quiet { return "No haptics at night (quiet hours) — follow the circle." }
        return "A soft tap on the iPhone at each turn."
    }
}

/// Keeps the screen awake while a flow runs (a 5-min pacer outlasts the auto-lock). Set on, then off on exit.
enum GuidedIdleTimer {
    static func keepAwake(_ on: Bool) {
        #if canImport(UIKit)
        Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = on }
        #endif
    }
}
