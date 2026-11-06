#if DEBUG
import Foundation
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of Settings. `SettingsState.preview` is SAMPLE (banner on, every control but the Sample-data switch
// disabled); the "live" variant turns SAMPLE off and leaves the "must be up by" fields and the profile blank, as the
// first build starts. The host applies the intents that change what Settings shows, so switches and rows react.

struct SettingsPreviewHost: View {
    @State private var state: SettingsState
    let theme: ThemeName

    init(state: SettingsState, theme: ThemeName = .cream) {
        _state = State(initialValue: state)
        self.theme = theme
    }

    var body: some View {
        SettingsView(state: state) { intent in apply(intent) }
            .mgTheme(theme)
    }

    private func apply(_ intent: UIIntent) {
        switch intent {
        case .setSampleData(let on):
            state.sampleData = on
            state.sample = on
        case .setTheme(let setting):
            state.theme = setting
        case .setResearchRows(let on):
            state.researchRowsShown = on
        case .setHideWorkingBars(let on):
            state.hideWorkingBars = on
        case .setWakeWindow(let minutes):
            state.wakeWindowMinutes = minutes
        case .setLatestWake(let weekday, let time):
            if let index = state.latestWake.firstIndex(where: { $0.weekday == weekday }) {
                state.latestWake[index].time = time
            }
        case .editSetting(.saveDrinkPreset(let preset)):
            if let index = state.drinkPresets.firstIndex(where: { $0.name == preset.name }) {
                state.drinkPresets[index] = preset
            } else {
                state.drinkPresets.append(preset)
            }
        case .editSetting(.removeDrinkPreset(let name)):
            state.drinkPresets.removeAll { $0.name == name }
        default:
            print("Settings intent:", intent)
        }
    }
}

extension SettingsState {
    /// The first-build starting point: SAMPLE off, profile blank, no "must be up by" times, notifications still PLACEHOLDERS.
    static var settingsPreviewLive: SettingsState {
        var s = SettingsState.preview
        s.sample = false
        s.sampleData = false
        s.profile = [
            LabeledValue(id: "birth_date", label: "Birth date", value: .blank(reason: "not set", receipt: nil)),
            LabeledValue(id: "sex", label: "Sex", value: .blank(reason: "not set", receipt: nil)),
            LabeledValue(id: "height_cm", label: "Height", value: .blank(reason: "not set", receipt: nil)),
            LabeledValue(id: "weight_kg", label: "Weight", value: .blank(reason: "not set", receipt: nil)),
            LabeledValue(id: "hr_max", label: "Max HR (measured)", value: .blank(reason: "not set", receipt: nil)),
            LabeledValue(id: "hr_rest", label: "Resting HR baseline", value: .blank(reason: "not set", receipt: nil)),
        ]
        return s
    }
}

#Preview("Preferences · Day") {
    PreferencesView(state: .settingsPreviewLive) { print($0) }.mgTheme(.cream)
}
#Preview("Settings · sample · everything locked but the switch") { SettingsPreviewHost(state: .preview) }
#Preview("Settings · Day") { SettingsPreviewHost(state: .settingsPreviewLive) }
#Preview("Settings · emerald") { SettingsPreviewHost(state: .settingsPreviewLive, theme: .emerald) }
#Preview("Settings · Night") { SettingsPreviewHost(state: .settingsPreviewLive, theme: .emeraldLow) }
#Preview("Settings · largest text") {
    SettingsPreviewHost(state: .settingsPreviewLive).environment(\.dynamicTypeSize, .accessibility3)
}
#Preview("Editor · must be up by") {
    SettingsWakeEditor(weekday: 2, current: SettingsState.settingsPreviewLive.latestWake, canEdit: true) { print($0) }
        .mgTheme(.cream)
}
#Preview("Editor · schedule") {
    SettingsScheduleEditor(row: ScheduleRow(id: "meda", title: "MedA 20 mg", detail: "daily · 07:15",
                                            isSupplement: false),
                           supplement: false, canEdit: true) { print($0) }
        .mgTheme(.cream)
}
#Preview("Editor · drink preset") {
    SettingsPresetEditor(preset: DrinkPreset(name: "DrinkA", caffeineMg: 200), existingNames: ["DrinkA", "DrinkB"],
                         canEdit: true) { print($0) }
        .mgTheme(.emerald)
}
#Preview("Front page · inner rings") {
    FrontPageSettingsView(state: FrontPagePresenter.settings(layout: .standard, sample: false)) { print($0) }
        .mgTheme(.cream)
}
#Preview("Command test · two tagged rows") {
    CommandTestView(state: CommandTestPresenter.make(
        commands: [
            CommandTestCommand(number: 29, name: "REBOOT_STRAP"),
            CommandTestCommand(number: 30, name: "DFU_MODE"),
            CommandTestCommand(number: 31, name: "READ_STATUS"),
        ],
        on: nil, payload: "", payloadProblem: nil, log: [], notice: nil,
        calendar: Calendar(identifier: .gregorian)
    )) { print($0) }
    .mgTheme(.cream)
}
#endif
