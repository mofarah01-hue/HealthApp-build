import Foundation

/// r9p (D-LOAD-WALK-2): the effort card of the workout detail - Mo's own CR-10 rating and his weights before and after,
/// with the readouts that use them (load score against his own sessions, session-RPE load, sweat loss) and the week
/// comparison and body log beside them.
public struct WorkoutEffortState: Equatable, Sendable {
    /// The CR-10 rating (0 to 10) Mo gave this session; nil = not rated yet.
    public var rpe: Double?
    public var weightPreKg: Double?
    public var weightPostKg: Double?
    /// Plain sentences, each already worded with its basis ("yours, 6 sessions", "population value").
    public var lines: [String]

    public init(rpe: Double?, weightPreKg: Double?, weightPostKg: Double?, lines: [String]) {
        self.rpe = rpe
        self.weightPreKg = weightPreKg
        self.weightPostKg = weightPostKg
        self.lines = lines
    }
}
