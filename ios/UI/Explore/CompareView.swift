import SwiftUI
import Charts
import MGContext
import MGDomain
import MGDesign

// "Compare with…" (UX-SPEC §9 step 4, APP-104): one metric against a second — scatter, Spearman ρ, days paired,
// optional lag of 0–2 days. Reached from a metric (`.openCompare`) or from a matrix cell (`.openMatrixCell`).
// ρ, n and the BH q-value come in `CompareState.cell` (WP-09 functions through the presenter, built with
// `MatrixCell.make`, which already blanks a pair under 14 days); this view never computes them. x is the first
// metric, y the second. Owner: WP-19. The state and the two intents were added to MGContext for this screen
// (main's OK, 2026-10-11).

struct CompareView: View {
    @Environment(\.mgColors) private var colors
    private let state: CompareState
    private let send: (UIIntent) -> Void

    init(state: CompareState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    private var title: String {
        "\(state.first.name) × \(state.second?.name ?? "…")"
    }

    private var lag: Int {
        min(max(state.lagDays, 0), CompareState.maxLagDays)
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                ExplorePushHeader(kicker: "Compare", title: title)

                ExplorePeriodPicker(selected: state.period, send: send)
                    .padding(.top, 14)

                SectionHeader("Compare \(state.first.name) with…")
                candidateChips

                SectionHeader("Lag", note: "0–\(CompareState.maxLagDays) days")
                ExploreSegmentedChips(items: Array(0...CompareState.maxLagDays), selected: lag,
                                      accessibilityName: "Lag in days",
                                      title: { $0 == 0 ? "No lag" : "\($0) d" },
                                      onSelect: { send(.setCompareLag(days: $0)) })
                Text("No lag compares the same day. With 1 or 2 days, the second metric is taken that many days after the first.")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                result
                    .padding(.top, MGSpace.section - 8)
            }
            .padding(.bottom, 40)
        }
        .exploreSampleBanner(state.sample)
        .environment(\.mgSend, send)
    }

    // MARK: Second metric

    @ViewBuilder private var candidateChips: some View {
        let options = state.candidates.filter { $0.key != state.first.key }
        if options.isEmpty {
            ExploreBlankNote("There is no other metric to compare with yet.")
        } else {
            // R9f (E7): a filter box and a short list, not a chip for every metric in the catalogue.
            ExploreMetricPickList(options: options, selectedKey: state.second?.key) { key in
                send(.setCompareWith(key: key))
            }
        }
    }

    // MARK: Scatter + ρ

    @ViewBuilder private var result: some View {
        if let second = state.second {
            if let cell = state.cell, let rho = cell.rho {
                VStack(alignment: .leading, spacing: 0) {
                    scatter(second: second, rho: rho, n: cell.n)
                    VStack(spacing: 0) {
                        ExploreInfoRow(label: "Spearman ρ", value: ExploreText.rho(rho))
                        ExploreInfoRow(label: "Days paired", value: "\(cell.n)")
                        if let q = cell.qValue {
                            ExploreInfoRow(label: "Benjamini–Hochberg q", value: MGFormat.number(q, decimals: 3))
                        }
                    }
                    .padding(.top, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
                    }
                    Text("Correlation, not cause. ρ is a rank correlation across days; it says the two move together or apart, nothing about why.")
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            } else {
                // Under 14 paired days (or no variation): blank with the reason, and no scatter (UX §13).
                ExploreBlankNote(state.cell?.blankReason ?? "No ρ for \(state.first.name) and \(second.name) yet.")
            }
        } else {
            ExploreBlankNote("Pick a second metric to compare with \(state.first.name).")
        }
    }

    @ViewBuilder private func scatter(second: MatrixMetric, rho: Double, n: Int) -> some View {
        let points = drawablePairs
        let xTitle = axisTitle(state.first.name, unit: state.xUnit)
        let yTitle = axisTitle(second.name, unit: state.yUnit)
        if points.isEmpty {
            ExploreBlankNote("No paired days to draw.")
        } else {
            Chart {
                ForEach(points, id: \.day) { p in
                    PointMark(x: .value(state.first.name, p.x), y: .value(second.name, p.y))
                        .symbolSize(40)
                        .foregroundStyle(colors.sleep.color.opacity(0.8))
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(colors.rule.color)
                    AxisValueLabel().foregroundStyle(colors.mute.color)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(colors.rule.color)
                    AxisValueLabel().foregroundStyle(colors.mute.color)
                }
            }
            .chartXAxisLabel(position: .bottom, alignment: .trailing) {
                Text(xTitle + " →").mgFont(.receipt).foregroundStyle(colors.ink2.color)
            }
            .chartYAxisLabel(position: .leading, alignment: .top) {
                Text(yTitle).mgFont(.receipt).foregroundStyle(colors.ink2.color)
            }
            .frame(minHeight: 220)
            .accessibilityLabel("Scatter of \(state.first.name) against \(second.name), \(points.count) paired days, "
                                + "Spearman rho \(ExploreText.rho(rho)), \(n) days")
        }
    }

    /// One point per day, finite values only, in day order (a chart must not choke on a repeated day).
    private var drawablePairs: [ComparePair] {
        var byDay: [String: ComparePair] = [:]
        for p in state.pairs where p.x.isFinite && p.y.isFinite { byDay[p.day.iso] = p }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private func axisTitle(_ name: String, unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return name }
        return "\(name) (\(unit))"
    }
}
