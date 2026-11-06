import Foundation

/// ALG-050 — the PVT-B run itself (the 3-minute reaction test's clock), pure and seeded so it can be tested.
///
/// Basner, Mollicone & Dinges 2011 (Acta Astronaut 69:949–959, PMC3197786) §2.2–2.3, read 2026-10-11: PVT-B lasts
/// 3 min; "inter-stimulus intervals varied randomly from 1–4 s (including a 1 s RT feedback interval)"; a stimulus with
/// no response for 30 s counts as a lapse; "responses without a stimulus or RTs < 100 ms were counted as false
/// starts"; lapse = RT ≥ 355 ms for the PVT-B. A 3-min PVT-B gave 62.3 stimuli on average.
/// NOTE: the brief asked for 2–10 s foreperiods — that is the 10-min PVT's ISI; the PVT-B (and its 355-ms lapse
/// threshold) uses 1–4 s, so 1–4 s is used here (`isiMinSeconds` / `isiMaxSeconds`, one line each to change).
///
/// Ours: a press with no stimulus also restarts the interval (no catching the next stimulus by tapping early); a
/// stimulus still open at 3:00 is dropped; the onset is the moment `advance` shows it (the view draws it that frame,
/// so every RT carries the same ≤ 1-frame offset).
extension ALG050 {
    public static let testSeconds = 180.0
    public static let feedbackSeconds = 1.0
    public static let isiMinSeconds = 1.0
    public static let isiMaxSeconds = 4.0
    public static let timeoutSeconds = 30.0

    /// SplitMix64: a small seeded generator so a run's intervals can be replayed in tests.
    public struct SeededRandom: RandomNumberGenerator, Sendable {
        var state: UInt64

        public init(seed: UInt64) { state = seed }

        public mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    public struct Run: Sendable {
        public enum Phase: Equatable, Sendable {
            /// Blank (the first second after a response shows its feedback) until the stimulus at `stimulusAt`.
            case waiting(stimulusAt: Double)
            /// The counter is running since `since`.
            case stimulus(since: Double)
            case done
        }

        public enum Feedback: Equatable, Sendable {
            case rt(Double)
            case falseStart
            case noResponse
        }

        public private(set) var startedAt: Double
        public private(set) var phase: Phase
        /// One entry per stimulus: RT in ms, or nil for no response within 30 s.
        public private(set) var rtMs: [Double?] = []
        public private(set) var pressesWithoutStimulus = 0
        public private(set) var lastFeedback: Feedback?
        public private(set) var lastFeedbackAt: Double?
        var rng: SeededRandom

        /// Clock values are seconds on one monotonic clock (the view uses CACurrentMediaTime).
        public init(startedAt: Double, seed: UInt64) {
            self.startedAt = startedAt
            rng = SeededRandom(seed: seed)
            phase = .done
            phase = .waiting(stimulusAt: startedAt + nextInterval())
        }

        public var endsAt: Double { startedAt + ALG050.testSeconds }
        public var finished: Bool { phase == .done }

        mutating func nextInterval() -> Double {
            Double.random(in: ALG050.isiMinSeconds...ALG050.isiMaxSeconds, using: &rng)
        }

        /// Moves the clock to `now`: shows a due stimulus, closes one unanswered for 30 s, ends the test at 3 min.
        public mutating func advance(to now: Double) {
            switch phase {
            case .done:
                return
            case .waiting(let at):
                if now >= endsAt {
                    phase = .done
                } else if now >= at {
                    phase = .stimulus(since: now)
                }
            case .stimulus(let since):
                if now >= endsAt {
                    phase = .done
                } else if now - since >= ALG050.timeoutSeconds {
                    rtMs.append(nil)
                    lastFeedback = .noResponse
                    lastFeedbackAt = now
                    phase = .waiting(stimulusAt: now + nextInterval())
                }
            }
        }

        /// A tap at `at`: a response to the running counter, or a false start.
        public mutating func press(at: Double) {
            switch phase {
            case .done:
                return
            case .stimulus(let since):
                let rt = max(0, at - since) * 1000
                rtMs.append(rt)
                lastFeedback = .rt(rt)
                lastFeedbackAt = at
                phase = .waiting(stimulusAt: at + nextInterval())
            case .waiting:
                pressesWithoutStimulus += 1
                lastFeedback = .falseStart
                lastFeedbackAt = at
                phase = .waiting(stimulusAt: at + nextInterval())
            }
            if at >= endsAt { phase = .done }
        }

        public func score() -> Computed<ALG050.Score> {
            ALG050.score(rtMs: rtMs, pressesWithoutStimulus: pressesWithoutStimulus)
        }
    }
}
