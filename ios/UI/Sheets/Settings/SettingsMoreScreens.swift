import SwiftUI
import MGContext
import MGDesign

// R8p (S7, T10022): "More screens": one list instead of five header-plus-one-row sections (Alarms, Usage, Places, Apple
// Health, Shortcuts, Model status, Command test each had a header and a single row with the same name). The rows come
// from `SettingsMap` in its order; each is a row view next to its old section file.

struct SettingsMoreScreensSection: View {
    let items: [SettingsItem]
    let send: (UIIntent) -> Void
    /// "MG" or "WHOOP 4.0" (`SettingsState.deviceName`).
    let deviceName: String

    init(items: [SettingsItem], deviceName: String = "MG", send: @escaping (UIIntent) -> Void) {
        self.items = items
        self.deviceName = deviceName
        self.send = send
    }

    var body: some View {
        SettingsSection("More screens", note: "each opens its own page") {
            ForEach(items) { item in
                row(item)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SettingsItem) -> some View {
        switch item {
        case .strapSync:
            SettingsLinkRow(deviceName == "MG" ? "Strap & sync" : "Strap & sync · \(deviceName)",
                            detail: "Bond, battery, history, write log, PC state.",
                            action: { send(.openStrapSync) }) { EmptyView() }
        case .alarms:
            SettingsAlarmsRow(send: send)
        case .places:
            SettingsPlacesRow(send: send)
        case .usage:
            SettingsUsageRow(send: send)
        case .appleHealth:
            SettingsAppleHealthRow(send: send)
        case .shortcuts:
            SettingsShortcutsRow()
        case .decodeLab:
            SettingsLinkRow("Decode lab", detail: "Raw strap streams by packet type; keep frames for the PC to read.",
                            action: { send(.openResearch("decode")) }) { EmptyView() }
        case .modelStatus:
            SettingsModelStatusRow(send: send)
        case .commandTest:
            SettingsCommandTestRow(send: send)
        case .ringLab:
            SettingsRingLabRow(send: send)
        case .screenTime:
            SettingsScreenTimeRow(send: send)
        default:
            EmptyView()          // not a screen row; `SettingsMap` never lists one here
        }
    }
}
