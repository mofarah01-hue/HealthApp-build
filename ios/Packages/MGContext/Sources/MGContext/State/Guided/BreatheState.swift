import Foundation
import MGDomain

/// Breathe — the full-screen pacer flow (UX §6 ActionGrid "Breathe (pacer + coherence)"; UX §4.1 Night and Late-night
/// "Breathe" Now rows; Tonight's wind-down [Breathe now]). APP-024. Coherence is ALG-104 v1 (McCraty & Zayas 2014),
/// computed by MGSignal (`ALG104.coherence`) and handed in through `result` — never computed in a view.
///
/// Cues are iPhone haptics only: the strap buzz is not used here (BRIEF default 4).
/// Opened by `.startBreathe`; inside the flow: `.guided(.beginBreathe(perMinute:minutes:))`, `.guided(.endNow)`,
/// `.guided(.close)`. Built by WP-23's presenter.
public struct BreatheState: Equatable, Sendable {
    public enum Phase: String, Sendable, CaseIterable {
        /// Pick rate and length, then Start. A presenter may skip it and publish `.running` straight away.
        case ready = "ready"
        /// The pacer runs from `startedAt` to `endsAt`.
        case running = "running"
        /// Done or ended early: `result` holds what was measured (or why nothing was).
        case finished = "finished"
    }

    /// Default pace: 6 breaths a minute (0.1 Hz resonance breathing, ALG-104).
    public static let defaultBreathsPerMinute: Double = 6
    /// Default length: 5 minutes (UX §4.1 Night row "Breathe (pacer, 5 min)").
    public static let defaultMinutes: Int = 5
    /// `inhaleFraction` is clamped to this range so neither half can vanish.
    public static let inhaleFractionRange: ClosedRange<Double> = 0.2...0.8

    public var sample: Bool
    public var phase: Phase
    /// Breaths per minute the pacer leads.
    public var breathsPerMinute: Double
    /// Share of each breath spent breathing in (0.5 → 5 s in, 5 s out at 6 /min).
    public var inhaleFraction: Double
    public var minutes: Int
    /// Ready-screen choices (presenter's, e.g. 5 · 5.5 · 6 · 6.5 · 7 /min and 3 · 5 · 10 min).
    public var rateOptions: [Double]
    public var minuteOptions: [Int]
    /// Pacer clock: every breath is timed from here. nil before Start.
    public var startedAt: Date?
    /// Planned end (startedAt + minutes).
    public var endsAt: Date?
    /// Live HR from the strap, or blank with the reason.
    public var heartRate: DisplayValue
    /// R-R beats collected so far for coherence; nil = nothing is being collected (no strap).
    public var beatsCollected: Int?
    /// Why coherence will be missing, shown while running ("Strap not connected — the pacer runs, no coherence.").
    public var strapNote: String?
    /// Mo's preference for iPhone haptic cues (a soft tap at each turn). The view also stays silent while
    /// `\.mgQuietHaptics` is on (Night, Late night — UX §1.4).
    public var phoneHaptics: Bool
    /// "iPhone haptics only · strap buzz not used here".
    public var cueNote: String?
    public var result: BreatheResult?

    public init(sample: Bool, phase: Phase, breathsPerMinute: Double, inhaleFraction: Double, minutes: Int,
                rateOptions: [Double], minuteOptions: [Int], startedAt: Date?, endsAt: Date?, heartRate: DisplayValue,
                beatsCollected: Int?, strapNote: String?, phoneHaptics: Bool, cueNote: String?,
                result: BreatheResult?) {
        self.sample = sample
        self.phase = phase
        self.breathsPerMinute = breathsPerMinute
        self.inhaleFraction = inhaleFraction
        self.minutes = minutes
        self.rateOptions = rateOptions
        self.minuteOptions = minuteOptions
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.heartRate = heartRate
        self.beatsCollected = beatsCollected
        self.strapNote = strapNote
        self.phoneHaptics = phoneHaptics
        self.cueNote = cueNote
        self.result = result
    }

    /// Seconds per breath; nil when the rate is not a positive finite number.
    public var breathSeconds: Double? {
        guard breathsPerMinute.isFinite, breathsPerMinute > 0 else { return nil }
        return 60 / breathsPerMinute
    }

    /// The clamped inhale share (a non-finite value reads as 0.5).
    public var clampedInhaleFraction: Double {
        guard inhaleFraction.isFinite else { return 0.5 }
        return min(max(inhaleFraction, Self.inhaleFractionRange.lowerBound), Self.inhaleFractionRange.upperBound)
    }

