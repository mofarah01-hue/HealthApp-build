import Foundation
import MGDomain

/// Every draw of one measured lab (W10 #96; pc.labs@1 results): "14 Jul 2026 · 600 ng/dL · reported 20.8 nmol/L ·
/// Function Health panel 2026-07-14.md", newest first, one line per draw date.
enum LabDraws {
    /// Bug 9 (M-169): a measured lab is static: it holds until the next draw, so Explore's period does not hide it.
    static func isStatic(_ key: String) -> Bool { key.hasPrefix("lab_") }

    /// The newest draw with a value: from Explore's stored rows, else the PC's pc.labs results; nil when none.
    static func newest(_ s: PresenterSnapshot, key: String) -> Metric? {
        let stored = (s.explore.latest[key] ?? []).map(\.metric)
        let pc = s.pcResults.filter { $0.modelId == "pc.labs" }.flatMap { $0.metrics.filter { $0.name == key } }
        return (stored + pc).filter { $0.value?.isFinite == true }.max { $0.at < $1.at }
    }

    /// A draw as a shown value (units from the metric, the labs' measured style); nil when it has no number.
    static func display(_ lab: Metric, _ s: PresenterSnapshot) -> DisplayValue? {
        guard let v = lab.value, v.isFinite else { return nil }
        let (text, unit) = MetricText.format(v, unit: lab.unit, name: lab.name)
        return .value(text: text, unit: unit, receipt: MetricText.receipt(lab),
                      style: DisplayValue.style(for: lab.tier, uncertainty: nil), sample: s.sample)
    }

    /// T9838: "drawn Tue 14 Jul 2026 · 3 months ago · reported 20.8 nmol/L · Function Health panel 2026-07-14.md": the draw
    /// date, how old it is, and the note's own parts (the reported unit and the source file), no part invented.
    static func caption(_ lab: Metric, _ s: PresenterSnapshot) -> String {
        let date = "drawn \(MGFormat.shortDate(lab.at, calendar: s.calendar)) \(s.calendar.component(.year, from: lab.at))"
        let age = ageWords(days: max(0, Int((s.now.timeIntervalSince(lab.at) / 86_400).rounded(.down))))
        let parts = (lab.note ?? "").components(separatedBy: "; ").filter { !$0.isEmpty && !$0.hasPrefix("drawn ") }
        let source = parts.isEmpty ? [lab.source].filter { !$0.isEmpty } : parts
        return ([date, age] + source).joined(separator: " · ")
    }

    /// "today", "5 days ago", "3 months ago", "2 years ago".
    static func ageWords(days: Int) -> String {
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<60: return "\(days) days ago"
        case ..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }

    static func lines(_ s: PresenterSnapshot, key: String) -> [String] {
        var byDay: [String: Metric] = [:]
        for r in s.pcResults where r.modelId == "pc.labs" {
            for m in r.metrics where m.name == key {
                let d = LocalDay(date: m.at, calendar: s.calendar).iso
                if byDay[d] == nil { byDay[d] = m }
            }
        }
        guard !byDay.isEmpty else { return ["No draw on the phone yet: the PC reads the vault's lab notes (pc.labs)."] }
        var out = byDay.keys.sorted(by: >).compactMap { d -> String? in
            guard let m = byDay[d] else { return nil }
            let date = "\(MGFormat.shortDate(m.at, calendar: s.calendar)) \(s.calendar.component(.year, from: m.at))"
            let parts = (m.note ?? "").components(separatedBy: "; ").filter { !$0.hasPrefix("drawn ") }
            guard let v = m.value, v.isFinite else { return "\(date) · " + (m.note ?? "no value") }
            let (text, unit) = MetricText.format(v, unit: m.unit, name: m.name)
            return ([date, text + (unit.map { " \($0)" } ?? "")] + parts).joined(separator: " · ")
        }
        if let r = retestLine(s, key: key) { out.append(r) }
        return out
    }

    /// "12 weeks" / "4 years" / "90 days" for a retest interval.
    static func period(_ days: Int) -> String {
        if days % 365 == 0 { let y = days / 365; return "\(y) year\(y == 1 ? "" : "s")" }
        if days % 7 == 0 { return "\(days / 7) weeks" }
        return "\(days) days"
    }

    /// T9893 (r9o): when a retest is due, from the published interval of `LabRetest` (its source named). Markers with no
    /// published interval get no line; the dot on the lab itself waits for its owner. Not medical advice for Mo's own result.
    static func retestLine(_ s: PresenterSnapshot, key: String) -> String? {
        guard let rule = LabRetest.rule(for: key), let last = newest(s, key: key)?.at else { return nil }
        let date: (Date) -> String = { "\(MGFormat.shortDate($0, calendar: s.calendar)) \(s.calendar.component(.year, from: $0))" }
        if rule.basis == .once { return "Needs measuring once; no repeat interval (\(rule.source))." }
        if let days = rule.routineDays {
            let next = last.addingTimeInterval(Double(days) * 86_400)
            return LabRetest.isDue(key: key, lastDraw: last, now: s.now)
                ? "Retest due since \(date(next)): routine guidance is every \(period(days)) (\(rule.source))."
                : "Next routine retest from \(date(next)): every \(period(days)) (\(rule.source))."
        }
        if let days = rule.watchDays {
            return "No routine retest interval; while it is being followed, about every \(period(days)) (\(rule.source))."
        }
        return nil
    }
}
