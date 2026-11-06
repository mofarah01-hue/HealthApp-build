import SwiftUI
import Charts
import MGContext
import MGDesign
import MGDomain

// The workout HR map (APP-051 "an HR map across the workout (zone shading, …)"; UX §14 "HR map with zone shading").
// Owner: WP-29. Draws `WorkoutHRMapState` and the time windows; computes nothing shown as a number:
// - zone bands (ALG-106 edges from the state) shaded across the whole workout, same colours as Live's zone bar
//   (`LiveZoneStyle`, WP-13) so a zone looks the same everywhere;
// - every time window as a faint alternating wash with its name at the top, and a dashed line where it starts;
// - the HR line from the state's regular series, broken at gaps (no reading → no line, never interpolated).

private struct WorkoutZoneBand: Identifiable {
    let id: Int       // zone 1…5
    let low: Double
    let high: Double
}

private struct WorkoutWindowSpan: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let name: String
    let shaded: Bool
    let first: Bool
}

struct WorkoutHRMapChart: View {
    let map: WorkoutHRMapState
    let windows: [WorkoutDetailWindow]
    /// The workout's end; nil = still running (the map ends at the last reading).
    let end: Date?
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    /// R8j (audit 7.5): the readings are built (and thinned) once when the view is made, not on every body pass.
    private let samples: [WorkoutHRSample]

    /// At most this many points are drawn: each run keeps the lowest and highest reading of every bucket, so a peak survives.
    static let maxPoints = 400

    init(map: WorkoutHRMapState, windows: [WorkoutDetailWindow], end: Date?) {
        self.map = map
        self.windows = windows
        self.end = end
        self.samples = Self.decimated(map.samples())
    }

    /// Thins `all` per unbroken run (a gap must stay a gap), keeping each bucket's lowest and highest reading.
    static func decimated(_ all: [WorkoutHRSample], limit: Int = maxPoints) -> [WorkoutHRSample] {
        guard all.count > limit else { return all }
        var out: [WorkoutHRSample] = []
        out.reserveCapacity(limit + 8)
        var from = 0
        while from < all.count {
            var to = from
            while to < all.count, all[to].segment == all[from].segment { to += 1 }
            let run = Array(all[from..<to])
            let share = max(4, Int(Double(limit) * Double(run.count) / Double(all.count)))
            let keep = LiveWaves.minMaxIndices(run.map(\.bpm), limit: share)
            out.append(contentsOf: keep.map { run[$0] })
            from = to
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reason = map.blankReason {
                blank(reason)
            } else if samples.count < 2 {
                blank("Not enough heart-rate readings to draw a map.")
            } else {
                chart(samples)
                axisLine(samples)
            }
            Text(caption)
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
            if let receipt = map.receipt {
                ReceiptLabel(receipt)
            }
        }
    }

