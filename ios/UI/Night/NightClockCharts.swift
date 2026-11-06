import SwiftUI
import MGContext
import MGDesign

// Night's charts on one shared clock (UX-SPEC §8.2; prototype nightView() L842-858; owner WP-12):
// the hypnogram (stages in rows, confidence as shading) and the lanes under it (breathing events, sounds, SpO₂ byte
// dots, movement, strap sleep flag — whatever lanes the state carries). Both use the same x mapping and the same
// left label column, so a mark in a lane sits exactly under the stage it happened in.

/// The time window and x mapping every chart on the Night screen shares. The window itself (`NightClockWindow`) is
/// worked out by the presenter; building it here from every lane mark on each redraw was the old cost (audit 0.C-5).
struct NightClock: Equatable {
    let start: Date
    let end: Date

    /// Width of the label column left of every chart ("awake", "Breathing events"), so the time axes line up.
    static let labelColumn: CGFloat = 76

    init(window: NightClockWindow) {
        start = window.start
        end = window.end
    }

    /// "11 PM": the hour without ":00" (as the dial sheets do), so seven labels fit over a long night.
    static func axisLabel(_ t: Date, calendar: Calendar) -> String {
        MGFormat.time(t, calendar: calendar).replacingOccurrences(of: ":00", with: "")
    }

    /// x of `t` across a plot `width` wide (0 at `start`).
    func x(_ t: Date, width: CGFloat) -> CGFloat {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return CGFloat(min(max(t.timeIntervalSince(start) / span, 0), 1)) * width
    }

    /// Whole hours inside the window for the axis: every second hour, every third over a window longer than 10 h
    /// ("11 PM · 1 AM · 3 AM …"), so the labels never collide on a long night.
    func axisHours(calendar: Calendar) -> [Date] {
        guard var t = calendar.nextDate(after: start.addingTimeInterval(-1), matching: DateComponents(minute: 0, second: 0),
                                        matchingPolicy: .nextTime) else { return [] }
        let step: TimeInterval = end.timeIntervalSince(start) > 10 * 3600 ? 3 * 3600 : 2 * 3600
        var out: [Date] = []
        while t <= end {
            out.append(t)
            t = t.addingTimeInterval(step)
        }
        return out
    }
}

// MARK: - Hypnogram

/// Stages in four rows (awake on top, then REM, light, deep — position is the code, colour only repeats it).
/// Confidence (main, 2026-10-11): each bar at opacity 0.35 + 0.65 × confidence, a dotted outline below 0.5; nil = full
/// strength, no outline.
/// `.unstaged` (asleep, stage unknown; main, 2026-10-11) sits on the light row as an OUTLINED bar hatched in the light
/// colour, never filled, so it is never read as light sleep. No stage minutes are computed here (it can't inflate any).
struct NightStageChart: View {
    let stages: [StageSegment]
    let clock: NightClock

    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    static let maxWidth: CGFloat = 353
    static let chartHeight: CGFloat = 120
    static let rowHeight: CGFloat = 24
    static let barHeight: CGFloat = 16
    static let axisHeight: CGFloat = 24
    static let rows: [StageSegment.Stage] = [.awake, .rem, .light, .deep]

    /// The row a stage is drawn on: its own, or the light row for "asleep, stage unknown".
    static func row(of stage: StageSegment.Stage) -> Int? {
        rows.firstIndex(of: stage == .unstaged ? .light : stage)
    }

    /// The UX/main rule for confidence shading.
    static func opacity(_ confidence: Double?) -> Double {
        guard let c = confidence, c.isFinite else { return 1 }
        return 0.35 + 0.65 * min(max(c, 0), 1)
    }

    static func isUnsure(_ confidence: Double?) -> Bool {
        guard let c = confidence, c.isFinite else { return false }
        return c < 0.5
    }

