import Foundation
import MGDomain

/// "Your ages" (W10, Mo 2026-10-11 21:30: "blood test aging predicted age and all of that these don't make sense").
/// Every age model on one screen, each as "Biological age 30.7 — 5.6 years older than your 25", the method in one plain
/// line ("PhenoAge, from your 14 Jul labs"), the draw date and what moves it. Lab ages compare with your age AT THE
/// DRAW (the model's own acceleration); the phone's ages with your age today (Profile birth date).
public enum AgesPresenter {
    struct Model {
        var id: String
        var key: String
        var accelKey: String?
        var name: String
        var lab: Bool
        var moves: String
    }

    static let models: [Model] = [
        Model(id: "phenoage", key: "phenoage", accelKey: "phenoage_accel", name: "PhenoAge", lab: true,
              moves: "Moves with CRP, glucose, albumin, creatinine, RDW, ALP, white cells, lymphocytes and MCV — your "
              + "next blood draw updates it."),
        Model(id: "kdm", key: "kdm_bioage", accelKey: "kdm_bioage_accel", name: "KDM", lab: true,
              moves: "Moves with the same blood markers, each weighed by how fast it changes with age in NHANES."),
        Model(id: "fitness", key: "fitness_age", accelKey: nil, name: "Fitness age", lab: false,
              moves: "Nes's definition: the age at which a typical healthy person of your sex has your VO₂max. "
              + "Moves with VO₂max: a lower resting heart rate and regular hard sessions bring it down."),
        // D-LOAD-WALK-1 item 9: the Body Age "vitality" readout is removed; CosinorAge (from 100 Hz motion) is what body_age holds now.
        Model(id: "body", key: "body_age", accelKey: nil, name: "CosinorAge", lab: false,
              moves: "Moves with the daily rhythm of your wrist movement; needs 100 Hz motion switched on."),
        // T15: Function Health's own number, read from the lab report in the vault (lab_function_bio_age), not computed
        Model(id: "function", key: "lab_function_bio_age", accelKey: nil, name: "Function Health", lab: true,
              moves: "Function's own number, read from your lab report; your next draw updates it."),
    ]

    /// The PC's KDM note opens with this when the person's age at the draw is outside the model's reference ages
    /// (alg/bioage.py `outside_range_note`).
    static let outsideRangePrefix = "outside its reference age range"

    /// Metric keys whose detail links to "Your ages".
    public static let keys: Set<String> = ["phenoage", "phenoage_accel", "kdm_bioage", "kdm_bioage_accel", "hd_distance",
                                           "fitness_age", "body_age", "lab_function_bio_age"]

    /// The "Your ages" line of the model behind `key` (the metric detail shows it above "All your ages ›").
    static func line(_ s: PresenterSnapshot, key: String) -> String? {
        if key == "hd_distance" { return hdRow(s).title }
        guard let m = models.first(where: { $0.key == key || $0.accelKey == key }) else { return nil }
        return row(s, m, ageNow: ageNow(s)).title
    }

    public static func make(_ s: PresenterSnapshot) -> InfoScreenState {
        let age = ageNow(s)
        var rows: [InfoScreenState.Row] = []
        for m in models {
            rows.append(row(s, m, ageNow: age))
        }
        rows.insert(hdRow(s), at: 2)
        let summary = age.map { "You are \($0) (from your birth date)." }
            ?? "Your age isn't set — Preferences › Profile › Use values from Apple Health, or type your birth date."
        return InfoScreenState(sample: s.sample, kicker: "BIOLOGICAL AGE", title: "Your ages", summary: summary,
                               sections: [InfoScreenState.Section(id: "ages", title: "Every age model",
                                                                  note: "older / younger than your age", rows: rows)])
    }

    /// Whole years from the Profile birth date to now; nil when not set.
    static func ageNow(_ s: PresenterSnapshot) -> Int? {
        guard let b = s.settings.profile.birthDate else { return nil }
        let today = LocalDay(date: s.now, calendar: s.calendar)
        var years = today.year - b.year
        if today.iso.dropFirst(5) < b.iso.dropFirst(5) { years -= 1 }
        return years
    }

    /// The newest valued row of `key` (own, PC, imported — `Outputs.ordered`), else the newest blank (for its reason).
    static func newest(_ s: PresenterSnapshot, _ key: String) -> Metric? {
        let rows = Outputs.ordered(s.explore.latest[key] ?? []).map(\.metric)
            + s.metrics.filter { $0.name == key }
        return rows.filter { $0.value?.isFinite ?? false }.max { $0.at < $1.at } ?? rows.first
    }

