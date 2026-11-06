import SwiftUI
import MGContext
import MGDesign

// MARK: Usage (tracker #40, 2026-10-11): one row that opens the Usage page. R8p (S7): a row of "More screens".

struct SettingsUsageRow: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsLinkRow("Usage", detail: "Storage on the iPhone and the PC, background runs, and the compute each "
                        + "uses — and what the PC is running now.",
                        action: { send(.usage(.open)) }) { EmptyView() }
    }
}
