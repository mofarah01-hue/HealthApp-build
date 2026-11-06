import Foundation

/// How long to rest after a slice of CPU work so the average share stays near `maxShare` (T140, 2026-10-12).
///
/// iOS kills a background task that burns CPU for long (the four kills Mo logged). The compute loop runs a whole
/// day's pipelines in one go; the caller measures each slice (CPU seconds and wall seconds) and sleeps for `pause`
/// before the next one. Pure arithmetic, so it is tested on Linux; the app reads the real CPU time with `getrusage`.
public struct CPUGovernor: Sendable, Equatable {
    /// Target CPU share of wall time, clamped to 0.05...1 (1 = never pause).
    public let maxShare: Double
    /// The longest single rest, so one huge slice cannot park the runner for minutes.
    public let maxPause: Double

    public init(maxShare: Double = 0.5, maxPause: Double = 5) {
        self.maxShare = maxShare.isFinite ? min(max(maxShare, 0.05), 1) : 0.5
        self.maxPause = maxPause.isFinite && maxPause >= 0 ? maxPause : 5
    }

    /// Seconds to rest: `cpu / maxShare - wall`, less whatever the slice already spent waiting; never negative, NaN
    /// or beyond `maxPause`.
    public func pause(afterSliceCPU cpu: Double, wall: Double) -> Double {
        guard cpu.isFinite, wall.isFinite, cpu > 0 else { return 0 }
        let p = cpu / maxShare - max(wall, 0)
        return p.isFinite ? min(max(p, 0), maxPause) : 0
    }
}
