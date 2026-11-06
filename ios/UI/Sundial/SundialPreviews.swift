#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of the Sundial for every prototype scenario (MGContext `DialState.preview(for:)`, all SAMPLE), the
// Sundown page turn, the empty first-launch dial and the largest text size. Taps print their intent.

private struct SundialPreviewHost: View {
    let state: DialState
    let theme: ThemeName

    init(_ scenario: PreviewScenario) {
        state = DialState.preview(for: scenario)
        theme = SampleDay.context(at: scenario.now).theme
    }

    init(state: DialState, theme: ThemeName) {
        self.state = state
        self.theme = theme
    }

    var body: some View {
        MGScreen {
            SundialView(state: state)
                .padding(.vertical, 20)
        }
        .safeAreaInset(edge: .top, spacing: 0) { SampleBanner() }
        .environment(\.mgNow, state.now)
        .environment(\.mgSend, { intent in print("Sundial intent:", intent) })
        .mgTheme(theme)
    }
}

/// Flip between the workout-ended dial (last night at the bottom) and Sundown (tonight's plan, smart-wake window
/// hatched) to watch the night arc turn the page.
private struct SundialPageTurnDemo: View {
    @State private var tonight = false

    var body: some View {
        let scenario: PreviewScenario = tonight ? .sundown : .wend
        let state = DialState.preview(for: scenario)
        VStack(spacing: 12) {
            SundialView(state: state)
            Button(tonight ? "Back to last night" : "Turn the page (Sundown)") { tonight.toggle() }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(MGBackground())   // inside .mgTheme, so it paints this theme
        .environment(\.mgNow, state.now)
        .environment(\.mgSend, { intent in print("Sundial intent:", intent) })
        .mgTheme(SampleDay.context(at: scenario.now).theme)
    }
}

#Preview("1 · Just woke 07:05") { SundialPreviewHost(.woke) }
#Preview("2 · Mid-morning 09:40 · unconfirmed vape") { SundialPreviewHost(.morning) }
#Preview("3 · After lunch 13:50") { SundialPreviewHost(.lunch) }
#Preview("4 · Nap detected 14:40 · nap?") { SundialPreviewHost(.nap) }
#Preview("5 · Strap off 15:40 · cross-hatch") { SundialPreviewHost(.off) }
#Preview("6 · Workout live 17:45 · golden") { SundialPreviewHost(.wlive) }
#Preview("7 · Workout just ended 18:25") { SundialPreviewHost(.wend) }
#Preview("8 · Sundown 20:05 · tonight's plan") { SundialPreviewHost(.sundown) }
#Preview("9 · Bedtime 22:10") { SundialPreviewHost(.night) }
#Preview("10 · Late night 00:40 · bedtime missed") { SundialPreviewHost(.late) }
#Preview("Page turn at Sundown") { SundialPageTurnDemo() }

/// A stretch of last night without R-R: asleep, stage unknown — an outlined hatched band, never drawn as light.
#Preview("Just woke · asleep, stage unknown 02:45–03:36") {
    var state = DialState.preview(for: .woke)
    if let i = state.arcs.firstIndex(where: { $0.kind == .light && $0.start >= SampleDay.at(2, 40) }) {
        state.arcs[i].kind = .unstaged
    }
    return SundialPreviewHost(state: state, theme: SampleDay.context(at: state.now).theme)
}

/// UX §13 first launch, no strap: an empty ring with the hand only.
#Preview("Empty · first launch") {
    let now = SampleDay.at(9, 40)
    let state = DialState(
        sample: true, now: now, wake: nil, nightArc: .lastNight, arcs: [], caffeineCurve: [],
        rimEvents: [], ticks: [], hub: DialHub(kicker: "NO STRAP YET", big: "—", detail: "pair it to fill the dial"),
        callouts: DialCallout.Corner.allCases.map { DialCallout(corner: $0, value: nil, caption: "", tone: .mute, intent: nil) },
        legend: "", accessibilityLabel: "24-hour dial. Nothing recorded yet. Now 09:40.")
    return SundialPreviewHost(state: state, theme: .cream)
}

#Preview("Largest text · callouts below") {
    SundialPreviewHost(.morning)
        .environment(\.dynamicTypeSize, .accessibility3)
}

