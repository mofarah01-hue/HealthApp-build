import Foundation

// The Sundial's finger logic: pure maths, no SwiftUI (round 8, T10021 / T10023; audit UI-SCRUB-A §1 and §5).
//
// One touch on the dial is one `DialTouchTracker` run, and its state is one `DialInteraction`:
//   idle → undecided (finger down, not yet moved 8 pt) → ringStep(index) OR timeScrub(hour), decided ONCE.
// A touch that starts inside the well (hub or inner rings) and moves mostly along the radius steps from ring to ring;
// anything else that moves scrubs time. The mode never changes until the finger lifts (audit #4: it used to flip when
// the finger drifted across radius 96). A touch that never moves 8 pt is a tap. A release is never a tap once a
// scrub has begun (audit #8).
// Haptics belong to the view and fire only from changes of this state (audit #7). Words for a time come from
// `DialScrubIndex`. Coordinates here are points from the dial centre, y growing downward; radii in design units
// (the 350-unit-wide dial; `scale` = points per unit).

/// What the finger is doing on the dial.
public enum DialInteraction: Equatable, Sendable {
    case idle
    /// Finger down, direction not known yet (under 8 pt of movement).
    case undecided
    /// Stepping through the inner rings, 0 = outermost.
    case ringStep(index: Int)
    /// Scrubbing the clock; `hour` is the dial hour (0 ..< 24).
    case timeScrub(hour: Double)

    /// True once the touch has chosen scrub or step: the page must not scroll under it.
    public var isLocked: Bool {
        switch self {
        case .ringStep, .timeScrub: return true
        case .idle, .undecided: return false
        }
    }
}

/// Where the inner rings sit, in design units from the dial centre. Magnified mode (round 8, T10023) re-spaces them
/// into a wider zone: the hub text goes, so the rings may run in to radius 26 and each gets up to 14 units.
public struct DialRingZone: Equatable, Sendable {
    public var outer: Double
    public var inner: Double
    public var stepMax: Double
    /// Inside this radius is the hub: no ring, and the time scrub keeps its last hour.
    public var hubRadius: Double

    public init(outer: Double, inner: Double, stepMax: Double, hubRadius: Double) {
        self.outer = outer
        self.inner = inner
        self.stepMax = stepMax
        self.hubRadius = hubRadius
    }

    public static let standard = DialRingZone(outer: 89, inner: 53, stepMax: 9, hubRadius: 50)
    public static let magnified = DialRingZone(outer: 89, inner: 26, stepMax: 14, hubRadius: 22)

    /// Spacing between ring centres for `count` rings.
    public func step(count: Int) -> Double { min(stepMax, (outer - inner) / Double(max(count, 1))) }

    /// Centre radius of ring `index` (0 = outermost).
    public func radius(index: Int, count: Int) -> Double { outer - step(count: count) * (Double(index) + 0.5) }
}

public enum DialScrub {
    // MARK: Design numbers (mirror UI/Sundial/SundialGeometry `SundialDesign`; the UI target cannot be imported here)

    /// The recessed well that holds the hub and the inner rings.
    public static let wellRadius: Double = 92
    public static let hubRadius: Double = 50
    public static let ringZoneOuter: Double = 89
    public static let ringZoneInner: Double = 53
    public static let ringStepMax: Double = 9

    /// Spacing between ring centres for `count` rings: min(9, 36 / n).
    public static func ringStep(count: Int, zone: DialRingZone = .standard) -> Double { zone.step(count: count) }

    /// Under this fraction of the hub radius the angle is meaningless: the time scrub keeps its last hour (audit #6).
    public static let hubDeadFraction: Double = 0.35
    /// Movement (points) before the touch picks its mode.
    public static let lockPoints: Double = 8
    /// A ring changes only after the finger is this far into the next band (audit step 3: no flip on a thumb wobble).
    public static let ringHysteresis: Double = 0.6

    // MARK: Angle → time

    /// The dial's hour (0 ..< 24) at `(dx, dy)` from the centre, y growing downward: noon at the top, 18 at the right,
    /// midnight at the bottom, 06 at the left (SundialGeometry).
    public static func hour(dx: Double, dy: Double) -> Double {
        let theta = positiveMod(atan2(dx, -dy) * 180 / .pi, 360)
        return positiveMod(12 + theta / 15, 24)
    }

    // MARK: Radius → ring

    /// Where `radius` (design units) falls along the ring zone: 0 at the outer edge, 1 at the end of ring 0's band,
    /// `count` at the inner edge. Outside the zone it runs below 0 / above `count`.
    public static func ringPosition(radius: Double, count: Int, zone: DialRingZone = .standard) -> Double {
        (zone.outer - radius) / zone.step(count: count)
    }

