import SwiftUI
import MGContext
import MGDesign
import MGDomain

// One struct per section of UX §14 "Settings": Profile · Sleep & wake · Medications & supplements · Drink presets ·
// Quick-log surfaces · Notifications · Theme · Research · Methods · Sample data · PC Lab & strap · Privacy · Export.
// Sections only draw `SettingsState` and send intents; editing happens in the sheets of SettingsEditors.swift.

// MARK: Profile (APP-364)

struct SettingsProfileSection: View {
    let rows: [LabeledValue]
    let canEdit: Bool
    let open: (SettingsEditor) -> Void
    /// Tracker #90: "Use values from Apple Health (via your PC)"; nil = not offered.
    let fillFromPC: (() -> Void)?

    init(rows: [LabeledValue], canEdit: Bool, open: @escaping (SettingsEditor) -> Void,
         fillFromPC: (() -> Void)? = nil) {
        self.rows = rows
        self.canEdit = canEdit
        self.open = open
        self.fillFromPC = fillFromPC
    }

    var body: some View {
        SettingsSection("Profile", note: "calories · zones · ages") {
            if rows.isEmpty {
                SettingsRow("No profile fields yet") { EmptyView() }
            }
            ForEach(rows) { row in
                SettingsLinkRow(row.label, detail: row.caption, enabled: canEdit, action: { open(.profile(row)) }) {
                    ValueView(row.value, size: .small)
                        .frame(maxWidth: 190, alignment: .trailing)
                }
            }
            if let fillFromPC {
                SettingsLinkRow("Use values from Apple Health (via your PC)",
                                detail: "Fills only the empty fields above from the birth date, sex, height and weight "
                                + "your PC read from the Apple Health export. What you typed stays.",
                                enabled: canEdit, action: fillFromPC) { EmptyView() }
            }
        }
    }
}

// MARK: Sun vitamin D estimate

struct SettingsVitaminDSection: View {
    let skinType: Int?
    let location: VitaminDRoughLocation?
    let canEdit: Bool
    let open: (SettingsEditor) -> Void

    var body: some View {
        SettingsSection("Sun vitamin D", note: "estimate inputs") {
            SettingsLinkRow("Skin type", detail: "Six-question Fitzpatrick quiz.", enabled: canEdit,
                            action: { open(.skinType) }) {
                SettingsValueText(skinType.map { "Type " + roman($0) } ?? "not set", muted: skinType == nil)
            }
            SettingsLinkRow("Rough location", detail: "Typed by hand. No GPS or location permission.", enabled: canEdit,
                            action: { open(.vitaminDLocation) }) {
                SettingsValueText(locationText, muted: location == nil)
            }
            LogHint("These feed the sunlight vitamin D estimate on your PC. Coordinates are stored to one decimal.")
                .padding(.vertical, 8)
        }
    }

    private var locationText: String {
        guard let location else { return "not set" }
        return location.name + String(format: " · %.1f, %.1f", location.latitude, location.longitude)
    }

    private func roman(_ type: Int) -> String {
        guard (1...6).contains(type) else { return "?" }
        return ["I", "II", "III", "IV", "V", "VI"][type - 1]
    }
}

// MARK: Sleep & wake (UX §8.1, §14)

struct SettingsSleepSection: View {
    let state: SettingsState
    let canEdit: Bool
    let open: (SettingsEditor) -> Void
    let send: (UIIntent) -> Void

    init(state: SettingsState, canEdit: Bool, open: @escaping (SettingsEditor) -> Void,
         send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.canEdit = canEdit
        self.open = open
        self.send = send
    }

    var body: some View {
        SettingsSection("Sleep & wake", note: "must be up by") {
            ForEach(SettingsWeekday.order, id: \.self) { day in
                SettingsLinkRow(SettingsWeekday.names[day] ?? "", enabled: canEdit,
                                action: { open(.latestWake(weekday: day)) }) {
                    SettingsValueText(wakeText(day), muted: wakeTime(day) == nil)
                }
            }
            LogHint("The latest time you must be up. Blank means no smart-wake plan that morning, and Tonight says why.")
                .padding(.vertical, 8)

            SettingsRow("Smart-wake window",
                        detail: "Inside this window before your latest time, the ring waits for a moment of light sleep.") {
                SettingsWakeWindowStepper(minutes: state.wakeWindowMinutes, send: send)
                    .disabled(!canEdit)
            }

            SettingsRow("Smart-wake mode", detail: SmartWakeModes.detail(state.smartWakeMode)) {
                SettingsSmartWakeModeMenu(state: state, send: send)
                    .disabled(!canEdit)
            }
            if state.smartWakeMode == "timeGate" {
                SettingsRow("Not before", detail: SmartWakeModes.needNote) {
                    SettingsSmartWakeGateStepper(state: state, send: send)
                        .disabled(!canEdit)
                }
            } else if state.smartWakeMode != SmartWakeModes.defaultID {
                LogHint(SmartWakeModes.needNote).padding(.vertical, 8)
            }

            SettingsLinkRow("Sleep need", detail: "Starts from your history unless you set your own.",
                            enabled: canEdit, action: { open(.needOverride) }) {
                if let value = state.needOverride {
                    ValueView(value, size: .small)
                } else {
                    SettingsValueText("from history", muted: true)
                }
            }
        }
    }

