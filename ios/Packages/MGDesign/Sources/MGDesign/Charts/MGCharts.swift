import SwiftUI
import Charts
import MGContext

// MGChart helpers (ARCHITECTURE §4.8): SparklineView, BandedDotChart, TrendLineChart, DivergingHeatmap.
// They draw what they are given; every number (bands, EWMA, CUSUM marks, ρ) is computed upstream (WP-09 / WP-15
// functions via state) — never in a view (WP-19 acceptance).

/// One dated value; `nil` = no value that day (drawn as a gap, never as zero).
public struct ChartPoint: Identifiable, Hashable, Sendable {
    public let date: Date
    public let value: Double?
    public var id: Date { date }

    public init(date: Date, value: Double?) {
        self.date = date
        self.value = value
    }
}

/// A flag on the x-axis: device change (firmware, wear location, scale — APP-101) or a Health-vault entry (APP-102).
public struct ChartMarker: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case device, healthVault }
    public let date: Date
    public let label: String
    public let kind: Kind
    public var id: String { "\(date.timeIntervalSince1970)|\(label)" }

    public init(date: Date, label: String, kind: Kind) {
        self.date = date
        self.label = label
        self.kind = kind
    }
}

private struct PresentPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

private func present(_ points: [ChartPoint]) -> [PresentPoint] {
    points.compactMap { p in p.value.map { PresentPoint(date: p.date, value: $0) } }
}

// MARK: - Sparkline

/// A small line: Explore shelf rows (64 × 18, the default) or a Now row's opened chart (`width: nil` = full width).
/// Gaps where values are missing — never drawn as zero.
public struct SparklineView: View {
    @Environment(\.mgColors) private var colors
    private let values: [Double?]
    private let accent: InkTone
    private let width: CGFloat?
    private let height: CGFloat
    private let lineWidth: CGFloat

    public init(values: [Double?], accent: InkTone = .ink2, width: CGFloat? = 64, height: CGFloat = 18,
                lineWidth: CGFloat = 1.4) {
        self.values = values
        self.accent = accent
        self.width = width
        self.height = height
        self.lineWidth = lineWidth
    }

    public var body: some View {
        Canvas { ctx, size in
            let known = values.compactMap { $0 }
            guard known.count >= 2, values.count >= 2, let lo = known.min(), let hi = known.max() else { return }
            let span = (hi - lo) == 0 ? 1 : (hi - lo)
            var path = Path()
            var penDown = false
            for (i, v) in values.enumerated() {
                guard let v else { penDown = false; continue }
                let x = CGFloat(i) / CGFloat(values.count - 1) * size.width
                let y = size.height - 2 - CGFloat((v - lo) / span) * (size.height - 4)
                if penDown { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)) }
                penDown = true
            }
            ctx.stroke(path, with: .color(colors.mark(accent).color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .accessibilityHidden(true)
    }
}

// MARK: - Banded dot chart (MetricDetail "Graph")

/// Dots per day on one y-axis, the normal band shaded (median ± 1.4826·MAD over 28 d, computed upstream),
/// device / vault flags on the x-axis, tap or drag to read a value (UX §9).
public struct BandedDotChart: View {
    @Environment(\.mgColors) private var colors
    private let points: [ChartPoint]
    private let band: ClosedRange<Double>?
    private let markers: [ChartMarker]
    private let unit: String
    private let format: (Double) -> String
    @State private var selected: Date?

    public init(points: [ChartPoint], band: ClosedRange<Double>?, markers: [ChartMarker] = [], unit: String,
                format: @escaping (Double) -> String = { String(format: "%.1f", $0) }) {
        self.points = points
        self.band = band
        self.markers = markers
        self.unit = unit
        self.format = format
    }

