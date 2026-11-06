import SwiftUI
import Charts
import MGContext
import MGDesign
import MGDomain

// The three live traces of the Live tab, drawn with Swift Charts (UX-SPEC §6 rows 3–4, workout HRMap).
// They draw what the state holds; no number shown here is computed in a view except the count of flagged beats
// and axis ranges. Artefact flags, RMSSD and bands come from MGSignal through `LiveState`.

private struct LiveIndexed: Identifiable {
    let id: Int
    let value: Double
}

// MARK: - Heart rate (#35: opens full, scrolls live)

private struct LiveHRItem: Identifiable {
    let id: Int
    let at: Date
    let bpm: Double
    /// A new run starts after a gap: the line is not drawn across seconds with no data.
    let run: Int
}

/// HR, the last 5 min, scrolling (Mo 2026-10-11: "as I open it's there scrolling live, like the HR in the WHOOP app").
/// The state holds stored seconds first, then live ones — one series, one style, so there is no seam between them. The
/// x-axis ends at the state's "now", so the line moves every second; a gap over 10 s breaks the line (never bridged).
struct LiveHRTrace: View {
    let points: [LiveHRPoint]
    let end: Date?
    /// Wave W11: "last 5 min of stored data, ending 9:12 PM" when the line shows the newest stored stretch.
    var note: String? = nil
    @Environment(\.mgColors) private var colors

    static let window: TimeInterval = 300
    static let gap: TimeInterval = 10
    /// Width of the right-hand label column; the raw optical wave reserves the same, so both plots are equally wide.
    static let axisLabelWidth: CGFloat = 30

    var body: some View {
        let items = self.items          // R8e (L7): one pass over the points per body, not five
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Heart rate", note: note ?? "last 5 min")
            if items.count < 2 {
                LiveChartBlank(text: "No heart rate in the last 5 minutes yet. The line starts with the first beats.")
            } else {
                Chart {
                    ForEach(items) { p in
                        LineMark(x: .value("Time", p.at), y: .value("bpm", p.bpm), series: .value("Run", p.run))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(colors.body.color)
                    }
                    if let last = items.last {
                        PointMark(x: .value("Time", last.at), y: .value("bpm", last.bpm))
                            .symbol { Circle().frame(width: 6, height: 6) }
                            .foregroundStyle(colors.body.color)
                    }
                }
                .chartXScale(domain: xDomain)
                .chartYScale(domain: yDomain(items))
                .chartXAxis(.hidden)
                .chartYAxis {
                    // T145: the label column has a fixed width so the raw optical wave under this graph has the same plot width.
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(colors.rule.color)
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(String(Int(v.rounded())))
                                    .mgFont(.label)
                                    .foregroundStyle(colors.mute.color)
                                    .frame(width: LiveHRTrace.axisLabelWidth, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(height: 140)
                .accessibilityLabel(accessibilityText(items))
            }
        }
        .padding(.bottom, MGSpace.s)
    }

    private var right: Date { end ?? items.last?.at ?? Date() }

    private var xDomain: ClosedRange<Date> { right.addingTimeInterval(-Self.window)...right }

    private var items: [LiveHRItem] {
        let from = right.addingTimeInterval(-Self.window)
        var out: [LiveHRItem] = []
        var run = 0
        for (i, p) in points.enumerated() where p.bpm.isFinite && p.at >= from && p.at <= right {
            if let prev = out.last, p.at.timeIntervalSince(prev.at) > Self.gap { run += 1 }
            out.append(LiveHRItem(id: i, at: p.at, bpm: p.bpm, run: run))
        }
        return out
    }

    private func yDomain(_ items: [LiveHRItem]) -> ClosedRange<Double> {
        let values = items.map { $0.bpm }
        guard let lo = values.min(), let hi = values.max() else { return 40...120 }
        let pad = max(5, (hi - lo) * 0.15)
        return (lo - pad)...(hi + pad)
    }

    private func accessibilityText(_ items: [LiveHRItem]) -> String {
        let values = items.map { $0.bpm }
        guard let lo = values.min(), let hi = values.max(), let last = values.last else { return "Heart rate" }
        return "Heart rate, last 5 minutes, from \(Int(lo.rounded())) to \(Int(hi.rounded())) beats per minute, "
            + "now \(Int(last.rounded()))."
    }
}

// MARK: - Pulse wave (row 3: PulseWave)

/// T146: one extra stream under the heart-rate graph - its title and note with its own switch beside them (tap = on / off,
/// the same intent as Strap & sync), then the wave(s) or the plain reason there is none, then the row's status line and
/// buttons (motion). Pure rendering of `LiveWaveRow`. R9f: the raw PPG has its own card (`LivePPGCard`), so this view draws the
/// 100 Hz motion row (the same Canvas, min-max columns and shared 5 s axis as the PPG plots, from `LiveWaveFeeds.motion`) and
/// the ECG row (the last finished reading, a still Canvas). It is only built while the Waves section is open.
struct LiveWaveRowView: View {
    let row: LiveWaveRow
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    private let plotHeight: Double = 160