    var body: some View {
        Canvas { ctx, size in
            let left = NightClock.labelColumn
            let plot = max(size.width - left, 1)
            for (i, stage) in Self.rows.enumerated() {
                let y = CGFloat(i) * Self.rowHeight
                ctx.draw(Text(Self.rowName(stage)).font(.system(size: 11, weight: .regular, design: .default))
                            .foregroundColor(colors.ink2.color),
                         at: CGPoint(x: 0, y: y + Self.barHeight / 2), anchor: .leading)
                // Faint row guide so an empty row still reads as a row.
                ctx.fill(Path(CGRect(x: left, y: y + Self.barHeight / 2 - 0.5, width: plot, height: 1)),
                         with: .color(colors.rule.color))
            }
            for seg in stages {
                guard let row = Self.row(of: seg.stage), seg.end > seg.start else { continue }
                let x0 = left + clock.x(seg.start, width: plot)
                let x1 = left + clock.x(seg.end, width: plot)
                let rect = CGRect(x: x0, y: CGFloat(row) * Self.rowHeight, width: max(1.5, x1 - x0),
                                  height: Self.barHeight)
                let shape = Path(roundedRect: rect, cornerRadius: 2)
                let shade = stageColor(seg.stage).opacity(Self.opacity(seg.confidence))
                if seg.stage == .unstaged {
                    ctx.drawLayer { layer in
                        layer.clip(to: shape)
                        var stripes = Path()
                        var x = rect.minX - rect.height
                        while x <= rect.maxX {
                            stripes.move(to: CGPoint(x: x, y: rect.maxY))
                            stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                            x += 4
                        }
                        layer.stroke(stripes, with: .color(shade.color), lineWidth: 1.2)
                    }
                    ctx.stroke(shape, with: .color(shade.color), lineWidth: 1)
                } else {
                    ctx.fill(shape, with: .color(shade.color))
                }
                if Self.isUnsure(seg.confidence) {
                    ctx.stroke(shape, with: .color(colors.ink2.color),
                               style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
                }
            }
            let axisY = CGFloat(Self.rows.count) * Self.rowHeight + Self.axisHeight / 2
            for t in clock.axisHours(calendar: calendar) {
                ctx.draw(Text(NightClock.axisLabel(t, calendar: calendar)).font(.system(size: 11, design: .monospaced))
                            .foregroundColor(colors.mute.color),
                         at: CGPoint(x: left + clock.x(t, width: plot), y: axisY), anchor: .center)
            }
        }
        .frame(maxWidth: Self.maxWidth)
        .frame(height: Self.chartHeight)
        .accessibilityElement(children: .ignore)
        // 0.C-5: the spoken strings are built only when an assistive reader is on, not on every redraw.
        .accessibilityLabel(voiceOver || switchControl ? spokenLabel : "Sleep stages")
        .accessibilityValue(voiceOver || switchControl ? spokenValue : "")
    }

    private func stageColor(_ stage: StageSegment.Stage) -> MGRGBA {
        switch stage {
        case .deep: return colors.stageDeep
        case .light: return colors.stageLight
        case .rem: return colors.stageRem
        case .awake: return colors.stageAwake
        case .unstaged: return colors.stageLight   // hatch + outline only, never a fill
        }
    }

    static func rowName(_ stage: StageSegment.Stage) -> String {
        switch stage {
        case .awake: return "awake"
        case .rem: return "REM"
        case .light: return "light"
        case .deep: return "deep"
        case .unstaged: return "asleep (stage unknown)"
        }
    }

    private var spokenLabel: String {
        guard let first = stages.map(\.start).min(), let last = stages.map(\.end).max() else {
            return "Sleep stages: none recorded"
        }
        return "Sleep stages, \(MGFormat.time(first, calendar: calendar)) to \(MGFormat.time(last, calendar: calendar))"
    }

    /// The stages in order, as read ("light 23:02–23:20, deep 23:20–00:05 less sure, …") — no totals computed here.
    private var spokenValue: String {
        stages.sorted { $0.start < $1.start }.map { s in
            "\(Self.rowName(s.stage)) \(MGFormat.timeRange(s.start, s.end, calendar: calendar))"
                + (Self.isUnsure(s.confidence) ? " less sure" : "")
        }.joined(separator: ", ")
    }
}

// MARK: - Lanes

/// One lane on the night's clock: marks with an end are spans, marks with a value are dots, the rest are ticks.
/// A lane with a blank reason and no marks shows the reason instead ("Not listening last night — switch on in Tonight").
struct NightLaneRow: View {
    let lane: NightLane
    let clock: NightClock?

    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(lane.title)
                .mgFont(.receipt)
                .foregroundStyle(colors.ink2.color)
                .frame(width: NightClock.labelColumn, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                if !lane.marks.isEmpty, let clock {
                    NightLaneStrip(marks: lane.marks, clock: clock, tone: Self.tone(for: lane.id))
                        .frame(height: 18)
                }
                if let reason = lane.blankReason {
                    Text(reason)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lane.title)
        .accessibilityValue(voiceOver || switchControl ? spoken : (lane.blankReason ?? ""))
    }

