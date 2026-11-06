import Foundation

// The Sundial's magnify mode: a plain state machine, no SwiftUI (round 8, T10023, audit UI-SCRUB-A §5 step 4).
//
// A tap on the dial that is not on a mark magnifies it: the dial grows to the full screen width, the rings are
// re-spaced into a wider zone, and a ring can be picked by tapping it or by dragging from the centre outward (the
// existing ring stepping, with its 60 % hysteresis and haptics). The sheet-opening tap moves to the info card, so one
// tap on the dial never both magnifies and opens a sheet, and a drag never opens one.
//
//   off  --tap on a ring or on nothing-->  on (that ring selected, if a ring was tapped)
//   off  --tap on a mark/arc/tick------->  off, opens that thing's sheet (as before)
//   on   --tap on a ring---------------->  on, that ring selected (its card shows)
//   on   --tap on a mark/arc/tick------->  on, opens that thing's sheet
//   on   --tap on nothing / the hub----->  off          (also "tap outside" and the Done chip: `leave()`)
//   on   --tap on the info card--------->  on, opens the selected ring's sheet
//   on   --a drag (ring step or scrub)-->  on, never a sheet; a ring step that ends on a ring keeps it selected
public struct DialMagnify: Equatable, Sendable {
    /// What a tap landed on, decided by the view from the spot (`SundialReading.tapTarget`).
    public enum Spot: Equatable, Sendable {
        case ring(DialRing.Kind)
        /// A rim mark, arc, plan tick, focus band or caffeine curve: anything with its own sheet that is not a ring.
        case thing(DialTarget)
        /// Nothing there, the hub, or outside the rim.
        case blank
    }

    public enum Effect: Equatable, Sendable {
        case none
        case open(DialTarget)
    }

    public private(set) var isOn = false
    /// The ring whose info card shows while magnified (kept after the finger lifts, so the card can be tapped).
    public private(set) var selected: DialRing.Kind?

    public init() {}

    public mutating func tap(_ spot: Spot) -> Effect {
        switch spot {
        case .thing(let target):
            return .open(target)
        case .ring(let kind):
            isOn = true
            selected = kind
            return .none
        case .blank:
            if isOn { leave() } else { enter() }
            return .none
        }
    }

    /// The info card was tapped: open the selected ring's sheet. Only while magnified, and only with a card showing.
    public mutating func tapCard() -> Effect {
        guard isOn, let kind = selected else { return .none }
        return .open(.ring(kind))
    }

    /// A finger drag ended (ring step or time scrub). Never opens anything; a ring step keeps its ring selected.
    public mutating func dragEnded(ring: DialRing.Kind?) {
        guard isOn else { return }
        if let ring { selected = ring }
    }

    public mutating func enter() {
        isOn = true
    }

    /// Tap outside, the Done chip, VoiceOver escape.
    public mutating func leave() {
        isOn = false
        selected = nil
    }
}
