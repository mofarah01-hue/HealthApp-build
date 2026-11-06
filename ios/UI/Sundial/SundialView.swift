import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// The 24-hour Sundial — Today's "what's happening" wheel (UX-SPEC §3.3, §4.1, §10; ARCHITECTURE §4.9; owner WP-12).
///
/// Frozen call (Today, WP-07): `SundialView(state: DialState)` (+ `scrubbing:`, round 8). Taps reach the screen through
/// `@Environment(\.mgSend)`. It draws only what the state holds (the presenter decides what each phase shows):
/// - geometry θ = (h − 12)/24 × 360°, noon at the top, 18 right, 00 bottom, 06 left (`SundialGeometry`);
/// - every layer on its own ring with its own mark and a direct label (`SundialPainter`, `SundialLabels`);
/// - the hub (kicker · big · detail) and four corner callouts by phase, from the state;
/// - until Sundown the night arc is last night; from Sundown it turns the page to tonight's plan, the smart-wake
///   window hatched (`nightArc` change → a page-turn flip, a 150 ms fade under Reduce Motion);
/// - one finger, one gesture, one state (`DialInteraction`, MGContext; round 8, T10021/T10023): touch down and slide.
///   Mostly sideways (round the dial) scrubs the clock: a label names what was there (`DialScrubIndex`) and a ghost
///   hand shows where. Starting in the hub or an inner ring and sliding mostly along the radius steps from ring to
///   ring: that ring's info shows in a card above the dial. The mode is chosen once after 8 pt and kept until the
///   finger lifts; the page does not scroll while it is on; a lift never counts as a tap; a touch that never moves is
///   a tap and opens the detail sheet. Haptics fire only when the state changes, never on lift;
/// - magnify (round 8, T10023; `DialMagnify`, MGContext): a tap on a ring or on nothing opens the dial at the full
///   screen width in a full-screen cover (so the page behind cannot scroll and the dial is always in view), the rings
///   re-spaced into a wider zone (`DialRingZone.magnified`), the hub text left out. A ring is picked by tapping it or
///   by sliding out from the centre; its card stays, and TAPPING THE CARD opens the sheet (a tap on the dial never
///   magnifies and opens a sheet at once; a drag never opens one). Tap outside, tap on nothing or the Done chip leaves.
///   A tap on a mark, arc or plan tick opens its sheet as before. VoiceOver: a "Magnify" action;
/// - rendering is split: a static layer that is redrawn only when the state changes (`SundialStaticLayer`) and a
///   small live overlay for the hand, the ring highlight and the labels (`SundialLiveOverlay`);
/// - 0.6: inner rings in a recessed well (`SundialRings`), a key under the dial (`SundialKey`), and every ring, mark
///   and arc opens its detail sheet (`DialDetailSheet`; with no sheet for it, the 0.5.3 tap);
/// - VoiceOver: one element with the state's one sentence, adjustable to step through the day (the ghost hand shows
///   where, and goes after 10 s), with one action per ring, mark kind and arc; each callout and key chip its own button.
struct SundialView: View {
    let state: DialState
    /// True while a finger is scrubbing or stepping: Today turns page scrolling off with it.
    let scrubbing: Binding<Bool>

    init(state: DialState, scrubbing: Binding<Bool> = .constant(false)) {
        self.state = state
        self.scrubbing = scrubbing
    }

