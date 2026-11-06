import SwiftUI
import MGContext

/// One live state at the top of Today (UX §4.2, §5): one line + one action; never a question.
/// ARCHITECTURE §4.8: `MomentCard(moment:send:)`. Other live states fold into "+n more".
public struct MomentCard: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let moment: MomentViewState
    private let send: (UIIntent) -> Void

    public init(moment: MomentViewState, send: @escaping (UIIntent) -> Void) {
        self.moment = moment
        self.send = send
    }

    /// Progress only (no action, no live value, no trace): the compact 64 pt layout.
    private var isCompact: Bool {
        moment.progress != nil && moment.actionTitle == nil && moment.secondaryActionTitle == nil
            && moment.liveValue == nil && moment.trace.count < 2
    }

    public var body: some View {
        Group {
            if isCompact { compact } else { full }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mgSurface(.card, radius: MGRadius.moment, shadow: true)
        .accessibilityElement(children: .contain)
    }

    /// Kicker left, trailing text right, one line, a 3 pt bar in the sleep colour on `trackPale`.
    private var compact: some View {
        let p = min(max(moment.progress ?? 0, 0), 1)
        let trailing = [moment.trailing, moment.extraCount > 0 ? "+\(moment.extraCount) more" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(moment.title)
                    .mgFont(.kicker)
                    .foregroundStyle(colors.text(moment.tone).color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !trailing.isEmpty { Text(trailing).mgFont(.receipt).foregroundStyle(colors.ink2.color) }
            }
            Text(moment.line)
                .mgFont(.detail)
                .foregroundStyle(colors.ink.color)
                .lineLimit(1)
            Capsule().fill(colors.trackPale.color)
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(colors.sleep.color).frame(width: geo.size.width * p)
                    }
                }
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((p * 100).rounded())) percent")
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Kicker row: "STRAP OFF · SINCE 15:12" … "28 min"
            HStack(alignment: .firstTextBaseline) {
                Text(moment.title)
                    .mgFont(.kicker)
                    .foregroundStyle(colors.text(moment.tone).color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let t = moment.trailing {
                    Text(t).mgFont(.receipt).foregroundStyle(colors.ink2.color)
                }
            }
            .accessibilityElement(children: .combine)

            if let live = moment.liveValue {
                HStack(alignment: .center, spacing: 10) {
                    ValueView(live, size: .big)
                    PulseDot(bpm: MomentCard.bpm(from: live), color: colors.body, reduceMotion: reduceMotion)
                    Spacer(minLength: 4)
                    Text(moment.line)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } else {
                Text(moment.line)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }

            if let d = moment.detail {
                Text(d)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }

            if let p = moment.progress {
                ProgressView(value: min(max(p, 0), 1))
                    .tint(colors.mark(moment.tone).color)
                    .padding(.top, 8)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(Int((min(max(p, 0), 1) * 100).rounded())) percent")
            }

            if moment.trace.count >= 2 {
                TraceLine(values: moment.trace, color: colors.live)
                    .frame(height: 34)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }

            if moment.actionTitle != nil || moment.secondaryActionTitle != nil || moment.receipt != nil {
                FlowLayout(spacing: 8) {
                    if let title = moment.actionTitle, let intent = moment.action {
                        MGButton(title, style: .filled) { send(intent) }
                    }
                    if let title = moment.secondaryActionTitle, let intent = moment.secondaryAction {
                        MGButton(title, style: .ghost) { send(intent) }
                    }
                    if let r = moment.receipt { ReceiptLabel(r).frame(minHeight: MGSpace.tapTarget) }
                }
                .padding(.top, 10)
            }

            if moment.extraCount > 0 {
                Text("+\(moment.extraCount) more")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.ink2.color)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Beats per minute from a live HR value ("138"), for the pulse-dot rhythm.
    static func bpm(from value: DisplayValue) -> Double? {
        guard case let .value(text, _, _, _, _) = value, let v = Double(text), v > 20, v < 250 else { return nil }
        return v
    }
}

/// The live pulse dot: scale 1 → 1.18 → 1 once per beat (Satin "pop", UX §1.4). Still under Reduce Motion.
struct PulseDot: View {
    let bpm: Double?
    let color: MGRGBA
    let reduceMotion: Bool

    var body: some View {
        Group {
            if reduceMotion || bpm == nil {
                dot(scale: 1)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    dot(scale: PulseDot.scale(at: context.date.timeIntervalSinceReferenceDate, bpm: bpm ?? 60))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func dot(scale: CGFloat) -> some View {
        Circle()
            .fill(color.color)
            .frame(width: 9, height: 9)
            .background(Circle().fill(color.opacity(0.22).color).frame(width: 17, height: 17))
            .scaleEffect(scale)
    }

    /// Up to the peak in the first 12 % of the beat, back to 1 by 30 % (prototype `@keyframes pop`).
    static func scale(at t: TimeInterval, bpm: Double) -> CGFloat {
        let phase = (t * bpm / 60).truncatingRemainder(dividingBy: 1)
        let peak = MGMotion.pulseScale - 1
        if phase < 0.12 { return 1 + peak * CGFloat(phase / 0.12) }
        if phase < 0.30 { return 1 + peak * CGFloat(1 - (phase - 0.12) / 0.18) }
        return 1
    }
}

/// A plain polyline of recent samples (newest on the right), scaled to its own min…max.
struct TraceLine: View {
    let values: [Double]
    let color: MGRGBA

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return }
            let span = hi - lo == 0 ? 1 : hi - lo
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * size.width,
                                 y: size.height - 3 - CGFloat((v - lo) / span) * (size.height - 6))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(color.color), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
        }
    }
}
