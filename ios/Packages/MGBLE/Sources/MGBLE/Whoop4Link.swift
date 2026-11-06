// Ported from ryanbr/noop @ 2a1de76 (main, 2026-10-25): Strand/BLE/BLEManager.swift (connect + bond write L6690-6712, WHOOP 4
// handshake L7010-7080, refreshBattery L2490, sendSetClockBothForms L7120), Strand/BLE/Whoop4BondAck.swift,
// docs/PROTOCOL_WHOOP4.md "Bond handshake & connect lifecycle (WHOOP 4)", docs/PROTOCOL_TRANSPORT.md "WHOOP 4".
// PolyForm Noncommercial 1.0.0. Required Notice: Copyright 2026 NoopApp.
import Combine
import Foundation
import MGDomain
import WhoopProtocol

/// What the link knows about the connected WHOOP 4.0, for Settings (Pair WHOOP 4.0 status line).
public struct Whoop4Status: Equatable, Sendable {
    /// Harvard firmware "a.b.c.d" from REPORT_VERSION_INFO (7), e.g. 41.17.6.0.
    public var firmware: String?
    /// 9-character strap serial from GET_HELLO_HARVARD (35).
    public var serial: String?
    /// From GET_BATTERY_LEVEL (26) and BATTERY_LEVEL events (the standard 2A19 is a constant-100 stub on a 4.0).
    public var batteryPercent: Double?
    public var charging: Bool?
    /// WRIST_ON (9) / WRIST_OFF (10) events; nil until one is seen.
    public var worn: Bool?
    public var liveBPM: Int?
    public var liveAt: Date?
    public var bonded = false
    /// Strap clock minus phone clock at the last GET_CLOCK; nil when unread.
    public var clockOffsetSeconds: Double?
    public var lastHistory: HistorySummary?
    /// HR broadcast (command 14) as the link knows it: nil until the switch was ever sent; "on" / "off" once event 24 / 25 confirmed it.
    public var hrBroadcast: String?

    public init() {}

    /// "connected · firmware 41.17.6.0 · serial WBB… · battery 83 % · worn · HR 62" for the Settings line.
    public func line(connected: Bool, now: Date = Date()) -> String {
        var parts = [connected ? "connected" : "not connected"]
        parts.append("firmware " + (firmware ?? "?"))
        parts.append("serial " + (serial ?? "?"))
        if let b = batteryPercent { parts.append(String(format: "battery %.0f %%%@", b, charging == true ? " (charging)" : "")) }
        else { parts.append("battery ?") }
        parts.append(worn.map { $0 ? "worn" : "not worn" } ?? "worn ?")
        if let bpm = liveBPM, let at = liveAt, now.timeIntervalSince(at) < 10 { parts.append("HR \(bpm)") } else { parts.append("HR -") }
        return parts.joined(separator: " · ")
    }
}

/// The WHOOP 4.0 link (WHOOP4-LINK, 2026-11-05; D-WHOOP4-LINK-1). A separate path next to `StrapLink`, not a mode of it: the 4.0
/// has a different service (`61080001`), different framing (CRC8), different offsets, a bonding write instead of a hello, a
/// different history token, and none of the 5/MG's unlock, raw-optical or ECG machinery. Sharing the transport, the command
/// channel, the history sink and the raw-frame archive is what the two have in common.
///
/// Hard rule: this link scans with the 4.0 service UUID only, and refuses any advertisement that lists the 5/MG service
/// (`fd4b0001`). It connects to nothing the radio did not find under that filter, and it never auto-sends a command outside
/// `Whoop4Command.sentAutomatically` (none of the dangerous ones except 23, the history ack, after the archive write).
///
/// Handshake (noop BLEManager, run ONCE per connection; re-running it mid-offload stopped type-47 streaming on 41.17.6.0):
/// discover → bonding write GET_BATTERY_LEVEL (26) WITH RESPONSE on 61080002 → subscribe 0003/0004/0005 + 2A37 + 2A19 →
/// REPORT_VERSION_INFO (7) → GET_HELLO_HARVARD (35, the serial) → clock (GET_CLOCK; SET_CLOCK in both firmware forms when the
/// clock is off and the standing consent exists) → SEND_R10R11_REALTIME [00] (stops the type-43 flood) → GET_DATA_RANGE (34) →
/// ready → history after `postClockHistoryDelay`. Live HR comes from 2A37 (and type 40 if it ever arrives); nothing turns type-40
/// realtime on by itself.
@MainActor
public final class Whoop4Link: ObservableObject, StrapTransportDelegate {
    @Published public private(set) var state: StrapLinkState = .idle
    @Published public internal(set) var status = Whoop4Status()
    /// The raw stream (63): wanted / on, frame counts, why it is not streaming.
    @Published public internal(set) var rawStream = Whoop4RawStatus()

