import Foundation

// Swift ports of Mo's master script — PART 9 (HRV / stress) and PART 11 (readiness / recovery) (WP-17). See MSLoad.swift
// for the rules of these ports. The inputs are chosen by the callers (ARCHITECTURE §8.2; "ours v0" adapters for MS-19,
// MS-20); the functions only compute.

/// MS-15 `hrv_stress_esc` — codename ESC-TF (Rhythm-Lab "Stress"). 50 + 20·z + 15·(LF/HF − 1), clipped to 0–100, with
/// z = (baseline RMSSD − RMSSD) / SD (SD floored at 0.001) and LF/HF from powers in ms² (HF floored at 1e-9). Bands LF
/// 0.04–0.15 Hz, HF 0.15–0.40 Hz (Task Force 1996). The weights are INFERRED in the script.
public enum MS15 {
    public static let id = "MS-15"
    public static let function = "hrv_stress_esc"
    public static let codename = "ESC-TF"

    public static func hrvStressEsc(rmssd: Double, lfMw2: Double, hfMw2: Double, rmssdB: Double,
                                    rmssdSD: Double) -> Computed<Double> {
        if let m = ScriptGuard.finite(("rmssd", rmssd), ("lfMw2", lfMw2), ("hfMw2", hfMw2), ("rmssdB", rmssdB),
                                      ("rmssdSD", rmssdSD)) { return .failure(m) }
        let z: Double = (rmssdB - rmssd) / max(rmssdSD, 1e-3)
        let lfhf: Double = lfMw2 / max(hfMw2, 1e-9)
        let raw: Double = 50 + z * 20 + (lfhf - 1.0) * 15
        return .success(min(max(raw, 0), 100))
    }
}

/// MS-18 `recovery_loop` — codename Loop "Recovery". 50 + 10·raw clipped to 0–100, raw = 0.56·HRV z − 0.14·RHR z −
/// 0.10·breathing deviation + 0.10·sleep performance − 0.06·temperature deviation + 0.04·SpO2 (signs fixed in F10: a
/// higher resting HR, faster breathing and a warmer skin all LOWER recovery). Green 67–99, yellow 34–66, red 0–33 are
/// WHOOP's bands, not returned by the script.
/// SpO2 unit, corrected 2026-10-11 11:02 PM PT (formula audit W1): the script takes SpO2 as a 0–1 fraction, as its own
/// call does (`recovery_loop(0.0, 0.0, 0.0, 0.8, -0.1, 0.9)`, SpO2 0.9 beside sleep performance 0.8). The weight 0.04
/// and this function are unchanged; the callers (ScriptMembers.ms18Inputs here, ms_inputs.build_ms18 on the PC) divide
/// the strap's byte (about 97) by 100 first.
/// WRONG until 2026-10-11 11:02 PM PT, kept for the record: "Script note: the SpO2 weight expects a percentage; with the
/// strap's raw byte (about 97) it shifts the score by about 39 points, which is why the PC and phone notes flag it."
public enum MS18 {
    public static let id = "MS-18"
    public static let function = "recovery_loop"
    public static let codename = "Loop"

    public static func recoveryLoop(hrvLnZ: Double, rhrZ: Double, respDev: Double, sleepPerf: Double, tempDev: Double,
                                    spo2: Double) -> Computed<Double> {
        if let m = ScriptGuard.finite(("hrvLnZ", hrvLnZ), ("rhrZ", rhrZ), ("respDev", respDev),
                                      ("sleepPerf", sleepPerf), ("tempDev", tempDev), ("spo2", spo2)) {
            return .failure(m)
        }
        // one term per line, added left to right, as the script's single expression evaluates (and so the type checker
        // never sees a 6-term mixed-literal sum)
        var raw: Double = 0.56 * hrvLnZ
        raw += 0.14 * (-rhrZ)
        raw += 0.10 * (-respDev)
        raw += 0.10 * sleepPerf
        raw += 0.06 * (-tempDev)
        raw += 0.04 * spo2
        return .success(min(max(50 + raw * 10, 0), 100))
    }
}

/// MS-19 `readiness_orchard` — codename Orchard "Readiness" (three inputs: activity, vitals, sleep score). 0–10:
/// 5 + (0.4·vitals + 0.3·sleep + 0.3·activity)·1.2, clipped. Weights INFERRED. With 0–1 inputs only 5.0 to 6.2 is
/// reachable (script note); a 0–100 score saturates it.
public enum MS19 {
    public static let id = "MS-19"
    public static let function = "readiness_orchard"
    public static let codename = "Orchard"

    public static func readinessOrchard(activity: Double, vitals: Double, sleepScore: Double) -> Computed<Double> {
        if let m = ScriptGuard.finite(("activity", activity), ("vitals", vitals), ("sleepScore", sleepScore)) {
            return .failure(m)
        }
        let mix: Double = 0.4 * vitals + 0.3 * sleepScore + 0.3 * activity
        return .success(min(max(5 + mix * 1.2, 0), 10))
    }
}

/// MS-20 `readiness_aura` — codename Aurora "Readiness" (nine contributors). 50 + 10·raw clipped to 0–100; the weights
/// are not published (INFERRED). HRV enters as (RMSSD − 3-month mean) / 3-month mean, not as a z. The resting HR is
/// taken in bpm as written, so its −0.10 weight dominates (script note, flagged on the metric note).
public enum MS20 {
    public static let id = "MS-20"
    public static let function = "readiness_aura"
    public static let codename = "Aurora"

    public static func readinessAura(rmssd: Double, rmssd3mo: Double, tempDev: Double, sleepPrev: Double,
                                     sleepBalance: Double, actPrev: Double, actBalance: Double, rhr: Double,
                                     recoveryIdx: Double, sleepReg: Double) -> Computed<Double> {
        if let m = ScriptGuard.finite(("rmssd", rmssd), ("rmssd3mo", rmssd3mo), ("tempDev", tempDev),
                                      ("sleepPrev", sleepPrev), ("sleepBalance", sleepBalance), ("actPrev", actPrev),
                                      ("actBalance", actBalance), ("rhr", rhr), ("recoveryIdx", recoveryIdx),
                                      ("sleepReg", sleepReg)) { return .failure(m) }
        let zH: Double = (rmssd - rmssd3mo) / max(rmssd3mo, 1e-3)
        var raw: Double = 0.08 * zH            // the script's nine terms, in its order, added left to right
        raw += 0.10 * (-tempDev)
        raw += 0.12 * sleepPrev
        raw += 0.12 * sleepBalance
        raw += 0.12 * sleepReg
        raw += 0.12 * actBalance
        raw += 0.10 * actPrev
        raw += 0.10 * (-rhr)
        raw += 0.14 * recoveryIdx
        return .success(min(max(50 + raw * 10, 0), 100))
    }
}
