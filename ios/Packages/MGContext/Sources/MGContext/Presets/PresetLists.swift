import Foundation
import MGDomain

/// T9746: Mo's own editable lists of Medications, Supplements and Drinks (Settings), offered as a dropdown where he logs.
/// Everything here is what Mo typed (or the seed he wrote down on 2026-10-14), never a recommendation or dose advice.
/// A blank field is "not entered", never a 0 (a real zero, like 0 g sugar, is stored as "0").
public enum PresetListKind: String, Codable, CaseIterable, Sendable {
    case medications, supplements, drinks

    public var title: String {
        switch self {
        case .medications: return "Medications"
        case .supplements: return "Supplements"
        case .drinks: return "Drinks"
        }
    }
}

/// A medication or supplement: name, and the strength of one unit ("Med A", 20, "mg").
public struct PresetEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Strength of one unit; nil = not entered.
    public var amount: Double?
    public var unit: String
    public var notes: String

    public init(id: String = PresetEntry.newID(), name: String, amount: Double? = nil, unit: String = "mg",
                notes: String = "") {
        self.id = id
        self.name = name
        self.amount = amount
        self.unit = unit
        self.notes = notes
    }

    public static func newID() -> String { "preset_" + UUID().uuidString.lowercased() }

    /// "Med A 20 mg"; just the name when no strength is entered.
    public var title: String {
        guard let amount else { return name }
        return "\(name) \(MGFormat.number(amount, decimals: amount == amount.rounded() ? 0 : 1)) \(unit)"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? PresetEntry.newID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        amount = try? c.decodeIfPresent(Double.self, forKey: .amount)
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? "mg"
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
    }
}

/// A drink with the full details Mo wants kept. The nutrition fields are text on purpose: a label gives ranges
/// ("10-15 calories") and Mo's own wording is kept exactly. nil = not entered (the app says so, never shows 0).
public struct DrinkEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Size or dose of one serving ("12 oz can").
    public var size: String
    public var calories: String?
    public var carbsG: String?
    public var sugarG: String?
    public var sodiumMg: String?
    /// Caffeine for the model: the middle of a range. nil = not entered (not logged as caffeine); 0 = a real zero (water).
    public var caffeineMg: Double?
    public var caffeineLowMg: Double?
    public var caffeineHighMg: Double?
    /// Where the caffeine comes from ("green tea/coffee", "double shot").
    public var caffeineNote: String
    public var sweeteners: String
    public var vitamins: String
    public var minerals: String
    public var aminosOther: String
    public var notes: String

    public init(id: String = PresetEntry.newID(), name: String, size: String = "", calories: String? = nil,
                carbsG: String? = nil, sugarG: String? = nil, sodiumMg: String? = nil, caffeineMg: Double? = nil,
                caffeineLowMg: Double? = nil, caffeineHighMg: Double? = nil, caffeineNote: String = "",
                sweeteners: String = "", vitamins: String = "", minerals: String = "", aminosOther: String = "",
                notes: String = "") {
        self.id = id
        self.name = name
        self.size = size
        self.calories = calories
        self.carbsG = carbsG
        self.sugarG = sugarG
        self.sodiumMg = sodiumMg
        self.caffeineMg = caffeineMg
        self.caffeineLowMg = caffeineLowMg
        self.caffeineHighMg = caffeineHighMg
        self.caffeineNote = caffeineNote
        self.sweeteners = sweeteners
        self.vitamins = vitamins
        self.minerals = minerals
        self.aminosOther = aminosOther
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? "" }
        func o(_ k: CodingKeys) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
        func d(_ k: CodingKeys) -> Double? { try? c.decodeIfPresent(Double.self, forKey: k) }
        id = o(.id) ?? PresetEntry.newID()
        name = s(.name)
        size = s(.size)
        calories = o(.calories)
        carbsG = o(.carbsG)
        sugarG = o(.sugarG)
        sodiumMg = o(.sodiumMg)
        caffeineMg = d(.caffeineMg)
        caffeineLowMg = d(.caffeineLowMg)
        caffeineHighMg = d(.caffeineHighMg)
        caffeineNote = s(.caffeineNote)
        sweeteners = s(.sweeteners)
        vitamins = s(.vitamins)
        minerals = s(.minerals)
        aminosOther = s(.aminosOther)
        notes = s(.notes)
    }

    /// Name with size when the name does not already say it: "Drink A", "Water bottle 26 oz".
    public var title: String { size.isEmpty ? name : "\(name) · \(size)" }

    /// Shown instead of a blank, so an empty field always says why it is empty.
    public static let notEntered = "not entered"

    /// A caffeine amount worth logging: more than 0 mg.
    public var hasCaffeine: Bool { (caffeineMg ?? 0) > 0 }

    /// "160 mg", "about 130 mg (120–140)", or "no caffeine" for a real 0, "not entered" for nil.
    public var caffeineText: String {
        guard let mg = caffeineMg else { return DrinkEntry.notEntered }
        if mg == 0 { return "no caffeine" }
        let n = MGFormat.number(mg, decimals: 0)
        if let lo = caffeineLowMg, let hi = caffeineHighMg, lo != hi {
            return "about \(n) mg (\(MGFormat.number(lo, decimals: 0))–\(MGFormat.number(hi, decimals: 0)))"
        }
        return "\(n) mg"
    }

    /// The detail lines for the editor and the list: every field, blank ones as "not entered".
    public var detailLines: [String] {
        func t(_ s: String?) -> String { (s?.isEmpty == false) ? s! : DrinkEntry.notEntered }
        return [
            "Calories: \(t(calories))", "Carbs (g): \(t(carbsG))", "Sugar (g): \(t(sugarG))",
            "Sodium (mg): \(t(sodiumMg))", "Caffeine: \(caffeineText)\(caffeineNote.isEmpty ? "" : " (\(caffeineNote))")",
            "Sweeteners: \(t(sweeteners))", "Vitamins: \(t(vitamins))", "Minerals: \(t(minerals))",
            "Aminos / other: \(t(aminosOther))", "Notes: \(t(notes))",
        ]
    }
}