    private func wakeTime(_ weekday: Int) -> TimeOfDay? {
        state.latestWake.first(where: { $0.weekday == weekday })?.time
    }

    private func wakeText(_ weekday: Int) -> String {
        guard let time = wakeTime(weekday) else { return "not set" }
        return MGFormat.time(time)
    }
}

// MARK: Medications & supplements (APP-075, 077)

struct SettingsSchedulesSection: View {
    let schedules: [ScheduleRow]
    let canEdit: Bool
    let open: (SettingsEditor) -> Void

    init(schedules: [ScheduleRow], canEdit: Bool, open: @escaping (SettingsEditor) -> Void) {
        self.schedules = schedules
        self.canEdit = canEdit
        self.open = open
    }

    var body: some View {
        SettingsSection("Medications & supplements", note: "schedules") {
            if schedules.isEmpty {
                SettingsRow("No schedules yet", detail: "Add one and the Log tab can remind you.") { EmptyView() }
            }
            ForEach(schedules) { schedule in
                SettingsLinkRow(schedule.title, detail: schedule.detail, enabled: canEdit,
                                action: { open(.schedule(schedule, supplement: schedule.isSupplement)) }) {
                    if schedule.isSupplement { SettingsTag("supplement") }
                }
            }
            HStack(spacing: 8) {
                MGButton("+ Medication", style: .ghost) { open(.schedule(nil, supplement: false)) }
                MGButton("+ Supplement", style: .ghost) { open(.schedule(nil, supplement: true)) }
            }
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.4)
            .padding(.vertical, 10)
            LogHint("Reminders only. No dosing advice.")
        }
    }
}

// MARK: Drink presets (APP-070)

struct SettingsPresetsSection: View {
    let presets: [DrinkPreset]
    let canEdit: Bool
    let open: (SettingsEditor) -> Void

    init(presets: [DrinkPreset], canEdit: Bool, open: @escaping (SettingsEditor) -> Void) {
        self.presets = presets
        self.canEdit = canEdit
        self.open = open
    }

    var body: some View {
        SettingsSection("Drink presets", note: "caffeine per serving") {
            ForEach(presets) { preset in
                SettingsLinkRow(preset.name, enabled: canEdit, action: { open(.preset(preset)) }) {
                    SettingsValueText("\(LogText.number(preset.caffeineMg)) mg")
                }
            }
            MGButton("+ Add a preset", style: .ghost) { open(.preset(nil)) }
                .disabled(!canEdit)
                .opacity(canEdit ? 1 : 0.4)
                .padding(.vertical, 10)
        }
    }
}

// MARK: Quick-log surfaces (APP-016)

struct SettingsSurfacesSection: View {
    let toggles: [ToggleState]
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(toggles: [ToggleState], canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.toggles = toggles
        self.canEdit = canEdit
        self.send = send
    }

    var body: some View {
        SettingsSection("Quick-log surfaces", note: "widget · Action Button · strap") {
            if toggles.isEmpty {
                SettingsRow("None available yet") { EmptyView() }
            }
            ForEach(toggles) { toggle in
                // The toggle's intent already carries the NEW value (same pattern as Today's switches).
                SettingsToggleRow(toggle.title, detail: toggle.detail, isOn: toggle.isOn,
                                  enabled: toggle.enabled && canEdit, reason: toggle.disabledReason,
                                  onChange: { _ in send(toggle.intent) })
            }
        }
    }
}

// MARK: Notifications (APP-363) — the quiet-hours and cap rows stay hidden while they are placeholders (R8p S6)

