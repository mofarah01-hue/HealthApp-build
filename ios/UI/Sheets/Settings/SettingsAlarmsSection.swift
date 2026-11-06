import SwiftUI
import MGContext
import MGDesign

// MARK: Alarms (2026-10-11, Mo's strap alarms): one row that opens the alarm page. R8p (S7): a row of "More screens".

struct SettingsAlarmsRow: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsLinkRow("Alarms", detail: "Fajr wake, normal wake, alarms, timers and calendar buzz — on the strap, "
                        + "with an iPhone alarm as backstop.",
                        action: { send(.alarms(.open)) }) { EmptyView() }
    }
}
