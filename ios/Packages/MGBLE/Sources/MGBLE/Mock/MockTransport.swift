import Foundation

/// An in-memory strap for tests and previews (ARCHITECTURE §4.2). Records every radio operation in order, acks
/// writes, and lets a `responder` answer them with notification frames, as a strap would.
@MainActor
public final class MockTransport: StrapTransport {
    public enum Op: Equatable, Sendable {
        case scan([String])
        case stopScan
        case connect(UUID)
        case cancelConnection(UUID)
        case discover
        case write(characteristic: String, bytes: [UInt8])
        case setNotify(characteristic: String, enabled: Bool)
        case read(String)
    }

    public weak var delegate: StrapTransportDelegate?
    public var radioState: RadioState = .poweredOn
    public var restoredPeripherals: [UUID] = []
    /// Returned by `connectedPeripherals(withService:)`.
    public var connected: [UUID] = []
    /// Peripherals `canReach` reports as known.
    public var reachable: Set<UUID> = []
    /// Characteristics the fake strap exposes.
    public var characteristics: Set<String> = StrapGATT.allKnownCharacteristics
    public var readValues: [String: Data] = [:]
    /// Fail a write before it is acknowledged (e.g. `.insufficientAuthentication` for a refused bond).
    public var writeError: (@MainActor (String, [UInt8]) -> TransportError?)?
    /// Notifications the strap sends after acknowledging a write: [(characteristic, frame bytes)].
    public var responder: (@MainActor (String, [UInt8]) -> [(String, [UInt8])])?
    /// Called for every recorded operation, in order (tests use it to interleave with other events).
    public var onOp: (@MainActor (Op) -> Void)?
    /// Test seam (T9997): when it returns true for a write, the write never completes (until cancelled / 60 s), like a
    /// write to a link that died.
    public var hangWrite: (@MainActor (String, [UInt8]) -> Bool)?

    public private(set) var ops: [Op] = []
    private var linkUp = false
    private var notifying: Set<String> = []

    public init() {}

    /// Frames written to the command characteristic, in order.
    public var commandWrites: [[UInt8]] {
        ops.compactMap { op in
            if case .write(let c, let b) = op, c == StrapGATT.write { return b }
            return nil
        }
    }

    /// Opcodes (frame[10]) of the command writes, in order.
    public var writtenOpcodes: [UInt8] { commandWrites.compactMap { $0.count > 10 ? $0[10] : nil } }

    /// Frames written to the WHOOP 4.0 command characteristic (`61080002`), in order (WHOOP4-LINK).
    public var whoop4CommandWrites: [[UInt8]] {
        ops.compactMap { op in
            if case .write(let c, let b) = op, c == Whoop4GATT.write { return b }
            return nil
        }
    }

    /// Opcodes (frame[6]) of the 4.0 command writes, in order.
    public var whoop4WrittenOpcodes: [UInt8] { whoop4CommandWrites.compactMap { $0.count > 6 ? $0[6] : nil } }

    public func connectedPeripherals(withService service: String) -> [UUID] { connected }

    public func canReach(peripheral id: UUID) -> Bool { reachable.contains(id) }

    public func scan(_ filter: ScanFilter) { record(.scan(filter.serviceUUIDs)) }

    public func stopScan() { record(.stopScan) }

    public func connect(_ id: UUID) async throws {
        record(.connect(id))
        linkUp = true
    }

    public func cancelConnection(_ id: UUID) {
        record(.cancelConnection(id))
        linkUp = false
        notifying.removeAll()
    }

    public func discover(_ plan: [String: [String]]) async throws -> Set<String> {
        record(.discover)
        guard linkUp else { throw TransportError.notConnected }
        return Set(plan.values.flatMap { $0 }).intersection(characteristics)
    }

    public func writeWithResponse(_ data: Data, to characteristic: String) async throws {
        let bytes = [UInt8](data)
        record(.write(characteristic: characteristic, bytes: bytes))
        guard linkUp else { throw TransportError.notConnected }
        guard characteristics.contains(characteristic) else { throw TransportError.characteristicMissing(characteristic) }
        if let error = writeError?(characteristic, bytes) { throw error }
        if hangWrite?(characteristic, bytes) == true { try await Task.sleep(nanoseconds: 60_000_000_000) }
        await Task.yield()
        if let replies = responder?(characteristic, bytes), !replies.isEmpty {
            Task { @MainActor [weak self] in
                for (c, frame) in replies { self?.deliver(frame, from: c) }
            }
        }
    }

    public func setNotify(_ enabled: Bool, for characteristic: String) async throws {
        record(.setNotify(characteristic: characteristic, enabled: enabled))
        guard linkUp else { throw TransportError.notConnected }
        if enabled { notifying.insert(characteristic) } else { notifying.remove(characteristic) }
    }

    public func read(_ characteristic: String) async throws -> Data {
        record(.read(characteristic))
        guard linkUp else { throw TransportError.notConnected }
        guard let value = readValues[characteristic] else { throw TransportError.failed("no value for \(characteristic)") }
        return value
    }

    // MARK: - Test drivers

    /// A notification from the strap. Dropped unless the characteristic is subscribed, as on a real radio.
    public func deliver(_ bytes: [UInt8], from characteristic: String) {
        guard linkUp, notifying.contains(characteristic) else { return }
        delegate?.transport(self, didReceive: Data(bytes), from: characteristic)
    }

    public func simulateDiscovery(_ peripheral: DiscoveredPeripheral) {
        delegate?.transport(self, didDiscover: peripheral)
    }

    public func simulateDisconnect(_ id: UUID, error: String?) {
        linkUp = false
        notifying.removeAll()
        delegate?.transport(self, didDisconnect: id, error: error)
    }

    private func record(_ op: Op) {
        ops.append(op)
        onOp?(op)
    }
}
