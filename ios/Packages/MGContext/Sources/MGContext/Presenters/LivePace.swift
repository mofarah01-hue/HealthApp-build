import Foundation

/// R-094 (Mo 2026-10-14: "Live on 0.5.4 is choppy, lags, and sometimes freezes then unfreezes"). Two parts, both pure here
/// and driven by AppModel:
/// - pace: a beat rebuilds the Live tab at once (it used to wait for the next 1-s tick, up to 1 s of extra delay, R-007),
///   at most once per `minGap`; the 1-s tick skips when a beat just did it, so the work per second does not grow;
/// - stall watch: a `watchTick` timer that wakes late by more than `stall` means the main thread was blocked. The worst
///   stall and the slowest Live / full rebuild since the last line are written to the strap log at most once per
///   `logEvery`, so the cause of a freeze can be read from the next run instead of guessed.
public struct LivePace: Equatable, Sendable {
    public static let minGap: TimeInterval = 0.5
    public static let watchTick: TimeInterval = 0.25
    public static let stall: TimeInterval = 0.3
    public static let logEvery: TimeInterval = 60
    /// Later than this = the app was suspended in the background (iOS ends a real main-thread hang well before), not a freeze.
    public static let suspended: TimeInterval = 20

    public private(set) var worstStall: TimeInterval = 0
    public private(set) var stalls = 0
    public private(set) var slowestLive: TimeInterval = 0
    public private(set) var slowestFull: TimeInterval = 0
    public private(set) var loggedAt: TimeInterval?

    public init() {}

    /// Whether a beat arriving `sinceLast` seconds after the last Live rebuild should rebuild it now.
    public static func beatShouldRefresh(sinceLast: TimeInterval) -> Bool { sinceLast >= minGap }

    public mutating func noteLive(_ seconds: TimeInterval) { slowestLive = max(slowestLive, seconds) }
    public mutating func noteFull(_ seconds: TimeInterval) { slowestFull = max(slowestFull, seconds) }

    /// The watch tick woke `lateBy` seconds after it should have. Returns a strap-log line when there were stalls and
    /// the last line is at least `logEvery` old; the counters then start again.
    public mutating func noteWake(lateBy: TimeInterval, at now: TimeInterval) -> String? {
        if lateBy > Self.stall, lateBy < Self.suspended {
            stalls += 1
            worstStall = max(worstStall, lateBy)
        }
        guard stalls > 0, loggedAt.map({ now - $0 >= Self.logEvery }) ?? true else { return nil }
        let line = "live pace: main thread blocked \(stalls) time\(stalls == 1 ? "" : "s"), worst \(Self.ms(worstStall)) "
            + "(Live on screen); slowest Live update \(Self.ms(slowestLive)), slowest full rebuild \(Self.ms(slowestFull))"
        loggedAt = now
        stalls = 0
        worstStall = 0
        slowestLive = 0
        slowestFull = 0
        return line
    }

    static func ms(_ s: TimeInterval) -> String { "\(Int((s * 1000).rounded())) ms" }
}
