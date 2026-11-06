import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Round 5 (t9806, items C21 and 6): the editor for Mo's own Medications / Supplements / Drinks lists (PresetLists).
// Add, edit, remove. Supplements start empty (nothing is invented). The Log forms read the same lists ("From your list").
// Every save is one intent (`.savePresetEntry` / `.saveDrinkEntry` / `.removePresetEntry`), applied in AppModel+Settings.

private enum PresetListIntents {
    static func save(_ list: PresetListKind, _ entry: PresetEntry) -> UIIntent {
        .editSetting(.savePresetEntry(list: list, entry: entry))
    }
    static func save(_ drink: DrinkEntry) -> UIIntent { .editSetting(.saveDrinkEntry(drink)) }
    static func remove(_ list: PresetListKind, id: String) -> UIIntent {
        .editSetting(.removePresetEntry(list: list, id: id))
    }
}

/// The three lists in Settings › You, each with its rows and an add button.
struct SettingsPresetListsSection: View {
    let lists: PresetLists
    let canEdit: Bool
    let open: (SettingsEditor) -> Void

    init(lists: PresetLists, canEdit: Bool, open: @escaping (SettingsEditor) -> Void) {
        self.lists = lists
        self.canEdit = canEdit
        self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("My medications", note: "offered as \"From your list\" when you log") {
                ForEach(lists.medications) { entry in
                    SettingsLinkRow(entry.title, enabled: canEdit, action: { open(.presetEntry(.medications, entry)) }) {
                        SettingsValueText(entry.notes.isEmpty ? "edit" : entry.notes, muted: true)
                    }
                }
                addButton("+ Add a medication") { open(.presetEntry(.medications, nil)) }
            }
            SettingsSection("My supplements", note: lists.supplements.isEmpty ? "none yet; nothing is filled in for you"
                                                                              : "offered as chips when you log") {
                ForEach(lists.supplements) { entry in
                    SettingsLinkRow(entry.title, enabled: canEdit, action: { open(.presetEntry(.supplements, entry)) }) {
                        SettingsValueText(entry.notes.isEmpty ? "edit" : entry.notes, muted: true)
                    }
                }
                addButton("+ Add a supplement") { open(.presetEntry(.supplements, nil)) }
            }
            SettingsSection("My drinks", note: "caffeine drinks are offered when you log caffeine") {
                ForEach(lists.drinks) { drink in
                    SettingsLinkRow(drink.title, enabled: canEdit, action: { open(.drinkEntry(drink)) }) {
                        SettingsValueText(drink.caffeineText, muted: drink.caffeineMg == nil)
                    }
                }
                addButton("+ Add a drink") { open(.drinkEntry(nil)) }
            }
        }
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        MGButton(title, style: .ghost, action: action)
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.4)
            .padding(.vertical, 10)
    }
}

/// A medication or supplement: name, strength of one unit, unit, notes.
struct SettingsPresetEntryEditor: View {
    let list: PresetListKind
    let entry: PresetEntry?
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(list: PresetListKind, entry: PresetEntry?, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.list = list
        self.entry = entry
        self.canEdit = canEdit
        self.send = send
        _name = State(initialValue: entry?.name ?? "")
        _amountText = State(initialValue: entry?.amount.map { LogText.number($0) } ?? "")
        _unit = State(initialValue: entry?.unit ?? "mg")
        _notes = State(initialValue: entry?.notes ?? "")
    }
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var amountText: String
    @State private var unit: String
    @State private var notes: String

    private var singular: String { list == .medications ? "medication" : "supplement" }
    private var amount: Double? { LogText.parse(amountText) }
    /// A blank strength is fine ("not entered"); a typed one must be above zero.
    private var amountOK: Bool { amountText.trimmingCharacters(in: .whitespaces).isEmpty || (amount ?? 0) > 0 }
    private var canSave: Bool { canEdit && LogText.clean(name) != nil && amountOK }

    var body: some View {
        SettingsSheetFrame(title: entry == nil ? "New \(singular)" : "Edit \(singular)", canSave: canSave,
                           reason: canEdit ? "A name, and a strength above zero if you enter one."
                                           : SettingsIntents.sampleReason,
                           onSave: save) {
            LogTextField("Name", text: $name)
            HStack(spacing: 8) {
                LogTextField("Strength of one unit (optional)", text: $amountText, decimal: true)
                LogTextField("Unit", text: $unit)
                    .frame(maxWidth: 90)
            }
            LogTextField("Notes (optional)", text: $notes)
            LogHint("This only keeps your list. It is not dose advice.")
            if let entry {
                MGButton("Remove from my list", style: .ghost) {
                    send(PresetListIntents.remove(list, id: entry.id))
                    dismiss()
                }
                .disabled(!canEdit)
                .opacity(canEdit ? 1 : 0.4)
            }
        }
    }