    public var liveBeats: AsyncStream<LiveBeat> { beatHub.stream() }
    public var strapEvents: AsyncStream<StrapEvent> { eventHub.stream() }
    /// The strap this link is on, once a peripheral is chosen (nil before). The app remembers it as the paired 4.0.
    public private(set) var peripheralID: UUID?
    /// Called once per connection with the peripheral id after the bonding write was acknowledged (the app pins it).
    public var onBonded: (@MainActor (UUID) -> Void)?
    /// Called when the pinned peripheral turned out not to hold the 4.0 service: the app clears its saved pin.
    public var onPinRejected: (@MainActor (UUID) -> Void)?
    /// The strap id of the current connection (`s_…`, derived from the install salt and the peripheral id); nil before a connect.
    public var currentStrapID: StrapID? { strapId }

    let transport: StrapTransport
    let config: StrapLinkConfig
    let clock: any MGDomain.Clock
    let historySink: any HistorySink
    let liveSink: any LiveSink
    let writeLog: (any StrapWriteLog)?
    let logLine: @MainActor (String) -> Void
    let channel: CommandChannel
    let beatHub = Broadcaster<LiveBeat>()
    let eventHub = Broadcaster<StrapEvent>()
    let ackedLedger = AckedLedger()

    var started = false
    var intentionalDisconnect = false
    var bondRefused = false
    var strapId: StrapID?
    /// The pinned peripheral: `config.pinnedPeripheralID` until it turns out not to be a 4.0, then nil (scan instead).
    var pin: UUID?
    private var pinJustRejected = false
    var connectionGeneration = 0
    var linkLostHandled = true
    var connectTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var maintenanceTask: Task<Void, Never>?
    var autoHistoryTask: Task<Void, Never>?
    var reconnectAttempts = 0
    var handshakeDone = false
    var historyRun: Whoop4HistoryRun?
    var persistStalledReason: String?
    /// Unproductive SEND_HISTORICAL_DATA runs since the last COMPLETE. NOT reset by a reconnect (2026-11-06); refilled
    /// `historyBudgetRefill` seconds after the last unproductive run (`historyBudgetUsedAt`).
    var historyRunsThisConnection = 0
    var historyBudgetUsedAt: Date?
    /// The auto download after the handshake has been scheduled and has not finished: nothing else is sent to the strap meanwhile.
    var historyPending = false
    /// Offload frames (47 / 49 / 50) that arrived while no run existed; replayed into the next run.
    var pendingOffload: [[UInt8]] = []
    static let pendingOffloadCap = 4000
    /// The strap's newest stored record (GET_DATA_RANGE) as last read on this connection, and when.
    var strapNewestTs: Int?
    var strapRangeAt: Date?
    /// The newest record time this link has stored from history (survives reconnects, not a relaunch).
    var storedFrontierTs: Int64?
    /// Replies that came back to commands the link sends without waiting (63 [00], 22, 23, 20, SET_CLOCK), by opcode.
    var ignoredReplyCounts: [UInt8: Int] = [:]
    static let fireAndForgetOpcodes: Set<UInt8> = [Whoop4Command.sendR10R11Realtime, Whoop4Command.sendHistoricalData,
                                                   Whoop4Command.historicalDataResult, Whoop4Command.abortHistoricalTransmits,
                                                   Whoop4Command.setClock, Whoop4Command.getBatteryLevel]
    var deferredWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var lastDataAt: Date?
    var lastBatteryPollAt: Date?
    var droppedOffloadFrames = 0
    var lastType40BeatAt: Date?
    /// The HR broadcast switch (WHOOP4-WIRE 4); the app sets it before the link starts and on every change.
    public var hrBroadcastWanted: Bool?
    /// The strap time (unix s) of the wake alarm this link armed and has not disabled (WHOOP4-WIRE 5); survives reconnects.
    var armedAlarmEpoch: UInt32?
    /// The raw stream (63), WHOOP4-WIRE 6: wished by the app, acknowledged on, an OFF owed, one writer at a time.
    var rawStreamWanted = false
    var rawStreamOn = false
    var rawStreamNeedsOff = false
    var rawStreamApplying = false
    var rawStreamApplyAgain = false
    var rawStreamUnexpectedStopAt: Date?
    let rawMotionHub = Broadcaster<MotionSecond>()
    let rawOpticalHub = Broadcaster<Whoop4OpticalFrame>()
    var live = LiveBuffer()
    /// One reassembler per characteristic, so fragments of two channels never interleave into one frame.
    var reassemblers: [String: Reassembler] = [:]

