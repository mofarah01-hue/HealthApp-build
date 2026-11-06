import SwiftUI
import MGContext
import MGDesign

// MARK: Apple Health (2026-10-11, the Shortcuts bridge): one row that opens Settings › Apple Health. R8p (S7): rows of "More screens".

/// Settings › Model status (2026-10-11): every model and its state today.
struct SettingsModelStatusRow: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsLinkRow("Model status", detail: "Every model: running, blank today and why, not built yet, or "
                        + "blocked (and on what).",
                        action: { send(.openModelStatus) }) { EmptyView() }
    }
}

struct SettingsAppleHealthRow: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsLinkRow("Apple Health", detail: "Send today's values to Health, bring Health's data to your PC, and "
                        + "the steps for the three Shortcuts.",
                        action: { send(.appleHealth(.open)) }) { EmptyView() }
    }
}
