#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// `StrapTransport` on CoreBluetooth. One peripheral at a time; the central runs on the main queue, so every
/// callback is already on the main actor (`MainActor.assumeIsolated`, iOS 17 / macOS 14).
///
/// - Writes are `.withResponse` only (finding A). There is no other write call in this file.
/// - `connect` is a standing connect: no timeout, it completes when the strap is next in range (noop #1413,
///   BLEManager L1120-1140). Other GATT operations time out after `gattTimeout`.
/// - State restoration (`mgapp.ble.central`, ARCHITECTURE §4.4.1) is iOS-only; restored peripherals are reported
///   once the radio is powered on (noop BLEManager L6485-6549).
@MainActor
public final class CoreBluetoothTransport: StrapTransport {
    public weak var delegate: StrapTransportDelegate?
    public private(set) var radioState: RadioState = .unknown
    public private(set) var restoredPeripherals: [UUID] = []

    private let proxy: CentralProxy
    private var central: CBCentralManager?
    private let gattTimeout: Double
    private var known: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var connectWaiter: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var discovery: (continuation: CheckedContinuation<Set<String>, Error>, plan: [String: [String]],
                            pending: Set<String>, found: Set<String>)?
    private var discoveryTimer: Task<Void, Never>?
    private let writes = WaiterQueues<Void>()
    private let notifies = WaiterQueues<Void>()
    private let reads = WaiterQueues<Data>()
    private var restoredPending: [CBPeripheral] = []
    /// T9819: iOS relaunched the app for this central (state restoration); the count of peripherals it handed back. The app
    /// writes it to its lifecycle log. Set right after init (the callback arrives later on the main queue).
    public var onRestore: (@MainActor (Int) -> Void)?