struct SettingsNotificationsSection: View {
    let rows: [LabeledValue]
    let toggles: [ToggleState]
    /// T9841: one "Skip: ..." switch per kind of notification (an alarm's is disabled with its reason).
    let skips: [ToggleState]
    let arePlaceholders: Bool
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(rows: [LabeledValue], toggles: [ToggleState], skips: [ToggleState] = [], arePlaceholders: Bool, canEdit: Bool,
         send: @escaping (UIIntent) -> Void) {
        self.rows = rows
        self.toggles = toggles
        self.skips = skips
        self.arePlaceholders = arePlaceholders
        self.canEdit = canEdit
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        SettingsSection("Notifications", note: "quiet hours · daily cap · skip any kind") {
            ForEach(toggles) { toggle in
                SettingsToggleRow(toggle.title, detail: toggle.detail, isOn: toggle.isOn,
                                  enabled: toggle.enabled && canEdit, reason: toggle.disabledReason,
                                  onChange: { _ in send(toggle.intent) })
            }
            // T9841: every kind of notification has a switch to skip it on purpose (never posted, never buzzes the strap).
            ForEach(skips) { toggle in
                SettingsToggleRow(toggle.title, detail: toggle.detail, isOn: toggle.isOn,
                                  enabled: toggle.enabled && canEdit, reason: toggle.disabledReason,
                                  onChange: { _ in send(toggle.intent) })
            }
            if arePlaceholders {
                // R8p (S6): the stand-in rows and their PLACEHOLDER tags are hidden until the policy is real: one plain line.
                Text("Quiet hours and the daily cap are not adjustable yet.")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
            } else {
                ForEach(rows) { row in
                    SettingsRow(row.label, detail: row.caption) {
                        ValueView(row.value, size: .small)
                    }
                }
            }
        }
    }
}

// MARK: Theme (UX §1.1)