    @Environment(\.mgTheme) private var theme
    @Environment(\.mgNow) private var mgNow
    @Environment(\.mgQuietHaptics) private var quietHaptics
    @Environment(\.mgSend) private var send
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The one scrub provider for this state, built once per state change off the main thread (audit #13).
    @State private var index: DialScrubIndex?
    /// The state changed while a finger was down: rebuild when it lifts, so the hour -> date map never moves under it.
    @State private var indexStale = false
    /// The target whose sheet is showing (kept until the sheet has gone, so it never blanks while sliding away).
    @State private var selected: DialTarget?
    @State private var sheetShown = false
    /// An intent sent from inside the sheet: delivered once the sheet is gone, so a screen it opens can present.
    @State private var pendingIntent: UIIntent?
    /// Magnify mode (a plain value from MGContext, so its rules are unit-tested).
    @State private var magnify = DialMagnify()

    /// At accessibility text sizes the callouts leave the corners for a grid under the dial (no overlap with the ring).
    private var calloutsBelow: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(spacing: MGSpace.m) {
            GeometryReader { geo in
                let m = SundialMetrics(width: geo.size.width)
                ZStack(alignment: .topLeading) {
                    SundialDial(state: state, metrics: m, index: index, selectedRing: selectedRing,
                                selectedMark: selectedMark, scrubbing: scrubbing, magnified: false,
                                showsCards: true, open: open, onTap: tapped, onDragEnded: { _ in },
                                onInteraction: { _ in }, onMagnify: { magnify.enter() })
                    if !calloutsBelow {
                        cornerCallouts(m)
                    }
                }
                .frame(width: m.size.width, height: m.size.height)
            }
            .aspectRatio(SundialDesign.width / SundialDesign.height, contentMode: .fit)
            .frame(maxWidth: .infinity)

            if calloutsBelow {
                calloutGrid
            }
            SundialKey(state: state, open: open)
        }
        .sheet(isPresented: sheetBinding(magnified: false), onDismiss: sheetGone) { sheet }
        .fullScreenCover(isPresented: magnifiedBinding) { magnifiedScreen }
        .task(id: state) { await rebuildIndex() }
        .onChange(of: scrubbing.wrappedValue) { _, now in
            if !now, indexStale { Task { await rebuildIndex() } }
        }
    }

    // MARK: Scrub index

    private func rebuildIndex() async {
        if scrubbing.wrappedValue {
            indexStale = true
            return
        }
        indexStale = false
        let snapshot = state, cal = calendar
        let built = await Task.detached(priority: .userInitiated) { DialScrubIndex(state: snapshot, calendar: cal) }.value
        guard !Task.isCancelled else { return }
        index = built
    }

    // MARK: Detail sheets

    /// A tap, key chip or VoiceOver action: the target's sheet, or the 0.5.3 tap when the state has no sheet for it.
    private func open(_ target: DialTarget) {
        if state.details.contains(where: { $0.id == target }) {
            selected = target
            sheetShown = true
        } else if let intent = SundialReading.legacyIntent(for: target, state: state) {
            send(intent)
        }
    }

    // MARK: Magnify

    private var magnifiedBinding: Binding<Bool> {
        Binding(get: { magnify.isOn }, set: { if !$0 { magnify.leave() } })
    }

    /// The detail sheet shows from the page, or from the magnified cover when that is up (a sheet cannot be presented
    /// from a view that is under a cover).
    private func sheetBinding(magnified: Bool) -> Binding<Bool> {
        Binding(get: { sheetShown && magnify.isOn == magnified }, set: { sheetShown = $0 })
    }

    /// A tap on the dial, after the dial decided what it landed on.
    private func tapped(_ spot: DialMagnify.Spot) {
        if case .open(let target) = magnify.tap(spot) { open(target) }
    }

    /// A tap on the info card (magnify only): the selected ring's sheet.
    private func cardTapped() {
        if case .open(let target) = magnify.tapCard() { open(target) }
    }

    /// The full-screen cover: the same screen environment as a sheet gets.
    private var magnifiedScreen: some View {
        SundialMagnifiedScreen(state: state, index: index, scrubbing: scrubbing, selectedRing: magnify.selected,
                               selectedMark: selectedMark, open: open, onTap: tapped, onCardTap: cardTapped,
                               onDragEnded: { magnify.dragEnded(ring: $0) }, onDone: { magnify.leave() })
            .sheet(isPresented: sheetBinding(magnified: true), onDismiss: sheetGone) { sheet }
            .mgTheme(theme)
            .environment(\.mgNow, mgNow)
            .environment(\.mgQuietHaptics, quietHaptics)
    }

    /// Looked up live, so an open sheet refreshes with the state every minute. Re-applies the screen environment
    /// the way RootView.themed(_:) does (a sheet is its own presentation).
    @ViewBuilder
    private var sheet: some View {
        if let target = selected, let detail = state.details.first(where: { $0.id == target }) {
            DialDetailSheet(detail: detail, siblings: siblings(of: target), select: { selected = $0 })
                .mgTheme(theme)
                .environment(\.mgNow, mgNow)
                .environment(\.mgQuietHaptics, quietHaptics)
                .environment(\.mgSend, { intent in
                    pendingIntent = intent
                    sheetShown = false
                })
        } else {
            // The thing went away (the minute refresh dropped it): close.
            Color.clear.onAppear { sheetShown = false }
        }
    }

