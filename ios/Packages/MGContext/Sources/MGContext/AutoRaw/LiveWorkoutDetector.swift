import Foundation

// r9q (Oct 17 2026, D-LOAD-WALK-2): the live "a workout is likely" detector. Pure: the app feeds it heart-rate beats,
// the zone-1 floor (ALG-106 via WorkoutZones) and a motion state; it says how likely a workout is and learns from Mo's
// yes / no answers. It only decides WHEN to ask and when to switch the raw streams on; the retrospective ALG-041
// detector (day pipeline) is the one that later confirms a workout. Nothing here is a clinical or published
// threshold: the starting numbers are engineering defaults, the learning is the documented update below.
//
// METHOD (docs/DECISIONS.md D-AUTO-WORKOUT-1):
//  1. Gate (a rule): the last `sustainMinutes` whole minutes, back to back, each have a mean heart rate at or above the
//     zone-1 floor. The floor is the POPULATION value (ALG-106: 50 % of HRmax, or of heart-rate reserve, the published
//     zone boundary) until Mo's answers move how readily the detector asks. Each minute needs `minSamples` beats.
//  2. Three features: margin = bpm above the floor (10 bpm units), rise = bpm above the quiet minutes before (10 bpm
//     units; a walk or a run starts from rest), motion = -1 wrist still / 0 unknown / +1 moving (raw motion only exists
//     when the 100 Hz stream is on, so it is usually 0).
//  3. p = sigmoid(w . [1, margin, rise, motion]). Ask when p >= `askProbability`.
//  4. D-POP-PRIOR: the weights START at the population weights W0 (engineering defaults: no published model exists for
//     "is this a workout" from wrist HR alone, so W0 is stated as a default, labelled as such) and move toward Mo's own:
//         w = W0 + Z * (wFit - W0),   Z = n / (n + k),   k = `shrinkageK` = 10
//     where n = his labelled answers and wFit = a logistic regression fitted to ALL his labels (full batch, gentle pull to
//     W0, each weight bounded within +-`weightBound` of W0). Z is the Buhlmann credibility weight: k is the number of
//     answers the population prior is "worth". k = 10 is a choice, not an estimate (one question a day: halfway at day
//     ten); it is the one number to change when there is enough data to estimate between- and within-person spread.
//     So a "No" lowers p for that kind of minute and a "Yes" raises it, a handful of answers move it a little, and it
//     can never learn "never ask" or "always ask" from a few answers. The screen says "population" (n = 0) or
//     "yours (n labels)".

/// Whether the wrist is moving now (from the raw 100 Hz stream when it is on, else unknown).
public enum MotionState: Int, Codable, Equatable, Sendable {
    case still = -1
    case unknown = 0
    case moving = 1
}

/// One whole minute of live heart rate.
public struct MinuteMean: Codable, Equatable, Sendable {
    public var minute: Int64      // Unix minute (seconds / 60)
    public var bpm: Double
    public var samples: Int

    public init(minute: Int64, bpm: Double, samples: Int) {
        self.minute = minute
        self.bpm = bpm
        self.samples = samples
    }
}

/// The last 20 whole minutes of live heart rate, one mean per minute. A minute is closed (and counted) when the first beat
/// of a later minute arrives, and counted only with at least `minSamples` beats in it. Memory: 20 small structs.
public struct HRMinuteRing: Equatable, Sendable {
    public static let keepMinutes = 20
    public static let minSamples = 20

    public private(set) var minutes: [MinuteMean] = []
    private var open: Int64?
    private var sum = 0.0
    private var count = 0

    public init() {}

    public mutating func add(at: Date, bpm: Double) {
        guard bpm.isFinite, bpm > 0 else { return }
        let m = Int64((at.timeIntervalSince1970 / 60).rounded(.down))
        if let o = open {
            if m < o { return }                      // a late beat from an older minute
            if m > o { close(); open = m }
        } else {
            open = m
        }
        sum += bpm
        count += 1
    }

    private mutating func close() {
        if let o = open, count >= Self.minSamples {
            minutes.append(MinuteMean(minute: o, bpm: sum / Double(count), samples: count))
            if minutes.count > Self.keepMinutes { minutes.removeFirst(minutes.count - Self.keepMinutes) }
        }
        sum = 0
        count = 0
    }

