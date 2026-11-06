import SwiftUI
import MGContext
import MGDesign

// MARK: Places (tracker #41, 2026-10-11): one row that opens the Places page. R8p (S7): a row of "More screens".

struct SettingsPlacesRow: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsLinkRow("Places", detail: "Home, Work, Gym, Soccer field, Pickup field — a workout is tagged with "
                        + "where it happened, and Home never becomes a workout without asking.",
                        action: { send(.places(.open)) }) { EmptyView() }
    }
}