    var body: some View {
        MGCard {
            VStack(alignment: .leading, spacing: 0) {
                if row.id == "ecg" {
                    // R8e (L4): ECG is a timed reading, not a stream: a button that starts it, under one name ("ECG reading").
                    // The permission switch lives in Strap & sync.
                    MGButton("Start ECG reading", style: .filled, action: { send(.startECG) })
                        .disabled(!row.toggle.enabled || !row.toggle.isOn)
                        .frame(minHeight: MGSpace.tapTarget)
                    LiveStrapSyncLink(what: "ECG", send: send)
                } else {
                    OptimisticToggle(isOn: row.toggle.isOn, onChange: { _ in send(row.toggle.intent) }) {
                        Text(row.title)
                            .mgFont(.rowTitle)
                            .foregroundStyle(colors.ink.color)
                    }
                    .tint(colors.focus.color)
                    .disabled(!row.toggle.enabled)
                    .frame(minHeight: MGSpace.tapTarget)
                }

                Text(row.note)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: MGSpace.s, lineSpacing: MGSpace.xs) {
                    if row.note.localizedCaseInsensitiveContains("raw counts") {
                        TagPill(text: "raw counts, no unit")
                    }
                    if row.note.localizedCaseInsensitiveContains("decoded, untested") {
                        TagPill(text: "decoded, untested")
                    }
                    if row.title.localizedCaseInsensitiveContains("research") {
                        ResearchTag()
                    }
                }
                .padding(.top, MGSpace.s)

                if let reason = row.reason {
                    Text(reason)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, MGSpace.m)
                } else if row.id == "motion", let feed = LiveWaveFeeds.feed(forRow: row.id) {
                    ForEach(row.waves) { wave in
                        SmoothWaveLine(labels: [wave.label], height: plotHeight,
                                       fps: LiveSmoothPPGPlots.framesPerSecond(plots: 1),
                                       source: .feed(ids: [wave.id], fallback: [wave], normalise: false, feed: feed),
                                       kind: "100 Hz motion")
                    }
                    LiveWaveAxis()
                } else if row.id == "ecg" {
                    ForEach(row.waves) { wave in
                        StillWaveLine(label: wave.label, samples: wave.samples, height: plotHeight, kind: "Last ECG reading")
                    }
                }
                if let detail = row.detail {
                    Text(detail)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, MGSpace.s)
                }
                if !row.actions.isEmpty {
                    HStack(spacing: MGSpace.s) {
                        ForEach(row.actions) { a in
                            MGButton(a.title, style: .ghost) { if let i = a.intent { send(i) } }
                                .disabled(!a.enabled)
                        }
                    }
                    .padding(.top, MGSpace.s)
                }
            }
        }
        .padding(.top, MGSpace.section)
    }
}

/// R26 PPG, last 8 s, `live` colour, quality label (ALG-005 quality). The state holds raw ADC counts, so the y-axis
/// is hidden: the shape matters, the scale is not a unit (BRIEF "raw counts are not units").
struct LivePulseWave: View {
    let samples: [Double]
    let quality: String?
    let sample: Bool
    /// Bug 3 (2026-10-14): the presenter's honest reason (LiveState.pulseBlank) and the rate / no-pulse line (pulseNote).
    var blank: String = "No pulse wave yet."
    var pulseNote: String? = nil
    /// P9729 (job 12): ALG-144 cleaned trace, quality chip, estimate / reason line (LiveState.clean*); nil chip = none.
    var cleanSamples: [Double] = []
    var cleanChip: StreamChipState? = nil
    var cleanNote: String? = nil
    @Environment(\.mgColors) private var colors

