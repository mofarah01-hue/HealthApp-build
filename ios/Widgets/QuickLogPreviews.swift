#if DEBUG
import MGDomain
import SwiftUI
import WidgetKit

// WP-27 — Xcode previews of the widget layouts. DEBUG builds only. The values below are made up to see the layouts;
// they are never compiled into a Release build and never reach a phone's widget (the real widget reads the app's
// snapshot, or says "Open MG once").

private enum QuickLogPreviewData {
    static let now = Date(timeIntervalSince1970: 1_791_700_000)

    static func ready(_ theme: QuickLogTheme, open: String? = nil, nextDue: Date? = nil) -> QuickLogEntry {
        let model = QuickLogModel(
            theme: theme, buttonsEnabled: true, vapeCount: 7, vapeCountIsPartial: false,
            lastVapeAt: now.addingTimeInterval(-42 * 60),
            med: QuickLogModel.Med(preset: QuickLogPresets.medication, nextDue: nextDue, lastTakenAt: nil),
            drink: QuickLogModel.Drink(preset: IntentsDrink(name: "Coffee", caffeineMg: 95), openName: open),
            symptomKind: "other")
        return QuickLogEntry(date: now, state: .ready(model))
    }

    static func message(_ state: QuickLogState) -> QuickLogEntry {
        QuickLogEntry(date: now, state: state)
    }
}

struct QuickLogHomeView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            QuickLogHomeView(entry: QuickLogPreviewData.ready(.cream, nextDue: QuickLogPreviewData.now.addingTimeInterval(3600)))
            QuickLogHomeView(entry: QuickLogPreviewData.ready(.emerald, open: "Coffee"))
            QuickLogHomeView(entry: QuickLogPreviewData.message(.openMG))
        }
        .previewContext(WidgetPreviewContext(family: .systemSmall))
    }
}

struct QuickLogLockView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            QuickLogLockView(entry: QuickLogPreviewData.ready(.cream))
                .previewContext(WidgetPreviewContext(family: .accessoryCircular))
            QuickLogLockView(entry: QuickLogPreviewData.ready(.cream, nextDue: QuickLogPreviewData.now.addingTimeInterval(3600)))
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
            QuickLogLockView(entry: QuickLogPreviewData.message(.openMG))
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
        }
    }
}
#endif
