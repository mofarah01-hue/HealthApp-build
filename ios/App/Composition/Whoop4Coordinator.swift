import Combine
import Foundation
import MGBLE
import MGContext
import MGDomain
import MGStore

// WHOOP4-LINK (2026-11-05; D-WHOOP4-LINK-1) — owns the WHOOP 4.0 link next to `StrapCoordinator` (the 5/MG's). One
// `CoreBluetoothTransport` of its own (restore id `mgapp.ble.central.whoop4`), one `Whoop4Link`. The two coordinators never run
// together: Settings › Strap & sync › Device decides which one starts (`StrapDeviceChoice`), and the 5/MG link also refuses to
// scan or connect while "WHOOP 4.0" is selected (`StrapLinkConfig.connectGate`).
//
// WRITTEN, NOT COMPILED here (the app target is built with xtool; only the MGBLE package was compiled and tested on Linux).

@MainActor
final class Whoop4Coordinator: ObservableObject {
    /// UserDefaults keys: a 4.0 was paired once (the central is created at launch for state restoration and the link starts by
    /// itself), the paired strap's peripheral id, and when Mo tapped Pair (the standing consent for setting the strap's clock).
    static let pairedKey = "mg.whoop4.paired"
    static let pinnedKey = "mg.whoop4.peripheral"
    static let consentKey = "mg.whoop4.clockConsentAt"
    static let restoreIdentifier = "mgapp.ble.central.whoop4"

    private let store: MGStore
    private let clock: any MGDomain.Clock

    /// What Settings shows. `choice` mirrors `StrapDeviceChoice.stored`; `state` and `status` follow the link.
    @Published private(set) var choice: StrapDeviceChoice = StrapDeviceChoice.stored
    @Published private(set) var state: StrapLinkState = .idle
    @Published private(set) var status = Whoop4Status()

    private(set) var link: Whoop4Link?
    private var transport: CoreBluetoothTransport?
    private var tasks: [Task<Void, Never>] = []
    /// Live beats and strap events go to the same screens as the 5/MG's (AppModel wires them).
    var onBeat: @MainActor (LiveBeat) -> Void = { _ in }
    var onEvent: @MainActor (StrapEvent) -> Void = { _ in }
    /// WHOOP4-WIRE: a finished history download (on connect or a keep-up pull) goes to the same follow-ups as the 5/MG's
    /// (`AppModel.historyFinished`: compute request, wake chain, checkpoint, PC sync trigger).
    var onHistory: @MainActor (HistorySummary) -> Void = { _ in }
    /// WHOOP4-WIRE: every link-state change goes to the same handler as the 5/MG's (`AppModel.strapChanged`): the sync request
    /// after a download, the wake-chain / alarm re-arm on a fresh handshake, the screens' link state.
    var onChange: @MainActor (StrapLinkState) -> Void = { _ in }
    private var lastHistoryReported: HistorySummary?
    /// WHOOP4-WIRE 4: the HR broadcast switch (AppModel sets it before the link starts); the link writes command 14 at the handshake
    /// when it is on. `onHRBroadcast` fires when the strap's answer or its event 24 / 25 changes what Settings shows.
    var hrBroadcastWanted: Bool?
    /// WHOOP4-WIRE 6: the raw stream (command 63) the app wants (a raw optical / raw motion switch is on and may run now); default off.
    /// Decoded IMU seconds, optical frames and the stream status go to the app below; `recentOptical` is what the Live Waves card falls
    /// back to (the last ~1,000 raw samples, no unit).
    private(set) var rawStreamWanted = false
    var onRawMotion: @MainActor (MotionSecond) -> Void = { _ in }
    var onRawOptical: @MainActor (Whoop4OpticalFrame) -> Void = { _ in }
    var onRawStatus: @MainActor (Whoop4RawStatus) -> Void = { _ in }
    private(set) var recentOptical: [Int32] = []
    /// 0.6.0.12: asked once a minute while a link exists; the app reads the LED settings (GET 40 / 42 / 44) when the overnight schedule says so.
    var ledTick: (@MainActor () async -> Void)?
    var onHRBroadcast: @MainActor (String?) -> Void = { _ in }
    private var lastHRBroadcastReported: String?
    private(set) var log: [String] = []
    /// Lines kept for the debug channel's `whoop4-log.txt` (was 200, which a single download overran; 5,000 lines is about 400 KB and the
    /// `logs` command tails it to the 1.4 MB file cap).
    static let logCap = 5000

    init(store: MGStore, clock: any MGDomain.Clock) {
        self.store = store
        self.clock = clock
    }

    static var wasPaired: Bool { UserDefaults.standard.bool(forKey: pairedKey) }

    static var pinnedPeripheral: UUID? {
        UserDefaults.standard.string(forKey: pinnedKey).flatMap(UUID.init(uuidString:))
    }

