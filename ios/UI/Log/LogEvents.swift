import Foundation
import MGContext
import MGDomain

/// Builds the contract events the Log forms save (pure; MGDomain types only). Every event carries BOTH times:
/// `at` = when it happened, `loggedAt` = when Mo tapped save (APP-082, contract eventBase). Source is `manual`.
/// Field meanings: contract $defs (ARCHITECTURE §4.3, `EventPayloads.swift`).
enum LogEvents {
    static func make(_ payload: EventPayload, at: Date, loggedAt: Date, note: String? = nil) -> EventRecord {
        EventRecord(at: at, loggedAt: loggedAt, source: .manual, note: note, payload: payload)
    }

    // MARK: Substances

    /// One tap is one `vape_tick` event at the tap time.
    static func vapeTick(at: Date, loggedAt: Date) -> EventRecord {
        let fields = SubstanceFields(kind: .vapeTick, vape: SubstanceFields.Vape(hits: 1, trigger: .button))
        return make(.substance(fields), at: at, loggedAt: loggedAt)
    }

    /// A pill record only: the app does not derive or recommend a dose or cut-down target.
    static func pill(name: String, mg: Double?, at: Date, loggedAt: Date) -> EventRecord {
        make(.substance(SubstanceFields(kind: .pill, product: name, pillMg: mg)), at: at, loggedAt: loggedAt)
    }

    /// Caffeine: `at` = start, `finishedAt` nil = still drinking (contract substanceEvent).
    static func caffeine(product: String, mg: Double, at: Date, finishedAt: Date?, loggedAt: Date) -> EventRecord {
        let fields = SubstanceFields(kind: .caffeine, product: product, caffeineMg: mg, finishedAt: finishedAt)
        return make(.substance(fields), at: at, loggedAt: loggedAt)
    }

    /// Caffeine with its estimate range and override (T101); built by `CaffeineDrinks.fields`.
    static func caffeine(fields: SubstanceFields, at: Date, loggedAt: Date) -> EventRecord {
        make(.substance(fields), at: at, loggedAt: loggedAt)
    }

    /// Alcohol. The contract (v0.4) has no units field, so the count goes in `product` and `note`; flagged for v0.5.
    static func alcohol(product: String, standardDrinks: Double, at: Date, loggedAt: Date) -> EventRecord {
        let n = LogText.number(standardDrinks)
        let note = "\(n) standard \(standardDrinks == 1 ? "drink" : "drinks") (US, 14 g alcohol each)"
        return make(.substance(SubstanceFields(kind: .alcohol, product: product)), at: at, loggedAt: loggedAt, note: note)
    }

    /// r9p (D-LOAD-WALK-2): water or any drink counted toward the day's fluid; `volume_ml` is the amount.
    static func drink(ml: Double, product: String?, at: Date, loggedAt: Date) -> EventRecord {
        make(.substance(SubstanceFields(kind: .drink, product: product ?? "Water", volumeMl: ml)), at: at, loggedAt: loggedAt)
    }

    /// r9p (D-LOAD-WALK-2): a soreness or injury entry, `level` 0 to 10, active until Mo resolves it.
    static func sore(kind: RecordFields.Kind, bodyPart: String, side: RecordFields.Side?, level: Int, text: String?,
                     at: Date, loggedAt: Date) -> EventRecord {
        let fields = RecordFields(kind: kind, bodyPart: bodyPart, side: side, status: .active, text: text, level: min(max(level, 0), 10))
        return make(.record(fields), at: at, loggedAt: loggedAt)
    }

    // MARK: Medication and supplements

    /// `units` of `unitKind` (1 capsule); `strength` per unit; `dose` = units × strength when the strength is known.
    static func medication(name: String, status: MedicationFields.Status, category: MedicationFields.Category?,
                           units: Double?, unitKind: MedicationFields.UnitKind?, strength: Double?,
                           strengthUnit: String?, withFood: Bool?, presetId: String?,
                           at: Date, loggedAt: Date) -> EventRecord {
        var dose: Double?
        if let units, let strength { dose = units * strength }
        let fields = MedicationFields(name: name, dose: dose, doseUnit: strength == nil ? nil : strengthUnit,
                                      status: status, category: category, units: units, unitKind: unitKind,
                                      dosePerUnit: strength, withFood: withFood, presetId: presetId)
        return make(.medication(fields), at: at, loggedAt: loggedAt)
    }

    /// A supplement intake typed as an amount in mg (the "input as mg" path of APP-077).
    static func supplementMg(name: String, mg: Double, at: Date, loggedAt: Date) -> EventRecord {
        let fields = MedicationFields(name: name, dose: mg, doseUnit: "mg", status: .taken, category: .supplement,
                                      units: mg, unitKind: .mg)
        return make(.medication(fields), at: at, loggedAt: loggedAt)
    }

