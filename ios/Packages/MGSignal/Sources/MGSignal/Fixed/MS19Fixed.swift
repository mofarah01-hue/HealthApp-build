import Foundation

/// MS-19 `readiness_orchard_fixed` — the `_fixed` port of Orchard "Readiness" (T16, D-044-T16). The original (`MS19`,
/// Script/MSReadiness.swift) stays as it is: 5 + 1.2·mix reads only 5.0 to 6.2 of 10 from 0–1 inputs. Here the same
/// INFERRED weights (they sum to 1) are scaled to the whole range: 10·(0.4·vitals + 0.3·sleep + 0.3·activity), clipped
/// to 0–10; a 0–100 input still saturates at 10. Python reference: pclab/mglab/ref/orchard_fixed.py; golden:
/// shared/golden/ms_fixed/MS-19_fixed.json.
public enum MS19Fixed {
    public static let id = "MS-19_fixed"
    public static let function = "readiness_orchard_fixed"

    public static func readinessOrchardFixed(activity: Double, vitals: Double, sleepScore: Double) -> Computed<Double> {
        if let m = ScriptGuard.finite(("activity", activity), ("vitals", vitals), ("sleepScore", sleepScore)) {
            return .failure(m)
        }
        let mix: Double = 0.4 * vitals + 0.3 * sleepScore + 0.3 * activity
        return .success(min(max(10 * mix, 0), 10))
    }
}