    var body: some View {
        let points = self.points          // R8e (L7): once per body
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Pulse wave", note: note)
            if points.count < 2 {
                LiveChartBlank(text: blank)
            } else {
                Chart {
                    ForEach(points) { p in
                        LineMark(x: .value("Sample", p.id), y: .value("PPG counts", p.value))
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(colors.live.color)
                    }
                }
                .chartXScale(domain: 0...(max(1, points.count - 1)))
                .chartYScale(domain: yDomain(points))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 120)
                .accessibilityLabel("Pulse wave from the strap, last seconds. \(quality ?? "Quality not rated.")")
                if let pulseNote {
                    Text(pulseNote)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let cleanChip {
                cleanSection(cleanChip)
            }
        }
    }

    /// P9729 (job 12): the ALG-144 cleaned trace under the raw one, its quality chip and the estimate / reason line.
    @ViewBuilder private func cleanSection(_ chip: StreamChipState) -> some View {
        HStack(spacing: 8) {
            Text("Cleaned (ALG-144, band-passed raw counts, decoded, untested)")
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            LiveStreamChip(chip: chip)
        }
        .padding(.top, 8)
        let pts = cleanSamples.enumerated().compactMap { i, v in v.isFinite ? LiveIndexed(id: i, value: v) : nil }
        if pts.count >= 2 {
            let lo = pts.map(\.value).min() ?? 0, hi = pts.map(\.value).max() ?? 1
            let pad = hi > lo ? (hi - lo) * 0.1 : 1
            Chart {
                ForEach(pts) { p in
                    LineMark(x: .value("Sample", p.id), y: .value("Cleaned counts", p.value))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(colors.live.color)
                }
            }
            .chartXScale(domain: 0...(max(1, pts.count - 1)))
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 90)
            .accessibilityLabel("Cleaned pulse wave, ALG-144. \(chip.text)")
        }
        if let cleanNote {
            Text(cleanNote)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var note: String {
        ["last seconds", quality].compactMap { $0 }.joined(separator: " · ")
    }

    private var points: [LiveIndexed] {
        samples.enumerated().compactMap { i, v in v.isFinite ? LiveIndexed(id: i, value: v) : nil }
    }

    private func yDomain(_ points: [LiveIndexed]) -> ClosedRange<Double> {
        let values = points.map { $0.value }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = hi > lo ? (hi - lo) * 0.1 : 1
        return (lo - pad)...(hi + pad)
    }
}

// MARK: - Tachogram (row 4: Tachogram)

/// R-R, last 60 s. Clean beats are the line; artefacts are hollow rings and are left out of the line (ALG-004).
/// A ring whose value would stretch the axis (a missed beat reads 1 400 ms) is pinned to the axis edge.
struct LiveTachogram: View {
    let points: [TachogramPoint]
    let median: DisplayValue
    /// T21: the right edge of the fixed 60 s axis ("now", or the end of the stored stretch); nil = the newest beat.
    var end: Date? = nil
    /// Wave W11: "last 60 s of stored beats, ending 9:12 PM" when the beats come from the store.
    var note: String? = nil
    /// Bug 23: the Live tab's blank reason (strap off, not connected), shown first when there is no line.
    var liveBlank: String? = nil
    /// b-11 (Mo 2026-10-14): "+ bpm" shows each beat as bpm too, in the dots' colour, so the two read as one.
    @State private var showBpm = false
    @Environment(\.mgColors) private var colors

    /// T9879 (R9f): the beats' dots, the bpm read-outs and the "+ bpm" button are ONE colour - the heart-rate hue the heart-rate
    /// graph uses - so the two read as one. The line between the dots stays ink; the hollow artefact rings keep the hue too.
    private var beatColor: Color { colors.body.color }
    /// Dots on every clean beat (a filled dot, 5 pt) only while there are few enough to be told apart.
    private static let dotLimit = 150

