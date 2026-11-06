import Foundation
import MGDomain

/// ALG-150 v1 — strap-night accounting (Oct 16 2026, 8:55 AM PT; replaces ALG-150, removed on Mo's order: "fix that damn
/// algorithm, remove it, it is not right, ALG-150 needs to be removed completely"). ALG-150 cut the hypnogram to the
/// ALG-030 rest window and began the night at the first 10-min asleep run, so a rest window that did not match the
/// strap's night turned a long night into "23 min of sleep". ALG-150 never looks at a rest window: the night is the
/// strap flag's own asleep period. Works on any hypnogram (the strap flag, the strap+stages hybrid, ALG-120 alone).
/// Python: `mglab.ref.sleep.accounting` / `performance`.
public enum ALG150 {
    /// ours v2 (D-SLEEP-LOW-3, Nov 5 2026): asleep runs ≤ 90 min apart (180 epochs) are one night: noop SleepStager
    /// nightContinuationGapMin = 90, OpenStrap segment.dart overnight chain 90. v1 bridged 30 min (60 epochs, OpenStrap
    /// van_hees.dart bridgeGapMin) and kept only the longest block, so a wake over 30 min threw away half the night.
    static let gapJoinEpochs = 180
    /// ours v2: a block with fewer than 60 asleep epochs (30 min) joins its neighbour across up to 120 min (240 epochs):
    /// geniemax-core SleepWindow.nightWindow merges an earlier bout within 120 min whatever its length (10-13: 21 min of
    /// sleep, a 96-min wake, then 255 min).
    static let shortFragmentEpochs = 60
    static let shortGapJoinEpochs = 240
    static let awakeningMinEpochs = 2        // ours v1: an awakening is a wake run ≥ 1 min inside the night
    static let noLatencyReason = "no bed time; needs T9979 NFC tag"
    public static let citation = "OpenStrap analytics segment.dart / coaching.dart (performance); strap flag R18 byte 81"

    /// D-SLEEP-LOW-2 (Nov 5 2026): a night whose last asleep epoch ends within this long of the newest strap second may
    /// still be going, or its history has not arrived yet (10-18 was published as 141 min from data that stopped at
    /// 05:06:30; the strap held until 08:56). OpenStrap `segment.dart` `_dropUnfinishedGroups`: 15 min.
    public static let unfinishedWithinSeconds: Int64 = 15 * 60
    /// ...but not for ever: when the newest strap second is older than this the record has stopped (strap taken off at
    /// wake, no more history coming) and the night is published as it is.
    public static let unfinishedGiveUpSeconds: Int64 = 12 * 3600
    public static let unfinishedPrefix = "night not finished"

    /// The reason a night must not be published yet, or nil. `dataEnd` = ts of the newest strap second the phone holds,
    /// `now` = the time of the run.
    public static func unfinishedReason(_ acc: Accounting, dataEnd: Int64, now: Int64) -> String? {
        guard now - dataEnd < unfinishedGiveUpSeconds else { return nil }
        guard acc.wakeTime >= dataEnd - unfinishedWithinSeconds else { return nil }
        let min = unfinishedWithinSeconds / 60
        return "\(unfinishedPrefix): the last asleep epoch is within \(min) min of the newest strap data, so the night may still "
            + "be going or its history has not arrived; it is computed again when more data arrives"
    }

    public struct Accounting: Sendable, Equatable {
        public var sleepOnset: Int64
        public var wakeTime: Int64
        /// Onset … wake, minutes (the denominator of efficiency).
        public var windowMin: Double
        public var latencyMin: Computed<Double>
        public var tstMin: Double
        public var wasoMin: Double
        public var unobservedMin: Double
        public var awakenings: Int
        public var efficiency: Computed<Double>
        public var deepMin: Computed<Double>
        public var lightMin: Computed<Double>
        public var remMin: Computed<Double>
        public var unstagedMin: Double
        public var wakeMin: Double
        public var remLatencyMin: Computed<Double>