    public var inhaleSeconds: Double? { breathSeconds.map { $0 * clampedInhaleFraction } }
    public var exhaleSeconds: Double? { breathSeconds.map { $0 * (1 - clampedInhaleFraction) } }

    /// Where the pacer is at `now` (pure arithmetic on the pacer clock; the view only draws it).
    /// nil unless running with a start and a valid rate. Before `startedAt` reads as the start; after `endsAt`
    /// it holds the last point (lungs empty, the final exhale finished).
    public func pacer(at now: Date) -> BreathePacerPoint? {
        guard phase == .running, let start = startedAt, let period = breathSeconds,
              let inhale = inhaleSeconds, let exhale = exhaleSeconds else { return nil }
        var t = max(0, now.timeIntervalSince(start))
        if let end = endsAt {
            let total = max(0, end.timeIntervalSince(start))
            if t >= total {
                let breaths = Int((total / period).rounded(.down))
                return BreathePacerPoint(half: .exhale, progress: 1, fullness: 0, cueIndex: 2 * breaths,
                                         secondsLeftInHalf: 0, breathsDone: breaths, finished: true)
            }
            t = min(t, total)
        }
        let k = (t / period).rounded(.down)
        let r = t - k * period
        let breaths = Int(k)
        if r < inhale {
            let p = inhale > 0 ? r / inhale : 1
            return BreathePacerPoint(half: .inhale, progress: p, fullness: (1 - cos(Double.pi * p)) / 2,
                                     cueIndex: 2 * breaths, secondsLeftInHalf: Int((inhale - r).rounded(.up)),
                                     breathsDone: breaths, finished: false)
        }
        let into = r - inhale
        let p = exhale > 0 ? min(1, into / exhale) : 1
        return BreathePacerPoint(half: .exhale, progress: p, fullness: (1 + cos(Double.pi * p)) / 2,
                                 cueIndex: 2 * breaths + 1, secondsLeftInHalf: Int((exhale - into).rounded(.up)),
                                 breathsDone: breaths, finished: false)
    }
}

/// One instant of the pacer.
public struct BreathePacerPoint: Equatable, Sendable {
    public enum Half: String, Sendable, CaseIterable {
        case inhale = "inhale"
        case exhale = "exhale"
    }

    public var half: Half
    /// 0…1 through the current half.
    public var progress: Double
    /// Circle size 0 (lungs empty) … 1 (full), cosine-eased so it slows at each turn.
    public var fullness: Double
    /// Half-breaths since the start (inhale 0, exhale 1, inhale 2, …): a new value = a turn = one haptic cue.
    public var cueIndex: Int
    /// Whole seconds left in this half, rounded up (the Reduce Motion count "in · 4").
    public var secondsLeftInHalf: Int
    /// Full breaths completed.
    public var breathsDone: Int
    /// The planned time is up.
    public var finished: Bool

    public init(half: Half, progress: Double, fullness: Double, cueIndex: Int, secondsLeftInHalf: Int,
                breathsDone: Int, finished: Bool) {
        self.half = half
        self.progress = progress
        self.fullness = fullness
        self.cueIndex = cueIndex
        self.secondsLeftInHalf = secondsLeftInHalf
        self.breathsDone = breathsDone
        self.finished = finished
    }
}

/// What a Breathe session measured. Every value comes from the presenter (MGSignal output); missing → blank + reason.
public struct BreatheResult: Equatable, Sendable {
    /// ALG-104 coherence ratio (peak power / the rest; HeartMath's emWave shows ln of it — we keep the ratio), or
    /// blank with why ("needs at least 60 s of R-R").
    public var coherence: DisplayValue
    /// "high for you" / "about your usual" — the presenter's words; nil when coherence is blank or has no history.
    public var coherenceWord: String?
    /// Where the heart rhythm peaked against the pace: "peak 0.100 Hz = 6.0 /min — on your pace".
    public var resonanceLine: String?
    /// Mean HR, RMSSD over the session (ALG-010), breathing rate by ALG-020 next to the pace (APP-031 known-answer
    /// check), minutes paced.
    public var rows: [LabeledValue]
    /// "Ended early at 3:40 of 5:00." / "Saved to the log."
    public var note: String?

    public init(coherence: DisplayValue, coherenceWord: String?, resonanceLine: String?, rows: [LabeledValue],
                note: String?) {
        self.coherence = coherence
        self.coherenceWord = coherenceWord
        self.resonanceLine = resonanceLine
        self.rows = rows
        self.note = note
    }
}
