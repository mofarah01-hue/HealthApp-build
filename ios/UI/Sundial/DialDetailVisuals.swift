import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// One small chart per `DialDetailVisual` case, for the detail sheet's tiles (0.6, package P04). Fixed heights (ring 132,
/// week 96, curve 140, stages 120, HR 120) so Dynamic Type grows the sheet's text, not its charts. Every bar and line
/// carries a text label, so colour is never the only cue; the sheet gives each chart one VoiceOver sentence.
struct DialDetailVisualView: View {
    let visual: DialDetailVisual
    /// The ring's or tone's mark colour.
    let color: MGRGBA
    /// What the ring shows in its centre (the sheet title, "9.4 of 21").
    let centreText: String
    /// Eaten draws its ring dashed.
    let dashed: Bool

    init(visual: DialDetailVisual, color: MGRGBA, centreText: String, dashed: Bool) {
        self.visual = visual
        self.color = color
        self.centreText = centreText
        self.dashed = dashed
    }

    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        switch visual {
        case let .ring(fraction, target):
            ZStack {
                RingGauge(fraction: fraction, target: target, color: color.color, track: colors.ringTrack.color,
                          lineWidth: 12, dashed: dashed)
                Text(centreText)
                    .mgFont(.number)
                    .foregroundStyle(colors.ink.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .frame(width: 88)
            }
            .frame(width: 132, height: 132)
            .frame(maxWidth: .infinity)
        case let .week(points, max, unit):
            Canvas { ctx, size in week(&ctx, size, points, max: max, unit: unit) }
                .frame(height: 96)
        case let .curve(values, window, marks, unit):
            Canvas { ctx, size in curve(&ctx, size, values, window: window, marks: marks, unit: unit) }
                .frame(height: 140)
        case let .stages(segments):
            Canvas { ctx, size in stages(&ctx, size, segments) }
                .frame(height: 120)
        case let .hrAround(values, at, before, after):
            Canvas { ctx, size in hrAround(&ctx, size, values, at: at, before: before, after: after) }
                .frame(height: 120)
        }
    }

    // MARK: Week: 7 bars, today in full colour, the others at 45 %

    private func week(_ ctx: inout GraphicsContext, _ size: CGSize, _ points: [DayPoint], max: Double?, unit: String?) {
        guard !points.isEmpty else { return }
        let y0: CGFloat = 16, y1 = size.height - 16
        let top = Swift.max(max ?? 0, points.compactMap(\.value).filter(\.isFinite).max() ?? 0)
        let slot = size.width / CGFloat(points.count)
        let barWidth = min(18, slot * 0.5)
        func y(_ v: Double) -> CGFloat { top > 0 ? y1 - CGFloat(v / top) * (y1 - y0) : y1 }

        if let max, max > 0 {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(max)))
            line.addLine(to: CGPoint(x: size.width, y: y(max)))
            ctx.stroke(line, with: .color(colors.ink2.opacity(0.5).color), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            label(&ctx, "max " + Self.number(max), at: CGPoint(x: size.width, y: y(max) - 7), anchor: .trailing)
        }
        if let unit, !unit.isEmpty { label(&ctx, unit, at: CGPoint(x: 0, y: 6), anchor: .leading) }

