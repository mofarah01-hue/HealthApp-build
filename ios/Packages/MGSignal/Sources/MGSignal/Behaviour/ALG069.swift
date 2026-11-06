import Foundation

/// ALG-069 v1 — intake frequency, adherence against a schedule, and co-timing ("taken within 30 min of a named medication").
/// Counts and times only; **no dose advice**. Rules are OURS (flagged):
///   * adherence: scheduled slots are matched one-to-one to intakes within ± `windowMin` (default 60 min): slots are
///     taken in time order, each picks the closest unmatched intake inside the window, the earlier intake on a tie;
///     the caller passes only slots that are already due (a slot in the future is not "missed");
///   * co-timing: an intake of A counts when it lies within ± `windowMin` (default 30 min, inclusive) of any anchor
///     intake; its lag is measured to the nearest anchor (the earlier anchor on a tie), negative = before the anchor.
/// Python reference: app/pclab/mglab/ref/behaviour.py `intake_stats` / `adherence` / `co_timing`; goldens
/// app/shared/golden/behaviour/ALG-069.json.
public enum ALG069 {
    public static let method = "ALG-069@1 intake-stats"
    public static let adherenceWindowMin = 60.0
    public static let coTimeWindowMin = 30.0

    public struct Stats: Sendable, Equatable {
        public var count: Int
        /// Hours between consecutive intakes (time order).
        public var gapsH: [Double]
        public var medianGapH: Double?
        public var maxGapH: Double?
        /// Sum of the amounts if given.
        public var total: Double?

        public init(count: Int, gapsH: [Double], medianGapH: Double?, maxGapH: Double?, total: Double?) {
            self.count = count
            self.gapsH = gapsH
            self.medianGapH = medianGapH
            self.maxGapH = maxGapH
            self.total = total
        }
    }

    public struct Match: Sendable, Equatable {
        /// Index into the time-sorted schedule.
        public var slot: Int
        /// Index into the time-sorted intakes.
        public var intake: Int

        public init(slot: Int, intake: Int) {
            self.slot = slot
            self.intake = intake
        }
    }

    public struct Adherence: Sendable, Equatable {
        public var scheduled: Int
        public var taken: Int
        public var missed: Int
        /// Intakes that matched no slot.
        public var extra: Int
        /// taken / scheduled, 0…1.
        public var adherence: Double
        public var matches: [Match]

        public init(scheduled: Int, taken: Int, missed: Int, extra: Int, adherence: Double, matches: [Match]) {
            self.scheduled = scheduled
            self.taken = taken
            self.missed = missed
            self.extra = extra
            self.adherence = adherence
            self.matches = matches
        }
    }

    public struct CoTiming: Sendable, Equatable {
        public var nA: Int
        public var nWithin: Int
        /// nWithin / nA; nil when A has no intakes.
        public var fraction: Double?
        /// Signed minutes to the nearest anchor for each counted intake, in A's time order.
        public var lagsMin: [Double]

        public init(nA: Int, nWithin: Int, fraction: Double?, lagsMin: [Double]) {
            self.nA = nA
            self.nWithin = nWithin
            self.fraction = fraction
            self.lagsMin = lagsMin
        }
    }

    /// ALG-069 v1 — counts, gaps and (optionally) the summed amount of a list of intakes.
    public static func stats(times: [Date], amounts: [Double]? = nil) -> Stats {
        let ts = times.map { BehaviourClock.seconds($0) }.sorted()
        var gaps: [Double] = []
        if ts.count > 1 {
            for i in 0..<(ts.count - 1) { gaps.append((ts[i + 1] - ts[i]) / BehaviourClock.hourSeconds) }
        }
        var total: Double?
        if let a = amounts {
            var s = 0.0
            for v in a { s += v }
            total = s
        }
        return Stats(count: ts.count, gapsH: gaps, medianGapH: gaps.isEmpty ? nil : SignalMath.median(gaps),
                     maxGapH: gaps.max(), total: total)
    }

    /// ALG-069 v1 — adherence. Missing when nothing was scheduled (adherence of 0 slots is not 100 %).
    public static func adherence(scheduled: [Date], taken: [Date], windowMin: Double = ALG069.adherenceWindowMin)
        -> Computed<Adherence> {
        guard !scheduled.isEmpty else { return .missing("no schedule: nothing was due") }
        let slots = scheduled.map { BehaviourClock.seconds($0) }.sorted()
        let intakes = taken.map { BehaviourClock.seconds($0) }.sorted()
        var used = [Bool](repeating: false, count: intakes.count)
        let w = windowMin * 60.0
        var matches: [Match] = []
        for (i, s) in slots.enumerated() {
            var best = -1
            var bestGap: Double?
            for (j, t) in intakes.enumerated() {
                if used[j] { continue }
                let g = abs(t - s)
                if g <= w && (bestGap == nil || g < bestGap!) {
                    best = j
                    bestGap = g
                }
            }
            if best >= 0 {
                used[best] = true
                matches.append(Match(slot: i, intake: best))
            }
        }
        let n = matches.count
        return .success(Adherence(scheduled: slots.count, taken: n, missed: slots.count - n, extra: intakes.count - n,
                                  adherence: Double(n) / Double(slots.count), matches: matches))
    }

    /// ALG-069 v1 — co-timing. Missing when there are no anchor doses to compare to.
    public static func coTiming(times: [Date], anchors: [Date], windowMin: Double = ALG069.coTimeWindowMin)
        -> Computed<CoTiming> {
        guard !anchors.isEmpty else { return .missing("no anchor doses logged") }
        let a = times.map { BehaviourClock.seconds($0) }.sorted()
        let anc = anchors.map { BehaviourClock.seconds($0) }.sorted()
        let w = windowMin * 60.0
        var lags: [Double] = []
        for t in a {
            var near = anc[0]
            for x in anc where abs(t - x) < abs(t - near) { near = x }
            if abs(t - near) <= w { lags.append((t - near) / 60.0) }
        }
        let n = a.count
        return .success(CoTiming(nA: n, nWithin: lags.count, fraction: n > 0 ? Double(lags.count) / Double(n) : nil,
                                 lagsMin: lags))
    }

    /// `vape_hits` (count), window "day": the day's puffs (from ALG-068's `hitsDay` or a count of events).
    public static let vapeHitsSpec = MetricSpec(
        key: .vapeHits, unit: "count", group: nil, variant: "ALG-069", method: method, tier: .high,
        source: "vape log", window: "day", paramsVersion: "sum-of-puffs")
}