    public var body: some View {
        let shown = present(points)
        let first = points.first?.date
        let last = points.last?.date
        Chart {
            if let band, let first, let last {
                ForEach([first, last], id: \.self) { d in
                    AreaMark(x: .value("Day", d), yStart: .value("Band low", band.lowerBound),
                             yEnd: .value("Band high", band.upperBound))
                        .foregroundStyle(colors.bandHigh.color)
                }
            }
            ForEach(shown) { p in
                PointMark(x: .value("Day", p.date, unit: .day), y: .value(unit, p.value))
                    .symbolSize(22)
                    .foregroundStyle(colors.ink.color)
            }
            ForEach(markers) { m in
                RuleMark(x: .value("Day", m.date, unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .foregroundStyle(colors.mute.color)
                    .annotation(position: .bottom, alignment: .center) {
                        Text(m.kind == .device ? "⚑" : "◆")
                            .font(.system(size: 9))
                            .foregroundStyle(colors.ink2.color)
                            .accessibilityLabel(m.label)
                    }
            }
            if let selected, let hit = shown.min(by: { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }) {
                RuleMark(x: .value("Day", hit.date, unit: .day))
                    .foregroundStyle(colors.ink.color.opacity(0.4))
                    .annotation(position: .top, alignment: .center) {
                        Text("\(format(hit.value)) \(unit)")
                            .mgFont(.receipt)
                            .foregroundStyle(colors.ink.color)
                            .padding(4)
                            .mgSurface(.card, radius: 6)
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(colors.rule.color)
                AxisValueLabel().foregroundStyle(colors.mute.color)
            }
        }
        .chartYAxisLabel(position: .leading, alignment: .center) {      // r9v (E13): the unit on the axis itself
            if !unit.isEmpty { Text(unit).mgFont(.receipt).foregroundStyle(colors.mute.color) }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(colors.mute.color)
            }
        }
        .frame(minHeight: 180)
        .accessibilityLabel("\(shown.count) daily values in \(unit)" + (band != nil ? ", with your normal band shaded" : ""))
    }
}

// MARK: - Trend line (MetricDetail "Trend")

/// EWMA line over faint daily dots, with CUSUM change marks (ALG-075, computed upstream).
public struct TrendLineChart: View {
    @Environment(\.mgColors) private var colors
    private let points: [ChartPoint]
    private let ewma: [ChartPoint]
    private let changeMarks: [Date]
    private let unit: String

    public init(points: [ChartPoint], ewma: [ChartPoint], changeMarks: [Date], unit: String) {
        self.points = points
        self.ewma = ewma
        self.changeMarks = changeMarks
        self.unit = unit
    }

    public var body: some View {
        Chart {
            ForEach(present(points)) { p in
                PointMark(x: .value("Day", p.date, unit: .day), y: .value(unit, p.value))
                    .symbolSize(14)
                    .foregroundStyle(colors.mute.color)
            }
            ForEach(present(ewma)) { p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("EWMA", p.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(colors.ink.color)
            }
            ForEach(changeMarks, id: \.self) { d in
                RuleMark(x: .value("Change", d, unit: .day))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .foregroundStyle(colors.caffeine.color)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(colors.rule.color)
                AxisValueLabel().foregroundStyle(colors.mute.color)
            }
        }
        .chartYAxisLabel(position: .leading, alignment: .center) {      // r9v (E13): the unit on the axis itself
            if !unit.isEmpty { Text(unit).mgFont(.receipt).foregroundStyle(colors.mute.color) }
        }
        .frame(minHeight: 180)
        .accessibilityLabel("Trend line in \(unit), \(changeMarks.count) change points marked")
    }
}

// MARK: - Diverging heatmap (Matrix, APP-104)

/// One Spearman ρ cell. `rho == nil` → blank "too few days (n)" (UX §13).
public struct HeatCell: Hashable, Sendable {
    public let rho: Double?
    public let n: Int
    public let note: String?

    public init(rho: Double?, n: Int, note: String? = nil) {
        self.rho = rho
        self.n = n
        self.note = note
    }
}

/// Spearman ρ grid on a diverging scale: two hues (sleep blue for negative, caffeine amber for positive — a
/// colour-blind-safe pair) and a neutral middle. Cell text picks ink or buttonText by contrast.
public struct DivergingHeatmap: View {
    @Environment(\.mgColors) private var colors
    private let labels: [String]
    private let cells: [[HeatCell]]
    private let onSelect: (Int, Int) -> Void

    public init(labels: [String], cells: [[HeatCell]], onSelect: @escaping (Int, Int) -> Void) {
        self.labels = labels
        self.cells = cells
        self.onSelect = onSelect
    }

    public var body: some View {
        // r8h E6: cells are at least 44 x 44; when 7-8 metrics no longer fit the width, the grid scrolls sideways.
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: false) { grid }
        }
    }

    private var grid: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(labels.indices, id: \.self) { c in
                    Text(labels[c]).mgFont(.tag).foregroundStyle(colors.ink2.color).lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
            ForEach(cells.indices, id: \.self) { r in
                GridRow {
                    Text(r < labels.count ? labels[r] : "").mgFont(.tag).foregroundStyle(colors.ink2.color)
                        .lineLimit(2).frame(maxWidth: 64, alignment: .leading)
                    ForEach(cells[r].indices, id: \.self) { c in
                        cellView(cells[r][c], row: r, col: c)
                    }
                }
            }
        }
    }

