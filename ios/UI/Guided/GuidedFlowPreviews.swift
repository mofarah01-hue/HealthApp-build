#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of the guided flows. All values are SAMPLE (`sample: true`), so the SAMPLE banner shows on each.
// The running pacer and the HRV countdown anchor on the preview's own clock, so they move. Taps print their intent.

#Preview("Breathe · ready") {
    GuidedBreatheView(state: .previewReady, theme: .emerald) { print("Breathe intent:", $0) }
}
#Preview("Breathe · running · Emerald") {
    GuidedBreatheView(state: .preview, theme: .emerald) { print("Breathe intent:", $0) }
}
#Preview("Breathe · running · Emerald low, quiet hours") {
    GuidedBreatheView(state: .preview, theme: .emeraldLow) { print("Breathe intent:", $0) }
        .environment(\.mgQuietHaptics, true)
}
#Preview("Breathe · no strap") {
    GuidedBreatheView(state: .previewNoStrap, theme: .cream) { print("Breathe intent:", $0) }
}
#Preview("Breathe · finished") {
    GuidedBreatheView(state: .previewFinished, theme: .emerald) { print("Breathe intent:", $0) }
}
#Preview("Breathe · largest text") {
    GuidedBreatheView(state: .preview, theme: .cream) { print("Breathe intent:", $0) }
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("HRV check · ready") {
    GuidedHRVCheckView(state: .previewReady, theme: .cream) { print("HRV intent:", $0) }
}
#Preview("HRV check · measuring") {
    GuidedHRVCheckView(state: .preview, theme: .cream) { print("HRV intent:", $0) }
}
#Preview("HRV check · result") {
    GuidedHRVCheckView(state: .previewResult, theme: .cream) { print("HRV intent:", $0) }
}
#Preview("HRV check · gate failed") {
    GuidedHRVCheckView(state: .previewFailed, theme: .creamGolden) { print("HRV intent:", $0) }
}
#Preview("HRV check · strap off") {
    GuidedHRVCheckView(state: .previewBlocked, theme: .emerald) { print("HRV intent:", $0) }
}
#Preview("HRV check · largest text") {
    GuidedHRVCheckView(state: .previewResult, theme: .cream) { print("HRV intent:", $0) }
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
