import Foundation
import MGDomain

/// T9994 (r9d, 2026-10-17): any wake reconnects the strap when it is wanted and the link is down. Night of Oct 15-16: every
/// stream stopped at 3:52 AM and iOS then woke the app hourly (background refresh) without the strap coming back. A wake
/// is the app coming to the foreground, a Bluetooth restore, a background task or a background refresh. Each one asks
/// here; the decision is one pure function of the link's own flags, and every decision is written to the strap log.
public enum WakeDecision: Equatable, Sendable {
    /// Not reconnecting, and why (not started, disconnected on purpose, pairing refused).
    case skip(String)
    /// The link is up: only its silence is checked (the keep-alive rule), nothing is reconnected.
    case linkUp
    /// A connect is already under way.
    case connecting
    /// Already scanning for the strap.
    case scanning
    /// A reconnect was waiting out its delay: cancel the wait and connect now.
    case reconnectNow
    /// Down with nothing pending: read the radio again and start connecting (or say why not).
    case checkRadio

    public var words: String {
        switch self {
        case .skip(let why): return "not reconnecting - \(why)"
        case .linkUp: return "link is up - silence checked"
        case .connecting: return "a connect is already under way"
        case .scanning: return "already scanning for the strap"
        case .reconnectNow: return "link down, a reconnect was waiting - connecting now"
        case .checkRadio: return "link down - reading the radio and connecting"
        }
    }
}

extension StrapLink {
    /// Pure: what a wake does for these flags. `reconnectWaiting` = a reconnect timer is pending, `canReach` = the radio
    /// is on and a peripheral id is known.
    static func wakeDecision(started: Bool, intentionalDisconnect: Bool, bondRefused: Bool, linkUp: Bool,
                             connectInFlight: Bool, scanning: Bool, reconnectWaiting: Bool,
                             canReach: Bool) -> WakeDecision {
        if !started { return .skip("the link is not started") }
        if intentionalDisconnect { return .skip("disconnected on purpose (you or the hand-back)") }
        if bondRefused { return .skip("the strap refused pairing earlier") }
        if linkUp { return .linkUp }
        if connectInFlight { return .connecting }
        if reconnectWaiting, canReach { return .reconnectNow }
        if scanning { return .scanning }
        return .checkRadio
    }

    /// A wake (`reason`: "foreground", "background task", "background refresh", ...). Logs the decision and acts on it.
    public func wake(_ reason: String) {
        let decision = Self.wakeDecision(
            started: started, intentionalDisconnect: intentionalDisconnect, bondRefused: bondRefused,
            linkUp: handshakeDone, connectInFlight: connectTask != nil, scanning: state == .scanning,
            reconnectWaiting: reconnectTask != nil,
            canReach: transport.radioState == .poweredOn && peripheralID != nil)
        logLine("strap: wake (\(reason)) → \(decision.words)")
        switch decision {
        case .skip, .connecting, .scanning:
            break
        case .linkUp:
            keepAliveTick()
        case .reconnectNow:
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempts = 0
            if let id = peripheralID { connect(to: id, restored: false) }
        case .checkRadio:
            evaluateRadio()
        }
    }
}