    static let bondRefusedHint = "The WHOOP 4.0 refused to pair. Close the WHOOP app if it holds this strap, forget the strap in "
        + "iOS Settings › Bluetooth, tap the strap until the blue light shows, then pair again."

    public init(transport: StrapTransport, config: StrapLinkConfig, clock: any MGDomain.Clock, historySink: any HistorySink,
                liveSink: any LiveSink, writeLog: (any StrapWriteLog)? = nil, log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.transport = transport
        self.config = config
        self.pin = config.pinnedPeripheralID
        self.clock = clock
        self.historySink = historySink
        self.liveSink = liveSink
        self.writeLog = writeLog
        self.logLine = log
        self.channel = CommandChannel(
            transport: transport, framer: CommandFramer(policy: config.policy),
            responseTimeout: config.timing.responseTimeout, writeCharacteristic: Whoop4GATT.write,
            frameBuilder: { command, seq in Whoop4Frame.command(command.opcode, seq: seq, payload: command.payload) })
    }

    // MARK: - Lifecycle

    public func start() {
        transport.delegate = self
        started = true
        intentionalDisconnect = false
        bondRefused = false
        // Restored peripherals count only when the system lists them as holding the 4.0 service: a restored 5/MG
        // (`fd4b…`) is never adopted (D-WHOOP4-LINK-1).
        if connectTask == nil, !handshakeDone {
            let holders = Set(transport.connectedPeripherals(withService: Whoop4GATT.service))
            if let restored = transport.restoredPeripherals.first(where: { holders.contains($0) && accepts($0) }) {
                connect(to: restored)
                return
            }
        }
        evaluateRadio()
    }

    public func disconnect() {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        transport.stopScan()
        if let id = peripheralID { transport.cancelConnection(id) }
        linkLost(reason: "disconnected by you", reconnect: false)
        setState(.idle)
    }

    /// The app came back to the foreground, or any other wake: look at the radio again when the link is down.
    public func wake(_ reason: String) {
        guard started, !intentionalDisconnect, !bondRefused, !handshakeDone, connectTask == nil else { return }
        logLine("whoop4: wake (\(reason)) — link down, reading the radio")
        if reconnectTask != nil, let id = peripheralID, transport.radioState == .poweredOn {
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempts = 0
            connect(to: id)
            return
        }
        if state != .scanning { evaluateRadio() }
    }

    /// The Command test page: any number with any payload, ONE frame, WITH RESPONSE (rule 5: nothing is refused; the page labels
    /// the dangerous ones, see `Whoop4Command.safety`).
    @discardableResult
    public func sendTestCommand(opcode: UInt8, payload: [UInt8]) async throws -> CommandResponse? {
        guard handshakeDone else { throw StrapLinkError.notReady("the WHOOP 4.0 is not connected") }
        // Nothing is sent to the strap while a download runs or is about to start (noop: never poke the strap mid-offload), except
        // the commands that stop something: ABORT (20), DISABLE_ALARM (69), STOP_HAPTICS (122).
        if ![Whoop4Command.abortHistoricalTransmits, Whoop4Command.disableAlarm, Whoop4Command.stopHaptics].contains(opcode) {
            try await deferWhileDownloading("command \(opcode)")
        }
        return try await channel.send(.test(opcode: opcode, payload: payload), awaitResponse: true)
    }

    // MARK: - Nothing else mid-download

    /// True while a history run exists or the auto download after the handshake is waiting to start.
    var downloadBusy: Bool { historyRun != nil || historyPending }

