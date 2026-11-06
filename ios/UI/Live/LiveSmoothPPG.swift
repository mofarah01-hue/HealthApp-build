import SwiftUI
import MGContext
import MGDesign
import MGSignal

// T10005 (Mo, Oct 17 2026) + round 8 (audit 7.1): the Live raw-PPG graph drawn smoothly and cheaply. The samples come from
// `LivePPGFeed.shared` (a fixed ring buffer the app feeds as each one-second record arrives); each plot asks it, at a steady
// capped rate, for the last 5 seconds as they look right now, so the trace slides left a few pixels per frame.
// Drawing: one `Canvas` per plot with ONE `Path` (not a Swift Charts mark per point); at most two points per pixel column
// (lowest + highest) so peaks survive; the y range is peak-held with a slow fall (`PeakHoldRange`) so the trace does not
// "breathe". The label chips are static views OUTSIDE the `TimelineView`; only the Canvas is inside it, wrapped in
// `.drawingGroup()`. The timelines pause while the plot is off screen. The row's own waves (from the presenter) supply the ids
// and labels, and their samples are drawn only until the feed has that wave. NOT COMPILED here (no Xcode on this PC).

/// Keeps `LiveFeedProbe` (MGContext cannot see MGSignal) pointed at the live feed, so the presenter leaves samples out of
/// `LiveState` for every wave the feed already holds. Idempotent; called when the Live tab appears.
enum LiveFeedBridge {
    static func install() {
        // R9f (T146): the motion feed's channels are reported as `motionIDBase + n`, so the presenter leaves motion samples out
        // of `LiveState` once the feed holds them (the same rule as the PPG blocks).
        LiveFeedProbe.shared.install {
            Set(LivePPGFeed.shared.ids()).union(LiveWaveFeeds.motion.ids().map { LiveWaves.motionIDBase + $0 })
        }
    }
}

/// R9f (T146): the other live waves, in feeds of the same type as the raw PPG one (a ring buffer per channel, sliding window
/// 1.5 s behind real time). Fed by the app while the Live tab is on screen (`AppModel.feedLiveMotion`); read only by the Waves
/// section's rows, which exist only while the section is open.
enum LiveWaveFeeds {
    /// 100 Hz accelerometer size (raw counts), channel 0.
    static let motion = LivePPGFeed()

    /// The feed behind a wave row, or nil for a row that does not draw from one (raw PPG has its own card; ECG is a finished
    /// reading drawn from the state).
    static func feed(forRow id: String) -> LivePPGFeed? {
        id == "motion" ? motion : nil
    }
}

/// The time axis the live plots share (T145): the same 5 s window ending 1.5 s behind the newest data, the same fixed label
/// column on the right as the heart-rate graph, and a gridline at every whole second drawn by every plot at the same instants,
/// so a beat lines up from one plot to the next.
struct LiveWaveAxis: View {
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("−\(Int(LiveSmoothPPGPlots.windowSeconds)) s")
                Spacer(minLength: 0)
                Text("now −\(String(format: "%.1f", LivePPGFeed.delay)) s")
            }
            .padding(.trailing, LiveHRTrace.axisLabelWidth)
            Text("One gridline a second, the same on every wave here. The heart-rate graph above covers 5 minutes; its right edge is the same moment.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .mgFont(.receipt)
        .foregroundStyle(colors.mute.color)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

struct LiveSmoothPPGPlots: View {
    /// The graphs the picker chose (ids = block x 2 + slot; labels carry the block map's colour name, unconfirmed).
    let graphs: [LivePPGGraph]
    var height: Double = 160

    static let windowSeconds = 5.0

    /// Redraws a second: 15 for one or two plots, 10 up to four, 6 above that (the heat budget is plots x frames); never
    /// above 30.
    static func framesPerSecond(plots: Int) -> Double { min(30, plots <= 2 ? 15 : plots <= 4 ? 10 : 6) }

    var body: some View {
        let plots = graphs.count + 1
        let fps = Self.framesPerSecond(plots: plots)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(graphs) { graph in
                SmoothWaveLine(
                    labels: graph.series.map(\.label), height: height, fps: fps,
                    source: .feed(ids: graph.series.map(\.id), fallback: graph.series, normalise: graph.series.count > 1))
            }
            CleanedPPGLine(height: height * 0.75, fps: fps)
            LiveWaveAxis()
        }
    }
}

