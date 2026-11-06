import Foundation

/// Wave W11 (2026-10-11, Mo 9:30 PM: "the graphs in live are not like it's being backfilled" — the HR line showed one
/// dot). The Live pre-fill (#35, LiveSeed) reads the last minutes of stored HR / R-R; with strap history hours behind
/// there is nothing stored there, so the line started empty. When the window before now holds too little to draw, the
/// charts show the newest stored stretch instead (live samples and history R18 seconds, R-R the same way), labelled with
/// where it ends, until enough live beats have arrived. Once background history keeps the store current (W11 fix 2) the
/// window before now is full and this never triggers.
public enum LiveBackfill {
    /// Fewer HR points than this in the window before now (about 30 s of live beats) = too little to draw a line.
    public static let minPoints = 30

    public struct Plan: Equatable, Sendable {
        /// The HR line's right edge: now, or the newest stored second.
        public var end: Date
        /// The charts (HR line, beat to beat, RMSSD) use the stored stretch ending at `end`.
        public var usesStoredTail: Bool
        /// "last 5 min of stored data, ending 9:12 PM"; nil when the line ends now.
        public var hrNote: String?
        /// "last 60 s of stored beats, ending 9:12 PM"; nil when the beats are live.
        public var rrNote: String?
    }

    /// - Parameters:
    ///   - pointsInWindow: HR points (stored and live) in [now − window, now].
    ///   - newestStored: the newest stored HR second at or before now (any source), nil if none.
    public static func plan(now: Date, window: TimeInterval, pointsInWindow: Int, newestStored: Date?,
                            calendar: Calendar) -> Plan {
        let live = Plan(end: now, usesStoredTail: false, hrNote: nil, rrNote: nil)
        guard pointsInWindow < minPoints, let newest = newestStored, newest <= now,
              newest < now.addingTimeInterval(-window) else { return live }
        let t = Clock12.hm(newest, calendar: calendar)
        let minutes = max(1, Int((window / 60).rounded()))
        return Plan(end: newest, usesStoredTail: true, hrNote: "last \(minutes) min of stored data, ending \(t)",
                    rrNote: "last 60 s of stored beats, ending \(t)")
    }
}