/// The three lists, stored inside the app settings (key-value area, so Export's kv/kv.json carries them).
public struct PresetLists: Codable, Equatable, Sendable {
    public var medications: [PresetEntry]
    public var supplements: [PresetEntry]
    public var drinks: [DrinkEntry]
    /// True once the seed was applied, so a list Mo emptied on purpose is not refilled (the seed is never re-added).
    public var seeded: Bool

    public init(medications: [PresetEntry] = [], supplements: [PresetEntry] = [], drinks: [DrinkEntry] = [],
                seeded: Bool = false) {
        self.medications = medications
        self.supplements = supplements
        self.drinks = drinks
        self.seeded = seeded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        medications = (try? c.decodeIfPresent([PresetEntry].self, forKey: .medications)) ?? []
        supplements = (try? c.decodeIfPresent([PresetEntry].self, forKey: .supplements)) ?? []
        drinks = (try? c.decodeIfPresent([DrinkEntry].self, forKey: .drinks)) ?? []
        seeded = (try? c.decodeIfPresent(Bool.self, forKey: .seeded)) ?? false
    }

    // MARK: Seed

    /// Fills a list from the user's own local file (`LocalPresetFile`, never part of the repo) only when that list is
    /// empty and the seed has not been applied before. Anything already entered is kept as is. With no file present
    /// nothing happens and `seeded` stays false, so a file that arrives later (copied onto the phone) still seeds once.
    public mutating func seedIfNeeded(from local: LocalPresetFile?) {
        guard !seeded, let local else { return }
        if medications.isEmpty { medications = local.medications }
        if supplements.isEmpty { supplements = local.supplements }
        if drinks.isEmpty { drinks = local.drinks }
        seeded = true
    }

    // MARK: Edit

    /// Add (new id) or replace (same id) a medication or supplement. A blank name is refused: returns false.
    @discardableResult
    public mutating func save(_ entry: PresetEntry, in kind: PresetListKind) -> Bool {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, kind != .drinks else { return false }
        if let a = entry.amount, !(a.isFinite && a > 0) { return false }
        var e = entry
        e.name = name
        if kind == .medications { PresetLists.upsert(&medications, e) } else { PresetLists.upsert(&supplements, e) }
        return true
    }

    @discardableResult
    public mutating func save(_ drink: DrinkEntry) -> Bool {
        let name = drink.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        for v in [drink.caffeineMg, drink.caffeineLowMg, drink.caffeineHighMg] {
            if let v, !(v.isFinite && v >= 0 && v <= 1000) { return false }
        }
        var d = drink
        d.name = name
        if let i = drinks.firstIndex(where: { $0.id == d.id }) { drinks[i] = d } else { drinks.append(d) }
        return true
    }

    public mutating func remove(id: String, from kind: PresetListKind) {
        switch kind {
        case .medications: medications.removeAll { $0.id == id }
        case .supplements: supplements.removeAll { $0.id == id }
        case .drinks: drinks.removeAll { $0.id == id }
        }
    }

