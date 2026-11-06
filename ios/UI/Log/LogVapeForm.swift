import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Vape, opened in place (UX §7): today's ticks on a 24 h strip and one-tap logging at the current time.
/// The presenter's own lines (time to first hit after waking + the cut-down target, 7-day median) and the strap
/// double-tap switch come in `row.expansion` and are drawn above by `LogExpansionBlock`.
/// Session start / stop (APP-071) is NOT built: the contract has only `session_id`, and sessions are derived from gaps.
struct LogVapeForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.calendar) private var calendar

    private var hitEntries: [SpineEntry] { ctx.spine.filter { $0.mark == .vapeStroke } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("Today's hits")
            LogHitStrip(entries: hitEntries)
            LogHint("One tap logs one vape tick at the current time.")
            LogSaveBar(title: "Log 1 hit now",
                       enabled: ctx.canLog, reason: ctx.canLog ? nil : LogIntents.sampleReason, action: save)
        }
    }

    private func save() {
        let now = Date()
        ctx.commit([LogEvents.vapeTick(at: now, loggedAt: now)],
                   message: "Vape hit \(LogText.time(now, calendar))")
    }
}

/// The day on one line, 00 → 24, one stroke per hit. Confirmed hits are solid strokes; detected-but-unconfirmed ones
/// are dashed (shape, not only colour). Reads out as one sentence for VoiceOver.
struct LogHitStrip: View {
    let entries: [SpineEntry]

    init(entries: [SpineEntry]) {
        self.entries = entries
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { gc, size in
                let midY = size.height / 2
                var base = Path()
                base.move(to: CGPoint(x: 0, y: midY))
                base.addLine(to: CGPoint(x: size.width, y: midY))
                gc.stroke(base, with: .color(colors.rule.color), lineWidth: 1)
                for quarter in 0...4 {
                    let x = size.width * CGFloat(quarter) / 4
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: midY - 3))
                    tick.addLine(to: CGPoint(x: x, y: midY + 3))
                    gc.stroke(tick, with: .color(colors.mute.color), lineWidth: 1)
                }
                for entry in entries {
                    let c = calendar.dateComponents([.hour, .minute], from: entry.at)
                    let minutes = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
                    let x = size.width * CGFloat(minutes / 1440)
                    var stroke = Path()
                    stroke.move(to: CGPoint(x: x, y: 4))
                    stroke.addLine(to: CGPoint(x: x, y: size.height - 4))
                    let style = StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: entry.unconfirmed ? [2, 3] : [])
                    gc.stroke(stroke, with: .color(colors.mark(.body).color), style: style)
                }
            }
            .frame(height: 28)
            HStack(spacing: 0) {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { label in
                    Text(label).mgFont(.receipt).foregroundStyle(colors.mute.color)
                    if label != "24" { Spacer(minLength: 0) }
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        if entries.isEmpty { return "No vape hits today." }
        let last = entries.map { $0.at }.max() ?? entries[0].at
        let unconfirmed = entries.filter { $0.unconfirmed }.count
        var text = "\(entries.count) vape \(entries.count == 1 ? "hit" : "hits") today, last at \(LogText.time(last, calendar))."
        if unconfirmed > 0 { text += " \(unconfirmed) detected, not confirmed." }
        return text
    }
}