    /// The ring sheets switch between each other; any other sheet stands alone.
    private func siblings(of target: DialTarget) -> [DialDetail] {
        guard case .ring = target else { return [] }
        return state.rings.compactMap { r in state.details.first { $0.id == .ring(r.kind) } }
    }

    private func sheetGone() {
        selected = nil
        if let intent = pendingIntent {
            pendingIntent = nil
            magnify.leave()          // the screen the intent opens must not open under the cover
            send(intent)
        }
    }

    private var selectedRing: DialRing.Kind? {
        if case .ring(let kind)? = selected { return kind }
        return nil
    }

    private var selectedMark: SundialMarkSelection? {
        if case let .mark(kind, at)? = selected { return SundialMarkSelection(kind: kind, at: at) }
        return nil
    }

    // MARK: Corner callouts (UX §3.3, §4.1)

    private func cornerCallouts(_ m: SundialMetrics) -> some View {
        ZStack {
            ForEach(DialCallout.Corner.allCases, id: \.self) { corner in
                if let c = callout(corner) {
                    // Value line ≤ 100 units, caption ≤ 84: both clear the hour ticks at width 353.
                    SundialCalloutButton(callout: c, maxWidth: m.units(100), captionWidth: m.units(84),
                                         compact: true, keepOut: keepOut(corner, m))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(corner))
                        .padding(.horizontal, m.units(4))
                }
            }
        }
        .frame(width: m.size.width, height: m.size.height)
    }

    /// Audit UI-SCRUB-A §1 #9: a corner callout's tap area stops short of the dial disc (radius 150 units), so a finger
    /// on a rim mark near 10:30, 1:30, 4:30 or 7:30 reaches the dial, not a callout. `toCenter` runs from the
    /// callout's flush corner (4 units in from the side, flush with the top or bottom) to the dial centre.
    private func keepOut(_ corner: DialCallout.Corner, _ m: SundialMetrics) -> CalloutKeepOut {
        let side = m.units(4)
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        return CalloutKeepOut(corner: corner,
                              toCenter: CGSize(width: left ? m.size.width / 2 - side : -(m.size.width / 2 - side),
                                               height: top ? m.size.height / 2 : -(m.size.height / 2)),
                              radius: m.units(SundialDesign.calloutKeepOutRadius))
    }

    private var calloutGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .trailing)],
                  spacing: 8) {
            ForEach(DialCallout.Corner.allCases, id: \.self) { corner in
                if let c = callout(corner) {
                    SundialCalloutButton(callout: c, maxWidth: .infinity, captionWidth: .infinity, compact: false)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
        }
    }

    /// The callout for a corner, or nil when that corner is empty in this phase.
    private func callout(_ corner: DialCallout.Corner) -> DialCallout? {
        state.callouts.first { $0.corner == corner && $0.value != nil }
    }

    private func alignment(_ corner: DialCallout.Corner) -> Alignment {
        switch corner {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

/// The rim mark whose sheet is open (a 2 pt ring is drawn round it).
struct SundialMarkSelection: Equatable {
    let kind: RimEvent.Kind
    let at: Date
}

// MARK: - The dial: gesture + state owner

/// Owns the finger: one `DragGesture(minimumDistance: 0)`, one `DialTouchTracker` (MGContext), one published
/// `DialInteraction`. The body is two children: the static layer (skipped while the state is unchanged) and the live
/// overlay (the only thing a finger move redraws). Used inline on the page and, `magnified`, on the full-screen cover.
struct SundialDial: View {
    let state: DialState
    let metrics: SundialMetrics
    let index: DialScrubIndex?
    let selectedRing: DialRing.Kind?
    let selectedMark: SundialMarkSelection?
    let scrubbing: Binding<Bool>
    /// Full-width mode: the rings sit in the wider zone, the hub text is left out.
    let magnified: Bool
    /// False when the owner draws the cards itself (magnify keeps its ring card on screen after the finger lifts).
    let showsCards: Bool
    /// VoiceOver actions: open this target's sheet.
    let open: (DialTarget) -> Void
    /// A tap (the finger never moved 8 pt): what it landed on. The owner decides: magnify, pick, or open a sheet.
    let onTap: (DialMagnify.Spot) -> Void
    /// A drag ended: the ring it ended on (a ring step), or nil (a time scrub). Never opens anything.
    let onDragEnded: (DialRing.Kind?) -> Void
    /// The finger's state changed (for an owner that draws the cards).
    let onInteraction: (DialInteraction) -> Void
    /// The VoiceOver "Magnify" action.
    let onMagnify: () -> Void

    init(state: DialState, metrics: SundialMetrics, index: DialScrubIndex?, selectedRing: DialRing.Kind?,
         selectedMark: SundialMarkSelection?, scrubbing: Binding<Bool>, magnified: Bool, showsCards: Bool,
         open: @escaping (DialTarget) -> Void, onTap: @escaping (DialMagnify.Spot) -> Void,
         onDragEnded: @escaping (DialRing.Kind?) -> Void, onInteraction: @escaping (DialInteraction) -> Void,
         onMagnify: @escaping () -> Void) {
        self.state = state
        self.metrics = metrics
        self.index = index
        self.selectedRing = selectedRing
        self.selectedMark = selectedMark
        self.scrubbing = scrubbing
        self.magnified = magnified
        self.showsCards = showsCards
        self.open = open
        self.onTap = onTap
        self.onDragEnded = onDragEnded
        self.onInteraction = onInteraction
        self.onMagnify = onMagnify
    }

    @Environment(\.calendar) private var calendar

    @State private var tracker = DialTouchTracker()
    @State private var interaction: DialInteraction = .idle
    /// True while the system still holds the touch; a drop to false with the tracker still running = cancelled.
    @GestureState private var touching = false
    /// VoiceOver's adjustable position (hour of day); nil until the user swipes, and again after 10 s.
    @State private var voiceOverHour: Double?

    var body: some View {
        let m = metrics
        ZStack(alignment: .topLeading) {
            SundialStaticLayer(state: state, metrics: m, selectedRing: selectedRing, selectedMark: selectedMark)
                .equatable()
            SundialLiveOverlay(state: state, metrics: m, index: index, interaction: interaction,
                               voiceOverHour: voiceOverHour, showsCards: showsCards)
        }
        .frame(width: m.size.width, height: m.size.height)
        .contentShape(Rectangle())
        // Simultaneous, so the page can still start scrolling in the first few points; once the touch has chosen,
        // `scrubbing` turns the page's scrolling off.
        .simultaneousGesture(touchGesture(m))
        .task(id: touching) {
            // A touch the system took away (no `onEnded`): give it a moment, then clear it so the page scrolls again.
            guard !touching else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !touching, tracker.interaction != .idle {
                tracker.cancel()
                publish()
            }
        }
        .task(id: voiceOverHour) {
            guard voiceOverHour != nil else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { voiceOverHour = nil }
        }
        .onChange(of: state.now) { _, _ in voiceOverHour = nil }
        .onDisappear {
            tracker.cancel()
            publish()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel)
        .accessibilityValue(voiceOverHour.flatMap { index?.reading(hour: $0).text } ?? "")
        .accessibilityHint("Swipe up or down to step through the day, half an hour at a time.")
        .accessibilityAdjustableAction { direction in
            let base = voiceOverHour ?? SundialGeometry.hourOfDay(state.now, calendar: calendar)
            switch direction {
            case .increment: voiceOverHour = SundialGeometry.positiveMod(base + 0.5, 24)
            case .decrement: voiceOverHour = SundialGeometry.positiveMod(base - 0.5, 24)
            @unknown default: break
            }
        }
        .accessibilityActions {
            if !magnified {
                Button("Magnify") { onMagnify() }
            }
            ForEach(Array(SundialReading.accessibilityActions(state).enumerated()), id: \.offset) { _, action in
                Button(action.title) { open(action.target) }
            }
        }
        .accessibilitySortPriority(1)
    }

    // MARK: The gesture

    private func touchGesture(_ m: SundialMetrics) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touching) { _, held, _ in held = true }
            .onChanged { value in
                if tracker.interaction == .idle {
                    tracker.begin(x: Double(value.startLocation.x - m.center.x),
                                  y: Double(value.startLocation.y - m.center.y),
                                  scale: Double(m.scale), ringCount: state.rings.count,
                                  nowHour: SundialGeometry.hourOfDay(state.now, calendar: calendar), zone: m.zone)
                }
                tracker.move(x: Double(value.location.x - m.center.x), y: Double(value.location.y - m.center.y))
                publish()
            }
            .onEnded { _ in
                // The ring a ring step ended on, read before `end()` resets the tracker.
                var ended: DialRing.Kind?
                if case .ringStep(let i) = tracker.interaction, state.rings.indices.contains(i) { ended = state.rings[i].kind }
                let outcome = tracker.end()
                publish()
                switch outcome {
                case .tap(let x, let y):
                    // Only a touch that never moved 8 pt is a tap; the lift after a scrub or ring step never is.
                    let point = CGPoint(x: m.center.x + CGFloat(x), y: m.center.y + CGFloat(y))
                    let idx = index ?? DialScrubIndex(state: state, calendar: calendar)
                    onTap(SundialReading.tapSpot(at: point, metrics: m, state: state, index: idx))
                case .finished:
                    onDragEnded(ended)
                case .none:
                    break
                }
            }
    }

    /// Copies the tracker's state out only when it changed, so a finger move that changes nothing redraws nothing.
    private func publish() {
        let next = tracker.interaction
        if interaction != next {
            interaction = next
            onInteraction(next)
        }
        let locked = next.isLocked
        if scrubbing.wrappedValue != locked { scrubbing.wrappedValue = locked }
    }
}

// MARK: - Static layer

/// Everything that depends only on the state: the well, rings, night arc, other arcs, ticks, marks, hub. `Equatable`,
/// used through `.equatable()`, so SwiftUI skips it while the state is unchanged. The under+rings and over passes are
/// each flattened with `drawingGroup()`; the night arc stays out of the groups so its page turn keeps its 3-D flip.
private struct SundialStaticLayer: View, Equatable {
    let state: DialState
    let metrics: SundialMetrics
    let selectedRing: DialRing.Kind?
    let selectedMark: SundialMarkSelection?

    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (l: SundialStaticLayer, r: SundialStaticLayer) -> Bool {
        l.state == r.state && l.metrics == r.metrics && l.selectedRing == r.selectedRing
            && l.selectedMark == r.selectedMark
    }

    var body: some View {
        let m = metrics
        let labels = SundialLabels.place(state: state, metrics: m, calendar: calendar)
        let painter = SundialPainter(state: state, metrics: m, colors: colors, calendar: calendar, labels: labels)
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in painter.drawUnder(&ctx) }
                SundialRings(rings: state.rings, metrics: m, selected: selectedRing)
            }
            .frame(width: m.size.width, height: m.size.height)
            .drawingGroup()
            // The night arc turns the page when `nightArc` flips (lastNight → tonight at Sundown, back after waking).
            Canvas { ctx, _ in painter.drawNight(&ctx) }
                .id(state.nightArc)
                .transition(reduceMotion ? .opacity : .sundialPageTurn)
            Canvas { ctx, _ in painter.drawOver(&ctx) }
                .drawingGroup()
            markHalo(m)
            // Magnified, the rings run in to where the hub text would sit, so the hub is left out (the card says it).
            if !m.magnified { hub(m) }
        }
        .frame(width: m.size.width, height: m.size.height)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.9), value: state.nightArc)
    }

    /// selectHalo: a 2 pt ink ring (mark radius + 4 units) around the tapped rim mark while its sheet is open.
    @ViewBuilder
    private func markHalo(_ m: SundialMetrics) -> some View {
        ZStack {
            if let mark = selectedMark {
                let d = m.units(2 * (Self.markRadius(mark.kind) + 4))
                Circle()
                    .stroke(colors.ink.color, lineWidth: 2)
                    .frame(width: d, height: d)
                    .position(m.point(hour: SundialGeometry.hourOfDay(mark.at, calendar: calendar),
                                      offset: SundialDesign.rimOffset))
                    .transition(.opacity)
            }
        }
        .frame(width: m.size.width, height: m.size.height)
        .animation(.easeOut(duration: 0.15), value: selectedMark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Half-size of each rim mark in design units (SundialPainter.drawRim).
    private static func markRadius(_ kind: RimEvent.Kind) -> CGFloat {
        switch kind {
        case .vape: return 2.7
        case .medication: return 4.7
        case .caffeine: return 3.3
        case .food: return 3.6
        case .supplement: return 3.5
        }
    }

    // MARK: Hub (UX §3.3: kicker + bigNumber + one detail line, by phase)

    /// With rings on, the text fits a 92-unit box inside the innermost ring (hubRadius 50); the kicker and detail
    /// lines are narrower (72) so their corners stay inside that circle. With no ring on, the 0.5.3 width.
    private func hub(_ m: SundialMetrics) -> some View {
        let ringsOn = !state.rings.isEmpty
        let box = m.units(ringsOn ? 2 * (SundialDesign.hubRadius - 4) : 2 * (SundialDesign.hubHalfWidth + 8))
        let line = ringsOn ? m.units(72) : box
        return VStack(spacing: 2) {
            Text(state.hub.kicker)
                .mgFont(.hubKicker)
                .foregroundStyle(colors.mute.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: line)
            Text(state.hub.big)
                .mgFont(.hubBig)
                .foregroundStyle(colors.ink.color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if let detail = state.hub.detail {
                Text(detail)
                    .mgFont(.hubDetail)
                    .foregroundStyle(colors.ink2.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: line)
            }
        }
        .frame(width: box)
        .position(m.center)
    }
}

// MARK: - Live overlay

/// What changes with the finger: the ghost hand, the selected-ring highlight, the time label and the ring card.
/// Hit-testing is off, so the gesture sees every touch. The haptic token lives here: it changes only when a ring is
/// entered or a time reading crosses into a different thing, and is nil (no haptic) when the finger is up.
private struct SundialLiveOverlay: View {
    let state: DialState
    let metrics: SundialMetrics
    let index: DialScrubIndex?
    let interaction: DialInteraction
    let voiceOverHour: Double?
    /// False when the owner draws the ring / time cards itself (the magnified screen).
    let showsCards: Bool

    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.mgQuietHaptics) private var quietHaptics

    var body: some View {
        let m = metrics
        let reading = timeReading
        let hand = scrubHour ?? voiceOverHour
        ZStack(alignment: .topLeading) {
            if let hand {
                let painter = SundialPainter(state: state, metrics: m, colors: colors, calendar: calendar, labels: [])
                Canvas { ctx, _ in painter.drawGhost(&ctx, hour: hand) }
            }
            if case .ringStep(let i) = interaction, state.rings.indices.contains(i) {
                ringHighlight(m, index: i)
            }
            if let reading, let hour = scrubHour {
                timeLabel(m, hour: hour, reading: reading)
            }
        }
        .frame(width: m.size.width, height: m.size.height)
        .overlay(alignment: .top) {
            if showsCards {
                if case .ringStep(let i) = interaction, state.rings.indices.contains(i) {
                    SundialRingCard(state: state, kind: state.rings[i].kind)
                        .padding(.bottom, 6)
                        .frame(width: m.size.width)
                        // Bottom edge on the dial's top edge: above the dial, never under the finger.
                        .alignmentGuide(.top) { d in d[.bottom] }
                } else if let reading, !reading.series.isEmpty {
                    SundialTimeCard(reading: reading)
                        .padding(.bottom, 6)
                        .frame(width: m.size.width)
                        .alignmentGuide(.top) { d in d[.bottom] }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .sensoryFeedback(.selection, trigger: hapticToken(reading)) { _, new in new != nil && !quietHaptics }
    }

    // MARK: State

    private var scrubHour: Double? {
        if case .timeScrub(let h) = interaction { return h }
        return nil
    }

    private var timeReading: DialScrubIndex.Reading? {
        guard let h = scrubHour else { return nil }
        return index?.reading(hour: h)
    }

    private func hapticToken(_ reading: DialScrubIndex.Reading?) -> String? {
        switch interaction {
        case .idle, .undecided:
            return nil
        case .ringStep(let i):
            return state.rings.indices.contains(i) ? "ring:" + state.rings[i].kind.rawValue : nil
        case .timeScrub:
            return reading.map { "t:" + $0.id }
        }
    }

    // MARK: Parts

    /// The selected ring: its track brightens and an ink outline marks it.
    private func ringHighlight(_ m: SundialMetrics, index i: Int) -> some View {
        let count = state.rings.count
        let r = m.units(SundialDesign.ringRadius(index: i, count: count, zone: m.zone))
        let width = m.units(SundialDesign.ringStep(count: count, zone: m.zone) * SundialDesign.ringWidthRatio)
        return ZStack {
            Circle()
                .stroke(colors.ring(state.rings[i].kind).opacity(0.35).color, lineWidth: width)
                .frame(width: 2 * r, height: 2 * r)
            Circle()
                .stroke(colors.ink.color, lineWidth: 1.5)
                .frame(width: 2 * (r + width / 2), height: 2 * (r + width / 2))
        }
        .position(m.center)
    }

    /// The time label rides above the hand's point on the rim, so the finger never covers it.
    private func timeLabel(_ m: SundialMetrics, hour: Double, reading: DialScrubIndex.Reading) -> some View {
        let anchor = m.point(hour: hour, offset: SundialDesign.handOuter)
        return Text(reading.text)
            .mgFont(.receipt)
            .foregroundStyle(colors.ink.color)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: m.size.width * 0.8)
            .fixedSize(horizontal: false, vertical: true)
            .mgSurface(.card, radius: MGRadius.chip, shadow: true)
            .position(x: min(max(anchor.x, m.size.width * 0.4), m.size.width * 0.6),
                      y: max(m.units(16), anchor.y - m.units(52)))
    }
}

// MARK: - Page turn (UX §3.3 "the night arc turns the page")

/// The night layer flips over its horizontal diameter like a page: the old one turns away, the new one turns in.
private struct SundialPageTurn: ViewModifier {
    let degrees: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(degrees), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.45)
            .opacity(degrees == 0 ? 1 : 0)
    }
}

extension AnyTransition {
    fileprivate static var sundialPageTurn: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SundialPageTurn(degrees: -90), identity: SundialPageTurn(degrees: 0)),
            removal: .modifier(active: SundialPageTurn(degrees: 90), identity: SundialPageTurn(degrees: 0)))
    }
}

