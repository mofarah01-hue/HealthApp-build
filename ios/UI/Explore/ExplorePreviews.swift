#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of the Explore screens (WP-19). Every value is SAMPLE (`sample: true`), so the SAMPLE banner shows
// on each one. Taps print their intent to the console. Cases: the tab (shelf, empty shelf, search with matches,
// search with none, Emerald), metric detail in Number / Graph / Trend and with blanks, the group screen with and without
// dropped methods, the matrix (4 metrics with a blank pair, and the full 8), the picker sheet, Compare (pick, blank
// under 14 days, lagged), and the largest text size.

private func exploreIntentLogger(_ screen: String) -> (UIIntent) -> Void {
    { intent in print("\(screen) intent:", intent) }
}

private func pushed<Content: View>(_ theme: ThemeName, @ViewBuilder _ content: () -> Content) -> some View {
    NavigationStack { content() }.mgTheme(theme)
}

/// P08 visual acceptance state: 7 d is selected, exactly one catalogue group is open, and that group contains
/// both a dotted research row and a comparison-group row. The shared preview data is synthetic.
private func exploreP08Preview(emptyShelf: Bool = false) -> ExploreState {
    var state = ExploreState.preview
    state.period = .days7
    if emptyShelf { state.shelf = [] }
    for index in state.catalogue.indices {
        state.catalogue[index].isOpen = index == state.catalogue.startIndex
    }
    if !state.catalogue.isEmpty, !state.catalogue[0].entries.isEmpty {
        state.catalogue[0].entries[0].isResearch = true
    }
    return state
}

// MARK: Explore tab

#Preview("Explore · Day · 7 d · 3-card shelf") {
    ExploreView(state: exploreP08Preview(), send: exploreIntentLogger("Explore")).mgTheme(.cream)
}

#Preview("Explore · Night · 7 d · 3-card shelf") {
    ExploreView(state: exploreP08Preview(), send: exploreIntentLogger("Explore")).mgTheme(.emerald)
}

#Preview("Explore · Day · 7 d · empty shelf") {
    ExploreView(state: exploreP08Preview(emptyShelf: true), send: exploreIntentLogger("Explore")).mgTheme(.cream)
}

#Preview("Explore · search “hr”") {
    var s = ExploreState.preview
    s.query = "hr"
    s.catalogue = s.catalogue.compactMap { section in
        let hits = section.entries.filter { $0.name.lowercased().contains("hr") || $0.key.contains("hr") }
        return hits.isEmpty ? nil : CatalogueSection(title: section.title, isOpen: false, entries: hits)
    }
    return ExploreView(state: s, send: exploreIntentLogger("Explore")).mgTheme(.cream)
}

#Preview("Explore · search with no match") {
    var s = ExploreState.preview
    s.query = "zzz"
    s.catalogue = []
    return ExploreView(state: s, send: exploreIntentLogger("Explore")).mgTheme(.cream)
}

#Preview("Explore · largest text") {
    ExploreView(state: .preview, send: exploreIntentLogger("Explore"))
        .mgTheme(.cream)
        .environment(\.dynamicTypeSize, .accessibility3)
}

// MARK: Metric detail

#Preview("Metric · Graph · cream") {
    pushed(.cream) { MetricDetailView(state: .preview, send: exploreIntentLogger("Metric")) }
}

#Preview("Metric · Number · cream") {
    var s = MetricDetailState.preview
    s.view = .number
    return pushed(.cream) { MetricDetailView(state: s, send: exploreIntentLogger("Metric")) }
}

#Preview("Metric · Trend · Emerald") {
    var s = MetricDetailState.preview
    s.view = .trend
    return pushed(.emerald) { MetricDetailView(state: s, send: exploreIntentLogger("Metric")) }
}

#Preview("Metric · with method dropdown") {
    var s = MetricDetailState.preview
    s.methods = .preview
    let explanation = PanelExplanation(
        id: "ALG-010", simple: "A nightly variability method.", technical: "RMSSD over clean intervals.",
        inputs: "Clean nightly intervals.", computation: "Summarises successive interval differences.",
        meaning: "Higher or lower relative to your own history.", unit: "ms", source: "Synthetic preview method.",
        blank: "No clean nightly interval is available."
    )
    var robustExplanation = explanation
    robustExplanation.id = "ALG-011"
    s.algorithmPanel = AlgorithmPanelState(
        sample: true, title: "HRV method", summary: "Choose the method used for this display.",
        selectedID: "ALG-010", options: [
            AlgorithmPanelOption(id: "ALG-010", label: "Nightly RMSSD", explanation: explanation, metrics: []),
            AlgorithmPanelOption(id: "ALG-011", label: "Robust RMSSD", explanation: robustExplanation, metrics: [])
        ]
    )
    return pushed(.cream) { MetricDetailView(state: s, send: exploreIntentLogger("Metric")) }
}

