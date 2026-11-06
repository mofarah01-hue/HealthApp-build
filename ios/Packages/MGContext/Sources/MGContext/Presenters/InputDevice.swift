import Foundation

// 0.6.0.3 "Ring live" (Mo, Oct 26 2026): which device feeds the live heart rate, the WHOOP strap or the smart ring.
// Settings keeps Mo's choice (`InputDevice`); `InputDeviceRule.active` turns it plus what is connected right now into
// the device in use. Pure, so it is tested on Linux.

public enum InputDevice: String, Codable, CaseIterable, Equatable, Sendable {
    /// Whatever is connected: the strap when its link is up, else the ring when it is connected, else none.
    case auto
    case whoop
    case ring

    public var title: String {
        switch self {
        case .auto: return "Auto — whatever is connected"
        case .whoop: return "WHOOP strap"
        case .ring: return "Ring"
        }
    }
}

public enum ActiveInput: Equatable, Sendable {
    case strap, ring, none
}

public enum InputDeviceRule {
    /// `strapLinkUp`: the strap link is `.ready` or `.downloadingHistory`. `ringConnected`: the ring is connected and
    /// its services are discovered.
    public static func active(setting: InputDevice, strapLinkUp: Bool, ringConnected: Bool) -> ActiveInput {
        switch setting {
        case .ring: return .ring
        case .whoop: return .strap
        case .auto: return strapLinkUp ? .strap : (ringConnected ? .ring : .none)
        }
    }

    /// "Active: Ring (M09), connected" / "Active: none — nothing is connected".
    public static func line(active: ActiveInput, strapLinkUp: Bool, ringConnected: Bool, ringName: String?) -> String {
        switch active {
        case .strap: return "Active: WHOOP strap, " + (strapLinkUp ? "connected" : "not connected")
        case .ring:
            let name = ringName.map { " (\($0))" } ?? ""
            return "Active: Ring\(name), " + (ringConnected ? "connected" : "not connected yet")
        case .none: return "Active: none — nothing is connected"
        }
    }
}

/// Strap & sync › "Input device": the picker button's label, one row per choice, and the lines under it.
public struct InputDeviceSection: Equatable, Sendable {
    public var currentTitle: String
    public var options: [ActionState]
    public var detailLines: [String]

    public init(currentTitle: String, options: [ActionState], detailLines: [String]) {
        self.currentTitle = currentTitle
        self.options = options
        self.detailLines = detailLines
    }
}
