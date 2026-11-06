import Combine
import Foundation
import MGDomain
import WhoopProtocol

/// The WHOOP 5/MG link (ARCHITECTURE §4.4). Ported from noop's BLEManager, not copied (D3): the connect handshake
/// keeps noop's order, which works on real straps (§4.4.2), and leaves out everything §4.4.3 forbids — no alarm
/// family, no without-response writes, no broadcast re-apply, no data-range request.
///
/// Handshake (§4.4.2): discover → subscribe 2A37/2A19 and read 2A19 → CLIENT_HELLO with response (bond trigger) →
/// only then subscribe fd4b0003/4/5/7 → clock (D6) → realtime toggles if wanted → ready → history after 1.5 s.
@MainActor
public final class StrapLink: ObservableObject, StrapLinking, StrapTransportDelegate {
    @Published public private(set) var state: StrapLinkState = .idle
    @Published public internal(set) var info: StrapInfo?
    /// The summary of the last finished history download (added 2026-10-11: the app's R22 watch reads it).
    @Published public internal(set) var lastHistory: HistorySummary?
    /// Raw optical (108 live R20): the switch, whether ON was sent on this connection, frames, why it stopped.
    @Published public internal(set) var rawOptical = RawOpticalStatus()
    /// MG ECG (wave W8): switch, phase, packets, whether a stop is owed, the last outcome in words.
    @Published public internal(set) var ecg = EcgStatus()
    /// Raw motion R21 (wave W8): switch, session, whether 81 + 106 ON went out on this connection, seconds received.
    @Published public internal(set) var rawMotion = RawMotionStatus()
    /// HR broadcast (T77): "on" / "off" as the strap last reported through 121, or a short reason it could not be read.
    /// nil = not read on this link yet.
    @Published public internal(set) var hrBroadcastReading: String?

    /// A new stream per caller; every consumer gets every beat (~1 Hz).
    public var liveBeats: AsyncStream<LiveBeat> { beatHub.stream() }
    /// Fresh strap events (double-tap 14, wrist 9/10, charging 7/8, battery 3, RTC lost 13). History replays
    /// are not re-emitted here; they are stored with their chunk.
    public var strapEvents: AsyncStream<StrapEvent> { eventHub.stream() }
    /// Live 1-second gravity vectors from raw-IMU buffers whose own timestamp is fresh. Usually empty in B1: the raw
    /// IMU stream needs opcodes 81 + 106, which stay policy-gated (see `StrapLinking.liveMotion`).
    public var liveMotion: AsyncStream<StrapMotionSecond> { motionHub.stream() }

    let transport: StrapTransport
    let config: StrapLinkConfig
    let clock: any MGDomain.Clock
    let historySink: any HistorySink
    let liveSink: any LiveSink
    let writeLog: any StrapWriteLog
    let confirmer: any StrapWriteConfirmer
    let logLine: @MainActor (String) -> Void
    /// Persisted pre-write value of a flag: (command, flag name) → the value text as read ("2"), or nil. Lets `restoreUnlock`
    /// work after an app restart. The app wires it to MGStore: `{ cmd, key in try? await store.latestPriorValue(command:
    /// cmd, key: key) }`. nil → only this session's priors are known.
    let priorValueLookup: (@Sendable (UInt8, String) async -> String?)?
    /// Durable store for a strap settings snapshot (MGStore `storeFlagSnapshot`). `readFlagSnapshot()` returns only
    /// after it, and the R22 write runs only after the snapshot holding its prior value is stored. nil → nothing is
    /// stored and both refuse.
    let flagSnapshotSink: (@Sendable (StrapFlagSnapshot) async throws -> Void)?
    let channel: CommandChannel
    let beatHub = Broadcaster<LiveBeat>()
    let eventHub = Broadcaster<StrapEvent>()
    let motionHub = Broadcaster<StrapMotionSecond>()

