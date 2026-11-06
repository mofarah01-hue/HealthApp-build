import SwiftUI
import MGContext
import MGDomain
import MGDesign

// Metric detail (UX-SPEC §9 "MetricDetail", pushed from Explore and from any number on Today).
// Scroll order: title + receipt · period · Number | Graph | Trend · MethodsStrip for the metric's group ·
// "Compare with…" · About. Pure rendering of `MetricDetailState`: the median, IQR, coverage, normal band
// (median ± 1.4826·MAD over 28 d, ALG-075), EWMA and CUSUM marks are all computed upstream and arrive in state.
// The view toggle and the period are state too (`.setMetricView`, `.setPeriod`). Owner: WP-19.

struct MetricDetailView: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    private let state: MetricDetailState
    private let send: (UIIntent) -> Void

    init(state: MetricDetailState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                ExplorePushHeader(kicker: "Metric", title: state.title, receipt: state.receipt)

                ExplorePeriodPicker(selected: state.period, send: send)
                    .padding(.top, 14)
                if let note = state.pcHistory {             // tracker #7: older years from the PC
                    PCHistoryNoteView(note, shown: state.pcHistoryShown)
                }

                ExploreSegmentedChips(items: MetricViewMode.allCases, selected: state.view,
                                      accessibilityName: "View", title: { $0.title },
                                      onSelect: { send(.setMetricView($0)) })
                    .padding(.top, 8)

                content
                    .padding(.top, 16)

                if let panel = state.algorithmPanel {        // T99 Strain, T133 Recovery: tap for how each method works
                    AlgorithmPanel(state: panel) {
                        send(.selectMethod(groupId: state.methods?.groupId ?? "G-LOAD", variant: $0))
                    }
                        .padding(.top, MGSpace.section)
                }

                // Wave 4: plain lines under the numbers (SpO₂: checked against WHOOP?, no reading on demand).
                if let title = state.infoTitle {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(title)
                        ForEach(Array(state.infoLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .mgFont(.detail)
                                .foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let action = state.infoAction {
                            if action.enabled, let intent = action.intent {
                                MGButton(action.title, style: .ghost) { send(intent) }
                            } else {
                                Text(action.disabledReason ?? action.title)
                                    .mgFont(.receipt)
                                    .foregroundStyle(colors.mute.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, MGSpace.section)
                }

                // T56: WHOOP's workout average HR, one line per activity (never mixed), blank with a reason under 3 workouts.
                ForEach(state.workoutTrends) { t in
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(t.title)
                        if !t.points.isEmpty {
                            SparklineView(values: t.points.compactMap(\.value), accent: .ink2, width: nil, height: 56, lineWidth: 2)
                        }
                        Text(t.summary)
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, MGSpace.section)
                }

                if let methods = state.methods {
                    MethodsStrip(state: methods, send: send)
                        .padding(.top, 14)
                }

                // Wave 2 (Mo: "I should be able to see all outputs on screen"): every source's newest value.
                MetricSourcesBlock(sources: state.sources)
                    .padding(.top, MGSpace.section)

                SectionHeader("Compare with…", note: "scatter + Spearman ρ")
                ExploreNavRow(title: "Pick a second metric",
                              detail: "Scatter of the two, Spearman ρ, days paired, optional lag of 0–2 days.") {
                    send(.openCompare(key: state.key))
                }

                aboutBlock
            }
            .padding(.bottom, 40)
        }
        .exploreSampleBanner(state.sample)
        .environment(\.mgSend, send)
    }

    // MARK: Number · Graph · Trend

    @ViewBuilder private var content: some View {
        switch state.view {
        case .number: numberBlock
        case .graph: graphBlock
        case .trend: trendBlock
        }
    }

    private var numberBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.period == .today ? "Today" : "Median · \(ExploreText.periodLong(state.period))")
                .mgFont(.kicker)
                .foregroundStyle(colors.ink2.color)
            ValueView(state.number.median, size: .big, showsReceipt: true)
                .padding(.top, 4)
            VStack(spacing: 0) {
                if let iqr = state.number.iqr {
                    ExploreInfoRow(label: "Middle half (IQR)", value: iqr)
                }
                // T9913: this row is days, not data quality (the quality share has its own row below).
                ExploreInfoRow(label: "Days with a value", value: state.number.coverage)
                if let clean = state.number.cleanShare {
                    ExploreInfoRow(label: "Clean data", value: clean)
                }
                // T9894 (e-5): nothing in this period, so the newest earlier value with its date and the 7-day median.
                if let last = state.number.lastSeen {
                    ExploreInfoRow(label: "Latest value", value: last)
                }
                if let week = state.number.medianSevenDay {
                    ExploreInfoRow(label: "7-day median", value: week)
                }
                if let previous = state.number.versusPrevious {
                    ExploreInfoRow(label: "Against the period before", value: previous)
                }
                // T9896 (e-6): the same value against your own usual range.
                if let normal = state.number.versusNormal {
                    ExploreInfoRow(label: "Against your normal", value: normal)
                }
            }
            .padding(.top, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
            }
            if let note = state.number.compareNote {
                Text(note)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var graphBlock: some View {
        let points = ExploreChartData.points(state.graph.points, calendar: calendar)
        let band = ExploreChartData.band(low: state.graph.bandLow, high: state.graph.bandHigh)
        if ExploreChartData.knownCount(points) >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                BandedDotChart(points: points, band: band,
                               markers: ExploreChartData.markers(state.graph.markers, calendar: calendar),
                               unit: state.graph.unit ?? "",
                               format: ExploreChartData.formatter(for: points))
                Text(graphCaption(hasBand: band != nil))
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                markerList
            }
        } else {
            ExploreBlankNote(notEnoughDays)
        }
    }

    @ViewBuilder private var trendBlock: some View {
        let points = ExploreChartData.points(state.graph.points, calendar: calendar)
        let ewma = ExploreChartData.points(state.trend.ewma, calendar: calendar)
        if ExploreChartData.knownCount(points) >= 2 || ExploreChartData.knownCount(ewma) >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                TrendLineChart(points: points, ewma: ewma,
                               changeMarks: ExploreChartData.dates(state.trend.changeDays, calendar: calendar),
                               unit: state.graph.unit ?? "")
                Text("Line: smoothed trend (EWMA). Dashed marks: change points (CUSUM), ALG-075. Grey dots are the days.")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                if state.trend.changeDays.isEmpty {
                    Text("No change point flagged in this period.")
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                } else {
                    Text("Change points: " + state.trend.changeDays.sorted().map { dayText($0) }.joined(separator: ", "))
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            ExploreBlankNote(notEnoughDays)
        }
    }

    private func graphCaption(hasBand: Bool) -> String {
        let days = "Dots are days; gaps are days without data."
        if hasBand {
            return "Shaded: your normal band, median ± 1.4826·MAD over 28 days (ALG-075). \(days) Touch the chart to read a day."
        }
        return "No normal band for this metric yet. \(days) Touch the chart to read a day."
    }

    private var notEnoughDays: String {
        state.period == .today
            ? "One day can't be drawn. Pick 7 d or longer for the graph and trend."
            : "Fewer than two days with a value in this period, so there is nothing to draw."
    }

    /// The flags on the x-axis, spelled out (the chart only shows ⚑ for a device change and ◆ for a Health-vault entry).
    @ViewBuilder private var markerList: some View {
        if !state.graph.markers.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(state.graph.markers.sorted { $0.day < $1.day }.enumerated()), id: \.offset) { _, marker in
                    Text("\(marker.kind == .healthVault ? "◆" : "⚑") \(dayText(marker.day)) · \(marker.label)")
                        .mgFont(.receipt)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func dayText(_ day: LocalDay) -> String {
        MGFormat.shortDate(day.start(in: calendar.timeZone), calendar: calendar)
    }

    // MARK: About

    private var aboutBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("About", note: state.about.algorithmId)
            Text(state.about.method)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            if let note = state.about.latestNote, !note.isEmpty {
                Text(note)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(aboutLine)
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// r8h E13: the one-line legend for the tier word (no METRICS grade here: that stays in the docs).
    private static func tierMeaning(_ tier: Tier) -> String {
        switch tier {
        case .verified: return "checked against a reference"
        case .strap: return "read straight from the strap"
        case .high: return "a well-established method"
        case .estimate: return "an estimate, treat as approximate"
        case .relative: return "only meaningful against your own baseline"
        case .research: return "experimental, not validated"
        }
    }

    private var aboutLine: String {
        var parts = ["tier \(state.about.tier.rawValue): \(Self.tierMeaning(state.about.tier))"]
        if let id = state.about.algorithmId { parts.append(id) }
        if let citation = state.about.citation { parts.append("source: \(citation)") }
        return parts.joined(separator: " · ")
    }
}