struct SettingsThemeSection: View {
    let selected: ThemeSetting
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(selected: ThemeSetting, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.selected = selected
        self.canEdit = canEdit
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        SettingsSection("Theme", note: "follow the day by default") {
            ForEach(ThemeSetting.allCases, id: \.self) { setting in
                Button { send(.setTheme(setting)) } label: {
                    SettingsRow(setting.title, detail: explanation(setting)) {
                        Image(systemName: selected == setting ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(selected == setting ? colors.focusText.color : colors.mute.color)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .opacity(canEdit ? 1 : 0.55)
                .accessibilityAddTraits(selected == setting ? .isSelected : [])
            }
        }
    }

    private func explanation(_ setting: ThemeSetting) -> String {
        switch setting {
        // T24 (2026-10-13): was "... Satin Emerald from four hours before bedtime." — true only for the first,
        // lighter stage (PhaseClock's "sundown"); the code's deep Emerald low, the look Mo picked for "dark mode",
        // starts an hour after bedtime (`testEmeraldLowStartsOneHourAfterBedtime`), not four hours before it.
        case .followDay: return "Cream by day, Satin Emerald from four hours before bedtime, Emerald low from an hour after."
        case .cream: return "Always the cream paper."
        case .emerald: return "Always Emerald low."
        case .followSystem: return "Light mode is cream, dark mode is Satin Emerald."
        }
    }
}

// MARK: Research (UX §14, D7)

struct SettingsResearchSection: View {
    let shown: Bool
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(shown: Bool, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.shown = shown
        self.canEdit = canEdit
        self.send = send
    }

    var body: some View {
        SettingsSection("Research", note: "dotted tag") {
            SettingsToggleRow("Show research rows", detail: "Methods and streams marked research stay visible.",
                              isOn: shown, enabled: canEdit, reason: SettingsIntents.sampleReason,
                              onChange: { send(.setResearchRows($0)) })
            // 2026-10-11: the 16-flag unlock is gone (it wrote '2' = R22 off on fw 50.42.1.0). The one R22 write lives
            // on Strap & sync behind its confirm sheet.
        }
    }
}

// MARK: Top bar (T142, Mo 2026-10-12)

struct SettingsTopBarSection: View {
    let hidden: Bool
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(hidden: Bool, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.hidden = hidden
        self.canEdit = canEdit
        self.send = send
    }

    var body: some View {
        SettingsSection("Top bar", note: "shown by default") {
            SettingsToggleRow("Hide the \"Working on\" bars",
                              detail: "The moving bars for uploading, processing and waiting on the PC. The work still runs.",
                              isOn: hidden, enabled: canEdit, reason: SettingsIntents.sampleReason,
                              onChange: { send(.setHideWorkingBars($0)) })
        }
    }
}

// MARK: Methods keep / drop (UX §11)

struct SettingsMethodsSection: View {
    let droppedCount: Int
    let openExplore: () -> Void

    init(droppedCount: Int, openExplore: @escaping () -> Void) {
        self.droppedCount = droppedCount
        self.openExplore = openExplore
    }

    var body: some View {
        SettingsSection("Methods", note: "keep · drop") {
            SettingsRow("Dropped methods", detail: "Drop hides a method; it never deletes it. Restore one from Explore.") {
                SettingsValueText(droppedCount == 0 ? "none" : "\(droppedCount)")
            }
            SettingsLinkRow("Open Explore", action: openExplore) { EmptyView() }
        }
    }
}

// MARK: Sample data (BRIEF hard rule)

struct SettingsSampleSection: View {
    let isOn: Bool
    let send: (UIIntent) -> Void

    init(isOn: Bool, send: @escaping (UIIntent) -> Void) {
        self.isOn = isOn
        self.send = send
    }

    var body: some View {
        SettingsSection("Sample data", note: "off by default") {
            SettingsToggleRow("Show sample data",
                              detail: "For looking around only. Every screen shows a SAMPLE banner, logging is switched off, and nothing is saved or sent to your PC.",
                              isOn: isOn, onChange: { send(.setSampleData($0)) })
        }
    }
}

// MARK: PC Lab (Strap & sync and Decode lab are rows of "More screens" now, R8p S7)

struct SettingsPCSection: View {
    let canEdit: Bool
    let statusWord: String
    let send: (UIIntent) -> Void

    init(canEdit: Bool, statusWord: String = "", send: @escaping (UIIntent) -> Void) {
        self.canEdit = canEdit
        self.statusWord = statusWord
        self.send = send
    }

    var body: some View {
        SettingsSection("PC Lab", note: "Tailscale") {
            // r8h T5: the row says where the PC stands; one name, "PC Lab".
            SettingsRow(statusWord.isEmpty ? "PC Lab" : "PC Lab · \(statusWord)",
                        detail: "Your data goes only to your own PC, over Tailscale. Nothing else receives it.") {
                MGButton(statusWord == "not paired" || statusWord.isEmpty ? "Pair PC Lab" : "Pair again", style: .ghost) { send(.pairPC) }
                    .disabled(!canEdit)
                    .opacity(canEdit ? 1 : 0.4)
            }
        }
    }
}

// MARK: Privacy (APP-116)

struct SettingsPrivacySection: View {
    let lines: [String]

    init(lines: [String]) {
        self.lines = lines
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        SettingsSection("Privacy") {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
            }
        }
    }
}

// MARK: Export (APP-114, ARCHITECTURE §4.12)

struct SettingsExportSection: View {
    let action: ActionState
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(action: ActionState, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.action = action
        self.canEdit = canEdit
        self.send = send
        _from = State(initialValue: Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date())
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @State private var from: Date
    @State private var to = Date()

    private var enabled: Bool { canEdit && action.enabled }

    var body: some View {
        SettingsSection("Export", note: "JSON · CSV · to Files") {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                DatePicker("To", selection: $to, in: min(from, Date())...Date(), displayedComponents: .date)
                HStack(spacing: 8) {
                    MGButton("\(action.title) these days", style: .filled, action: exportRange)
                    MGButton("Everything", style: .ghost) { send(action.intent ?? .export) }
                }
                // r9v (S8): no size guess; the real size of what was written is in the "Exported ..." notice afterwards.
                LogHint("Everything runs from your first stored day, at most \(ExportEstimate.maxDays) days back. "
                        + "The size depends on what is stored; the notice after the export gives the real size.")
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
                if !enabled {
                    LogHint(canEdit ? (action.disabledReason ?? "Export isn't available right now.")
                                    : SettingsIntents.sampleReason)
                }
                // R8p (S8): one sentence on where the files go (the app asks for a folder in Files; it does not send to the PC).
                LogHint("Saves one folder, \"MG export <from> to <to>\", to the place you choose in Files: days/<date>/summary.json, events.jsonl, series.json and streams/*.csv; removed entries are included, marked removed.")
            }
            .foregroundStyle(colors.ink.color)
            .tint(colors.focus.color)
            .padding(.vertical, 10)
        }
    }

    private func exportRange() {
        guard enabled else { return }
        send(SettingsIntents.exportRange(from: LocalDay(date: from, calendar: calendar),
                                         to: LocalDay(date: to, calendar: calendar)))
    }
}

// MARK: About (W10, 2026-10-11; version names and What's new at the W10 merge, 11:20 PM)

/// "HealthApp 0.5 'Your data, filled' · build 202610112345" from the installed bundle (CFBundleShortVersionString,
/// HAReleaseName, CFBundleVersion; MGContext `AboutPresenter`), and What's new: every version from app/docs/CHANGELOG.md,
/// newest first, the one on this phone marked. It said "HealthApp 0.1 (build N)" before the merge.
struct SettingsAboutSection: View {
    let mapLine: String
    @State private var showsWhatsNew = false
    @Environment(\.mgSend) private var mgSend

    var body: some View {
        SettingsSection("About") {
            SettingsRow(AboutPresenter.line(info: Bundle.main.infoDictionary)) { EmptyView() }
            if !mapLine.isEmpty { SettingsRow(mapLine) { EmptyView() } }      // T9972
            SettingsLinkRow("What's new", detail: "Every version, what changed and which build is on this phone.",
                            action: { showsWhatsNew = true }) { EmptyView() }
        }
        .sheet(isPresented: $showsWhatsNew) {
            // r8h U1: a Done button and a drag indicator, and the real send (it was a no-op, so rows with an intent were dead).
            InfoScreenView(state: AboutPresenter.whatsNew(info: Bundle.main.infoDictionary), send: mgSend,
                           onDone: { showsWhatsNew = false })
                .presentationDragIndicator(.visible)
        }
    }
}

/// R8e (S3): the Smart-wake window. The number changes at once on this screen and the intent goes out once, half a second
/// after the last tap (the system stepper read the old state between taps, so three quick taps made +5, not +15, and every
/// tap saved and asked the compute engine). 44 pt buttons.
/// T9841 (R-097): the smart-wake mode picker. Choosing a mode keeps the gate and the minimum rest share as they were.
private struct SettingsSmartWakeModeMenu: View {
    let state: SettingsState
    let send: (UIIntent) -> Void

    var body: some View {
        Menu {
            ForEach(SmartWakeModes.all) { mode in
                Button(mode.title) {
                    send(.editSetting(.smartWake(mode: mode.id, gateMinutes: state.smartWakeGateMinutes,
                                          restPercent: state.smartWakeRestPercent)))
                }
            }
        } label: {
            SettingsValueText(SmartWakeModes.title(state.smartWakeMode))
        }
        .accessibilityLabel("Smart-wake mode, \(SmartWakeModes.title(state.smartWakeMode))")
    }
}

/// T9841: the earliest time the ring may sound in "Not before a time" mode, in 15-minute steps (6:00 AM when not set).
private struct SettingsSmartWakeGateStepper: View {
    let state: SettingsState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    private func step(_ delta: Int) {
        let base = state.smartWakeGateMinutes ?? 360
        let next = min(max(base + delta, 0), 1439)
        send(.editSetting(.smartWake(mode: state.smartWakeMode, gateMinutes: next, restPercent: state.smartWakeRestPercent)))
    }

    var body: some View {
        HStack(spacing: MGSpace.s) {
            button("minus", delta: -15, label: "Earlier")
            SettingsValueText(SmartWakeModes.gateWords(minutes: state.smartWakeGateMinutes), muted: state.smartWakeGateMinutes == nil)
                .frame(minWidth: 72)
            button("plus", delta: 15, label: "Later")
        }
        .accessibilityElement(children: .contain)
    }

    private func button(_ symbol: String, delta: Int, label: String) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(colors.ink.color)
        }
        .accessibilityLabel(label)
    }
}

private struct SettingsWakeWindowStepper: View {
    let minutes: Int
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    /// The value being stepped; nil = follow the state.
    @State private var local: Int?
    @State private var pending: Task<Void, Never>?

    var body: some View {
        HStack(spacing: MGSpace.s) {
            stepButton("minus", delta: -5, label: "Shorter window")
            SettingsValueText("\(local ?? minutes) min")
                .frame(minWidth: 56)
            stepButton("plus", delta: 5, label: "Longer window")
        }
        .onChange(of: minutes) { _, new in
            if local == new { local = nil }          // the state caught up
        }
        .accessibilityElement(children: .contain)
    }

    private func stepButton(_ symbol: String, delta: Int, label: String) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(colors.ink.color)
                .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                .background(Circle().fill(colors.chip.color))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func step(_ delta: Int) {
        let next = min(45, max(10, (local ?? minutes) + delta))
        local = next
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            send(.setWakeWindow(minutes: next))
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { local = nil }       // a refused or clamped value shows the real one again
        }
    }
}
