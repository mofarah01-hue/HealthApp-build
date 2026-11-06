import Foundation
import MGDomain

/// Event log → algorithm inputs for the behaviour family. Pure mapping, no algorithm: what counts as a caffeine dose, a
/// vape hit or a medication intake is decided here once so every caller (pipelines, presenters) agrees.
///   * a removed event (soft remove, D10) never counts;
///   * caffeine: `at` = start, `finishedAt` = finish (nil = still drinking), `caffeineMg` as logged (nil → the curve says
///     "no mg" instead of guessing, R6);
///   * vape: one event per hit or per press of the button (`vape.hits` puffs, default 1). A DETECTED hit that Mo has not
///     confirmed (or has rejected) is a guess and is left out — no fake counts;
///   * medication: status `skipped` is not an intake; `dose` is used as logged (relative curves only need the ratio).
public enum BehaviourEvents {
    /// Caffeine drinks in start order.
    public static func caffeineDoses(from events: [EventRecord]) -> [ALG060.Dose] {
        var out: [ALG060.Dose] = []
        for e in events {
            guard !e.removed, case .substance(let f) = e.payload, f.kind == .caffeine else { continue }
            out.append(ALG060.Dose(start: e.at, finish: f.finishedAt, mg: f.caffeineMg))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Vape events (with puffs) in time order; unconfirmed or rejected detections are left out.
    public static func vapeHits(from events: [EventRecord]) -> [ALG068.Hit] {
        var out: [ALG068.Hit] = []
        for e in events {
            guard !e.removed, case .substance(let f) = e.payload,
                  f.kind == .vapeTick || f.kind == .vape else { continue }
            if let status = f.vape?.detectedStatus, status != .confirmed { continue }
            let puffs = f.vape?.hits ?? 1
            out.append(ALG068.Hit(at: e.at, hits: puffs > 0 ? puffs : 1))
        }
        return out.sorted { $0.at < $1.at }
    }

    /// Intakes of one medication (case-insensitive name) as dose events for ALG-143, in time order.
    public static func medicationDoses(from events: [EventRecord], named name: String) -> [ALG143.Dose] {
        var out: [ALG143.Dose] = []
        for e in events {
            guard let f = takenMedication(e, named: name) else { continue }
            out.append(ALG143.Dose(at: e.at, mg: f.dose))
        }
        return out.sorted { $0.at < $1.at }
    }

    /// Times of the intakes of one medication (case-insensitive name), for ALG-069 counts, adherence and co-timing.
    public static func medicationTimes(from events: [EventRecord], named name: String) -> [Date] {
        var out: [Date] = []
        for e in events where takenMedication(e, named: name) != nil { out.append(e.at) }
        return out.sorted()
    }

    private static func takenMedication(_ e: EventRecord, named name: String) -> MedicationFields? {
        guard !e.removed, case .medication(let f) = e.payload else { return nil }
        if f.status == .skipped { return nil }
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let have = (f.name ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return (!wanted.isEmpty && have == wanted) ? f : nil
    }
}
