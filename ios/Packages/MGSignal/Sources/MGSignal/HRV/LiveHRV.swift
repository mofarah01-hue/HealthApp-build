import Foundation
import MGDomain

/// Live 5-minute RMSSD with the gates the nightly path already uses (0.6.0.12; Mo Nov 5 2026). The old live tile needed 3 beats
/// (`ALG010.minBeats`), so it showed a number from a few seconds of beats and then vanished. Now a window counts only when:
///   - at least `minPairs` (20) CLEAN SUCCESSIVE intervals, as noop (`HRVAnalyzer`: >= 20 clean intervals) and OpenStrap
///     (`hrv_time.dart`: >= 20 clean successive differences) require;
///   - the clean beats cover at least `minCoverage` (80 %) of the 5 minutes (Atria asks >= 240 s of 300 s);
///   - no pair of beats is joined across a silence longer than `maxGapSeconds` (3 s; my-whoop / wearable `hrv.py`, Atria);
///   - the beats do not overlap in time: OpenStrap rejects a coverage above 1.10 as a duplicated or interleaved R-R stream.
/// Clean = inside 300...2000 ms (noop, OpenStrap, wearable, Atria) and not flagged by ALG-004's classifier. Flagged beats are
/// left out, not repaired, so no variability is invented. Sources: research-4.0-algorithms-CHATGPT-B-2026-11-05.md; Task Force
/// 1996 (5-minute convention). Decoded from the sources' text, not run against Mo's strap: "decoded, untested" on a 4.0.
public enum LiveHRV {
    public static let windowSeconds = 300.0
    public static let minPairs = 20
    public static let minCoverage = 0.80
    public static let maxGapSeconds = 3.0
    public static let maxCoverageRatio = 1.10
    public static let minRRms = 300.0
    public static let maxRRms = 2000.0
    /// A grey provisional number needs at least this many clean pairs (the old minimum).
    public static let provisionalPairs = 3

    /// One R-R interval and the time its beat ended.
    public struct Beat: Equatable, Sendable {
        public var at: Date
        public var ms: Double
        public init(at: Date, ms: Double) {
            self.at = at
            self.ms = ms
        }
    }

