import Foundation

/// The guided MG ECG reading (APP-033; wave W8, 2026-10-11): ready (finger on the sensor) → recording (live waveform,
/// countdown, the strap's contact and progress) → result (HR from our R-peaks, research tier; the strap's own screen,
/// with its code; saved). Built by the app from the strap's R17 packets; values computed by MGSignal ALG014.
public struct EcgReadingState: Equatable, Sendable {
    public enum Phase: String, Sendable, CaseIterable {
        case ready, starting, recording, result, blocked
    }

    public var sample: Bool
    public var phase: Phase
    /// "left" / "right": the wrist the strap is on.
    public var wrist: String
    /// What to do, in order.
    public var steps: [String]
    public var seconds: Int
    public var startedAt: Date?
    public var endsAt: Date?
    /// The last few seconds of filtered samples, raw counts (no voltage scale is established), oldest first.
    public var trace: [Double]
    /// "Contact: yes · quality 3 · strap progress 40 %" — the strap's own status bytes, raw meanings.
    public var statusLine: String?
    public var packets: Int
    public var result: EcgReadingResult?
    /// Why it cannot run (phase blocked) or why it stopped.
    public var blankReason: String?
    // P9821 (2026-10-15): the live card. Set after init (defaults keep older call sites working).
    /// Seconds left of the 5 s lead-in (nil once recording or before it starts); nothing is kept during it.
    public var leadInSecondsLeft: Int?
    /// Live heart rate from our R-peaks over the last 8 s, "72 bpm", or nil with `liveHeartRateReason`.
    public var liveHeartRate: String?
    public var liveHeartRateReason: String?
    /// "Contact: yes" / "Contact: not yet" (the strap's own electrode flag); nil before any packet.
    public var contactLine: String?
    /// The waveform drawn is the display-filtered one (0.5-40 Hz band-pass + powerline notch) or the unfiltered counts.
    public var filtered: Bool = true
    /// Waveform enlarged to the whole recording so far (tap to expand).
    public var expanded: Bool = false
    /// "Filtered: 0.5-40 Hz band-pass + 60 Hz-alias notch, zero-phase · display only, the saved samples are raw" or
    /// "Unfiltered counts · decoded, untested, no voltage scale".
    public var traceLabel: String = ""

    public init(sample: Bool, phase: Phase, wrist: String, steps: [String], seconds: Int, startedAt: Date?, endsAt: Date?,
                trace: [Double], statusLine: String?, packets: Int, result: EcgReadingResult?, blankReason: String?) {
        self.sample = sample
        self.phase = phase
        self.wrist = wrist
        self.steps = steps
        self.seconds = seconds
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.trace = trace
        self.statusLine = statusLine
        self.packets = packets
        self.result = result
        self.blankReason = blankReason
    }
}

/// One line of the result's breakdown: a label, the value, and a short note that says what it means or why it is blank.
public struct EcgBreakdownRow: Equatable, Sendable {
    public var label: String
    public var value: String
    public var note: String?

    public init(label: String, value: String, note: String? = nil) {
        self.label = label
        self.value = value
        self.note = note
    }
}

public struct EcgReadingResult: Equatable, Sendable {
    /// "72 bpm" or nil (then `heartRateReason`).
    public var heartRate: String?
    public var heartRateReason: String?
    /// "Research tier · R-peaks (Pan-Tompkins) · 37 beats · rate 100 Hz measured".
    public var heartRateNote: String
    /// "Strap's screen: … — code 1." (the disclaimer sentence was removed 2026-10-11 at Mo's request, tracker #89)
    public var strapScreen: String
    /// "The strap's own average: 71 bpm" or nil.
    public var strapHeartRate: String?
    /// "Saved 09:41 · samples on the phone, raw frames go to the PC" or why not.
    public var saved: String
    /// "Recorded with raw optical: 38 R20 records on the same phone clock" / raw motion likewise; empty = neither on.
    public var together: [String]
    /// The whole recording (decimated for drawing), raw counts.
    public var trace: [Double]
    /// The same recording through the display filter (decimated); empty when the sample rate is not established.
    public var filteredTrace: [Double] = []
    /// T9821: the reading in plain words, in order: heart rate, R-R spread, signal quality, contact, rhythm (MGSignal
    /// `EcgBreakdown`). Research tier; empty when no records arrived.
    public var breakdown: [EcgBreakdownRow] = []

    public init(heartRate: String?, heartRateReason: String?, heartRateNote: String, strapScreen: String,
                strapHeartRate: String?, saved: String, together: [String], trace: [Double]) {
        self.heartRate = heartRate
        self.heartRateReason = heartRateReason
        self.heartRateNote = heartRateNote
        self.strapScreen = strapScreen
        self.strapHeartRate = strapHeartRate
        self.saved = saved
        self.together = together
        self.trace = trace
    }
}