// MARK: 0.6 inner rings (invented round values only)

/// Bedtime (tonight's plan, smart-wake hatch, strap-off cross-hatch, workout, nap) with 3 vape hits (one unconfirmed),
/// a medication diamond and the first `count` of six invented rings: strain with a target, recovery, sleep, a blank
/// stress ring, burned, eaten (dashed). The strain ring and the two mark kinds have a sheet, so a tap opens it.
private func ringsDemo(_ count: Int) -> DialState {
    var state = DialState.preview(for: .night)
    let r = SampleDay.receipt(.phone, .estimate, 22, 0)
    let all = [
        DialRing(kind: .strain, title: "Strain", value: SampleDay.value("9.4", "/21", r, .estimate(nil)), fraction: 0.45,
                 target: 0.5...0.65),
        DialRing(kind: .recovery, title: "Recovery", value: SampleDay.value("82", "/100", r), fraction: 0.82,
                 detail: "in your range"),
        DialRing(kind: .sleep, title: "Sleep", value: SampleDay.value("7 h 10", nil, r), fraction: 0.9,
                 detail: "of 8 h need, est."),
        DialRing(kind: .stress, title: "Arousal", value: .blank(reason: "No body-arousal score yet today.", receipt: nil),
                 fraction: nil),
        DialRing(kind: .burn, title: "Burned", value: SampleDay.value("2,100", "kcal", r), fraction: 0.85),
        DialRing(kind: .eaten, title: "Eaten", value: SampleDay.value("1,600", "kcal", r), fraction: 0.75),
    ]
    state.rings = Array(all.prefix(count))
    let vapes = [SampleDay.at(9, 0), SampleDay.at(13, 30), SampleDay.at(19, 0)]
    state.rimEvents = vapes.enumerated().map {
        RimEvent(kind: .vape, at: $0.element, hollow: $0.offset == 1, eventID: "v\($0.offset)")
    }
        + [RimEvent(kind: .medication, at: SampleDay.at(7, 30), label: "Medication 20 mg", eventID: "m1")]
    state.legendItems = [
        DialLegendItem(id: "vape", glyph: "●", text: "vape ×3 · first 2 h after waking", tone: .body,
                       target: .mark(.vape, at: vapes[2])),
        DialLegendItem(id: "medication", glyph: "◆", text: "Medication 20 mg", tone: .ink,
                       target: .mark(.medication, at: SampleDay.at(7, 30))),
    ]
    state.details = [
        DialDetail(id: .ring(.strain), tone: .body, kicker: "Strain · today so far", title: "9.4 of 21",
                   value: all[0].value, sentence: "Inside today's target.",
                   visuals: [.ring(fraction: 0.45, target: 0.5...0.65)], visualSummary: "Strain ring, 45 % full."),
        DialDetail(id: .mark(.vape, at: vapes[2]), tone: .body, kicker: "Vape · 7:00 PM", title: "Vape hit"),
        DialDetail(id: .mark(.medication, at: SampleDay.at(7, 30)), tone: .ink, kicker: "Medication · 7:30 AM",
                   title: "Medication 20 mg"),
    ]
    return state
}

#Preview("Rings 0 · Day") { SundialPreviewHost(state: ringsDemo(0), theme: .cream) }
#Preview("Rings 2 · Day") { SundialPreviewHost(state: ringsDemo(2), theme: .cream) }
#Preview("Rings 4 · Day · blank stress") { SundialPreviewHost(state: ringsDemo(4), theme: .cream) }
#Preview("Rings 6 · Day · key scrolls") { SundialPreviewHost(state: ringsDemo(6), theme: .cream) }
#Preview("Rings 0 · Night") { SundialPreviewHost(state: ringsDemo(0), theme: .emerald) }
#Preview("Rings 2 · Night") { SundialPreviewHost(state: ringsDemo(2), theme: .emerald) }
#Preview("Rings 4 · Night · blank stress") { SundialPreviewHost(state: ringsDemo(4), theme: .emerald) }
#Preview("Rings 6 · Night · key scrolls") { SundialPreviewHost(state: ringsDemo(6), theme: .emerald) }
#endif