    /// The ring (0 = outermost) for a finger at `radius`, with hysteresis: from ring `current` it moves to the next
    /// ring only once the finger is `ringHysteresis` of the way into that band, in either direction. With no current
    /// ring the plain band is taken. Beyond either end of the zone it holds the first / last ring.
    public static func ringIndex(radius: Double, count: Int, current: Int?, zone: DialRingZone = .standard) -> Int {
        guard count > 0 else { return 0 }
        let p = ringPosition(radius: radius, count: count, zone: zone)
        guard var c = current else { return min(max(Int(p.rounded(.down)), 0), count - 1) }
        c = min(max(c, 0), count - 1)
        while c < count - 1, p >= Double(c + 1) + ringHysteresis { c += 1 }
        while c > 0, p < Double(c) - ringHysteresis { c -= 1 }
        return c
    }

    // MARK: Positive modulo

    static func positiveMod(_ x: Double, _ m: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
}

/// What a finger lift meant.
public enum DialTouchOutcome: Equatable, Sendable {
    /// A tap at this spot (points from the centre): the finger never moved far enough to pick a mode.
    case tap(x: Double, y: Double)
    /// A scrub or ring step ended. Never a tap.
    case finished
    /// No touch was running (a cancel already cleared it).
    case none
}

/// One touch on the dial, from finger down to lift. A plain value: the view keeps it in `@State`, feeds it
/// `begin` / `move` / `end` from one DragGesture and shows `interaction`.
public struct DialTouchTracker: Sendable {
    public private(set) var interaction: DialInteraction = .idle
    /// Set the moment the touch locks into a scrub or ring step; cleared by the next `begin` (audit #8).
    public private(set) var didScrub = false

    private var active = false
    private var sx = 0.0, sy = 0.0
    private var scale = 1.0
    private var ringCount = 0
    private var zone = DialRingZone.standard
    private var lastHour = 12.0
    private var ring: Int?

    public init() {}

    /// Finger down at `(x, y)` points from the centre. `nowHour` is where the time scrub starts if the finger is in the
    /// dead zone of the hub when it locks.
    public mutating func begin(x: Double, y: Double, scale: Double, ringCount: Int, nowHour: Double,
                               zone: DialRingZone = .standard) {
        active = true
        didScrub = false
        sx = x
        sy = y
        self.scale = max(scale, 0.0001)
        self.ringCount = max(ringCount, 0)
        self.zone = zone
        lastHour = nowHour
        ring = nil
        interaction = .undecided
    }

    public mutating func move(x: Double, y: Double) {
        guard active else { return }
        switch interaction {
        case .idle:
            return
        case .undecided:
            let dx = x - sx, dy = y - sy
            guard (dx * dx + dy * dy).squareRoot() >= DialScrub.lockPoints else { return }
            didScrub = true
            let startR = (sx * sx + sy * sy).squareRoot() / scale
            if ringCount > 0, startR < DialScrub.wellRadius, startsRadial(dx: dx, dy: dy, startRadius: startR) {
                ring = DialScrub.ringIndex(radius: startR, count: ringCount, current: nil, zone: zone)
                stepRing(x: x, y: y)
            } else {
                scrubTime(x: x, y: y)
            }
        case .ringStep:
            stepRing(x: x, y: y)
        case .timeScrub:
            scrubTime(x: x, y: y)
        }
    }

    /// Finger up. Resets to idle.
    public mutating func end() -> DialTouchOutcome {
        defer { reset() }
        guard active else { return .none }
        if interaction == .undecided { return .tap(x: sx, y: sy) }
        return interaction.isLocked ? .finished : .none
    }

    /// The system took the touch (the scroll view, an alert): no tap, no scrub.
    public mutating func cancel() { reset() }

    private mutating func reset() {
        active = false
        interaction = .idle
        ring = nil
    }

    /// Mostly along the radius from where the touch began (inside the hub's dead zone any move is radial).
    private func startsRadial(dx: Double, dy: Double, startRadius: Double) -> Bool {
        if startRadius < DialScrub.hubDeadFraction * zone.hubRadius { return true }
        let len = (sx * sx + sy * sy).squareRoot()
        let radial = (dx * sx + dy * sy) / len
        let tangential = (dx * sy - dy * sx) / len
        return abs(radial) >= abs(tangential)
    }

    private mutating func stepRing(x: Double, y: Double) {
        let r = (x * x + y * y).squareRoot() / scale
        let next = DialScrub.ringIndex(radius: r, count: ringCount, current: ring, zone: zone)
        ring = next
        if interaction != .ringStep(index: next) { interaction = .ringStep(index: next) }
    }

    private mutating func scrubTime(x: Double, y: Double) {
        let r = (x * x + y * y).squareRoot() / scale
        if r >= DialScrub.hubDeadFraction * zone.hubRadius {
            lastHour = DialScrub.hour(dx: x, dy: y)
        }
        if interaction != .timeScrub(hour: lastHour) { interaction = .timeScrub(hour: lastHour) }
    }
}