    /// How many whole minutes in a row, ending at the newest closed minute, were below `floor`. 0 when the newest closed
    /// minute is at or above it, or when none is closed. A missing minute in the middle ends the run.
    public func quietMinutes(below floor: Double) -> Int {
        var n = 0
        var expected: Int64?
        for m in minutes.reversed() {
            if let e = expected, m.minute != e { break }
            guard m.bpm < floor else { break }
            n += 1
            expected = m.minute - 1
        }
        return n
    }

    /// How many whole minutes in a row, ending at the newest closed minute, stayed within `spreadBpm` of each other (the
    /// burst chooser's "calm"). A missing minute ends the run.
    public func calmMinutes(spreadBpm: Double) -> Int {
        var n = 0
        var expected: Int64?
        var lo = Double.infinity
        var hi = -Double.infinity
        for m in minutes.reversed() {
            if let e = expected, m.minute != e { break }
            lo = min(lo, m.bpm)
            hi = max(hi, m.bpm)
            if hi - lo > spreadBpm { break }
            n += 1
            expected = m.minute - 1
        }
        return n
    }

    public mutating func reset() {
        self = HRMinuteRing()
    }
}

public struct WorkoutFeatures: Codable, Equatable, Sendable {
    /// Mean bpm of the sustained minutes above the zone-1 floor, in 10 bpm units, 0...5.
    public var margin: Double
    /// Mean bpm of the sustained minutes above the quiet minutes just before them, in 10 bpm units, -2...4 (0 when no
    /// earlier minutes are known).
    public var rise: Double
    /// -1 still, 0 unknown, +1 moving.
    public var motion: Double
    /// The first minute of the unbroken run at or above the floor (Unix minute): where the workout probably began.
    public var onsetMinute: Int64

    public init(margin: Double, rise: Double, motion: Double, onsetMinute: Int64) {
        self.margin = margin
        self.rise = rise
        self.motion = motion
        self.onsetMinute = onsetMinute
    }

    public var vector: [Double] { [1, margin, rise, motion] }
    public var onset: Date { Date(timeIntervalSince1970: TimeInterval(onsetMinute * 60)) }
}

/// The per-user part: four weights and how many answers shaped them. Decodes tolerantly (a wrong-sized vector = defaults).
public struct LiveWorkoutParams: Codable, Equatable, Sendable {
    /// bias, margin, rise, motion. Starting values are conservative: just at the floor with no rise asks nothing
    /// (p = 0.18); 10 bpm over the floor with a 15 bpm rise asks (p = 0.67); zone 3 or higher asks even from a standing start.
    public static let defaultWeights: [Double] = [-1.5, 1.0, 0.8, 0.7]
    public var weights: [Double]
    public var yes: Int
    public var no: Int

    /// "population" until the first answer, then "yours (n labels)" with how much of the way the weights have moved.
    public var provenance: String {
        let n = yes + no
        if n == 0 { return "population" }
        let share = Double(n) / (Double(n) + LiveWorkoutDetector.shrinkageK)
        let z = Int((share * 100).rounded())
        let noun = n == 1 ? "label" : "labels"
        return "yours (\(n) \(noun), \(z) % of the way from the population values)"
    }

    public init(weights: [Double] = LiveWorkoutParams.defaultWeights, yes: Int = 0, no: Int = 0) {
        self.weights = weights.count == 4 && weights.allSatisfy({ $0.isFinite }) ? weights : Self.defaultWeights
        self.yes = yes
        self.no = no
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let w = (try? c.decodeIfPresent([Double].self, forKey: .weights)) ?? nil
        self.init(weights: w ?? Self.defaultWeights,
                  yes: ((try? c.decodeIfPresent(Int.self, forKey: .yes)) ?? nil) ?? 0,
                  no: ((try? c.decodeIfPresent(Int.self, forKey: .no)) ?? nil) ?? 0)
    }

    private enum CodingKeys: String, CodingKey { case weights, yes, no }
}

