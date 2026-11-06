import Foundation

// Swift ports of Mo's master script — PART 2, VO2max (WP-17). See MSLoad.swift for the rules of these ports.

/// MS-05 `vo2max_orchard` — codename Orchard "Cardio Fitness". HRmax = 208 − 0.8·age (EXACT per the script; Tanaka
/// 2001 is 208 − 0.7·age), result 15 · (HRmax/HRrest) · (0.5 + 0.5·scale) · (70/kg), then clipped to 14–65 (FIX F4: the
/// clip is applied last). `time1miS` is accepted and unused, exactly as in the script. The model needs a timed 1-mile
/// effort; without one the caller must not call it (ARCHITECTURE §8.2: "needs a timed 1-mile effort").
/// Port guard: HRrest and weight must be > 0 (the script would divide by zero or return a negative number).
public enum MS05 {
    public static let id = "MS-05"
    public static let function = "vo2max_orchard"
    public static let codename = "Orchard"

    public static func vo2maxOrchard(time1miS: Double, hr1mi: Double, hrRest: Double, age: Double,
                                     kg: Double) -> Computed<Double> {
        if let m = ScriptGuard.finite(("time1miS", time1miS), ("hr1mi", hr1mi), ("hrRest", hrRest), ("age", age),
                                      ("kg", kg)) { return .failure(m) }
        if let m = ScriptGuard.positive(("hrRest", hrRest), ("kg", kg)) { return .failure(m) }
        let hrmax: Double = 208.0 - 0.8 * age
        let scale: Double = (hrmax - hrRest) / max(1.0, hr1mi - hrRest)
        let prior: Double = 15.0 * (hrmax / hrRest)
        let fit: Double = 0.5 + 0.5 * scale
        return .success(min(max(prior * fit * (70.0 / kg), 14), 65))
    }
}

/// MS-06 `vo2max_fenix_firstbeat` — codename Fenix / Rhythm-Lab "VO2max". Same formula as MS-05 without the (unused)
/// time (the script marks the whole return INFERRED). Same guard and the same need for a timed 1-mile effort.
public enum MS06 {
    public static let id = "MS-06"
    public static let function = "vo2max_fenix_firstbeat"
    public static let codename = "Fenix / Rhythm-Lab"

    public static func vo2maxFenixFirstbeat(hr1mi: Double, hrRest: Double, age: Double, kg: Double) -> Computed<Double> {
        if let m = ScriptGuard.finite(("hr1mi", hr1mi), ("hrRest", hrRest), ("age", age), ("kg", kg)) {
            return .failure(m)
        }
        if let m = ScriptGuard.positive(("hrRest", hrRest), ("kg", kg)) { return .failure(m) }
        let hrmax: Double = 208.0 - 0.8 * age
        let scale: Double = (hrmax - hrRest) / max(1.0, hr1mi - hrRest)
        let prior: Double = 15.0 * (hrmax / hrRest)
        let fit: Double = 0.5 + 0.5 * scale
        return .success(min(max(prior * fit * (70.0 / kg), 14), 65))
    }
}
