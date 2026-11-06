import Foundation
import MGDomain

// Sleep expanded (§B 1-10 of sleep-expanded-layouts-CHATGPT-2026-11-05.md): the breakdown the dashboard card opens into. Cells and the card are in
// SleepCardState.swift; a field with no data is a grey cell with its reason, never a made-up number.

/// One aligned track of the night explorer (§B4): points on the shared night clock, or a grey reason.
public struct SleepTrack: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var unit: String
    /// "from hr_5min" / "decoded, untested".
    public var caption: String?
    public var points: [LaneMark]
    public var reason: String?

    public init(id: String, title: String, unit: String, caption: String?, points: [LaneMark], reason: String?) {
        self.id = id
        self.title = title
        self.unit = unit
        self.caption = caption
        self.points = points
        self.reason = reason
    }
}

/// §B4: the synchronized night explorer.
public struct SleepExplorerState: Equatable, Sendable {
    public var window: NightClockWindow?
    /// The headline's own stages; empty with `hypnogramNote`.
    public var hypnogram: [StageSegment]
    public var hypnogramNote: String?
    /// "strap flag · asleep / awake only", "phone ALG-151 · deep and REM are estimates".
    public var hypnogramSource: String
    /// The Apple Watch's own stages, drawn under the headline's when the toggle is on, never merged. nil = none stored.
    public var watchOverlay: [StageSegment]?
    public var watchOverlayReason: String?
    public var tracks: [SleepTrack]

    public init(window: NightClockWindow?, hypnogram: [StageSegment], hypnogramNote: String?, hypnogramSource: String,
                watchOverlay: [StageSegment]?, watchOverlayReason: String?, tracks: [SleepTrack]) {
        self.window = window
        self.hypnogram = hypnogram
        self.hypnogramNote = hypnogramNote
        self.hypnogramSource = hypnogramSource
        self.watchOverlay = watchOverlay
        self.watchOverlayReason = watchOverlayReason
        self.tracks = tracks
    }
}

/// §B9: one trend row, medians over the last 7 / 30 / 90 nights.
public struct SleepTrendRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var d7: String?
    public var d30: String?
    public var d90: String?
    /// Grey reason when no window has data; otherwise "12 of 30 nights" style coverage of the 30-night window.
    public var note: String?

    public init(id: String, label: String, d7: String?, d30: String?, d90: String?, note: String?) {
        self.id = id
        self.label = label
        self.d7 = d7
        self.d30 = d30
        self.d90 = d90
        self.note = note
    }
}

/// §B8: one nap and what it did.
public struct SleepNapRow: Equatable, Sendable, Identifiable {
    public var id: String
    /// "11:05 AM–11:29 AM".
    public var range: String
    public var duration: String
    /// "ALG-033 · confirmed" / "unconfirmed".
    public var caption: String
    /// "Reduces tonight's need; does not change last night's score."
    public var effect: String

    public init(id: String, range: String, duration: String, caption: String, effect: String) {
        self.id = id
        self.range = range
        self.duration = duration
        self.caption = caption
        self.effect = effect
    }
}

/// §B: the whole expanded breakdown, in the spec's order.
public struct SleepBreakdownState: Equatable, Sendable {
    /// The same card as the dashboard (one source of truth; the "also:" line and the order of sources are identical).
    public var card: SleepCardState
    /// 1: summary and source rows with coverage per signal.
    public var summary: SleepGroup
    public var sourceRows: SleepGroup
    /// 2: one sentence.
    public var interpretation: String
    /// 3: the continuity equation and its parts; the `equation` is nil with `continuity.note` saying why.
    public var equation: String?
    public var continuity: SleepGroup
    /// 4.
    public var explorer: SleepExplorerState
    /// Stage rows (minutes, share of asleep time) under the explorer; empty when the headline has no stages.
    public var stages: SleepGroup
    /// 5: one card per overnight signal.
    public var physiology: [SleepGroup]
    /// 6: nil = no sleep score exists (the section is skipped).
    public var score: SleepGroup?
    /// 7.
    public var need: SleepGroup
    /// 8.
    public var naps: [SleepNapRow]
    public var napsNote: String?
    /// 9.
    public var trends: [SleepTrendRow]
    /// 10: the source / algorithm / version line.
    public var versionLine: String

    public init(card: SleepCardState, summary: SleepGroup, sourceRows: SleepGroup, interpretation: String,
                equation: String?, continuity: SleepGroup, explorer: SleepExplorerState, stages: SleepGroup,
                physiology: [SleepGroup], score: SleepGroup?, need: SleepGroup, naps: [SleepNapRow], napsNote: String?,
                trends: [SleepTrendRow], versionLine: String) {
        self.card = card
        self.summary = summary
        self.sourceRows = sourceRows
        self.interpretation = interpretation
        self.equation = equation
        self.continuity = continuity
        self.explorer = explorer
        self.stages = stages
        self.physiology = physiology
        self.score = score
        self.need = need
        self.naps = naps
        self.napsNote = napsNote
        self.trends = trends
        self.versionLine = versionLine
    }
}
