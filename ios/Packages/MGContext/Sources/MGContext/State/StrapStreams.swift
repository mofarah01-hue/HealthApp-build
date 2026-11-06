import Foundation

// One settings page (Mo, Nov 6 2026: "we have two settings pages ... we need to get this a bit cleaner"). The strap's streams sit in
// one "Streams" section near the top of the device section: each stream its own switch (existing intents, nothing new), and the
// rows only an MG (WHOOP 5.0) has are not offered while the WHOOP 4.0 is the chosen device. Pure, so the choice is tested.

extension StrapSyncState {
    /// The WHOOP 4.0 is the chosen device (`deviceName` is "MG" otherwise).
    public var whoop4Chosen: Bool { deviceName != "MG" }

    /// The switches of the Streams section, in order: raw optical (MG only), raw motion, automatic bursts, during workouts,
    /// heart-rate broadcast.
    public var streamToggles: [ToggleState] {
        var out: [ToggleState] = []
        if !whoop4Chosen, let optical = rawOptical { out.append(optical) }
        if let motion = ecgMotion?.motion { out.append(motion) }
        if let auto = autoRaw {
            out.append(auto.bursts)
            out.append(auto.workout)
        }
        out.append(broadcast)
        return out
    }

    /// The one line that goes with the raw-motion switch.
    public var streamMotionLine: String? { ecgMotion?.motionLine }

    /// ECG and the R22 stream exist only on an MG: hidden, not greyed, while the 4.0 is chosen.
    public var showsMGOnlyRows: Bool { !whoop4Chosen }
}
