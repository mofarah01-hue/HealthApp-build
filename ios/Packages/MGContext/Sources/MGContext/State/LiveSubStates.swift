import Foundation
import MGDomain

// R8j (audit 7.3, UI-SCRUB-B L8): the Live tab's pieces, each its own Equatable value. The views that draw them are wrapped in
// `.equatable()` (UI/Live/LiveView.swift), so a 1 Hz change in one piece (the heart rate) leaves the others' bodies alone.
// These are read-only slices of `LiveState`; nothing here is stored twice.

/// The wave rows (raw PPG ids and labels, motion, ECG) - no PPG samples while the smooth view draws from `LivePPGFeed`.
public struct LiveWavesSubState: Equatable, Sendable {
    public var rows: [LiveWaveRow]
    public init(rows: [LiveWaveRow]) { self.rows = rows }

    /// The raw PPG row has waves to draw.
    public var ppgDraws: Bool { rows.first(where: { $0.id == "ppg" })?.waves.isEmpty == false }
}

/// The Pulse wave box and what belongs under it.
public struct LivePulseSubState: Equatable, Sendable {
    public var samples: [Double]
    public var quality: String?
    public var sample: Bool
    public var blank: String
    public var note: String?
    public var cleanSamples: [Double]
    public var cleanChip: StreamChipState?
    public var cleanNote: String?
    /// The raw PPG row draws the same signal: the box is not shown, its note lines move into that card.
    public var hidden: Bool
}

/// The heart-rate line.
public struct LiveHRTraceSubState: Equatable, Sendable {
    public var points: [LiveHRPoint]
    public var end: Date?
    public var note: String?
}

/// The beat-to-beat chart.
public struct LiveTachogramSubState: Equatable, Sendable {
    public var points: [TachogramPoint]
    public var median: DisplayValue
    public var end: Date?
    public var note: String?
    public var blankReason: String?
}

extension LiveState {
    public var wavesPart: LiveWavesSubState { LiveWavesSubState(rows: waveRows) }

    public var pulsePart: LivePulseSubState {
        LivePulseSubState(samples: pulseWave, quality: pulseQuality, sample: sample, blank: pulseBlank, note: pulseNote,
                          cleanSamples: cleanWave, cleanChip: cleanChip, cleanNote: cleanNote,
                          hidden: pulseFromRaw && wavesPart.ppgDraws)
    }

    public var hrTracePart: LiveHRTraceSubState {
        LiveHRTraceSubState(points: hrTrace, end: hrTraceEnd, note: hrTraceNote)
    }

    public var tachogramPart: LiveTachogramSubState {
        LiveTachogramSubState(points: tachogram, median: tachogramMedian, end: hrTraceEnd, note: tachogramNote,
                              blankReason: blankReason)
    }
}