// MARK: - Callout

/// A corner callout: the value in its accent's TEXT colour (`colors.text(tone)`, BRIEF WP-07 rule) with its meaning
/// tag, and a sans caption of up to two lines (0.6; was one mono line). Tappable when the state gives an intent
/// (UX §10); long-press shows the receipt (UX §10 "any number").
struct SundialCalloutButton: View {
    let callout: DialCallout
    let maxWidth: CGFloat
    /// The caption's own width cap (narrower than the value in the corners, to clear the hour ticks).
    let captionWidth: CGFloat
    /// Corner placement: capped text growth so it stays clear of the ring.
    let compact: Bool
    /// The dial disc the tap area must not cover (corner placement only); nil = the whole label is tappable.
    var keepOut: CalloutKeepOut?

    @Environment(\.mgColors) private var colors
    @Environment(\.mgSend) private var send
    @Environment(\.mgNow) private var now
    @Environment(\.calendar) private var calendar

    private var horizontal: HorizontalAlignment {
        callout.corner == .topRight || callout.corner == .bottomRight ? .trailing : .leading
    }

    private var valueStyle: MGTextStyle { MGTextStyle.calloutValue.capped(compact ? 1.3 : 2.0) }

    private var captionStyle: MGTextStyle { MGTextStyle.calloutCaption.capped(compact ? 1.3 : 2.0) }

