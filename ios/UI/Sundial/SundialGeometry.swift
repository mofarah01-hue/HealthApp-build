import Foundation
import CoreGraphics
import MGContext

// The Sundial's geometry (UX-SPEC §3.3; owner WP-12). Pure maths, no SwiftUI, so it can be checked by hand and mirrored
// in Python (the WP-12 report names the check).
//
// Convention (UX §3.3, prototype app/prototype/index.html `dial()` L518-523, Sundial mockup mockups/opus-v2-A.html):
//   noon at the top, 18 at the right, midnight at the bottom, 06 at the left.
//   θ = (h − 12) / 24 × 360°, measured from the top, clockwise on screen, normalised to 0 ..< 360.
//   point(h, r) = (cx + r·sin θ, cy − r·cos θ)          (screen y grows downward)
//   so 12:00 → 0° top · 18:00 → 90° right · 00:00 → 180° bottom · 06:00 → 270° left.
// `h` is the WALL-CLOCK hour in the phone's calendar (a DST night still puts 07:00 at the same place).

/// Sizes in design units (the prototype's 350-unit-wide dial), scaled to points by `SundialMetrics.scale`.
/// The track radius follows UX §3.3 ("dial radius ≈ 0.33 × width"): 0.33 × 350 = 115.5. Every other offset is the
/// prototype's (dial() L519-559), measured from the track.
enum SundialDesign {
    static let width: CGFloat = 350
    static let trackRadius: CGFloat = 115.5
    /// Outermost ring (hour labels) = track + 45; height = 2 × that + 20 (prototype Hd = 2·(R+45) + 20).
    static let height: CGFloat = 2 * (trackRadius + 45) + 20
    static let trackWidth: CGFloat = 13

    // Layer offsets from the track radius, inside → out (UX §3.3 layer table).
    static let caffeineOffset: CGFloat = -17
    static let rimOffset: CGFloat = 20
    static let hourTickInner: CGFloat = 27
    static let hourTickOuterSmall: CGFloat = 31
    static let hourTickOuterBig: CGFloat = 36
    static let hourLabelOffset: CGFloat = 45
    /// The now-hand runs from the well edge (92 = track − 23.5) to the rim dot; it never crosses the inner rings.
    static let handInner: CGFloat = wellRadius - trackRadius
    static let handOuter: CGFloat = 27
    static let cutoffInner: CGFloat = -22
    static let cutoffOuter: CGFloat = 8
    static let bedtimeHalf: CGFloat = 10
    /// Direct layer labels sit on one ring inside the caffeine dots (drawn only when no inner ring is on).
    static let labelOffset: CGFloat = -30
    /// The hub keeps clear of this half-width × half-height box around the centre when no inner ring is on.
    static let hubHalfWidth: CGFloat = 64
    static let hubHalfHeight: CGFloat = 38

    // 0.6 inner rings in a recessed well (ui-pitch DESIGN-TOKENS §6). Radii from the centre, not from the track.
    static let wellRadius: CGFloat = 92
    static let ringZoneOuter: CGFloat = 89
    static let ringZoneInner: CGFloat = 53
    static let ringStepMax: CGFloat = 9
    static let ringWidthRatio: CGFloat = 0.7
    /// With rings on, the hub text fits a 92-unit box inside this radius.
    static let hubRadius: CGFloat = 50
    /// A corner callout's tap area stops at this radius from the dial centre (audit UI-SCRUB-A §1 #9: the rim marks sit at
    /// radius 131-152, the hour ticks beyond).
    static let calloutKeepOutRadius: CGFloat = 150

    /// Ring spacing for `count` rings: min(9, 36 / n); in the magnified zone (MGContext `DialRingZone`) min(14, 63 / n).
    static func ringStep(count: Int, zone: DialRingZone = .standard) -> CGFloat {
        CGFloat(zone.step(count: count))
    }

    /// Centre radius of ring `index` (0 = outermost): 89 − step × (i + 0.5).
    static func ringRadius(index: Int, count: Int, zone: DialRingZone = .standard) -> CGFloat {
        CGFloat(zone.radius(index: index, count: count))
    }
}

