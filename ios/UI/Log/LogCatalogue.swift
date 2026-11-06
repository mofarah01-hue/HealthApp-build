import Foundation
import MGContext
import MGDomain

// What the entry forms offer: drink presets, the medication preset, supplements, alcohol presets.
// LogState carries none of this (it is not state of the day), so LogView takes a `LogCatalogue`; WP-23 builds it with
// `LogCatalogue(settings:)`. Approved clarification (e): supplements are EMPTY until Mo fills them. His stack is never invented.

struct LogDrink: Hashable, Identifiable {
    var name: String
    var caffeineMg: Double
    var id: String { name }
    /// "Coffee 95"
    var chipLabel: String { "\(name) \(LogText.number(caffeineMg))" }
}

/// A medication the Log row can log in one form. APP-076: "preset (name, 20 mg, 1 capsule) with editable dose"; the
/// presets are the user's own Medications list (T9973: no name is written in source).
struct LogMedication: Hashable, Identifiable {
    var name: String
    /// Strength of ONE unit (20 for a 20 mg capsule); nil = unknown, the form asks.
    var strength: Double?
    var strengthUnit: String
    var units: Double
    var unitKind: MedicationFields.UnitKind
    var category: MedicationFields.Category
    var id: String { name.lowercased() }
}

/// A supplement Mo has saved. `strength` is per pill when `strengthUnit` is set (200 mg, 2000 IU).
struct LogSupplement: Hashable, Identifiable {
    var name: String
    var strength: Double?
    var strengthUnit: String?
    var defaultPills: Double
    var id: String { name.lowercased() }
}

/// An alcohol preset. `standardDrinks` is in US standard drinks (14 g alcohol; NIAAA: 12 oz beer, 5 oz wine, 1.5 oz spirits).
struct LogAlcohol: Hashable, Identifiable {
    var name: String
    var portion: String
    var standardDrinks: Double
    var id: String { name.lowercased() }
}

struct LogCatalogue: Equatable {
    var drinks: [LogDrink]
    var medications: [LogMedication]
    var supplements: [LogSupplement]
    var alcohol: [LogAlcohol]
    /// T9746: Mo's editable Medications / Supplements / Drinks lists, the source of the "From your list" dropdowns.
    var presetLists = PresetLists()

    /// UX §7 generic drink presets (Coffee 95 · Espresso 63 · Tea 47), alcohol presets; no branded drink, no medication,
    /// no supplement (T9973: those are the user's own lists, seeded from his local file).
    static let standard = LogCatalogue(
        drinks: [
            LogDrink(name: "Coffee", caffeineMg: 95),
            LogDrink(name: "Espresso", caffeineMg: 63),
            LogDrink(name: "Tea", caffeineMg: 47),
        ],
        medications: [],
        supplements: [],
        alcohol: [
            LogAlcohol(name: "Beer", portion: "12 oz", standardDrinks: 1),
            LogAlcohol(name: "Wine", portion: "5 oz", standardDrinks: 1),
            LogAlcohol(name: "Spirit", portion: "1.5 oz", standardDrinks: 1),
        ])

    /// Drink presets follow Settings; an empty list falls back to the standard three. The medication list and the
    /// supplement list stay as in `standard` (SettingsState carries schedule TEXT only, no doses).
    init(settings: SettingsState) {
        let base = LogCatalogue.standard
        self.drinks = settings.drinkPresets.isEmpty
            ? base.drinks
            : settings.drinkPresets.map { LogDrink(name: $0.name, caffeineMg: $0.caffeineMg) }
        self.medications = base.medications
        self.supplements = base.supplements
        self.alcohol = base.alcohol
    }

    init(drinks: [LogDrink], medications: [LogMedication], supplements: [LogSupplement], alcohol: [LogAlcohol],
         presetLists: PresetLists = PresetLists()) {
        self.presetLists = presetLists
        self.drinks = drinks
        self.medications = medications
        self.supplements = supplements
        self.alcohol = alcohol
    }

    /// The preset whose name starts the row title ("MedA 20 mg" → MedA).
    func medication(matching rowTitle: String) -> LogMedication? {
        medications.first { rowTitle.localizedCaseInsensitiveContains($0.name) }
    }

    #if DEBUG
    /// Previews only: a made-up supplement list, so the form can be seen with chips. Never used in the app.
    static let previewWithSupplements: LogCatalogue = {
        var c = LogCatalogue.standard
        c.supplements = [
            LogSupplement(name: "Magnesium glycinate", strength: 200, strengthUnit: "mg", defaultPills: 1),
            LogSupplement(name: "Vitamin D3", strength: 2000, strengthUnit: "IU", defaultPills: 1),
            LogSupplement(name: "Fish oil", strength: 1000, strengthUnit: "mg", defaultPills: 2),
        ]
        return c
    }()
    #endif
}
