import SwiftUI
import MGContext
import MGDesign

/// UX §3.2 row 1 (0.6, P05): the kicker "TUE 13 OCT · EVENING · WOKE 7:02 AM" (the presenter's `MGFormat.kicker`),
/// then the weekday in the serif title with the "M" (→ Preferences) and a gear (→ Settings) on the right, then one line of chips: the status
/// chip, "Open Settings" beside it when Bluetooth is off / not allowed (T141), the next-alarm chip and the "1 question"
/// chip. The chips wrap instead of squeezing the title.
/// Header text uses `topText`: it sits on the brightest part of the Emerald glow (ThemeColors.swift note 1).
struct TodayHeader: View {
    let header: HeaderState
    let send: (UIIntent) -> Void

    init(header: HeaderState, send: @escaping (UIIntent) -> Void) {
        self.header = header
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.xs) {
            Text(header.kicker)
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(TodayHeader.spokenKicker(header.kicker))

            HStack(alignment: .center, spacing: MGSpace.s) {
                Text(header.title)
                    .mgFont(.title)
                    .foregroundStyle(colors.ink.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                preferencesButton
                settingsButton
            }

            FlowLayout(spacing: MGSpace.s, lineSpacing: 0) {
                StatusChip(state: header.status, send: send)
                // T141: Bluetooth off / not allowed are fixed in iOS Settings, not in this app.
                if header.status.showOpenSettings {
                    OpenSettingsButton()
                }
                if let alarm = header.alarmChip {
                    // The next strap alarm within 24 h → the alarm page (2026-10-11).
                    chip(alarm, systemImage: "alarm") { send(.alarms(.open)) }
                        .accessibilityLabel("Next alarm \(alarm)")
                        .accessibilityHint("Opens the alarms")
                }
                if let question = header.questionChip {
                    chip(question, systemImage: "questionmark.bubble") { send(.openDeferredQuestion) }
                        .accessibilityHint("Shows the question you put off")
                }
            }
        }
    }

    /// The monogram: a 44 pt outlined circle, the whole circle is the target. T10022: it opens Preferences (you and how
    /// the app looks, what Mo opens more often); the gear beside it opens Settings (the system and its connections).
    private var preferencesButton: some View {
        Button { send(.openPreferences) } label: {
            Text("M")
                .mgFont(MGTextStyle(family: .serif, size: 18, lineHeight: 22, weight: .semibold,
                                    relativeTo: .headline, maxScale: 1.3))
                .foregroundStyle(colors.ink.color)
                .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                .background(Circle().strokeBorder(colors.rule.color, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(MGPressButtonStyle())
        .accessibilityLabel("Preferences")
    }

    /// A 44 pt outlined gear (S12): Settings.
    private var settingsButton: some View {
        Button { send(.openSettings) } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(colors.ink.color)
                .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                .background(Circle().strokeBorder(colors.rule.color, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(MGPressButtonStyle())
        .accessibilityLabel("Settings")
    }

    /// A 32 pt tonal capsule inside a 44 pt target.
    private func chip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
                Text(title).lineLimit(1)
            }
            .mgFont(.detail)
            .foregroundStyle(colors.ink.color)
            .padding(.horizontal, MGSpace.m)
            .frame(minHeight: 32)
            .background(Capsule().fill(colors.chip.color))
            .frame(minHeight: MGSpace.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(MGPressButtonStyle())
    }

    /// "SUN 11 OCT · MORNING · WOKE 6:52 AM" → "sun 11 oct, morning, woke 6:52 am" (VoiceOver spells some caps words).
    static func spokenKicker(_ kicker: String) -> String {
        kicker.lowercased().replacingOccurrences(of: " · ", with: ", ")
    }
}

/// UX §3.2 row 3: headline (`verdict`) + one sentence (`body`, ≤ 20 words) + the receipt on one line (tap = the
/// receipt in full). The UX §12 rules are the presenter's; this only draws them.
struct VerdictBlock: View {
    let verdict: VerdictState
    let send: (UIIntent) -> Void

    init(verdict: VerdictState, send: @escaping (UIIntent) -> Void = { _ in }) {
        self.verdict = verdict
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.s) {
            VStack(alignment: .leading, spacing: MGSpace.s) {
                Text(verdict.headline)
                    .mgFont(.verdict)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let sentence = verdict.sentence {
                    Text(sentence)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            // Outside the combined element so VoiceOver keeps these separate buttons.
            if let r = verdict.receipt {
                Button { send(.showReceipt(r)) } label: { receiptLine.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows where this comes from")
            } else if verdict.receiptNote != nil {
                receiptLine
            }
            if let action = verdict.action, let intent = action.intent {
                MGButton(action.title, weight: .filled) { send(intent) }
                    .disabled(!action.enabled)
                    .padding(.top, MGSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One line, truncated in the middle.
    private var receiptLine: some View {
        ReceiptLine(receipt: verdict.receipt, note: verdict.receiptNote)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
