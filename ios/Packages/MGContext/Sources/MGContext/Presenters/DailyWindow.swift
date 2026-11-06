import Foundation
import MGDomain

/// Bug 4 (M-137, M-139, 2026-10-14): one metric name can carry two different measures. `hr_recovery_tau` is both the
/// day-level wind-down to resting (ALG-012@2, window "day", e.g. 1107 s) and the per-workout fitted time constant
/// (ALG-012@1, window "workout:<id8>", e.g. 372-832 s). Explore's daily series used to take whichever came first, so
/// Today read 1107 and 30 d read a median of workout taus. A daily series now keeps one measure: when the rows hold
/// both a "day" row and per-workout rows, the day rows win (the Explore row is named "wind-down to resting"); the
/// per-workout values stay stored and are shown on the workout screen. Nothing is deleted.
///
/// Oct 17 2026 (D-RECOV-WALK-2): the day-level wind-down measure was removed. Day rows it stored earlier stay on the phone
/// but are no longer a measure of anything we show, so `dailyRows` drops a `hr_recovery_tau` row whose window is "day".
public enum DailyWindow {
    /// A `hr_recovery_tau` row with window "day" can only be the removed wind-down-to-resting readout (ALG-012@2).
    public static func isRemovedWindDown(_ m: Metric) -> Bool {
        m.name == MetricKey.hrRecoveryTau.rawValue && m.window == "day"
    }

    /// "workout", "workout:ab12cd34", "workout_window": a value tied to one workout, not to the day.
    public static func isPerWorkout(_ window: String?) -> Bool { window?.hasPrefix("workout") == true }

    /// The rows a one-value-per-day series may use (see the type note).
    public static func dailyRows<T>(_ rowsIn: [T], metric: (T) -> Metric) -> [T] {
        let rows = rowsIn.filter { !isRemovedWindDown(metric($0)) }
        let hasDay = rows.contains { metric($0).window == "day" }
        let hasWorkout = rows.contains { isPerWorkout(metric($0).window) }
        guard hasDay, hasWorkout else { return rows }
        return rows.filter { !isPerWorkout(metric($0).window) }
    }
}
