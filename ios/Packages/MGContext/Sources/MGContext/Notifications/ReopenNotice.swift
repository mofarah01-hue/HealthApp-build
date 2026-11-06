import Foundation

/// Nov 5 2026: "HealthApp was closed — open it again so Apple Health and your strap keep syncing".
///
/// When the user closes the app from the app switcher iOS sets a flag that blocks every background launch (HealthKit delivery,
/// BLE restoration, background tasks) until the app is opened again; Apple documents no override. WHOOP's own app sends a
/// notification at that moment. This is the pure wording; the app schedules it (App/Background/ReopenNoticeScheduler.swift).
///
/// LIMITS (also in docs/features/APPLE-HEALTH-AUTO.md): iOS calls `applicationWillTerminate` only for an app that is running,
/// not for one that is suspended in the background, and a swipe from the switcher usually hits a suspended app. So the notice
/// is sent only when the app was still running, or its scene was disconnected while backgrounded; a plain swipe-away of a
/// suspended app may send nothing. It is cancelled at every launch.
public enum ReopenNotice {
    /// One id, so a launch removes exactly this request.
    public static let identifier = "mg.reopenNotice"
    public static let threadIdentifier = "mg.reopen"
    /// Seconds after the app ended; iOS does not accept a time trigger under 1 s.
    public static let delay: TimeInterval = 3

    public static let title = "App closed"

    /// `strapName` is the chosen strap ("WHOOP 4.0", "MG") or nil when none is chosen: then no strap is mentioned.
    public static func body(appName: String, strapName: String?) -> String {
        let what = strapName.map { "Apple Health and your \($0) keep" } ?? "Apple Health keeps"
        return "\(appName) was closed — open it again so \(what) syncing."
    }

    /// The WHOOP 4.0 when it is the chosen device (the MG is never named then); the MG only when one is paired; else nil.
    public static func strapName(whoop4Chosen: Bool, mgPaired: Bool) -> String? {
        if whoop4Chosen { return "WHOOP 4.0" }
        return mgPaired ? "MG" : nil
    }
}
