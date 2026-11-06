import Foundation
import MGDomain

// WP-24 — the contract events the quick-log intents create. Same payload shapes as the Log tab's forms
// (UI/Log/LogEvents.swift, WP-18), built here from MGDomain alone so WP-27's widget target can compile this file too.
// Every event: fresh id, revision 1, `at` = `loggedAt` = the moment of the tap (APP-082), `source` = shortcut / widget.

/// A drink preset (Settings drink presets; UX §7 defaults).
struct IntentsDrink: Codable, Hashable, Sendable {
    var name: String
    var caffeineMg: Double

    enum CodingKeys: String, CodingKey {
        case name = "name"
        case caffeineMg = "caffeine_mg"
    }
}

/// A medication preset (APP-076: "MedA, 20 mg, 1 capsule").
struct IntentsMedication: Codable, Hashable, Sendable {
    var name: String
    /// Strength of ONE unit; nil = unknown (then no dose is written).
    var strength: Double?
    var strengthUnit: String
    var units: Double
    var unitKind: MedicationFields.UnitKind
    var category: MedicationFields.Category

    /// Same id rule as the Log form (`LogMedication.id`).
    var presetId: String { name.lowercased() }

    enum CodingKeys: String, CodingKey {
        case name = "name"
        case strength = "strength"
        case strengthUnit = "strength_unit"
        case units = "units"
        case unitKind = "unit_kind"
        case category = "category"
    }
}

/// What the intents offer as choices. The app (WP-23) writes `intent-catalogue.json` next to the queue whenever
/// Settings change, so Shortcuts and widgets see Mo's own presets; until then the app falls back to the Log tab's
/// standard catalogue (IntentsHandler.swift). Supplements are never invented (BRIEF clarification (e)).
struct IntentsCatalogue: Codable, Equatable, Sendable {
    static let fileName = "intent-catalogue.json"

    var drinks: [IntentsDrink]
    var medications: [IntentsMedication]

    static func load(from directory: URL) -> IntentsCatalogue? {
        guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(fileName).path) else {
            return nil
        }
        return try? MGJSON.decoder().decode(IntentsCatalogue.self, from: data)
    }

    func save(to directory: URL) throws {
        try MGJSON.encoder().encode(self).write(to: directory.appendingPathComponent(IntentsCatalogue.fileName),
                                                options: .atomic)
    }
}

enum IntentsEvents {
    private static func make(_ payload: EventPayload, at: Date, surface: IntentsSurface, note: String? = nil) -> EventRecord {
        EventRecord(at: at, loggedAt: at, source: surface.eventSource, note: note, payload: payload)
    }

    /// One vape hit (APP-071 "one event per hit"). Session and minutes-since-wake are derived by the app.
    static func vapeHit(at: Date, surface: IntentsSurface) -> EventRecord {
        make(.substance(SubstanceFields(kind: .vapeTick,
                                        vape: SubstanceFields.Vape(hits: 1, trigger: surface.vapeTrigger))),
             at: at, surface: surface)
    }

    /// Start sipping: `finished_at` empty until FinishDrinkIntent (contract substanceEvent).
    static func drinkStart(_ drink: IntentsDrink, at: Date, surface: IntentsSurface) -> EventRecord {
        make(.substance(SubstanceFields(kind: .caffeine, product: drink.name, caffeineMg: drink.caffeineMg)),
             at: at, surface: surface)
    }

    /// A dose taken now: dose = units × strength when the strength is known (as LogEvents.medication).
    static func medicationTaken(_ med: IntentsMedication, at: Date, surface: IntentsSurface) -> EventRecord {
        let dose = med.strength.map { $0 * med.units }
        let fields = MedicationFields(name: med.name, dose: dose, doseUnit: med.strength == nil ? nil : med.strengthUnit,
                                      status: .taken, category: med.category, units: med.units,
                                      unitKind: med.unitKind, dosePerUnit: med.strength, presetId: med.presetId)
        return make(.medication(fields), at: at, surface: surface)
    }

    /// `severity` 0–3 (gut symptoms, headache) or nil.
    static func symptom(_ kind: SymptomFields.Kind, severity: Int?, at: Date, surface: IntentsSurface) -> EventRecord {
        make(.symptom(SymptomFields(kind: kind, severity: severity)), at: at, surface: surface)
    }

    /// KSS 1–9 check-in (the Log tab's Sleepy row saves the same checkin event, prompt `manual`).
    static func sleepiness(kss: Int, at: Date, surface: IntentsSurface) -> EventRecord {
        make(.checkin(CheckinFields(kss: kss, prompt: .manual)), at: at, surface: surface)
    }

    /// A free-text note (journal event, as the Log tab's Note row).
    static func note(_ text: String, at: Date, surface: IntentsSurface) -> EventRecord {
        make(.journal(JournalFields(text: text)), at: at, surface: surface)
    }

    /// FinishDrinkIntent's rule: the latest caffeine drink that is still open (no `finished_at`, not removed), started
    /// at or before `at` and no more than `maxOpen` before it, comes back with `finished_at = at` (same id: the store
    /// bumps its revision). nil = nothing open (the request is refused with that reason, never guessed).
    static func finishing(_ events: [EventRecord], at: Date, maxOpen: TimeInterval = 12 * 3600) -> EventRecord? {
        let open = events.filter { e in
            guard !e.removed, e.at <= at, at.timeIntervalSince(e.at) <= maxOpen,
                  case .substance(let f) = e.payload, f.kind == .caffeine, f.finishedAt == nil else { return false }
            return true
        }
        guard var latest = open.max(by: { $0.at < $1.at }),
              case .substance(var fields) = latest.payload else { return nil }
        fields.finishedAt = at
        latest.payload = .substance(fields)
        return latest
    }
}
