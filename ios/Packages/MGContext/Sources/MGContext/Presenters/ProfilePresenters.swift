import Foundation
import MGDomain

// Settings › Profile, tracker #42 (2026-10-11; Mo: "the function inbody weight heigh age injuries … food intake food
// quality calories sleep"). Profile and Log already held birth date, sex, height, weight, max HR, resting HR (profile)
// and injury records + InBody / DEXA scans (Log › More); these presenters add what each empty field unlocks, the list of
// injuries with their dates and status, and the body-composition entries with their typed numbers.

/// What each profile field unlocks, read from the code that needs it (2026-10-11): MGSignal DayPipeline (ALG-036
/// strain needs sex and an HRmax; ALG-106 Tanaka needs age; ALG-048 Keytel / Mifflin need weight, height, age, sex),
/// ALG-133 / ALG-134 (age, sex), ScriptMembers (MS-01 sex; MS-05 / 06 age, weight), SnapshotMath workout TRIMP
/// (sex, resting HR), the PC (ms_runner MS-01..04, PhenoAge's age). Shown under an EMPTY field only.
public enum ProfileUnlocks {
    public static let byField: [String: [String]] = [
        "sex": ["day strain and workout strain (ALG-036)", "fitness, fatigue and form (ALG-036, MS-01–03)",
                "active and basal calories (ALG-048)", "fitness age (ALG-133)", "CosinorAge (ALG-134)",
                "workout TRIMP (MS-01)", "your own hydration baseline (ALG-135)"],
        "birth_date": ["max HR estimate (ALG-106, MS-05), so day strain and HR zones until a measured max is set",
                       "calories (ALG-048)", "fitness age (ALG-133)", "CosinorAge (ALG-134)",
                       "PhenoAge on the PC (ALG-070)"],
        "height_cm": ["basal and active calories (ALG-048 Mifflin, Keytel)"],
        "weight_kg": ["calories (ALG-048; Apple Health weight is used while this is blank)",
                      "VO₂max from a timed mile (MS-05, MS-06)"],
        "hr_max": ["your measured max instead of the age formula (ALG-106): strain, zones, HR recovery"],
        "hr_rest": ["workout TRIMP when no resting HR was measured that day (MS-01)"],
    ]

    /// "Sex unlocks: day strain and workout strain (ALG-036), …"; nil for a field with no known use.
    public static func caption(field: String, label: String) -> String? {
        guard let list = byField[field], !list.isEmpty else { return nil }
        return "\(label) unlocks: " + list.joined(separator: ", ")
    }
}

enum ProfileRecords {
    static let months = PCHistoryText.months

    /// "86", "82.1" (one decimal, a trailing ".0" dropped: as typed from a printout).
    static func num(_ v: Double) -> String {
        let s = MGFormat.number(v, decimals: 1)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    static func day(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return "\(c.day ?? 1) \(months[max(0, (c.month ?? 1) - 1)]) \(c.year ?? 0)"
    }

    /// Injuries (record events, kind injury), newest first: body part and side, the dates, the status.
    static func injuries(_ s: PresenterSnapshot) -> [LabeledValue] {
        let r = s.phoneReceipt(.high, method: "Log › More › Health record")
        return s.profileRecords.reversed().compactMap { e -> LabeledValue? in
            guard case .record(let f) = e.payload, f.kind == .injury else { return nil }
            let side = f.side.flatMap { $0 == .notApplicable ? nil : $0.rawValue }
            let part = [side, f.bodyPart].compactMap { $0 }.joined(separator: " ")
            var dates = "since " + day(e.at, s.calendar)
            if let end = f.end { dates = day(e.at, s.calendar) + " – " + day(end, s.calendar) }
            let status = f.status?.rawValue ?? (f.end == nil ? "status not set" : "ended")
            let caption = [dates, f.text, f.clinician.map { "seen by \($0)" }].compactMap { $0 }.joined(separator: " · ")
            return LabeledValue(id: "injury|\(e.id.uuidString)", label: part.isEmpty ? "Injury" : part.capitalizedFirst,
                                value: s.worded(status, receipt: r), caption: caption)
        }
    }

    /// T119: the tape-measure body-fat estimate (US Navy formula, anchored on the InBody), shown above the entries.
    static func tapeEstimate(_ s: PresenterSnapshot) -> LabeledValue? {
        let p = s.settings.profile
        guard let e = TapeBodyFat.estimate(events: s.profileRecords, sex: p.sex, heightCm: p.heightCm,
                                           fallbackWeightKg: p.weightKg, upTo: s.now) else { return nil }
        let r = s.phoneReceipt(.estimate, method: "US Navy tape formula, anchored on the InBody")
        let shown = e.anchoredPct ?? e.tapeOnlyPct
        var parts = ["tape of " + day(e.tapeAt, s.calendar)]
        if let a = e.inbodyAt, let c = e.changePoints {
            parts.append("InBody of \(day(a, s.calendar)) plus \(c < 0 ? "−" : "+")\(num(abs(c))) points since")
        } else {
            parts.append("tape formula alone, no InBody to anchor it")
        }
        if e.anchoredPct != nil { parts.append("tape alone \(num(e.tapeOnlyPct)) %") }
        if let kg = e.fatMassKg { parts.append("fat mass about \(num(kg)) kg") }
        parts.append(TapeBodyFat.label)
        return LabeledValue(id: "tape_body_fat", label: "Body fat (tape estimate)",
                            value: s.worded(num(shown), unit: "%", receipt: r, style: .estimate(nil)),
                            caption: parts.joined(separator: " · "))
    }

    /// Body-composition entries (InBody, DEXA, tape / scale), newest first: weight as the value, the rest in the caption.
    static func bodyComposition(_ s: PresenterSnapshot) -> [LabeledValue] {
        let r = s.phoneReceipt(.high, method: "Log › More › Scan")
        return s.profileRecords.reversed().compactMap { e -> LabeledValue? in
            guard case .scan(let f) = e.payload, BodyComposition.kinds.contains(f.scanKind) else { return nil }
            let bc = BodyComposition(values: f.values)
            let kind: String
            switch f.scanKind {
            case .inbody: kind = "InBody"
            case .dexa: kind = "DEXA"
            default: kind = "Measurement"
            }
            let parts = BodyComposition.fields.filter { $0.key != "weight_kg" }.compactMap { fld -> String? in
                bc.numbers[fld.key].map { "\(fld.label.lowercased()) \(fld.unit == "ratio" ? MGFormat.number($0, decimals: 3) : num($0)) \(fld.unit)" }
            }
            let caption = ([day(e.at, s.calendar)] + parts + [f.provider].compactMap { $0 }).joined(separator: " · ")
            let value: DisplayValue = bc.numbers["weight_kg"].map {
                s.worded(num($0), unit: "kg", receipt: r)
            } ?? (bc.isEmpty ? .blank(reason: "No numbers typed for this scan.", receipt: nil)
                             : s.worded("\(bc.numbers.count) values", receipt: r))
            return LabeledValue(id: "scan|\(e.id.uuidString)", label: kind, value: value, caption: caption)
        }
    }
}
