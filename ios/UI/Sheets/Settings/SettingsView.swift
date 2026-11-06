import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Settings (T10022, r8p): the system and its connections: PC Lab, the screens behind it (Strap & sync, Alarms, Places,
// Usage, Apple Health, Shortcuts, Decode lab, Model status, Command test), Privacy, Export, Sample data, Methods, Tests,
// About. You and how the app looks are on Preferences (PreferencesView); the first row links there. Which item is on which
// screen is `SettingsMap` (MGContext). Pure rendering of `SettingsState`; every change is a `UIIntent` sent through `send`.
//
// Theme: RootView applies `.mgTheme(...)` above this view (SettingsState has no ThemeName); sheets inherit it.
// SAMPLE mode: the SAMPLE banner is pinned, every control that changes a setting is disabled with its reason, and
// only the Sample-data switch works, so Mo can always turn it off.

struct SettingsView: View {
    let state: SettingsState
    let send: (UIIntent) -> Void
    let testRuns: TestRunsState
    /// The strap page, drawn as the Device section (nil until it has been built; the section then says so).
    let strap: SettingsStrapEmbed?

    init(state: SettingsState, send: @escaping (UIIntent) -> Void, testRuns: TestRunsState = .empty,
         strap: SettingsStrapEmbed? = nil) {
        self.state = state
        self.send = send
        self.testRuns = testRuns
        self.strap = strap
    }
    @Environment(\.dismiss) private var dismiss

    private var canEdit: Bool { !state.sample }

    var body: some View {
        SettingsScreenFrame(screen: .settings, sample: state.sample, kicker: "System and connections",
                            openOther: { send(.openPreferences) }) { block in
            blockView(block)
        }
        .environment(\.mgSend, send)
    }

    @ViewBuilder
    private func blockView(_ block: SettingsBlock) -> some View {
        switch block {
        case .moreScreens(let items):
            SettingsMoreScreensSection(items: items, deviceName: state.deviceName, send: send)
        case .item(let item):
            switch item {
            case .strapSync:
                SettingsStrapSection(embed: strap, send: send)
            case .pcLab:
                SettingsPCSection(canEdit: canEdit, statusWord: state.pcStatusWord, send: send)
            case .privacy:
                SettingsPrivacySection(lines: state.privacyLines)
            case .export:
                SettingsExportSection(action: state.export, canEdit: canEdit, send: send)
            case .sampleData:
                SettingsSampleSection(isOn: state.sampleData, send: send)
            case .methods:
                SettingsMethodsSection(droppedCount: state.droppedMethodsCount, openExplore: openExplore)
            case .tests:
                SettingsTestsSection(state: testRuns, send: send)
            case .about:
                SettingsAboutSection(mapLine: state.primaryMapLine)
            default:
                EmptyView()      // the items of Preferences and of "More screens": never listed for this screen
            }
        }
    }

    /// r9v (T3): leave this screen first, then switch tab on the next turn of the run loop, so the tab change is not
    /// swallowed by the screen that is still on its way out.
    private func openExplore() {
        dismiss()
        Task { @MainActor in send(.selectTab(.explore)) }
    }
}
