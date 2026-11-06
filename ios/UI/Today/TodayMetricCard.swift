import SwiftUI
import MGContext
import MGDesign

// T96: a metric Mo picked for Today (Settings › Front page › Metrics on Today), drawn in the form he chose (0.6, P05):
// a tile (the Today-so-far tile), a graph (a 96 pt card: name and value over its recent days, the newest a dot) or the
// bare number on one line. Pure rendering of `MetricCardState`; a tap opens the metric (Explore).

struct TodayMetricCard: View {
    let card: MetricCardState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        switch card.form {
        case .tile:
            MetricTile(label: card.name, value: card.value, caption: card.caption, size: .large) { send(card.intent) }
                .accessibilityHint("Opens \(card.name)")
        case .graph:
            Button { send(card.intent) } label: {
                VStack(alignment: .leading, spacing: MGSpace.s) {
                    HStack(alignment: .firstTextBaseline, spacing: MGSpace.s) {
                        Text(card.name)
                            .mgFont(.label)
                            .foregroundStyle(colors.ink2.color)
                            .lineLimit(2)
                        Spacer(minLength: MGSpace.s)
                        ValueView(card.value, size: .number)
                    }
                    SparklineView(values: card.series, accent: .ink2, width: nil, height: 40, lineWidth: 2)
                        .overlay { SparkEndDot(values: card.series, color: colors.mark(.ink2).color) }
                    if let caption = card.caption { captionText(caption) }
                }
                .padding(MGSpace.tileInset)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                .mgSurface(.tile)
                .contentShape(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous))
            }
            .buttonStyle(MGPressButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens \(card.name)")
        case .number:
            Button { send(card.intent) } label: {
                VStack(alignment: .leading, spacing: MGSpace.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: MGSpace.m) {
                        Text(card.name)
                            .mgFont(.rowTitle)
                            .foregroundStyle(colors.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: MGSpace.s)
                        ValueView(card.value, size: .big)
                    }
                    if let caption = card.caption { captionText(caption) }
                }
                .padding(.vertical, MGSpace.s)
                .frame(maxWidth: .infinity, minHeight: MGSpace.rowMinHeight, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens \(card.name)")
        }
    }
}

extension TodayMetricCard {
    /// T9838 / T9890: the draw date and source of a lab, or the date of a daily metric's last value.
    fileprivate func captionText(_ text: String) -> some View {
        Text(text)
            .mgFont(.label)
            .foregroundStyle(colors.ink2.color)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The newest value of a `SparklineView` as a 6 pt dot, placed with the sparkline's own scaling (2 pt inset). Drawn
/// on a canvas 3 pt larger on every side, so a dot at the edge is not cut in half.
private struct SparkEndDot: View {
    let values: [Double?]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let known = values.compactMap { $0 }
            guard known.count >= 2, values.count >= 2, let lo = known.min(), let hi = known.max(),
                  let i = values.lastIndex(where: { $0 != nil }), let v = values[i] else { return }
            let span = (hi - lo) == 0 ? 1 : (hi - lo)
            let w = size.width - 6, h = size.height - 6
            let p = CGPoint(x: 3 + CGFloat(i) / CGFloat(values.count - 1) * w,
                            y: 3 + h - 2 - CGFloat((v - lo) / span) * (h - 4))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color))
        }
        .padding(-3)
        .accessibilityHidden(true)
    }
}