        public init(sleepOnset: Int64, wakeTime: Int64, windowMin: Double, latencyMin: Computed<Double>, tstMin: Double,
                    wasoMin: Double, unobservedMin: Double, awakenings: Int, efficiency: Computed<Double>,
                    deepMin: Computed<Double>, lightMin: Computed<Double>, remMin: Computed<Double>,
                    unstagedMin: Double, wakeMin: Double, remLatencyMin: Computed<Double>) {
            self.sleepOnset = sleepOnset
            self.wakeTime = wakeTime
            self.windowMin = windowMin
            self.latencyMin = latencyMin
            self.tstMin = tstMin
            self.wasoMin = wasoMin
            self.unobservedMin = unobservedMin
            self.awakenings = awakenings
            self.efficiency = efficiency
            self.deepMin = deepMin
            self.lightMin = lightMin
            self.remMin = remMin
            self.unstagedMin = unstagedMin
            self.wakeMin = wakeMin
            self.remLatencyMin = remLatencyMin
        }
    }

    /// The night = the LONGEST block of asleep epochs (L/D/R/S) joined across gaps of ≤ 90 min (≤ 120 min next to a < 30-min block; every asleep run of the chain counts, the gap is
    /// WASO / unobserved) whose wake instant (end of
    /// its last asleep epoch) falls in [dayStart, dayEnd) (the result's Pacific day, D13; nil = no day limit). Onset =
    /// first asleep epoch, wake = end of the last; window = wake − onset; TST = asleep epochs in it, WASO = W epochs,
    /// unobserved = '.' epochs, awakenings = W runs ≥ 1 min, efficiency = TST ÷ window, stage minutes = the hypnogram's own
    /// letters (Missing when it has no L/D/R at all), REM latency = first R − onset; sleep latency is Missing (no bed time).
    public static func account(_ hyp: SleepHypnogram, dayStart: Double? = nil, dayEnd: Double? = nil) -> Computed<Accounting> {
        let codes = Array(hyp.codes.utf8)
        func asleep(_ c: UInt8) -> Bool { SleepStageCode(rawValue: String(UnicodeScalar(c)))?.isAsleep ?? false }
        var blocks: [(Int, Int)] = []
        var asleepEpochs: [Int] = []                      // asleep epochs of each block, to tell a short fragment
        for run in SleepMath.runs(codes.map(asleep)) {
            let n = run.1 - run.0 + 1
            if let last = blocks.last {
                let gap = run.0 - last.1 - 1
                let short = Swift.min(asleepEpochs[asleepEpochs.count - 1], n) < shortFragmentEpochs
                if gap <= gapJoinEpochs || (short && gap <= shortGapJoinEpochs) {
                    blocks[blocks.count - 1].1 = run.1
                    asleepEpochs[asleepEpochs.count - 1] += n
                    continue
                }
            }
            blocks.append((run.0, run.1))
            asleepEpochs.append(n)
        }
        guard !blocks.isEmpty else { return .missing("no asleep epoch in the hypnogram") }
        if dayStart != nil || dayEnd != nil {
            let lo = dayStart ?? -Double.infinity
            let hi = dayEnd ?? Double.infinity
            blocks = blocks.filter {
                let wake = Double(hyp.epoch0 + Int64($0.1 + 1) * 30)
                return wake >= lo && wake < hi
            }
            guard !blocks.isEmpty else { return .missing("no strap-asleep period ends on this day") }
        }
        // longest span; a tie goes to the later block
        guard let night = blocks.max(by: { ($0.1 - $0.0, $0.0) < ($1.1 - $1.0, $1.0) }) else {
            return .missing("no asleep epoch in the hypnogram")
        }
        let body = Array(codes[night.0...night.1])
        let epMin = 30.0 / 60.0
        func count(_ c: SleepStageCode) -> Int { body.filter { $0 == c.byte }.count }
        let onset = hyp.epoch0 + Int64(night.0) * 30
        let finalWake = hyp.epoch0 + Int64(night.1 + 1) * 30
        let window = Double(finalWake - onset) / 60.0
        let tst = Double(body.filter(asleep).count) * epMin
        let awakenings = SleepMath.runs(body.map { $0 == SleepStageCode.wake.byte })
            .filter { $0.1 - $0.0 + 1 >= awakeningMinEpochs }.count
        let staged = body.contains { $0 == SleepStageCode.light.byte || $0 == SleepStageCode.deep.byte
            || $0 == SleepStageCode.rem.byte }
        let noStage: Computed<Double> = .missing("this hypnogram is sleep / wake only (no stages)")
        var remLatency = noStage
        if staged {
            if let r = body.firstIndex(of: SleepStageCode.rem.byte) {
                remLatency = .success(Double(r) * epMin)
            } else {
                remLatency = .missing("no REM epoch")
            }
        }
        return .success(Accounting(
            sleepOnset: onset, wakeTime: finalWake, windowMin: window, latencyMin: .missing(noLatencyReason),
            tstMin: tst, wasoMin: Double(count(.wake)) * epMin, unobservedMin: Double(count(.noData)) * epMin,
            awakenings: awakenings, efficiency: .success(tst / window),
            deepMin: staged ? .success(Double(count(.deep)) * epMin) : noStage,
            lightMin: staged ? .success(Double(count(.light)) * epMin) : noStage,
            remMin: staged ? .success(Double(count(.rem)) * epMin) : noStage,
            unstagedMin: Double(count(.asleep)) * epMin, wakeMin: Double(count(.wake)) * epMin,
            remLatencyMin: remLatency))
    }