    var body: some View {
        let layout = self.layout          // R8e (L7): built once per body (it ran about 8 times)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Beat to beat", note: (note ?? "last 60 s") + " · " + TachogramLayout.axisHint
                          + " · hollow = artefact, left out")
            if let why = layout.emptyReason(liveBlank: liveBlank) {
                LiveChartBlank(text: why)     // bug 23: the specific reason
            } else {
                Chart {
                    ForEach(Array(layout.line.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Time", p.at), y: .value("R-R ms", p.rrMs), series: .value("Run", p.run))
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                            .foregroundStyle(colors.ink.color)
                    }
                    if layout.line.count <= Self.dotLimit {
                        ForEach(Array(layout.line.enumerated()), id: \.offset) { _, p in
                            PointMark(x: .value("Time", p.at), y: .value("R-R ms", p.rrMs))
                                .symbol { Circle().fill(beatColor).frame(width: 5, height: 5) }
                        }
                    }
                    ForEach(Array(layout.rings.enumerated()), id: \.offset) { _, p in
                        PointMark(x: .value("Time", p.at), y: .value("R-R ms", clampedY(p.rrMs, layout)))
                            .symbol {
                                Circle()
                                    .strokeBorder(beatColor, lineWidth: 1.5)
                                    .frame(width: 5, height: 5)
                            }
                    }
                }
                .chartXScale(domain: layout.xDomain)
                .chartYScale(domain: layout.yDomain)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(colors.rule.color)
                        AxisValueLabel().foregroundStyle(colors.mute.color)
                    }
                }
                .chartYAxisLabel(TachogramLayout.axisLabel, position: .leading)     // bug 23: the unit on screen
                .chartOverlay { _ in
                    if showBpm {
                        // b-11: the same y positions read as bpm (60 000 / ms), in the dots' colour.
                        let ticks = bpmTicks(layout)
                        VStack {
                            ForEach(ticks, id: \.self) { ms in
                                Text("\(Int((60_000 / ms).rounded())) bpm")
                                    .mgFont(.label)
                                    .foregroundStyle(beatColor)
                                if ms != ticks.last { Spacer(minLength: 0) }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { showBpm.toggle() }
                .frame(height: 140)
                .accessibilityLabel("Beat to beat intervals, last 60 seconds. \(layout.rings.count) flagged beats left out.")
                .accessibilityHint("Shows the beats as bpm. The button under the graph does the same.")
            }
            caption(layout)
        }
    }

    private func caption(_ layout: TachogramLayout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("median").mgFont(.receipt).foregroundStyle(colors.mute.color)
                ValueView(median, size: .inline)
                if showBpm, let bpm = medianBpm(layout) {
                    Text("≈ \(bpm) bpm").mgFont(.receipt).foregroundStyle(beatColor)   // b-11 / T9879: the dots' colour
                }
                if layout.line.count >= 2 {
                    // R8e (L6): a real button, 44 pt tall (it was a receipt-size Text with a tap gesture, about 12 pt).
                    Button { showBpm.toggle() } label: {
                        Text(showBpm ? "− bpm" : "+ bpm")
                            .mgFont(.receipt)
                            .foregroundStyle(beatColor)          // b-11 / T9879: the + and bpm share the dots' colour
                            .padding(.horizontal, MGSpace.s)
                            .frame(minWidth: MGSpace.tapTarget, minHeight: MGSpace.tapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showBpm ? "Hide beats as bpm" : "Show beats as bpm")
                }
            }
            if !points.isEmpty {
                Text(artefactText(layout))
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
            }
        }
        .padding(.top, 4)
    }

    private func artefactText(_ layout: TachogramLayout) -> String {
        let n = layout.rings.count
        if n == 0 { return "no beats left out (ALG-004)" }
        return n == 1 ? "1 artefact left out (ALG-004)" : "\(n) artefacts left out (ALG-004)"
    }

    private var layout: TachogramLayout {
        TachogramLayout.make(points, end: end ?? points.map(\.at).max() ?? Date())
    }

    /// Three ms values, top to bottom of the y-axis, for the bpm labels (top = longest interval = slowest beat).
    private func bpmTicks(_ layout: TachogramLayout) -> [Double] {
        let y = layout.yDomain
        guard y.lowerBound > 0 else { return [] }
        return [y.upperBound, (y.lowerBound + y.upperBound) / 2, y.lowerBound]
    }

    /// The clean beats' median as bpm; nil without clean beats.
    private func medianBpm(_ layout: TachogramLayout) -> Int? {
        let xs = layout.line.map(\.rrMs).filter { $0 > 0 }.sorted()
        guard !xs.isEmpty else { return nil }
        let m = xs.count % 2 == 1 ? xs[xs.count / 2] : (xs[xs.count / 2 - 1] + xs[xs.count / 2]) / 2
        return Int((60_000 / m).rounded())
    }

