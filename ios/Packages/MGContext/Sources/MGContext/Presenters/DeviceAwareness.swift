import Foundation

// 0.6.0.12 — the app follows the chosen device. With the WHOOP 4.0 selected, the things that only an MG (WHOOP 5.0) strap
// has are greyed with a reason instead of offered: ECG, raw optical (R20), raw motion (R21), the automatic raw streams and
// bursts, the R22 unlock, the feature-flag read, and hand-back. With the MG selected nothing here changes.

public enum MGOnly {
    /// Shown under a greyed switch or button, only while the WHOOP 4.0 is the chosen device (Nov 5 2026: it used to start with
    /// "MG only", naming the device the user did NOT choose).
    public static let reason = "Not available on the WHOOP 4.0."
}

/// Nov 5 2026: the words of the notices that follow a device choice (shown by the app; here so a test can pin them). Nothing
/// here names the 5.0/MG to a 4.0 user, or a strap brand when no device is chosen.
public enum StrapNotices {
    /// After "WHOOP 4.0" (true) or "MG / none" (false) was picked in Settings.
    public static func selected(whoop4: Bool) -> String {
        whoop4 ? "WHOOP 4.0 selected. Tap Pair WHOOP 4.0 with the strap near."
               : "Device changed. The WHOOP 4.0 is disconnected."
    }

    /// A timed raw-motion session was asked for on a WHOOP 4.0.
    public static let timedSessionNotOn4 =
        "Timed record sessions are not available on the WHOOP 4.0. It streams raw motion while the Raw motion switch is on."
}

extension PresenterSnapshot {
    /// "WHOOP 4.0" when the 4.0 is the chosen device, else "MG". Used in titles; "pair your …" lines use `pairName`.
    public var deviceName: String { whoop4Selected ? "WHOOP 4.0" : "MG" }

    /// What a "pair your …" line calls the strap to pair: "WHOOP 4.0" when it is the chosen device, else just "strap" (nothing
    /// is paired and no device is chosen, so no brand is named; Nov 5 2026, was "MG").
    public var pairName: String { whoop4Selected ? "WHOOP 4.0" : "strap" }

    /// The reason to grey an MG-only control, or nil on an MG. Sample data keeps its own reason where it applies.
    var mgOnlyReason: String? { whoop4Selected ? MGOnly.reason : nil }
}
