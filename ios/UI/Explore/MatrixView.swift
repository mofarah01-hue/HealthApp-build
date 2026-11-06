import SwiftUI
import MGContext
import MGDomain
import MGDesign

// Correlation matrix (UX-SPEC §9 "MatrixView", APP-104; in the first build by BRIEF default 6).
// Up to 8 metrics, the period from the picker, a Spearman ρ heatmap on a diverging scale (blue = move opposite,
// amber = move together, grey middle). A cell with fewer than 14 paired days is blank "too few days (n)" — decided
// upstream by `MatrixCell.make`; this view only draws it and spells the reason out. Every ρ, n and BH q arrives in
// `MatrixState` (WP-09 functions through the presenter); nothing is computed here. Tapping a cell sends
// `.openMatrixCell(row:column:)` (its scatter is the Compare screen). Owner: WP-19.

struct MatrixView: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.mgTheme) private var theme
    private let state: MatrixState
    private let choices: [MatrixMetric]
    private let send: (UIIntent) -> Void
    /// Presenting the metric picker sheet. A sheet is a picker, not an expansion, so this is the one piece of local state.
    @State private var isPicking = false

    /// `choices` = the metrics Mo can pick from; the root builds it with `ExploreChoices.metrics(from: exploreState)`.
    init(state: MatrixState, choices: [MatrixMetric], send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.choices = choices
        self.send = send
    }

    private var selectedKeys: [String] { state.metrics.map { $0.key } }

    /// Square, and as big as the metric list. Anything else is a presenter bug and is flagged, not drawn.
    private var shapeError: String? {
        let n = state.metrics.count
        if state.cells.count != n {
            return "The matrix has \(state.cells.count) rows for \(n) metrics, so nothing is drawn."
        }
        if let bad = state.cells.firstIndex(where: { $0.count != n }) {
            return "Row \(bad + 1) of the matrix has \(state.cells[bad].count) cells for \(n) metrics, so nothing is drawn."
        }
        return nil
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                ExplorePushHeader(kicker: "Explore", title: "Correlation matrix")

                Text("Spearman ρ between days, \(ExploreText.periodLong(state.period)). "
                     + "Blue: the two move opposite. Amber: they move together. Grey: nothing.")
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                ExplorePeriodPicker(selected: state.period, send: send)
                    .padding(.top, 14)

                metricChips
                    .padding(.top, 14)

                grid
                    .padding(.top, 14)

                Text(state.footnote.isEmpty ? ExploreText.matrixFootnote : state.footnote)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .padding(.bottom, 40)
        }
        .exploreSampleBanner(state.sample)
        .environment(\.mgSend, send)
        .sheet(isPresented: $isPicking) {
            ExploreMatrixPicker(choices: choices, selected: selectedKeys, onChange: { keys in
                send(.setMatrixMetrics(keys))
            }, done: { isPicking = false })
                .mgTheme(theme)
        }
    }

    // MARK: Chosen metrics

    private var metricChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(state.metrics.count) of \(MatrixState.maxMetrics) metrics")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                Spacer()
                Pill("Choose metrics", systemImage: "plus") { isPicking = true }
            }
            if !state.metrics.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(state.metrics) { metric in
                        Chip("\(metric.name) ✕", selected: true) {    // r8h E8: the ✕ says a tap removes it
                            send(.setMatrixMetrics(selectedKeys.filter { $0 != metric.key }))
                        }
                        .accessibilityLabel("\(metric.name), in the matrix")
                        .accessibilityHint("Removes it from the matrix")
                    }
                }
            }
        }
    }

    // MARK: Grid

    @ViewBuilder private var grid: some View {
        if state.metrics.count < 2 {
            ExploreBlankNote("Pick at least two metrics to see how they move together.")
        } else if let error = shapeError {
            ExploreBlankNote(error)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                DivergingHeatmap(
                    labels: state.metrics.map { ExploreText.shortLabel($0.name) },
                    cells: state.cells.map { row in
                        row.map { HeatCell(rho: $0.rho, n: $0.n, note: $0.blankReason) }
                    },
                    onSelect: { row, column in
                        // The diagonal is a metric against itself: nothing to open.
                        if row != column { send(.openMatrixCell(row: row, column: column)) }
                    })
                Text("Touch a cell to see its scatter.")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                legend
                blankList
            }
        }
    }

    /// The scale: blue (−1) through grey (0) to amber (+1), with words under it.
    private var legend: some View {
        let middle = MGRGBA.composite(colors.chip, over: colors.background.lastColor)
        return VStack(spacing: 4) {
            LinearGradient(colors: [colors.sleep.color, middle.color, colors.caffeine.color],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 10)
                .clipShape(Capsule())
            HStack {
                Text("-1 opposite")
                Spacer()
                Text("0 nothing")
                Spacer()
                Text("+1 together")
            }
            .mgFont(.receipt)
            .foregroundStyle(colors.ink2.color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scale from minus one, move opposite, through zero, nothing, to plus one, move together")
    }

    /// Blank cells, spelled out once per pair: "—" in the grid is not enough to say why.
    @ViewBuilder private var blankList: some View {
        let blanks = blankPairs
        if blanks.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Left blank (fewer than \(MatrixState.minPairedDays) paired days, or no variation)")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(blanks, id: \.self) { line in
                    Text(line)
                        .mgFont(.receipt)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "HRV × Vape: too few days (9)" for each pair above the diagonal that has no ρ.
    private var blankPairs: [String] {
        var lines: [String] = []
        let n = state.metrics.count
        guard state.cells.count == n else { return [] }
        for r in 0..<n {
            guard state.cells[r].count == n else { continue }
            for c in (r + 1)..<max(r + 1, n) {
                let cell = state.cells[r][c]
                guard cell.rho == nil else { continue }
                let reason = cell.blankReason ?? "too few days (\(cell.n))"
                lines.append("\(ExploreText.shortLabel(state.metrics[r].name)) × "
                             + "\(ExploreText.shortLabel(state.metrics[c].name)): \(reason)")
            }
        }
        return lines
    }
}

// MARK: - The picker

/// "Choose metrics" (up to 8). Every tap sends the whole new list through `.setMatrixMetrics`; the ticks come back
/// from state, so the sheet always shows what the matrix really holds.
struct ExploreMatrixPicker: View {
    @Environment(\.mgColors) private var colors
    private let choices: [MatrixMetric]
    private let selected: [String]
    private let onChange: ([String]) -> Void
    private let done: () -> Void
    /// r8h E8: the tick moves at once; the presenter's list replaces it when it arrives.
    @State private var local: [String]?
    /// R9f (E7): filters the list below; the ticks stay on the chosen metrics even when they are filtered out of view.
    @State private var query = ""

    init(choices: [MatrixMetric], selected: [String], onChange: @escaping ([String]) -> Void,
         done: @escaping () -> Void) {
        self.choices = choices
        self.selected = selected
        self.onChange = onChange
        self.done = done
    }

    private var current: [String] { local ?? selected }
    private var isFull: Bool { current.count >= MatrixState.maxMetrics }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose metrics").mgFont(.headline).foregroundStyle(colors.ink.color)
                    Text(isFull ? "\(current.count) of \(MatrixState.maxMetrics) — the most; remove one to add another"
                                : "\(current.count) of \(MatrixState.maxMetrics)")
                        .mgFont(.receipt)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                MGButton("Done", style: .ghost, action: done)
            }
            .padding(.horizontal, MGSpace.gutter)
            .padding(.vertical, 14)

            if choices.isEmpty {
                ExploreBlankNote("The catalogue has no metrics to pick from yet.")
                    .padding(.horizontal, MGSpace.gutter)
                Spacer()
            } else {
                ExploreFilterField(text: $query)
                    .padding(.horizontal, MGSpace.gutter)
                    .padding(.bottom, 8)
                let shown = ExploreMetricFilter.apply(choices, query: query)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if shown.isEmpty {
                            ExploreBlankNote("No metric matches “\(query)”.")
                        }
                        ForEach(shown) { metric in
                            row(metric)
                        }
                    }
                    .padding(.horizontal, MGSpace.gutter)
                    .padding(.bottom, 24)
                }
            }
        }
        .onChange(of: selected) { _, _ in local = nil }
        // r9v (E8): if the presenter never answers (or answers with the same list), the tick falls back to its list after 4 s.
        .task(id: local) {
            guard local != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            local = nil
        }
        .background(colors.sheet.color)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(colors.sheet.color)
    }

    private func row(_ metric: MatrixMetric) -> some View {
        let isOn = current.contains(metric.key)
        let blocked = !isOn && isFull
        return Button {
            guard !blocked else { return }
            let next = isOn ? current.filter { $0 != metric.key } : current + [metric.key]
            local = next
            onChange(next)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(blocked ? colors.mute.color : colors.ink.color)
                    .accessibilityHidden(true)
                Text(metric.name)
                    .mgFont(.rowTitle)
                    .foregroundStyle(blocked ? colors.mute.color : colors.ink.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: MGSpace.tapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(blocked ? "Eight metrics are already chosen. Remove one first." : "")
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
    }
}
