import Foundation
import MGBLE
import MGContext
import MGDomain
import MGStore

// WP-23a — owns the strap link (ARCHITECTURE §4.4): one `CoreBluetoothTransport` (the only CBCentralManager, created
// lazily so the Bluetooth permission prompt appears when Mo taps Pair, not on first open — UX rule 2), and one
// `StrapLink` built with `StrapPolicy.b1` (every gated switch off; unlock off, D7). The link's config is fixed at init,
// so a new clock consent (D6) means a new link on the same transport. No CoreBluetooth import here (BRIEF WP-25 row).
//
// Limitation (reported to main): StrapLink keeps the peripheral id internal, so `pinnedPeripheralID` stays nil — the
// link accepts any 5/MG strap, matched on the service UUID fd4b0001 only, never on its name (finding L).
//
// WRITTEN, NOT COMPILED.

@MainActor
final class StrapCoordinator {
    /// UserDefaults key: a strap was paired once, so the central is created at launch (BLE state restoration needs it
    /// early) and the link starts by itself.
    static let pairedKey = "mg.strap.paired"

    private let store: MGStore
    private let clock: any MGDomain.Clock
    let confirmer: UnlockConfirmPresenter

    private(set) var transport: CoreBluetoothTransport?
    private(set) var link: StrapLink?
    private var builtWithConsent: Date??
    private var tasks: [Task<Void, Never>] = []

    /// Called on the main actor for every change of link state or strap info.
    var onChange: @MainActor (StrapLinkState, StrapInfo?) -> Void = { _, _ in }
    var onBeat: @MainActor (LiveBeat) -> Void = { _ in }
    var onEvent: @MainActor (StrapEvent) -> Void = { _ in }
    /// A new link object (first build or rebuild) — smart wake must follow it.
    var onLinkBuilt: @MainActor (StrapLink) -> Void = { _ in }
    /// Raw optical status changes (frames, on/off, a watchdog stop).
    var onRawOptical: @MainActor (RawOpticalStatus) -> Void = { _ in }
    /// What the strap reports for the HR broadcast key changed (T77).
    var onHRBroadcast: @MainActor (String?) -> Void = { _ in }
    /// A history download finished (its summary; the R22 watch counts R22 records and post-write offloads).
    var onHistory: @MainActor (HistorySummary) -> Void = { _ in }
    /// The link's own log lines (handshake, clock, history), newest last, for diagnostics.
    private(set) var log: [String] = []

    init(store: MGStore, clock: any MGDomain.Clock, confirmer: UnlockConfirmPresenter) {
        self.store = store
        self.clock = clock
        self.confirmer = confirmer
    }

    static var wasPaired: Bool { UserDefaults.standard.bool(forKey: pairedKey) }

    /// R8o (audit §2.7): the central, created synchronously at the very start of launch (MGApp.init) when a strap was paired,
    /// so CoreBluetooth state restoration finds it with the restore id `mgapp.ble.central` even though the database and the
    /// rest of the services are now built a moment later, off the main thread. `prepareTransport` adopts it.
    private static var earlyTransport: CoreBluetoothTransport?

    static func createEarlyTransportIfPaired() {
        guard wasPaired, StrapDeviceChoice.stored != .whoop4, earlyTransport == nil else { return }   // WHOOP 4.0 chosen: no 5/MG central
        earlyTransport = makeTransport()
    }

    private static func makeTransport() -> CoreBluetoothTransport {
        let t = CoreBluetoothTransport()
        t.onRestore = { n in LifecycleRecorder.note(.bleRestore, "Bluetooth state restored by iOS (\(n) peripheral\(n == 1 ? "" : "s"))") }
        return t
    }

    /// Creates the central (with the restore id `mgapp.ble.central`), or adopts the one made at launch. Call at launch only
    /// when a strap was paired.
    func prepareTransport() {
        if transport == nil {
            guard StrapDeviceChoice.stored != .whoop4 else { return }   // WHOOP 4.0 chosen: the 5/MG central is not created
            transport = Self.earlyTransport ?? Self.makeTransport()
        }
    }

    /// Builds the link if needed (or rebuilds it when the clock consent changed) and starts it.
    func start(installSalt: Data, clockConsentAt: Date?) {
        prepareTransport()
        UserDefaults.standard.set(true, forKey: Self.pairedKey)
        guard let transport else { return }
        if let link, builtWithConsent == .some(clockConsentAt) {
            link.start()
            return
        }
        let rawOpticalMayBeOn = link?.rawOptical.on ?? false
        teardown()
        // No command is refused on policy (CLAUDE.md rule 5, 2026-10-13).
        // WHOOP4-LINK (D-WHOOP4-LINK-1): this link neither scans nor connects while "WHOOP 4.0" is the selected device. The gate
        // is asked every time, so a choice made while the link exists takes effect at its next scan, connect or reconnect.
        let config = StrapLinkConfig(installSalt: installSalt, pinnedPeripheralID: nil, clockConsentAt: clockConsentAt,
                                     policy: .b1, autoDownloadHistoryOnConnect: true,
                                     timing: .production,
                                     connectGate: { StrapConnectPolicy.allows(.mg, choice: StrapDeviceChoice.stored, handedBack: false) })
        let store = self.store
        let new = StrapLink(transport: transport, config: config, clock: clock, historySink: store, liveSink: store,
                            writeLog: store, confirmer: confirmer,
                            log: { [weak self] line in self?.note(line) },
                            priorValueLookup: { cmd, key in try? await store.latestPriorValue(command: cmd, key: key) },
                            flagSnapshotSink: { snap in try await store.storeFlagSnapshot(snap) })
        link = new
        if rawOpticalMayBeOn { new.noteRawOpticalMayBeOn() }
        builtWithConsent = .some(clockConsentAt)
        observe(new)
        onLinkBuilt(new)
        new.start()
    }

