import SwiftUI
import MGContext
import MGDesign

// MARK: Front page (tracker #34, 2026-10-11): one row that opens Settings › Front page.

struct SettingsFrontPageSection: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsSection("Front page", note: "Today") {
            SettingsLinkRow("Front page and dial ring",
                            detail: "Choose, order and hide Today's cards, and what the 24-hour dial draws.",
                            action: { send(.frontPage(.open)) }) { EmptyView() }
        }
    }
}