    private func cellView(_ cell: HeatCell, row: Int, col: Int) -> some View {
        let fill = cell.rho.map { fillColor(rho: $0) } ?? colors.chip
        let label: String = cell.rho.map { String(format: "%+.2f", $0) } ?? "—"
        let rowName = row < labels.count ? labels[row] : "row \(row + 1)"
        let colName = col < labels.count ? labels[col] : "column \(col + 1)"
        // The diagonal is a metric against itself: disabled and dimmed, not a dead tap.
        let isDiagonal = row == col
        return Button { onSelect(row, col) } label: {
            Text(label)
                .mgFont(.receipt)
                .foregroundStyle(textColor(on: fill).color)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 4).fill(fill.color))
                .opacity(isDiagonal ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDiagonal)
        .accessibilityLabel(cell.rho.map { "\(rowName) and \(colName): rho \(String(format: "%.2f", $0)), \(cell.n) days" }
                            ?? "\(rowName) and \(colName): too few days, \(cell.n)")
    }

    /// Linear in sRGB from the neutral chip colour to the hue at |ρ| = 1.
    private func fillColor(rho: Double) -> MGRGBA {
        let t = min(1, abs(rho))
        let end = rho < 0 ? colors.sleep : colors.caffeine
        let mid = MGRGBA.composite(colors.chip, over: colors.background.lastColor)
        return MGRGBA(red: mid.red + (end.red - mid.red) * t,
                      green: mid.green + (end.green - mid.green) * t,
                      blue: mid.blue + (end.blue - mid.blue) * t)
    }

    private func textColor(on fill: MGRGBA) -> MGRGBA {
        let base = MGRGBA.composite(fill, over: colors.background.lastColor)
        return MGRGBA.contrast(colors.ink, on: base) >= MGRGBA.contrast(colors.buttonText, on: base)
            ? colors.ink : colors.buttonText
    }
}

extension MGRGBA {
    /// `fg` composited over an opaque `bg`.
    public static func composite(_ fg: MGRGBA, over bg: MGRGBA) -> MGRGBA {
        let a = fg.alpha
        return MGRGBA(red: fg.red * a + bg.red * (1 - a),
                      green: fg.green * a + bg.green * (1 - a),
                      blue: fg.blue * a + bg.blue * (1 - a))
    }

    /// WCAG 2.x relative luminance (alpha ignored; composite first).
    public var luminance: Double {
        func lin(_ c: Double) -> Double {
            let s = c / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// WCAG contrast ratio of `fg` (composited) on an opaque `bg`.
    public static func contrast(_ fg: MGRGBA, on bg: MGRGBA) -> Double {
        let a = composite(fg, over: bg).luminance
        let b = bg.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
