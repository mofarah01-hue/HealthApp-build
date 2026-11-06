import Foundation
import MGDomain

/// T119 (2026-10-13): body fat estimated from tape measures (Log › More › Scan › other: neck, waist, hip), anchored on
/// the InBody. Two numbers: the US Navy circumference formula on the newest tape (no anchor), and the InBody's body fat
/// plus how far the Navy figure has moved since the tape taken with that InBody. Always an estimate.
public struct TapeBodyFat: Equatable, Sendable {
    public static let label = "estimate - tape measures can be off by several percentage points; the InBody is the anchor"
    /// A tape counts as "taken with the InBody" within this many days of it.
    static let baselineDays = 14.0

    /// Navy formula on the newest tape alone.
    public var tapeOnlyPct: Double
    /// InBody body fat + the Navy change since the baseline tape; nil without an InBody or a baseline tape.
    public var anchoredPct: Double?
    public var changePoints: Double?
    public var fatMassKg: Double?
    public var tapeAt: Date
    public var inbodyAt: Date?

    /// US Navy body-fat formula (Hodgdon & Beckett, 1984), all lengths in cm: male 495 / (1.0324 − 0.19077·log10(waist −
    /// neck) + 0.15456·log10(height)) − 450; female 495 / (1.29579 − 0.35004·log10(waist + hip − neck) +
    /// 0.22100·log10(height)) − 450. nil without the inputs the sex needs (female: hip), or for sex other.
    public static func navy(sex: Profile.Sex?, heightCm: Double?, waistCm: Double?, neckCm: Double?, hipCm: Double?) -> Double? {
        guard let sex, let h = heightCm, let waist = waistCm, let neck = neckCm, h > 0, waist > 0, neck > 0 else { return nil }
        switch sex {
        case .male:
            guard waist > neck else { return nil }
            return 495 / (1.0324 - 0.19077 * log10(waist - neck) + 0.15456 * log10(h)) - 450
        case .female:
            guard let hip = hipCm, hip > 0, waist + hip > neck else { return nil }
            return 495 / (1.29579 - 0.35004 * log10(waist + hip - neck) + 0.22100 * log10(h)) - 450
        case .other:
            return nil
        }
    }

    /// `events`: the body-composition scans (removed ones skipped, later than `upTo` skipped). `fallbackWeightKg`: the
    /// profile weight, used when no scan carries one.
    public static func estimate(events: [EventRecord], sex: Profile.Sex?, heightCm: Double?, fallbackWeightKg: Double? = nil,
                                upTo: Date) -> TapeBodyFat? {
        func navy(_ b: BodyComposition) -> Double? {
            TapeBodyFat.navy(sex: sex, heightCm: heightCm, waistCm: b.numbers["waist_cm"], neckCm: b.numbers["neck_cm"],
                             hipCm: b.numbers["hip_cm"])
        }
        var tapes: [(at: Date, bc: BodyComposition, navy: Double)] = []
        var inbody: (at: Date, bc: BodyComposition)?
        var weight: (Date, Double)?
        for e in events where !e.removed && e.at <= upTo {
            guard case .scan(let f) = e.payload, BodyComposition.kinds.contains(f.scanKind) else { continue }
            let bc = BodyComposition(values: f.values)
            if let w = bc.numbers["weight_kg"], weight == nil || e.at > weight!.0 { weight = (e.at, w) }
            if f.scanKind == .inbody, bc.numbers["body_fat_pct"] != nil, inbody == nil || e.at > inbody!.at {
                inbody = (e.at, bc)
            } else if f.scanKind == .other, let n = navy(bc) {
                tapes.append((e.at, bc, n))
            }
        }
        guard let latest = tapes.max(by: { $0.at < $1.at }) else { return nil }
        var out = TapeBodyFat(tapeOnlyPct: latest.navy, anchoredPct: nil, changePoints: nil, fatMassKg: nil,
                              tapeAt: latest.at, inbodyAt: inbody?.at)
        if let inbody, let base = inbody.bc.numbers["body_fat_pct"],
           let baseline = tapes.filter({ abs($0.at.timeIntervalSince(inbody.at)) <= baselineDays * 86_400 && $0.at <= latest.at })
               .min(by: { abs($0.at.timeIntervalSince(inbody.at)) < abs($1.at.timeIntervalSince(inbody.at)) }) {
            out.changePoints = latest.navy - baseline.navy
            out.anchoredPct = min(100, max(0, base + latest.navy - baseline.navy))
        }
        if let kg = weight?.1 ?? fallbackWeightKg {
            out.fatMassKg = max(0, out.anchoredPct ?? latest.navy) / 100 * kg
        }
        return out
    }
}
