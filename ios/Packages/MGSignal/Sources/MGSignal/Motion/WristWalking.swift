import Foundation
import MGDomain

/// T118 walking bouts, steps and cadence from the 100 Hz raw accelerometer (R21). Pure functions, no I/O.
///
/// Steps are peaks of the band-passed magnitude (7-sample boxcar minus a 2 s boxcar baseline); a bout is a chain of at least
/// `minSteps` peaks whose gaps lie in the cadence band 1.2-2.8 Hz and change by at most 30 % from one gap to the next. A
/// faster shake, a still wrist or irregular arm movement chains nothing. Only full buffers (100 samples, sample i at
/// ts + i/100 s) in unbroken seconds are used, like `RawMotion.gaitWindows`. The peak height is in g at the unconfirmed
/// 1/4096 g per count (see `RawMotion.gravityCheck`), so it is a threshold, not a reported value. A step the wrist swing
/// splits into two peaks inside one gap breaks the chain, so a wrist can under-count. Raw motion has not been checked on a
/// real capture. Gait speed and step length are not produced: from a wrist they are too rough. Apple's gait comes from the
/// iPhone and is kept apart (T63).
public enum WristWalking {
    /// Every figure from here is shown with this label.
    public static let label = "estimate, wrist-based"
    public static let minSteps = 8
    public static let cadenceHz = (1.2, 2.8)
    public static let minPeakG = 0.1
    public static let maxGapChange = 0.3

    public struct Bout: Sendable, Equatable {
        /// Unix seconds of the first and last step.
        public var start: Double
        public var end: Double
        public var steps: Int
        /// Steps per minute over the bout, an estimate.
        public var cadence: Double
    }

    public struct Result: Sendable, Equatable {
        public var bouts: [Bout]
        public var steps: Int { bouts.reduce(0) { $0 + $1.steps } }
    }

    public static func bouts(_ seconds: [MotionSecond]) -> Computed<Result> {
        let full = seconds.filter { $0.accelCount == 100 && $0.columns != nil }.sorted { $0.ts < $1.ts }
        guard !full.isEmpty else { return .missing("no full 100-sample raw accelerometer seconds") }
        var runs: [[MotionSecond]] = []
        for s in full {
            if let last = runs.last?.last, s.ts == last.ts + 1 { runs[runs.count - 1].append(s) }
            else if runs.last?.last?.ts != s.ts { runs.append([s]) }
        }
        return .success(Result(bouts: runs.flatMap(bouts(inRun:))))
    }

    private static func bouts(inRun run: [MotionSecond]) -> [Bout] {
        let mag = run.flatMap { RawMotion.magnitudes($0.columns ?? []) }
        let f = bandpassed(mag)
        let threshold = minPeakG * RawMotion.lsbPerG
        var peaks: [Int] = []
        if f.count > 2 {
            for i in 1..<(f.count - 1) where f[i] > threshold && f[i] > f[i - 1] && f[i] >= f[i + 1] { peaks.append(i) }
        }
        let lo = 100 / cadenceHz.1, hi = 100 / cadenceHz.0
        var out: [Bout] = []
        var chain: [Int] = []
        func close() {
            if chain.count >= minSteps, let a = chain.first, let b = chain.last {
                let t0 = Double(run[0].ts)
                out.append(Bout(start: t0 + Double(a) / 100, end: t0 + Double(b) / 100, steps: chain.count,
                                cadence: 60 * Double(chain.count - 1) / (Double(b - a) / 100)))
            }
            chain = []
        }
        for p in peaks {
            if let last = chain.last {
                let gap = Double(p - last)
                var ok = gap >= lo && gap <= hi
                if ok, chain.count >= 2 {
                    let prev = Double(last - chain[chain.count - 2])
                    ok = abs(gap - prev) <= maxGapChange * prev
                }
                if !ok { close() }
            }
            chain.append(p)
        }
        close()
        return out
    }

    public static let stepsSpec = MetricSpec(
        key: .wristWalkSteps, unit: "count", group: nil, variant: "T118", method: "T118@1 wrist-walking-bouts",
        tier: .estimate, source: "r21", window: "day", citation: "ours (T118); band-passed magnitude peaks in a 1.2-2.8 Hz chain",
        paramsVersion: "peak0.1g min8steps cadence1.2-2.8Hz gap30%")
    public static let cadenceSpec = MetricSpec(
        key: .wristWalkCadence, unit: "steps_min", group: nil, variant: "T118", method: "T118@1 wrist-walking-bouts",
        tier: .estimate, source: "r21", window: "day", citation: "ours (T118); band-passed magnitude peaks in a 1.2-2.8 Hz chain",
        paramsVersion: "peak0.1g min8steps cadence1.2-2.8Hz gap30%")

    /// The day's two wrist-walking metrics: total steps in bouts and the step-weighted mean cadence; both labelled
    /// `label`. No raw motion = both blank with the reason; no bout = steps 0 and a blank cadence.
    public static func dayMetrics(_ seconds: [MotionSecond], at: Date) -> [Metric] {
        switch bouts(seconds) {
        case .failure(let m):
            return [stepsSpec.blank(m.reason, at: at), cadenceSpec.blank(m.reason, at: at)]
        case .success(let r):
            let note = "\(label); \(r.bouts.count) walking bout(s)"
            guard r.steps > 0 else {
                return [stepsSpec.metric(.success(0), at: at, note: note),
                        cadenceSpec.blank("no walking bout (\(minSteps) steps in a row at 1.2-2.8 Hz) in today's raw motion", at: at)]
            }
            let mean = r.bouts.reduce(0) { $0 + $1.cadence * Double($1.steps) } / Double(r.steps)
            return [stepsSpec.metric(.success(Double(r.steps)), at: at, note: note),
                    cadenceSpec.metric(.success(mean), at: at, note: note)]
        }
    }

    /// r9o (D-LOAD-WALK-2): the walking-bout steps per MINUTE of the day (`origin` = local midnight, unix s), each bout spread over the
    /// minutes it spans in proportion to time. Empty when there are no full raw seconds (the caller labels it).
    public static func stepsByMinute(_ seconds: [MotionSecond], origin: Double) -> [Int: Double] {
        guard case .success(let r) = bouts(seconds) else { return [:] }
        return StepsMerge.spread(r.bouts.map { (start: $0.start, end: $0.end, steps: Double($0.steps)) }, origin: origin)
    }

    /// Minutes of the day holding at least `StepsMerge.coveredSeconds` full 100-sample raw seconds: where the model could see.
    public static func coveredMinutes(_ seconds: [MotionSecond], origin: Double) -> Set<Int> {
        var perMinute: [Int: Int] = [:]
        for s in seconds where s.accelCount == 100 && s.columns != nil {
            perMinute[Int((Double(s.ts) - origin) / 60), default: 0] += 1
        }
        return Set(perMinute.filter { $0.value >= StepsMerge.coveredSeconds && (0..<StepsMerge.minutesPerDay).contains($0.key) }.keys)
    }

    /// 7-sample centred boxcar minus 201-sample centred boxcar (edges use the samples that exist).
    private static func bandpassed(_ x: [Double]) -> [Double] {
        var prefix = [0.0]
        prefix.reserveCapacity(x.count + 1)
        for v in x { prefix.append(prefix[prefix.count - 1] + v) }
        func box(_ i: Int, _ half: Int) -> Double {
            let a = max(0, i - half), b = min(x.count - 1, i + half)
            return (prefix[b + 1] - prefix[a]) / Double(b - a + 1)
        }
        return (0..<x.count).map { box($0, 3) - box($0, 100) }
    }
}