public enum LiveWorkoutDetector {
    /// Minutes in a row at or above the zone-1 floor before anyone is asked. Why 3: ALG-041 (the confirming detector)
    /// needs 12 minutes, which is too late to catch the start; one or two minutes is a staircase or a sprint to a bus. Three
    /// whole minutes at zone 1 or more is the first point where walking uphill, a warm-up or a jog is already different
    /// from a burst, and a false start costs only a few minutes of raw streams (capped per day).
    public static let sustainMinutes = 3
    /// Quiet minutes just before the sustained ones that set the "rise" baseline: up to 5 within the 15 before.
    public static let baselineMinutes = 5
    public static let baselineSpanMinutes = 15
    public static let askProbability = 0.5
    /// Shrinkage constant k (see the header): Z = n / (n + k).
    public static let shrinkageK = 10.0
    /// The most any weight can move from its population value.
    public static let weightBound = 1.5
    /// Full-batch fit: iterations, step, and the gentle pull back to the population weights.
    public static let fitIterations = 150
    public static let fitStep = 0.5
    public static let fitPull = 0.1

    public static func features(ring: HRMinuteRing, floorBpm: Double, motion: MotionState) -> WorkoutFeatures? {
        guard floorBpm.isFinite, floorBpm > 0 else { return nil }
        let all = ring.minutes
        guard all.count >= sustainMinutes else { return nil }
        let tail = Array(all.suffix(sustainMinutes))
        for i in 1..<tail.count where tail[i].minute != tail[i - 1].minute + 1 { return nil }
        guard tail.allSatisfy({ $0.bpm >= floorBpm }) else { return nil }
        let mean = tail.map(\.bpm).reduce(0, +) / Double(tail.count)

        // Where the unbroken elevated run began (walk back from the sustained minutes).
        var onset = tail[0].minute
        for m in all.dropLast(sustainMinutes).reversed() {
            guard m.minute == onset - 1, m.bpm >= floorBpm else { break }
            onset = m.minute
        }
        // Baseline: the quiet minutes just before the run began.
        let before = all.filter { $0.minute < onset && $0.minute >= onset - Int64(baselineSpanMinutes) && $0.bpm < floorBpm }
            .suffix(baselineMinutes)
        var rise = 0.0
        if !before.isEmpty {
            rise = (mean - before.map(\.bpm).reduce(0, +) / Double(before.count)) / 10
        }
        return WorkoutFeatures(margin: min(max((mean - floorBpm) / 10, 0), 5), rise: min(max(rise, -2), 4),
                               motion: Double(motion.rawValue), onsetMinute: onset)
    }

    public static func probability(_ p: LiveWorkoutParams, _ f: WorkoutFeatures) -> Double {
        let z = zip(p.weights, f.vector).map { $0 * $1 }.reduce(0, +)
        return 1 / (1 + exp(-z))
    }

    /// The population weights moved toward Mo's own by his labels (D-POP-PRIOR). Deterministic: the same labels always give
    /// the same weights, whatever order they arrived in.
    public static func refit(labels: [WorkoutLabel]) -> LiveWorkoutParams {
        let n = labels.count
        let yes = labels.filter { $0.workout }.count
        guard n > 0 else { return LiveWorkoutParams() }
        let w0 = LiveWorkoutParams.defaultWeights
        var w = w0
        for _ in 0..<fitIterations {
            var grad = [Double](repeating: 0, count: 4)
            for l in labels {
                let x = l.features.vector
                let z = zip(w, x).map { $0 * $1 }.reduce(0, +)
                let err = (l.workout ? 1.0 : 0.0) - 1 / (1 + exp(-z))
                for i in 0..<4 { grad[i] += err * x[i] / Double(n) }
            }
            for i in 0..<4 {
                w[i] += fitStep * (grad[i] - fitPull * (w[i] - w0[i]))
                w[i] = min(max(w[i], w0[i] - weightBound), w0[i] + weightBound)
            }
        }
        let z = Double(n) / (Double(n) + shrinkageK)
        let blended = (0..<4).map { w0[$0] + z * (w[$0] - w0[$0]) }
        return LiveWorkoutParams(weights: blended, yes: yes, no: n - yes)
    }
}

/// What the raw streams should be, given the saved switch and the automatic reasons. The saved switch is never changed by
/// the automatic switching; when the automatic reasons end, the stream is exactly what Mo saved.
public enum AutoStreams {
    public static func effective(saved: Bool, autoOn: Bool) -> Bool { saved || autoOn }
}