    static var consentAt: Date? {
        let t = UserDefaults.standard.double(forKey: consentKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// BLE state restoration needs the central to exist at launch (MGApp.init), but only when the 4.0 is the selected device
    /// and was paired: a restored 5.0 must not be handed to anything.
    private static var earlyTransport: CoreBluetoothTransport?

    static func createEarlyTransportIfSelected() {
        guard wasPaired, StrapDeviceChoice.stored == .whoop4, earlyTransport == nil else { return }
        earlyTransport = CoreBluetoothTransport(restoreIdentifier: restoreIdentifier)
    }

    private func prepareTransport() {
        if transport == nil { transport = Self.earlyTransport ?? CoreBluetoothTransport(restoreIdentifier: Self.restoreIdentifier) }
    }

    // MARK: Choice

    /// Saves the choice. Nothing connects here; the caller (`AppModel.chooseStrapDevice`) starts or stops the links.
    func select(_ new: StrapDeviceChoice) {
        StrapDeviceChoice.store(new)
        choice = new
        if new != .whoop4 { stop() }
    }

    // MARK: Link

    /// Builds the link if needed and starts it. Only call with "WHOOP 4.0" selected; the link's own gate checks again.
    func start(installSalt: Data) {
        guard StrapDeviceChoice.stored == .whoop4 else { return }
        prepareTransport()
        guard let transport else { return }
        UserDefaults.standard.set(true, forKey: Self.pairedKey)
        if let link {
            link.hrBroadcastWanted = hrBroadcastWanted
            link.presetRawStream(rawStreamWanted)
            link.start()
            return
        }
        // No command is refused on policy (CLAUDE.md rule 5); the clock is set only with the consent given by tapping Pair.
        let config = StrapLinkConfig(installSalt: installSalt, pinnedPeripheralID: Self.pinnedPeripheral,
                                     clockConsentAt: Self.consentAt, policy: .b1, autoDownloadHistoryOnConnect: true,
                                     timing: .production, connectGate: { StrapDeviceChoice.stored == .whoop4 })
        let store = self.store
        let new = Whoop4Link(transport: transport, config: config, clock: clock, historySink: store, liveSink: store,
                             writeLog: store, log: { [weak self] line in self?.note(line) })
        new.onBonded = { [weak self] id in
            UserDefaults.standard.set(id.uuidString, forKey: Whoop4Coordinator.pinnedKey)
            self?.note("whoop4: bonded, strap remembered (\(id.uuidString.prefix(8))…)")
        }
        new.onPinRejected = { [weak self] id in
            UserDefaults.standard.removeObject(forKey: Whoop4Coordinator.pinnedKey)   // that device is not a 4.0: forget it
            self?.note("whoop4: saved device \(id.uuidString.prefix(8))... has no 4.0 service - forgotten, scanning")
        }
        new.hrBroadcastWanted = hrBroadcastWanted
        new.presetRawStream(rawStreamWanted)
        link = new
        observe(new)
        new.start()
    }

    /// "Pair WHOOP 4.0": forget any earlier pin, record the standing clock consent, build a fresh link and scan for the 4.0
    /// service only. Bonding happens on the first write, no iOS dialog; if it fails the link says how to put the strap in
    /// pairing mode (tap until the blue light shows).
    func pair(installSalt: Data) {
        UserDefaults.standard.removeObject(forKey: Self.pinnedKey)
        UserDefaults.standard.set(clock.now.timeIntervalSince1970, forKey: Self.consentKey)
        teardown()
        start(installSalt: installSalt)
    }

    func stop() {
        link?.disconnect()
        teardown()
    }

    /// HR broadcast switch (WHOOP4-WIRE 4): written now when connected, else at the next handshake (the link keeps the wish).
    func setHRBroadcast(_ on: Bool) async {
        hrBroadcastWanted = on
        if let link { await link.setHRBroadcast(on) }
    }

    /// The raw stream switch (WHOOP4-WIRE 6): `on` = raw optical or raw motion is on and may run now. Stored when there is no link yet.
    func setRawStream(_ on: Bool) {
        rawStreamWanted = on
        guard let link else { return }
        Task { @MainActor in await link.setRawStream(on) }
    }

    func wake(_ reason: String) {
        link?.wake(reason)
    }

    /// Settings › Command test, with "WHOOP 4.0" selected: one frame, WITH RESPONSE. Throws words for the page.
    func sendTestCommand(opcode: UInt8, payload: [UInt8]) async throws {
        guard let link else { throw StrapActionError("the WHOOP 4.0 link is not started") }
        do { _ = try await link.sendTestCommand(opcode: opcode, payload: payload) } catch {
            throw StrapActionError(StrapCoordinator.words(error))
        }
    }

    var isConnected: Bool {
        switch state {
        case .ready, .downloadingHistory: return true
        default: return false
        }
    }

    /// The Settings status line: connected, firmware, serial, battery, worn, live HR.
    var statusLine: String { status.line(connected: isConnected, now: clock.now) }

    /// 0.6.0.11: what Today and Live show while "WHOOP 4.0" is selected (they used to show the idle 5/MG link: "MG not connected").
    func strapStatus(lastRecordAt: Date?) -> StrapStatus {
        let link: StrapStatus.Link
        switch state {
        case .ready, .downloadingHistory: link = .connected
        case .scanning: link = .searching
        case .connecting, .bonding, .handshaking: link = .connecting
        case .bluetoothOff: link = .bluetoothOff
        case .unauthorized: link = .bluetoothNotAllowed
        default: link = (Self.wasPaired || status.bonded) ? .disconnected : .notPaired
        }
        var s = StrapStatus(link: link, batteryPercent: status.batteryPercent, charging: status.charging,
                            offWristSince: status.worn == false ? (status.liveAt ?? clock.now) : nil,
                            lastRecordAt: lastRecordAt)
        s.device = "WHOOP 4.0"
        return s
    }

    /// 0.6.0.11 "Stop buzzing" (Mo, Nov 5: the 4.0 "started vibrating like hell" on connect): STOP_HAPTICS (122) [00] ends a
    /// running pattern, DISABLE_ALARM (69) [01] clears a stored strap alarm (a second-hand strap may hold one). noop
    /// BLE_REVERSE_ENGINEERING.md §6 + PROTOCOL.md; bWanShiTong "Alarm off" = 0x45 01. Returns one line per command.
    func stopBuzzing() async -> String {
        guard let link else { return "the WHOOP 4.0 link is not started" }
        var out: [String] = []
        for (op, payload, name) in [(UInt8(122), [UInt8(0)], "STOP_HAPTICS"), (UInt8(69), [UInt8(1)], "DISABLE_ALARM")] {
            do {
                let r = try await link.sendTestCommand(opcode: op, payload: payload)
                out.append("\(name) (\(op)): " + (r.map { "answered \($0.result)" } ?? "sent"))
            } catch {
                out.append("\(name) (\(op)): \(StrapCoordinator.words(error))")
            }
        }
        let line = "whoop4: stop buzzing - " + out.joined(separator: "; ")
        note(line)
        return line
    }

    // MARK: Internals

    private func observe(_ link: Whoop4Link) {
        tasks.append(Task { @MainActor [weak self, weak link] in
            guard let link else { return }
            for await s in link.$state.values {
                guard let self else { return }
                self.state = s
                self.onChange(s)
            }
        })
        tasks.append(Task { @MainActor [weak self, weak link] in
            guard let link else { return }
            for await s in link.$status.values {
                guard let self else { return }
                self.status = s
                if let h = s.lastHistory, h != self.lastHistoryReported {   // the status stream fires per beat: once per download
                    self.lastHistoryReported = h
                    self.onHistory(h)
                }
                if s.hrBroadcast != self.lastHRBroadcastReported {
                    self.lastHRBroadcastReported = s.hrBroadcast
                    self.onHRBroadcast(s.hrBroadcast)
                }
                await self.register(link, s)
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                await self.ledTick?()
            }
        })
        let beats = link.liveBeats
        tasks.append(Task { @MainActor [weak self] in
            for await b in beats { self?.onBeat(b) }
        })
        let events = link.strapEvents
        tasks.append(Task { @MainActor [weak self] in
            for await e in events { self?.onEvent(e) }
        })
        let motion = link.liveRawMotion
        tasks.append(Task { @MainActor [weak self] in
            for await m in motion { self?.onRawMotion(m) }
        })
        let optical = link.liveRawOptical
        tasks.append(Task { @MainActor [weak self] in
            for await f in optical {
                guard let self else { return }
                self.recentOptical = Array((self.recentOptical + f.samples).suffix(1000))
                self.onRawOptical(f)
            }
        })
        tasks.append(Task { @MainActor [weak self, weak link] in
            guard let link else { return }
            for await r in link.$rawStream.values {
                guard let self else { return }
                self.onRawStatus(r)
            }
        })
    }

    private func teardown() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        link?.disconnect()
        link = nil
        lastRegistered = nil
        lastHistoryReported = nil
        state = .idle
    }

    /// The strap registry row (§4.5 `strap`): family "whoop4", firmware and model as the link learns them.
    private func register(_ link: Whoop4Link, _ s: Whoop4Status) async {
        guard let id = link.currentStrapID else { return }
        let key = "\(id)|\(s.firmware ?? "")"
        guard key != lastRegistered else { return }   // the status stream fires per HR beat: write the row only when it changes
        lastRegistered = key
        do {
            try await store.upsertStrap(id: id, peripheralUUID: nil, family: "whoop4", firmware: s.firmware, model: "WHOOP 4.0",
                                        seenAt: clock.now)
        } catch {
            note("strap registry: \(error)")
        }
    }

    private var lastRegistered: String?

    /// A line from elsewhere in the composition for the same diagnostics log (keep-up pulls, wake chain, double tap).
    func noteExternal(_ line: String) { note(line) }

    private func note(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        log.append(f.string(from: clock.now) + " " + line)   // 0.6.0.11: timed, for the debug channel
        if log.count > Self.logCap { log.removeFirst(log.count - Self.logCap) }
    }
}
