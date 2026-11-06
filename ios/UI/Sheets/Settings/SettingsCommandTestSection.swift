import SwiftUI
import MGContext
import MGDesign

// MARK: Command test (T87, 2026-10-13): one row that opens the Command test page. R8p (S7): a row of "More screens".

struct SettingsCommandTestRow: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsLinkRow("Command test", detail: "Send one strap command by number, with an optional payload, and mark "
                        + "whether it did anything. Red/IR and SpO₂ on demand are tried here.",
                        action: { send(.commandTest(.open)) }) { EmptyView() }
    }
}