    /// " (outside its reference range)" for a KDM age whose note says the person is outside the model's ages; else "".
    static func rangeFlag(_ m: Model, _ met: Metric) -> String {
        m.id == "kdm" && (met.note ?? "").hasPrefix(outsideRangePrefix) ? " (outside its reference range)" : ""
    }

    /// "14 Jul" in the snapshot's calendar.
    static func dayMonth(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.day, .month], from: d)
        return "\(c.day ?? 0) \(MGFormat.monthShort[((c.month ?? 1) - 1) % 12])"
    }

    /// "5.6 years older than your 25" / "2.1 years younger than your 33" / "the same as your 25".
    public static func comparison(bio: Double, age: Double) -> String {
        let d = bio - age
        let ageText = String(Int(age.rounded(.down)))
        if abs(d) < 0.05 { return "the same as your \(ageText)" }
        return "\(MGFormat.number(abs(d), decimals: 1)) years \(d > 0 ? "older" : "younger") than your \(ageText)"
    }

    static func row(_ s: PresenterSnapshot, _ m: Model, ageNow: Int?) -> InfoScreenState.Row {
        let open = UIIntent.openMetric(key: m.key, variant: nil)
        guard let met = newest(s, m.key), let bio = met.value, bio.isFinite else {
            let why = newest(s, m.key)?.note ?? "not computed yet"
            return InfoScreenState.Row(id: m.id, title: "\(m.name): no value yet", lines: [why, m.moves], intent: open)
        }
        var lines: [String] = []
        let headline: String
        if m.lab {
            let draw = dayMonth(met.at, s.calendar)
            lines.append("\(m.name), from your \(draw) labs")
            // D-LOAD-WALK-1 item 10: a lab age outside its model's reference age range says so (the PC note opens with that clause).
            if m.id == "kdm", let n = met.note, n.hasPrefix(outsideRangePrefix) {
                lines.append(String(n.prefix { $0 != ";" }))
            }
            lines.append("Drawn \(MGFormat.shortDate(met.at, calendar: s.calendar)) \(s.calendar.component(.year, from: met.at))")
            if let ak = m.accelKey, let acc = newest(s, ak)?.value, acc.isFinite {
                headline = "Biological age \(MGFormat.number(bio, decimals: 1))\(rangeFlag(m, met)) — " + comparison(bio: bio, age: bio - acc)
            } else if let a = ageNow {
                headline = "Biological age \(MGFormat.number(bio, decimals: 1)) — " + comparison(bio: bio, age: Double(a))
            } else {
                headline = "Biological age \(MGFormat.number(bio, decimals: 1))"
            }
        } else {
            lines.append("\(m.name), from your strap data (\(met.variant ?? met.method ?? "phone"))")
            // CosinorAge and Fitness age are estimates; the note carries the inputs
            let label = (m.id == "body" || m.id == "fitness") ? " (estimate)" : ""
            if m.id == "body" || m.id == "fitness" {
                if let n = met.note { lines.append(n) }
            }
            if let a = ageNow {
                headline = "\(m.name) \(MGFormat.number(bio, decimals: 1))\(label) — " + comparison(bio: bio, age: Double(a))
            } else {
                headline = "\(m.name) \(MGFormat.number(bio, decimals: 1))\(label) — your age isn't set"
            }
        }
        lines.append(m.moves)
        return InfoScreenState.Row(id: m.id, title: headline, lines: lines, intent: open)
    }

    /// Homeostatic dysregulation as the percentile its note carries ("62th percentile of the reference's own
    /// distances"): how far the draw sits from young healthy people, higher = further.
    static func hdRow(_ s: PresenterSnapshot) -> InfoScreenState.Row {
        let open = UIIntent.openMetric(key: "hd_distance", variant: nil)
        let moves = "Moves with the same blood markers: how far they sit, together, from young healthy adults."
        guard let m = newest(s, "hd_distance"), let v = m.value, v.isFinite else {
            return InfoScreenState.Row(id: "hd", title: "HD: no value yet",
                                       lines: [newest(s, "hd_distance")?.note ?? "not computed yet", moves],
                                       intent: open)
        }
        var title = "Distance from young-healthy \(MGFormat.number(v, decimals: 1))"
        if let note = m.note, let r = note.range(of: #"(\d+)(st|nd|rd|th) percentile"#, options: .regularExpression) {
            let pct = note[r].prefix { $0.isNumber }
            title = "Further from young-healthy than \(pct) % of young adults"
        }
        return InfoScreenState.Row(id: "hd", title: title,
                                   lines: ["HD (homeostatic dysregulation), from your \(dayMonth(m.at, s.calendar)) labs",
                                           moves], intent: open)
    }
}
