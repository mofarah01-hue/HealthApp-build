import SwiftUI
import MGContext
import MGDesign

// Sleep expanded (Mo, Nov 5 2026), spec §B 1-10: the full breakdown the dashboard card opens into. It is the top of the Night page
// (NightView), not a second screen. Pure rendering of `SleepBreakdownState`: every figure, label and grey reason is written by
// `SleepBreakdownPresenter`; this view adds no number, no unit and no source choice.

struct SleepBreakdownView: View {
    let state: SleepBreakdownState

    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Summary and source rows
            SleepGroupView(group: state.summary)
            SleepGroupView(group: state.sourceRows)
            // 2. One sentence
            SectionHeader("In one sentence")
            Text(state.interpretation)
                .mgFont(.body)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            // 3. Opportunity and continuity
            if let equation = state.equation {
                SectionHeader("Sleep opportunity")
                Text(equation)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, MGSpace.s)
            }
            SleepGroupView(group: state.continuity, showsTitle: state.equation == nil)
            // 4. Night explorer, then the stage rows
            SleepExplorerView(explorer: state.explorer)
            SleepGroupView(group: state.stages)
            // 5. Overnight physiology
            SectionHeader("Overnight physiology")
            ForEach(state.physiology) { SleepGroupView(group: $0, compactHeader: true) }
            // 6. Score (skipped when no score exists)
            if let score = state.score { SleepGroupView(group: score) }
            // 7. Need, debt, consistency
            SleepGroupView(group: state.need)
            // 8. Naps
            naps
            // 9. Trends
            trends
            // 10. Source / algorithm / version
            SectionHeader("Source and version")
            Text(state.versionLine)
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 8. Naps

    @ViewBuilder
    private var naps: some View {
        SectionHeader("Naps")
        if state.naps.isEmpty {
            Text(state.napsNote ?? "No naps.").mgFont(.detail).foregroundStyle(colors.ink2.color)
        } else {
            VStack(alignment: .leading, spacing: MGSpace.s) {
                ForEach(state.naps) { nap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(nap.range) · \(nap.duration)").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                        Text(nap.caption).mgFont(.receipt).foregroundStyle(colors.mute.color)
                        Text(nap.effect).mgFont(.detail).foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(MGSpace.tileInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mgSurface(.card, radius: MGRadius.chip)
                }
            }
        }
    }

    // MARK: 9. Trends

    private var trends: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Trends", note: "median · 7 / 30 / 90 nights")
            ForEach(state.trends) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).mgFont(.label).foregroundStyle(colors.ink2.color)
                    HStack(spacing: MGSpace.s) {
                        trendCell("7", row.d7)
                        trendCell("30", row.d30)
                        trendCell("90", row.d90)
                    }
                    if let note = row.note {
                        Text(note).mgFont(.receipt).foregroundStyle(colors.mute.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, MGSpace.s)
                .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func trendCell(_ days: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(days) d").mgFont(.receipt).foregroundStyle(colors.mute.color)
            Text(text ?? "—").mgFont(.rowTitle).foregroundStyle(text == nil ? colors.mute.color : colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A heading and a two-column grid of `SleepCellView`s on card surfaces, with the group's one-line note under it.
struct SleepGroupView: View {
    let group: SleepGroup
    var showsTitle = true
    var compactHeader = false

    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                if compactHeader {
                    Text(group.title).mgFont(.headline).foregroundStyle(colors.ink.color)
                        .padding(.top, MGSpace.m).padding(.bottom, MGSpace.xs)
                } else {
                    SectionHeader(group.title)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .topLeading),
                                GridItem(.flexible(), spacing: 10, alignment: .topLeading)],
                      alignment: .leading, spacing: 10) {
                ForEach(group.cells) { cell in
                    SleepCellView(cell: cell)
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: MGSpace.rowMinHeight, alignment: .topLeading)
                        .mgSurface(.card, radius: MGRadius.chip)
                }
            }
            if let note = group.note {
                Text(note).mgFont(.receipt).foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, MGSpace.xs)
            }
        }
    }
}

