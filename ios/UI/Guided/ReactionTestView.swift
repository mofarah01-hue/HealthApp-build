import Combine
import SwiftUI
import QuartzCore
import MGContext
import MGDesign
import MGDomain
import MGSignal

/// The 3-minute reaction test (PVT-B, ALG-050; Basner, Mollicone & Dinges 2011). Log › Sleepy & check-in › Reaction
/// test, 3 min, and the focus window's row. Full-screen cover.
///
/// Timing lives HERE, not in AppModel (an exception to the "no local view state" rule, on purpose): a response time is
/// "touch-down time − the moment the counter appeared", both read from CACurrentMediaTime in this view; a round trip
/// through the intent queue would add tens of ms of noise. The run itself (intervals, lapses, false starts, the 30-s
/// timeout) is `ALG050.Run`, pure and tested in MGSignal. At 3:00 the result is scored with `ALG050.score` and sent
/// once as `.saveEvent(reactionTest)` (contract reactionTestEvent) — ALG-051 can personalise from these later.
/// Known offset: the counter appears on the frame after `advance` sees it is due (≤ 1 frame, the same for every trial).
struct ReactionTestView: View {
    let send: (UIIntent) -> Void
    let close: () -> Void

    init(send: @escaping (UIIntent) -> Void, close: @escaping () -> Void) {
        self.send = send
        self.close = close
    }

    @Environment(\.mgColors) private var colors
    @State private var run: ALG050.Run?
    @State private var startedAt: Date?
    @State private var clock: Double = CACurrentMediaTime()
    @State private var touching = false
    @State private var result: Computed<ALG050.Score>?
    private let tick = Timer.publish(every: 1.0 / 120, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let run, result == nil {
                // Not inside MGScreen's ScrollView: a scroll view holds touch-down back while it decides whether a
                // drag is a scroll, which would add to every response time.
                GeometryReader { geo in
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                        runningView(run)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, MGSpace.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background {
                        MGBackgroundLayer(colors.background, size: CGSize(
                            width: geo.size.width, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom))
                            .ignoresSafeArea()
                    }
                }
            } else {
                MGScreen {
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                        if let result { resultView(result) } else { intro }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .onReceive(tick) { _ in step() }
        .onDisappear { GuidedIdleTimer.keepAwake(false) }
    }

    private var topBar: some View {
        GuidedTopBar(kicker: "Reaction test · 3 min · PVT-B", title: "Reaction test",
                     closeLabel: run != nil && result == nil ? "Stop and close — nothing is saved" : "Close") {
            GuidedIdleTimer.keepAwake(false)
            close()
        }
        .padding(.top, 12)
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tap anywhere on the box the moment the counter starts. Don't tap before it starts. It runs 3 minutes; "
                 + "keep the phone still and your thumb ready.")
                .mgFont(.body)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            GuidedNote("Scored as Basner 2011's PVT-B: a lapse is 355 ms or slower (or no tap within 30 s), a "
                       + "false start is a tap before the counter or under 100 ms. The result goes to your log; the "
                       + "alertness model uses population numbers until it is fitted to your tests.")
            MGButton("Start", style: .filled) { start() }
        }
        .padding(.top, 18)
    }

    // MARK: Running

    private func runningView(_ run: ALG050.Run) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(remaining(run))
                .mgFont(.kicker)
                .foregroundStyle(colors.ink2.color)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colors.chip.color)
                switch run.phase {
                case .stimulus(let since):
                    Text("\(Int(max(0, clock - since) * 1000))")
                        .mgFont(.heroNumber)
                        .foregroundStyle(colors.ink.color)
                        .monospacedDigit()
                default:
                    Text(feedback(run))
                        .mgFont(.bigNumber)
                        .foregroundStyle(colors.ink2.color)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 420)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !touching else { return }
                    touching = true
                    press()
                }
                .onEnded { _ in touching = false })
            .accessibilityElement()
            .accessibilityLabel("Reaction test box: tap when the counter starts")
            .accessibilityAddTraits(.allowsDirectInteraction)
        }
        .padding(.top, 18)
    }

    private func remaining(_ run: ALG050.Run) -> String {
        let left = max(0, run.endsAt - clock)
        return String(format: "%d:%02d left · %d stimuli", Int(left) / 60, Int(left) % 60, run.rtMs.count)
    }

    /// The last response, shown for the 1-s feedback part of the interval (Basner 2011 §2.2).
    private func feedback(_ run: ALG050.Run) -> String {
        guard let f = run.lastFeedback, let at = run.lastFeedbackAt, clock - at < ALG050.feedbackSeconds else { return "" }
        switch f {
        case .rt(let ms): return "\(Int(ms.rounded())) ms"
        case .falseStart: return "Too soon"
        case .noResponse: return "No tap"
        }
    }

    // MARK: Result

    private func resultView(_ r: Computed<ALG050.Score>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch r {
            case .success(let s):
                Text("\(Int(s.meanRtMs.rounded())) ms")
                    .mgFont(.heroNumber)
                    .foregroundStyle(colors.ink.color)
                Text("mean response time · \(s.lapses) lapse\(s.lapses == 1 ? "" : "s") (≥ 355 ms or no tap) · "
                     + "\(s.falseStarts) false start\(s.falseStarts == 1 ? "" : "s") · \(s.trials) stimuli")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                GuidedNote("Saved to your log (Sleepy & check-in). Kept for fitting the alertness model to you.")
            case .failure(let m):
                Text("Not saved")
                    .mgFont(.headline)
                    .foregroundStyle(colors.ink.color)
                GuidedNote("The test " + m.reason + ".")
            }
            HStack(spacing: 8) {
                MGButton("Again", style: .ghost) { start() }
                MGButton("Done", style: .filled) { close() }
            }
        }
        .padding(.top, 18)
    }

    // MARK: Clock

    private func start() {
        let now = CACurrentMediaTime()
        clock = now
        result = nil
        startedAt = Date()
        run = ALG050.Run(startedAt: now, seed: UInt64.random(in: 1...UInt64.max))
        GuidedIdleTimer.keepAwake(true)
    }

    private func press() {
        guard result == nil, run != nil else { return }
        run!.press(at: CACurrentMediaTime())
    }

    private func step() {
        guard result == nil, run != nil else { return }
        clock = CACurrentMediaTime()
        run!.advance(to: clock)
        guard run!.finished, let started = startedAt else { return }
        let score = run!.score()
        result = score
        GuidedIdleTimer.keepAwake(false)
        if case .success(let s) = score {
            send(.saveEvent(EventFactory.reactionTest(s, startedAt: started, endedAt: Date())))
        }
    }
}
