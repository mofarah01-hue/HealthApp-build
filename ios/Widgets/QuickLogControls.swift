import AppIntents
import SwiftUI
import WidgetKit

// WP-27 — Control Center controls (iOS 18): a vape-hit button and a medication button. They also work from the Lock
// Screen's two control slots and the Action Button (Settings › Action Button › Controls). Each is a
// `ControlWidgetButton` whose action is the same widget intent the other surfaces use, stamped `control`.
//
// ControlWidget exists only in the iOS 18 SDK (Xcode 16, Swift 6.0 compiler), hence `#if compiler(>=6.0)` here and in
// the bundle, and `@available(iOS 18.0, *)` for phones on iOS 17, where these two simply don't exist. The medication
// control logs the app's own first prescription medication, found at tap time (T9973: no medication name is written
// in source; with nothing known yet it logs a plain "Medication" entry with no dose).

#if compiler(>=6.0)

@available(iOS 18.0, *)
struct QuickLogVapeControl: ControlWidget {
    static let kind = "mg.control.vape"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: QuickLogVapeControl.kind) {
            ControlWidgetButton(action: WidgetLogVapeHitIntent(surface: .control)) {
                Label("Vape hit", systemImage: "wind")
            }
        }
        .displayName("Log a vape hit")
        .description("Adds one vape hit to your MG log, right now.")
    }
}

@available(iOS 18.0, *)
struct QuickLogMedicationControl: ControlWidget {
    /// Kept exactly as first shipped (R9k, brain's instruction): WidgetKit keys a placed control by this id, so changing it
    /// would make Mo re-add the control. It is an identifier, never shown; only the display name is generic.
    static let kind = "mg.control.vyvanse"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: QuickLogMedicationControl.kind) {
            ControlWidgetButton(action: WidgetLogMedicationIntent(presetId: QuickLogPresets.medication.presetId,
                                                                  surface: .control)) {
                Label("Medication", systemImage: "pills")
            }
        }
        .displayName("Log medication")
        .description("Logs your medication dose as taken now.")
    }
}

#endif