/// §B4: the headline's hypnogram with the aligned tracks under it on one clock. A toggle draws the Apple Watch's own stages as a
/// second strip beside the headline's; they are never merged.
struct SleepExplorerView: View {
    let explorer: SleepExplorerState

    @State private var showWatch = false
    @Environment(\.mgColors) private var colors

    var body: some View {
        let clock = explorer.window.map { NightClock(window: $0) }
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Night explorer", note: explorer.hypnogramSource.isEmpty ? nil : explorer.hypnogramSource)
            if let clock, !explorer.hypnogram.isEmpty {
                NightStageChart(stages: explorer.hypnogram, clock: clock)
            } else {
                Text(explorer.hypnogramNote ?? "No stages for this night.")
                    .mgFont(.detail).foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if explorer.watchOverlay != nil {
                Toggle("Show Apple Watch stages beside these", isOn: $showWatch)
                    .mgFont(.detail)
                    .padding(.top, MGSpace.s)
                if showWatch, let clock, let overlay = explorer.watchOverlay {
                    NightStageChart(stages: overlay, clock: clock)
                    Text("Apple Watch's own staging, drawn beside the headline's and never merged with it.")
                        .mgFont(.receipt).foregroundStyle(colors.mute.color)
                }
            } else if let why = explorer.watchOverlayReason {
                Text(why).mgFont(.receipt).foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, MGSpace.xs)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(explorer.tracks) { track in SleepTrackRow(track: track, clock: clock) }
            }
            .padding(.top, MGSpace.s)
        }
    }
}

/// One track under the hypnogram: its title and caption on the left, a polyline on the shared clock, or the grey reason.
struct SleepTrackRow: View {
    let track: SleepTrack
    let clock: NightClock?

    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).mgFont(.receipt).foregroundStyle(colors.ink2.color)
                if !track.unit.isEmpty { Text(track.unit).mgFont(.receipt).foregroundStyle(colors.mute.color) }
            }
            .frame(width: NightClock.labelColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let clock, !track.points.isEmpty {
                    SleepTrackLine(points: track.points, clock: clock).frame(height: 44)
                    if let caption = track.caption {
                        Text(caption).mgFont(.receipt).foregroundStyle(colors.mute.color)
                    }
                } else {
                    Text(track.reason ?? "No data.").mgFont(.detail).foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(track.title)
        .accessibilityValue(summary)
    }

    private var summary: String {
        let v = track.points.compactMap(\.value)
        guard let lo = v.min(), let hi = v.max() else { return track.reason ?? "no data" }
        return "from \(MGFormat.number(lo, decimals: 1)) to \(MGFormat.number(hi, decimals: 1)) \(track.unit)"
    }
}

/// A thin polyline of one track on the night clock, scaled to its own min and max.
struct SleepTrackLine: View {
    let points: [LaneMark]
    let clock: NightClock

    @Environment(\.mgColors) private var colors

    var body: some View {
        Canvas { ctx, size in
            let pts = points.compactMap { m -> (Date, Double)? in m.value.map { (m.at, $0) } }
            guard let lo = pts.map(\.1).min(), let hi = pts.map(\.1).max() else { return }
            let span = hi - lo == 0 ? 1 : hi - lo
            var path = Path()
            var started = false
            var last: Date?
            for (t, v) in pts {
                let p = CGPoint(x: clock.x(t, width: size.width), y: size.height - 3 - CGFloat((v - lo) / span) * (size.height - 6))
                // A gap longer than 15 minutes breaks the line: missing data is a gap, not a straight line across it.
                if started, let l = last, t.timeIntervalSince(l) <= 15 * 60 { path.addLine(to: p) } else { path.move(to: p) }
                started = true
                last = t
            }
            ctx.stroke(path, with: .color(colors.mark(.ink2).color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