/// UX §13: no band yet, no value for the period, and a single day — every part says why instead of drawing.
#Preview("Metric · blanks · Today") {
    var s = MetricDetailState.preview
    s.period = .today
    s.number.median = .previewBlank
    s.number.iqr = nil
    s.number.versusPrevious = nil
    s.graph.bandLow = nil
    s.graph.bandHigh = nil
    s.graph.points = Array(s.graph.points.prefix(1))
    s.view = .graph
    return pushed(.cream) { MetricDetailView(state: s, send: exploreIntentLogger("Metric")) }
}

// MARK: Group

#Preview("Group · cream") {
    pushed(.cream) { GroupView(state: .preview, send: exploreIntentLogger("Group")) }
}

#Preview("Group · one dropped · shown") {
    var s = GroupState.preview
    if var last = s.members.popLast() {
        last.isDropped = true
        s.dropped = [last]
    }
    if var first = s.members.first {
        first.isKept = true
        s.members[0] = first
    }
    s.showDropped = true
    return pushed(.emerald) { GroupView(state: s, send: exploreIntentLogger("Group")) }
}

// MARK: Matrix

#Preview("Matrix · 4 metrics · one blank pair") {
    pushed(.cream) {
        MatrixView(state: .preview, choices: ExploreChoices.metrics(from: .preview),
                   send: exploreIntentLogger("Matrix"))
    }
}

#Preview("Matrix · Emerald") {
    pushed(.emerald) {
        MatrixView(state: .preview, choices: ExploreChoices.metrics(from: .preview),
                   send: exploreIntentLogger("Matrix"))
    }
}

/// The most the matrix takes: 8 metrics, SAMPLE ρ, a few pairs under 14 days.
#Preview("Matrix · 8 metrics") {
    let names = ["HRV", "Resting HR", "Total sleep", "Strain", "Caffeine", "Vape hits", "Breathing rate", "Steps"]
    let metrics = names.enumerated().map { MatrixMetric(key: "m\($0.offset)", name: $0.element) }
    let cells: [[MatrixCell]] = (0..<8).map { i in
        (0..<8).map { j in
            if i == j { return MatrixCell.make(rho: 1, n: 30, qValue: nil) }
            let k = Double(min(i, j) * 8 + max(i, j))
            let n = (i + j) % 5 == 0 ? 9 : 28
            return MatrixCell.make(rho: sin(k) * 0.7, n: n, qValue: 0.1)
        }
    }
    let state = MatrixState(sample: true, metrics: metrics, period: .days90, cells: cells)
    return pushed(.cream) {
        MatrixView(state: state, choices: ExploreChoices.metrics(from: .preview), send: exploreIntentLogger("Matrix"))
    }
}

#Preview("Matrix · fewer than 2 metrics") {
    let state = MatrixState(sample: true, metrics: [MatrixMetric(key: "hrv_rmssd", name: "HRV")], period: .days30,
                            cells: [[MatrixCell.make(rho: 1, n: 30, qValue: nil)]])
    return pushed(.cream) {
        MatrixView(state: state, choices: ExploreChoices.metrics(from: .preview), send: exploreIntentLogger("Matrix"))
    }
}

#Preview("Matrix picker sheet") {
    ExploreMatrixPicker(choices: ExploreChoices.metrics(from: .preview),
                        selected: ["hrv_rmssd", "sleep_total"],
                        onChange: { print("Matrix picker:", $0) }, done: {})
        .mgTheme(.cream)
}

// MARK: Compare

/// `CompareState.preview` puts the caffeine-sized numbers on x and labels x "mg" while `first` is HRV. The screen
/// reads x as the first metric and y as the second, so the previews swap the sample points and units to match.
private func comparePreview() -> CompareState {
    var s = CompareState.preview
    s.pairs = s.pairs.map { ComparePair(day: $0.day, x: $0.y, y: $0.x) }
    s.xUnit = "ms"
    s.yUnit = "mg"
    return s
}

#Preview("Compare · cream") {
    pushed(.cream) { CompareView(state: comparePreview(), send: exploreIntentLogger("Compare")) }
}

#Preview("Compare · Emerald · lag 1 d") {
    var s = comparePreview()
    s.lagDays = 1
    return pushed(.emerald) { CompareView(state: s, send: exploreIntentLogger("Compare")) }
}

/// Under 14 paired days: the cell is blank with its reason, and no scatter is drawn.
#Preview("Compare · too few days") {
    var s = comparePreview()
    s.pairs = Array(s.pairs.prefix(9))
    s.cell = MatrixCell.make(rho: 0.4, n: 9, qValue: 0.3)
    return pushed(.cream) { CompareView(state: s, send: exploreIntentLogger("Compare")) }
}

#Preview("Compare · nothing picked yet") {
    var s = comparePreview()
    s.second = nil
    s.pairs = []
    s.cell = nil
    return pushed(.cream) { CompareView(state: s, send: exploreIntentLogger("Compare")) }
}
#endif
