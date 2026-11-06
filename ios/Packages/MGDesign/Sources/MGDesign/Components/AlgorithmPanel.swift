import SwiftUI
import MGContext

/// Shared T30/T99/T100/T133 panel: tap the title to expand, then use one dropdown to choose the display algorithm.
/// The caller persists the selected id; this view owns no algorithm rules.
public struct AlgorithmPanel: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let state: AlgorithmPanelState
    private let select: (String) -> Void
    @State private var expanded = false
    /// The pick of an option outside the comparison group: shown here, never saved as the group's read method.
    @State private var localID: String?

    private var shownID: String { localID ?? state.selectedID }

    public init(state: AlgorithmPanelState, select: @escaping (String) -> Void) {
        self.state = state
        self.select = select
    }

    public var body: some View {
        MGCard {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(MGMotion.expand(reduceMotion: reduceMotion)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.title).mgFont(.headline).foregroundStyle(colors.ink.color)
                            Text(state.summary).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(colors.mute.color)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: MGSpace.tapTarget)      // Night 8: the one header under 44 pt
                .accessibilityValue(expanded ? "open" : "closed")
                .accessibilityHint(expanded ? "Closes the breakdown" : "Shows the algorithm and metric breakdown")

                if expanded, let selected = state.options.first(where: { $0.id == shownID }) ?? state.selected {
                    Menu {
                        ForEach(state.options) { option in
                            Button {
                                localID = option.savesChoice ? nil : option.id
                                if option.savesChoice { select(option.id) }
                            } label: {
                                if option.id == shownID {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Display algorithm").mgFont(.receipt).foregroundStyle(colors.ink2.color)
                                Text(selected.label).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(colors.ink2.color)
                        }
                        .frame(minHeight: MGSpace.tapTarget)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: MGRadius.chip).fill(colors.chip.color))
                    }
                    .accessibilityLabel("Display algorithm, \(selected.label)")

                    if let note = state.note { detail(note) }
                    if let note = selected.note { detail(note) }

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(selected.metrics.enumerated()), id: \.element.id) { index, metric in
                            metricRow(metric, first: index == 0)
                        }
                    }

                    explainer(selected.explanation)
                        .transition(.opacity)
                }
            }
        }
        .animation(MGMotion.expand(reduceMotion: reduceMotion), value: shownID)
    }

    private func metricRow(_ metric: PanelMetricState, first: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric.label).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                Spacer(minLength: 8)
                ValueView(metric.value, size: .small)
            }
            Text("Unit: " + metric.explanation.unit)
                .mgFont(.receipt)
                .foregroundStyle(colors.ink2.color)
            if metric.value.isBlank {
                Text(metric.explanation.blank)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(colors.rule.color).frame(height: 1) }
        }
    }

    private func explainer(_ explanation: PanelExplanation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(explanation.id).mgFont(.kicker).foregroundStyle(colors.ink2.color)
            explanationLine("What it measures", explanation.simple)
            explanationLine("Technical", explanation.technical)
            explanationLine("Takes in", explanation.inputs)
            explanationLine("How it computes", explanation.computation)
            explanationLine("What the number means", explanation.meaning)
            explanationLine("Unit", explanation.unit)
            explanationLine("Source", explanation.source)
            explanationLine("If blank", explanation.blank)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
    }

    private func explanationLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).mgFont(.receipt).foregroundStyle(colors.ink2.color)
            Text(text).mgFont(.detail).foregroundStyle(colors.ink.color).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text).mgFont(.detail).foregroundStyle(colors.ink2.color).fixedSize(horizontal: false, vertical: true)
    }
}
