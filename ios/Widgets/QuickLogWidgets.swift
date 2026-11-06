import SwiftUI
import WidgetKit

// WP-27 — the two WidgetKit widgets. Static (no per-widget settings): the presets come from the app's snapshot.

/// Home Screen: four quick-log buttons.
struct QuickLogHomeWidget: Widget {
    static let kind = "mg.quicklog.home"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: QuickLogHomeWidget.kind, provider: QuickLogProvider()) { entry in
            QuickLogHomeView(entry: entry)
        }
        .configurationDisplayName("MG quick log")
        .description("Vape, medication, a drink or a symptom: one tap logs it.")
        .supportedFamilies([.systemSmall])
    }
}

/// Lock Screen: a vape-hit button with today's count (circular), next medication and last vape (rectangular).
struct QuickLogLockWidget: Widget {
    static let kind = "mg.quicklog.lock"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: QuickLogLockWidget.kind, provider: QuickLogProvider()) { entry in
            QuickLogLockView(entry: entry)
        }
        .configurationDisplayName("MG vape and medication")
        .description("One tap logs a vape hit or your medication. Shows today's count and the next dose.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}