    private func chart(_ samples: [WorkoutHRSample]) -> some View {
        let xDomain = domain(samples)
        let yDomain = bpmDomain(samples)
        let spans = windowSpans(in: xDomain)
        return Chart {
            ForEach(bands(in: yDomain)) { band in
                RectangleMark(xStart: .value("From", xDomain.lowerBound), xEnd: .value("To", xDomain.upperBound),
                              yStart: .value("Zone low", band.low), yEnd: .value("Zone high", band.high))
                    .foregroundStyle(LiveZoneStyle.color(zone: band.id, colors: colors).opacity(0.16).color)
            }
            ForEach(spans) { span in
                RectangleMark(xStart: .value("Window start", span.start), xEnd: .value("Window end", span.end),
                              yStart: .value("Low", yDomain.lowerBound), yEnd: .value("High", yDomain.upperBound))
                    .foregroundStyle(colors.ink.opacity(span.shaded ? 0.06 : 0.001).color)
                    .annotation(position: .overlay, alignment: .topLeading, spacing: 2) {
                        Text(span.name)
                            .mgFont(.tag)
                            .foregroundStyle(colors.ink2.color)
                            .padding(.leading, 3)
                            .padding(.top, 2)
                    }
                if !span.first {
                    RuleMark(x: .value("Window starts", span.start))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(colors.ink2.opacity(0.6).color)
                }
            }
            ForEach(samples) { s in
                LineMark(x: .value("Time", s.at), y: .value("bpm", s.bpm), series: .value("Run", s.segment))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    .foregroundStyle(colors.body.color)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: map.validZoneEdges ?? []) { _ in
                AxisGridLine().foregroundStyle(colors.rule.color)
                AxisValueLabel().foregroundStyle(colors.mute.color)
            }
        }
        .frame(height: 170)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "17:32 … 18:20" under the chart (the windows table carries every time).
    private func axisLine(_ samples: [WorkoutHRSample]) -> some View {
        let d = domain(samples)
        return HStack {
            Text(MGFormat.time(d.lowerBound, calendar: calendar))
            Spacer(minLength: 0)
            Text(end == nil ? "now" : MGFormat.time(d.upperBound, calendar: calendar))
        }
        .mgFont(.receipt)
        .foregroundStyle(colors.mute.color)
        .accessibilityHidden(true)
    }

    private func blank(_ text: String) -> some View {
        Text(text)
            .mgFont(.detail)
            .foregroundStyle(colors.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }

    // MARK: Geometry (drawing ranges only)

    /// Workout start → its end (or the last reading while live); never empty.
    private func domain(_ samples: [WorkoutHRSample]) -> ClosedRange<Date> {
        let lo = min(map.start, samples.first?.at ?? map.start)
        let last = samples.last?.at ?? lo
        let hi = max(end ?? last, last, lo.addingTimeInterval(1))
        return lo...hi
    }

    private func bpmDomain(_ samples: [WorkoutHRSample]) -> ClosedRange<Double> {
        let values = samples.map(\.bpm)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let low = min(lo, map.validZoneEdges?.first ?? lo) - 8
        let high = max(hi, map.validZoneEdges?.last ?? hi) + 8
        return low...high
    }

    private func bands(in d: ClosedRange<Double>) -> [WorkoutZoneBand] {
        guard let e = map.validZoneEdges else { return [] }
        let bounds = [d.lowerBound] + e + [d.upperBound]
        return (0..<5).compactMap { i in
            let low = max(bounds[i], d.lowerBound)
            let high = min(bounds[i + 1], d.upperBound)
            return high > low ? WorkoutZoneBand(id: i + 1, low: low, high: high) : nil
        }
    }

    private func windowSpans(in d: ClosedRange<Date>) -> [WorkoutWindowSpan] {
        let inRange = windows.filter { $0.end > d.lowerBound && $0.start < d.upperBound && $0.end > $0.start }
        return inRange.enumerated().map { i, w in
            WorkoutWindowSpan(id: w.id, start: max(w.start, d.lowerBound), end: min(w.end, d.upperBound),
                              name: w.kind.map { WorkoutDetailWindow.title(for: $0) } ?? w.label,
                              shaded: i % 2 == 0, first: i == 0)
        }
    }

    private var caption: String {
        if map.blankReason != nil { return "zone bands need heart-rate readings" }
        if let basis = map.zoneBasis, map.validZoneEdges != nil {
            return "zone bands from your \(basis) (ALG-106) · dashed lines = window starts · gaps = no reading"
        }
        if map.zoneEdgesBpm != nil { return "Zone bands not drawn: the zone edges are not four rising heart rates." }
        return "Zone bands need your max heart rate; none is known yet. Dashed lines = window starts."
    }

    private var accessibilityText: String {
        var parts = ["Heart rate map across the workout"]
        if map.validZoneEdges != nil { parts.append("zone bands shaded") }
        if !windows.isEmpty {
            let list = windows.map { w -> String in
                let name = w.kind.map { WorkoutDetailWindow.title(for: $0) } ?? w.label
                return "\(name) \(MGFormat.timeRange(w.start, w.end, calendar: calendar))"
            }
            parts.append("windows: " + list.joined(separator: "; "))
        }
        return parts.joined(separator: ", ") + ". Values per window are in the table below."
    }
}