    /// Holds a user action (LED read, alarm, haptics, test command, HR broadcast change) until the download ends, then lets it
    /// go; logs "deferred until the download ends". The action is queued, never dropped: it is sent when the download ends, when the
    /// wait reaches `historyDeferMax`, or throws only if the link died meanwhile.
    func deferWhileDownloading(_ what: String) async throws {
        guard downloadBusy else { return }
        let generation = connectionGeneration
        logLine("whoop4: \(what) deferred until the download ends")
        let id = UUID()
        let cap = config.timing.historyDeferMax
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            deferredWaiters[id] = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, cap) * 1_000_000_000))
                if let c = self?.deferredWaiters.removeValue(forKey: id) {
                    self?.logLine("whoop4: \(what) waited \(Int(cap)) s for the download — sent anyway")
                    c.resume()
                }
            }
        }
        guard connectionAlive(generation), handshakeDone else {
            throw StrapLinkError.notReady("the WHOOP 4.0 link dropped while \(what) waited for the download to end")
        }
    }

    func releaseDeferred() {
        guard !deferredWaiters.isEmpty else { return }
        let waiting = deferredWaiters
        deferredWaiters.removeAll()
        for (_, c) in waiting { c.resume() }
    }

    /// The connection this generation number belongs to is still the live one.
    func connectionAlive(_ generation: Int) -> Bool {
        generation == connectionGeneration && !linkLostHandled
    }

    func setState(_ new: StrapLinkState) {
        if state != new { state = new }
    }

    func accepts(_ id: UUID) -> Bool {
        pin == nil || pin == id
    }

    /// `config.connectGate` (the app passes "the selected device is a WHOOP 4.0").
    func connectAllowed() -> Bool {
        if config.connectGate?() ?? true { return true }
        logLine("whoop4: not connecting — WHOOP 4.0 is not the selected device")
        if state == .scanning || state == .connecting { setState(.idle) }
        return false
    }

    func evaluateRadio() {
        switch transport.radioState {
        case .poweredOn: beginConnecting()
        case .poweredOff, .unsupported: setState(.bluetoothOff)
        case .unauthorized: setState(.unauthorized)
        case .unknown, .resetting: break
        }
    }

    /// A 4.0 already connected to the phone → the pinned strap (standing connect) → scan for the 4.0 service UUID only.
    func beginConnecting() {
        guard started, !intentionalDisconnect, !bondRefused, connectTask == nil, !handshakeDone, connectAllowed() else { return }
        if let id = transport.connectedPeripherals(withService: Whoop4GATT.service).first(where: accepts) {
            connect(to: id)
            return
        }
        if let pin, transport.canReach(peripheral: pin) {
            connect(to: pin)
            return
        }
        setState(.scanning)
        transport.scan(.whoop4Strap)
    }

    func connect(to id: UUID) {
        guard connectAllowed() else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration += 1
        let generation = connectionGeneration
        linkLostHandled = false
        peripheralID = id
        strapId = StrapIdentity.strapID(installSalt: config.installSalt, peripheralID: id)
        status.bonded = false
        setState(.connecting)
        connectTask = Task { @MainActor [weak self] in
            await self?.runConnection(id, generation: generation)
            if let self, self.connectionGeneration == generation {
                self.connectTask = nil
                if self.pinJustRejected { self.pinJustRejected = false; self.beginConnecting() }   // scan for a real 4.0
            }
        }
    }

    private func runConnection(_ id: UUID, generation: Int) async {
        do {
            try await transport.connect(id)
            guard connectionAlive(generation) else { return }
            try await runHandshake(id, generation: generation)
            if connectionAlive(generation) { reconnectAttempts = 0 }
        } catch {
            guard generation == connectionGeneration else { return }
            if (error as? TransportError) == .insufficientAuthentication {
                bondRefused = true
                transport.cancelConnection(id)
                linkLost(reason: Self.bondRefusedHint, reconnect: false)
                return
            }
            if (error as? TransportError) == .cancelled, intentionalDisconnect { return }
            transport.cancelConnection(id)
            linkLost(reason: describeError(error), reconnect: !(error is StrapLinkError))
        }
    }

    private func runHandshake(_ id: UUID, generation: Int) async throws {
        // Discovery. A strap without the 4.0 command characteristic is not a WHOOP 4.0: leave it alone, write nothing.
        let found = try await transport.discover(Whoop4GATT.discoveryPlan)
        guard found.contains(Whoop4GATT.write) else {
            if pin == id {
                pin = nil
                pinJustRejected = true
                logLine("whoop4: the pinned device has no 4.0 service - pin dropped, scanning")
                onPinRejected?(id)
            }
            throw StrapLinkError.notReady("no 61080002 command characteristic: not a WHOOP 4.0")
        }
        // The bonding write: GET_BATTERY_LEVEL (26) [00] WITH RESPONSE. Its write-ack is the bond ("just works": no iOS
        // dialog); the custom channels send nothing until it is done (noop BLEManager L6700-6712).
        setState(.bonding)
        channel.resetSequence()
        try await channel.send(.test(opcode: Whoop4Command.getBatteryLevel, payload: [0x00]), awaitResponse: false)
        guard connectionAlive(generation) else { return }
        status.bonded = true
        onBonded?(id)
        // Subscribe: command responses, events, data, then the standard heart rate (2A37) and battery (2A19, a stub).
        for c in Whoop4GATT.notify + [StrapGATT.heartRateMeasurement, StrapGATT.batteryLevel] where found.contains(c) {
            do { try await transport.setNotify(true, for: c) } catch {
                if c == Whoop4GATT.notifyCommand { throw error }   // without responses nothing below can be read
                logLine("whoop4: subscribe \(c) failed — \(describeError(error))")
            }
        }
        setState(.handshaking)
        // Version, identity (serial), battery.
        if let r = try? await channel.send(.test(opcode: Whoop4Command.reportVersionInfo, payload: [0x00]), awaitResponse: true),
           r.result == .success, let fw = Whoop4Frame.firmware(r.frame) {
            status.firmware = fw
        }
        if let r = try? await channel.send(.test(opcode: Whoop4Command.getHelloHarvard, payload: [0x00]), awaitResponse: true),
           r.result == .success {
            status.serial = Whoop4Frame.serial(r.frame)   // the key material beside it is never read or logged
        }
        if let r = try? await channel.send(.test(opcode: Whoop4Command.getBatteryLevel, payload: [0x00]), awaitResponse: true),
           r.result == .success, let pct = Whoop4Frame.batteryPercent(r.body) {
            noteBattery(pct, charging: nil)
        }
        guard connectionAlive(generation) else { return }
        await runClockSync()
        guard connectionAlive(generation) else { return }
        // Stop the ~2/s type-43 raw flood if something left it on (noop: every connect), then read the stored range.
        _ = try? await channel.send(.test(opcode: Whoop4Command.sendR10R11Realtime, payload: [0x00]), awaitResponse: false)
        if let newest = await readDataRange() {
            logLine("whoop4: data range ok, strap newest \(newest)")
        } else {
            logLine("whoop4: data range not read (no usable answer)")
        }
        // A link that dropped during any step above ended in `linkLost`: never mark this connection ready (the 2026-11-06 stuck
        // "ready" on a dead link).
        guard connectionAlive(generation) else { return }
        handshakeDone = true
        lastDataAt = clock.now
        // noop order (BLEManager L6751-6795): handshake once, 63 [00], range, THEN history; the raw stream is re-applied only after
        // the download ends. With the auto download off nothing is pending and the raw wish is applied right away.
        historyPending = config.autoDownloadHistoryOnConnect
        if hrBroadcastWanted == true { await applyHRBroadcast() }   // WHOOP4-WIRE 4: only when the switch is on
        guard connectionAlive(generation) else { return }
        setState(.ready)
        startMaintenance()
        if config.autoDownloadHistoryOnConnect {
            scheduleAutoHistory()
        } else if rawStreamWanted {
            await applyRawStream()                                  // WHOOP4-WIRE 6: after the 63 [00] above, only when asked
        }
    }

    /// GET_DATA_RANGE (34) `[00]`: the strap's newest stored record, kept in `strapNewestTs`. nil when unanswered or undecodable.
    /// The strap answers PENDING first and the payload after; `CommandChannel` keeps the request open for the final answer.
    @discardableResult
    func readDataRange() async -> Int? {
        guard let r = try? await channel.send(.test(opcode: Whoop4Command.getDataRange, payload: [0x00]), awaitResponse: true),
              r.result == .success else { return nil }
        let now = clock.now
        guard let newest = Whoop4Frame.dataRangeNewestUnix(r.frame, wallNow: Int(now.timeIntervalSince1970),
                                                           futureSkew: Int(config.timing.historyFutureSkew)) else { return nil }
        strapNewestTs = newest
        strapRangeAt = now
        return newest
    }

    // MARK: - Clock

    /// GET_CLOCK ([00], then [] for firmware that answers only that), compare with the phone; with the standing consent and an
    /// offset past the tolerance, SET_CLOCK in both firmware forms, then read back. Without consent the clock is only read.
    /// Every set is written to the strap write log (prior, payload, readback, result).
    func runClockSync() async {
        let prior = await readClock()
        let offset = prior.map { Double($0) - clock.now.timeIntervalSince1970 }
        status.clockOffsetSeconds = offset
        guard let consentAt = config.clockConsentAt else {
            logLine("whoop4: clock read only — no standing consent recorded at pairing")
            return
        }
        if let offset, abs(offset) < config.timing.clockTolerance {
            logLine(String(format: "whoop4: clock ok, not set (strap − phone %+.1f s)", offset))
            return
        }
        let now = UInt32(truncatingIfNeeded: Int64(clock.now.timeIntervalSince1970))
        var verdicts: [String] = []
        for (label, payload) in [("8-byte", Whoop4Frame.setClockPayload(now: now)),
                                 ("9-byte", Whoop4Frame.setClockPayloadLegacy(now: now))] {
            do {
                try await channel.send(.test(opcode: Whoop4Command.setClock, payload: payload), awaitResponse: false)
                verdicts.append("\(label) written")
            } catch {
                verdicts.append("\(label) failed: \(describeError(error))")
            }
        }
        let after = await readClock()
        let off = after.map { Double($0) - clock.now.timeIntervalSince1970 }
        status.clockOffsetSeconds = off ?? status.clockOffsetSeconds
        let ok = off.map { abs($0) <= config.timing.clockTolerance } ?? false
        let consent = ISO8601DateFormatter().string(from: consentAt)
        let result = (ok ? "ok" : "readback off or missing") + "; " + verdicts.joined(separator: ", ")
            + "; standing consent \(consent)"
        for (n, payload) in [Whoop4Frame.setClockPayload(now: now), Whoop4Frame.setClockPayloadLegacy(now: now)].enumerated() {
            let entry = StrapWriteEntry(command: Int(Whoop4Command.setClock), name: "SET_CLOCK (WHOOP 4.0, form \(n + 1))",
                                        payloadHex: payload.hexLower, priorValue: prior.map { "unix \($0)" },
                                        readback: after.map { "unix \($0)" }, confirmedAt: clock.now, result: result,
                                        standingConsent: true, restored: nil)
            do { try await writeLog?.log(entry) } catch { logLine("whoop4: write log failed for SET_CLOCK — \(describeError(error))") }
        }
        logLine("whoop4: clock set — \(result)")
    }

    /// Strap unix seconds from GET_CLOCK. Newer firmware answers the empty form and ignores `[00]`; 41.17.x answers `[00]` and
    /// ignores the empty form (noop BLEManager L7071-7080, #120), so both are tried, `[00]` first.
    func readClock() async -> UInt32? {
        for payload in [[UInt8(0x00)], []] as [[UInt8]] {
            if let r = try? await channel.send(.test(opcode: Whoop4Command.getClock, payload: payload), awaitResponse: true),
               r.result == .success, let s = Whoop4Frame.clockSeconds(r.body) {
                return s
            }
        }
        return nil
    }

    // MARK: - History

    /// Downloads banked history: SEND_HISTORICAL_DATA (22), every chunk stored (raw frames included) and only then acked (23).
    public func downloadHistory() async throws -> HistorySummary {
        guard handshakeDone, let sid = strapId else { throw StrapLinkError.notReady("the WHOOP 4.0 is not connected") }
        if let reason = persistStalledReason { throw StrapLinkError.persistStalled(reason) }
        if historyRun != nil { throw StrapLinkError.historyInProgress }
        refreshHistoryBudget()
        let budget = config.timing.maxHistoryRunsPerConnection - historyRunsThisConnection
        if budget <= 0 {
            logLine("whoop4: history run budget spent (\(historyRunsThisConnection) unproductive runs since the last complete); "
                    + "it refills \(Int(config.timing.historyBudgetRefill)) s after the last one")
        }
        let run = Whoop4HistoryRun(channel: channel, sink: historySink, clock: clock, strapId: sid, timing: config.timing,
                                   runBudget: budget, ledger: ackedLedger, log: logLine)
        let generation = connectionGeneration
        run.isCurrent = { [weak self] in self?.connectionAlive(generation) == true && self?.handshakeDone == true }
        run.onProgress = { [weak self] progress in self?.setState(.downloadingHistory(progress)) }
        run.frontierTs = storedFrontierTs
        run.rangeNewest = { [weak self] allowSend in await self?.rangeForContinuation(allowSend: allowSend) }
        historyRun = run
        historyPending = false
        // Frames the strap sent before this run existed (a resumed offload): the stream is already open. A stale COMPLETE is not
        // replayed (it would end the run before the strap answered 22).
        let early = pendingOffload
        pendingOffload.removeAll()
        for frame in early where !Self.isCompleteMarker(frame) { run.inbox.push(frame) }
        logLine("whoop4: history download started" + (early.isEmpty ? "" : " (\(early.count) offload frame(s) were already streaming)"))
        let summary = await run.execute()
        if let l = summary.lastTs { storedFrontierTs = max(storedFrontierTs ?? l, l) }
        if summary.recordsInserted == 0, run.runsUsed > 0 {
            historyRunsThisConnection += run.runsUsed
            historyBudgetUsedAt = clock.now
        }
        if summary.endReason == .complete { historyRunsThisConnection = 0 }
        guard historyRun === run else { return summary }
        historyRun = nil
        status.lastHistory = summary
        if case .persistStalled(let reason) = summary.endReason { persistStalledReason = reason }
        if handshakeDone, case .downloadingHistory = state { setState(.ready) }
        if !ignoredReplyCounts.isEmpty {
            let counts = ignoredReplyCounts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            logLine("whoop4: replies to commands sent without waiting, so far on this link: \(counts)")
        }
        releaseDeferred()   // alarms, LED reads and test commands that waited for the download go out now
        if rawStreamWanted, !rawStreamOn { Task { @MainActor [weak self] in await self?.applyRawStream() } }   // WHOOP4-WIRE 6
        return summary
    }

    /// Refill the unproductive-run budget when the last unproductive run is old enough.
    func refreshHistoryBudget() {
        guard historyRunsThisConnection > 0, let at = historyBudgetUsedAt,
              clock.now.timeIntervalSince(at) > config.timing.historyBudgetRefill else { return }
        historyRunsThisConnection = 0
    }

    /// The strap's newest stored record for the run's "more to fetch" decision: re-read (34) when asked and allowed, else the value
    /// read at the handshake.
    func rangeForContinuation(allowSend: Bool) async -> Int? {
        if allowSend, handshakeDone { return await readDataRange() ?? strapNewestTs }
        return strapNewestTs
    }

    static func isCompleteMarker(_ frame: [UInt8]) -> Bool {
        guard frame.count > 4, frame[4] == 49 else { return false }
        if case .complete = classifyHistoricalMeta(parseFrame(frame, family: .whoop4)) { return true }
        return false
    }

    /// Stop a download: ABORT_HISTORICAL_TRANSMITS (20) is a stop request, not a trim.
    public func abortHistory() { historyRun?.abort() }

    private func scheduleAutoHistory() {
        autoHistoryTask?.cancel()
        let delay = config.timing.postClockHistoryDelay
        let generation = connectionGeneration
        autoHistoryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.connectionAlive(generation), self.handshakeDone else { return }
            do {
                let s = try await self.downloadHistory()
                self.logLine("whoop4: history \(s.chunksAcked) chunk(s) acked, \(s.recordsInserted) records, ended \(s.endReason)")
            } catch {
                self.logLine("whoop4: history not started — \(describeError(error))")
            }
            await self.endHistoryPending(generation)
        }
    }

    /// The auto download is over (or never started): what waited for it goes out - deferred actions, then the raw stream.
    private func endHistoryPending(_ generation: Int) async {
        guard connectionAlive(generation) else { return }
        historyPending = false
        releaseDeferred()
        if rawStreamWanted, !rawStreamOn { await applyRawStream() }
    }

    // MARK: - Link loss, reconnect, maintenance

    func linkLost(reason: String, reconnect: Bool) {
        guard !linkLostHandled else { return }
        linkLostHandled = true
        handshakeDone = false
        channel.failAll()
        historyRun?.linkLost(reason)
        historyRun = nil
        historyPending = false
        pendingOffload.removeAll()
        strapNewestTs = nil
        strapRangeAt = nil
        releaseDeferred()            // waiting actions see the dead connection and throw
        maintenanceTask?.cancel()
        maintenanceTask = nil
        autoHistoryTask?.cancel()
        autoHistoryTask = nil
        reassemblers.removeAll()
        persistStalledReason = nil
        // `historyRunsThisConnection` is deliberately kept: the unproductive-run budget is not reset by a reconnect.
        rawStreamOn = false          // the next handshake sends 63 [00], then 63 [01] again when the app still wants it
        rawStreamNeedsOff = false
        publishRawStream()
        status.bonded = false
        flushLiveSoon()
        setState(.disconnected(reason: reason))
        logLine("whoop4: link lost — \(reason)")
        if reconnect, !intentionalDisconnect, !bondRefused { scheduleReconnect() }
    }

    func scheduleReconnect() {
        guard reconnectTask == nil, let id = peripheralID else { return }
        reconnectAttempts += 1
        let delay = min(config.timing.reconnectDelay * Double(reconnectAttempts), 60)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.started, !self.intentionalDisconnect, !self.bondRefused, !self.handshakeDone else { return }
            if self.connectTask != nil {
                self.scheduleReconnect()
                return
            }
            self.connect(to: id)
        }
    }

    private func startMaintenance() {
        maintenanceTask?.cancel()
        let interval = config.timing.liveFlushInterval
        lastBatteryPollAt = clock.now
        maintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.flushLive()
                await self.silenceWatchdog()
                await self.pollBatteryIfDue()
            }
        }
    }

    /// No-data watchdog (like the MG's `noDataReconnect` / keep-alive, StrapLink): nothing at all arrived for `silenceBounce`
    /// while ready and no download runs (a run has its own idle timeout) → probe with the battery read (26); an answer clears it
    /// (the phone may only have been suspended), no answer → drop and reconnect. Without this a link that died without a
    /// disconnect callback stayed "ready" for hours (2026-11-06 incident).
    func silenceWatchdog() async {
        guard handshakeDone, !downloadBusy, let id = peripheralID, let last = lastDataAt else { return }
        let silent = clock.now.timeIntervalSince(last)
        guard silent > config.timing.silenceBounce else { return }
        let generation = connectionGeneration
        lastBatteryPollAt = clock.now
        let answer = try? await channel.send(.test(opcode: Whoop4Command.getBatteryLevel, payload: [0x00]), awaitResponse: true)
        guard connectionAlive(generation), handshakeDone else { return }
        if answer != nil { return }
        transport.cancelConnection(id)
        linkLost(reason: "no data for \(Int(silent)) s and the strap did not answer a battery read", reconnect: true)
    }

    /// The battery by command (the 2A19 is a stub on a 4.0), every `keepAliveInterval` while idle; the answer also shows the link
    /// still works. Never while a history download runs.
    func pollBatteryIfDue() async {
        guard handshakeDone, historyRun == nil else { return }
        let now = clock.now
        guard now.timeIntervalSince(lastBatteryPollAt ?? .distantPast) >= max(config.timing.keepAliveInterval, 30) else { return }
        lastBatteryPollAt = now
        if let r = try? await channel.send(.test(opcode: Whoop4Command.getBatteryLevel, payload: [0x00]), awaitResponse: true),
           r.result == .success, let pct = Whoop4Frame.batteryPercent(r.body) {
            noteBattery(pct, charging: nil)
        }
    }

    // MARK: - StrapTransportDelegate

    public func transport(_ source: StrapTransport, didChangeRadio radio: RadioState) {
        guard started else { return }
        switch radio {
        case .poweredOn: beginConnecting()
        case .poweredOff, .unsupported:
            linkLost(reason: "Bluetooth is off", reconnect: false)
            setState(.bluetoothOff)
        case .unauthorized: setState(.unauthorized)
        case .unknown, .resetting: break
        }
    }

    /// Hard rule (D-WHOOP4-LINK-1): connect only to an advertisement that lists the 4.0 service, never to one that lists the
    /// 5/MG service, never by name. An empty list is accepted only because the radio-side filter already matched the 4.0 service
    /// (noop `whoopGattScanDecision`; CoreBluetooth sometimes omits the list). Nothing else is connected to.
    public func transport(_ source: StrapTransport, didDiscover peripheral: DiscoveredPeripheral) {
        guard state == .scanning, connectTask == nil else { return }
        guard connectAllowed() else {
            transport.stopScan()
            return
        }
        guard Self.shouldConnect(advertised: peripheral.advertisedServiceUUIDs), accepts(peripheral.id) else { return }
        transport.stopScan()
        connect(to: peripheral.id)
    }

    static func shouldConnect(advertised services: [String]) -> Bool {
        let s = services.map(StrapGATT.normalize)
        if s.contains(StrapGATT.service) { return false }
        return s.isEmpty || s.contains(Whoop4GATT.service)
    }

    public func transport(_ source: StrapTransport, didDisconnect peripheral: UUID, error: String?) {
        guard peripheral == peripheralID else { return }
        linkLost(reason: error ?? "strap disconnected", reconnect: true)
    }

    public func transport(_ source: StrapTransport, didRestore peripherals: [UUID]) {
        // Only a peripheral the system lists as holding the 4.0 service is adopted; a restored 5/MG is ignored.
        let holders = Set(transport.connectedPeripherals(withService: Whoop4GATT.service))
        guard started, connectTask == nil, !handshakeDone, let id = peripherals.first(where: { holders.contains($0) && accepts($0) }) else {
            logLine("whoop4: Bluetooth restore (\(peripherals.count) peripheral(s)) → nothing to do")
            return
        }
        logLine("whoop4: Bluetooth restore → connecting to the restored WHOOP 4.0")
        connect(to: id)
    }
}
