import SwiftUI
import MGContext
import MGDesign

// The animated breathing pacer (APP-024; UX §6 "Breathe (pacer + coherence)"). Owner: WP-29.
//
// Where the pacer is comes from `BreatheState.pacer(at:)` (pure arithmetic in MGContext); this file only draws it:
// - a circle that grows while breathing in and shrinks while breathing out, cosine-eased so it slows at the turns;
// - Reduce Motion: the circle stays still; the words "Breathe in" / "Breathe out" change with a 150 ms fade and a
//   seconds count ("4") shows instead (UX §1.4: every animation becomes a 150 ms fade or nothing);
// - iPhone haptics only (BRIEF default 4 — the strap never buzzes): a soft tap at the start of each inhale, a lighter
//   one at each exhale, a success tap when the time is up. Silent when Mo turned them off or under quiet hours.

struct GuidedPacer: View {
    let state: BreatheState
    /// Mo's preference AND not quiet hours — decided by the caller.
    let haptics: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: state.phase != .running)) { context in
            let point = state.pacer(at: context.date)
            GuidedPacerFace(point: point, reduceMotion: reduceMotion)
                .sensoryFeedback(trigger: GuidedPacerCue(point)) { old, new in
                    GuidedPacerCue.feedback(old: old, new: new, enabled: haptics)
                }
        }
    }
}

/// The value the haptics watch: it changes exactly once per turn (and once at the end).
struct GuidedPacerCue: Equatable {
    let index: Int
    let half: BreathePacerPoint.Half?
    let finished: Bool

    init(_ point: BreathePacerPoint?) {
        index = point?.cueIndex ?? -1
        half = point?.half
        finished = point?.finished ?? false
    }

    static func feedback(old: GuidedPacerCue, new: GuidedPacerCue, enabled: Bool) -> SensoryFeedback? {
        guard enabled, old != new, new.index >= 0, let half = new.half else { return nil }
        if new.finished { return old.finished ? nil : .success }
        switch half {
        case .inhale: return .impact(flexibility: .soft, intensity: 0.9)
        case .exhale: return .impact(flexibility: .soft, intensity: 0.5)
        }
    }
}

struct GuidedPacerFace: View {
    let point: BreathePacerPoint?
    let reduceMotion: Bool
    @Environment(\.mgColors) private var colors

    /// Circle scale when the lungs are empty; full = 1.
    private let emptyScale: CGFloat = 0.42

    var body: some View {
        let fullness = CGFloat(point?.fullness ?? 0)
        let scale = reduceMotion ? 1 : emptyScale + (1 - emptyScale) * fullness
        ZStack {
            // The outer guide = full lungs.
            Circle()
                .strokeBorder(colors.rule.color, lineWidth: 1.5)
            Circle()
                .fill(colors.focus.opacity(reduceMotion ? 0.12 : 0.18).color)
                .scaleEffect(scale)
            Circle()
                .strokeBorder(colors.focus.color, lineWidth: 2)
                .scaleEffect(scale)
            VStack(spacing: 4) {
                Text(word)
                    .mgFont(.headline)
                    .foregroundStyle(colors.ink.color)
                    .contentTransition(.opacity)
                if reduceMotion, let point, !point.finished {
                    Text("\(point.secondsLeftInHalf)")
                        .mgFont(.bigNumber)
                        .foregroundStyle(colors.ink.color)
                        .contentTransition(.opacity)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : nil, value: point?.half)
        }
        .frame(width: 240, height: 240)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(word)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var word: String {
        guard let point else { return "Ready" }
        if point.finished { return "Done" }
        return point.half == .inhale ? "Breathe in" : "Breathe out"
    }
}