    // Per-connection state.
    var started = false
    var intentionalDisconnect = false
    var bondRefused = false
    var peripheralID: UUID?
    var strapId: StrapID?
    var connectionGeneration = 0
    var linkLostHandled = true
    var connectTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var maintenanceTask: Task<Void, Never>?
    var autoHistoryTask: Task<Void, Never>?
    var reconnectAttempts = 0
    /// Reassembly + CRC + R20 decode run here, off the main actor (audit #6); `decodeState` is the main-actor side.
    let decodeStage = FrameDecodeStage()
    var decodeState = LiveDecodeState()
    var decodeApplyTask: Task<Void, Never>?
    var handshakeDone = false
    var clockSyncRunning = false
    var historyRun: HistoryRun?
    /// The read-without-deleting test while it runs (StrapLink+HistoryProbe.swift); the normal download waits for it.
    var historyProbe: HistoryProbe?
    var persistStalledReason: String?
    var historyRunsThisConnection = 0
    /// T10003: chunks stored on this app run, so a strap re-serving one is acked again without storing it again.
    let ackedLedger = AckedLedger()
    var wantRealtimeHR = false
    var wantMotion = false
    /// HR broadcast switch (T77): nil = never set, so nothing is sent; true is re-applied at every handshake; false after a
    /// set only reads the strap's value back.
    public var hrBroadcastWanted: Bool?
    /// r9q (D-TRENDS-1): called when a history chunk holds optical windows the strap flagged 50 Hz: (first strap unix second, count).
    public var onFiftyHz: (@MainActor (Int64, Int) -> Void)?
    /// The switch was changed while not connected: the next handshake writes it even when it is off.
    var hrBroadcastUnsent = false
    var lastDataAt: Date?
    /// Keep-alive (audit §5a): when the last read went out, whether it failed, and the read in flight.
    var lastKeepAliveAt: Date?
    var keepAliveFailed = false
    var keepAliveTask: Task<Void, Never>?
    var lastFd4bBeatAt: Date?
    var droppedOffloadFrames = 0
    var live = LiveBuffer()
    /// enable_r22_packets as read before this app session's R22 write, for `restoreUnlock` (the persisted copy is the
    /// write log, through `priorValueLookup`).
    var r22Prior: String?
    /// Raw optical (2026-10-11): the app switch, foreground state, and what was sent on this connection.
    var wantRawOptical = false
    var appForeground = true
    /// 108 [01 01] went out on this connection and no 108 [01 00] since.
    var rawOpticalLiveOn = false
    /// The link dropped while raw optical was on: whether the strap stopped is unknown (noop PROTOCOL_CONFIGURATION:
    /// "what remains active after a radio disconnect" is unresolved), so the next handshake sends 108 [01 00] unless
    /// the switch wants it on.
    var rawOpticalNeedsOff = false
    /// Set by the offload watchdog; raw optical stays off until the switch is turned on again.
    var rawOpticalTrip: String?
    var rawOpticalApplying = false
    /// T9996 (r9d): when 108 [01 01] / 81 + 106 ON last went out, when the strap was last asked again after a stall, and
    /// the end of the last history download (the strap may pause raw streams during one). Used by the stall check only.
    var rawOpticalOnSentAt: Date?
    var rawOpticalRearmAt: Date?
    var rawMotionOnSentAt: Date?
    var rawMotionRearmAt: Date?
    var streamsQuietSince: Date?
    /// The moment a "soft" stopped reason was set (it clears itself once data arrives after it).
    var rawOpticalReasonAt: Date?
    var rawMotionReasonAt: Date?
    var rawOpticalApplyAgain = false
    /// T9992: "keep raw on the strap if the app is closed" - the app switch, and what was sent on this connection.
    /// 107 ENABLE_OPTICAL_DATA [01 01] asks the strap to bank R20 into its history (OpenStrap commands.dart `cmdEnableOptical`:
    /// on gen5 it is the save-to-history toggle, not the live stream). Sent only while the switch AND raw optical are wanted.
    var wantRawBanking = false
    var rawBankingOn = false
    /// The link dropped while 107 was on: whether the strap kept banking is not established, so the next handshake sends
    /// 107 [01 00] unless the switch wants it on.
    var rawBankingNeedsOff = false
    /// MG ECG reading (2026-10-11 19:50 PT, wave W8; StrapLink+Ecg.swift). The app switch (off by default); the reading in
    /// progress; whether a stop is owed (an ON write went out and the full stop has not) — kept across link loss.
    var ecgSwitchOn = false
    var ecgReading: EcgReadingRun?
    var ecgNeedsStop = false
    var ecgStopping = false
    var ecgUnexpectedStopAt: Date?
    let ecgHub = Broadcaster<EcgLivePacket>()
    /// Raw motion, R21 100 Hz IMU (2026-10-11 19:50 PT, wave W8; StrapLink+RawMotion.swift): the app switch (off by
    /// default), foreground state, a bounded session, what was sent on this connection, and a stop owed after link loss.
    var rawMotionSwitchOn = false
    var rawMotionForeground = true
    var rawMotionSessionUntil: Date?
    var rawMotionLiveOn = false
    var rawMotionNeedsOff = false
    var rawMotionApplying = false
    var rawMotionApplyAgain = false
    var rawMotionSessionTask: Task<Void, Never>?
    var rawMotionDeferTask: Task<Void, Never>?   // r8b T10006: waits (bounded) for a history offload to end before the 100 Hz start
    var rawMotionUnexpectedStopAt: Date?
    let rawMotionHub = Broadcaster<MotionSecond>()
    /// A 117/118/128 walk is in flight (the strap's enumeration cursor is shared state: one walk at a time).
    var flagReadRunning = false
    /// The newest strap settings snapshot this link stored.
    public internal(set) var lastFlagSnapshot: StrapFlagSnapshot?

