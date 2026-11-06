import SwiftUI
import WidgetKit

// WP-27 — the widget extension's entry point (APP-016): Home Screen widget, Lock Screen widgets, and on iOS 18 the two
// Control Center controls. Built by the MGWidgets target (Widgets/PROJECT-TARGET.yml), embedded in MGApp.

@main
struct MGWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuickLogHomeWidget()
        QuickLogLockWidget()
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            QuickLogVapeControl()
            QuickLogMedicationControl()
        }
        #endif
    }
}
