import Foundation

/// T110 (app/docs/T-LIST-v2.md): the off-wrist flag used to move only on the strap's wrist events — a slow
/// reconnect dropped the "wrist on" (the 30 s freshness window), live beats never touched the flag, and a
/// relaunch restored a stale "off". Pure: every time is passed in, nothing reads a clock. `wristOff` /
/// `wristOn` are the strap's events (10 / 9); `beat` is a live beat. Five consecutive good beats at or
/// after the off clear it, so beats that flow while the event never arrived unstick the flag, and a
/// restored "off" is marked `mayBeStale` until a strap event or good beats confirm or clear it.
public struct OffWristTracker: Equatable, Sendable {
    /// Consecutive good beats that clear an "off" — a run, not a count, so one junk beat restarts it.
    public static let neededGoodBeats = 5
    /// A good beat's bpm must be inside this range (off the wrist the strap reads 0; a bad read spikes).
    public static let bpmRange: ClosedRange<Double> = 30...220
    /// A good beat needs at least one R-R interval inside this range, in milliseconds.
    public static let rrRange: ClosedRange<Double> = 250...2000

    /// When the strap went off the wrist; nil while it is worn (or was restored as worn).
    public private(set) var offSince: Date?
    /// True only while `offSince` came from `init(restoredOffSince:)` and nothing has confirmed it since.
    public private(set) var mayBeStale: Bool
    /// The current run of consecutive good beats.
    private var goodBeats = 0
    /// The off came from a restore, not from the strap: its stored time may predate the beats still in
    /// flight, so the beat-time test is skipped until a strap event or good beats settle the flag.
    private var restored = false

    public init() {
        offSince = nil
        mayBeStale = false
    }

    /// Restores a stored off time (a relaunch); nil means nothing stored, nothing stale.
    public init(restoredOffSince: Date?) {
        offSince = restoredOffSince
        mayBeStale = restoredOffSince != nil
        restored = restoredOffSince != nil
    }

    /// The strap's WRIST_OFF (event 10): the off is certain from now on.
    public mutating func wristOff(at: Date) {
        offSince = at
        mayBeStale = false
        restored = false
        goodBeats = 0
    }

    /// The strap's WRIST_ON (event 9): worn again, nothing left stale.
    public mutating func wristOn(at: Date) {
        offSince = nil
        mayBeStale = false
        restored = false
        goodBeats = 0
    }

    /// A live beat. While off: a bad beat restarts the run, a beat earlier than the off is a replay and
    /// is ignored, and five consecutive good beats clear the flag. While worn, beats do nothing.
    public mutating func beat(at: Date, bpm: Double?, rrMs: [Double]) {
        guard offSince != nil else { return }
        // A strap-confirmed off only counts beats it could not have preceded; a restored off takes any
        // five good beats — its stored time may predate the beats that are still arriving.
        if !restored, let since = offSince, at < since { return }
        if Self.isGoodBeat(bpm: bpm, rrMs: rrMs) {
            goodBeats += 1
        } else {
            goodBeats = 0
        }
        guard goodBeats >= Self.neededGoodBeats else { return }
        offSince = nil
        mayBeStale = false
        restored = false
        goodBeats = 0
    }

    /// bpm inside `bpmRange` with at least one R-R inside `rrRange`.
    private static func isGoodBeat(bpm: Double?, rrMs: [Double]) -> Bool {
        guard let bpm, bpmRange.contains(bpm), rrMs.contains(where: { rrRange.contains($0) }) else { return false }
        return true
    }
}