    /// Sleep performance = TST ÷ need, capped at 1 (OpenStrap coaching.dart sleepPerformance).
    public static func performance(tstMin: Double, needMin: Computed<Double>) -> Computed<Double> {
        switch needMin {
        case .failure(let m):
            return .missing("no sleep need: \(m.reason)")
        case .success(let need):
            guard need > 0 else { return .missing("no sleep need") }
            return .success(Swift.min(1.0, Swift.max(0.0, tstMin / need)))
        }
    }

    // MARK: metrics

    static func spec(_ key: MetricKey, _ unit: String, _ name: String) -> MetricSpec {
        MetricSpec(key: key, unit: unit, group: nil, variant: "ALG-150", method: "ALG-150@1 \(name)", tier: .estimate,
                   source: "R18+rr", window: "night", citation: citation, paramsVersion: "gap90min short120min awake1min")
    }

    public static let totalSpec = spec(.sleepTotal, "min", "tst")
    public static let latencySpec = spec(.sleepLatency, "min", "latency")
    public static let wasoSpec = spec(.waso, "min", "waso")
    public static let remLatencySpec = spec(.remLatency, "min", "rem-latency")
    public static let efficiencySpec = spec(.sleepEfficiency, "fraction", "efficiency-asleep-over-window")
    public static let awakeningsSpec = spec(.awakenings, "count", "awakenings")
    public static let performanceSpec = spec(.sleepPerformance, "fraction", "performance-got-over-need")

    /// sleep_total, sleep_latency, waso, rem_latency, sleep_efficiency, awakenings, sleep_performance, sleep_onset,
    /// wake_time for the night that ends at `at` (the wake time, D13), from the strap-night accounting.
    public static func metrics(_ acc: Computed<Accounting>, needMin: Computed<Double>, at: Date) -> [Metric] {
        [
            totalSpec.metric(acc.map(\.tstMin), at: at),
            latencySpec.metric(acc.flatMap(\.latencyMin), at: at),
            wasoSpec.metric(acc.map(\.wasoMin), at: at),
            remLatencySpec.metric(acc.flatMap(\.remLatencyMin), at: at),
            efficiencySpec.metric(acc.flatMap(\.efficiency), at: at),
            awakeningsSpec.metric(acc.map { Double($0.awakenings) }, at: at),
            performanceSpec.metric(acc.flatMap { performance(tstMin: $0.tstMin, needMin: needMin) }, at: at),
            ALG030.onsetSpec.metric(acc.map { Double($0.sleepOnset) }, at: at),
            ALG030.wakeSpec.metric(acc.map { Double($0.wakeTime) }, at: at),
        ]
    }
}