/// Where a plot gets its points each frame.
enum SmoothSource: Sendable {
    /// The feed's channels `ids` (one trace each); a channel the feed does not hold yet is drawn from `fallback`'s samples.
    /// R9f: `feed` defaults to the raw PPG feed; the motion row passes its own.
    case feed(ids: [Int], fallback: [OpticalWave], normalise: Bool, feed: LivePPGFeed = .shared)
    /// The feed's cleaned trace.
    case cleaned

    /// One frame's traces (oldest first), `t` seconds from the left edge.
    nonisolated func traces(now: Double) -> [[LivePPGFeed.Point]] {
        let window = LiveSmoothPPGPlots.windowSeconds
        switch self {
        case .cleaned:
            return [LivePPGFeed.shared.cleanWindow(now: now, seconds: window)]
        case let .feed(ids, fallback, normalise, feed):
            return ids.map { id in
                var pts = feed.window(id: id, now: now, seconds: window)
                if pts.isEmpty, let wave = fallback.first(where: { $0.id == id }), wave.samples.count > 1 {
                    let n = Double(wave.samples.count - 1)
                    pts = wave.samples.enumerated().map { LivePPGFeed.Point(t: Double($0.offset) / n * window, v: $0.element) }
                }
                guard normalise else { return pts }
                let peak = pts.map { abs($0.v) }.max() ?? 0
                return peak > 0 ? pts.map { LivePPGFeed.Point(t: $0.t, v: $0.v / peak) } : pts
            }
        }
    }
}

/// Reference box for a plot's smoothed y range: changing it never invalidates the view.
final class PPGRangeBox: @unchecked Sendable {
    var range = PeakHoldRange()
}

/// "Cleaned (ours)": one plot of the feed's cleaned trace, drawn only while the feed has one.
struct CleanedPPGLine: View {
    let height: Double
    let fps: Double

    var body: some View {
        // `cleanSourceID` is read when the row is (re)built, which the record flow does about once a second.
        if let src = LivePPGFeed.shared.cleanSourceID() {
            SmoothWaveLine(
                labels: ["Cleaned (ours) · block \(src / 2) slot A · band-pass 0.5-4 Hz "
                         + "(zero-phase) · raw counts, decoded, untested"],
                height: height, fps: fps, source: .cleaned)
                .padding(.top, MGSpace.s)
        }
    }
}

