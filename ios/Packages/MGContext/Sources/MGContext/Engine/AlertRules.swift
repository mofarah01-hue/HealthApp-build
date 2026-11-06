import Foundation
import MGDomain

/// Health alerts from what the pipelines stored (wave 2, 2026-10-11; audit D2: "no alert is ever raised" — the app
/// passed `alerts: []`). Mo: breathing disturbance "should hit when it catches it". Pure: the app passes the wake day's
/// own metrics and the events around last night; the context engine turns unseen alerts into the top Moment card, and
/// the app posts each new one once as an ALERT notification (quiet hours apply: NotifyPolicy).
///
/// Rules:
/// - possible AF: any G-AF member (ALG-013, ALG-129 pNN70 / COSEn) with class 1 for the night;
/// - breathing disturbance: one or more breathing events (contract `breathingEvent`: ALG-023 CVHR, pauses, desats — any
///   detector) between 18:00 the evening before and noon of the wake day, not retracted, not removed;
/// - unusual night: ALG-112's distance over the χ² 99.9 % gate for the features it used — ours v0, NOT calibrated on
///   Mo's data (ALG-112 is research tier and ships no gate: OpenStrap measured 0.197 false candidates a night with a
///   99 % gate at 10 baseline nights, so this one is stricter); the evidence line says so.
/// An alert's id is stable per pattern and night, so a seen one does not come back until a new night raises it.
public enum AlertRules {
    /// sqrt of the χ² 99.9 % quantile for k = 1…4 degrees of freedom (10.83, 13.82, 16.27, 18.47).
    static let anomalyGate: [Int: Double] = [1: 3.291, 2: 3.717, 3: 4.033, 4: 4.298]

    public static func alerts(metrics: [Metric], events: [EventRecord], day: LocalDay, calendar: Calendar,
                              dismissedAt: Date?) -> [AlertInfo] {
        var out: [AlertInfo] = []
        let own = metrics.filter { !ImportedHistory.isImported($0) }

        // possible AF
        let af = own.filter { $0.name == MetricKey.afScreen.rawValue && $0.value.map { Int($0.rounded()) } == 1 }
        if let newest = af.max(by: { $0.at < $1.at }) {
            let who = af.compactMap(\.variant).sorted().joined(separator: ", ")
            out.append(AlertInfo(id: "af:\(day.iso)", kind: .possibleAF, raisedAt: newest.at,
                                 sentence: "The rhythm screen flagged a possible irregular rhythm last night.",
                                 evidence: "\(who) · an ECG reading can check it"))
        }

        // breathing disturbance
        let tz = calendar.timeZone
        let from = day.adding(days: -1).start(in: tz).addingTimeInterval(18 * 3600)
        let to = day.start(in: tz).addingTimeInterval(12 * 3600)
        var kinds: [String: Int] = [:]
        var detectors = Set<String>()
        var last: Date?
        for e in events where !e.removed && e.at >= from && e.at < to {
            guard case .breathing(let f) = e.payload, f.retracted != true else { continue }
            kinds[f.kind.rawValue, default: 0] += 1
            if let d = f.detector { detectors.insert(d) }
            last = max(last ?? f.end, f.end)
        }
        if let last {
            let n = kinds.values.reduce(0, +)
            let byKind = kinds.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            let by = detectors.isEmpty ? "" : " · " + detectors.sorted().joined(separator: ", ")
            out.append(AlertInfo(id: "breath:\(day.iso)", kind: .breathingDisturbance, raisedAt: last,
                                 sentence: "The breathing screen flagged \(n) event\(n == 1 ? "" : "s") last night. It is a screen, not a diagnosis.",
                                 evidence: byKind + by))
        }

        // unusual night (ALG-112)
        if let m = own.first(where: { $0.name == MetricKey.anomaly.rawValue && $0.variant == "ALG-112" }),
           let d = m.value, d.isFinite {
            let k = featureCount(m.note)
            let gate = anomalyGate[k] ?? anomalyGate[4]!
            if d >= gate {
                out.append(AlertInfo(id: "anomaly:\(day.iso)", kind: .anomaly, raisedAt: m.at,
                                     sentence: "Last night was far from your normal across \(k) signals "
                                         + "(distance \(MGFormat.number(d, decimals: 1))).",
                                     evidence: "ALG-112 · research · gate χ² 99.9 % = \(MGFormat.number(gate, decimals: 1))"
                                         + ", ours v0, not calibrated on your nights yet"))
            }
        }
        return out.map { a in
            var a = a
            a.seen = dismissedAt.map { $0 >= a.raisedAt } ?? false
            return a
        }
    }

    /// "distance over rhr, hrv, temp; research, …" → 3; 4 (the strictest gate) when the note does not say.
    static func featureCount(_ note: String?) -> Int {
        guard let note, let r = note.range(of: "distance over ") else { return 4 }
        let list = note[r.upperBound...].prefix { $0 != ";" }
        let n = list.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        return (1...4).contains(n) ? n : 4
    }
}
