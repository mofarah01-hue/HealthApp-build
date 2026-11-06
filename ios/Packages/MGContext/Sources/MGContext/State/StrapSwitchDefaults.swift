import Foundation

/// The strap research switches (Strap & sync, and the wave rows on Live): raw optical (live R20, 108), raw optical nights
/// in the background (wave 4), ECG (MG) and raw motion (100 Hz). CHANGED 2026-10-13 (T147, Mo; CLAUDE.md rule 5 updated;
/// D-028 done): all four start OFF to save strap battery; Mo turns each on in Settings or on the Live tab. It used to
/// be ON by default since 2026-10-11 21:43 PT, with a one-time migration that turned saved offs on; that migration is
/// gone, so a value Mo already saved (on or off) is kept as it is.
public enum StrapSwitchDefaults {
    public struct Switches: Equatable, Sendable {
        public var rawOptical: Bool
        public var rawOpticalNights: Bool
        public var ecg: Bool
        public var rawMotion: Bool

        public init(rawOptical: Bool, rawOpticalNights: Bool, ecg: Bool, rawMotion: Bool) {
            self.rawOptical = rawOptical
            self.rawOpticalNights = rawOpticalNights
            self.ecg = ecg
            self.rawMotion = rawMotion
        }
    }

    /// 2 = the 2026-10-13 "off by default" change (1 was the 2026-10-11 "on by default" one). Nothing reads it to reset a
    /// value; it only records which default a saved settings file was written under.
    public static let version = 2
    public static let fresh = Switches(rawOptical: false, rawOpticalNights: false, ecg: false, rawMotion: false)
}

/// T9984 (2026-10-15, Mo): raw motion (R21, 100 Hz) and raw optical (R20) keep running with the Live tab closed and the app in
/// the background until Mo switches them off. They stay off by default (`StrapSwitchDefaults`); this is only about what a
/// switch that IS on does. Before, raw optical was allowed only while the app was in the foreground, and nothing kept the
/// app awake once Live HR stopped with the Live tab, so iOS suspended it and both streams died.
public enum StrapStreamPolicy {
    /// May raw optical run now? A switch that is on is the permission, app open or not. Only the nights-only mode (Mo's own
    /// choice) narrows it to "app open, or the schedule's window around a strap SpO₂ burst" (`scheduleRunNow`; nil = no window known).
    public static func opticalMayRun(nightsOnly: Bool, appActive: Bool, scheduleRunNow: Bool?) -> Bool {
        guard nightsOnly else { return true }
        return appActive || (scheduleRunNow ?? false)
    }

    /// Does a running stream keep live HR on so the strap keeps notifying and iOS keeps the app running in the background?
    /// (Raw optical's nights-only mode has its own keep-awake from the schedule.)
    public static func keepsRealtimeOn(rawMotionOn: Bool, rawOpticalOn: Bool, opticalNightsOnly: Bool, sample: Bool) -> Bool {
        !sample && (rawMotionOn || (rawOpticalOn && !opticalNightsOnly))
    }
}
