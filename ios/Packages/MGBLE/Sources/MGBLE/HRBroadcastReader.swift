import Foundation
import MGDomain

// 0.6.0.12 — "Read WHOOP 5.0 heart-rate broadcast". Reads the standard Bluetooth heart-rate profile (service 180D, measurement
// 2A37) that a WHOOP 5.0 advertises when its HR broadcast is switched on in the WHOOP app, while the strap stays with the WHOOP
// app. It is its own tiny link, not `StrapLink`:
//
//   - bond-free: it never pairs, never asks for encryption, never takes the strap from the WHOOP app;
//   - read-only: it never calls `writeWithResponse` (the only radio calls are scan, connect, discover, subscribe to 2A37);
//   - it matches on the SERVICE UUID 180D. Nothing is connected until Mo picks a device from the scan list once; after that the
//     chosen peripheral id (and its name, for display) is remembered and only that peripheral is reconnected;
//   - a WHOOP 4.0 (service 61080001) never appears in the list: the 4.0 has its own link.
//
// Beats go to the same live HR / R-R path as every other source (`onBeat`), labelled `HRBroadcastReader.beatSource`.
// Whether it may run at all (not while a 4.0 or MG link is feeding beats) is the app's call: `setHeld(reason:)` stops the radio and
// says why (`HRReadSourceRule` in MGContext).

/// What the reader is doing, in words the Settings line can use.
public enum HRBroadcastState: Equatable, Sendable {
    /// The switch is off (or the reader was stopped).
    case off
    /// Held back by the app: another source is feeding heart rate (the text says which) or sample data is on.
    case held(String)
    /// Bluetooth is off, not allowed or not available on this phone.
    case radio(String)
    /// Nothing chosen yet: scanning for heart-rate sensors so Mo can pick one. Nothing is connected.
    case choosing
    /// A device is chosen: looking for it or waiting for it to come into range.
    case searching
    case connecting
    /// Subscribed to 2A37. `beats` counts notifications that carried a heart rate or an R-R interval.
    case reading
}

/// The one device Mo picked, remembered across launches (the id is CoreBluetooth's peripheral id on this phone).
public struct HRBroadcastChoice: Equatable, Sendable, Codable {
    public var id: UUID
    public var name: String?

    public init(id: UUID, name: String?) {
        self.id = id
        self.name = name
    }
}

@MainActor
public final class HRBroadcastReader: StrapTransportDelegate {
    /// The label shown on the Live tab while these beats are the source.
    public static let beatSource = "WHOOP 5.0 broadcast"

    public private(set) var state: HRBroadcastState = .off
    /// Heart-rate sensors seen while choosing, strongest signal first. A WHOOP 4.0 is never in it.
    public private(set) var candidates: [DiscoveredPeripheral] = []
    public private(set) var chosen: HRBroadcastChoice?
    public private(set) var beats = 0
    public private(set) var lastBeatAt: Date?
    /// 2A37 notifications that could not be read (a count for Settings; nothing is guessed from them).
    public private(set) var unreadable = 0
    public private(set) var lastError: String?

    /// One call per notification that carried a heart rate or an R-R interval.
    public var onBeat: (@MainActor (LiveBeat) -> Void)?
    /// Called after every change of `state`, `candidates` or `chosen` (Settings redraws).
    public var onChange: (@MainActor () -> Void)?
    /// Called when Mo picks a device or forgets it, so the app can remember it.
    public var onChosen: (@MainActor (HRBroadcastChoice?) -> Void)?

    private let transport: StrapTransport
    private let clock: any MGDomain.Clock
    private let reconnectDelay: Double
    private var wanted = false
    private var heldReason: String?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?

    public init(transport: StrapTransport, clock: any MGDomain.Clock = SystemClock(), reconnectDelay: Double = 3) {
        self.transport = transport
        self.clock = clock
        self.reconnectDelay = reconnectDelay
        transport.delegate = self
    }

    // MARK: control

    /// Turn the reader on. With a remembered choice it looks for that device; without one it scans so Mo can pick.
    public func start(chosen: HRBroadcastChoice?) {
        wanted = true
        self.chosen = chosen
        evaluate()
    }

    /// Turn the reader off: scan stopped, connection cancelled, nothing kept running.
    public func stop() {
        wanted = false
        heldReason = nil
        tearDown()
        setState(.off)
    }

    /// The app says another source is feeding heart rate (`reason`) or that it may run again (nil).
    public func setHeld(reason: String?) {
        guard heldReason != reason else { return }
        heldReason = reason
        if wanted { evaluate() }
    }

    /// Mo picked a device from the list: remember it and connect. Only a device seen in the last scan can be picked.
    public func choose(_ id: UUID) {
        guard wanted, heldReason == nil, let p = candidates.first(where: { $0.id == id }) else { return }
        let c = HRBroadcastChoice(id: id, name: p.name)
        chosen = c
        onChosen?(c)
        evaluate()
    }

    /// Forget the chosen device and go back to choosing (when the switch is on).
    public func forget() {
        chosen = nil
        candidates = []
        onChosen?(nil)
        if wanted { evaluate() } else { onChange?() }
    }

