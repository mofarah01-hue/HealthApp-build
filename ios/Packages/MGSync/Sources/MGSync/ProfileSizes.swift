import Foundation
import MGDomain

// T9918 (2026-10-17, Mo e-35: "the Me profile and sizes go into the PC profile"): the newest tape size of each kind, taken
// from the Log scan entries (waist, hip, neck, chest, bicep, thigh, calf), goes to the PC with the profile as `body_sizes`.
// Height and weight already travel as `height_cm` / `weight_kg`. Pure: the caller hands over the scan events.

public enum ProfileSizes {
    /// The tape keys of `BodyComposition.fields` that are sizes (cm), in the order the PC file lists them.
    public static let keys = ["waist_cm", "hip_cm", "neck_cm", "chest_cm", "bicep_cm", "thigh_cm", "calf_cm"]

    /// The newest value of each size key among body-composition scans (removed events skipped), with its local day.
    /// A size that was never measured is absent (never 0). A value that is not a positive number is skipped.
    public static func latest(from events: [EventRecord], calendar: Calendar = .current) -> [String: BodySize] {
        var best: [String: (at: Date, cm: Double)] = [:]
        for e in events where !e.removed {
            guard case .scan(let f) = e.payload, BodyComposition.kinds.contains(f.scanKind) else { continue }
            let numbers = BodyComposition(values: f.values).numbers
            for k in keys {
                guard let v = numbers[k], v > 0 else { continue }
                if let cur = best[k], cur.at >= e.at { continue }
                best[k] = (e.at, v)
            }
        }
        return best.mapValues { BodySize(cm: $0.cm, on: LocalDay(date: $0.at, calendar: calendar).iso) }
    }
}