    // MARK: Food, symptoms, check-ins, notes

    /// Calories and macros typed here are `estimate_method: manual`; `quality` is Mo's 1–5 rating (contract v0.5,
    /// tracker #42). A meal photo is never named in the event: it stays on the phone (MealPhotos, by event id).
    static func food(text: String?, tags: [String], portion: FoodFields.Portion?, kcal: Double?,
                     proteinG: Double? = nil, carbG: Double? = nil, fatG: Double? = nil, quality: Int? = nil,
                     at: Date, loggedAt: Date) -> EventRecord {
        let typed = kcal != nil || proteinG != nil || carbG != nil || fatG != nil
        let fields = FoodFields(text: text, tags: tags.isEmpty ? nil : tags, portion: portion, kcal: kcal,
                                proteinG: proteinG, carbG: carbG, fatG: fatG,
                                estimateMethod: typed ? .manual : nil, quality: quality)
        return make(.food(fields), at: at, loggedAt: loggedAt)
    }

    static func stool(_ choice: LogStoolChoice, at: Date, loggedAt: Date) -> EventRecord {
        make(.symptom(SymptomFields(kind: .stool, bristol: choice.bristol, stoolWord: choice.word)),
             at: at, loggedAt: loggedAt)
    }

    /// `severity` 0–3 for gut symptoms and headache; nil when not asked. `detail` for swallowing and "other".
    /// A swallowing event leaves `follows` empty: the saveEvent handler links it to the meal before it (APP-081, clarification d).
    static func symptom(kind: SymptomFields.Kind, severity: Int?, detail: String?, at: Date, loggedAt: Date) -> EventRecord {
        make(.symptom(SymptomFields(kind: kind, severity: severity, detail: detail)), at: at, loggedAt: loggedAt)
    }

    static func checkin(kss: Int?, energy: Int?, focus: Int?, mood: Int?, at: Date, loggedAt: Date) -> EventRecord {
        make(.checkin(CheckinFields(kss: kss, energy: energy, focus: focus, mood: mood, prompt: .manual)),
             at: at, loggedAt: loggedAt)
    }

    static func journal(text: String, tags: [String], at: Date, loggedAt: Date) -> EventRecord {
        make(.journal(JournalFields(text: text, tags: tags.isEmpty ? nil : tags)), at: at, loggedAt: loggedAt)
    }

    // MARK: More ›

    static func bpCuff(systolic: Double, diastolic: Double, pulse: Double?, posture: BPCuffFields.Posture?,
                       arm: BPCuffFields.Arm?, at: Date, loggedAt: Date) -> EventRecord {
        let fields = BPCuffFields(systolic: systolic, diastolic: diastolic, pulse: pulse, posture: posture, arm: arm)
        return make(.bpCuff(fields), at: at, loggedAt: loggedAt)
    }

    /// `end`: when an injury (or any record) ended — contract v0.4 `recordEvent.end` (tracker #42 puts it on the form).
    static func record(kind: RecordFields.Kind, bodyPart: String?, side: RecordFields.Side?, clinician: String?,
                       status: RecordFields.Status?, text: String?, end: Date? = nil, at: Date,
                       loggedAt: Date) -> EventRecord {
        let fields = RecordFields(kind: kind, bodyPart: bodyPart, side: side, clinician: clinician, status: status,
                                  end: end, text: text)
        return make(.record(fields), at: at, loggedAt: loggedAt)
    }

    /// `composition`: the typed numbers of an InBody / DEXA / tape entry (contract v0.5 bodyCompositionValues in
    /// `values`; tracker #42).
    static func scan(kind: ScanFields.ScanKind, provider: String?, bodyPart: String?, side: ScanFields.Side?,
                     note: String?, composition: BodyComposition = BodyComposition(), at: Date,
                     loggedAt: Date) -> EventRecord {
        let fields = ScanFields(scanKind: kind, provider: provider,
                                values: composition.isEmpty ? nil : composition.merged(into: nil),
                                bodyPart: bodyPart, side: side)
        return make(.scan(fields), at: at, loggedAt: loggedAt, note: note)
    }

    /// BP numbers a cuff can plausibly show; anything else is probably a typo and is refused with its reason (R6).
    static func bpProblem(systolic: Double?, diastolic: Double?, pulse: Double?) -> String? {
        guard let systolic, let diastolic else { return "Enter both numbers." }
        if systolic < 60 || systolic > 260 { return "Top number should be between 60 and 260." }
        if diastolic < 30 || diastolic > 160 { return "Bottom number should be between 30 and 160." }
        if diastolic >= systolic { return "The top number must be higher than the bottom one." }
        if let pulse, pulse < 20 || pulse > 250 { return "Pulse should be between 20 and 250." }
        return nil
    }
}