/// Scaled geometry for one rendered size. `magnified` (round 8, T10023) is the full-width mode: the rings sit in the
/// wider `DialRingZone.magnified` and the hub text is left out.
struct SundialMetrics: Equatable {
    /// Points per design unit.
    let scale: CGFloat
    let magnified: Bool

    init(width: CGFloat, magnified: Bool = false) {
        scale = max(width, 1) / SundialDesign.width
        self.magnified = magnified
    }

    var zone: DialRingZone { magnified ? .magnified : .standard }

    var size: CGSize { CGSize(width: SundialDesign.width * scale, height: SundialDesign.height * scale) }
    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var trackRadius: CGFloat { SundialDesign.trackRadius * scale }

    /// Radius of a ring `offset` design units from the track.
    func radius(_ offset: CGFloat) -> CGFloat { (SundialDesign.trackRadius + offset) * scale }

    func units(_ designUnits: CGFloat) -> CGFloat { designUnits * scale }

    func point(hour: Double, offset: CGFloat) -> CGPoint {
        SundialGeometry.point(hour: hour, radius: radius(offset), center: center)
    }
}

enum SundialGeometry {
    /// θ in degrees, 0 ..< 360, from the top, clockwise: θ = (h − 12)/24 × 360.
    static func angleDegrees(hour: Double) -> Double {
        positiveMod((hour - 12) / 24 * 360, 360)
    }

    static func point(hour: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let a = angleDegrees(hour: hour) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(sin(a)), y: center.y - radius * CGFloat(cos(a)))
    }

    /// The inverse: which hour of the day (0 ..< 24) lies under `location`, and how far from the centre it is.
    static func hourAndRadius(at location: CGPoint, center: CGPoint) -> (hour: Double, radius: CGFloat) {
        let dx = Double(location.x - center.x)
        let dy = Double(location.y - center.y)
        let theta = positiveMod(atan2(dx, -dy) * 180 / .pi, 360)
        return (positiveMod(12 + theta / 15, 24), CGFloat((dx * dx + dy * dy).squareRoot()))
    }

    /// Wall-clock hour of `date` (0 ..< 24, with minutes and seconds as the fraction) in `calendar`'s time zone.
    static func hourOfDay(_ date: Date, calendar: Calendar) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }

    /// The clockwise sweep in hours from `start` to `end` on the 24-hour face.
    /// - end ≤ start → 0 (nothing to draw; never a full circle by accident).
    /// - a span of 23.98 h or more is capped at 23.98 h (a full ring would hide where it starts; prototype `A()` L521).
    /// - otherwise the wall-clock difference, wrapped past midnight (23:02 → 06:52 = 7.83 h, not 16.17 h).
    static func sweepHours(from start: Date, to end: Date, calendar: Calendar) -> Double {
        let duration = end.timeIntervalSince(start) / 3600
        guard duration > 0 else { return 0 }
        if duration >= 23.98 { return 23.98 }
        let wall = positiveMod(hourOfDay(end, calendar: calendar) - hourOfDay(start, calendar: calendar), 24)
        // A DST change can make the wall-clock sweep 0 or ~24 for a short span; trust the duration then.
        if wall == 0 || abs(wall - duration) > 1.5 { return min(duration, 23.98) }
        return wall
    }

    /// Points along an arc from `startHour`, clockwise for `sweep` hours, one point per ≤ 0.5° (≤ 1 pt at r = 120).
    /// Sampled as a polyline on purpose: SwiftUI's `addArc(clockwise:)` flag is inverted in flipped coordinates, and
    /// a polyline built from `point(hour:)` cannot get the direction wrong.
    static func arcPoints(startHour: Double, sweep: Double, radius: CGFloat, center: CGPoint) -> [CGPoint] {
        guard sweep > 0 else { return [] }
        let steps = max(2, Int((sweep * 15 / 0.5).rounded(.up)))
        return (0...steps).map { i in
            point(hour: startHour + sweep * Double(i) / Double(steps), radius: radius, center: center)
        }
    }

    static func positiveMod(_ x: Double, _ m: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
}
