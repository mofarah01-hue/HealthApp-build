import Foundation
import MGDomain

/// ALG-050 v1 — PVT-B scoring (the 3-minute psychomotor vigilance test on the phone). Basner, Mollicone & Dinges 2011
/// (Acta Astronaut 69:949–959): a lapse is a response time ≥ 355 ms or no response; a false start is a response under
/// 100 ms or a press with no stimulus; response speed = mean of 1/RT (their most sensitive outcome). `meanRtMs` is the
/// plain mean of the valid responses (≥ 100 ms), lapses included; false starts and non-responses are not in it.
/// A test with fewer than 10 valid responses is Missing (ours: a 3-minute PVT-B has about 40–60).
/// Python reference: app/pclab/mglab/ref/behaviour.py `pvt_score`; goldens app/shared/golden/behaviour/ALG-050.json.
public enum ALG050 {
    public static let method = "ALG-050@1 pvt-b-355ms"
    public static let citation = "Basner M, Mollicone D, Dinges DF. Acta Astronaut 2011;69:949-959"
    public static let lapseMs = 355.0
    public static let falseStartMs = 100.0
    public static let minValid = 10

    public struct Score: Sendable, Equatable {
        public var meanRtMs: Double
        public var lapses: Int
        public var falseStarts: Int
        /// Stimuli presented (one entry of `rtMs` each).
        public var trials: Int
        /// Responses of 100 ms or more.
        public var valid: Int
        /// Mean of 1000 / RT over the valid responses, per second.
        public var responseSpeedPerS: Double

        public init(meanRtMs: Double, lapses: Int, falseStarts: Int, trials: Int, valid: Int, responseSpeedPerS: Double) {
            self.meanRtMs = meanRtMs
            self.lapses = lapses
            self.falseStarts = falseStarts
            self.trials = trials
            self.valid = valid
            self.responseSpeedPerS = responseSpeedPerS
        }
    }

    /// ALG-050 v1 — `rtMs` has one entry per stimulus: the response time in ms, or nil for no response.
    public static func score(rtMs: [Double?], pressesWithoutStimulus: Int = 0) -> Computed<Score> {
        guard pressesWithoutStimulus >= 0 else { return .missing("presses without a stimulus cannot be negative") }
        for r in rtMs {
            if let v = r, !(v.isFinite && v >= 0) {
                return .missing("a response time is negative or not a number")
            }
        }
        var falseStarts = pressesWithoutStimulus
        var valid: [Double] = []
        var noResponse = 0
        for r in rtMs {
            guard let v = r else {
                noResponse += 1
                continue
            }
            if v < falseStartMs { falseStarts += 1 } else { valid.append(v) }
        }
        var lapses = noResponse
        for v in valid where v >= lapseMs { lapses += 1 }
        guard valid.count >= minValid else {
            return .missing("needs at least \(minValid) valid responses (have \(valid.count))")
        }
        let speed = SignalMath.mean(valid.map { 1000.0 / $0 })
        return .success(Score(meanRtMs: SignalMath.mean(valid), lapses: lapses, falseStarts: falseStarts,
                              trials: rtMs.count, valid: valid.count, responseSpeedPerS: speed))
    }

    /// `pvt_mean_rt` (ms), window "test".
    public static let meanRtSpec = MetricSpec(
        key: .pvtMeanRt, unit: "ms", group: nil, variant: "ALG-050", method: method, tier: .high,
        source: "reaction test", window: "test", citation: citation, paramsVersion: "lapse355 fs100 min10")

    /// `pvt_lapses` (count), window "test".
    public static let lapsesSpec = MetricSpec(
        key: .pvtLapses, unit: "count", group: nil, variant: "ALG-050", method: method, tier: .high,
        source: "reaction test", window: "test", citation: citation, paramsVersion: "lapse355 fs100 min10")
}
