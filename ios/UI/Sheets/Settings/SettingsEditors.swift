import SwiftUI
import MGContext
import MGDesign
import MGDomain

// The editor sheets opened from Settings. Each sends ONE kind of intent and then closes. While SAMPLE data is on they
// show the reason and cannot save (main's rule g).

/// Which editor is open (presentation only; values change through intents).
enum SettingsEditor: Identifiable {
    case profile(LabeledValue)
    case latestWake(weekday: Int)
    case needOverride
    case schedule(ScheduleRow?, supplement: Bool)
    case preset(DrinkPreset?)
    case presetEntry(PresetListKind, PresetEntry?)
    case drinkEntry(DrinkEntry?)
    case skinType
    case vitaminDLocation

    var id: String {
        switch self {
        case .profile(let row): return "profile:" + row.id
        case .latestWake(let weekday): return "wake:\(weekday)"
        case .needOverride: return "need"
        case .schedule(let row, let supplement):
            return "schedule:" + (row?.id ?? (supplement ? "new-supplement" : "new-medication"))
        case .preset(let preset): return "preset:" + (preset?.name ?? "new")
        case .presetEntry(let list, let entry): return "list:" + list.rawValue + ":" + (entry?.id ?? "new")
        case .drinkEntry(let drink): return "list:drinks:" + (drink?.id ?? "new")
        case .skinType: return "skin-type"
        case .vitaminDLocation: return "vitamin-d-location"
        }
    }
}

/// Picks the editor for a `SettingsEditor`.
struct SettingsEditorSheet: View {
    let editor: SettingsEditor
    let state: SettingsState
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(editor: SettingsEditor, state: SettingsState, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.editor = editor
        self.state = state
        self.canEdit = canEdit
        self.send = send
    }

    var body: some View {
        switch editor {
        case .profile(let row):
            SettingsProfileEditor(row: row, canEdit: canEdit, send: send)
        case .latestWake(let weekday):
            SettingsWakeEditor(weekday: weekday, current: state.latestWake, canEdit: canEdit, send: send)
        case .needOverride:
            SettingsNeedEditor(current: state.needOverride, canEdit: canEdit, send: send)
        case .schedule(let row, let supplement):
            SettingsScheduleEditor(row: row, supplement: supplement, canEdit: canEdit, send: send)
        case .preset(let preset):
            SettingsPresetEditor(preset: preset, existingNames: state.drinkPresets.map { $0.name }, canEdit: canEdit,
                                 send: send)
        case .presetEntry(let list, let entry):
            SettingsPresetEntryEditor(list: list, entry: entry, canEdit: canEdit, send: send)
        case .drinkEntry(let drink):
            SettingsDrinkEntryEditor(drink: drink, canEdit: canEdit, send: send)
        case .skinType:
            SettingsSkinTypeEditor(current: state.fitzpatrickSkinType, canEdit: canEdit, send: send)
        case .vitaminDLocation:
            SettingsVitaminDLocationEditor(current: state.vitaminDLocation, canEdit: canEdit, send: send)
        }
    }
}

/// Title, Cancel, Save, then the editor's own controls.
struct SettingsSheetFrame<Content: View>: View {
    let title: String
    let saveTitle: String
    let canSave: Bool
    /// Why Save is disabled (shown at the bottom).
    let reason: String?
    let onSave: () -> Void
    let content: Content

    init(title: String, saveTitle: String = "Save", canSave: Bool, reason: String?, onSave: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.saveTitle = saveTitle
        self.canSave = canSave
        self.reason = reason
        self.onSave = onSave
        self.content = content()
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mgColors) private var colors

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(title)
                        .mgFont(.headline)
                        .foregroundStyle(colors.ink.color)
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MGButton("Cancel", style: .ghost) { dismiss() }
                    MGButton(saveTitle, style: .filled) {
                        onSave()
                        dismiss()
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.4)
                }
                content
                if !canSave, let reason {
                    LogHint(reason)
                }
            }
            .foregroundStyle(colors.ink.color)
            .tint(colors.focus.color)
            .padding(MGSpace.gutter)
        }
        .background(colors.sheet.color.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationBackground(colors.sheet.color)
    }
}

// MARK: - Profile field

struct SettingsProfileEditor: View {
    let row: LabeledValue
    let canEdit: Bool
    let send: (UIIntent) -> Void

    private enum Kind {
        case birthDate, sex, number(unit: String), height, weight
    }

