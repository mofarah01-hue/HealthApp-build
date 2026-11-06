import Foundation
import MGDomain

/// r9p (D-LOAD-WALK-2, D-POP-PRIOR): the wording of the load and body readouts that sit beside strain.
///
/// * "This week vs your 4-week average": two numbers and the percent difference. No ratio, no zone, no injury or risk word
///   (the acute:chronic ratio is not an injury predictor: Impellizzeri et al. 2020).
/// * Session RPE (CR-10, Foster 2001) and the injury / soreness entries are shown beside the load, as Mo's own inputs.
/// * Hydration: drinks logged next to the EFSA reference, and the sweat rate as 'population' or 'yours (N sessions)'.
enum LoadReadouts {
    /// The CR-10 ratings, 0 to 10.
    static let rpeScale: [Int] = Array(0...10)

    /// Foster's verbal anchors on the CR-10 scale; the in-between numbers carry no word.
    static func rpeTitle(_ n: Int) -> String {
        switch n {
        case 0: return "0 Rest"
        case 1: return "1 Very easy"
        case 2: return "2 Easy"
        case 3: return "3 Moderate"
        case 4: return "4 Somewhat hard"
        case 5: return "5 Hard"
        case 7: return "7 Very hard"
        case 10: return "10 Maximal"
        default: return "\(n)"
        }
    }

    private static func au(_ v: Double) -> String { MGFormat.number(v, decimals: 0) }

    /// "This week 1,050 au vs your 4-week average 788 au: 33 % above (yours, 28 days)".
    static func weekLine(_ s: PresenterSnapshot) -> String? {
        guard let w = s.metric(.loadWeek, variant: "ALG-036:week", window: "day"),
              let a = s.metric(.loadWeek, variant: "ALG-036:week4", window: "day") else { return nil }
        guard let this = w.value, let avg = a.value, this.isFinite, avg.isFinite, avg > 0 else {
            return "This week vs your 4-week average: " + (w.note ?? a.note ?? "learning")
        }
        let pct = (this / avg - 1) * 100
        let how: String
        if abs(pct) < 1 { how = "about the same" } else {
            how = "\(MGFormat.number(abs(pct), decimals: 0)) % \(pct > 0 ? "above" : "below")"
        }
        var line = "This week \(au(this)) au (TRIMP) vs your 4-week average \(au(avg)) au: \(how)"
        if let basis = a.note, let r = basis.range(of: "(yours, ") {
            line += " " + String(basis[r.lowerBound...].prefix { $0 != ")" }) + ")"
        }
        return line
    }

    /// The week's session-RPE load, when at least one session was rated.
    static func srpeWeekLine(_ s: PresenterSnapshot) -> String? {
        guard let m = s.metric(.loadWeek, variant: "ALG-036:srpe_week", window: "day"), let v = m.value, v.isFinite else {
            return nil
        }
        return "Session-RPE load this week \(au(v)) au" + (m.note.map { " (\($0))" } ?? "")
    }

    /// Soreness and injuries from the log, newest per body area, active ones only: "Sore: left calf 6/10 (Oct 15)".
    static func bodyLines(_ s: PresenterSnapshot, withinDays: Int = 14) -> [String] {
        let since = s.now.addingTimeInterval(-Double(withinDays) * 86_400)
        var seen = Set<String>()
        var out: [String] = []
        for e in s.profileRecords.sorted(by: { $0.at > $1.at }) where !e.removed && e.at >= since {
            guard case .record(let f) = e.payload, f.kind == .soreness || f.kind == .injury,
                  f.status != .resolved, f.end == nil else { continue }
            let side = f.side.flatMap { $0 == .notApplicable ? nil : $0.rawValue }
            let area = ([side, f.bodyPart].compactMap { $0 }.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
            let key = f.kind.rawValue + "|" + area.lowercased()
            guard seen.insert(key).inserted else { continue }
            let c = s.calendar.dateComponents([.month, .day], from: e.at)
            let when = "\(PCHistoryText.months[max(0, (c.month ?? 1) - 1)]) \(c.day ?? 1)"
            let level = f.level.map { " \($0)/10" } ?? ""
            out.append("\(f.kind == .injury ? "Injury" : "Sore"): \(area.isEmpty ? "area not named" : area)\(level) (\(when))")
        }
        return out
    }

    /// The note under the strain panel: the plain week comparison, the rated load and the body log, all Mo's own numbers.
    static func strainNote(_ s: PresenterSnapshot) -> String? {
        let lines = [weekLine(s), srpeWeekLine(s)].compactMap { $0 } + bodyLines(s)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// One workout's lines: load score against his own sessions, rating load, sweat loss, then the week and the body log.
    static func workoutLines(_ s: PresenterSnapshot, metrics: [Metric]) -> [String] {
        func m(_ key: MetricKey, _ variant: String) -> Metric? { s.metric(key.rawValue, variant: variant, window: "workout", in: metrics) }
        var out: [String] = []
        if let x = m(.loadSession, "ALG-036:score") {
            if let v = x.value, v.isFinite {
                out.append("Load score: heavier than \(MGFormat.number(v, decimals: 0)) % of " + (x.note ?? "your earlier sessions of this type"))
            } else {
                out.append("Load score: " + (x.note ?? "learning"))
            }
        }
        if let x = m(.loadSession, "ALG-036:srpe") {
            if let v = x.value, v.isFinite {
                out.append("Session rating load \(MGFormat.number(v, decimals: 0)) au (" + (x.note ?? "rating x minutes") + ")")
            } else {
                out.append("Session rating load: " + (x.note ?? "not rated yet"))
            }
        }
        if let x = m(.hydrationGoal, "ALG-135:sweat") {
            if let v = x.value, v.isFinite {
                out.append("Sweat loss about \(MGFormat.number(v, decimals: 0)) ml: " + (x.note ?? "from your weights"))
            } else {
                out.append("Sweat loss: " + (x.note ?? "log your weights"))
            }
        }
        out += [weekLine(s), srpeWeekLine(s)].compactMap { $0 } + bodyLines(s)
        return out
    }

    /// "Drinks logged today 1,750 ml of the 2,500 ml EFSA reference" (reference = total water, drinks and food).
    static func hydrationLine(_ s: PresenterSnapshot) -> String? {
        guard let ref = s.metric(.hydrationGoal, variant: "ALG-135", window: "day"), let r = ref.value, r.isFinite else {
            return nil
        }
        let refText = "\(MGFormat.number(r, decimals: 0)) ml EFSA reference (population value, total water: drinks and food)"
        guard let i = s.metric(.hydrationGoal, variant: "ALG-135:intake", window: "day"), let v = i.value, v.isFinite else {
            return "No drinks logged today. The \(refText)."
        }
        return "Drinks logged today \(MGFormat.number(v, decimals: 0)) ml of the \(refText)."
    }
}
