import SwiftUI
import MGContext
import MGDesign

/// UX §3.2 row 6 (0.6, P05): at most three phase-ranked rows (UX §4.1), a rule between rows, no card. Each: letter
/// badge, title, two-line detail, one-line receipt, and on the right a filled pill ("Start", "Alarms ›") and/or a
/// chevron; tapping opens it in place with lines, a small chart, switches and actions. One open at a time is the
/// presenter's rule — the view sends `.toggleRow(id:)` and draws `isOpen` from state.
struct NowList: View {
    let rows: [NowRowState]
    let send: (UIIntent) -> Void

    init(rows: [NowRowState], send: @escaping (UIIntent) -> Void) {
        self.rows = rows
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.prefix(3)) { row in
                NowRowView(row: row, send: send)
            }
        }
        .overlay(alignment: .top) {
            if !rows.isEmpty { Rectangle().fill(colors.rule.color).frame(height: 1) }
        }
    }
}

struct NowRowView: View {
    let row: NowRowState
    let send: (UIIntent) -> Void

    init(row: NowRowState, send: @escaping (UIIntent) -> Void) {
        self.row = row
        self.send = send
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mgQuietHaptics) private var quietHaptics
    @State private var logTaps = 0

    /// Badge 40 + gap 12: where the text column and the opened panel start.
    private static let textInset: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: MGSpace.m) {
                Button {
                    guard row.expansion != nil else { return }
                    send(.toggleRow(id: row.id))
                } label: {
                    HStack(alignment: .center, spacing: MGSpace.m) {
                        LetterBadge(row.badge, accent: row.tone)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .mgFont(.rowTitle)
                                .foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = row.detail {
                                Text(detail)
                                    .mgFont(.body)
                                    .foregroundStyle(colors.ink2.color)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if row.receipt != nil || row.receiptNote != nil {
                                ReceiptLine(receipt: row.receipt, note: row.receiptNote)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.top, 2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(row.expansion == nil ? "" : (row.isOpen ? "open" : "closed"))
                .accessibilityHint(row.expansion == nil ? "" : (row.isOpen ? "Closes this row" : "Opens this row in place"))

                // The one-tap button ("Took it", "Start"); hidden when disabled (its reason shows when opened).
                if let b = row.button, b.enabled, let intent = b.intent {
                    MGButton(b.title, weight: .filled) {
                        logTaps += 1
                        send(intent)
                    }
                }
                if row.expansion != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.mute.color)
                        .rotationEffect(.degrees(row.isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, MGSpace.m)
            .frame(minHeight: MGSpace.rowMinHeight)

            if row.isOpen, let expansion = row.expansion {
                NowRowExpansionView(expansion: expansion, tone: row.tone, send: send)
                    .padding(.leading, NowRowView.textInset)
                    .padding(.bottom, MGSpace.l)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
        .animation(MGMotion.expand(reduceMotion: reduceMotion), value: row.isOpen)
        .mgLogHaptic(trigger: logTaps, quiet: quietHaptics)
    }
}

/// What a Now row shows when open, on a chip-filled panel: a small chart, lines, switches, actions, optionally its
/// methods strip. Text on the chip fill uses ink2, never mute (DESIGN-TOKENS §1 contrast note).
struct NowRowExpansionView: View {
    let expansion: NowRowExpansion
    let tone: InkTone
    let send: (UIIntent) -> Void

    init(expansion: NowRowExpansion, tone: InkTone, send: @escaping (UIIntent) -> Void) {
        self.expansion = expansion
        self.tone = tone
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.m) {
            if expansion.chart.compactMap({ $0 }).count >= 2 {
                VStack(alignment: .leading, spacing: MGSpace.xs) {
                    SparklineView(values: expansion.chart, accent: tone, width: nil, height: 48, lineWidth: 2)
                        .accessibilityHidden(true)
                    if let caption = expansion.chartCaption {
                        Text(caption)
                            .mgFont(.receipt)
                            .foregroundStyle(colors.ink2.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            ForEach(Array(expansion.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(expansion.toggles) { toggle in
                ToggleRowView(toggle: toggle, send: send)
            }

            if !expansion.actions.isEmpty {
                FlowLayout(spacing: MGSpace.s) {
                    ForEach(expansion.actions) { action in
                        if action.enabled, let intent = action.intent {
                            // Outline, not tonal: a tonal pill is the panel's own chip fill and would vanish.
                            MGButton(action.title, weight: .outline) { send(intent) }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title).mgFont(.button).foregroundStyle(colors.ink2.color.opacity(0.7))
                                if let why = action.disabledReason {
                                    Text(why)
                                        .mgFont(.detail)
                                        .foregroundStyle(colors.ink2.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isStaticText)
                        }
                    }
                }
            }

            if let methods = expansion.methods {
                MethodsStrip(state: methods, send: send)
            }
        }
        .padding(MGSpace.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mgSurface(.chip, radius: MGRadius.tile)
    }
}

/// A switch row inside an opened Now row ("Smart wake", "Listen tonight"). The switch shows state; flipping it
/// sends the presenter's intent for the new value.
struct ToggleRowView: View {
    let toggle: ToggleState
    let send: (UIIntent) -> Void

    init(toggle: ToggleState, send: @escaping (UIIntent) -> Void) {
        self.toggle = toggle
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        Toggle(isOn: Binding(get: { toggle.isOn }, set: { _ in send(toggle.intent) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(toggle.title).mgFont(.body).foregroundStyle(colors.ink.color)
                if let d = toggle.detail {
                    Text(d).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !toggle.enabled, let why = toggle.disabledReason {
                    Text(why).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(colors.focus.color)
        .disabled(!toggle.enabled)
        .frame(minHeight: MGSpace.tapTarget)
        .padding(.top, MGSpace.xs)
        .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
    }
}
