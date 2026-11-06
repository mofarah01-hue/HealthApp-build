import Foundation
import MGDomain

/// "Current estimated level" for what a lab or scan measured once and we also measure ourselves (D-LOAD-WALK-1 item 14, r9o
/// 2026-10-17). Today that overlap is body composition: an InBody scan (weight, body fat) against the weight Apple Health /
/// the scale records after it. Blood markers have no daily measure of ours (the sun-vitamin-D figure is an oral-dose
/// equivalent, not a blood level), so they get no estimate here; their draw dates and retest dues are in `LabDraws`.
///
/// The InBody file is not in the vault yet: with no scan stored the lines say so ("InBody scan not imported yet").
/// Weight is a measurement, shown as measured. Body fat is NOT measured between scans, so it is given as two bounds, never a
/// point: (a) every kilo gained or lost is fat; (b) fat and lean change in the scan's own proportion, so the percentage does
/// not move. The truth lies between them. Arithmetic only, no published model: labelled "estimate".
public enum LabCurrentLevel {
    public static let placeholder = "InBody scan not imported yet: add it in Log › More › Scan (kind InBody) when the file is there; "
        + "until then there is nothing to compare today's weight with."
    public static let label = "estimate, between two bounds; only the InBody measured body fat"

    public struct Scan: Equatable, Sendable {
        public var at: Date
        public var weightKg: Double
        public var bodyFatPct: Double?

        public init(at: Date, weightKg: Double, bodyFatPct: Double? = nil) {
            self.at = at
            self.weightKg = weightKg
            self.bodyFatPct = bodyFatPct
        }
    }

    /// The newest InBody scan with a weight among the body-composition events (removed and later-than-`upTo` skipped).
    public static func newestInBody(_ events: [EventRecord], upTo: Date) -> Scan? {
        var best: Scan?
        for e in events where !e.removed && e.at <= upTo {
            guard case .scan(let f) = e.payload, f.scanKind == .inbody else { continue }
            let bc = BodyComposition(values: f.values)
            guard let w = bc.numbers["weight_kg"], w > 0, best == nil || e.at > best!.at else { continue }
            best = Scan(at: e.at, weightKg: w, bodyFatPct: bc.numbers["body_fat_pct"])
        }
        return best
    }

    /// The PC's copy of the scan: `pc.labs` carries it as `detail.inbody` (kg, % — converted from the printout's pounds on the PC,
    /// `import_labs.read_inbody`). The newest wins when the PC and a phone-logged scan both exist.
    public static func pcInBody(_ results: [LabResult]) -> Scan? {
        var best: Scan?
        for r in results where r.modelId == "pc.labs" {
            guard case .object(let detail)? = r.extra["detail"], case .object(let o)? = detail["inbody"],
                  case .string(let at)? = o["at"], case .number(let w)? = o["weight_kg"], w > 0,
                  let when = ISO8601DateFormatter().date(from: at) else { continue }
            var fat: Double?
            if case .number(let f)? = o["body_fat_pct"] { fat = f }
            if best == nil || when > best!.at { best = Scan(at: when, weightKg: w, bodyFatPct: fat) }
        }
        return best
    }

    /// Body fat now as (lowest, highest) percent given the scan and today's weight; nil without the scan's body fat.
    /// Gain: (b) is the low bound and (a) the high one; loss: (a) is the low bound. Never below 0 or above 100.
    public static func bodyFatBounds(scan: Scan, weightNowKg: Double) -> (low: Double, high: Double)? {
        guard let pct = scan.bodyFatPct, weightNowKg > 0, scan.weightKg > 0 else { return nil }
        let fat0 = pct / 100 * scan.weightKg
        let allFat = min(100, max(0, (fat0 + (weightNowKg - scan.weightKg)) / weightNowKg * 100))
        return (min(allFat, pct), max(allFat, pct))
    }

    /// Lines for the weight / body fat / lean mass screens. `weightNow` = the newest weight we have (kg, date).
    public static func lines(scan: Scan?, weightNow: (kg: Double, at: Date)?, key: String, calendar: Calendar) -> [String] {
        func day(_ d: Date) -> String { "\(MGFormat.shortDate(d, calendar: calendar)) \(calendar.component(.year, from: d))" }
        func n(_ v: Double) -> String { MGFormat.number(v, decimals: 1) }
        guard let scan else { return [placeholder] }
        var out = ["InBody \(day(scan.at)): \(n(scan.weightKg)) kg" + (scan.bodyFatPct.map { ", body fat \(n($0)) %" } ?? "")]
        guard let now = weightNow, now.at > scan.at else {
            out.append("No weight recorded since the scan (Apple Health or your scale), so nothing newer to compare.")
            return out
        }
        let d = now.kg - scan.weightKg
        let move = abs(d) < 0.05 ? "unchanged" : (d < 0 ? "down \(n(-d)) kg" : "up \(n(d)) kg")
        out.append("Weight now \(n(now.kg)) kg (\(day(now.at)), measured): \(move) since the scan.")
        if key != "weight", let b = bodyFatBounds(scan: scan, weightNowKg: now.kg) {
            out.append("Body fat now: between \(n(b.low)) % and \(n(b.high)) % (\(label)). The low end assumes every kilo "
                + "gained or lost is fat, the high end that fat and lean moved in the scan's own proportion.")
        }
        return out
    }

    /// The same, read from a presenter snapshot (InBody events in `profileRecords`, newest weight in Explore's stored rows).
    static func lines(_ s: PresenterSnapshot, key: String) -> [String] {
        let weight = (s.explore.latest["weight"] ?? []).compactMap { d -> (kg: Double, at: Date)? in
            guard let v = d.metric.value, v.isFinite, v > 0 else { return nil }
            return (v, d.metric.at)
        }.max { $0.at < $1.at }
        let scans = [newestInBody(s.profileRecords, upTo: s.now), pcInBody(s.pcResults)].compactMap { $0 }.filter { $0.at <= s.now }
        return lines(scan: scans.max { $0.at < $1.at }, weightNow: weight, key: key, calendar: s.calendar)
    }
}
