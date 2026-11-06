import Foundation

// Swift ports of Mo's master script — PART 1, training load (WP-17).
// Source of truth: reference/whoop_all_metrics_master_fixed.py (the FIXED copy; the original stays untouched).
// Weights, constants and codenames are Mo's and are copied literally; a test compares every numeric literal of each port
// against the script (app/pclab/tests/test_ms_runner.py). Python reference of the goldens: the script itself
// (app/pclab/golden/gen_ms.py calls it directly; goldens in app/shared/golden/ms/).

/// MS-01 `trimp_banister` — codename Loop "Strain" research base. Banister TRIMP: duration × reserve fraction ×
/// 0.64·e^(1.92·b) (male) or 0.86·e^(1.67·b) (female); b = (HRex − HRrest) / (HRmax − HRrest), floored at 0 (FIX F13).
/// Unbounded training load in arbitrary units (not 0–21). Script notes: the comment says Banister 1991; the
/// coefficients are Morton, Fitz-Clarke & Banister 1990 (ALGORITHM-REQUIREMENTS §12).
public enum MS01 {
    public static let id = "MS-01"
    public static let function = "trimp_banister"
    public static let codename = "Loop"

    /// - Parameters: duration in minutes, mean HR in the effort, resting HR, maximum HR (bpm), sex (`true` = male).
    public static func trimpBanister(durationMin: Double, hrEx: Double, hrRest: Double, hrMax: Double,
                                     male: Bool) -> Computed<Double> {
        if let m = ScriptGuard.finite(("durationMin", durationMin), ("hrEx", hrEx), ("hrRest", hrRest),
                                      ("hrMax", hrMax)) { return .failure(m) }
        let b = max(0.0, (hrEx - hrRest) / max(1.0, hrMax - hrRest))
        let c = male ? 0.64 * exp(1.92 * b) : 0.86 * exp(1.67 * b)
        return .success(durationMin * b * c)
    }
}

/// MS-02 `trimp_edwards` — codename Rhythm-Lab "Session Load". Edwards zone TRIMP: minutes in each of five HR zones
/// × 1, 2, 3, 4, 5, summed (FIX F15: fewer than five entries are fine, entries beyond five are ignored).
public enum MS02 {
    public static let id = "MS-02"
    public static let function = "trimp_edwards"
    public static let codename = "Rhythm-Lab"

    public static func trimpEdwards(minsInFiveZones mins: [Double]) -> Computed<Double> {
        if let m = ScriptGuard.allFinite("minsInFiveZones", mins) { return .failure(m) }
        var total = 0.0
        for (i, minutes) in mins.prefix(5).enumerated() { total += minutes * Double(i + 1) }
        return .success(total)
    }
}

/// The bands `acl_ctl` (MS-03) returns.
public enum MS03Band: String, Sendable, Equatable {
    case red = "RED"
    case yellow = "YEL"
    case green = "GRN"
    case insufficient = "INSUFFICIENT"
}

/// MS-03 result. `ratio` is nil exactly when `band` is `.insufficient` (the script returns NaN there, FIX F14).
public struct MS03Result: Sendable, Equatable {
    public var ratio: Double?
    public var band: MS03Band

    public init(ratio: Double?, band: MS03Band) {
        self.ratio = ratio
        self.band = band
    }
}

/// MS-03 `acl_ctl` — codename Rhythm-Lab "ACWR" / Fenix "Acute:Chronic Load". Acute = 7-day TRIMP, chronic = 28-day
/// TRIMP / 4; ratio and a band (> 1.5 RED, > 1.3 YEL, else GRN; bands are INFERRED in the script). No chronic load →
/// INSUFFICIENT with no ratio (FIX F14).
public enum MS03 {
    public static let id = "MS-03"
    public static let function = "acl_ctl"
    public static let codename = "Rhythm-Lab / Fenix"

    public static func aclCtl(week7Trimp: Double, week28Trimp: Double) -> Computed<MS03Result> {
        if let m = ScriptGuard.finite(("week7Trimp", week7Trimp), ("week28Trimp", week28Trimp)) { return .failure(m) }
        if week28Trimp <= 0 { return .success(MS03Result(ratio: nil, band: .insufficient)) }
        let ratio = week7Trimp / max(1e-9, week28Trimp / 4.0)
        let band: MS03Band = ratio > 1.5 ? .red : (ratio > 1.3 ? .yellow : .green)
        return .success(MS03Result(ratio: ratio, band: band))
    }
}