/// One plot: label chips above (static), the Canvas below (the only thing a frame redraws). Same look as the old Swift Charts line
/// (fixed label column on the right so the plots line up with the heart-rate graph), x axis = time in seconds.
struct SmoothWaveLine: View {
    let labels: [String]
    var height: Double = 160
    var fps: Double = 15
    let source: SmoothSource
    /// What the plot is, for VoiceOver ("Raw PPG", "100 Hz motion").
    var kind: String = "Raw PPG"
    @Environment(\.mgColors) private var colors
    @State private var visible = false
    @State private var box = PPGRangeBox()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            FlowLayout(spacing: MGSpace.s, lineSpacing: MGSpace.xs) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Text(label)
                        .mgFont(.label)
                        .foregroundStyle(Self.channelColor(label, fallback: colors.live.color))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .frame(height: 32)                       // L10: no extra 44 pt frame, the chip is not tappable
                        .background(Capsule().fill(colors.chip.color))
                }
            }
            TimelineView(.animation(minimumInterval: 1.0 / max(1, min(30, fps)), paused: !visible)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                let source = source, labels = labels, box = box, fallback = colors.live.color, grid = colors.rule.color
                // The renderer captures only plain values, so it does not depend on this view's actor isolation.
                Canvas { gc, size in
                    Self.render(gc, size: size, now: now, source: source, labels: labels, box: box, fallback: fallback,
                                grid: grid)
                }
                .drawingGroup()
            }
            .padding(.trailing, LiveHRTrace.axisLabelWidth)
            .frame(height: height)
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind) waveform, \(labels.joined(separator: ", ")), last 5 seconds, raw counts.")
        }
        .padding(.top, 4)
    }

    nonisolated private static func render(_ gc: GraphicsContext, size: CGSize, now: Double, source: SmoothSource,
                                           labels: [String], box: PPGRangeBox, fallback: Color, grid: Color) {
        drawSecondLines(gc, size: size, now: now, color: grid)
        let traces = source.traces(now: now)
        let all = traces.flatMap { $0.map(\.v) }
        guard let lo = all.min(), let hi = all.max(), size.width > 1, size.height > 1 else { return }
        let range = box.range.update(dataLo: lo, dataHi: hi, now: now)
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return }
        let window = LiveSmoothPPGPlots.windowSeconds
        let columns = max(1, Int(size.width))
        for (i, pts) in traces.enumerated() {
            let cols = LiveWaves.minMaxColumns(t: pts.map(\.t), v: pts.map(\.v), span: window, columns: columns)
            guard cols.count > 1 else { continue }
            var path = Path()
            for (k, c) in cols.enumerated() {
                let x = CGFloat(c.t / window) * size.width
                let y = CGFloat(1 - (c.v - range.lowerBound) / span) * size.height
                let p = CGPoint(x: x, y: y)
                if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            let label = i < labels.count ? labels[i] : ""
            gc.stroke(path, with: .color(channelColor(label, fallback: fallback)),
                      style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }

    /// T145: a hairline at every whole second of the shared clock. The window is `[now - delay - 5 s, now - delay]`, the same
    /// for every plot, so the lines sit at the same instants on all of them and slide left together.
    nonisolated static func drawSecondLines(_ gc: GraphicsContext, size: CGSize, now: Double, color: Color) {
        let window = LiveSmoothPPGPlots.windowSeconds
        let right = now - LivePPGFeed.delay
        let left = right - window
        guard size.width > 1, left.isFinite else { return }
        var path = Path()
        var t = left.rounded(.up)
        while t <= right {
            let x = CGFloat((t - left) / window) * size.width
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            t += 1
        }
        gc.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 0.5))
    }

    nonisolated static func channelColor(_ label: String, fallback: Color) -> Color {
        label.hasPrefix("Green") || label.hasPrefix("Cleaned") ? .green
            : label.hasPrefix("Red") ? .red : label.hasPrefix("IR") ? .purple : fallback
    }
}

/// R9f (T146): a finished wave drawn once (no timeline, no feed): the last ECG reading, start to end of the reading, with the
/// peaks kept (min-max columns). The label chip is the same look as the live plots; the x axis is the reading's own time
/// ("start" to "end"), not the sliding 5 s window, and the caption says so.
struct StillWaveLine: View {
    let label: String
    let samples: [Double]
    var height: Double = 160
    var kind: String = "Last ECG reading"
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .mgFont(.label)
                .foregroundStyle(colors.live.color)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(colors.chip.color))
            let pts = samples, inkColor = colors.live.color, gridColor = colors.rule.color
            Canvas { gc, size in
                Self.render(gc, size: size, samples: pts, ink: inkColor, grid: gridColor)
            }
            .padding(.trailing, LiveHRTrace.axisLabelWidth)
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(kind), \(label), raw counts.")
            HStack {
                Text("start")
                Spacer(minLength: 0)
                Text("end of the reading")
            }
            .mgFont(.receipt)
            .foregroundStyle(colors.mute.color)
            .padding(.trailing, LiveHRTrace.axisLabelWidth)
            .accessibilityHidden(true)
        }
        .padding(.top, 4)
    }

    nonisolated private static func render(_ gc: GraphicsContext, size: CGSize, samples: [Double], ink: Color, grid: Color) {
        let v = samples.filter(\.isFinite)
        guard v.count > 1, let lo = v.min(), let hi = v.max(), size.width > 1, size.height > 1 else { return }
        let pad = hi > lo ? (hi - lo) * 0.1 : 1
        let span = (hi - lo) + 2 * pad
        let t = v.indices.map { Double($0) }
        let cols = LiveWaves.minMaxColumns(t: t, v: v, span: Double(v.count), columns: max(1, Int(size.width)))
        var path = Path()
        for (k, c) in cols.enumerated() {
            let p = CGPoint(x: CGFloat(c.t / Double(v.count - 1)) * size.width,
                            y: CGFloat(1 - (c.v - (lo - pad)) / span) * size.height)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        gc.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
    }
}