    init(row: LabeledValue, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.row = row
        self.canEdit = canEdit
        self.send = send
        var initial = ""
        if case .value(let text, _, _, _, _) = row.value { initial = text }
        _text = State(initialValue: initial)
        _sex = State(initialValue: initial.isEmpty ? nil : initial.lowercased())
        let known = LocalDay(iso: initial)
        _birthOn = State(initialValue: known != nil)
        _birth = State(initialValue: known?.start(in: TimeZone.current)
            ?? Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date())
    }
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var sex: String?
    @State private var birthOn: Bool
    @State private var birth: Date

    private var kind: Kind {
        switch row.id {
        case "birth_date": return .birthDate
        case "sex": return .sex
        case "height_cm": return .height
        case "weight_kg": return .weight
        case "hr_max", "hrmax", "hr_rest": return .number(unit: "bpm")
        case "calorie_goal_kcal": return .number(unit: "kcal")
        default: return .number(unit: "")
        }
    }

    /// What would be sent; nil = clear the field.
    private var newText: String? {
        switch kind {
        case .birthDate: return birthOn ? LocalDay(date: birth, calendar: Calendar.current).iso : nil
        case .sex: return sex
        case .number: return LogText.parse(text).map { LogText.number($0) }
        case .height, .weight: return text.trimmingCharacters(in: .whitespaces)   // AppModel parses (ProfileUnits)
        }
    }

    private var isValid: Bool {
        switch kind {
        case .birthDate, .sex: return true
        case .number: return LogText.parse(text).map { $0 > 0 } ?? false
        case .height: return ProfileUnits.parseHeightCm(text) != nil
        case .weight: return ProfileUnits.parseWeightKg(text) != nil
        }
    }

    private var reasonText: String {
        switch kind {
        case .height: return "Enter a height like 5'8 or 172 cm, or use Clear."
        case .weight: return "Enter a weight like 155 lb or 70 kg, or use Clear."
        default: return "Enter a number above zero, or use Clear."
        }
    }

    var body: some View {
        SettingsSheetFrame(title: row.label, canSave: canEdit && isValid,
                           reason: canEdit ? reasonText : SettingsIntents.sampleReason,
                           onSave: { send(editIntent(text: newText)) }) {
            editorBody
            MGButton("Clear this field", style: .ghost) {
                send(editIntent(text: nil))
                dismiss()
            }
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.4)
        }
    }

    private func editIntent(text: String?) -> UIIntent {
        if row.id == "calorie_goal_kcal" {
            return SettingsPresenter.calorieGoalIntent(text.flatMap { LogText.parse($0) })
        }
        return SettingsIntents.profile(id: row.id, text: text)
    }

    @ViewBuilder private var editorBody: some View {
        switch kind {
        case .birthDate:
            Toggle("Birth date is set", isOn: $birthOn)
            if birthOn {
                DatePicker("Birth date", selection: $birth, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
            }
        case .sex:
            LogChoiceChips(options: [(id: "male", label: "male"), (id: "female", label: "female"),
                                     (id: "other", label: "other")],
                           selection: $sex)
        case .number(let unit):
            HStack(spacing: 8) {
                LogTextField(row.label, text: $text, decimal: true)
                if !unit.isEmpty { LogUnitLabel(unit) }
            }
        case .height, .weight:
            LogTextField(row.label, text: $text)   // text keyboard: 5'8 needs an apostrophe
        }
    }
}

// MARK: - Must be up by

struct SettingsWakeEditor: View {
    let weekday: Int
    let current: [WeekdayWake]
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(weekday: Int, current: [WeekdayWake], canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.weekday = weekday
        self.current = current
        self.canEdit = canEdit
        self.send = send
        _days = State(initialValue: [weekday])
        let existing = current.first(where: { $0.weekday == weekday })?.time
        let calendar = Calendar.current
        let base = calendar.date(bySettingHour: existing?.hour ?? 7, minute: existing?.minute ?? 0, second: 0,
                                 of: Date()) ?? Date()
        _time = State(initialValue: base)
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @State private var days: Set<Int>
    @State private var time: Date

    var body: some View {
        SettingsSheetFrame(title: "Must be up by", canSave: canEdit && !days.isEmpty,
                           reason: canEdit ? "Pick at least one day." : SettingsIntents.sampleReason,
                           onSave: save) {
            LogFormLabel("Days")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(SettingsWeekday.order, id: \.self) { day in
                    Chip(SettingsWeekday.short[day] ?? "", selected: days.contains(day)) {
                        if days.contains(day) {
                            if days.count > 1 { _ = days.remove(day) }
                        } else {
                            _ = days.insert(day)
                        }
                    }
                }
            }
            DatePicker("Latest wake time", selection: $time, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.locale, AlarmTimeLocale.picker)
                .frame(maxWidth: .infinity, maxHeight: 130)
            LogHint("Smart wake rings by this time. A blank day means no wake plan that morning.")
            MGButton("Clear these days", style: .ghost) {
                for day in days.sorted() { send(.setLatestWake(weekday: day, time: nil)) }
                dismiss()
            }
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.4)
        }
    }

    private func save() {
        guard canEdit else { return }
        let c = calendar.dateComponents([.hour, .minute], from: time)
        let value = TimeOfDay(hour: c.hour ?? 7, minute: c.minute ?? 0)
        for day in days.sorted() { send(.setLatestWake(weekday: day, time: value)) }
    }
}

