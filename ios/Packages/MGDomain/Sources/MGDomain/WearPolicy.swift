import Foundation

/// What the place the strap is worn changes in our algorithms (D-LOAD-WALK-1 item 12, r9o 2026-10-17). One table, read by
/// the pipeline (what is computed) and by Workout detail (what it tells Mo). Only what the code really does is listed here.
///
/// Today exactly one thing depends on the place: STEP COUNTING. Strap-derived steps (the strap's step counter ticks and the
/// wrist-swing walking-bout model T118) are off while the strap is on the upper arm; the phone's steps are untouched.
/// Why: both are built for the wrist. The counter's ticks-per-step is calibrated against iPhone steps on wrist-worn days,
/// and T118 counts the peaks of the wrist's arm swing; at the upper arm the swing is much smaller and neither has been
/// checked. Source: none published for this strap at the upper arm: this is our choice (labelled that way), taken from
/// Mo's brief ("step counting off for bicep"), not a validated result. Heart rate, HRV, strain and calories are read the
/// same at every place: no source here says by how much optical heart rate differs between the wrist and the upper
/// arm for this strap, so the place is only shown beside the workout (compare days by place in ALG-042).
public enum WearPolicy {
    public enum Group: String, Sendable, Equatable {
        case wrist, upperArm, body, notSet
    }

    public static func group(_ l: WearLocation?) -> Group {
        switch l {
        case .leftWrist?, .rightWrist?: return .wrist
        case .leftBicep?, .rightBicep?: return .upperArm
        case .bodyTorso?, .bodyWaist?, .tailboneUnderwear?, .other?: return .body
        case .unknown?, nil: return .notSet
        }
    }

    /// Strap-derived steps (counter and wrist-swing model) count while the strap is at the wrist, or the place is not set
    /// (read as the wrist, as before this table). Upper arm and the body places: off.
    public static func countsStrapSteps(_ l: WearLocation?) -> Bool {
        switch group(l) {
        case .wrist, .notSet: return true
        case .upperArm, .body: return false
        }
    }

    /// One line of "what changes at this place".
    public struct Effect: Equatable, Sendable {
        public var what: String
        public var change: String
        public var why: String

        public init(what: String, change: String, why: String) {
            self.what = what
            self.change = change
            self.why = why
        }
    }

    public static let stepsWhy = "The strap's step counter is calibrated on wrist-worn days and the walking-bout model reads wrist "
        + "arm swing; neither is checked at another place. Ours: no published validation for this strap."

    public static func effects(for l: WearLocation?) -> [Effect] {
        let readSame = Effect(what: "Heart rate, HRV, strain, calories", change: "read the same",
                              why: "No source says how much this strap's optical heart rate differs between places, so nothing is "
                                  + "adjusted; the place is shown beside the workout.")
        switch group(l) {
        case .wrist:
            return [Effect(what: "Steps from the strap", change: "on", why: "Built and calibrated for the wrist."), readSame]
        case .notSet:
            return [Effect(what: "Steps from the strap", change: "on, place not set (read as the wrist)",
                           why: "Choose where you wore it so the steps are right."), readSame]
        case .upperArm:
            return [Effect(what: "Steps from the strap", change: "off", why: stepsWhy),
                    Effect(what: "Walking bouts and cadence", change: "off", why: stepsWhy),
                    Effect(what: "Phone steps", change: "unchanged", why: "The phone does not depend on where the strap is."),
                    readSame]
        case .body:
            return [Effect(what: "Steps from the strap", change: "off", why: stepsWhy),
                    Effect(what: "Walking bouts and cadence", change: "off", why: stepsWhy), readSame]
        }
    }

    // MARK: where the strap was, over a window

    /// A stretch of time at one place.
    public struct Segment: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var location: WearLocation

        public init(start: Double, end: Double, location: WearLocation) {
            self.start = start
            self.end = end
            self.location = location
        }
    }

    /// The place at every moment of [from, to] (unix seconds): the located `wear` events give the base (a place holds until the
    /// next located event; the last one before `from` carries in), and a workout that has its own place overrides it for
    /// its own window (Mo edits it in Workout detail). Moments with no place known are left out (read as the wrist).
    public static func segments(events: [EventRecord], from: Double, to: Double) -> [Segment] {
        guard to > from else { return [] }
        let located = events.filter { !$0.removed && $0.type == .wear && $0.wearLocation != nil && $0.wearLocation != .unknown }
            .sorted { $0.at < $1.at }
        var overrides: [(start: Double, end: Double, location: WearLocation)] = []
        for e in events where !e.removed {
            if case .workout(let f) = e.payload, let w = e.wearLocation, w != .unknown {
                overrides.append((e.at.timeIntervalSince1970, f.end.timeIntervalSince1970, w))
            }
        }
        var cuts: Set<Double> = [from, to]
        for e in located { let t = e.at.timeIntervalSince1970; if t > from && t < to { cuts.insert(t) } }
        for o in overrides {
            for t in [o.start, o.end] where t > from && t < to { cuts.insert(t) }
        }
        let points = cuts.sorted()
        var out: [Segment] = []
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let mid = (a + b) / 2
            // The newest-starting override that contains the moment wins; otherwise the last located wear event before it.
            let over = overrides.filter { $0.start <= mid && mid < $0.end }.max { $0.start < $1.start }?.location
            let base = located.last { $0.at.timeIntervalSince1970 <= mid }?.wearLocation
            guard let loc = over ?? base else { continue }
            if let last = out.last, last.location == loc, last.end == a {
                out[out.count - 1].end = b
            } else {
                out.append(Segment(start: a, end: b, location: loc))
            }
        }
        return out
    }

    /// The stretches of [from, to] where strap-derived steps are off.
    public static func stepsOffSpans(events: [EventRecord], from: Double, to: Double) -> [ClosedRange<Double>] {
        segments(events: events, from: from, to: to).filter { !countsStrapSteps($0.location) }.map { $0.start...$0.end }
    }

    /// True when `t` lies in one of `spans` (start inclusive, end exclusive).
    public static func inside(_ t: Double, _ spans: [ClosedRange<Double>]) -> Bool {
        spans.contains { t >= $0.lowerBound && t < $0.upperBound }
    }
}
