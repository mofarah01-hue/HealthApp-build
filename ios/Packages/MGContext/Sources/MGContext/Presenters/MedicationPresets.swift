import Foundation
import MGDomain

/// T102 / T9973: the one-tap dose presets of the Log tab's Medication row. They come from the user's own Medications
/// list (Settings, seeded from his local file: `PresetLists`), never from names written in source. Logged only, never
/// dose advice. The tapped preset's own dose is the logged dose, even when a schedule lists another one. A custom dose
/// goes through the Medication form (editable strength); the time can be edited after logging.
public struct MedicationPreset: Equatable, Sendable {
    public var name: String
    public var mg: Double

    /// "Name 30 mg" (what the tap carries in `QuickLogAction.medication(name:)`).
    public var title: String { "\(name) \(MGFormat.number(mg, decimals: mg == mg.rounded() ? 0 : 1)) mg" }
}

public enum MedicationPresets {
    /// The list's entries that have a strength in mg (an entry with no strength, or in another unit, is not a one-tap dose).
    public static func presets(from lists: PresetLists) -> [MedicationPreset] {
        lists.medications.compactMap { e in
            guard let mg = e.amount, mg.isFinite, mg > 0, e.unit.caseInsensitiveCompare("mg") == .orderedSame else { return nil }
            return MedicationPreset(name: e.name, mg: mg)
        }
    }

    public static func preset(titled title: String, in lists: PresetLists) -> MedicationPreset? {
        presets(from: lists).first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    /// The contract medication event: 1 capsule of `mg`, taken at `at` (`loggedAt` = the tap).
    public static func takenEvent(_ p: MedicationPreset, at: Date, scheduleId: String? = nil) -> EventRecord {
        EventRecord(at: at, loggedAt: at, source: .manual,
                    payload: .medication(MedicationFields(name: p.name, dose: p.mg, doseUnit: "mg", status: .taken,
                                                          scheduleId: scheduleId, category: .prescription, units: 1,
                                                          unitKind: .capsule)))
    }
}