    public init(restoreIdentifier: String = StrapGATT.restoreIdentifier, gattTimeout: Double = 15) {
        self.gattTimeout = gattTimeout
        self.proxy = CentralProxy()
        proxy.owner = self
        #if os(iOS)
        let options: [String: Any] = [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        #else
        let options: [String: Any] = [:]
        #endif
        central = CBCentralManager(delegate: proxy, queue: nil, options: options)
    }

    // MARK: StrapTransport

    public func connectedPeripherals(withService service: String) -> [UUID] {
        guard let central else { return [] }
        let found = central.retrieveConnectedPeripherals(withServices: [CBUUID(string: service)])
        for p in found { known[p.identifier] = p }
        return found.map(\.identifier)
    }

    public func canReach(peripheral id: UUID) -> Bool {
        guard let central else { return false }
        if known[id] != nil { return true }
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else { return false }
        known[id] = p
        return true
    }

    public func scan(_ filter: ScanFilter) {
        central?.scanForPeripherals(withServices: filter.serviceUUIDs.map { CBUUID(string: $0) },
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        central?.stopScan()
    }

    public func connect(_ id: UUID) async throws {
        guard let central, let p = known[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            throw TransportError.failed("unknown peripheral")
        }
        known[id] = p
        p.delegate = proxy
        active = p
        restoredPeripherals.removeAll { $0 == id }
        if p.state == .connected { return }   // restored or connected by the system
        if let old = connectWaiter {
            connectWaiter = nil
            old.continuation.resume(throwing: TransportError.cancelled)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectWaiter = (id, continuation)
            central.connect(p, options: nil)
        }
    }

    public func cancelConnection(_ id: UUID) {
        if let w = connectWaiter, w.id == id {
            connectWaiter = nil
            w.continuation.resume(throwing: TransportError.cancelled)
        }
        if let p = known[id] { central?.cancelPeripheralConnection(p) }
    }

    public func discover(_ plan: [String: [String]]) async throws -> Set<String> {
        guard let p = active, p.state == .connected else { throw TransportError.notConnected }
        characteristics.removeAll()
        if let d = discovery {
            discovery = nil
            d.continuation.resume(throwing: TransportError.cancelled)
        }
        let timeout = gattTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Set<String>, Error>) in
            discovery = (continuation, plan, [], [])
            discoveryTimer?.cancel()
            discoveryTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let self, let d = self.discovery else { return }
                self.discovery = nil
                d.continuation.resume(throwing: TransportError.timeout)
            }
            p.discoverServices(plan.keys.map { CBUUID(string: $0) })
        }
    }

    public func writeWithResponse(_ data: Data, to characteristic: String) async throws {
        let (p, c, key) = try target(characteristic)
        try await writes.wait(key, timeout: gattTimeout) {
            p.writeValue(data, for: c, type: .withResponse)
        }
    }

    public func setNotify(_ enabled: Bool, for characteristic: String) async throws {
        let (p, c, key) = try target(characteristic)
        // An already-notifying characteristic gets no callback for setNotifyValue(true) (noop BLEManager L5421).
        if c.isNotifying == enabled { return }
        try await notifies.wait(key, timeout: gattTimeout) {
            p.setNotifyValue(enabled, for: c)
        }
    }

    public func read(_ characteristic: String) async throws -> Data {
        let (p, c, key) = try target(characteristic)
        return try await reads.wait(key, timeout: gattTimeout) {
            p.readValue(for: c)
        }
    }

    private func target(_ characteristic: String) throws -> (CBPeripheral, CBCharacteristic, String) {
        guard let p = active, p.state == .connected else { throw TransportError.notConnected }
        let key = StrapGATT.normalize(characteristic)
        guard let c = characteristics[key] else { throw TransportError.characteristicMissing(characteristic) }
        return (p, c, key)
    }

    // MARK: Callbacks (main queue → main actor)

    fileprivate func handleState(_ state: CBManagerState) {
        switch state {
        case .poweredOn: radioState = .poweredOn
        case .poweredOff: radioState = .poweredOff
        case .unauthorized: radioState = .unauthorized
        case .unsupported: radioState = .unsupported
        case .resetting: radioState = .resetting
        default: radioState = .unknown
        }
        if radioState != .poweredOn { failEverything(TransportError.notConnected) }
        // Restored peripherals first, so the link re-arms them as restored instead of finding them as merely
        // "already connected" through the radio-on path.
        if radioState == .poweredOn, !restoredPending.isEmpty {
            let connectedIDs = restoredPending.filter { $0.state == .connected }.map(\.identifier)
            restoredPending.removeAll()
            restoredPeripherals = connectedIDs
            if !connectedIDs.isEmpty { delegate?.transport(self, didRestore: connectedIDs) }
        }
        delegate?.transport(self, didChangeRadio: radioState)
    }

    fileprivate func handleRestore(_ peripherals: [CBPeripheral]) {
        for p in peripherals {
            known[p.identifier] = p
            p.delegate = proxy
        }
        restoredPending = peripherals
        onRestore?(peripherals.count)
    }

    fileprivate func handleDiscover(_ p: CBPeripheral, services: [String], name: String?, rssi: Int) {
        known[p.identifier] = p
        delegate?.transport(self, didDiscover: DiscoveredPeripheral(id: p.identifier, name: name,
                                                                    advertisedServiceUUIDs: services, rssi: rssi))
    }

    fileprivate func handleConnect(_ p: CBPeripheral) {
        restoredPeripherals.removeAll { $0 == p.identifier }
        if let w = connectWaiter, w.id == p.identifier {
            connectWaiter = nil
            w.continuation.resume()
        }
    }

    fileprivate func handleFailToConnect(_ p: CBPeripheral, error: Error?) {
        if let w = connectWaiter, w.id == p.identifier {
            connectWaiter = nil
            w.continuation.resume(throwing: TransportError.failed(error?.localizedDescription ?? "connect failed"))
        }
    }

    fileprivate func handleDisconnect(_ p: CBPeripheral, error: Error?) {
        if active?.identifier == p.identifier {
            characteristics.removeAll()
            failEverything(TransportError.notConnected)
        }
        delegate?.transport(self, didDisconnect: p.identifier, error: error?.localizedDescription)
    }

    fileprivate func handleServices(_ p: CBPeripheral, error: Error?) {
        guard var d = discovery else { return }
        if let error {
            discovery = nil
            d.continuation.resume(throwing: TransportError.failed(error.localizedDescription))
            return
        }
        for service in p.services ?? [] {
            let key = StrapGATT.normalize(service.uuid.uuidString)
            guard let wanted = d.plan[key] else { continue }
            d.pending.insert(key)
            p.discoverCharacteristics(wanted.map { CBUUID(string: $0) }, for: service)
        }
        discovery = d
        finishDiscoveryIfDone()
    }

    fileprivate func handleCharacteristics(_ p: CBPeripheral, service: CBService, error: Error?) {
        guard var d = discovery else { return }
        let key = StrapGATT.normalize(service.uuid.uuidString)
        for c in service.characteristics ?? [] {
            let id = StrapGATT.normalize(c.uuid.uuidString)
            characteristics[id] = c
            d.found.insert(id)
        }
        d.pending.remove(key)
        discovery = d
        finishDiscoveryIfDone()
    }

    private func finishDiscoveryIfDone() {
        guard let d = discovery, d.pending.isEmpty else { return }
        discovery = nil
        discoveryTimer?.cancel()
        d.continuation.resume(returning: d.found)
    }

    fileprivate func handleWrite(_ c: CBCharacteristic, error: Error?) {
        let key = StrapGATT.normalize(c.uuid.uuidString)
        if let error {
            writes.resumeFirst(key, .failure(Self.map(error)))
        } else {
            writes.resumeFirst(key, .success(()))
        }
    }

    fileprivate func handleNotifyState(_ c: CBCharacteristic, error: Error?) {
        let key = StrapGATT.normalize(c.uuid.uuidString)
        if let error {
            notifies.resumeFirst(key, .failure(Self.map(error)))
        } else {
            notifies.resumeFirst(key, .success(()))
        }
    }

    fileprivate func handleValue(_ c: CBCharacteristic, error: Error?) {
        let key = StrapGATT.normalize(c.uuid.uuidString)
        if reads.hasWaiter(key) {
            if let error {
                reads.resumeFirst(key, .failure(Self.map(error)))
            } else {
                reads.resumeFirst(key, .success(c.value ?? Data()))
            }
            return
        }
        guard error == nil, let value = c.value else { return }
        delegate?.transport(self, didReceive: value, from: key)
    }

    private func failEverything(_ error: TransportError) {
        writes.failAll(error)
        notifies.failAll(error)
        reads.failAll(error)
        if let d = discovery {
            discovery = nil
            d.continuation.resume(throwing: error)
        }
    }

    /// ATT "insufficient authentication / encryption" = the bond was refused (noop BLEManager
    /// `isInsufficientAuthError`, classified by code, not by localized text).
    private static func map(_ error: Error) -> TransportError {
        let ns = error as NSError
        if ns.domain == CBATTErrorDomain,
           ns.code == CBATTError.Code.insufficientAuthentication.rawValue
            || ns.code == CBATTError.Code.insufficientEncryption.rawValue {
            return .insufficientAuthentication
        }
        return .failed(error.localizedDescription)
    }
}