// MARK: - Sleep need override

struct SettingsNeedEditor: View {
    let current: DisplayValue?
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(current: DisplayValue?, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.current = current
        self.canEdit = canEdit
        self.send = send
        var existing: Int?
        if let current, case .value(let text, _, _, _, _) = current { existing = SettingsNeedEditor.minutes(in: text) }
        _useOverride = State(initialValue: existing != nil)
        _minutes = State(initialValue: Double(existing ?? 480))
    }
    @State private var useOverride: Bool
    @State private var minutes: Double

    /// "8 h 10" → 490, "7 h" → 420, "45 min" → 45; nil when the text is neither.
    static func minutes(in text: String) -> Int? {
        let tokens = text.split(separator: " ").map(String.init)
        var hours = 0
        var mins = 0
        var found = false
        var index = 0
        while index < tokens.count {
            if let number = Int(tokens[index]), index + 1 < tokens.count {
                if tokens[index + 1] == "h" {
                    hours = number
                    found = true
                    index += 2
                    // "8 h 10": a bare number after the h is minutes
                    if index < tokens.count, let extra = Int(tokens[index]) {
                        mins = extra
                        index += 1
                    }
                    continue
                }
                if tokens[index + 1] == "min" {
                    mins = number
                    found = true
                    index += 2
                    continue
                }
            }
            index += 1
        }
        return found ? hours * 60 + mins : nil
    }

    var body: some View {
        SettingsSheetFrame(title: "Sleep need", canSave: canEdit,
                           reason: SettingsIntents.sampleReason,
                           onSave: { send(SettingsIntents.needOverride(minutes: useOverride ? Int(minutes) : nil)) }) {
            Toggle("Use my own number instead of the one worked out from my history", isOn: $useOverride)
            if useOverride {
                LogStepperRow(title: "Sleep I need", valueText: MGFormat.duration(minutes: Int(minutes)),
                              value: $minutes, range: 240...720, step: 15)
            }
            LogHint("Tonight's need is this number, less any nap credit. Sleep debt is worked out against it and shown on its own.")
        }
    }
}

// MARK: - Medication / supplement schedule

struct SettingsTimeDraft: Identifiable, Equatable {
    let id = UUID()
    var date: Date
}