    private static func upsert(_ list: inout [PresetEntry], _ e: PresetEntry) {
        if let i = list.firstIndex(where: { $0.id == e.id }) { list[i] = e } else { list.append(e) }
    }

    // MARK: Logging

    /// The caffeine log path's fields for a drink (same as the built-in drinks: `CaffeineDrinks.fields`); nil when the
    /// drink has no caffeine to log (water, or not entered).
    public static func caffeineFields(_ d: DrinkEntry, finishedAt: Date? = nil) -> SubstanceFields? {
        guard d.hasCaffeine, let mid = d.caffeineMg else { return nil }
        let low = d.caffeineLowMg ?? mid
        let high = d.caffeineHighMg ?? mid
        let drink = CaffeineDrink(name: d.name, low: low, mid: mid, high: high, source: "Your drink list",
                                  isEstimate: low != high, confirmedByMo: false)
        return CaffeineDrinks.fields(drink, overrideMg: nil, finishedAt: finishedAt)
    }

    /// Drinks Mo can pick in the caffeine form: his list (caffeine above 0), then the built-in presets his list does
    /// not already name (same name, or the same first word: his "Drink A Zero Sugar" replaces the built-in
    /// "Drink A" and "Drink A 12 oz", so the dropdown never shows it twice), nothing else dropped.
    public static func drinkChoices(_ lists: PresetLists, legacy: [(name: String, caffeineMg: Double)])
        -> [(name: String, caffeineMg: Double)] {
        var out = lists.drinks.filter { $0.hasCaffeine }.map { (name: $0.name, caffeineMg: $0.caffeineMg ?? 0) }
        let firstWords = Set(lists.drinks.filter { $0.hasCaffeine }.compactMap { firstWord($0.name) })
        for l in legacy where !out.contains(where: { $0.name.caseInsensitiveCompare(l.name) == .orderedSame })
            && !(firstWord(l.name).map { firstWords.contains($0) } ?? false) {
            out.append(l)
        }
        return out
    }

    private static func firstWord(_ name: String) -> String? {
        name.split(separator: " ").first.map { $0.lowercased() }
    }
}

/// The user's own starting lists (T9746), read from a JSON file that is NOT in the repo (T9973: no personal medication
/// or drink names in source, tests or docs). The app looks for `local-presets.json` in its Application Support folder,
/// then in the app bundle (a build can include the git-ignored `ios/local/local-presets.json`). Same field names as the
/// stored lists: `{"medications": [PresetEntry], "supplements": [PresetEntry], "drinks": [DrinkEntry]}`. Applied once, only
/// to an empty list (`PresetLists.seedIfNeeded(from:)`). A missing or unreadable file means no seed, never an error.
public struct LocalPresetFile: Codable, Equatable, Sendable {
    public static let fileName = "local-presets.json"

    public var medications: [PresetEntry]
    public var supplements: [PresetEntry]
    public var drinks: [DrinkEntry]
    /// Compound id (a generic name such as "lisdexamfetamine") -> the product names the user logs it under. The models
    /// match a logged dose to a compound through this table, so no brand name is written in source (T9973).
    public var medicationAliases: [String: [String]]

    public init(medications: [PresetEntry] = [], supplements: [PresetEntry] = [], drinks: [DrinkEntry] = [],
                medicationAliases: [String: [String]] = [:]) {
        self.medications = medications
        self.supplements = supplements
        self.drinks = drinks
        self.medicationAliases = medicationAliases
    }

    /// The product names listed for a compound (empty when the file has none).
    public func aliases(for compound: String) -> [String] {
        medicationAliases.first { $0.key.caseInsensitiveCompare(compound) == .orderedSame }?.value ?? []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        medications = (try? c.decodeIfPresent([PresetEntry].self, forKey: .medications)) ?? []
        supplements = (try? c.decodeIfPresent([PresetEntry].self, forKey: .supplements)) ?? []
        drinks = (try? c.decodeIfPresent([DrinkEntry].self, forKey: .drinks)) ?? []
        medicationAliases = (try? c.decodeIfPresent([String: [String]].self, forKey: .medicationAliases)) ?? [:]
    }

    /// The file's content, or nil when the bytes are not a JSON object or hold no entry at all.
    public static func decode(_ data: Data) -> LocalPresetFile? {
        guard let file = try? JSONDecoder().decode(LocalPresetFile.self, from: data) else { return nil }
        return file.medications.isEmpty && file.supplements.isEmpty && file.drinks.isEmpty && file.medicationAliases.isEmpty
            ? nil : file
    }
}
