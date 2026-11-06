import SwiftUI
import MGContext
import MGDesign

// Sleep expanded (Mo, Nov 5 2026), spec §A: the dashboard sleep card. Pure rendering of `SleepCardState`: provenance pill, the
// duration first and large, the window, "of X need", the score beside it (never above), a one-line hypnogram, at most three
// measured facts, one sentence, the physiology strip and the resolver's "also:" line. A tap opens the full breakdown (the Night
// page). Missing data is grey with its reason (the presenter wrote it); this view adds no figure and no unit.

struct SleepCardView: View {
    let card: SleepCardState
    let send: (UIIntent) -> Void

    @Environment(\.mgColors) private var colors

    var body: some View {
        // Nov 6 2026: the card keeps its look; "Process now" sits under the tappable part (a button inside a button label
        // does not take taps), inside the same surface.
        VStack(alignment: .leading, spacing: MGSpace.s) {
            Button { send(card.openIntent) } label: { content }
                .buttonStyle(MGPressButtonStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint("Opens the full sleep breakdown")
            if let process = card.processIntent {
                MGButton("Process now", weight: .filled) { send(process) }
            }
        }
        .padding(MGSpace.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mgSurface(.card, radius: MGRadius.card)
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: MGSpace.s) {
                header
                headline
                if card.phase == .downloading { downloadingBlock }
                if card.phase == .notProcessed, let have = card.haveLine {
                    Text(have).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                hypnogram
                if !card.facts.isEmpty { facts }
                if !card.story.isEmpty, card.durationText != nil || card.story != card.blankReason {   // not said twice
                    Text(card.story)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !card.physiology.isEmpty { physiology }
                if let also = card.alsoLine {
                    Text(also).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = card.fallbackNote {
                    Text(note).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Details ›").mgFont(.detail).foregroundStyle(colors.ink2.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// Downloading: a placeholder with the finished card's shape (nothing jumps when the numbers arrive) and the strap's own
    /// clock time reached, the percent and the time left.
    private var downloadingBlock: some View {
        VStack(alignment: .leading, spacing: MGSpace.s) {
            VStack(alignment: .leading, spacing: 4) {
                Text("0 h 00 asleep").mgFont(.title)
                RoundedRectangle(cornerRadius: 6, style: .continuous).frame(height: 22)
            }
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
            if let p = card.progress {
                if let f = p.fraction { ProgressView(value: f).tint(colors.ink.color) }
                Text(p.text).mgFont(.detail).foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: MGSpace.s) {
            Text("Sleep · Last night").mgFont(.label).foregroundStyle(colors.ink2.color)
            Spacer(minLength: MGSpace.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(card.pill)
                    .mgFont(.receipt)
                    .foregroundStyle(card.isFallback ? colors.ink.color : colors.ink2.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().stroke(colors.rule.color, lineWidth: 1))
                    .fixedSize(horizontal: false, vertical: true)
                if let badge = card.reviewBadge {
                    Text(badge).mgFont(.receipt).foregroundStyle(colors.ink.color)
                }
            }
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let duration = card.durationText {
            HStack(alignment: .firstTextBaseline, spacing: MGSpace.m) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(duration).mgFont(.title).foregroundStyle(colors.ink.color)
                        Text("asleep").mgFont(.detail).foregroundStyle(colors.ink2.color)
                    }
                    if let window = card.windowText {
                        Text([window, card.needText].compactMap { $0 }.joined(separator: " · "))
                            .mgFont(.detail).foregroundStyle(colors.ink2.color)
                    } else if let need = card.needText {
                        Text(need).mgFont(.detail).foregroundStyle(colors.ink2.color)
                    }
                }
                Spacer(minLength: MGSpace.s)
                if let score = card.scoreText {
                    Text(score).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        .multilineTextAlignment(.trailing)
                }
            }
        } else {
            Text(card.blankReason ?? "No night recorded yet.")
                .mgFont(.body).foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var hypnogram: some View {
        if !card.hypnogram.isEmpty {
            SleepMiniHypnogram(segments: card.hypnogram).frame(height: 22)
        } else if let note = card.hypnogramNote {
            Text(note).mgFont(.receipt).foregroundStyle(colors.mute.color)
        }
    }

    private var facts: some View {
        HStack(alignment: .top, spacing: MGSpace.s) {
            ForEach(card.facts) { SleepCellView(cell: $0, compact: true) }
        }
    }

    private var physiology: some View {
        HStack(alignment: .top, spacing: MGSpace.s) {
            ForEach(card.physiology) { SleepCellView(cell: $0, compact: true) }
        }
    }

    private var accessibilityText: String {
        var parts = ["Sleep, last night", card.pill]
        if let d = card.durationText { parts.append("\(d) asleep") }
        if let w = card.windowText { parts.append(w) }
        if let n = card.needText { parts.append(n) }
        if let b = card.reviewBadge { parts.append(b) }
        if card.durationText == nil, let r = card.blankReason { parts.append(r) }
        if let p = card.progress { parts.append(p.text) }
        if let h = card.haveLine { parts.append(h) }
        parts.append(card.story)
        if let a = card.alsoLine { parts.append(a) }
        if let n = card.fallbackNote { parts.append(n) }
        return parts.joined(separator: ". ")
    }
}

/// One figure of the sleep card or the breakdown: label, value (or the grey reason), caption (who measured it / what kind).
struct SleepCellView: View {
    let cell: SleepCell
    var compact = false

    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cell.label).mgFont(.receipt).foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            if let text = cell.text {
                Text(text).mgFont(compact ? .label : .rowTitle).foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = cell.caption {
                    Text(caption).mgFont(.receipt).foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("—").mgFont(compact ? .label : .rowTitle).foregroundStyle(colors.mute.color)
                if let reason = cell.reason {
                    Text(reason).mgFont(.receipt).foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The one-line hypnogram of the card: stages as bars on four levels (awake on top), in the stage colours. A strap-flag night
/// (asleep / awake only, `.unstaged`) is drawn in the sleep colour on one level, never as light sleep.
struct SleepMiniHypnogram: View {
    let segments: [StageSegment]

    @Environment(\.mgColors) private var colors

    var body: some View {
        Canvas { ctx, size in
            guard let a = segments.map(\.start).min(), let b = segments.map(\.end).max(), b > a else { return }
            let span = b.timeIntervalSince(a)
            let onlyFlag = !segments.contains { [.deep, .light, .rem].contains($0.stage) }
            let rowH = size.height / 4
            ctx.fill(Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 1)), with: .color(colors.rule.color))
            for seg in segments where seg.end > seg.start {
                let row: Int
                switch seg.stage {
                case .awake: row = 0
                case .rem: row = 1
                case .light: row = 2
                case .deep: row = 3
                case .unstaged: row = 2
                }
                let x0 = CGFloat(seg.start.timeIntervalSince(a) / span) * size.width
                let x1 = CGFloat(seg.end.timeIntervalSince(a) / span) * size.width
                let rect = CGRect(x: x0, y: CGFloat(row) * rowH + 1, width: max(1, x1 - x0), height: rowH - 2)
                let color: Color
                switch seg.stage {
                case .deep: color = colors.stageDeep.color
                case .light: color = colors.stageLight.color
                case .rem: color = colors.stageRem.color
                case .awake: color = colors.stageAwake.color
                case .unstaged: color = onlyFlag ? colors.mark(.sleep).color : colors.stageLight.color
                }
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}
