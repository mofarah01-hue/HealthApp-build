import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Preferences (T10022, r8p; UI-SCRUB-B section 7): you and how the app looks and behaves. Profile, sun vitamin D, records,
// Sleep & wake (latest wake times, smart-wake window, sleep need), Medications & supplements, Drink presets, preset lists;
// then Front page, Theme, Top bar, Working on, Quick-log surfaces, Notifications, Show research rows. Opened by the "M" on
// Today. Everything connected or technical is on Settings (SettingsView); the first row links there. Which item is on
// which screen is `SettingsMap` (MGContext).
//
// Same state, intents and sheets as Settings used to have: `SettingsState` (one build serves both screens), editing a
// value opens a small sheet (SettingsEditors). SAMPLE mode: every control that changes a setting is disabled with its
// reason; the Sample-data switch is on Settings and the reason says so.

struct PreferencesView: View {
    let state: SettingsState
    let send: (UIIntent) -> Void
    /// T149: the running and waiting jobs (WorkingDetailPresenter); not emptied by the hide switch.
    let workingDetail: WorkingDetailState

    init(state: SettingsState, send: @escaping (UIIntent) -> Void, workingDetail: WorkingDetailState = .empty) {
        self.state = state
        self.send = send
        self.workingDetail = workingDetail
    }
    @State private var editor: SettingsEditor?

    private var canEdit: Bool { !state.sample }

    var body: some View {
        SettingsScreenFrame(screen: .preferences, sample: state.sample, kicker: "You and how the app looks",
                            openOther: { send(.openSettings) }) { block in
            blockView(block)
        }
        .sheet(item: $editor) { current in
            SettingsEditorSheet(editor: current, state: state, canEdit: canEdit, send: send)
        }
        .environment(\.mgSend, send)
    }

    @ViewBuilder
    private func blockView(_ block: SettingsBlock) -> some View {
        switch block {
        case .moreScreens:
            EmptyView()          // Settings only
        case .item(let item):
            switch item {
            case .profile:
                SettingsProfileSection(rows: state.profile, canEdit: canEdit, open: { editor = $0 },
                                       fillFromPC: { send(SettingsIntents.profileFromPC) })
            case .sunVitaminD:
                SettingsVitaminDSection(skinType: state.fitzpatrickSkinType, location: state.vitaminDLocation,
                                        canEdit: canEdit, open: { editor = $0 })
            case .records:
                SettingsProfileRecordsSection(bodyComposition: state.bodyComposition, injuries: state.injuries)
            case .sleepWake:
                SettingsSleepSection(state: state, canEdit: canEdit, open: { editor = $0 }, send: send)
            case .medications:
                SettingsSchedulesSection(schedules: state.schedules, canEdit: canEdit, open: { editor = $0 })
            case .drinkPresets:
                SettingsPresetsSection(presets: state.drinkPresets, canEdit: canEdit, open: { editor = $0 })
            case .presetLists:
                SettingsPresetListsSection(lists: state.presetLists, canEdit: canEdit, open: { editor = $0 })
            case .frontPage:
                SettingsFrontPageSection(send: send)
            case .theme:
                SettingsThemeSection(selected: state.theme, canEdit: canEdit, send: send)
            case .topBar:
                SettingsTopBarSection(hidden: state.hideWorkingBars, canEdit: canEdit, send: send)
            case .workingOn:
                SettingsWorkingSection(detail: workingDetail, barsHidden: state.hideWorkingBars, send: send)
            case .quickLog:
                SettingsSurfacesSection(toggles: state.quickLogSurfaces, canEdit: canEdit, send: send)
            case .notifications:
                SettingsNotificationsSection(rows: state.notificationRows, toggles: state.notificationToggles,
                                             skips: state.notificationSkips, arePlaceholders: state.notificationsArePlaceholders,
                                             canEdit: canEdit, send: send)
            case .researchRows:
                SettingsResearchSection(shown: state.researchRowsShown, canEdit: canEdit, send: send)
            default:
                EmptyView()      // the items of Settings: never listed for this screen
            }
        }
    }
}
