import SwiftUI

/// One inner dial ring (0.6): fills clockwise from 12 o'clock with round caps and a progress-head dot.
/// `fraction` 0…1; nil = no scale to fill against, so only a dotted track is drawn. `target` (fractions of the
/// ring) draws two radial ticks and a faint arc just outside. `dashed` (eaten) draws the fill as 5 on / 3 off.
/// The fill sweeps per `MGMotion.ringSweep` (`index` 0 = outermost ring) on first appearance and on change; under
/// Reduce Motion it jumps. Decorative: the caller's chip or sheet carries the number and the VoiceOver text.
public struct RingGauge: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0
    private let fraction: Double?
    private let target: ClosedRange<Double>?
    private let color: Color
    private let track: Color
    private let lineWidth: CGFloat
    private let dashed: Bool
    private let index: Int

    public init(fraction: Double?, target: ClosedRange<Double>? = nil, color: Color, track: Color,
                lineWidth: CGFloat, dashed: Bool = false, index: Int = 0) {
        self.fraction = fraction
        self.target = target
        self.color = color
        self.track = track
        self.lineWidth = lineWidth
        self.dashed = dashed
        self.index = index
    }

    public var body: some View {
        RingPaint(shown: shown, hasFraction: fraction != nil, target: target, color: color, track: track,
                  well: colors.well.color, lineWidth: lineWidth, dashed: dashed)
            .onAppear { sweep(to: fraction) }
            .onChange(of: fraction) { _, new in sweep(to: new) }
            .accessibilityHidden(true)
    }

    private func sweep(to value: Double?) {
        withAnimation(MGMotion.ringSweep(reduceMotion: reduceMotion, index: index)) {
            shown = min(max(value ?? 0, 0), 1)
        }
    }
}

/// The drawing; its `shown` fraction is the animatable part.
private struct RingPaint: View, Animatable {
    var shown: Double
    let hasFraction: Bool
    let target: ClosedRange<Double>?
    let color: Color
    let track: Color
    let well: Color
    let lineWidth: CGFloat
    let dashed: Bool

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            // Room for the head dot (lineWidth + 2, plus its 1 pt ring) and, with a target, the arc outside.
            let inset = lineWidth / 2 + (target == nil ? 2 : 5)
            let radius = (min(size.width, size.height) - 2 * inset) / 2
            guard radius > 0 else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func point(_ f: Double, _ r: CGFloat) -> CGPoint {
                let a = -Double.pi / 2 + 2 * Double.pi * f    // y points down, so growing angle = clockwise
                return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            }
            func arc(_ from: Double, _ to: Double, _ r: CGFloat) -> Path {
                var p = Path()
                let steps = max(2, Int((to - from) * 180))    // 2° segments
                p.move(to: point(from, r))
                for i in 1...steps { p.addLine(to: point(from + (to - from) * Double(i) / Double(steps), r)) }
                return p
            }

            // Track: the full ring, or dots when there is no scale.
            let ring = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius))
            if hasFraction {
                ctx.stroke(ring, with: .color(track), lineWidth: lineWidth)
            } else {
                ctx.stroke(ring, with: .color(track), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                                                         dash: [0.01, lineWidth * 1.6]))
                return
            }

            // Target: two radial ticks across the ring and a faint arc just outside it.
            if let target {
                let outer = radius + lineWidth / 2
                ctx.stroke(arc(target.lowerBound, target.upperBound, outer + 2.5), with: .color(color.opacity(0.35)),
                           lineWidth: 2)
                for f in [target.lowerBound, target.upperBound] {
                    var tick = Path()
                    tick.move(to: point(f, radius - lineWidth / 2 - 1))
                    tick.addLine(to: point(f, outer + 1))
                    ctx.stroke(tick, with: .color(color), lineWidth: 1)
                }
            }

            // Fill.
            if shown > 0 {
                let style = dashed
                    ? StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .round,
                                  dash: [lineWidth * 0.8, lineWidth * 0.5])
                    : StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                ctx.stroke(arc(0, shown, radius), with: .color(color), style: style)
            }

            // Progress head: a dot of lineWidth + 2 with a 1 pt ring in `well`.
            let d = lineWidth + 2
            let head = Path(ellipseIn: CGRect(x: point(shown, radius).x - d / 2, y: point(shown, radius).y - d / 2,
                                              width: d, height: d))
            ctx.fill(head, with: .color(color))
            ctx.stroke(head, with: .color(well), lineWidth: 1)
        }
    }
}

/// The dial-key icon (20 pt): `count` concentric rings, all `trackPale` except the `highlighted` one, which takes
/// its entry of `colors` (ring 0 = outermost).
public struct ConcentricRingsIcon: View {
    @Environment(\.mgColors) private var colors
    private let count: Int
    private let highlighted: Int?
    private let ringColors: [Color]

    public init(count: Int, highlighted: Int?, colors: [Color]) {
        self.count = count
        self.highlighted = highlighted
        self.ringColors = colors
    }

    public var body: some View {
        Canvas { ctx, size in
            guard count > 0 else { return }
            let step = 9.0 / Double(count)
            let width = max(1.4, step * 0.75)
            for i in 0..<count {
                let r = 9.5 - step * (Double(i) + 0.5)
                let rect = CGRect(x: size.width / 2 - r, y: size.height / 2 - r, width: 2 * r, height: 2 * r)
                let paint = i == highlighted && i < ringColors.count ? ringColors[i] : colors.trackPale.color
                ctx.stroke(Path(ellipseIn: rect), with: .color(paint), lineWidth: width)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}
