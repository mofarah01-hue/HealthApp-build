import Foundation
import MGDomain
import Network

// WP-24 — "sync immediately whenever the PC becomes reachable" (PLAN §2, ARCHITECTURE §5.7 "NWPathMonitor path change
// (Tailscale VPN on/off)") and the network half of the raw-upload gate (MGDomain RawUploadPolicy; #74, 2026-10-11:
// any connection outside Low Data Mode — it used to be D11, Wi-Fi + charging only).
// The iPhone can't see Tailscale's state directly; a VPN tunnel coming up shows as a path change (a new utun
// interface). Whether the PC answers is MGSync's probe (`/v1/health`), not ours.

/// The network as one comparable value.
struct BackgroundNetSnapshot: Equatable, Sendable {
    var satisfied: Bool
    /// "wifi:en0", "other:utun4", sorted. A tunnel coming up or going down changes this list.
    var interfaces: [String]
    var isExpensive: Bool
    var isConstrained: Bool
}

enum BackgroundNetRule {
    /// Worth a sync: the path is usable now, and it was not, or its interfaces changed (Tailscale on, Wi-Fi joined).
    /// The first snapshot after start is not a change (the foreground trigger covers launch).
    static func shouldSync(previous: BackgroundNetSnapshot?, current: BackgroundNetSnapshot) -> Bool {
        guard current.satisfied, let previous else { return false }
        return !previous.satisfied || previous.interfaces != current.interfaces
    }

    /// May raw frames go now? CHANGED 2026-10-11 (#74, Mo: "upload always is fine"): any satisfied path outside Low Data
    /// Mode, cellular included, charging or not (MGDomain `RawUploadPolicy`, tested there). It used to be D11:
    /// "raw frames go only on Wi-Fi (or wired) + charging", via `rawUploadAllowed(network:charging:)`.
    /// Risk (verify on device): whether iOS marks a VPN path over cellular as constrained when Low Data Mode is on.
    static func rawDecision(network: BackgroundNetSnapshot?) -> RawUploadPolicy.Decision {
        RawUploadPolicy.decide(network.map {
            RawUploadPolicy.Network(satisfied: $0.satisfied, isConstrained: $0.isConstrained, isExpensive: $0.isExpensive)
        })
    }

    static func snapshot(_ path: NWPath) -> BackgroundNetSnapshot {
        let names = path.availableInterfaces.map { "\(typeName($0.type)):\($0.name)" }.sorted()
        return BackgroundNetSnapshot(satisfied: path.status == .satisfied, interfaces: names,
                                     isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    private static func typeName(_ t: NWInterface.InterfaceType) -> String {
        switch t {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wired"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}

/// Wraps NWPathMonitor. Calls `onChange(previous, current)` for every update, on its own queue.
final class BackgroundPathWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "mgapp.background.path")
    private let lock = NSLock()
    private var last: BackgroundNetSnapshot?
    private let onChange: @Sendable (BackgroundNetSnapshot?, BackgroundNetSnapshot) -> Void

    init(onChange: @escaping @Sendable (BackgroundNetSnapshot?, BackgroundNetSnapshot) -> Void) {
        self.onChange = onChange
    }

    /// The latest snapshot (nil before the first update).
    var latest: BackgroundNetSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let current = BackgroundNetRule.snapshot(path)
            self.lock.lock()
            let previous = self.last
            self.last = current
            self.lock.unlock()
            self.onChange(previous, current)
        }
        monitor.start(queue: queue)
    }

    func cancel() { monitor.cancel() }
}
