import Foundation

/// MS-18 `recovery_loop_fixed` — Loop v2, our estimate of WHOOP's described recovery inputs (D-RECOV-WALK-2, Mo
/// 2026-10-17 ~4:05 PM PT). WHOOP names HRV, resting HR, sleep and breathing rate and publishes no weights, so every
/// weight here is ours. The original (`MS18`, Script/MSReadiness.swift) stays as Mo's script has it.
///
///     raw   = 0.56 hrvLnZ − 0.14 rhrZ − 0.10 respDev + 0.10 sleepZ − 0.06 |tempDev| + 0.04 spo2Z
///     score = clip(58 + 30 raw, 0, 100)
///
/// Changes from the script: scale ×10 → ×30 and centre 50 → 58 (fit to the WHOOP export, 796 scored days, hold-out kept
/// centre 58, MAE 7.5, same colour band 85 %: pclab/prototypes/fit_loop_scale.py); sleep performance and the SpO₂ byte are
/// z-scores against the previous 14 nights, clamped at ±3 (they were raw fractions worth 0.1 and 0.0 points per SD);
/// skin temperature counts in both directions. Python reference: pclab/mglab/ref/readiness_fixed.py; golden:
/// shared/golden/ms_fixed/MS-18_fixed.json.
public enum MS18Fixed {
    public static let id = "MS-18_fixed"
    public static let function = "recovery_loop_fixed"
    public static let scale = 30.0
    public static let centre = 58.0
    public static let zClamp = 3.0
    /// A flat 14-night baseline must not make a z infinite: SD floors for the two standardised supporting terms
    /// (3 points of sleep performance as a 0–1 fraction; 0.5 of the SpO₂ byte). Ours.
    public static let sleepSDFloor = 0.03
    public static let spo2SDFloor = 0.5

    public static func recoveryLoopFixed(hrvLnZ: Double, rhrZ: Double, respDev: Double, sleepZ: Double, tempDev: Double,
                                         spo2Z: Double) -> Computed<Double> {
        if let m = ScriptGuard.finite(("hrvLnZ", hrvLnZ), ("rhrZ", rhrZ), ("respDev", respDev), ("sleepZ", sleepZ),
                                      ("tempDev", tempDev), ("spo2Z", spo2Z)) { return .failure(m) }
        var raw: Double = 0.56 * hrvLnZ
        raw += 0.14 * (-rhrZ)
        raw += 0.10 * (-respDev)
        raw += 0.10 * min(max(sleepZ, -zClamp), zClamp)
        raw += 0.06 * (-abs(tempDev))
        raw += 0.04 * min(max(spo2Z, -zClamp), zClamp)
        return .success(min(max(centre + scale * raw, 0), 100))
    }
}
