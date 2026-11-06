import Foundation
import MGDomain

/// The Live tab opens with its charts already full (tracker #35, Mo 2026-10-11: "as I open it's there scrolling live,
/// like the HR in the WHOOP app"). On open the app reads the last minutes of stored HR and R-R ONCE (MGStore
/// `hrSamples` / `rrIntervals`) and merges them under the live beats it already holds; from then on live beats append
/// as before, so stored and live points are one series with no seam.
///
/// Rules (each one a failure seen or expected, LiveSeedTests):
/// - a second the live buffer already covers (±1 s: a live second's R-R list starts in the second before) is never
///   taken from the store again — live rows are stored too, and doubling them would zig-zag the line and double RMSSD;
/// - one HR value and one source's R-R per stored second (live, history and 0x2A37 can all hold the same second);
/// - R-R inside a second keeps heart order (`ord`): the last interval ends at the second, earlier ones before it,
///   exactly as `LiveBeatBuffer.append` places live beats — never sorted by value;
/// - nothing older than the window or later than now; the result is sorted by time, so seeding twice changes nothing.
public enum LiveSeed {
    /// One timed value: HR (bpm) or an R-R interval (ms) ending at `at`.
    public struct Point: Equatable, Sendable {
        public var at: Date
        public var value: Double

        public init(at: Date, value: Double) {
            self.at = at
            self.value = value
        }
    }

    public struct Merged: Equatable, Sendable {
        public var hr: [Point]
        public var rr: [Point]
    }

    /// Live buffer + stored rows → one HR series and one R-R series inside [now − keep, now], oldest first.
    public static func merge(bufferHR: [Point], bufferRR: [Point], storedHR: [HRPoint], storedRR: [RRPoint],
                             now: Date, keep: TimeInterval) -> Merged {
        let cutoff = now.addingTimeInterval(-keep)
        let inWindow: (Point) -> Bool = { $0.at >= cutoff && $0.at <= now }
        var covered = Set<Int64>()
        for p in bufferHR + bufferRR { covered.insert(second(p.at)) }
        func isCovered(_ ts: Int64) -> Bool {
            covered.contains(ts) || covered.contains(ts - 1) || covered.contains(ts + 1)
        }

        var hr = bufferHR.filter(inWindow)
        var seenHR = Set<Int64>()
        for row in storedHR where row.bpm.isFinite && row.bpm > 0 && !isCovered(row.ts) && !seenHR.contains(row.ts) {
            seenHR.insert(row.ts)
            hr.append(Point(at: Date(timeIntervalSince1970: TimeInterval(row.ts)), value: row.bpm))
        }

        var rr = bufferRR.filter(inWindow)
        var bySecond: [Int64: [StreamSource: [RRPoint]]] = [:]
        for row in storedRR where row.rrMs.isFinite && row.rrMs > 0 && !isCovered(row.ts) {
            bySecond[row.ts, default: [:]][row.source, default: []].append(row)
        }
        for (ts, sources) in bySecond {
            // The source with the most beats in that second (ties: the first in StreamSource order), never two sources.
            guard let rows = StreamSource.allCases.compactMap({ sources[$0] }).max(by: { $0.count < $1.count })
            else { continue }
            var end = Date(timeIntervalSince1970: TimeInterval(ts))
            var timed: [Point] = []
            for r in rows.sorted(by: { $0.ord < $1.ord }).reversed() {
                timed.append(Point(at: end, value: r.rrMs))
                end = end.addingTimeInterval(-r.rrMs / 1000)
            }
            rr.append(contentsOf: timed.reversed())
        }

        // A stable sort keeps the in-second heart order of equal-time points.
        return Merged(hr: stableSorted(hr.filter(inWindow)), rr: stableSorted(rr.filter(inWindow)))
    }

    /// One value per `spacing` seconds, oldest first (the workout HR map is one value per 5 s, UX §6). The first point
    /// is always kept; a point is kept when it is at least `spacing` after the last kept one.
    public static func thin(_ points: [Point], spacing: TimeInterval) -> [Point] {
        var out: [Point] = []
        for p in stableSorted(points) {
            if let last = out.last, p.at.timeIntervalSince(last.at) < spacing { continue }
            out.append(p)
        }
        return out
    }

    static func second(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970.rounded(.down)) }

    static func stableSorted(_ points: [Point]) -> [Point] {
        points.enumerated().sorted { a, b in
            a.element.at == b.element.at ? a.offset < b.offset : a.element.at < b.element.at
        }.map(\.element)
    }
}
