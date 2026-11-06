import Foundation

/// Wave W11 (2026-10-11, Mo 10:03 PM got "Synced with the PC — PC got 71 h 59 of data (3.7 MB)" and asked if it
/// was a bug; it was). Between 9:30 and 9:35 PM the new build recomputed 10 and 11 Oct and re-sent their day drops
/// about ten times. The receipt batch did merge overlapping ranges (each hour once), but every re-sent version still
/// counted as data the PC "got", and every routine sync posted a banner. Now:
/// - what a sync adds is measured against everything the PC already confirmed (`received`): a re-sent day adds nothing;
/// - a routine successful sync posts NOTHING; its details stay in Settings › Usage;
/// - Mo is told only about problems: the PC unreachable for more than `outageHours` with data waiting (once per
///   outage), uploads failing `failuresInARow` times in a row (once until one succeeds), phone storage under
///   `lowStorageBytes` (at most once a day);
/// - durations read "2 days", "3 h 20 min", "40 min" (`HumanDuration`), never "71 h 59".
public enum SyncNotice {
    public static let outageHours: Double = 12
    public static let failuresInARow = 3
    public static let lowStorageBytes: Int64 = 1_000_000_000

    public struct Span: Codable, Equatable, Sendable {
        public var start: Date
        public var end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
    }

    /// Sorted, non-overlapping union.
    public static func union(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for s in spans.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }

    public static func seconds(_ spans: [Span]) -> TimeInterval {
        union(spans).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// The time `delivered` covers that `received` did not (each hour once), and the new `received`.
    public static func newCoverage(received: [Span], delivered: [Span]) -> (seconds: TimeInterval, received: [Span]) {
        let before = seconds(received)
        let after = union(received + delivered)
        return (max(0, seconds(after) - before), after)
    }

    /// Settings › Usage: "10:03 PM with the PC: 3.7 MB in 12 drops — 15 min of new data, 2 days re-sent
    /// (recomputed days)" / "… — nothing new (3 days re-sent: recomputed days)".
    public static func deliveryLine(at: Date, newSeconds: TimeInterval, resentSeconds: TimeInterval, bytes: Int64,
                                    drops: Int, pcName: String?, calendar: Calendar) -> String {
        let head = Clock12.hm(at, calendar: calendar) + (pcName.map { " with \($0)" } ?? "")
            + ": \(UsageMath.bytes(bytes)) in \(drops) drop\(drops == 1 ? "" : "s")"
        let resent = resentSeconds >= 60 ? "\(HumanDuration.text(resentSeconds)) re-sent (recomputed days)" : nil
        if newSeconds < 60 { return head + " — nothing new" + (resent.map { " (\($0))" } ?? "") }
        return head + " — \(HumanDuration.text(newSeconds)) of new data" + (resent.map { ", \($0)" } ?? "")
    }

    public enum Notice: Equatable, Sendable {
        case pcUnreachable(since: Date, waiting: Bool)
        case uploadsFailing(times: Int, last: String?)
        case storageLow(freeBytes: Int64)
    }

    public enum Attempt: Equatable, Sendable {
        /// Synced, or nothing to send.
        case ok
        /// The PC could not be reached.
        case offline
        /// Reached, but the upload failed (error or partial), with the reason.
        case failed(String?)
        /// Not set up, skipped: says nothing about the PC.
        case other
    }

    public struct State: Codable, Equatable, Sendable {
        public var failures: Int = 0
        public var lastFailure: String?
        public var failingNoticed = false
        /// The outage (its `unreachableSince`) a notice already went out for.
        public var outageNoticed: Date?
        public var storageNoticedAt: Date?

        public init() {}
    }

    /// After every sync attempt. Returns the new state and what to tell Mo (usually nothing).
    public static func afterAttempt(_ attempt: Attempt, state: State, unreachableSince: Date?, dataWaiting: Bool,
                                    freeBytes: Int64?, now: Date) -> (state: State, notices: [Notice]) {
        var s = state
        var out: [Notice] = []
        switch attempt {
        case .ok:
            s.failures = 0
            s.lastFailure = nil
            s.failingNoticed = false
            s.outageNoticed = nil
        case .failed(let why):
            s.failures += 1
            s.lastFailure = why
            if s.failures >= failuresInARow, !s.failingNoticed {
                s.failingNoticed = true
                out.append(.uploadsFailing(times: s.failures, last: why))
            }
        case .offline:
            if let since = unreachableSince, dataWaiting, now.timeIntervalSince(since) >= outageHours * 3600,
               s.outageNoticed != since {
                s.outageNoticed = since
                out.append(.pcUnreachable(since: since, waiting: dataWaiting))
            }
        case .other:
            break
        }
        if let free = freeBytes, free < lowStorageBytes,
           s.storageNoticedAt.map({ now.timeIntervalSince($0) >= 86_400 }) ?? true {
            s.storageNoticedAt = now
            out.append(.storageLow(freeBytes: free))
        }
        return (s, out)
    }
}

/// "2 days", "1 day", "3 h 20 min", "3 h", "40 min", "under a minute" (Mo, 2026-10-11: never "71 h 59").
public enum HumanDuration {
    public static func text(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "under a minute" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        if seconds < 86_400 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) h" : "\(h) h \(m) min"
        }
        let days = Int((seconds / 86_400).rounded())
        return days == 1 ? "1 day" : "\(days) days"
    }
}