    private func save() {
        guard canSave, let clean = LogText.clean(name) else { return }
        let id = entry?.id ?? PresetEntry.newID()
        send(PresetListIntents.save(list, PresetEntry(id: id, name: clean, amount: amountText.isEmpty ? nil : amount,
                                                      unit: LogText.clean(unit) ?? "mg", notes: notes)))
    }
}

/// A drink with every detail Mo keeps. Empty text fields are saved as "not entered" (nil), never as 0.
struct SettingsDrinkEntryEditor: View {
    let drink: DrinkEntry?
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(drink: DrinkEntry?, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.drink = drink
        self.canEdit = canEdit
        self.send = send
        let d = drink
        _name = State(initialValue: d?.name ?? "")
        _size = State(initialValue: d?.size ?? "")
        _caffeine = State(initialValue: d?.caffeineMg.map { LogText.number($0) } ?? "")
        _low = State(initialValue: d?.caffeineLowMg.map { LogText.number($0) } ?? "")
        _high = State(initialValue: d?.caffeineHighMg.map { LogText.number($0) } ?? "")
        _caffeineNote = State(initialValue: d?.caffeineNote ?? "")
        _calories = State(initialValue: d?.calories ?? "")
        _carbs = State(initialValue: d?.carbsG ?? "")
        _sugar = State(initialValue: d?.sugarG ?? "")
        _sodium = State(initialValue: d?.sodiumMg ?? "")
        _sweeteners = State(initialValue: d?.sweeteners ?? "")
        _vitamins = State(initialValue: d?.vitamins ?? "")
        _minerals = State(initialValue: d?.minerals ?? "")
        _aminos = State(initialValue: d?.aminosOther ?? "")
        _notes = State(initialValue: d?.notes ?? "")
    }
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var size: String
    @State private var caffeine: String
    @State private var low: String
    @State private var high: String
    @State private var caffeineNote: String
    @State private var calories: String
    @State private var carbs: String
    @State private var sugar: String
    @State private var sodium: String
    @State private var sweeteners: String
    @State private var vitamins: String
    @State private var minerals: String
    @State private var aminos: String
    @State private var notes: String

    private func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
    private func number(_ s: String) -> Double? { blank(s) ? nil : LogText.parse(s) }
    /// Each typed caffeine number must be 0...1000; a blank one is "not entered".
    private var caffeineOK: Bool {
        [caffeine, low, high].allSatisfy { blank($0) || (number($0).map { $0 >= 0 && $0 <= 1000 } ?? false) }
    }
    private var canSave: Bool { canEdit && LogText.clean(name) != nil && caffeineOK }

    var body: some View {
        SettingsSheetFrame(title: drink == nil ? "New drink" : "Edit drink", canSave: canSave,
                           reason: canEdit ? "A name, and caffeine between 0 and 1000 mg if you enter it."
                                           : SettingsIntents.sampleReason,
                           onSave: save) {
            LogTextField("Name", text: $name)
            LogTextField("Size (12 oz can)", text: $size)
            LogFormLabel("Caffeine (mg). Leave empty if not known; 0 is a real zero (water).")
            HStack(spacing: 8) {
                LogTextField("Typical", text: $caffeine, decimal: true)
                LogTextField("Low", text: $low, decimal: true)
                LogTextField("High", text: $high, decimal: true)
            }
            LogTextField("Where the caffeine comes from", text: $caffeineNote)
            LogFormLabel("Label details (empty = not entered)")
            LogTextField("Calories", text: $calories)
            LogTextField("Carbs (g)", text: $carbs)
            LogTextField("Sugar (g)", text: $sugar)
            LogTextField("Sodium (mg)", text: $sodium)
            LogTextField("Sweeteners", text: $sweeteners)
            LogTextField("Vitamins", text: $vitamins)
            LogTextField("Minerals", text: $minerals)
            LogTextField("Aminos / other", text: $aminos)
            LogTextField("Notes", text: $notes)
            if let drink {
                MGButton("Remove from my list", style: .ghost) {
                    send(PresetListIntents.remove(.drinks, id: drink.id))
                    dismiss()
                }
                .disabled(!canEdit)
                .opacity(canEdit ? 1 : 0.4)
            }
        }
    }

    private func opt(_ s: String) -> String? { blank(s) ? nil : s }

    private func save() {
        guard canSave, let clean = LogText.clean(name) else { return }
        let mid = number(caffeine)
        send(PresetListIntents.save(DrinkEntry(
            id: drink?.id ?? PresetEntry.newID(), name: clean, size: size, calories: opt(calories), carbsG: opt(carbs),
            sugarG: opt(sugar), sodiumMg: opt(sodium), caffeineMg: mid, caffeineLowMg: number(low) ?? mid,
            caffeineHighMg: number(high) ?? mid, caffeineNote: caffeineNote, sweeteners: sweeteners,
            vitamins: vitamins, minerals: minerals, aminosOther: aminos, notes: notes)))
    }
}
