import SwiftUI
import MGContext
import MGDesign

// The 0.6 inner rings (ui-pitch DESIGN-TOKENS §6): WHOOP-style progress rings in the recessed well, `state.rings` in
// order, outermost first. Angle on the face is time of day; angle in the well is "how full", so the two never mix.
// Each ring: a full `ringTrack` circle, a 1.5-unit notch at 12, a clockwise fill from 12 in `colors.ring(kind)` with a
// progress-head dot (eaten dashed 5 / 3), a dotted track and no fill when `fraction` is nil, and the target bracket
// when the ring has one. Fills sweep in per MGMotion.ringSweep; under Reduce Motion they are drawn at once.
struct SundialRings: View {
    let rings: [DialRing]
    let metrics: SundialMetrics
    /// The ring whose sheet is open: its track brightens.
    let selected: DialRing.Kind?

    init(rings: [DialRing], metrics: SundialMetrics, selected: DialRing.Kind?) {
        self.rings = rings
        self.metrics = metrics
        self.selected = selected
    }

    var body: some View {
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.element.kind) { i, ring in
                SundialRingView(ring: ring, index: i, count: rings.count, metrics: metrics,
                                selected: ring.kind == selected)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SundialRingView: View {
    let ring: DialRing
    let index: Int
    let count: Int
    let metrics: SundialMetrics
    let selected: Bool

    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double

    /// `shown` starts at the ring's current fraction, so a ring that is already full does not sweep in from zero every
    /// time the Today tab appears (audit #17); it animates only when the fraction changes.
    init(ring: DialRing, index: Int, count: Int, metrics: SundialMetrics, selected: Bool) {
        self.ring = ring
        self.index = index
        self.count = count
        self.metrics = metrics
        self.selected = selected
        _shown = State(initialValue: min(max(ring.fraction ?? 0, 0), 1))
    }

    var body: some View {
        let m = metrics
        let r = m.units(SundialDesign.ringRadius(index: index, count: count, zone: m.zone))
        let width = m.units(SundialDesign.ringStep(count: count, zone: m.zone) * SundialDesign.ringWidthRatio)
        ZStack {
            SundialRingPaint(shown: shown, ring: ring, center: m.center, radius: r, width: width,
                             unit: m.scale, color: colors.ring(ring.kind).color, track: colors.ringTrack.color,
                             well: colors.well.color)
            // selectHalo: the tapped ring's track brightens while its sheet is open (0.15 s fade).
            Circle()
                .stroke(colors.ring(ring.kind).opacity(0.3).color, lineWidth: width)
                .frame(width: 2 * r, height: 2 * r)
                .position(m.center)
                .opacity(selected ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: selected)
        }
        .onChange(of: ring.fraction) { _, new in sweep(to: new) }
    }

    private func sweep(to value: Double?) {
        withAnimation(MGMotion.ringSweep(reduceMotion: reduceMotion, index: index)) {
            shown = min(max(value ?? 0, 0), 1)
        }
    }
}

/// One ring in dial coordinates; `shown` is the animated part.
private struct SundialRingPaint: View, Animatable {
    var shown: Double
    let ring: DialRing
    let center: CGPoint
    let radius: CGFloat
    let width: CGFloat
    /// Points per design unit.
    let unit: CGFloat
    let color: Color
    let track: Color
    let well: Color

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    var body: some View {
        Canvas { ctx, _ in
            let c = center, r = radius
            // f = 0…1 of the ring, clockwise from 12 (y grows downward, so a growing angle is clockwise).
            func point(_ f: Double, _ radius: CGFloat) -> CGPoint {
                let a = -Double.pi / 2 + 2 * Double.pi * f
                return CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * CGFloat(sin(a)))
            }
            func arc(_ from: Double, _ to: Double, _ radius: CGFloat) -> Path {
                var p = Path()
                let steps = max(2, Int((to - from) * 360))    // 1° segments
                p.move(to: point(from, radius))
                for i in 1...steps { p.addLine(to: point(from + (to - from) * Double(i) / Double(steps), radius)) }
                return p
            }

            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            guard ring.fraction != nil else {
                // No scale to fill against: a dotted track, no fill; the key and the sheet say why.
                ctx.stroke(circle, with: .color(track),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.01, width * 1.6]))
                return
            }
            ctx.stroke(circle, with: .color(track), lineWidth: width)

            // Strain target: a faint arc just outside the ring and a tick across it at each end.
            if let t = ring.target, t.upperBound > t.lowerBound {
                let outer = r + width / 2
                ctx.stroke(arc(t.lowerBound, t.upperBound, outer + 1.2 * unit), with: .color(color.opacity(0.45)),
                           lineWidth: max(1, 0.9 * unit))
                for f in [t.lowerBound, t.upperBound] {
                    var tick = Path()
                    tick.move(to: point(f, r - width / 2 - 0.6 * unit))
                    tick.addLine(to: point(f, outer + 1.8 * unit))
                    ctx.stroke(tick, with: .color(color), lineWidth: 1)
                }
            }

            // Fill: butt start so the notch at 12 stays crisp; the head dot rounds the leading end.
            if shown > 0.001 {
                let style = ring.kind == .eaten
                    ? StrokeStyle(lineWidth: width, lineCap: .butt, dash: [5 * unit, 3 * unit])
                    : StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .round)
                ctx.stroke(arc(0, min(shown, 0.999), r), with: .color(color), style: style)
            }

            // Notch at 12: cleared, so the well shows through (where every ring starts and ends).
            var notch = Path()
            notch.move(to: point(0, r - width / 2 - 0.5))
            notch.addLine(to: point(0, r + width / 2 + 0.5))
            var clear = ctx
            clear.blendMode = .clear
            clear.stroke(notch, with: .color(.black), lineWidth: 1.5 * unit)

            // Progress head: a dot a little wider than the ring, ringed in `well`.
            let d = width + 2
            let p = point(min(shown, 0.999), r)
            let head = Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
            ctx.fill(head, with: .color(color))
            ctx.stroke(head, with: .color(well), lineWidth: 1)
        }
    }
}