    /// Scan again for the list (only while nothing is chosen).
    public func rescan() {
        guard wanted, chosen == nil else { return }
        candidates = []
        evaluate()
    }

    // MARK: state machine

    private func evaluate() {
        tearDown()
        guard wanted else { return setState(.off) }
        if let reason = heldReason { return setState(.held(reason)) }
        switch transport.radioState {
        case .poweredOn: break
        case .unauthorized: return setState(.radio("iOS has not allowed MG to use Bluetooth."))
        case .poweredOff: return setState(.radio("Bluetooth is off."))
        case .unsupported: return setState(.radio("Bluetooth is not available on this phone."))
        case .unknown, .resetting: return setState(.radio("Bluetooth is not ready yet."))
        }
        guard let chosen else {
            transport.scan(ScanFilter(serviceUUIDs: [StrapGATT.heartRateService]))
            return setState(.choosing)
        }
        beginConnect(chosen.id)
    }

    private func beginConnect(_ id: UUID) {
        generation += 1
        let mine = generation
        guard transport.canReach(peripheral: id) || transport.connectedPeripherals(withService: StrapGATT.heartRateService).contains(id) else {
            // Not known to iOS yet: scan for it, and connect when it is seen (only that id).
            transport.scan(ScanFilter(serviceUUIDs: [StrapGATT.heartRateService]))
            return setState(.searching)
        }
        setState(.connecting)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.connect(id)
                guard mine == self.generation else { return }
                let found = try await self.transport.discover([StrapGATT.heartRateService: [StrapGATT.heartRateMeasurement]])
                guard mine == self.generation else { return }
                guard found.contains(StrapGATT.heartRateMeasurement) else {
                    self.lastError = "That device has no heart-rate measurement. Is its HR broadcast on?"
                    self.transport.cancelConnection(id)
                    return self.scheduleReconnect(mine)
                }
                try await self.transport.setNotify(true, for: StrapGATT.heartRateMeasurement)
                guard mine == self.generation else { return }
                self.lastError = nil
                self.setState(.reading)
            } catch {
                guard mine == self.generation else { return }
                self.lastError = "\(error)"
                self.transport.cancelConnection(id)
                self.scheduleReconnect(mine)
            }
        }
    }

    private func scheduleReconnect(_ mine: Int) {
        setState(.searching)
        reconnect?.cancel()
        reconnect = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.reconnectDelay * 1_000_000_000))
            guard !Task.isCancelled, mine == self.generation, self.wanted, self.heldReason == nil,
                  let id = self.chosen?.id else { return }
            self.beginConnect(id)
        }
    }

    private func tearDown() {
        generation += 1
        task?.cancel()
        reconnect?.cancel()
        task = nil
        reconnect = nil
        transport.stopScan()
        if let id = chosen?.id { transport.cancelConnection(id) }
    }

    private func setState(_ s: HRBroadcastState) {
        state = s
        onChange?()
    }

    // MARK: StrapTransportDelegate

    public func transport(_ transport: StrapTransport, didChangeRadio state: RadioState) {
        if wanted { evaluate() }
    }

    public func transport(_ transport: StrapTransport, didDiscover peripheral: DiscoveredPeripheral) {
        guard wanted, heldReason == nil else { return }
        // The service UUID decides, never the name. A WHOOP 4.0 advertises its own service as well: it is not listed.
        guard peripheral.advertisedServiceUUIDs.contains(StrapGATT.heartRateService),
              !peripheral.advertisedServiceUUIDs.contains(StrapGATT.whoop4Service) else { return }
        if let chosen {
            // Waiting for the chosen device: connect when it shows up, ignore every other sensor.
            guard peripheral.id == chosen.id, state == .searching else { return }
            transport.stopScan()
            beginConnect(chosen.id)
            return
        }
        if let i = candidates.firstIndex(where: { $0.id == peripheral.id }) { candidates[i] = peripheral } else { candidates.append(peripheral) }
        candidates.sort { ($0.rssi ?? -127) > ($1.rssi ?? -127) }
        onChange?()
    }

    public func transport(_ transport: StrapTransport, didDisconnect peripheral: UUID, error: String?) {
        guard wanted, heldReason == nil, peripheral == chosen?.id else { return }
        lastError = error
        scheduleReconnect(generation)
    }

    public func transport(_ transport: StrapTransport, didReceive data: Data, from characteristic: String) {
        guard StrapGATT.normalize(characteristic) == StrapGATT.heartRateMeasurement, wanted, heldReason == nil else { return }
        guard let m = HeartRateMeasurement.parse([UInt8](data)) else {
            unreadable += 1
            return
        }
        guard m.bpm != nil || !m.rrMs.isEmpty else { return }   // no skin contact / zero: not a reading
        let now = clock.now
        beats += 1
        lastBeatAt = now
        onBeat?(LiveBeat(at: now, bpm: m.bpm.map(Double.init), rrMs: m.rrMs))
    }

    public func transport(_ transport: StrapTransport, didRestore peripherals: [UUID]) {}
}
