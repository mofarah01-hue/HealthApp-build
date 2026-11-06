import Foundation

// 0.6.0.12 — "Read WHOOP 5.0 heart-rate broadcast" (Strap & sync). The reader itself is MGBLE's `HRBroadcastReader`; this file is
// what Settings shows and the one rule about which source may feed the live heart rate.

/// Payload of `UIIntent.hrRead`.
public enum HRReadAction: Equatable, Sendable {
    /// The switch.
    case setOn(Bool)
    /// Mo picked this sensor (a `HRReadCandidate.id`) from the scan list. Nothing connects before this.
    case pick(String)
    /// Forget the chosen sensor and choose again.
    case forget
    /// Scan again for the list.
    case rescan
}

/// What the reader is doing (mirrors MGBLE's `HRBroadcastState`; MGContext does not import MGBLE).
public enum HRReadPhase: Equatable, Sendable {
    case off, held, radio, choosing, searching, connecting, reading
}

public struct HRReadCandidate: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var rssi: Int?

    public init(id: String, name: String?, rssi: Int?) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

public struct HRReadInfo: Equatable, Sendable {
    public var wanted = false
    public var phase: HRReadPhase = .off
    /// Why the reader is held or the radio unusable (the reader's own words).
    public var detail: String?
    public var chosenName: String?
    public var chosenID: String?
    public var candidates: [HRReadCandidate] = []
    public var beats = 0
    public var lastBeatAt: Date?
    public var lastError: String?
    /// The other links, for the one-source rule.
    public var whoop4LinkUp = false
    public var mgLinkUp = false

    public init() {}
}

/// Only one source feeds the live heart rate at a time. The 5.0 broadcast runs only when no other strap link is up; a connected
/// WHOOP 4.0 (or MG) link wins and the broadcast waits, and Settings says which one is in use.
public enum HRReadSourceRule {
    public enum Decision: Equatable, Sendable {
        case off
        case run
        case hold(String)
    }

    public static func decide(wanted: Bool, sample: Bool, whoop4LinkUp: Bool, mgLinkUp: Bool) -> Decision {
        guard wanted else { return .off }
        if sample { return .hold("Sample data is on.") }
        if whoop4LinkUp { return .hold("The WHOOP 4.0 is connected and feeding heart rate, so the 5.0 broadcast waits.") }
        if mgLinkUp { return .hold("The MG link is connected and feeding heart rate, so the 5.0 broadcast waits.") }
        return .run
    }

    /// "Heart rate now comes from …": which source feeds the Live tab, or nil when the switch is off.
    public static func sourceLine(_ i: HRReadInfo) -> String? {
        guard i.wanted else { return nil }
        if i.whoop4LinkUp { return "Heart rate now comes from the WHOOP 4.0. The 5.0 broadcast is paused." }
        if i.mgLinkUp { return "Heart rate now comes from the MG link. The 5.0 broadcast is paused." }
        switch i.phase {
        case .reading: return "Heart rate now comes from the WHOOP 5.0 broadcast" + (i.chosenName.map { " (\($0))." } ?? ".")
        default: return "No heart rate yet from the WHOOP 5.0 broadcast."
        }
    }
}

public struct HRReadSection: Equatable, Sendable {
    public var toggle: ToggleState
    public var lines: [String]
    /// The scan list, while choosing. Tapping one is the only thing that connects.
    public var candidates: [ActionState]
    public var rescan: ActionState?
    public var forget: ActionState?
}

public enum HRReadPresenter {
    public static func section(_ s: PresenterSnapshot) -> HRReadSection {
        let i = s.strapSync.hrRead
        let toggle = ToggleState(
            id: "hrRead", title: "Read WHOOP 5.0 heart-rate broadcast",
            detail: "Reads the standard Bluetooth heart rate your WHOOP 5.0 sends when \"HR Broadcast\" is on in the WHOOP app, "
                + "while the strap stays with the WHOOP app. It never pairs, never writes anything to the strap and never takes "
                + "it from the WHOOP app. Only one source feeds Live at a time: a connected strap link wins.",
            isOn: i.wanted, enabled: !s.sample, disabledReason: s.sample ? "Sample data is on." : nil,
            intent: .hrRead(.setOn(!i.wanted)))
        var lines: [String] = []
        if let src = HRReadSourceRule.sourceLine(i) { lines.append(src) }
        if i.wanted {
            switch i.phase {
            case .off: break
            case .held: lines.append(i.detail ?? "Waiting for the other source to stop.")
            case .radio: lines.append(i.detail ?? "Bluetooth is not ready.")
            case .choosing:
                lines.append(i.candidates.isEmpty
                             ? "Looking for heart-rate sensors. Switch on HR Broadcast in the WHOOP app and keep the strap near the phone."
                             : "Pick your strap from the list. Nothing connects until you do.")
            case .searching: lines.append("Looking for \(i.chosenName ?? "your strap")…")
            case .connecting: lines.append("Connecting to \(i.chosenName ?? "your strap")…")
            case .reading:
                lines.append("Reading \(i.chosenName ?? "your strap"): \(i.beats) beat\(i.beats == 1 ? "" : "s")"
                             + (i.lastBeatAt.map { ", last at \(s.hm($0))" } ?? "") + ".")
            }
            if let e = i.lastError, i.phase == .searching || i.phase == .connecting { lines.append("Last problem: \(e)") }
        }
        let choosing = i.wanted && i.phase == .choosing
        let candidates = choosing ? i.candidates.map { c -> ActionState in
            let signal = c.rssi.map { " · signal \($0) dBm" } ?? ""
            return ActionState(id: "hrReadPick.\(c.id)", title: (c.name ?? "Heart-rate sensor") + signal,
                               intent: .hrRead(.pick(c.id)))
        } : []
        let rescan = choosing ? ActionState(id: "hrReadRescan", title: "Scan again", intent: .hrRead(.rescan)) : nil
        let forget = (i.wanted && i.chosenID != nil)
            ? ActionState(id: "hrReadForget", title: "Forget \(i.chosenName ?? "this strap")", intent: .hrRead(.forget)) : nil
        return HRReadSection(toggle: toggle, lines: lines, candidates: candidates, rescan: rescan, forget: forget)
    }
}