    var body: some View {
        Button {
            if let intent = callout.intent { send(intent) }
        } label: {
            VStack(alignment: horizontal, spacing: 1) {
                valueLine
                Text(callout.caption)
                    .mgFont(captionStyle)
                    .foregroundStyle(colors.ink2.color)
                    .multilineTextAlignment(horizontal == .trailing ? .trailing : .leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: captionWidth, alignment: Alignment(horizontal: horizontal, vertical: .center))
            }
            .frame(minWidth: 88, maxWidth: maxWidth, minHeight: MGSpace.tapTarget,
                   alignment: Alignment(horizontal: horizontal, vertical: .center))
            .contentShape(CalloutHitShape(keepOut: keepOut))
        }
        .buttonStyle(.plain)
        .disabled(callout.intent == nil)
        .accessibilityLabel(spoken)
        .contextMenu {
            if let r = callout.value?.receipt {
                Text("\(r.originText) · tier \(r.tier.rawValue)")
                Text(r.text(calendar: calendar, now: now))
                if let method = r.method { Text("Method: \(method)") }
                if let citation = r.citation { Text("Source: \(citation)") }
            }
        }
    }

    @ViewBuilder
    private var valueLine: some View {
        switch callout.value {
        case let .blank(reason, _)?:
            VStack(alignment: horizontal, spacing: 0) {
                Text("—").mgFont(valueStyle).foregroundStyle(colors.mute.color)
                Text(reason)
                    .mgFont(captionStyle)
                    .foregroundStyle(colors.mute.color)
                    .multilineTextAlignment(horizontal == .trailing ? .trailing : .leading)
                    .lineLimit(2)
                    .frame(maxWidth: captionWidth, alignment: Alignment(horizontal: horizontal, vertical: .center))
            }
        case let v?:
            SundialValueLine(value: v, style: valueStyle, color: colors.text(callout.tone))
                .frame(maxWidth: maxWidth, alignment: Alignment(horizontal: horizontal, vertical: .center))
        case nil:
            EmptyView()
        }
    }