    /// Judges the window `(windowEnd - 300 s, windowEnd]` from `beats`. `moving` = a workout or movement ran in it.
    public static func evaluate(beats: [Beat], windowEnd: Date, moving: Bool = false) -> LiveHRVWindow {
        let start = windowEnd.addingTimeInterval(-windowSeconds)
        var inWindow = beats.filter { $0.at > start && $0.at <= windowEnd && $0.ms.isFinite && $0.ms > 0 }
            .sorted { $0.at < $1.at }
        // Duplicate R-R (the same interval ending at the same moment, e.g. a repeated notification) is dropped.
        var kept: [Beat] = []
        for b in inWindow {
            if let last = kept.last, abs(b.at.timeIntervalSince(last.at)) < 0.001, abs(b.ms - last.ms) < 0.5 { continue }
            kept.append(b)
        }
        inWindow = kept
        guard !inWindow.isEmpty else {
            return LiveHRVWindow(start: start, end: windowEnd, why: moving ? .motion : .noBeats)
        }

        // Coverage ratio: summed R-R over the time the beats span. Above 1.10 the beats overlap.
        let first = inWindow[0].at.addingTimeInterval(-inWindow[0].ms / 1000)
        let span = inWindow[inWindow.count - 1].at.timeIntervalSince(first)
        let total = inWindow.reduce(0.0) { $0 + $1.ms } / 1000
        let overlapping = span > 0 && total / span > maxCoverageRatio

        // Segments: a silence over `maxGapSeconds` between one beat's end and the next beat's start splits them.
        var segments: [[Beat]] = [[inWindow[0]]]
        var longestGap = 0.0
        for i in 1..<inWindow.count {
            let prevEnd = inWindow[i - 1].at
            let thisStart = inWindow[i].at.addingTimeInterval(-inWindow[i].ms / 1000)
            let gap = thisStart.timeIntervalSince(prevEnd)
            longestGap = max(longestGap, gap)
            if gap > maxGapSeconds { segments.append([inWindow[i]]) } else { segments[segments.count - 1].append(inWindow[i]) }
        }

        // Clean successive pairs within each segment only.
        var sumSq = 0.0
        var pairs = 0
        var cleanMs: [Double] = []
        var cleanSeconds = 0.0
        for seg in segments where seg.count >= ALG004.minBeats {
            let rr = seg.map(\.ms)
            let flags = ALG004.classify(rrMs: rr)
            let clean = (0..<rr.count).map { flags[$0] == ArtefactFlag.ok.rawValue && rr[$0] >= minRRms && rr[$0] <= maxRRms }
            for i in 0..<rr.count where clean[i] {
                cleanMs.append(rr[i])
                cleanSeconds += rr[i] / 1000
                if i + 1 < rr.count, clean[i + 1] {
                    let d = rr[i + 1] - rr[i]
                    sumSq += d * d
                    pairs += 1
                }
            }
        }
        let coverage = min(1, cleanSeconds / windowSeconds)
        let rmssd: Double? = pairs >= provisionalPairs && sumSq > 0 ? (sumSq / Double(pairs)).squareRoot() : nil
        let meanRR: Double? = cleanMs.isEmpty ? nil : cleanMs.reduce(0, +) / Double(cleanMs.count)

        var why: LiveHRVWhy?
        if moving {
            why = .motion
        } else if overlapping {
            why = .duplicates
        } else if longestGap > maxGapSeconds, coverage < minCoverage {
            why = .gaps(longest: longestGap)
        } else if pairs < minPairs {
            why = .tooFewBeats(have: pairs, need: minPairs)
        } else if coverage < minCoverage {
            why = .coverage(percent: Int((coverage * 100).rounded()))
        }
        let ideal = why == nil && rmssd != nil
        if !ideal && why == nil { why = .tooFewBeats(have: pairs, need: minPairs) }   // 20 flat pairs: RMSSD 0, not a usable stream
        return LiveHRVWindow(start: start, end: windowEnd, rmssd: overlapping ? nil : rmssd, meanRR: overlapping ? nil : meanRR,
                             cleanPairs: pairs, coverage: coverage, ideal: ideal, why: why)
    }

    /// Today's finished 5-minute windows, cut on the wall clock (every `windowSeconds` since the Unix epoch, so two runs agree on
    /// the boundaries). A window is judged once, when it is over and its beats are still in the buffer; windows with no beats
    /// at all are not recorded. A new day starts an empty list.
    public struct Tracker: Equatable, Sendable {
        public private(set) var day: Date?
        public private(set) var windows: [LiveHRVWindow] = []
        private var lastEnd: Date?

        public init() {}

        /// `bufferStart` = the oldest beat time the caller still holds (windows starting before it are skipped, not judged on
        /// partial data). `dayStart` = local midnight of today.
        public mutating func update(beats: [Beat], now: Date, dayStart: Date, bufferStart: Date, moving: Bool) {
            if day != dayStart {
                day = dayStart
                windows = []
                lastEnd = nil
            }
            let w = LiveHRV.windowSeconds
            let aligned = (now.timeIntervalSince1970 / w).rounded(.down) * w
            var end = aligned
            var due: [TimeInterval] = []
            while end > (lastEnd?.timeIntervalSince1970 ?? -.infinity), end - w >= bufferStart.timeIntervalSince1970,
                  end - w >= dayStart.timeIntervalSince1970 {
                due.append(end)
                end -= w
            }
            for e in due.reversed() {
                let endDate = Date(timeIntervalSince1970: e)
                let win = LiveHRV.evaluate(beats: beats, windowEnd: endDate, moving: moving)
                if win.why != .noBeats { windows.append(win) }
            }
            if aligned > (lastEnd?.timeIntervalSince1970 ?? -.infinity) { lastEnd = Date(timeIntervalSince1970: aligned) }
        }
    }
}
