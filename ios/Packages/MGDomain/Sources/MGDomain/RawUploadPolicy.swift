import Foundation

/// Raw strap frames and the PC: when they are sent, and when the phone may delete them. One pure place for both rules,
/// so the background code (App), the sync engine (MGSync) and the retention pass (MGStore) cannot drift apart.
///
/// CHANGED 2026-10-11 19:2x PT (Mo, decision #74: "upload always is fine"). It used to be D11: "raw frames go only on
/// Wi-Fi (or wired) + charging", on the `.rawupload` processing task alone. Now raw frames go on ANY working connection,
/// cellular included, with every sync and with the processing task, except in iOS Low Data Mode (the path is
/// `constrained`): then they wait, and the app says so (sync notice, Settings › Usage).
///
/// Deletion is unchanged: a frame leaves the phone only when the PC has confirmed it (the drop that carried it was
/// delivered with matching receipts) AND it was received more than 30 days ago.
public enum RawUploadPolicy {
    /// What the app knows of the network path (NWPath).
    public struct Network: Equatable, Sendable {
        public var satisfied: Bool
        /// Low Data Mode (NWPath.isConstrained).
        public var isConstrained: Bool
        /// Cellular or a personal hotspot (NWPath.isExpensive). Raw goes anyway since #74.
        public var isExpensive: Bool

        public init(satisfied: Bool, isConstrained: Bool, isExpensive: Bool) {
            self.satisfied = satisfied
            self.isConstrained = isConstrained
            self.isExpensive = isExpensive
        }
    }

    public enum Decision: Equatable, Sendable {
        case send
        /// Raw waits; the sentence says why (shown as-is).
        case wait(String)

        public var allowed: Bool { self == .send }
        public var reason: String? {
            if case .wait(let why) = self { return why }
            return nil
        }
    }

    public static let lowDataModeReason = "Raw strap frames are waiting: Low Data Mode is on. They go when it's off."
    public static let noNetworkReason = "Raw strap frames are waiting: no network."
    public static let unknownNetworkReason = "Raw strap frames are waiting: the network state isn't known yet."

    /// Send raw now? Any satisfied path that is not in Low Data Mode: Wi-Fi, wired or cellular, charging or not.
    public static func decide(_ network: Network?) -> Decision {
        guard let n = network else { return .wait(unknownNetworkReason) }
        guard n.satisfied else { return .wait(noNetworkReason) }
        if n.isConstrained { return .wait(lowDataModeReason) }
        return .send
    }

    /// How long the phone keeps confirmed raw frames and per-second rows (Mo, 2026-10-11: "Yes, after 30 days").
    public static let phoneKeepSeconds: TimeInterval = 30 * 86_400

    /// Unix seconds: confirmed data received before this may be deleted.
    public static func deleteCutoff(now: Date) -> TimeInterval {
        now.timeIntervalSince1970 - phoneKeepSeconds
    }

    /// The deletion rule for one frame (MGStore `pruneConfirmed` applies it as SQL with `deleteCutoff`).
    public static func mayDelete(receivedAt: TimeInterval, pcConfirmed: Bool, now: Date) -> Bool {
        pcConfirmed && receivedAt < deleteCutoff(now: now)
    }
}
