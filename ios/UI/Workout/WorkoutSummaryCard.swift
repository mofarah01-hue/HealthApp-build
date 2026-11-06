import SwiftUI
import MGContext
import MGDesign
import MGDomain

// T116: the WHOOP-style workout summary. The headline numbers always show; the row opens in place
// (`.toggleRow(id: state.toggleId)`) to zones, steps, HR recovery, the flags and the HR map. Pure rendering of
// `WorkoutSummaryState`. Used on Live while the workout runs and in Explore › Workouts.

struct WorkoutSummaryCard: View {
    let state: WorkoutSummaryState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(state.headline) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label).mgFont(.receipt).foregroundStyle(colors.mute.color)
                        ValueView(item.value, size: .small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            ExpandableRow(title: state.title, detail: state.kicker, receipt: nil,
                          isOpen: Binding(get: { state.isOpen }, set: { _ in send(.toggleRow(id: state.toggleId)) })) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.details.enumerated()), id: \.element.id) { i, item in
                        ExploreLabeledValueRow(item: item, showsRule: i > 0, send: send)
                    }
                    Text(state.flagsNote)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                    if let map = state.hrMap {
                        WorkoutHRMapChart(map: map, windows: [], end: nil)
                    }
                    Button("Open workout") { send(.openWorkout(id: state.id)) }
                        .mgFont(.rowTitle)
                        .padding(.top, 6)
                }
            }
            .animation(MGMotion.expand(reduceMotion: reduceMotion), value: state.isOpen)
        }
    }
}

/// Explore › Workouts: the recent finished workouts, each a summary card.
struct ExploreWorkoutsSection: View {
    let history: WorkoutHistoryState
    let send: (UIIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Workouts", note: history.rows.isEmpty ? nil : "this month · tap to open")
            if let reason = history.emptyReason {
                ExploreBlankNote(reason)
            }
            ForEach(history.rows) { row in
                WorkoutSummaryCard(state: row, send: send)
            }
        }
    }
}