    /// T141: the app came back to the foreground; let the link look at the radio again (no-op unless it was stuck on
    /// "Bluetooth is off" / "not allowed", or idle after a lost connection).
    func foregrounded() { wake("foreground") }

    /// T9994 (r9d): any wake (foreground, background task, background refresh) reconnects the strap when it is wanted and the
    /// link is down. The decision is made and logged by `StrapLink.wake`.
    func wake(_ reason: String) {
        guard let link else {
            note("wake (\(reason)): the link is not built yet")
            return
        }
        link.wake(reason)
    }

    /// Sends 108 OFF first when raw optical is on, then disconnects.
    func disconnect() {
        guard let link else { return }
        Task { @MainActor in await link.disconnectStoppingRawOptical() }
    }

    /// Same as `disconnect()` but returns only after raw streams are off and the link is down (used before the WHOOP 4.0 starts).
    func disconnectAndWait() async {
        guard let link else { return }
        await link.disconnectStoppingRawOptical()
    }

    /// The raw optical switch and the app's foreground state (raw optical runs only while both are true).
    func setRawOptical(enabled: Bool, foreground: Bool) {
        guard let link else { return }
        Task { @MainActor in await link.setRawOptical(enabled: enabled, foreground: foreground) }
    }

    /// T9992: the "keep raw on the strap if the app is closed" switch (107 banking; the link only sends it while raw optical is wanted).
    func setRawBanking(_ enabled: Bool) {
        guard let link else { return }
        Task { @MainActor in await link.setRawBanking(enabled) }
    }

    /// HR broadcast switch (T77): written now when connected, else at the next handshake (the link keeps the wish).
    func setHRBroadcast(_ on: Bool) async {
        if let link { await link.setHRBroadcast(on) }
    }

    /// Realtime HR (3) and R10/R11 (63) — the two sanctioned toggles (D5). Applied now or at the next handshake.
    func setRealtime(hr: Bool, motion: Bool) {
        guard let link else { return }
        Task { @MainActor [weak self] in
            do { try await link.setRealtime(hr: hr, motion: motion) } catch {
                self?.note("realtime toggles: \(error)")
            }
        }
    }

    /// The read-only strap settings snapshot (117/118/128), stored by MGBLE before it returns.
    func readFlagSnapshot() async -> Result<StrapFlagSnapshot, StrapActionError> {
        guard let link else { return .failure(StrapActionError("the strap link is not started")) }
        do { return .success(try await link.readFlagSnapshot()) } catch {
            note("strap settings: \(error)")
            return .failure(StrapActionError("\(error)"))
        }
    }

    /// R22 research stream: read + store every setting, then the one enable_r22_packets = '1' write (confirm sheet).
    func enableR22() async -> Result<UnlockReport, StrapActionError> {
        guard let link else { return .failure(StrapActionError("the strap link is not started")) }
        do {
            let plan = try await link.prepareUnlock()
            return .success(try await link.runUnlock(plan))
        } catch {
            note("R22: \(error)")
            return .failure(StrapActionError(Self.words(error)))
        }
    }

    /// Writes the value stored before the R22 write back (confirm sheet).
    func restoreR22() async -> Result<UnlockReport, StrapActionError> {
        guard let link else { return .failure(StrapActionError("the strap link is not started")) }
        do { return .success(try await link.restoreUnlock()) } catch {
            note("R22 restore: \(error)")
            return .failure(StrapActionError(Self.words(error)))
        }
    }

    /// Live › Research › "Test: read history without deleting" (wave W12b): reads, one unacknowledged chunk, ABORT.
    func runHistoryReadTest() async -> Result<HistoryProbeResult, StrapActionError> {
        guard let link else { return .failure(StrapActionError("the strap link is not started")) }
        do { return .success(try await link.runHistoryReadTest()) } catch {
            note("history test: \(error)")
            if case StrapLinkError.historyInProgress = error {
                return .failure(StrapActionError("a history download is running — try again when it ends"))
            }
            return .failure(StrapActionError(Self.words(error)))
        }
    }

