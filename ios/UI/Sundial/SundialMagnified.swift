import SwiftUI
import MGContext
import MGDesign

/// The magnified Sundial (round 8, T10023; audit UI-SCRUB-A §5 step 4): the dial at the full screen width in a
/// full-screen cover, so the page behind cannot scroll and the dial is always in view.
///
/// Top to bottom: a Done chip, the info slot (a fixed height, so nothing moves under the finger), the dial. The slot
/// shows the ring being stepped through, else the ring picked (it stays after the finger lifts, and TAPPING IT opens
/// that ring's sheet), else the day's numbers at the scrubbed time, else a one-line hint. The dial is the same
/// `SundialDial` as on the page, with `magnified` set: rings in the wider zone, no hub text, the cards drawn here.
/// A tap on nothing, the hub or the backdrop leaves; a tap on a ring picks it; a tap on a mark or arc opens its sheet;
/// a drag never opens a sheet (`DialMagnify`).
struct SundialMagnifiedScreen: View {
    let state: DialState
    let index: DialScrubIndex?
    let scrubbing: Binding<Bool>
    /// The ring picked (kept after the finger lifts).
    let selectedRing: DialRing.Kind?
    let selectedMark: SundialMarkSelection?
    let open: (DialTarget) -> Void
    let onTap: (DialMagnify.Spot) -> Void
    let onCardTap: () -> Void
    let onDragEnded: (DialRing.Kind?) -> Void
    let onDone: () -> Void

    init(state: DialState, index: DialScrubIndex?, scrubbing: Binding<Bool>, selectedRing: DialRing.Kind?,
         selectedMark: SundialMarkSelection?, open: @escaping (DialTarget) -> Void,
         onTap: @escaping (DialMagnify.Spot) -> Void, onCardTap: @escaping () -> Void,
         onDragEnded: @escaping (DialRing.Kind?) -> Void, onDone: @escaping () -> Void) {
        self.state = state
        self.index = index
        self.scrubbing = scrubbing
        self.selectedRing = selectedRing
        self.selectedMark = selectedMark
        self.open = open
        self.onTap = onTap
        self.onCardTap = onCardTap
        self.onDragEnded = onDragEnded
        self.onDone = onDone
    }

    @Environment(\.mgColors) private var colors
    @Environment(\.mgQuietHaptics) private var quietHaptics

    /// What the finger is doing on the dial, mirrored from `SundialDial` for the slot.
    @State private var live: DialInteraction = .idle

    /// The slot's height: enough for the ring card (kicker, title, value, 3 rows) or the time card (7 lines).
    private static let slotHeight: CGFloat = 200

    var body: some View {
        GeometryReader { geo in
            let m = SundialMetrics(width: geo.size.width, magnified: true)
            ZStack {
                colors.sheet.color
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDone() }        // tap outside the dial leaves
                VStack(spacing: MGSpace.m) {
                    HStack {
                        Spacer()
                        Button(action: onDone) {
                            Text("Done")
                                .mgFont(.rowTitle)
                                .foregroundStyle(colors.ink.color)
                                .padding(.horizontal, MGSpace.l)
                                .frame(minHeight: MGSpace.tapTarget)
                                .mgSurface(.chip, radius: MGRadius.chip)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Done, close the magnified dial")
                    }
                    .padding(.horizontal, MGSpace.gutter)
                    slot
                        .padding(.horizontal, MGSpace.gutter)
                        .frame(maxWidth: .infinity, minHeight: Self.slotHeight, maxHeight: Self.slotHeight,
                               alignment: .bottom)
                    SundialDial(state: state, metrics: m, index: index, selectedRing: pickedRing,
                                selectedMark: selectedMark, scrubbing: scrubbing, magnified: true, showsCards: false,
                                open: open, onTap: onTap, onDragEnded: onDragEnded,
                                onInteraction: { live = $0 }, onMagnify: {})
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        // A tap on a ring picks it: one tick. Stepping through rings ticks from the live overlay in the dial.
        .sensoryFeedback(.selection, trigger: selectedRing) { _, new in new != nil && !quietHaptics }
    }

    /// The ring highlighted on the dial: the one being stepped through, else the one picked.
    private var pickedRing: DialRing.Kind? {
        if case .ringStep(let i) = live, state.rings.indices.contains(i) { return state.rings[i].kind }
        return selectedRing
    }

    @ViewBuilder
    private var slot: some View {
        if case .ringStep(let i) = live, state.rings.indices.contains(i) {
            SundialRingCard(state: state, kind: state.rings[i].kind)
        } else if case .timeScrub(let hour) = live, let reading = index?.reading(hour: hour), !reading.series.isEmpty {
            SundialTimeCard(reading: reading)
        } else if let kind = selectedRing, state.rings.contains(where: { $0.kind == kind }) {
            Button(action: onCardTap) {
                VStack(alignment: .trailing, spacing: 4) {
                    SundialRingCard(state: state, kind: kind)
                    Text("Tap the card for details")
                        .mgFont(.unit)
                        .foregroundStyle(colors.mute.color)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the details sheet")
        } else {
            Text("Tap a ring to pick it, or slide out from the centre. Slide round the rim to move through the day.")
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