struct SettingsScheduleEditor: View {
    let row: ScheduleRow?
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(row: ScheduleRow?, supplement: Bool, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.row = row
        self.canEdit = canEdit
        self.send = send
        let isSupplement = row?.isSupplement ?? supplement
        let sc = row?.schedule
        _name = State(initialValue: sc?.name ?? row?.title ?? "")
        let initialKind: MedSchedule.Kind = sc?.kind ?? (isSupplement ? .supplement : .prescription)
        _kind = State(initialValue: initialKind)
        _doseText = State(initialValue: sc?.dose.map { LogText.number($0) } ?? "")
        _unitText = State(initialValue: sc?.unit ?? "mg")
        _reminder = State(initialValue: sc?.reminder ?? true)
        if let d = sc?.days, !d.isEmpty {
            _days = State(initialValue: Set(SettingsScheduleEditor.weekdayCodes.filter { d.contains($0.value) }.map(\.key)))
        }
        // Medications list (tracker #42): what it is for, started / stopped, as needed.
        _purpose = State(initialValue: sc?.purpose ?? "")
        _asNeeded = State(initialValue: sc?.asNeeded ?? false)
        _hasStarted = State(initialValue: sc?.started != nil)
        _started = State(initialValue: sc?.started?.start(in: .current) ?? Date())
        _hasStopped = State(initialValue: sc?.stopped != nil)
        _stopped = State(initialValue: sc?.stopped?.start(in: .current) ?? Date())
        let calendar = Calendar.current
        let drafts: [SettingsTimeDraft] = (sc?.times ?? SettingsScheduleEditor.times(in: row?.detail ?? "")).compactMap { text in
            let bits = text.split(separator: ":")
            guard bits.count == 2, let h = Int(bits[0]), let m = Int(bits[1]),
                  let date = calendar.date(bySettingHour: h, minute: m, second: 0, of: Date()) else { return nil }
            return SettingsTimeDraft(date: date)
        }
        _times = State(initialValue: drafts)
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @State private var name: String
    @State private var kind: MedSchedule.Kind?
    @State private var doseText = ""
    @State private var unitText = "mg"
    @State private var times: [SettingsTimeDraft]
    @State private var days: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
    @State private var reminder = true
    @State private var purpose: String
    @State private var asNeeded: Bool
    @State private var hasStarted: Bool
    @State private var started: Date
    @State private var hasStopped: Bool
    @State private var stopped: Date

    /// "daily · 7:15 AM, 7:00 PM" → ["07:15", "19:00"] (the presenter writes the detail line in 12-hour words; this
    /// reads the clock times back as stored "HH:MM"; an older 24-hour "07:15" is returned as is).
    static func times(in detail: String) -> [String] {
        var out: [String] = []
        var rest = detail[...]
        while let range = rest.range(of: #"\b(1[0-2]|0?\d):[0-5]\d (AM|PM)\b|\b([01]?\d|2[0-3]):[0-5]\d\b"#,
                                     options: .regularExpression) {
            let text = String(rest[range])
            let bits = text.split(whereSeparator: { $0 == ":" || $0 == " " })
            if bits.count == 3, let h12 = Int(bits[0]) {
                let h = h12 % 12 + (bits[2] == "PM" ? 12 : 0)
                out.append((h < 10 ? "0\(h)" : "\(h)") + ":" + String(bits[1]))
            } else {
                out.append(text)
            }
            rest = rest[range.upperBound...]
        }
        return out
    }

    private static let weekdayCodes: [Int: MedSchedule.Weekday] = [
        1: .sun, 2: .mon, 3: .tue, 4: .wed, 5: .thu, 6: .fri, 7: .sat,
    ]

    private var canSave: Bool { canEdit && LogText.clean(name) != nil && !days.isEmpty }

    var body: some View {
        SettingsSheetFrame(title: row == nil ? "New schedule" : "Edit schedule", canSave: canSave,
                           reason: canEdit ? "Give it a name and at least one day." : SettingsIntents.sampleReason,
                           onSave: save) {
            scheduleBasics
            scheduleList
            if !asNeeded {
                scheduleTimes
                scheduleDays
            }
            scheduleOptions
            if let row {
                MGButton("Remove this schedule", style: .ghost) {
                    send(SettingsIntents.removeSchedule(id: row.id))
                    dismiss()
                }
                .disabled(!canEdit)
                .opacity(canEdit ? 1 : 0.4)
            }
        }
    }

    // The editor is cut into four parts: a ViewBuilder takes at most ten children.

    @ViewBuilder private var scheduleBasics: some View {
        VStack(alignment: .leading, spacing: 12) {
            LogTextField("Name and strength", text: $name)
            LogChoiceChips(options: [(id: MedSchedule.Kind.prescription, label: "prescription"),
                                     (id: MedSchedule.Kind.supplement, label: "supplement"),
                                     (id: MedSchedule.Kind.otc, label: "over the counter")],
                           selection: $kind)
            HStack(spacing: 8) {
                LogTextField("Dose (optional)", text: $doseText, decimal: true)
                LogTextField("Unit", text: $unitText)
            }
        }
    }

    /// The medications-list fields (tracker #42, 2026-10-11): sent to the PC with the profile (contract v0.5).
    @ViewBuilder private var scheduleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            LogTextField("What it's for (optional)", text: $purpose)
            Toggle("Taken as needed (no fixed times)", isOn: $asNeeded)
            Toggle("Started on", isOn: $hasStarted)
            if hasStarted {
                DatePicker("Started", selection: $started, in: ...Date(), displayedComponents: .date)
                    .environment(\.locale, AlarmTimeLocale.picker)
            }
            Toggle("Stopped on", isOn: $hasStopped)
            if hasStopped {
                DatePicker("Stopped", selection: $stopped, in: ...Date(), displayedComponents: .date)
                    .environment(\.locale, AlarmTimeLocale.picker)
                LogHint("A stopped medication stays in the list (history); its reminders stop.")
            }
        }
    }

    @ViewBuilder private var scheduleTimes: some View {
        VStack(alignment: .leading, spacing: 8) {
            LogFormLabel("Times")
            ForEach($times) { $draft in
                HStack {
                    DatePicker("Time", selection: $draft.date, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.locale, AlarmTimeLocale.picker)
                    Spacer()
                    Button {
                        times.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove this time")
                }
            }
            MGButton("+ Add a time", style: .ghost) {
                let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
                times.append(SettingsTimeDraft(date: morning))
            }
        }
    }

    @ViewBuilder private var scheduleDays: some View {
        VStack(alignment: .leading, spacing: 8) {
            LogFormLabel("Days")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(SettingsWeekday.order, id: \.self) { day in
                    Chip(SettingsWeekday.short[day] ?? "", selected: days.contains(day)) {
                        if days.contains(day) { _ = days.remove(day) } else { _ = days.insert(day) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var scheduleOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Remind me", isOn: $reminder)
            Toggle("Buzz the strap too", isOn: .constant(false))
                .disabled(true)
            LogHint("Strap buzz is off; reminders use the iPhone only. Reminder only, no dosing advice.")
        }
    }

    private func save() {
        guard canSave else { return }
        let id = row?.id ?? "sched_" + UUID().uuidString.lowercased()
        let clockTimes: [String] = times.map { draft in
            let c = calendar.dateComponents([.hour, .minute], from: draft.date)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }.sorted()
        let chosenDays: [MedSchedule.Weekday]? = days.count == 7
            ? nil
            : SettingsWeekday.order.filter { days.contains($0) }.compactMap { SettingsScheduleEditor.weekdayCodes[$0] }
        let schedule = MedSchedule(id: id, name: LogText.clean(name) ?? name, kind: kind, dose: LogText.parse(doseText),
                                   unit: LogText.clean(unitText),
                                   times: asNeeded || clockTimes.isEmpty ? nil : clockTimes,
                                   days: asNeeded ? nil : chosenDays, reminder: asNeeded || hasStopped ? false : reminder,
                                   buzz: nil, purpose: LogText.clean(purpose),
                                   started: hasStarted ? LocalDay(date: started, calendar: calendar) : nil,
                                   stopped: hasStopped ? LocalDay(date: stopped, calendar: calendar) : nil,
                                   asNeeded: asNeeded ? true : nil)
        send(SettingsIntents.saveSchedule(schedule))
    }
}

// MARK: - Drink preset

struct SettingsPresetEditor: View {
    let preset: DrinkPreset?
    let existingNames: [String]
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(preset: DrinkPreset?, existingNames: [String], canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.preset = preset
        self.existingNames = existingNames
        self.canEdit = canEdit
        self.send = send
        _name = State(initialValue: preset?.name ?? "")
        _mgText = State(initialValue: preset.map { LogText.number($0.caffeineMg) } ?? "")
    }
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var mgText: String

    private var mg: Double? { LogText.parse(mgText).flatMap { $0 > 0 ? $0 : nil } }
    private var cleanName: String? { LogText.clean(name) }
    private var canSave: Bool { canEdit && cleanName != nil && mg != nil }

    /// Saving under another preset's name replaces that preset.
    private var replacesOther: Bool {
        guard let cleanName else { return false }
        return existingNames.contains(cleanName) && cleanName != preset?.name
    }

    var body: some View {
        SettingsSheetFrame(title: preset == nil ? "New drink preset" : "Edit drink preset", canSave: canSave,
                           reason: canEdit ? "Give it a name and the caffeine in mg." : SettingsIntents.sampleReason,
                           onSave: save) {
            LogTextField("Name", text: $name)
            HStack(spacing: 8) {
                LogTextField("Caffeine", text: $mgText, decimal: true)
                LogUnitLabel("mg")
            }
            if replacesOther {
                LogHint("A preset with this name already exists; saving replaces it.")
            }
            if let preset {
                MGButton("Remove this preset", style: .ghost) {
                    send(SettingsIntents.removePreset(name: preset.name))
                    dismiss()
                }
                .disabled(!canEdit)
                .opacity(canEdit ? 1 : 0.4)
            }
        }
    }

    private func save() {
        guard canSave, let cleanName, let mg else { return }
        send(SettingsIntents.savePreset(DrinkPreset(name: cleanName, caffeineMg: mg)))
        // Renamed: the old name goes away (new first, so a failed save never loses the preset).
        if let old = preset?.name, old != cleanName {
            send(SettingsIntents.removePreset(name: old))
        }
    }
}

// MARK: - Sun vitamin D inputs

struct SettingsSkinTypeEditor: View {
    let current: Int?
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(current: Int?, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.current = current
        self.canEdit = canEdit
        self.send = send
        _answers = State(initialValue: [Int](repeating: current ?? 0, count: SkinTypeQuiz.questions.count))
    }

    @Environment(\.dismiss) private var dismiss
    @State private var answers: [Int]

    private var result: SkinTypeQuiz.SkinType? { SkinTypeQuiz.type(for: answers) }

    var body: some View {
        SettingsSheetFrame(title: "Skin type", canSave: canEdit && result != nil,
                           reason: canEdit ? "Answer all six questions." : SettingsIntents.sampleReason,
                           onSave: { send(SettingsIntents.skinType(answers: answers)) }) {
            ForEach(Array(SkinTypeQuiz.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 6) {
                    LogFormLabel("\(index + 1). \(question.prompt)")
                    Picker(question.prompt, selection: $answers[index]) {
                        Text("Choose").tag(0)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { option, label in
                            Text(label).tag(option + 1)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if let result { LogHint("Result: Fitzpatrick type \(result.roman).") }
            MGButton("Clear skin type", style: .ghost) {
                send(SettingsIntents.skinType(answers: nil))
                dismiss()
            }
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.4)
        }
    }
}

struct SettingsVitaminDLocationEditor: View {
    let current: VitaminDRoughLocation?
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(current: VitaminDRoughLocation?, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.current = current
        self.canEdit = canEdit
        self.send = send
        _name = State(initialValue: current?.name ?? "")
        _latitude = State(initialValue: current.map { String(format: "%.1f", $0.latitude) } ?? "")
        _longitude = State(initialValue: current.map { String(format: "%.1f", $0.longitude) } ?? "")
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var latitude: String
    @State private var longitude: String

    private var lat: Double? { SettingsCoordinate.parse(latitude) }
    private var lon: Double? { SettingsCoordinate.parse(longitude) }
    private var canSave: Bool {
        canEdit && LogText.clean(name) != nil && lat.map { (-90...90).contains($0) } == true
            && lon.map { (-180...180).contains($0) } == true
    }

    var body: some View {
        SettingsSheetFrame(title: "Rough location", canSave: canSave,
                           reason: canEdit ? "Enter a place, latitude -90 to 90, and longitude -180 to 180."
                                           : SettingsIntents.sampleReason,
                           onSave: save) {
            LogTextField("Place name", text: $name)
            HStack(spacing: 8) {
                SettingsCoordinateField("Latitude", text: $latitude)
                SettingsCoordinateField("Longitude", text: $longitude)
            }
            LogHint("Type a rough place and coordinates by hand. The app rounds both coordinates to one decimal and never reads GPS.")
            MGButton("Clear rough location", style: .ghost) {
                send(SettingsIntents.vitaminDLocation(name: nil, latitude: nil, longitude: nil))
                dismiss()
            }
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.4)
        }
    }

    private func save() {
        guard canSave, let lat, let lon else { return }
        send(SettingsIntents.vitaminDLocation(name: LogText.clean(name), latitude: lat, longitude: lon))
    }
}

/// R8e (S5): a coordinate can be negative (west and south), which `LogText.parse` refuses and the decimal pad cannot type.
enum SettingsCoordinate {
    /// "-122.4", "−122,4" (a typed minus sign or the Unicode one), "47.6". nil for empty, text, NaN or infinity.
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
        guard !t.isEmpty, let v = Double(t), v.isFinite else { return nil }
        return v
    }
}

/// A text field with the keyboard that has a minus key (`.numbersAndPunctuation`), styled like `LogTextField`.
struct SettingsCoordinateField: View {
    let title: String
    @Binding var text: String

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        TextField(text: $text, prompt: Text(title).foregroundStyle(colors.mute.color)) {
            Text(title)
        }
        .mgFont(.body)
        .foregroundStyle(colors.ink.color)
        .keyboardType(.numbersAndPunctuation)
        .formSubmit()                             // r9v (K1)
        .padding(.horizontal, 12)
        .frame(minHeight: MGSpace.tapTarget)
        .background(RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous).fill(colors.chip.color))
        .accessibilityLabel(title)
    }
}