    private var spoken: String {
        switch callout.value {
        case let .blank(reason, _)?:
            return "\(callout.caption): no value. \(reason)"
        case let v?:
            return "\(callout.caption): \(SundialValueLine.spoken(v))"
        case nil:
            return callout.caption
        }
    }
}

/// Where the dial disc is, seen from a corner callout (audit UI-SCRUB-A §1 #9).
struct CalloutKeepOut: Equatable {
    let corner: DialCallout.Corner
    /// From the callout's flush corner to the dial centre, points (x right, y down).
    let toCenter: CGSize
    /// Points.
    let radius: CGFloat
}

/// A callout's tap area: its rectangle minus the dial disc.
struct CalloutHitShape: Shape {
    let keepOut: CalloutKeepOut?

    func path(in rect: CGRect) -> Path {
        let full = Path(rect)
        guard let k = keepOut else { return full }
        let right = k.corner == .topRight || k.corner == .bottomRight
        let bottom = k.corner == .bottomLeft || k.corner == .bottomRight
        let c = CGPoint(x: (right ? rect.maxX : rect.minX) + k.toCenter.width,
                        y: (bottom ? rect.maxY : rect.minY) + k.toCenter.height)
        let disc = Path(ellipseIn: CGRect(x: c.x - k.radius, y: c.y - k.radius, width: 2 * k.radius, height: 2 * k.radius))
        return full.subtracting(disc)
    }
}