    private func clampedY(_ rr: Double, _ layout: TachogramLayout) -> Double {
        min(max(rr, layout.yDomain.lowerBound), layout.yDomain.upperBound)
    }
}

// MARK: - HR map (workout mode: HRMap)

/// Zone colour order is fixed: Z1 ink2, Z2 focus, Z3 caffeine, Z4 body, Z5 ink (prototype `zoneBar` / `hrMap`).
enum LiveZoneStyle {
    static func color(zone: Int, colors: ThemeColors) -> MGRGBA {
        switch zone {
        case 1: return colors.ink2.opacity(0.35)
        case 2: return colors.focus
        case 3: return colors.caffeine
        case 4: return colors.body
        default: return colors.ink
        }
    }
}

private struct LiveHRBand: Identifiable {
    let id: Int       // zone 1…5
    let low: Double
    let high: Double
}

/// HR so far (one value per 5 s), zone bands shaded when the state has the zone edges (ALG-106), the time axis
/// reduced to "start … now". With no edges it draws the trace alone and says why there is no shading.
struct LiveHRMap: View {
    let trace: [Double]
    let start: Date
    let zoneEdges: [Double]?
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if points.count < 2 {
                LiveChartBlank(text: "Not enough heart-rate samples yet.")
            } else {
                Chart {
                    ForEach(bands) { band in
                        RectangleMark(xStart: .value("Start", 0), xEnd: .value("End", points.count - 1),
                                      yStart: .value("Zone low", band.low), yEnd: .value("Zone high", band.high))
                            .foregroundStyle(LiveZoneStyle.color(zone: band.id, colors: colors).opacity(0.16).color)
                    }
                    ForEach(points) { p in
                        LineMark(x: .value("Sample", p.id), y: .value("bpm", p.value))
                            .interpolationMethod(.linear)
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                            .foregroundStyle(colors.body.color)
                    }
                }
                .chartXScale(domain: 0...(max(1, points.count - 1)))
                .chartYScale(domain: yDomain)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: edges ?? []) { _ in
                        AxisGridLine().foregroundStyle(colors.rule.color)
                        AxisValueLabel().foregroundStyle(colors.mute.color)
                    }
                }
                .frame(height: 120)
                .accessibilityLabel(accessibilityText)
                HStack {
                    Text(MGFormat.time(start, calendar: calendar))
                    Spacer(minLength: 0)
                    Text("now")
                }
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .accessibilityHidden(true)
            }
            Text(caption)
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var points: [LiveIndexed] {
        trace.enumerated().compactMap { i, v in v.isFinite ? LiveIndexed(id: i, value: v) : nil }
    }

    /// Four ascending, finite edges, or nil.
    private var edges: [Double]? {
        guard let e = zoneEdges, e.count == 4, e.allSatisfy({ $0.isFinite }), e == e.sorted() else { return nil }
        return e
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map { $0.value }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let low = min(lo, edges?.first ?? lo) - 8
        let high = max(hi, edges?.last ?? hi) + 8
        return low...high
    }

    private var bands: [LiveHRBand] {
        guard let e = edges else { return [] }
        let d = yDomain
        let bounds = [d.lowerBound] + e + [d.upperBound]
        return (0..<5).compactMap { i in
            let low = max(bounds[i], d.lowerBound)
            let high = min(bounds[i + 1], d.upperBound)
            return high > low ? LiveHRBand(id: i + 1, low: low, high: high) : nil
        }
    }

    private var caption: String {
        if edges != nil { return "zone bands shaded (ALG-106) · strap HR" }
        if zoneEdges != nil { return "Zone bands not drawn: the zone edges are not four rising heart rates." }
        return "Zone bands need your measured max HR; none is known yet."
    }

    private var accessibilityText: String {
        let values = points.map { $0.value }
        guard let lo = values.min(), let hi = values.max() else { return "Heart rate so far" }
        return "Heart rate so far this workout, from \(Int(lo.rounded())) to \(Int(hi.rounded())) beats per minute."
    }
}

// MARK: - Shared blank

/// A chart that has nothing to draw says why (UX §13), in the chart's own place.
struct LiveChartBlank: View {
    let text: String
    @Environment(\.mgColors) private var colors

    var body: some View {
        Text(text)
            .mgFont(.detail)
            .foregroundStyle(colors.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }
}
