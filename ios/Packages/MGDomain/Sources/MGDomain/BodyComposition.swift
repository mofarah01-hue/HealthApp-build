import Foundation

/// The typed numbers of a body-composition entry (tracker #42, 2026-10-11): an InBody or DEXA scan, or a tape / scale
/// reading logged as scan kind `other`, kept in `scanEvent.values` (contract v0.5 `bodyCompositionValues`,
/// sync-api.schema.json). The Swift type of `values` stays the v0.4 free object, so other keys a source prints survive
/// a round trip; this type reads and writes the typed ones. Each number is as the device printed it — never converted.
public struct BodyComposition: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var key: String
        public var label: String
        public var unit: String
    }

    /// Display order. Keys equal `bodyCompositionValues` in sync-api.schema.json (BodyCompositionTests checks).
    public static let fields: [Field] = [
        Field(key: "weight_kg", label: "Weight", unit: "kg"),
        Field(key: "body_fat_pct", label: "Body fat", unit: "%"),
        Field(key: "fat_mass_kg", label: "Fat mass", unit: "kg"),
        Field(key: "lean_mass_kg", label: "Lean mass", unit: "kg"),
        Field(key: "skeletal_muscle_kg", label: "Skeletal muscle", unit: "kg"),
        Field(key: "total_body_water_l", label: "Body water", unit: "L"),
        Field(key: "visceral_fat_level", label: "Visceral fat level", unit: "level"),
        Field(key: "visceral_fat_area_cm2", label: "Visceral fat area", unit: "cm²"),
        Field(key: "bmr_kcal", label: "BMR (device)", unit: "kcal"),
        Field(key: "bone_mass_kg", label: "Bone mass", unit: "kg"),
        Field(key: "bone_density_g_cm2", label: "Bone density", unit: "g/cm²"),
        Field(key: "bone_t_score", label: "Bone T-score", unit: "SD"),
        Field(key: "waist_cm", label: "Waist", unit: "cm"),
        Field(key: "hip_cm", label: "Hip", unit: "cm"),
        Field(key: "phase_angle_deg", label: "Phase angle", unit: "°"),
        // T38 (2026-10-12): the rest of an InBody printout. Every field optional; a printout without one leaves it blank.
        Field(key: "ecw_tbw_ratio", label: "ECW/TBW", unit: "ratio"),
        Field(key: "inbody_score", label: "InBody score", unit: "points"),
        Field(key: "segmental_fat_trunk_kg", label: "Trunk fat", unit: "kg"),
        Field(key: "segmental_fat_legs_kg", label: "Legs fat", unit: "kg"),
        Field(key: "segmental_fat_arms_kg", label: "Arms fat", unit: "kg"),
        // T119 (2026-10-13): the tape set beside waist and hip (US Navy body-fat estimate needs neck); logged as scan kind other.
        Field(key: "neck_cm", label: "Neck", unit: "cm"),
        Field(key: "chest_cm", label: "Chest", unit: "cm"),
        Field(key: "bicep_cm", label: "Bicep", unit: "cm"),
        Field(key: "thigh_cm", label: "Thigh", unit: "cm"),
        Field(key: "calf_cm", label: "Calf", unit: "cm"),
    ]

    /// Scan kinds that are body-composition entries.
    public static let kinds: Set<ScanFields.ScanKind> = [.inbody, .dexa, .other]

    /// The typed numbers present, by key.
    public var numbers: [String: Double]

    public init(numbers: [String: Double] = [:]) {
        self.numbers = numbers.filter { $0.value.isFinite }
    }

    /// Reads the typed keys of `scanEvent.values`; other keys are ignored here (and kept by the event).
    public init(values: [String: JSONValue]?) {
        var n: [String: Double] = [:]
        for f in BodyComposition.fields {
            if case .number(let d)? = values?[f.key], d.isFinite { n[f.key] = d }
        }
        self.init(numbers: n)
    }

    /// `values` with the typed keys set from `numbers` (existing other keys kept).
    public func merged(into values: [String: JSONValue]?) -> [String: JSONValue]? {
        var out = values ?? [:]
        for f in BodyComposition.fields { out[f.key] = numbers[f.key].map(JSONValue.number) }
        return out.isEmpty ? nil : out
    }

    public var isEmpty: Bool { numbers.isEmpty }
    public var waistCm: Double? { numbers["waist_cm"] }

    /// The newest waist measured at or before `upTo` among body-composition scans (removed events skipped).
    /// ALG-036's Nes VO₂max reads it (MGSignal DayPipeline).
    public static func latestWaist(in events: [EventRecord], upTo: Date) -> Double? {
        var best: (Date, Double)?
        for e in events where !e.removed && e.at <= upTo {
            guard case .scan(let f) = e.payload, kinds.contains(f.scanKind),
                  let w = BodyComposition(values: f.values).waistCm else { continue }
            if best == nil || e.at > best!.0 { best = (e.at, w) }
        }
        return best?.1
    }
}
