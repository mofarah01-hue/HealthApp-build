import Foundation

// T9893 (2026-10-17, Mo R-071: "after a set time, put a dot on a lab when a new test is due, using each marker's recommended
// retest interval"). One table: lab metric key -> how soon a retest is recommended, with the published source of each number.
//
// Two intervals, because guidance has two cases:
//  - `routineDays`: for a person with no known problem with this marker (a screening interval). nil = no published routine
//    interval (or the guidance says not to screen), so no dot.
//  - `watchDays`: while the marker is being followed (out of range, or a treatment / supplement / dose just started or
//    changed). nil = no published follow-up interval.
// A marker with neither number, or one that is not in the table, never gets a dot from this table: the caller may pass its own
// `fallbackDays` (a user-set time). No interval is made up here: where no source gives one the entry says so.
//
// Sources are named from the publications as recalled, not re-read for this change; they are a reminder cadence, not medical
// advice for Mo's own results. Re-check a number against its source before relying on it.

public struct LabRetestRule: Equatable, Sendable {
    public enum Basis: String, Sendable { case guideline, mechanism, once }
    public var routineDays: Int?
    public var watchDays: Int?
    public var basis: Basis
    /// Where the number comes from (author, journal, year) or why there is none.
    public var source: String
}

public enum LabRetest {
    private static let lipid = LabRetestRule(
        routineDays: 4 * 365, watchDays: 12 * 7, basis: .guideline,
        source: "Grundy SM et al., 2018 AHA/ACC cholesterol guideline, Circulation 2019;139:e1082: adults 20+ every 4-6 years; "
              + "4-12 weeks after starting or changing lipid therapy")
    private static let lipoproteinA = LabRetestRule(
        routineDays: nil, watchDays: nil, basis: .once,
        source: "Kronenberg F et al., EAS consensus, Eur Heart J 2022;43:3925: measure once in a lifetime; no repeat interval")
    private static let glucose = LabRetestRule(
        routineDays: 3 * 365, watchDays: 365, basis: .guideline,
        source: "ADA Standards of Care, section 2 (diagnosis): screen at least every 3 years; yearly with prediabetes")
    private static let hba1c = LabRetestRule(
        routineDays: 3 * 365, watchDays: 183, basis: .guideline,
        source: "ADA Standards of Care, sections 2 and 6: screen at least every 3 years; at least twice a year when following it "
              + "(quarterly if therapy changed or off target)")
    private static let thyroid = LabRetestRule(
        routineDays: nil, watchDays: 8 * 7, basis: .guideline,
        source: "Jonklaas J et al., ATA hypothyroidism guideline, Thyroid 2014;24:1670: TSH 4-8 weeks after a dose change; "
              + "no routine screening interval for people without thyroid disease")
    private static let vitaminD = LabRetestRule(
        routineDays: nil, watchDays: 90, basis: .guideline,
        source: "Holick MF et al., Endocrine Society, J Clin Endocrinol Metab 2011;96:1911: re-measure 25(OH)D about 3 months "
              + "after starting treatment; Demay MB et al., 2024 guideline advises against routine testing without an indication")
    private static let testosterone = LabRetestRule(
        routineDays: nil, watchDays: 90, basis: .guideline,
        source: "Bhasin S et al., Endocrine Society, J Clin Endocrinol Metab 2018;103:1715: 3-6 months after starting testosterone "
              + "treatment, then yearly; no routine screening in men without symptoms")
    private static let omega = LabRetestRule(
        routineDays: nil, watchDays: 120, basis: .mechanism,
        source: "Harris WS, von Schacky C, Prev Med 2004;39:212 (omega-3 index in red cell membranes); about 4 months because "
              + "red cells live about 120 days. A mechanism, not a guideline number")

    private static let byKey: [String: LabRetestRule] = {
        var t: [String: LabRetestRule] = [:]
        for k in ["lab_total_cholesterol", "lab_hdl_cholesterol", "lab_ldl_cholesterol", "lab_non_hdl_cholesterol",
                  "lab_triglycerides", "lab_chol_hdl_ratio", "lab_apob"] { t[k] = lipid }
        t["lab_lpa"] = lipoproteinA
        t["lab_glucose"] = glucose
        t["lab_hba1c"] = hba1c
        for k in ["lab_tsh", "lab_free_t4", "lab_free_t3"] { t[k] = thyroid }
        t["lab_vitamin_d"] = vitaminD
        for k in ["lab_testosterone_total", "lab_testosterone_free"] { t[k] = testosterone }
        for k in ["lab_omega3_total", "lab_omega3_omegacheck", "lab_omega3_dha", "lab_omega3_dpa", "lab_omega3_epa",
                  "lab_omega6_total", "lab_omega6_3_ratio", "lab_aa_epa_ratio"] { t[k] = omega }
        return t
    }()

    /// The rule for a lab metric key, nil when this table has no published interval for it.
    public static func rule(for key: String) -> LabRetestRule? { byKey[key] }

    /// The keys that have a rule.
    public static var keys: [String] { Array(byKey.keys).sorted() }

    /// Is a retest due? `lastDraw` = the newest draw of that marker. `watching` = the marker is being followed (see above).
    /// `fallbackDays` = a user-set time for markers without a published interval (nil = no dot for those).
    /// Never due without a previous draw (a marker never measured has nothing to retest), and never for a `once` marker.
    public static func isDue(key: String, lastDraw: Date?, now: Date, watching: Bool = false, fallbackDays: Int? = nil) -> Bool {
        guard let lastDraw, lastDraw <= now else { return false }
        let rule = byKey[key]
        if rule?.basis == .once { return false }
        let days: Int?
        if let rule {
            days = (watching ? (rule.watchDays ?? rule.routineDays) : rule.routineDays) ?? fallbackDays
        } else {
            days = fallbackDays
        }
        guard let days, days > 0 else { return false }
        return now.timeIntervalSince(lastDraw) >= Double(days) * 86_400
    }
}