        for (i, p) in points.enumerated() {
            let today = i == points.count - 1
            let x = slot * (CGFloat(i) + 0.5)
            if let v = p.value, v.isFinite, v >= 0 {
                let rect = CGRect(x: x - barWidth / 2, y: y(v), width: barWidth, height: Swift.max(1, y1 - y(v)))
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                         with: .color(color.opacity(today ? 1 : 0.45).color))
                label(&ctx, Self.number(v), at: CGPoint(x: x, y: rect.minY - 7), strong: today)
            } else {
                // No value that day: a short dotted stub, never a zero bar.
                var stub = Path()
                stub.move(to: CGPoint(x: x - barWidth / 2, y: y1 - 1))
                stub.addLine(to: CGPoint(x: x + barWidth / 2, y: y1 - 1))
                ctx.stroke(stub, with: .color(colors.mute.color),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.01, 3.5]))
            }
            label(&ctx, Self.weekdayInitial(p.day), at: CGPoint(x: x, y: size.height - 6), strong: today)
        }
    }

    // MARK: Curve: a line over 12-hour time labels, the window shaded, marks as thin ticks

    private func curve(_ ctx: inout GraphicsContext, _ size: CGSize, _ values: [TimedValue], window: DialSpan?,
                       marks: [Date], unit: String?) {
        let pts = values.filter { $0.value.isFinite }.sorted { $0.at < $1.at }
        let times = pts.map(\.at) + marks + [window?.start, window?.end].compactMap { $0 }
        guard let lo = times.min(), let hi = times.max(), hi > lo else { return }
        let scale = TimeScale(lo: lo, hi: hi, x0: 4, x1: size.width - 4)
        let y0: CGFloat = 18, y1 = size.height - 20
        let vmin = Swift.min(0, pts.map(\.value).min() ?? 0)
        let vmax = Swift.max(vmin + 1, (pts.map(\.value).max() ?? 1) * 1.1)
        func y(_ v: Double) -> CGFloat { y1 - CGFloat((v - vmin) / (vmax - vmin)) * (y1 - y0) }

        if let w = window, w.end > w.start {
            let rect = CGRect(x: scale.x(w.start), y: y0, width: scale.x(w.end) - scale.x(w.start), height: y1 - y0)
            ctx.fill(Path(rect), with: .color(color.opacity(0.12).color))
        }
        for m in marks {
            var tick = Path()
            tick.move(to: CGPoint(x: scale.x(m), y: y0))
            tick.addLine(to: CGPoint(x: scale.x(m), y: y1))
            ctx.stroke(tick, with: .color(colors.ink2.color), lineWidth: 1)
        }
        var base = Path()
        base.move(to: CGPoint(x: scale.x0, y: y1))
        base.addLine(to: CGPoint(x: scale.x1, y: y1))
        ctx.stroke(base, with: .color(colors.rule.color), lineWidth: 1)
        if pts.count >= 2 {
            var line = Path()
            line.addLines(pts.map { CGPoint(x: scale.x($0.at), y: y($0.value)) })
            ctx.stroke(line, with: .color(color.color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        if let peak = pts.max(by: { $0.value < $1.value }) {
            label(&ctx, Self.number(peak.value), at: CGPoint(x: scale.x(peak.at), y: y(peak.value) - 8))
        }
        if let unit, !unit.isEmpty { label(&ctx, unit, at: CGPoint(x: size.width, y: 6), anchor: .trailing) }
        axis(&ctx, scale, y: size.height - 7)
    }

    // MARK: Stages: a hypnogram, awake on top, deep at the bottom; unstaged is an outlined hatch, never light

    private func stages(_ ctx: inout GraphicsContext, _ size: CGSize, _ segments: [StageSegment]) {
        guard let lo = segments.map(\.start).min(), let hi = segments.map(\.end).max(), hi > lo else { return }
        let rows: [(StageSegment.Stage, String, MGRGBA)] = [(.awake, "Awake", colors.stageAwake),
                                                            (.rem, "REM", colors.stageRem),
                                                            (.light, "Light", colors.stageLight),
                                                            (.deep, "Deep", colors.stageDeep)]
        let scale = TimeScale(lo: lo, hi: hi, x0: 46, x1: size.width - 4)
        let rowHeight = (size.height - 20) / 4
        for (i, row) in rows.enumerated() {
            label(&ctx, row.1, at: CGPoint(x: 0, y: rowHeight * (CGFloat(i) + 0.5)), anchor: .leading)
        }
        for s in segments where s.end > s.start {
            let x = scale.x(s.start), w = Swift.max(1, scale.x(s.end) - x)
            if s.stage == .unstaged {
                // Asleep, stage unknown: across the three sleep rows, outlined and hatched, never filled.
                let rect = CGRect(x: x, y: rowHeight + 3, width: w, height: rowHeight * 3 - 6)
                let shape = Path(roundedRect: rect, cornerRadius: 2)
                ctx.drawLayer { layer in
                    layer.clip(to: shape)
                    var hatch = Path()
                    var hx = rect.minX - rect.height
                    while hx < rect.maxX {
                        hatch.move(to: CGPoint(x: hx, y: rect.maxY))
                        hatch.addLine(to: CGPoint(x: hx + rect.height, y: rect.minY))
                        hx += 5
                    }
                    layer.stroke(hatch, with: .color(colors.stageLight.opacity(0.6).color), lineWidth: 1)
                }
                ctx.stroke(shape, with: .color(colors.stageLight.color), lineWidth: 1)
                continue
            }
            guard let row = rows.firstIndex(where: { $0.0 == s.stage }) else { continue }
            let rect = CGRect(x: x, y: rowHeight * CGFloat(row) + 3, width: w, height: rowHeight - 6)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(rows[row].2.color))
        }
        axis(&ctx, scale, y: size.height - 7)
    }

    // MARK: HR around an event: the HR line, a rule at the event, the before / after means as labelled dashes

    private func hrAround(_ ctx: inout GraphicsContext, _ size: CGSize, _ values: [TimedValue], at: Date,
                          before: Double?, after: Double?) {
        let pts = values.filter { $0.value.isFinite }.sorted { $0.at < $1.at }
        let lo = Swift.min(pts.first?.at ?? at, at.addingTimeInterval(-600))
        let hi = Swift.max(pts.last?.at ?? at, at.addingTimeInterval(600))
        let scale = TimeScale(lo: lo, hi: hi, x0: 4, x1: size.width - 4)
        let all = pts.map(\.value) + [before, after].compactMap { $0 }
        let vmin = (all.min() ?? 60) - 5, vmax = Swift.max((all.max() ?? 100) + 5, vmin + 10)
        let y0: CGFloat = 20, y1 = size.height - 20
        func y(_ v: Double) -> CGFloat { y1 - CGFloat((v - vmin) / (vmax - vmin)) * (y1 - y0) }

        label(&ctx, "bpm · estimate", at: CGPoint(x: 0, y: 6), anchor: .leading)
        if pts.count >= 2 {
            var line = Path()
            line.addLines(pts.map { CGPoint(x: scale.x($0.at), y: y($0.value)) })
            ctx.stroke(line, with: .color(color.color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        let ax = scale.x(at)
        var rule = Path()
        rule.move(to: CGPoint(x: ax, y: y0 - 4))
        rule.addLine(to: CGPoint(x: ax, y: y1))
        ctx.stroke(rule, with: .color(colors.ink.color), lineWidth: 1)
        for (mean, word, from, to) in [(before, "before", scale.x0, ax), (after, "after", ax, scale.x1)] {
            guard let mean else { continue }
            var dash = Path()
            dash.move(to: CGPoint(x: from + 2, y: y(mean)))
            dash.addLine(to: CGPoint(x: to - 2, y: y(mean)))
            ctx.stroke(dash, with: .color(colors.ink2.color), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            let left = word == "before"
            label(&ctx, "\(word) \(Self.number(mean))", at: CGPoint(x: left ? from + 2 : to - 2, y: y(mean) - 8),
                  anchor: left ? .leading : .trailing)
        }
        label(&ctx, MGFormat.time(at, calendar: calendar), at: CGPoint(x: ax, y: size.height - 7), strong: true)
    }

    // MARK: Parts

    /// Whole-hour labels ("9 AM", "12 PM") along the bottom, every 1, 2, 3 or 6 hours so they never crowd.
    private func axis(_ ctx: inout GraphicsContext, _ scale: TimeScale, y: CGFloat) {
        for t in scale.hours(calendar: calendar) {
            let text = MGFormat.time(t, calendar: calendar).replacingOccurrences(of: ":00", with: "")
            let x = Swift.min(Swift.max(scale.x(t), scale.x0 + 16), scale.x1 - 16)
            label(&ctx, text, at: CGPoint(x: x, y: y))
        }
    }

    private func label(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint, anchor: UnitPoint = .center,
                       strong: Bool = false) {
        let style = MGTextStyle.label
        ctx.draw(Text(text)
                    .font(style.font(size: 11).weight(strong ? .semibold : .regular))
                    .foregroundColor((strong ? colors.ink : colors.ink2).color),
                 at: p, anchor: anchor)
    }

    static func number(_ v: Double) -> String { MGFormat.number(v, decimals: abs(v) < 10 ? 1 : 0) }

    static func weekdayInitial(_ day: LocalDay) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let d = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return "" }
        return ["S", "M", "T", "W", "T", "F", "S"][(cal.component(.weekday, from: d) + 6) % 7]
    }
}

/// Maps times onto a chart's x range.
private struct TimeScale {
    let lo: Date
    let hi: Date
    let x0: CGFloat
    let x1: CGFloat

    func x(_ d: Date) -> CGFloat {
        let span = hi.timeIntervalSince(lo)
        guard span > 0 else { return x0 }
        return x0 + CGFloat(d.timeIntervalSince(lo) / span) * (x1 - x0)
    }

    func hours(calendar: Calendar) -> [Date] {
        let span = hi.timeIntervalSince(lo) / 3600
        let step = span <= 4 ? 1 : span <= 9 ? 2 : span <= 15 ? 3 : 6
        guard let start = calendar.dateInterval(of: .hour, for: lo)?.start else { return [] }
        var out: [Date] = []
        for k in 0...25 {
            guard let t = calendar.date(byAdding: .hour, value: k, to: start), t <= hi else { break }
            if t >= lo, calendar.component(.hour, from: t) % step == 0 { out.append(t) }
        }
        return out
    }
}
