#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of the Workout detail. All values are SAMPLE (`sample: true`), so the SAMPLE banner shows on each.
// Taps print their intent to the console.

private struct WorkoutPreviewHost: View {
    let state: WorkoutDetailState
    let theme: ThemeName

    init(_ state: WorkoutDetailState, theme: ThemeName = .creamGolden) {
        self.state = state
        self.theme = theme
    }

    var body: some View {
        NavigationStack {
            WorkoutDetailView(state: state, theme: theme) { print("Workout intent:", $0) }
        }
    }
}

#Preview("Workout · just ended · golden") { WorkoutPreviewHost(.preview) }
#Preview("Workout · Emerald") { WorkoutPreviewHost(.preview, theme: .emerald) }
#Preview("Workout · live, so far") { WorkoutPreviewHost(.previewLive) }

/// One window open (values with receipts, kind chips, split, merge) and the times editor open.
#Preview("Workout · window + times open") {
    var s = WorkoutDetailState.preview
    if s.windows.count > 1 { s.windows[1].isOpen = true }
    s.timesOpen = true
    return WorkoutPreviewHost(s)
}

/// No max HR known: no zone bands, and the map says why; TRIMP blank with its reason.
#Preview("Workout · no zone edges") {
    var s = WorkoutDetailState.preview
    s.hrMap.zoneEdgesBpm = nil
    s.hrMap.zoneBasis = nil
    s.windows = s.windows.map { w in
        var w = w
        w.trimp = .blank(reason: "needs your max HR (Preferences › Profile)", receipt: nil)
        w.zoneMinutes = nil
        return w
    }
    return WorkoutPreviewHost(s, theme: .cream)
}

/// Strap off the whole session: the map is blank with the reason.
#Preview("Workout · no heart rate") {
    var s = WorkoutDetailState.preview
    s.hrMap.bpm = []
    s.hrMap.blankReason = "No heart rate — the strap was off the whole session."
    return WorkoutPreviewHost(s, theme: .cream)
}

/// Edits off (sample mode) with the reason.
#Preview("Workout · edits off") {
    var s = WorkoutDetailState.preview
    s.editable = false
    s.editDisabledReason = "Sample data — edits are off."
    return WorkoutPreviewHost(s, theme: .cream)
}

#Preview("Workout · largest text") {
    WorkoutPreviewHost(.preview, theme: .cream)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
