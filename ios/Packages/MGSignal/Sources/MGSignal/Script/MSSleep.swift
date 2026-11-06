import Foundation

// Swift ports of Mo's master script — PART 12, sleep staging (WP-17; MS-22 sleep inertia removed 2026-10-17, D-SLEEP-WALK-1). See MSLoad.swift for the rules of
// these ports. The inputs per 30-second epoch and for the morning are chosen by the callers (ARCHITECTURE §8.2, "ours v0").

/// MS-21 stages.
public enum MS21Stage: String, Sendable, Equatable {
    case wake = "wake"
    case deep = "deep"
    case rem = "rem"
    case light = "light"
}

/// MS-21 `sleep_stage_ppg` — rule-based stage of one epoch (the script's PART 12; no codename). Rules in order:
/// wake = HR/100 > 0.70 and motion > 0.5; deep = HRV (RMSSD) > 60, breathing < 15 per minute, motion < 0.3 and the skin
/// temperature deviation > −0.2; REM = HR/100 > 0.55, motion > 0.3 and RMSSD < 50; otherwise light. All thresholds are
/// INFERRED in the script. The last argument is meant to be ambient-corrected; the callers have no ambient sensor and
/// say so in the metric note.
public enum MS21 {
    public static let id = "MS-21"
    public static let function = "sleep_stage_ppg"
    public static let codename: String? = nil

    public static func sleepStagePPG(hr: Double, rmssd: Double, resp: Double, motion: Double,
                                     tempDevAmbientCorrected: Double) -> Computed<MS21Stage> {
        if let m = ScriptGuard.finite(("hr", hr), ("rmssd", rmssd), ("resp", resp), ("motion", motion),
                                      ("tempDevAmbientCorrected", tempDevAmbientCorrected)) { return .failure(m) }
        if hr / 100 > 0.70 && motion > 0.5 { return .success(.wake) }
        if rmssd > 60 && resp < 15 && motion < 0.3 && tempDevAmbientCorrected > -0.2 { return .success(.deep) }
        if hr / 100 > 0.55 && motion > 0.3 && rmssd < 50 { return .success(.rem) }
        return .success(.light)
    }
}