// MARK: - Legend (UX §3.3: one line naming only the marks present today)

/// The state's legend line, its mark glyphs tinted like the marks on the rim (the glyph's SHAPE is the key; the tint
/// only repeats it). VoiceOver hears the glyphs as words.
struct SundialLegend: View {
    let text: String

    init(text: String) {
        self.text = text
    }

    @Environment(\.mgColors) private var colors

    /// UX §3.3 rim marks: ● vape (body) · ◆ medication (ink) · ▲ food (ink2) · ■ supplement (focus) · ◉ caffeine.
    static func glyphColor(_ ch: Character, _ colors: ThemeColors) -> MGRGBA? {
        switch ch {
        case "●", "○": return colors.body
        case "◆": return colors.ink
        case "▲": return colors.ink2
        case "■": return colors.focus
        case "◉": return colors.caffeine
        default: return nil
        }
    }

    var body: some View {
        if !text.isEmpty {
            Text(attributed)
                .mgFont(.unit)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Self.spoken(text))
        }
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for ch in text {
            var piece = AttributedString(String(ch))
            piece.foregroundColor = (Self.glyphColor(ch, colors) ?? colors.ink2).color
            out += piece
        }
        return out
    }

    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: "●", with: "dot,")
            .replacingOccurrences(of: "○", with: "hollow dot,")
            .replacingOccurrences(of: "◆", with: "diamond,")
            .replacingOccurrences(of: "▲", with: "triangle,")
            .replacingOccurrences(of: "■", with: "square,")
            .replacingOccurrences(of: "◉", with: "ringed dot,")
            .replacingOccurrences(of: " · ", with: ", ")
    }
}
