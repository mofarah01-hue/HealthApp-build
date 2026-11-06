import Foundation

/// MS-20 `readiness_aura_fixed` — Aurora v2, our estimate of Oura's described readiness contributors (D-RECOV-WALK-2,
/// Mo 2026-10-17 ~4:05 PM PT). Oura lists nine contributors and publishes no weights, so every weight here is ours. The
/// original (`MS20`, Script/MSReadiness.swift) stays as Mo's script has it.
///
/// Each contributor is mapped to 0…1 and the weighted sum is scaled to 0–100:
///   HRV 0.20 · clip(0.5 + hrvZ/6) · resting HR 0.14 · clip(0.5 − rhrZ/6) · recovery index 0.10 · temperature 0.06 ·
///   max(0, 1 − |tempDev|) · sleep 0.10 · sleep balance 0.10 · sleep regularity 0.08 · activity balance 0.10 ·
///   previous-day activity 0.12 (the five 0–1 fractions are clipped to 0…1).
/// Changes from the script: resting HR is a z-score against your own nights (it was raw bpm, which clipped the score to 0
/// every day); temperature counts in both directions; HRV carries the largest weight (it had the smallest). Python
/// reference: pclab/mglab/ref/readiness_fixed.py; golden: shared/golden/ms_fixed/MS-20_fixed.json.
public enum MS20Fixed {
    public static let id = "MS-20_fixed"
    public static let function = "readiness_aura_fixed"
    public static let zClamp = 3.0

    static func clip(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    public static func readinessAuraFixed(hrvZ: Double, rhrZ: Double, tempDev: Double, sleepPrev: Double,
                                          sleepBalance: Double, sleepReg: Double, actPrev: Double, actBalance: Double,
                                          recoveryIdx: Double) -> Computed<Double> {
        if let m = ScriptGuard.finite(("hrvZ", hrvZ), ("rhrZ", rhrZ), ("tempDev", tempDev), ("sleepPrev", sleepPrev),
                                      ("sleepBalance", sleepBalance), ("sleepReg", sleepReg), ("actPrev", actPrev),
                                      ("actBalance", actBalance), ("recoveryIdx", recoveryIdx)) { return .failure(m) }
        var t: Double = 0.20 * clip(0.5 + clip(hrvZ, -zClamp, zClamp) / 6.0, 0, 1)
        t += 0.14 * clip(0.5 - clip(rhrZ, -zClamp, zClamp) / 6.0, 0, 1)
        t += 0.10 * clip(recoveryIdx, 0, 1)
        t += 0.06 * max(0, 1 - abs(tempDev))
        t += 0.10 * clip(sleepPrev, 0, 1)
        t += 0.10 * clip(sleepBalance, 0, 1)
        t += 0.08 * clip(sleepReg, 0, 1)
        t += 0.10 * clip(actBalance, 0, 1)
        t += 0.12 * clip(actPrev, 0, 1)
        return .success(clip(100 * t, 0, 100))
    }
}
