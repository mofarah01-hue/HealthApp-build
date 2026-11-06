import Foundation

/// Payload of `UIIntent.ecgMotion` (wave W8, 2026-10-11): the MG ECG reading and raw motion (R21). CLAUDE.md rule 5: each
/// family behind its own off-by-default switch; the switches live in Strap & sync, the reading on the Live tab.
public enum EcgMotionAction: Equatable, Sendable {
    /// Strap & sync › "ECG (MG)".
    case setEcgSwitch(Bool)
    /// The wrist the strap is worn on ("left" / "right"), sent as SELECT_WRIST at the start of each reading.
    case setWrist(String)
    /// Strap & sync › "Raw motion (100 Hz)".
    case setRawMotion(Bool)
    /// Live › "Record n min": a bounded raw-motion session (runs in the background too). 0 = stop the session.
    case rawMotionSession(minutes: Int)
    /// ECG cover: start the timed reading.
    case beginECG
    /// ECG cover: filtered (true) or unfiltered (false) waveform. Display only; the saved samples are always raw.
    case setEcgFiltered(Bool)
    /// ECG cover: enlarge / shrink the waveform (tap).
    case setEcgExpanded(Bool)
    /// ECG cover: stop now and save what was recorded.
    case finishECG
    /// ECG cover: close (a running reading is stopped first; nothing recorded is thrown away silently).
    case closeECG
}
