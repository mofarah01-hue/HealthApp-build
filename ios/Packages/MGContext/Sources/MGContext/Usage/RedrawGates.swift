import Foundation

// T23 (2026-10-12): two tiny gates that keep the app from redrawing every screen more often than anything changed.

/// Lets a stream of progress callbacks (one per history chunk) through at most once per `minInterval`. The caller
/// still rebuilds on every real state change (download started or ended), so the last picture is always right.
public struct ProgressRefreshGate: Sendable, Equatable {
    public let minInterval: TimeInterval
    private var last: Date?

    public init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    /// True when a rebuild may run at `now`. A clock set back lets the next call through instead of freezing the gate.
    public mutating func allow(at now: Date) -> Bool {
        if let last, now >= last, now.timeIntervalSince(last) < minInterval { return false }
        last = now
        return true
    }
}

/// The screens' published "now" (`\.mgNow`) is used for receipt days and the sundial hands, never for seconds; changing
/// it every second redrew every tab every second.
public enum MinuteGate {
    /// True when `new` is in a different whole minute from `old` (either direction).
    public static func changed(from old: Date, to new: Date) -> Bool {
        (old.timeIntervalSince1970 / 60).rounded(.down) != (new.timeIntervalSince1970 / 60).rounded(.down)
    }
}
