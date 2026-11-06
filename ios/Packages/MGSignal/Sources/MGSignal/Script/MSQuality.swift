import Foundation

// Swift ports of Mo's master script — PART 15, signal-quality gate and fusion (WP-17). See MSLoad.swift for the rules of
// these ports.

/// MS-30 `sqi` — signal-quality weight 0.4–1.0 from a feature dictionary (the script's PART 15, after CardioFusion-AI
/// arXiv 2608.26000; no codename). Keys read: "systolic_area" (≤ 0.05 → 0.4), "fall" (any non-zero value → 0.8),
/// "dev_C" (|value| > 2.0 → 0.7), "rms" (≤ 0.002 → 0.5); the weight is the smallest that applies, 1.0 when none does.
/// Port fidelity: a key that is absent behaves exactly as in the script (`systolic_area` absent counts as 0 and gives
/// 0.4; `dev_C` absent counts as 0; `rms` absent counts as 1). Callers must therefore NOT call this without a PPG
/// systolic area: ARCHITECTURE §8.2 leaves MS-30 blank until those features exist, so 0.4 is never shown as a reading.
public enum MS30 {
    public static let id = "MS-30"
    public static let function = "sqi"
    public static let codename: String? = nil

    public static func sqi(_ f: [String: Double]) -> Double {
        var q: Double = 1.0
        if (f["systolic_area"] ?? 0) <= 0.05 { q = min(q, 0.4) }
        if let fall = f["fall"], fall != 0 { q = min(q, 0.8) }
        if abs(f["dev_C"] ?? 0) > 2.0 { q = min(q, 0.7) }
        if (f["rms"] ?? 1) <= 0.002 { q = min(q, 0.5) }
        return min(max(q, 0), 1)
    }
}

/// MS-31 `fuse` — decision-level fusion: for each requested key, the mean over the modalities that have it, weighted by
/// each modality's MS-30 weight (the script's PART 15; no codename). The script returns −1.0 for a key no modality has
/// (FIX F17 made it a float); the port returns `Missing`. Modalities are visited in name order (the script visits
/// dictionary insertion order; the sums differ below 1e-15).
public enum MS31 {
    public static let id = "MS-31"
    public static let function = "fuse"
    public static let codename: String? = nil

    public static func fuse(feats: [String: [String: Double]], keys: [String]) -> [String: Computed<Double>] {
        var out: [String: Computed<Double>] = [:]
        let names = feats.keys.sorted()
        for key in keys {
            var numerator = 0.0
            var denominator = 0.0
            var found = false
            var finite = true
            for name in names {
                guard let features = feats[name], let a = features[key] else { continue }
                if !a.isFinite { finite = false }
                let w = MS30.sqi(features)
                numerator += a * w
                denominator += w
                found = true
            }
            if !found {
                out[key] = Computed<Double>.missing("no modality has the feature '\(key)'")
            } else if !finite {
                out[key] = Computed<Double>.missing("feature '\(key)' holds a value that is not a finite number")
            } else {
                out[key] = Computed<Double>.success(numerator / denominator)
            }
        }
        return out
    }
}
