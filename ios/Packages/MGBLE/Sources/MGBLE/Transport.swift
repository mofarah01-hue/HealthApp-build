import Foundation

public enum RadioState: Equatable, Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

/// One advertisement seen by a scan. `name` is carried for display only — nothing in MGBLE decides on it.
public struct DiscoveredPeripheral: Equatable, Sendable {
    public var id: UUID
    public var name: String?
    public var advertisedServiceUUIDs: [String]
    public var rssi: Int?

    public init(id: UUID, name: String?, advertisedServiceUUIDs: [String], rssi: Int? = nil) {
        self.id = id
        self.name = name
        self.advertisedServiceUUIDs = advertisedServiceUUIDs.map(StrapGATT.normalize)
        self.rssi = rssi
    }
}

/// What a scan asks the radio for. There is deliberately no name field: straps are matched on the service
/// UUID only (finding L).
public struct ScanFilter: Equatable, Sendable {
    public let serviceUUIDs: [String]

    public init(serviceUUIDs: [String]) {
        self.serviceUUIDs = serviceUUIDs.map(StrapGATT.normalize)
    }

    /// The only filter MGBLE uses (ARCHITECTURE §4.4.1).
    public static let strap = ScanFilter(serviceUUIDs: [StrapGATT.service])
}

public enum TransportError: Error, Equatable, Sendable {
    case notConnected
    case characteristicMissing(String)
    /// The link is not encrypted / the bond was refused (ATT insufficient authentication or encryption) —
    /// typically the strap is still bonded to the WHOOP app or a stale iOS pairing (noop BLEManager L6800-6830).
    case insufficientAuthentication
    case timeout
    case cancelled
    case failed(String)
}

/// Events from the radio. Called on the main actor.
@MainActor
public protocol StrapTransportDelegate: AnyObject {
    func transport(_ transport: StrapTransport, didChangeRadio state: RadioState)
    func transport(_ transport: StrapTransport, didDiscover peripheral: DiscoveredPeripheral)
    func transport(_ transport: StrapTransport, didDisconnect peripheral: UUID, error: String?)
    func transport(_ transport: StrapTransport, didReceive data: Data, from characteristic: String)
    /// iOS relaunched the app into the background with these peripherals already connected (state restoration).
    func transport(_ transport: StrapTransport, didRestore peripherals: [UUID])
}

/// GATT-level access to one strap at a time (ARCHITECTURE §4.2: `CoreBluetoothTransport`, `MockTransport`).
///
/// There is no write-without-response method: every command write waits for the strap's ATT write response
/// (finding A — the 5/MG silently drops without-response writes; noop's `send` defaults to it, BLEManager
/// L2280-2282, and we never do). Characteristic ids are `StrapGATT` strings.
@MainActor
public protocol StrapTransport: AnyObject {
    var delegate: StrapTransportDelegate? { get set }
    var radioState: RadioState { get }
    /// Peripherals iOS handed back through state restoration, not yet claimed by a link.
    var restoredPeripherals: [UUID] { get }

    /// Peripherals already connected to this phone (by any app) that expose `service`.
    func connectedPeripherals(withService service: String) -> [UUID]
    /// True when the system still knows `id` (a standing connect to it can be issued).
    func canReach(peripheral id: UUID) -> Bool
    func scan(_ filter: ScanFilter)
    func stopScan()
    /// Returns once connected. On CoreBluetooth this is a standing connect: no timeout, it completes when the
    /// strap is next in range (noop #1413). Throws `.cancelled` after `cancelConnection`.
    func connect(_ id: UUID) async throws
    func cancelConnection(_ id: UUID)
    /// Discovers `plan` (service → characteristics) on the connected peripheral and returns the characteristic
    /// ids found.
    func discover(_ plan: [String: [String]]) async throws -> Set<String>
    /// Writes WITH RESPONSE and returns when the strap acknowledged the write.
    func writeWithResponse(_ data: Data, to characteristic: String) async throws
    func setNotify(_ enabled: Bool, for characteristic: String) async throws
    func read(_ characteristic: String) async throws -> Data
}