    static let bondRefusedHint = "The strap refused to pair. Close the WHOOP app, forget the strap in iOS Settings › "
        + "Bluetooth, put the strap in pairing mode, then connect again."

    public init(transport: StrapTransport, config: StrapLinkConfig, clock: any MGDomain.Clock,
                historySink: any HistorySink, liveSink: any LiveSink, writeLog: any StrapWriteLog,
                confirmer: any StrapWriteConfirmer, log: @escaping @MainActor (String) -> Void = { _ in },
                priorValueLookup: (@Sendable (UInt8, String) async -> String?)? = nil,
                flagSnapshotSink: (@Sendable (StrapFlagSnapshot) async throws -> Void)? = nil) {
        self.transport = transport
        self.config = config
        self.clock = clock
        self.historySink = historySink
        self.liveSink = liveSink
        self.writeLog = writeLog
        self.confirmer = confirmer
        self.logLine = log
        self.priorValueLookup = priorValueLookup
        self.flagSnapshotSink = flagSnapshotSink
        self.channel = CommandChannel(transport: transport, framer: CommandFramer(policy: config.policy),
                                      responseTimeout: config.timing.responseTimeout)
        startDecodeApply()
    }

    // MARK: - Lifecycle

    public func start() {
        transport.delegate = self
        started = true
        intentionalDisconnect = false
        bondRefused = false
        if connectTask == nil, !handshakeDone,
           let restored = transport.restoredPeripherals.first(where: accepts) {
            connect(to: restored, restored: true)
            return
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

    /// T141: look at the radio again (the app calls this when it returns to the foreground). Same as `wake("foreground")`
    /// (StrapLink+Wake.swift, T9994): every wake reconnects when the strap is wanted and the link is down.
    public func reevaluate() {
        wake("foreground")
    }

    /// The formerly policy-gated commands. CHANGED 2026-10-13 (T87, rule 5 removed): no policy check; WITH RESPONSE.
    @discardableResult
    public func send(_ command: PolicyGatedCommand) async throws -> CommandResponse? {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        return try await channel.send(.gated(command), awaitResponse: true)
    }

    /// The Command test page (T87): any command number with any payload, ONE frame, written WITH RESPONSE through the
    /// same channel as every other command. Throws only when the strap is not connected or the write fails.
    @discardableResult
    public func sendTestCommand(opcode: UInt8, payload: [UInt8]) async throws -> CommandResponse? {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        return try await channel.send(.test(opcode: opcode, payload: payload), awaitResponse: true)
    }

    /// Wanted realtime streams. Applied now when connected, and again at every handshake (step 7), so smart wake
    /// can ask at bedtime even if the strap is momentarily out of range (D8).
    public func setRealtime(hr: Bool, motion: Bool) async throws {
        wantRealtimeHR = hr
        wantMotion = motion
        guard handshakeDone else { return }
        try await sendRealtimeToggles()
    }

    func setState(_ new: StrapLinkState) {
        if state != new { state = new }
    }

    func accepts(_ id: UUID) -> Bool {
        config.pinnedPeripheralID == nil || config.pinnedPeripheralID == id
    }

    func evaluateRadio() {
        switch transport.radioState {
        case .poweredOn: beginConnecting()
        case .poweredOff, .unsupported: setState(.bluetoothOff)
        case .unauthorized: setState(.unauthorized)
        case .unknown, .resetting: break   // the delegate reports the settled state
        }
    }

    /// Step 1 (noop BLEManager L1691-1764): a strap already connected to the phone → the pinned strap (standing
    /// connect) → scan for the service UUID.
    func beginConnecting() {
        guard started, !intentionalDisconnect, !bondRefused, connectTask == nil, !handshakeDone else { return }
        // WHOOP4-LINK: the selected device is a WHOOP 4.0 — this link neither scans nor connects (hard rule, D-WHOOP4-LINK-1).
        guard connectAllowed("scan") else { return }
        let connected = transport.connectedPeripherals(withService: StrapGATT.service).filter(accepts)
        if let id = connected.first {
            connect(to: id, restored: false)
            return
        }
        if let pin = config.pinnedPeripheralID, transport.canReach(peripheral: pin) {
            connect(to: pin, restored: false)
            return
        }
        setState(.scanning)
        transport.scan(.strap)
    }

    /// `config.connectGate` (WHOOP4-LINK): false while the selected device is not a 5/MG. Logged once per refusal.
    func connectAllowed(_ what: String) -> Bool {
        if config.connectGate?() ?? true { return true }
        logLine("strap: not \(what == "scan" ? "scanning" : "connecting") — the selected device is not a WHOOP 5/MG")
        if state == .scanning || state == .connecting { setState(.idle) }
        return false
    }

    func connect(to id: UUID, restored: Bool) {
        guard connectAllowed("connect") else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration += 1
        let generation = connectionGeneration
        linkLostHandled = false
        let sid = StrapIdentity.strapID(installSalt: config.installSalt, peripheralID: id)
        if let old = strapId, old != sid, let leftover = live.take(strapId: old) {
            let sink = liveSink
            Task { try? await sink.append(leftover) }
        }
        peripheralID = id
        strapId = sid
        if info?.strapId == sid {
            info?.bonded = false
        } else {
            info = StrapInfo(strapId: sid, firmware: nil, batteryPercent: nil, bonded: false,
                             clockOffsetSeconds: nil, model: nil)
        }
        setState(.connecting)
        connectTask = Task { @MainActor [weak self] in
            await self?.runConnection(id, restored: restored, generation: generation)
            if let self, self.connectionGeneration == generation { self.connectTask = nil }
        }
    }

    private func runConnection(_ id: UUID, restored: Bool, generation: Int) async {
        do {
            try await transport.connect(id)
            guard generation == connectionGeneration else { return }
            try await runHandshake(restored: restored, generation: generation)
            reconnectAttempts = 0
        } catch {
            guard generation == connectionGeneration else { return }
            if (error as? TransportError) == .insufficientAuthentication {
                // Don't retry into a refusal: the strap is held by another phone/app (noop #1635, #78).
                bondRefused = true
                transport.cancelConnection(id)
                linkLost(reason: Self.bondRefusedHint, reconnect: false)
                return
            }
            if (error as? TransportError) == .cancelled, intentionalDisconnect { return }
            transport.cancelConnection(id)
            linkLost(reason: describeError(error), reconnect: true)
        }
    }

    private func runHandshake(restored: Bool, generation: Int) async throws {
        // Step 2 — discovery.
        let found = try await transport.discover(StrapGATT.discoveryPlan)
        guard found.contains(StrapGATT.write) else {
            throw StrapLinkError.notReady("no fd4b0002 command characteristic: not a WHOOP 5/MG")
        }
        // Step 3 — the standard profiles answer before the bond (noop BLEManager L6727-6744).
        for c in [StrapGATT.heartRateMeasurement, StrapGATT.batteryLevel] where found.contains(c) {
            do { try await transport.setNotify(true, for: c) } catch {
                logLine("strap: subscribe \(c) failed — \(describeError(error))")
            }
        }
        if found.contains(StrapGATT.batteryLevel), let d = try? await transport.read(StrapGATT.batteryLevel),
           let percent = d.first {
            noteBattery(Double(percent), charging: nil)
        }
        // Step 4 — bond trigger: CLIENT_HELLO (145 [01], seq 1 = the static Goose frame) WITH RESPONSE, before
        // any fd4b subscription. The write-ack is the bond (noop BLEManager L6712-6723, L6879-6912; issue #17).
        setState(.bonding)
        channel.resetSequence()
        try await channel.send(.sanctioned(.getHello), awaitResponse: false)
        guard generation == connectionGeneration else { return }
        info?.bonded = true
        // Step 5 — puffin notify characteristics, only now. A restored link re-arms them off/on: its inherited
        // subscriptions can report active yet deliver nothing (noop #613, BLEManager L5421-5434).
        for c in StrapGATT.notify where found.contains(c) {
            if restored { try? await transport.setNotify(false, for: c) }
            try await transport.setNotify(true, for: c)
        }
        if found.contains(StrapGATT.modelNumber), let d = try? await transport.read(StrapGATT.modelNumber) {
            info?.model = Self.text(d)
        }
        if found.contains(StrapGATT.firmwareRevision), info?.firmware == nil,
           let d = try? await transport.read(StrapGATT.firmwareRevision) {
            info?.firmware = Self.text(d)
        }
        // Step 6 — clock (D6).
        setState(.handshaking)
        await runClockSync()
        guard generation == connectionGeneration else { return }
        // Step 7 — realtime toggles, when something wants them.
        if wantRealtimeHR || wantMotion {
            do { try await sendRealtimeToggles() } catch {
                logLine("strap: realtime toggles failed — \(describeError(error))")
            }
        }
        handshakeDone = true
        lastDataAt = clock.now
        setState(.ready)
        startMaintenance()
        // Raw optical: on again if the switch wants it (session-scoped, so every connection asks anew), or an explicit
        // OFF when the last link dropped while it was on.
        await applyRawOptical()
        guard generation == connectionGeneration else { return }
        await applyHRBroadcast(writing: hrBroadcastWanted == true || hrBroadcastUnsent)
        guard generation == connectionGeneration else { return }
        // Wave W8: raw motion on again if its switch wants it (or OFF when the last link dropped with it on); an ECG
        // reading the last link left running is stopped, never restarted (noop PROTOCOL_ECG.md L92-93).
        await applyRawMotion()
        await stopEcgIfOwed()
        guard generation == connectionGeneration else { return }
        // Step 8 — history, 1.5 s after the clock settles (noop BLEManager L6952-6958).
        if config.autoDownloadHistoryOnConnect { scheduleAutoHistory() }
    }

    func sendRealtimeToggles() async throws {
        let hr = try await channel.send(.sanctioned(.toggleRealtimeHR(on: wantRealtimeHR)), awaitResponse: true)
        let motion = try await channel.send(.sanctioned(.sendR10R11Realtime(on: wantMotion)), awaitResponse: true)
        logLine("strap: realtime HR \(wantRealtimeHR ? "on" : "off") → \(hr?.result.label ?? "no response"); "
                + "motion \(wantMotion ? "on" : "off") → \(motion?.result.label ?? "no response")")
        lastDataAt = clock.now
    }

    // MARK: - Clock (D6)

    /// GET 147 → SET 146 rev-1 → GET 147; if 146 is refused or the readback is off by more than 2 s, SET 10 → GET 11.
    /// Each SET is logged with prior, payload and readback. Without the standing consent the clock is only read.
    /// Sources: FINDINGS §7 (5/MG needs the revision byte; only one form may latch; read back);
    /// noop:docs/PROTOCOL_TRANSPORT.md "Clock and identity contracts"; noop BLEManager L6949-6950, L7087-7091.
    func runClockSync() async {
        guard !clockSyncRunning else { return }
        clockSyncRunning = true
        defer { clockSyncRunning = false }

        let prior = await readClock(deprecated: false)
        let offsetBefore = prior.map { $0.date.timeIntervalSince(clock.now) }
        guard let consentAt = config.clockConsentAt else {
            info?.clockOffsetSeconds = offsetBefore
            logLine("clock: read only — no standing consent recorded at pairing (D6)")
            return
        }
        // r8a 2026-10-17 (audit §5.3): the clock is stepped only when it is off. Within the tolerance (2 s) the write is
        // skipped; the log line is the only trace (an event per reconnect would only add noise).
        if let offsetBefore, abs(offsetBefore) < config.timing.clockTolerance {
            info?.clockOffsetSeconds = offsetBefore
            logLine(String(format: "clock ok, not set (strap − phone %+.1f s)", offsetBefore))
            return
        }
        // r8a 2026-10-17 (audit §4.6): the strap−phone offset before the set goes into the logged result, and the
        // time of the standing consent beside it. The event itself is dated when the write was made (it used to carry
        // the consent time, which put every clock set on the pairing day).
        let note = Self.clockNote(offsetBefore: offsetBefore, consentAt: consentAt)

        // Attempt A — 146, read back with 147.
        let a = Self.clockParts(clock.now)
        let setA = SanctionedCommand.setClock(unix: a.seconds, ticks: a.ticks)
        var readA: ClockReading?
        var resultA: String
        do {
            let response = try await channel.send(.sanctioned(setA), awaitResponse: true)
            if let r = response, r.result == .unsupported || r.result == .failure {
                resultA = "strap answered \(r.result.label)"
            } else {
                readA = await readClock(deprecated: false)
                resultA = clockVerdict(readA)
                if response == nil, resultA != "ok" { resultA += "; no response to the set" }
            }
        } catch {
            resultA = "write failed: \(describeError(error))"
        }
        await logWrite(setA, prior: prior?.text, readback: readA?.text, confirmedAt: clock.now,
                       result: resultA + note, standingConsent: true)
        if resultA == "ok" {
            info?.clockOffsetSeconds = readA.map { $0.date.timeIntervalSince(clock.now) }
            return
        }
        guard !linkLostHandled else { return }

        // Attempt B — 10, read back with 11 (always read back: the 5/MG reply layout of this pair is unresolved).
        let b = Self.clockParts(clock.now)
        let setB = SanctionedCommand.setClockDeprecated(unix: b.seconds)
        var readB: ClockReading?
        var resultB: String
        do {
            let response = try await channel.send(.sanctioned(setB), awaitResponse: true)
            readB = await readClock(deprecated: true)
            resultB = clockVerdict(readB)
            if resultB != "ok" {
                resultB += "; set answered \(response?.result.label ?? "nothing")"
            }
        } catch {
            resultB = "write failed: \(describeError(error))"
        }
        await logWrite(setB, prior: (readA ?? prior)?.text, readback: readB?.text, confirmedAt: clock.now,
                       result: resultB + note, standingConsent: true)
        let best = resultB == "ok" ? readB : (readA ?? readB ?? prior)
        info?.clockOffsetSeconds = best.map { $0.date.timeIntervalSince(clock.now) }
    }

    /// "; strap clock offset before set +12.3 s; standing consent 2026-10-11T19:00:00Z" appended to a clock write's result.
    static func clockNote(offsetBefore: Double?, consentAt: Date) -> String {
        let offset = offsetBefore.map { String(format: "%+.1f s", $0) } ?? "unknown (no readback)"
        let consent = ISO8601DateFormatter().string(from: consentAt)
        return "; strap clock offset before set \(offset); standing consent \(consent)"
    }

    func readClock(deprecated: Bool) async -> ClockReading? {
        let command: SanctionedCommand = deprecated ? .getClockDeprecated : .getClock
        guard let response = try? await channel.send(.sanctioned(command), awaitResponse: true) else { return nil }
        if deprecated {
            // Result byte placement for this pair is unresolved on 5/MG; only the ±2 s check decides.
            return ClockReading.fromDeprecatedGetClock(response.body)
        }
        guard response.result == .success else { return nil }
        return ClockReading.fromGetClock(response.body)
    }

    private func clockVerdict(_ readback: ClockReading?) -> String {
        guard let readback else { return "no readback" }
        let off = readback.date.timeIntervalSince(clock.now)
        if abs(off) <= config.timing.clockTolerance { return "ok" }
        return String(format: "readback off by %.1f s", off)
    }

    static func clockParts(_ date: Date) -> (seconds: UInt32, ticks: UInt16) {
        let t = date.timeIntervalSince1970
        let whole = t.rounded(.down)
        let ticks = UInt16(min(32767, max(0, ((t - whole) * 32768).rounded(.down))))
        return (UInt32(truncatingIfNeeded: Int64(whole)), ticks)
    }

    /// `restored: true` marks a write that put back a logged prior value, so the store never offers that entry's
    /// prior (the unlocked value) as the value to restore (MGStore `latestPriorValue` skips restored entries).
    func logWrite(_ command: SanctionedCommand, prior: String?, readback: String?, confirmedAt: Date, result: String,
                  standingConsent: Bool, restored: Bool? = nil) async {
        let entry = StrapWriteEntry(command: Int(command.opcode), name: command.name,
                                    payloadHex: command.payload.hexLower, priorValue: prior, readback: readback,
                                    confirmedAt: confirmedAt, result: result, standingConsent: standingConsent,
                                    restored: restored)
        do { try await writeLog.log(entry) } catch {
            logLine("strap: write log failed for \(command.name) — \(describeError(error))")
        }
    }

    // MARK: - Link loss, reconnect, maintenance

    func linkLost(reason: String, reconnect: Bool) {
        guard !linkLostHandled else { return }
        linkLostHandled = true
        handshakeDone = false
        channel.failAll()
        historyRun?.linkLost(reason)
        historyRun = nil   // T9997: the run ends by itself (its waits are bounded); the next connection must not be blocked by it
        historyProbe?.linkLost(reason)
        maintenanceTask?.cancel()
        maintenanceTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        autoHistoryTask?.cancel()
        autoHistoryTask = nil
        decodeStage.reset()
        // T9996 (r9d): the offload that tripped the raw-optical watchdog is over with the link. The resume code sits behind
        // `historyRun === run`, which a link loss breaks (`historyRun = nil` above), so the trip used to stay set and raw
        // optical stayed off after the reconnect until the switch was toggled. A new offload trips it again if needed.
        if let trip = rawOpticalTrip {
            rawOpticalTrip = nil
            logLine("raw optical: watchdog stop cleared by the link loss (was: \(trip))")
        }
        persistStalledReason = nil   // "no ack … for the rest of this connection" — a new connection starts clean
        if wantRawOptical {
            setOpticalReason("link lost (\(reason)); raw optical starts again when the strap reconnects")
        }
        if rawMotionSwitchOn {
            setMotionReason("link lost (\(reason)); raw motion starts again when the strap reconnects")
        }
        if rawOpticalLiveOn { rawOpticalNeedsOff = true }
        rawOpticalLiveOn = false
        if rawBankingOn { rawBankingNeedsOff = true }     // T9992
        rawBankingOn = false
        publishRawOptical()
        if rawMotionLiveOn { rawMotionNeedsOff = true }   // wave W8: whether the strap stopped is unknown
        rawMotionLiveOn = false
        publishRawMotion()
        ecgLinkLost()
        historyRunsThisConnection = 0
        info?.bonded = false
        flushLiveSoon()
        setState(.disconnected(reason: reason))
        logLine("strap: link lost — \(reason)")
        if reconnect, !intentionalDisconnect, !bondRefused { scheduleReconnect() }
    }

    /// The reconnect hands off to a standing connect (no timeout), which is what lets iOS wake the app when the
    /// strap comes back (noop BLEManager L1120-1140, #1413).
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
                // T9994 (r9d): this used to return silently, and nothing asked again: a reconnect that fired while the
                // failing connect was still unwinding left the link down for good. Look again later (delay grows to 60 s).
                self.logLine("strap: reconnect found a connect still in flight - will look again")
                self.scheduleReconnect()
                return
            }
            self.connect(to: id, restored: false)
        }
    }

    private func startMaintenance() {
        maintenanceTask?.cancel()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        lastKeepAliveAt = nil
        keepAliveFailed = false
        let interval = config.timing.liveFlushInterval
        maintenanceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.flushLive()
                self.checkNoData()
                self.checkRawStreamStalls()
                self.keepAliveTick()
            }
        }
    }

    /// Keep-alive (audit §5a, r8a 2026-10-17; noop ARCHITECTURE.md L273: a 30 s timer that polls battery and bounces
    /// the link after 120 s without a notification). Runs on the maintenance loop, so only while connected and ready,
    /// and ends with it (`linkLost` cancels the loop and any read in flight). Nothing is sent while notifications flow.
    /// 1. Silent for `silenceBounce` and (the stream is wanted, or the last keep-alive read failed): drop and reconnect.
    /// 2. Otherwise, idle for `keepAliveInterval` since the last notification or read: read the battery level (2A19).
    func keepAliveTick() {
        guard handshakeDone, let id = peripheralID else { return }
        let now = clock.now
        let silent = lastDataAt.map { now.timeIntervalSince($0) } ?? 0
        if silent > config.timing.silenceBounce, wantRealtimeHR || wantMotion || keepAliveFailed {
            transport.cancelConnection(id)
            linkLost(reason: "no notification for \(Int(silent)) s (keep-alive)", reconnect: true)
            return
        }
        guard keepAliveTask == nil else { return }
        let idleSince = max(lastDataAt ?? .distantPast, lastKeepAliveAt ?? .distantPast)
        guard now.timeIntervalSince(idleSince) >= config.timing.keepAliveInterval else { return }
        lastKeepAliveAt = now
        let generation = connectionGeneration
        keepAliveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let data = try await self.transport.read(StrapGATT.batteryLevel)
                guard generation == self.connectionGeneration else { return }
                self.keepAliveFailed = false
                if let percent = data.first { self.noteBattery(Double(percent), charging: nil) }
            } catch {
                guard generation == self.connectionGeneration else { return }
                // A strap without the battery characteristic cannot answer this probe; that is not a dead link.
                if case TransportError.characteristicMissing = error {} else {
                    self.keepAliveFailed = true
                    self.logLine("strap: keep-alive read failed — \(describeError(error))")
                }
            }
            self.keepAliveTask = nil
        }
    }

    /// Realtime on but nothing arrived for 600 s → drop and reconnect (noop BLEManager L4821-4827).
    private func checkNoData() {
        guard handshakeDone, wantRealtimeHR || wantMotion, let last = lastDataAt, let id = peripheralID,
              clock.now.timeIntervalSince(last) > config.timing.noDataReconnect else { return }
        transport.cancelConnection(id)
        linkLost(reason: "no data for \(Int(config.timing.noDataReconnect)) s with realtime on", reconnect: true)
    }

    private func scheduleAutoHistory() {
        autoHistoryTask?.cancel()
        let delay = config.timing.postClockHistoryDelay
        let generation = connectionGeneration
        autoHistoryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, generation == self.connectionGeneration, self.handshakeDone else { return }
            do {
                let summary = try await self.downloadHistory()
                self.logLine("history: \(summary.chunksAcked) chunk(s) acked, \(summary.recordsInserted) records, "
                             + "ended \(summary.endReason)")
            } catch {
                self.logLine("history: not started — \(describeError(error))")
            }
        }
    }

    static func text(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return s.isEmpty ? nil : s
    }

    // MARK: - StrapTransportDelegate (radio, discovery, disconnect, restore; data is in StrapLink+Live.swift)

    public func transport(_ source: StrapTransport, didChangeRadio radio: RadioState) {
        guard started else { return }
        switch radio {
        case .poweredOn:
            beginConnecting()
        case .poweredOff, .unsupported:
            linkLost(reason: "Bluetooth is off", reconnect: false)
            setState(.bluetoothOff)
        case .unauthorized:
            setState(.unauthorized)
        case .unknown, .resetting:
            break
        }
    }

    /// Service UUID only — the advertised name is never read (finding L). WhoopProtocol's decision also refuses an
    /// advertisement that lists services but not fd4b0001 (e.g. a WHOOP 4.0's 6108…); an empty list is accepted
    /// because the radio-side filter already matched (noop `whoopGattScanDecision`).
    public func transport(_ source: StrapTransport, didDiscover peripheral: DiscoveredPeripheral) {
        guard state == .scanning, connectTask == nil else { return }
        guard config.connectGate?() ?? true else {
            transport.stopScan()
            _ = connectAllowed("scan")
            return
        }
        let decision = whoopGattScanDecision(selectedServiceUUIDString: StrapGATT.service,
                                             advertisedServiceUUIDStrings: peripheral.advertisedServiceUUIDs)
        guard decision.shouldConnect, accepts(peripheral.id) else { return }
        transport.stopScan()
        connect(to: peripheral.id, restored: false)
    }

    public func transport(_ source: StrapTransport, didDisconnect peripheral: UUID, error: String?) {
        guard peripheral == peripheralID else { return }
        linkLost(reason: error ?? "strap disconnected", reconnect: true)
    }

    public func transport(_ source: StrapTransport, didRestore peripherals: [UUID]) {
        guard started, connectTask == nil, !handshakeDone, let id = peripherals.first(where: accepts) else {
            logLine("strap: Bluetooth restore (\(peripherals.count) peripheral(s)) → nothing to do "
                    + "(started \(started), connecting \(connectTask != nil), link up \(handshakeDone))")
            return
        }
        logLine("strap: Bluetooth restore → connecting to the restored strap")
        connect(to: id, restored: true)
    }
}

/// Short text for an error in logs and states.
func describeError(_ error: Error) -> String {
    switch error {
    case let e as TransportError:
        switch e {
        case .notConnected: return "not connected"
        case .characteristicMissing(let c): return "characteristic \(c) missing"
        case .insufficientAuthentication: return "pairing refused (insufficient authentication)"
        case .timeout: return "timed out"
        case .cancelled: return "cancelled"
        case .failed(let s): return s
        }
    case let e as StrapLinkError:
        return "\(e)"
    default:
        return String(describing: error)
    }
}
