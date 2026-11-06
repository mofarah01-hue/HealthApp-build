import Foundation

/// R9m (brain's change before merge, 2026-10-17): the ONE place that says whether the R20 red / IR block identity is
/// confirmed. Which R20 blocks are red and IR is a CLAIM (OpenStrap's, in the strap sheet), not a finding. The PC's
/// `pc.led-identity` experiment exists to confirm it.
///
/// While `confirmed` is false the enhanced SpO₂ (ALG-022:night) is still computed and stored, but Today never shows it;
/// Explore and the SpO₂ metric detail show it under `researchLabel`.
/// To flip it on: when pc.led-identity names a pair, put that pair in `red` / `ir`, set `confirmed = true`; Today then shows it.
public enum LEDIdentity {
    public static let confirmed = false
    /// The pair assumed until it is confirmed (blocks of the R20 record).
    public static let red = 1
    public static let ir = 3
    /// What every non-Today place says while `confirmed` is false.
    public static let researchLabel =
        "red/IR blocks assumed (not yet confirmed), another sensor's calibration — research only"
}