/// CoreBluetooth delegate trampoline. The central uses the main queue, so each callback asserts main-actor
/// isolation and forwards to the transport.
private final class CentralProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: CoreBluetoothTransport?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { _ = owner?.handleState(state) }
    }

    #if os(iOS)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated { _ = owner?.handleRestore(peripherals) }
    }
    #endif

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { StrapGATT.normalize($0.uuidString) }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { _ = owner?.handleDiscover(peripheral, services: services, name: name, rssi: rssi) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { _ = owner?.handleConnect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { _ = owner?.handleFailToConnect(peripheral, error: error) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { _ = owner?.handleDisconnect(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { _ = owner?.handleServices(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { _ = owner?.handleCharacteristics(peripheral, service: service, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { _ = owner?.handleWrite(characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        MainActor.assumeIsolated { _ = owner?.handleNotifyState(characteristic, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { _ = owner?.handleValue(characteristic, error: error) }
    }
}

/// FIFO waiters per characteristic, each with a timeout. CoreBluetooth completes operations on one characteristic
/// in order, so the oldest waiter takes the next callback.
@MainActor
final class WaiterQueues<Value> {
    private struct Entry {
        let id: UInt64
        let continuation: CheckedContinuation<Value, Error>
    }

    private var queues: [String: [Entry]] = [:]
    private var counter: UInt64 = 0

    func wait(_ key: String, timeout: Double, start: () -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            counter &+= 1
            let id = counter
            queues[key, default: []].append(Entry(id: id, continuation: continuation))
            start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.expire(key, id)
            }
        }
    }

    func hasWaiter(_ key: String) -> Bool { !(queues[key]?.isEmpty ?? true) }

    func resumeFirst(_ key: String, _ result: Result<Value, TransportError>) {
        guard var q = queues[key], !q.isEmpty else { return }
        let entry = q.removeFirst()
        queues[key] = q
        switch result {
        case .success(let v): entry.continuation.resume(returning: v)
        case .failure(let e): entry.continuation.resume(throwing: e)
        }
    }

    func failAll(_ error: TransportError) {
        let all = queues
        queues.removeAll()
        for (_, q) in all { for e in q { e.continuation.resume(throwing: error) } }
    }

    private func expire(_ key: String, _ id: UInt64) {
        guard var q = queues[key], let i = q.firstIndex(where: { $0.id == id }) else { return }
        let entry = q.remove(at: i)
        queues[key] = q
        entry.continuation.resume(throwing: TransportError.timeout)
    }
}
#endif
