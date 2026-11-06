import Foundation
import MGDomain

/// One of the two big live tiles (RMSSD 5 min, autonomic load) in its three looks (0.6.0.12; Mo Nov 5 2026: a number that cannot
/// be trusted yet is shown GREY with the reason, not blank).
/// - `solid`: a number that met every rule.
/// - `grey`: a number (or "—" when none can be worked out) that did not meet the rules, with the reason.
/// - `blank`: nothing streams at all (strap away, Bluetooth off, ...); the reason is the Live tab's own.
public struct LiveTileState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case solid, grey, blank }

    public var kind: Kind
    /// The number or word shown big ("48", "about usual"); "—" when grey with no value.
    public var text: String
    public var unit: String?
    /// Why it is grey or blank.
    public var reason: String?
    /// The line under it: how many clean windows the number averages, or where a stored value comes from.
    public var note: String?
    public var receipt: Receipt?

    public init(kind: Kind, text: String, unit: String? = nil, reason: String? = nil, note: String? = nil,
                receipt: Receipt? = nil) {
        self.kind = kind
        self.text = text
        self.unit = unit
        self.reason = reason
        self.note = note
        self.receipt = receipt
    }

    public static func blank(_ reason: String) -> LiveTileState {
        LiveTileState(kind: .blank, text: "—", reason: reason)
    }
}
