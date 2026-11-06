import Foundation

// Fallback 2 (Mo, Nov 6 2026: "if our sleep fails, fallbacks to other sources are important"; rule D-SLEEP-PRIORITY-1):
// Apple Health's sleep read on the phone itself, so the card does not wait for the PC row or a full upload queue.
// Read-only: samples come from HealthKit `SleepAnalysis`; nothing here writes or sends anything. The merge is plain Swift
// so it tests without HealthKit.

/// One `SleepAnalysis` category sample, reduced to what the merge needs.
public struct AppleSleepSample: Hashable, Sendable {
    /// `HKCategoryValueSleepAnalysis` raw value: 0 inBed, 1 asleepUnspecified, 2 awake, 3 core, 4 deep, 5 REM.
    public var value: Int
    public var start: Date
    public var end: Date
    /// The app that wrote it: "WHOOP", "Mo's Apple Watch".
    public var source: String

    public init(value: Int, start: Date, end: Date, source: String) {
        self.value = value
        self.start = start
        self.end = end
        self.source = source
    }

    public var isAsleep: Bool { [1, 3, 4, 5].contains(value) }
}

/// One source's night, merged from its samples.
public struct PhoneAppleSleep: Hashable, Sendable {
    public var source: String
    public var minutes: Double
    public var start: Date
    public var end: Date
    /// Other sources' minutes for the same night, most complete first.
    public var others: [Other]

    public struct Other: Hashable, Sendable {
        public var source: String
        public var minutes: Double
        public init(source: String, minutes: Double) {
            self.source = source
            self.minutes = minutes
        }
    }

    public init(source: String, minutes: Double, start: Date, end: Date, others: [Other] = []) {
        self.source = source
        self.minutes = minutes
        self.start = start
        self.end = end
        self.others = others
    }

    /// Gap between asleep samples that still counts as one night (a long wake at 3 AM stays in it).
    public static let nightGapSeconds: TimeInterval = 3 * 3600
    /// A stretch shorter than this is a nap, not the night.
    public static let minNightSeconds: TimeInterval = 2 * 3600
    /// Only samples this recent are looked at.
    public static let lookbackSeconds: TimeInterval = 36 * 3600

    /// The latest night (a cluster of asleep samples with gaps under `nightGapSeconds`, at least `minNightSeconds` of
    /// asleep time) of the best source: WHOOP first (worn 24/7, as pc.history ranks it), then the Watch, then any other.
    /// Overlapping samples are merged, so inBed + asleep never count twice. nil when there is no night.
    public static func build(_ samples: [AppleSleepSample], now: Date) -> PhoneAppleSleep? {
        let recent = samples.filter { $0.isAsleep && $0.end > $0.start && $0.end <= now.addingTimeInterval(300)
            && $0.end >= now.addingTimeInterval(-lookbackSeconds) }
        let bySource = Dictionary(grouping: recent, by: \.source)
        var nights: [(source: String, minutes: Double, start: Date, end: Date)] = []
        for (src, list) in bySource {
            guard let n = latestNight(list) else { continue }
            nights.append((src, n.minutes, n.start, n.end))
        }
        guard !nights.isEmpty else { return nil }
        func rank(_ s: String) -> Int {
            let l = s.lowercased()
            return l.contains("whoop") ? 0 : l.contains("watch") ? 1 : 2
        }
        nights.sort { (rank($0.source), -$0.minutes, $0.source) < (rank($1.source), -$1.minutes, $1.source) }
        let best = nights[0]
        return PhoneAppleSleep(source: best.source, minutes: best.minutes, start: best.start, end: best.end,
                               others: nights.dropFirst().map { Other(source: $0.source, minutes: $0.minutes) })
    }

    private static func latestNight(_ list: [AppleSleepSample]) -> (minutes: Double, start: Date, end: Date)? {
        let sorted = list.sorted { $0.start < $1.start }
        // union of intervals, clustered by gap
        var clusters: [[(Date, Date)]] = []
        for s in sorted {
            if var last = clusters.last, let tail = last.last, s.start.timeIntervalSince(tail.1) < nightGapSeconds {
                if s.start <= tail.1 { last[last.count - 1].1 = max(tail.1, s.end) } else { last.append((s.start, s.end)) }
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([(s.start, s.end)])
            }
        }
        for c in clusters.reversed() {
            let secs = c.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) }
            if secs >= minNightSeconds, let a = c.first?.0, let b = c.last?.1 { return (secs / 60, a, b) }
        }
        return nil
    }
}
