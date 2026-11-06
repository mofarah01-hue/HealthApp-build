import SwiftUI
import MGContext
import MGDesign

// 0.6.0.12 (Mo, Nov 5 2026) — the card that opens when the RMSSD tile or the autonomic-load tile is tapped: what the number is in
// plain words, how often it really changes, today's 5-minute windows (clean ones solid, the others faded), the 7-night lnRMSSD
// mean against your normal band, and what a change that matters looks like. Pure rendering of `HRVExplainerState`.
//
// WRITTEN, NOT COMPILED here (the app target is built with xtool).

struct HRVExplainerSheet: View {
    let state: HRVExplainerState
    @Environment(\.mgColors) private var colors
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(state.title)
                        .mgFont(.headline)
                        .foregroundStyle(colors.ink.color)
                    Spacer(minLength: 8)
                    MGButton("Done", style: .ghost, action: { dismiss() })
                }
                .padding(.top, 20)
                block("What it is", state.what)
                block("How often it really changes", state.howOften)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today, 5-minute windows").mgFont(.kicker).foregroundStyle(colors.mute.color)
                    HRVWindowsChart(points: state.points, bandMs: state.bandMs)
                        .frame(height: 120)
                    Text(state.chartNote)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your last 7 nights").mgFont(.kicker).foregroundStyle(colors.mute.color)
                    Text(state.weekLine).mgFont(.body).foregroundStyle(colors.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(state.bandLine).mgFont(.body).foregroundStyle(colors.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                block("What a change that matters looks like", state.changeLine)
                Text(state.footnote)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 32)
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).mgFont(.kicker).foregroundStyle(colors.mute.color)
            Text(text)
                .mgFont(.body)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Today's finished 5-minute RMSSD windows as dots over the clock: solid when the window met every rule, faded when it did
/// not (a window with no number sits on the axis). A thin band marks your normal range when it is known (the 7-night band,
/// in the same ms, so a day's windows can be read against it).
struct HRVWindowsChart: View {
    let points: [HRVExplainerState.Point]
    let bandMs: [Double]?
    @Environment(\.mgColors) private var colors

    var body: some View {
        GeometryReader { geo in
            let values = points.compactMap(\.rmssd) + (bandMs ?? [])
            let top = max(values.max() ?? 1, 1) * 1.15
            let height = geo.size.height
            let width = geo.size.width
            let t0 = (points.first?.end.addingTimeInterval(-300) ?? Date()).timeIntervalSince1970
            let t1 = (points.last?.end ?? Date()).timeIntervalSince1970
            let span = max(t1 - t0, 600)
            ZStack(alignment: .topLeading) {
                if let band = bandMs, band.count == 2 {
                    let yHigh = height - band[1] / top * height
                    let yLow = height - band[0] / top * height
                    Rectangle()
                        .fill(colors.rule.color.opacity(0.5))
                        .frame(width: width, height: max(2, yLow - yHigh))
                        .offset(y: yHigh)
                }
                Rectangle().fill(colors.rule.color).frame(width: width, height: 1).offset(y: height - 1)
                ForEach(points) { p in
                    let x = (p.end.addingTimeInterval(-150).timeIntervalSince1970 - t0) / span * width
                    let y = height - (p.rmssd ?? 0) / top * height
                    Circle()
                        .fill(p.clean ? colors.ink.color : colors.mute.color.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .position(x: min(max(x, 4), width - 4), y: min(max(y, 4), height - 4))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let clean = points.filter(\.clean).count
        return "Today's 5-minute RMSSD windows: \(points.count), \(clean) clean, the rest not used in the average."
    }
}
