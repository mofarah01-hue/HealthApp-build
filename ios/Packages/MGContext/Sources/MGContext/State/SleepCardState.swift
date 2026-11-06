import Foundation
import MGDomain

// Sleep card (Mo, Nov 5 2026): "the primary is always shown first ... if you click to expand a card, whether in Explore or
// the sleep thing, we get a full breakdown of sleep". The dashboard card (§A) and the expanded breakdown (§B 1-10) of
// sleep-expanded-layouts-CHATGPT-2026-11-05.md. Every figure here comes from the ONE sleep resolver (`sleepFill()`); a field with no
// data is a grey cell with its reason, never a made-up number.

/// One labelled figure: `text` is nil when there is no data, and then `reason` says why (drawn grey).
public struct SleepCell: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var text: String?
    /// Who measured it and what kind of number it is ("WHOOP sleep HRV (RMSSD)", "estimate", "decoded, untested").
    public var caption: String?
    public var reason: String?
    /// Deep / REM minutes and other staged figures: drawn with their estimate label.
    public var isEstimate: Bool

    public init(id: String, label: String, text: String?, caption: String? = nil, reason: String? = nil,
                isEstimate: Bool = false) {
        self.id = id
        self.label = label
        self.text = text
        self.caption = caption
        self.reason = reason
        self.isEstimate = isEstimate
    }

    /// A cell with no data: grey, with the reason.
    public static func grey(_ id: String, _ label: String, _ reason: String) -> SleepCell {
        SleepCell(id: id, label: label, text: nil, reason: reason)
    }

    public var isGrey: Bool { text == nil }
}

/// A group of cells under a heading (a physiology card, the source rows, the need block).
public struct SleepGroup: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var cells: [SleepCell]
    /// One plain line under the cells (coverage, caveat, how to read it).
    public var note: String?

    public init(id: String, title: String, cells: [SleepCell], note: String? = nil) {
        self.id = id
        self.title = title
        self.cells = cells
        self.note = note
    }
}

/// §A: the dashboard sleep card.
public struct SleepCardState: Equatable, Sendable {
    /// "Strap · primary · 96% HR coverage", "WHOOP via Apple Health · fallback".
    public var pill: String
    /// True when the headline is Apple Health's night because our own raw data had none.
    public var isFallback: Bool
    /// "2 sources · review" when the other sources differ from the headline by more than `SleepBreakdownPresenter.reviewMinutes`.
    public var reviewBadge: String?
    /// "7 h 18": the duration, first and large. nil with `blankReason` when there is no night.
    public var durationText: String?
    public var blankReason: String?
    /// "11:12 PM–7:04 AM"; nil when the source gave no window.
    public var windowText: String?
    /// "of 8 h 05 need"; nil when no sleep need exists.
    public var needText: String?
    /// "Sleep performance 90%"; beside the duration, never above it. nil without one.
    public var scoreText: String?
    /// The one-line hypnogram (the headline's own source); empty with `hypnogramNote` when none.
    public var hypnogram: [StageSegment]
    public var hypnogramNote: String?
    /// At most three, measured ones only.
    public var facts: [SleepCell]
    /// One sentence.
    public var story: String
    /// HRV with its labelled kind, resting HR, temperature deviation: each against your baseline where there is one.
    public var physiology: [SleepCell]
    /// "also: WHOOP 7 h 18 · Watch 7 h 44" (the resolver's line); nil when no other source.
    public var alsoLine: String?
    public var openIntent: UIIntent
    /// Which of the card's states this is (the words and the skeleton follow it; the card keeps its look).
    public var phase: SleepCardPhase = .done
    /// While downloading: the strap's clock time reached, the percent and the time left.
    public var progress: SleepCardProgress?
    /// Not processed: what we do have ("Live heart rate: ... · Apple Health: not here yet (459 batches waiting)").
    public var haveLine: String?
    /// Fallback in use: why ours is not shown and that it replaces this when it arrives.
    public var fallbackNote: String?
    /// The "Process now" button's intent; nil unless the night is not processed and not already coming down.
    public var processIntent: UIIntent?

    public init(pill: String, isFallback: Bool, reviewBadge: String?, durationText: String?, blankReason: String?,
                windowText: String?, needText: String?, scoreText: String?, hypnogram: [StageSegment],
                hypnogramNote: String?, facts: [SleepCell], story: String, physiology: [SleepCell], alsoLine: String?,
                openIntent: UIIntent = .openNight(nil)) {
        self.pill = pill
        self.isFallback = isFallback
        self.reviewBadge = reviewBadge
        self.durationText = durationText
        self.blankReason = blankReason
        self.windowText = windowText
        self.needText = needText
        self.scoreText = scoreText
        self.hypnogram = hypnogram
        self.hypnogramNote = hypnogramNote
        self.facts = facts
        self.story = story
        self.physiology = physiology
        self.alsoLine = alsoLine
        self.openIntent = openIntent
    }
}