    /// Lanes are told apart by their row and title; the tint only repeats the meaning (breathing events = body,
    /// strap sleep flag = sleep, everything else neutral).
    static func tone(for id: String) -> InkTone {
        switch id {
        case "breathing": return .body
        case "strapFlag", "strap_flag", "strap": return .sleep
        default: return .ink2
        }
    }

    private var spoken: String {
        if lane.marks.isEmpty { return lane.blankReason ?? "nothing recorded" }
        let parts = lane.marks.prefix(12).map { m -> String in
            var s = m.end.map { MGFormat.timeRange(m.at, $0, calendar: calendar) } ?? MGFormat.time(m.at, calendar: calendar)
            // Raw values stay raw: no unit, no % sign (BRIEF "raw counts are not units").
            if let v = m.value, v.isFinite { s += " \(MGFormat.number(v, decimals: v.rounded() == v ? 0 : 1))" }
            if let l = m.label { s += " \(l)" }
            return s
        }
        let more = lane.marks.count > 12 ? ", and \(lane.marks.count - 12) more" : ""
        return "\(lane.marks.count) marks: " + parts.joined(separator: ", ") + more
            + (lane.blankReason.map { ". \($0)" } ?? "")
    }
}

/// The marks of one lane, on the shared clock.
struct NightLaneStrip: View {
    let marks: [LaneMark]
    let clock: NightClock
    let tone: InkTone

    @Environment(\.mgColors) private var colors

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, mid = size.height / 2
            let color = colors.mark(tone).color
            for m in marks {
                let x = clock.x(m.at, width: w)
                if let end = m.end, end > m.at {
                    let x1 = clock.x(end, width: w)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - 4, width: max(2, x1 - x), height: 8), cornerRadius: 2),
                             with: .color(color))
                } else if m.value != nil {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 2, y: mid - 2, width: 4, height: 4)), with: .color(color))
                } else {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: mid - 6))
                    p.addLine(to: CGPoint(x: x, y: mid + 6))
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Strap flag, phone and PC on one clock (Night 4)

/// The same night as the strap flag, the phone's stager and the PC's stager, one thin hypnogram per row, all on the
/// shared clock so a difference reads at a glance. A row with no night says why instead. The strap row is drawn in the
/// sleep colour (it only knows asleep / awake); the staged rows use the stage colours.
struct NightStageCompare: View {
    let rows: [StageCompareRow]
    let clock: NightClock

    @Environment(\.mgColors) private var colors

    static let stripHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.label).mgFont(.receipt).foregroundStyle(colors.ink2.color)
                        if let total = row.total {
                            Text(total).mgFont(.receipt).foregroundStyle(colors.mute.color)
                        }
                    }
                    .frame(width: NightClock.labelColumn, alignment: .leading)
                    if row.segments.isEmpty {
                        Text(row.blankReason ?? "No night stored.")
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Strip(segments: row.segments, clock: clock, isStrap: row.id == "strap")
                            .frame(height: Self.stripHeight)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.label) stages")
                .accessibilityValue(row.segments.isEmpty ? (row.blankReason ?? "none") : (row.total.map { "asleep \($0)" } ?? "drawn"))
            }
        }
        .frame(maxWidth: NightStageChart.maxWidth)
    }

    private struct Strip: View {
        let segments: [StageSegment]
        let clock: NightClock
        let isStrap: Bool

        @Environment(\.mgColors) private var colors

        var body: some View {
            Canvas { ctx, size in
                let rowH = size.height / CGFloat(NightStageChart.rows.count)
                ctx.fill(Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 1)), with: .color(colors.rule.color))
                for seg in segments where seg.end > seg.start {
                    guard let r = NightStageChart.row(of: seg.stage) else { continue }
                    let x0 = clock.x(seg.start, width: size.width)
                    let x1 = clock.x(seg.end, width: size.width)
                    // The strap flag has no stages: asleep sits on one row in the sleep colour, awake on the top row.
                    let row = isStrap ? (seg.stage == .awake ? 0 : 2) : r
                    let rect = CGRect(x: x0, y: CGFloat(row) * rowH + 1, width: max(1.5, x1 - x0), height: rowH - 2)
                    let fillColor = isStrap ? colors.mark(.sleep).color : color(seg.stage)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(fillColor))
                }
            }
            .accessibilityHidden(true)
        }

        private func color(_ stage: StageSegment.Stage) -> Color {
            switch stage {
            case .deep: return colors.stageDeep.color
            case .light, .unstaged: return colors.stageLight.color
            case .rem: return colors.stageRem.color
            case .awake: return colors.stageAwake.color
            }
        }
    }
}