    /// "Hand the strap back to WHOOP" (wave W12b, #103): restore, stop, disconnect (MGBLE `handBackToWhoop`).
    func handBack(alarmArmedByApp: Bool, consentAt: Date) async -> HandBackReport {
        guard let link else {
            return HandBackReport(startedAt: clock.now, endedAt: clock.now,
                                  lines: ["The strap link never started — nothing on the strap to put back."])
        }
        return await link.handBackToWhoop(alarmArmedByApp: alarmArmedByApp, consentAt: consentAt)
    }

    /// Settings › Command test (T87): one frame, WITH RESPONSE, any number and payload. Throws words for the page.
    func sendTestCommand(opcode: UInt8, payload: [UInt8]) async throws {
        guard let link else { throw StrapActionError("the strap link is not started") }
        do { _ = try await link.sendTestCommand(opcode: opcode, payload: payload) } catch {
            throw StrapActionError(Self.words(error))
        }
    }

    /// The newest snapshot the link stored (the R22 plan takes one).
    var lastFlagSnapshot: StrapFlagSnapshot? { link?.lastFlagSnapshot }

    static func words(_ error: Error) -> String {
        guard let e = error as? StrapLinkError else { return "\(error)" }
        switch e {
        case .refused(let why), .notSaved(let why), .notReady(let why), .planMismatch(let why): return why
        case .refusedByPolicy(let reason): return reason
        default: return "\(e)"
        }
    }

    var state: StrapLinkState { link?.state ?? .idle }
    var info: StrapInfo? { link?.info }

    // MARK: Internals

    private func observe(_ link: StrapLink) {
        tasks.append(Task { @MainActor [weak self, weak link] in
            guard let link else { return }
            for await s in link.$state.values {
                guard let self else { return }
                self.onChange(s, link.info)
            }
        })
        tasks.append(Task { @MainActor [weak self, weak link] in
            guard let link else { return }
            for await i in link.$info.values {
                guard let self else { return }
                self.onChange(link.state, i)
                if let i { await self.register(i) }
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
        tasks.append(Task { @MainActor [weak self, weak link] in
            guard let link else { return }
            for await r in link.$rawOptical.values {
                guard let self else { return }
                self.onRawOptical(r)
            }
        })
        tasks.append(Task { @MainActor [weak self, weak link] in
            guard let link else { return }
            for await r in link.$hrBroadcastReading.values {
                guard let self else { return }
                self.onHRBroadcast(r)
            }
        })
        tasks.append(Task { @MainActor [weak self, weak link] in
            guard let link else { return }
            for await summary in link.$lastHistory.values {
                guard let self else { return }
                guard let summary else { continue }
                self.onHistory(summary)
            }
        })
    }

    private func teardown() {
        for t in tasks { t.cancel() }
        tasks.removeAll()
        link?.disconnect()
        link = nil
        builtWithConsent = nil
    }

    /// The strap registry row (§4.5 `strap`): firmware and model as the link learns them.
    private func register(_ i: StrapInfo) async {
        do {
            try await store.upsertStrap(id: i.strapId, peripheralUUID: nil, family: "whoop5", firmware: i.firmware,
                                        model: i.model, seenAt: clock.now)
        } catch {
            note("strap registry: \(error)")
        }
    }

    /// A line from elsewhere in the composition for the same diagnostics log.
    func noteExternal(_ line: String) { note(line) }

    private func note(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: Mapping for the context engine

    /// StrapLinkState → StrapStatus.Link (MGContext). `paired` false and idle = not paired (first launch, UX §13).
    /// T10004: `starting` = the app is about to start (or has just started) the link, so a paired strap that is `.idle` is
    /// "connecting", not "not connected" (every app open flashed "MG not connected" before the link came up). False with
    /// "Hand the strap back to WHOOP" on: the link is not started then, and idle really is not connected.
    static func linkStatus(_ s: StrapLinkState, paired: Bool, starting: Bool = false) -> StrapStatus.Link {
        switch s {
        case .bluetoothOff: return .bluetoothOff
        case .unauthorized: return .bluetoothNotAllowed   // T141: was folded into "Bluetooth is off"
        case .idle: return paired ? (starting ? .connecting : .disconnected) : .notPaired
        case .scanning: return .searching
        case .connecting, .bonding, .handshaking: return .connecting
        case .ready, .downloadingHistory: return .connected
        case .disconnected: return .disconnected
        }
    }

    /// T141 (r9d): why "MG not connected", in a few words (MGContext `StrapStatus.notConnectedWords`). nil unless the link is down.
    static func notConnectedReason(_ s: StrapLinkState, handedBack: Bool) -> String? {
        switch s {
        case .idle: return handedBack ? StrapStatus.notConnectedWords(raw: nil, handedBack: true) : nil
        case .disconnected(let reason): return StrapStatus.notConnectedWords(raw: reason, handedBack: handedBack)
        default: return nil
        }
    }

    static func history(_ s: StrapLinkState) -> HistoryProgress? {
        if case .downloadingHistory(let p) = s { return p }
        return nil
    }
}

/// Why a strap action did not happen, in words for a notice.
struct StrapActionError: Error {
    let text: String
    init(_ text: String) { self.text = text }
}
