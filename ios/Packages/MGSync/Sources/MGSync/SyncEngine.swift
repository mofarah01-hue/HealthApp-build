import Foundation
import MGDomain

/// The phone-side sync client (ARCHITECTURE.md 5, WP-14). One `sync` = probe the PC, build and enqueue what is waiting,
/// upload each drop, accept it as delivered only on matching receipts, fetch new PC results.
///
/// The delivery rule (5.5): a drop is marked delivered only when the commit answers `stored` AND every file of the drop
/// has a receipt whose `name`, `bytes`, `sha256` and `records` equal the phone's own numbers for the bytes it sent.
/// Anything else (422, timeout, 5xx, a receipt that differs) leaves the drop in the outbox and counts a failed attempt.
/// Nothing on the phone is deleted because of a sync.
///
/// Errors that stop a whole sync (they are not the drop's fault): 401 -> state `.error` "Pairing was reset — pair
/// again"; 409 contract / sync API mismatch -> state `.error` "PC Lab speaks contract N.x; update one side".
/// What a running sync is doing, for the app's "Working on…" line (wave 2, 2026-10-11; Mo: "if stuff is processing I
/// want to know about it"). `nil` is reported when the sync ends.
public struct SyncProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        /// Day, stream or raw drops going to the PC.
        case uploading
        /// The profile going to the PC.
        case profile
        /// PC results coming to the phone ("past days 120 of 366").
        case fetchingResults
    }

    public var phase: Phase
    public var done: Int
    public var total: Int

    public init(phase: Phase, done: Int, total: Int) {
        self.phase = phase
        self.done = done
        self.total = total
    }
}

public actor SyncEngine {
    static let bleWakeMinGap: TimeInterval = 3600
    /// T10002: a day whose drop was delivered less than this long ago is not rebuilt for a background, foreground or path
    /// trigger. Today's numbers keep moving while the strap streams (every compute changes some value), and each rebuild
    /// is a new ~400 KB content-hash drop: the PC log showed 107 PUTs of one day between 12 AM and 8:46 AM. `.manual`
    /// (Sync now, the wake chain) ignores the gap; the day stays dirty and goes at the first run after it.
    static let dayResendGap: TimeInterval = 30 * 60
    /// T9991 (b): how long past the run's budget a single PUT or commit may still be in flight before the run is cancelled.
    static let hardStopGrace: TimeInterval = 90
    /// T9991 (a): a run looks again for drops queued while it uploaded, this many times at most.
    static let maxPasses = 3
    /// Retry ladder (P9734, 2026-10-14; Mo: the phone must reach the PC without him): 1, 2, 5, 15, then every 60 minutes.
    static let retryLadder: [TimeInterval] = [60, 120, 300, 900, 3600]
    /// Rejected keys in a row (each after a good /v1/health) before the app asks for a QR re-scan.
    static let authFailuresToRepair = 3

    private let transport: any PCLabTransport
    private let credentials: any CredentialStore
    private let days: any DayBundleSource
    private let streams: any StreamExportSource
    private let outbox: any SyncOutbox
    private let results: any ResultsSink
    private let notifier: any SyncNotifying
    private let clock: any MGDomain.Clock
    private let strapIds: (any StrapIDSource)?
    private let raw: (any RawExportSource)?
    private let isSampleMode: @Sendable () async -> Bool
    private let ledgerStore: any SyncLedgerStore
    private let calendar: Calendar
    private let appVersion: String
    private let builder: DropBuilder
    private let profileSource: (@Sendable () async -> Profile?)?
    private let onProgress: (@Sendable (SyncProgress?) async -> Void)?
    /// Round 8: one line for the phone's compute/sync log (a results cursor restart and why, a PC without the bundle route).
    private let onLog: (@Sendable (String) async -> Void)?
    /// #74 (2026-10-11): may raw drops go now? The app answers from the network path (MGDomain `RawUploadPolicy`:
    /// any connection, not in Low Data Mode). nil = always (tests, a build without a path watcher).
    private let rawGate: (@Sendable () async -> RawUploadPolicy.Decision)?

    /// What the phone knows about the PC Lab (contract `syncState`). Updated by `pair`, `sync` and `refreshStatus`.
    public private(set) var status: SyncStatus

    private var ledger = SyncLedger()
    private var ledgerLoaded = false
    private var ledgerDirty = false
    /// Persisted in the ledger (`syncState`): survives a relaunch.
    private var needsRepair: Bool {
        get { ledger.syncState?.needsRepair ?? false }
        set { var s = ledger.syncState ?? PersistedSyncState(); s.needsRepair = newValue; ledger.syncState = s; ledgerDirty = true }
    }
    private var st: PersistedSyncState {
        get { ledger.syncState ?? PersistedSyncState() }
        set { ledger.syncState = newValue; ledgerDirty = true }
    }
    private var running: Task<SyncOutcome, Never>?
    private var runningRaw = false
    private var lastReachable: Bool?
    private var failures: [String: (at: Date, attempts: Int)] = [:]

    /// The first eight parameters are ARCHITECTURE.md 5.9; the rest are additive and defaulted.
    public init(
        transport: any PCLabTransport,
        credentials: any CredentialStore,
        days: any DayBundleSource,
        streams: any StreamExportSource,
        outbox: any SyncOutbox,
        results: any ResultsSink,
        notifier: any SyncNotifying,
        clock: any MGDomain.Clock,
        strapIds: (any StrapIDSource)? = nil,
        raw: (any RawExportSource)? = nil,
        isSampleMode: @escaping @Sendable () async -> Bool = { false },
        ledger: any SyncLedgerStore = InMemorySyncLedgerStore(),
        calendar: Calendar = .current,
        appVersion: String = "0.1.0",
        deflater: any Deflating = RawDeflate(),
        profile: (@Sendable () async -> Profile?)? = nil,
        progress: (@Sendable (SyncProgress?) async -> Void)? = nil,
        rawGate: (@Sendable () async -> RawUploadPolicy.Decision)? = nil,
        log: (@Sendable (String) async -> Void)? = nil
    ) {
        self.rawGate = rawGate
        self.onLog = log
        self.profileSource = profile
        self.onProgress = progress
        self.transport = transport
        self.credentials = credentials
        self.days = days
        self.streams = streams
        self.outbox = outbox
        self.results = results
        self.notifier = notifier
        self.clock = clock
        self.strapIds = strapIds
        self.raw = raw
        self.isSampleMode = isSampleMode
        self.ledgerStore = ledger
        self.calendar = calendar
        self.appVersion = appVersion
        self.builder = DropBuilder(calendar: calendar, appVersion: appVersion, clock: clock, deflater: deflater)
        if let c = try? credentials.load() {
            status = SyncStatus(state: .offline, pcName: c.pcName)
        } else {
            status = .notSetUp
        }
    }

    // MARK: - Watch recordings (0.6.0.10)

    /// Relays one .mgw file from the Watch (`WatchReceiver`) to PC Lab. true = the PC stored it (201) or already had it
    /// (200); false = the PC answered something else (the file stays in the phone's inbox). Throws when there is no
    /// PC to send to (not paired, SAMPLE mode) or the network failed; the receiver retries on its next call.
    public func uploadWatchFile(name: String, data: Data, sha256: String) async throws -> Bool {
        if await isSampleMode() { throw SyncError.unexpected(SyncMessages.sampleMode) }
        guard let creds = try credentials.load() else { throw SyncError.unexpected(SyncMessages.notPaired) }
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)
        let reply = try await client.putWatchFile(name: name, data: data, sha256: sha256)
        return reply.status == 200 || reply.status == 201
    }

    // MARK: - Pairing (5.2)

    /// Redeems the one-time token for a device key and keeps it in the credential store (the Keychain).
    /// Throws `SyncError` with a sentence for the screen; `status` also carries it as `.error`.
    public func pair(_ payload: PairingPayload, deviceName: String, allowAnyHost: Bool = false) async throws {
        guard allowAnyHost || payload.isTailscaleHost else {
            throw SyncError.hostNotAllowed(
                "\(payload.base.host ?? "That address") is not a Tailscale name or address, so the app will not send your data there")
        }
        let previous = status
        status = SyncStatus(state: .pairing, pcName: payload.pcName)
        let client = PCLabClient(transport: transport, baseURL: payload.base, deviceKey: nil)
        let reply: APIReply
        do {
            reply = try await client.pair(token: payload.token, deviceName: deviceName, appVersion: appVersion)
        } catch is TransportError {
            let msg = SyncMessages.unreachable(payload.pcName)
            status = SyncStatus(state: .error, pcName: payload.pcName, error: msg)
            throw SyncError.unreachable(msg)
        } catch {
            status = previous
            throw error
        }
        let err = reply.apiError
        switch reply.status {
        case 200:
            let paired: PairResponse
            do { paired = try reply.decode(PairResponse.self) } catch {
                status = SyncStatus(state: .error, pcName: payload.pcName, error: "\(error)")
                throw error
            }
            if let problem = SyncEngine.versionProblem(contract: paired.contractVersion, syncAPI: paired.syncAPI) {
                status = SyncStatus(state: .error, pcName: payload.pcName, error: problem)
                throw SyncError.versionMismatch(problem)
            }
            let pcName = paired.pcName ?? payload.pcName
            let creds = PCCredentials(baseURL: payload.base, deviceId: paired.deviceId, deviceKey: paired.deviceKey,
                                      pcName: pcName, pairedAt: clock.now)
            do { try credentials.save(creds) } catch {
                status = SyncStatus(state: .error, pcName: pcName, error: "\(error)")
                throw error
            }
            await ensureLedger()
            ledger = SyncLedger()          // delivered-input hashes belong to the PC they were sent to
            ledgerDirty = true
            await persistLedger()
            needsRepair = false
            lastReachable = true
            status = SyncStatus(state: .online, pcName: pcName)
        case 401:
            let msg = err?.reason ?? "The pairing code was not accepted — run `python -m mglab pair` on the PC again"
            status = SyncStatus(state: .error, pcName: payload.pcName, error: msg)
            throw SyncError.pairingRejected(msg)
        case 409:
            let msg = SyncEngine.versionMessage(err) ?? err?.reason ?? "The PC Lab and the app speak different versions; update one side"
            status = SyncStatus(state: .error, pcName: payload.pcName, error: msg)
            throw SyncError.versionMismatch(msg)
        default:
            let msg = "The PC Lab answered HTTP \(reply.status) to the pairing request" + (err?.reason.map { ": \($0)" } ?? "")
            status = SyncStatus(state: .error, pcName: payload.pcName, error: msg)
            throw SyncError.unexpected(msg)
        }
    }

    /// T9821: queues one saved live-ECG reading for the PC (drop `ecg_<event id>`). It goes with the next sync; asking again
    /// for the same reading changes nothing (the outbox keeps the first copy). Throws when the trace cannot be encoded or
    /// the outbox cannot be written; the reading stays on the phone either way.
    public func enqueueEcg(_ trace: EcgTrace, startedAt: Date) async throws {
        guard !(await isSampleMode()) else { return }
        try await outbox.enqueue(try builder.ecgDrop(trace: trace, startedAt: startedAt))
    }

    /// Forgets the pairing on this phone (Settings > Unpair). The outbox is left as it is.
    public func unpair() async throws {
        try credentials.clear()
        await ensureLedger()
        ledger.syncState = nil
        ledger.primary = nil          // T9809: the primary-source map belongs to the PC just forgotten
        mapProblem = nil
        ledgerDirty = true
        await persistLedger()
        lastReachable = nil
        status = .notSetUp
    }

    // MARK: - Sync (5.5, 5.7)

    /// Runs one sync. Concurrent calls join the run in progress (a `.rawUpload` after a non-raw run waits for it and
    /// then runs its own). `budget` is wall-clock time before the engine stops starting new work (a background
    /// refresh gets 25 s, a BLE wake 20 s); cancelling the calling task stops it at the next step.
    public func sync(_ trigger: SyncTrigger, budget: Duration) async -> SyncOutcome {
        let isRaw = trigger == .rawUpload
        while let current = running {
            let outcome = await current.value
            if runningRaw == isRaw { return outcome }
        }
        runningRaw = isRaw
        let task = Task { () -> SyncOutcome in
            let outcome = await self.runSync(trigger, budget: budget)
            await self.onProgress?(nil)
            await self.persistLedger()
            self.running = nil
            return outcome
        }
        running = task
        // T9991 (b): the budget is only checked between files; a PUT or commit that stalls (URLSession's own timers are idle
        // timers) is cut off here, a little past the budget. The drop is marked part-way and goes on at the next sync.
        let hardStop = budget.totalSeconds + SyncEngine.hardStopGrace
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(1, hardStop) * 1_000_000_000))
            if !Task.isCancelled { task.cancel() }
        }
        let value = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        watchdog.cancel()
        return value
    }

    /// Recomputes the status counters (unsynced days, last synced) without talking to the PC. Cheap; call it on
    /// foreground and after logging.
    @discardableResult
    public func refreshStatus() async -> SyncStatus {
        await ensureLedger()
        guard running == nil else { return status }
        var s = status
        if s.state != .notSetUp && s.state != .pairing {
            s.unsyncedDays = await unsyncedDayCount(pending: nil)
            s.lastSynced = ledger.lastSynced
            s.lastReceipt = ledger.lastReceipt
            status = s
        }
        return s
    }

    /// T9809: metric name -> primary source as the PC last served it; empty before the first poll or with an old PC.
    public func primaryMap() async -> [String: String] {
        await ensureLedger()
        return ledger.primary ?? [:]
    }

    /// Is a PC result for `date` computed on what this phone has delivered? (5.6)
    public func freshness(ofInputsHash hash: String?, on date: LocalDay) async -> ResultFreshness {
        await ensureLedger()
        return InputsHash.freshness(resultHash: hash, delivered: ledger.deliveredInputs(for: date))
    }

    // MARK: - One sync

    private func runSync(_ trigger: SyncTrigger, budget: Duration) async -> SyncOutcome {
        await ensureLedger()
        let started = clock.now
        let deadline = started.addingTimeInterval(budget.totalSeconds)

        if await isSampleMode() {
            return SyncOutcome(result: .skipped, detail: SyncMessages.sampleMode)
        }
        let creds: PCCredentials
        do {
            guard let loaded = try credentials.load() else {
                if status.state != .error { status = .notSetUp }
                return SyncOutcome(result: .notSetUp, detail: SyncMessages.notPaired)
            }
            creds = loaded
        } catch {
            status = SyncStatus(state: .error, error: SyncMessages.keychainUnreadable)
            return SyncOutcome(result: .error, detail: SyncMessages.keychainUnreadable)
        }
        if needsRepair && trigger != .manual {
            return SyncOutcome(result: .error, detail: SyncMessages.pairingReset)
        }
        // Background triggers wait out the retry ladder after a failure (the user, a path change and a foreground do not).
        if trigger == .bleWake || trigger == .backgroundRefresh, let next = st.nextRetryAt, started < next {
            return SyncOutcome(result: .skipped, detail: "Retrying at \(SyncMessages.clock12(next, now: started))")
        }
        // T9988: a sync that stopped with work left (time ran out) does not wait out the hour: the next strap wake goes on.
        if trigger == .bleWake, st.consecutiveFailures == 0, st.lastStop == nil, let last = st.lastAttemptAt,
           started.timeIntervalSince(last) < SyncEngine.bleWakeMinGap {
            return SyncOutcome(result: .skipped, detail: "Last attempt was under an hour ago")
        }
        st.lastAttemptAt = started
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)

        // 1. Is the PC there, and does it speak our versions?
        switch await probe(client) {
        case .unreachable(let why):
            await noteReachable(false)
            noteFailure(why)
            status = SyncStatus(state: .offline, pcName: creds.pcName, lastSynced: ledger.lastSynced,
                                unsyncedDays: await unsyncedDayCount(pending: nil), lastReceipt: ledger.lastReceipt)
            return SyncOutcome(result: .offline, detail: why)
        case .versionMismatch(let message):
            await noteReachable(true)
            status = SyncStatus(state: .error, pcName: creds.pcName, lastSynced: ledger.lastSynced,
                                unsyncedDays: await unsyncedDayCount(pending: nil), error: message,
                                lastReceipt: ledger.lastReceipt)
            return SyncOutcome(result: .error, detail: message)
        case .cancelled:
            return SyncOutcome(result: .skipped, detail: "Stopped")
        case .ok:
            await noteReachable(true)
        }

        // 2. Build and enqueue what is waiting. Raw goes with every sync since #74 (2026-10-11), unless the gate says
        // wait (Low Data Mode): then raw drops are neither built nor sent, and the outcome says why.
        let rawDecision = await rawGate?() ?? .send
        var failed: [DropFailure] = []

        // 3. Upload, oldest first: day drops, then streams, then raw (the .rawUpload task: raw only).
        let bypassBackoff = trigger == .manual || trigger == .pathChange || trigger == .foreground
        var delivered = DeliveryAccumulator(pcName: creds.pcName)
        var warnings: [String] = []
        var stop: StopReason?
        var waiting = 0
        var rawHeld: String?
        // T9991 (a): a drop queued while this run was uploading (a history chunk landing, a compute finishing) used to wait
        // for the next run although this one reported "done". After the queue is empty the run builds again and takes what
        // is new, up to `maxPasses` times; a drop already looked at in this run (sent, failed or backed off) is not retried.
        var looked = Set<String>()
        var pass = 0
        while true {
            pass += 1
            let built = await buildAndEnqueue(trigger: trigger, deadline: deadline, raw: rawDecision.allowed)
            for f in built.failures where !failed.contains(where: { $0.dropId == f.dropId }) { failed.append(f) }
            if built.expired { stop = .budget }
            let all = (try? await outbox.pending()) ?? []
            let pending = all
                .filter { $0.kind == .raw ? rawDecision.allowed : trigger != .rawUpload }
                .filter { !looked.contains($0.dropId) }
            // T9988: rotate day / streams / raw so re-sent day drops cannot starve streams and raw (see `interleaved`).
            let ordered = SyncEngine.interleaved(pending)
            // Say why raw waits only when there is raw to send (a drop already built, or frames not yet in a drop).
            if pass == 1, !rawDecision.allowed {
                let ranges = (try? await raw?.pendingRawRanges()) ?? []
                if all.contains(where: { $0.kind == .raw }) || !ranges.isEmpty { rawHeld = rawDecision.reason }
            }
            if stop == nil {
                for (n, drop) in ordered.enumerated() {
                    if Task.isCancelled { stop = .cancelled; break }
                    if clock.now >= deadline { stop = .budget; break }
                    looked.insert(drop.dropId)
                    if isBackedOff(drop, bypass: bypassBackoff) { waiting += 1; continue }
                    await onProgress?(SyncProgress(phase: .uploading, done: n, total: ordered.count))
                    switch await upload(drop, client: client, deadline: deadline) {
                    case .delivered(let receipts, let drift):
                        delivered.add(drop, receipts: receipts)
                        warnings += drift.map { "\(drop.dropId): \($0)" }
                        recordDelivered(drop)
                        failures[drop.dropId] = nil
                    case .failed(let failure):
                        failed.append(failure)
                    case .stop(let reason):
                        stop = reason
                    }
                    if stop != nil { break }
                }
            }
            if stop != nil || ordered.isEmpty || pass >= SyncEngine.maxPasses || clock.now >= deadline { break }
        }

        // 3b. The profile, when it changed (wave 2: the PC's MS-01..04 and PhenoAge need age / sex / height / weight).
        // A problem here is a warning, not a failed sync: the data itself went through.
        if stop == nil, trigger != .rawUpload, let problem = await pushProfile(client: client) {
            warnings.append(problem)
        }

        // 4. New PC results (not on the raw-upload task).
        var fetched = 0
        var fetchedProblem: String?
        mapProblem = nil
        resultNotes = []
        if stop == nil, trigger != .rawUpload {
            let r = await fetchResults(client: client, deadline: deadline)
            fetched = r.fetched
            fetchedProblem = r.problem
            stop = r.stop
        }
        // T9809: the map's own error is reported with any other results error and in every outcome, never hidden by one.
        let resultsProblem = SyncEngine.joined(fetchedProblem, mapProblem)

        // 5. Report.
        var outcome = await conclude(creds: creds, trigger: trigger, stop: stop, delivered: delivered, failed: failed,
                                     fetched: fetched, resultsProblem: resultsProblem, backedOff: waiting)
        outcome.warnings = warnings + resultNotes
        outcome.rawHeld = rawHeld
        if let rawHeld, trigger == .rawUpload, outcome.result == .nothingToSend {
            outcome.result = .skipped
            outcome.detail = rawHeld
        }
        return outcome
    }

    private func conclude(creds: PCCredentials, trigger: SyncTrigger, stop: StopReason?, delivered: DeliveryAccumulator,
                          failed: [DropFailure], fetched: Int, resultsProblem: String?, backedOff: Int) async -> SyncOutcome {
        let now = clock.now
        let summary = delivered.summary
        if let receipt = delivered.lastReceipt { ledger.lastReceipt = receipt; ledgerDirty = true }
        if let summary {
            await notifier.delivered(summary: summary)
            var s = st                  // the PC accepted something: the key works and the PC is receiving
            s.lastAcceptedAt = now
            s.bytesDelivered += summary.bytes
            s.authFailures = 0
            s.consecutiveFailures = 0
            s.nextRetryAt = nil
            st = s
        }
        let unsynced = await unsyncedDayCount(pending: nil)

        func online(error: String? = nil) -> SyncStatus {
            SyncStatus(state: .online, pcName: creds.pcName, lastSynced: ledger.lastSynced, unsyncedDays: unsynced,
                       error: error, lastReceipt: ledger.lastReceipt)
        }

        switch stop {
        case .authFailed:
            // One 401 is not proof the key changed (the PC restarting, a proxy, a race): retry on the ladder, and ask for
            // a QR re-scan only after `authFailuresToRepair` in a row, each after a good /v1/health (we only get here
            // after the probe answered).
            var s = st
            s.authFailures += 1
            let detail = "HTTP 401 from the PC Lab after a good /v1/health (key not accepted, \(s.authFailures) in a row)"
            let message: String
            if s.authFailures >= SyncEngine.authFailuresToRepair {
                s.needsRepair = true
                message = SyncMessages.pairingReset
            } else {
                message = SyncMessages.keyNotAcceptedYet(n: s.authFailures, of: SyncEngine.authFailuresToRepair)
            }
            st = s
            noteFailure(detail)
            status = SyncStatus(state: .error, pcName: creds.pcName, lastSynced: ledger.lastSynced,
                                unsyncedDays: unsynced, error: message, lastReceipt: ledger.lastReceipt)
            return SyncOutcome(result: .error, delivered: summary, failures: failed, resultsFetched: fetched,
                               detail: SyncEngine.joined(message, resultsProblem))
        case .versionMismatch(let message):
            recordError(message)
            status = SyncStatus(state: .error, pcName: creds.pcName, lastSynced: ledger.lastSynced,
                                unsyncedDays: unsynced, error: message, lastReceipt: ledger.lastReceipt)
            return SyncOutcome(result: .error, delivered: summary, failures: failed, resultsFetched: fetched,
                               detail: SyncEngine.joined(message, resultsProblem))
        case .unreachable(let why):
            await noteReachable(false)
            noteFailure(why)
            status = SyncStatus(state: .offline, pcName: creds.pcName, lastSynced: ledger.lastSynced,
                                unsyncedDays: unsynced, lastReceipt: ledger.lastReceipt)
            return SyncOutcome(result: summary == nil ? .offline : .partial, delivered: summary, failures: failed,
                               resultsFetched: fetched, detail: SyncEngine.joined(why, resultsProblem))
        case .budget, .cancelled:
            // T9988: a stop with work left is said, not silent: "stopped, 2.4 MB left" (Settings > Strap & sync, the notice).
            let left = await queuedBytes()
            let note = SyncMessages.stopped(leftBytes: left)
            var s = st
            s.lastStop = note
            s.lastStopAt = now
            st = s
            status = online()
            let why = stop == .budget ? "time ran out" : "interrupted"
            return SyncOutcome(result: .partial, delivered: summary, failures: failed, resultsFetched: fetched,
                               detail: SyncEngine.joined("\(note.prefix(1).uppercased() + note.dropFirst()) (\(why)); the rest goes at the next sync",
                                                         resultsProblem))
        case nil:
            var s = st
            s.lastStop = nil
            s.lastStopAt = nil
            s.needsRepair = false
            s.authFailures = 0
            s.consecutiveFailures = 0
            s.nextRetryAt = nil
            if failed.isEmpty && resultsProblem == nil { s.lastError = nil; s.lastErrorAt = nil }
            else if let f = failed.last { s.lastError = f.reason; s.lastErrorAt = now }
            else if let p = resultsProblem { s.lastError = p; s.lastErrorAt = now }
            st = s
            if failed.isEmpty && backedOff == 0 && resultsProblem == nil {
                if trigger != .rawUpload {      // the raw task does not fetch results, so it is not a full sync
                    ledger.lastSynced = now
                    ledgerDirty = true
                }
                status = online()
                let nothing = summary == nil && fetched == 0
                return SyncOutcome(result: nothing ? .nothingToSend : .synced, delivered: summary, resultsFetched: fetched)
            }
            status = online()
            var detail = resultsProblem
            if backedOff > 0, failed.isEmpty { detail = SyncEngine.joined(detail, "\(backedOff) drops are waiting out a retry delay") }
            return SyncOutcome(result: .partial, delivered: summary, failures: failed, resultsFetched: fetched, detail: detail)
        }
    }

    // MARK: - Probe

    private enum ProbeResult { case ok, unreachable(String), versionMismatch(String), cancelled }

    private func probe(_ client: PCLabClient) async -> ProbeResult {
        switch await call({ try await client.health() }) {
        case .cancelled:
            return .cancelled
        case .transport(let e):
            return .unreachable(SyncMessages.unreachable(nil) + " (\(e))")
        case .reply(let r):
            guard r.status == 200, let info = try? r.decode(HealthInfo.self), info.ok else {
                return .unreachable("Something answered on the PC Lab's address with HTTP \(r.status), but it is not the PC Lab")
            }
            if let problem = SyncEngine.versionProblem(contract: info.contractVersion, syncAPI: info.syncAPI) {
                return .versionMismatch(problem)
            }
            return .ok
        }
    }

    /// Two sentences as one (either may be nil): none lost, none repeated.
    static func joined(_ a: String?, _ b: String?) -> String? {
        let parts = [a, b].compactMap { $0 }.filter { !$0.isEmpty }
        if parts.count == 2, parts[0] == parts[1] { return parts[0] }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// nil when the PC's majors equal ours. Only the major part must match (ARCHITECTURE.md 5.2 step 4).
    static func versionProblem(contract: String?, syncAPI: String?) -> String? {
        if let contract, VersionText.major(contract) != VersionText.major(ContractInfo.version) {
            return SyncMessages.contractMismatch(pcMajor: VersionText.major(contract))
        }
        if let syncAPI, VersionText.major(syncAPI) != VersionText.major(ContractInfo.syncAPI) {
            return SyncMessages.syncAPIMismatch(pc: syncAPI)
        }
        return nil
    }

    private static func versionMessage(_ err: APIErrorBody?) -> String? {
        guard let err else { return nil }
        switch err.error {
        case "contract_mismatch"?:
            return err.serverContractVersion.map { SyncMessages.contractMismatch(pcMajor: VersionText.major($0)) }
        case "sync_api_mismatch"?:
            return err.serverSyncAPI.map { SyncMessages.syncAPIMismatch(pc: $0) }
        default:
            return nil
        }
    }

    // MARK: - Build

    /// T10002: true when the day's last drop reached the PC less than `dayResendGap` ago and the trigger is not a manual
    /// sync. The day stays dirty (nothing is lost); it goes at the first run after the gap.
    private func dayIsHeld(_ day: LocalDay, trigger: SyncTrigger) -> Bool {
        if trigger == .manual { return false }
        let last = ledger.drops.filter { $0.kind == .day && $0.localDate == day.iso }.map(\.deliveredAt).max()
        guard let last else { return false }
        return clock.now.timeIntervalSince(last) < SyncEngine.dayResendGap
    }

    /// Day drops for dirty days, then stream drops (not on `.rawUpload`), then raw drops (when `raw`: the #74 gate),
    /// each saved to the outbox. A drop that cannot be built is reported as a failure and left for the next sync; it
    /// never blocks the others.
    private func buildAndEnqueue(trigger: SyncTrigger, deadline: Date,
                                 raw rawAllowed: Bool) async -> (failures: [DropFailure], expired: Bool) {
        var out: [DropFailure] = []
        if trigger != .rawUpload {
            let dirty: [LocalDay]
            do { dirty = try await days.dirtyDays() } catch {
                return ([DropFailure(dropId: "days", reason: "Could not list the days to send: \(error)", retryable: true)], false)
            }
            for day in dirty.sorted() {
                if Task.isCancelled || clock.now >= deadline { return (out, true) }
                if dayIsHeld(day, trigger: trigger) { continue }
                do {
                    let bundle = try await days.dayBundle(day)
                    try await outbox.enqueue(try builder.dayDrop(bundle))
                } catch {
                    out.append(DropFailure(dropId: "day_\(day.iso)", reason: "Could not prepare \(day.iso): \(error)",
                                           retryable: true))
                }
            }
        }
        // Streams and raw are keyed by a real strap; with none seen yet there is nothing to build (BRIEF rule).
        guard let strapIds, let strap = try? await strapIds.primaryStrapId() else { return (out, false) }
        if trigger != .rawUpload {
            let ranges: [(kind: StreamKind, from: Int64, to: Int64)]
            do { ranges = try await streams.pendingStreamRanges() } catch {
                out.append(DropFailure(dropId: "streams", reason: "Could not list stream ranges: \(error)", retryable: true))
                return (out, false)
            }
            for r in ranges {
                if Task.isCancelled || clock.now >= deadline { return (out, true) }
                let id = DropIDs.streams(strapId: strap.raw, kind: r.kind, from: r.from, to: r.to)
                do {
                    let csv = try await streams.streamCSV(r.kind, from: r.from, to: r.to)
                    try await outbox.enqueue(try builder.streamsDrop(strapId: strap, kind: r.kind, from: r.from, to: r.to, csv: csv))
                } catch {
                    out.append(DropFailure(dropId: id, reason: "Could not prepare \(r.kind.rawValue) \(r.from)-\(r.to): \(error)",
                                           retryable: true))
                }
            }
        }
        if rawAllowed, let raw {
            let ranges: [(from: Int64, to: Int64)]
            do { ranges = try await raw.pendingRawRanges() } catch {
                return (out + [DropFailure(dropId: "raw", reason: "Could not list raw ranges: \(error)", retryable: true)],
                        false)
            }
            for r in ranges {
                if Task.isCancelled || clock.now >= deadline { return (out, true) }
                let id = DropIDs.raw(strapId: strap.raw, from: r.from, to: r.to)
                do {
                    let file = try await raw.rawFramesFile(from: r.from, to: r.to)
                    guard file.frames > 0 else { continue }
                    try await outbox.enqueue(try builder.rawDrop(strapId: strap, from: r.from, to: r.to,
                                                                frames: file.data, frameCount: file.frames))
                } catch {
                    out.append(DropFailure(dropId: id, reason: "Could not prepare raw \(r.from)-\(r.to): \(error)", retryable: true))
                }
            }
        }
        return (out, false)
    }

    // MARK: - Upload one drop

    private enum StopReason: Equatable {
        case unreachable(String)
        case authFailed
        case versionMismatch(String)
        case budget
        case cancelled
    }

    private enum DropOutcome {
        case delivered([SyncReceipt], warnings: [String])
        case failed(DropFailure)
        case stop(StopReason)
    }

    private enum CallResult {
        case reply(APIReply)
        case transport(TransportError)
        case cancelled
    }

    private func call(_ operation: () async throws -> APIReply) async -> CallResult {
        do {
            return .reply(try await operation())
        } catch let e as TransportError {
            return .transport(e)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .transport(.unreachable("\(error)"))
        }
    }

    private enum Verdict {
        case ok
        case stop(StopReason)
        case fail(String, retryable: Bool)
    }

    private func classify(_ r: APIReply, ok: Set<Int>, what: String) -> Verdict {
        if ok.contains(r.status) { return .ok }
        let err = r.apiError
        let code = err?.error ?? ""
        let reason = err?.reason ?? "HTTP \(r.status)"
        switch r.status {
        case 401:
            return .stop(.authFailed)
        case 409 where code == "contract_mismatch" || code == "sync_api_mismatch":
            return .stop(.versionMismatch(SyncEngine.versionMessage(err) ?? reason))
        case 409 where code == "missing_file":
            return .fail("The PC is missing files of this drop (\(reason)); they are sent again next time", retryable: true)
        case 409:
            return .fail("The PC refused \(what): \(reason)", retryable: false)
        case 422:
            let detail = (err?.errors ?? []).prefix(3).joined(separator: "; ")
            return .fail("The PC rejected \(what) (\(code.isEmpty ? "HTTP 422" : code)): \(reason)"
                         + (detail.isEmpty ? "" : " — \(detail)"), retryable: true)
        case 400, 411, 413:
            return .fail("The PC refused \(what) (\(code.isEmpty ? "HTTP \(r.status)" : code)): \(reason)", retryable: false)
        case 500...599:
            return .fail("The PC Lab had an error on \(what) (HTTP \(r.status)): \(reason)", retryable: true)
        default:
            return .fail("Unexpected HTTP \(r.status) on \(what)", retryable: true)
        }
    }

    private func upload(_ drop: OutboxDrop, client: PCLabClient, deadline: Date) async -> DropOutcome {
        let id = drop.dropId

        // A retry after a lost commit reply, or a drop cut off part-way (T9988): the PC may already hold the whole drop, or
        // some of its files. Ask it, and send only what it lacks (GET /v1/drops/{id} answers 404 with `staged_files`).
        var held: [String: String] = [:]
        if drop.attempts > 0 || isPartial(id) {
            switch await call({ try await client.drop(dropId: id) }) {
            case .cancelled:
                return .stop(.cancelled)
            case .transport(let e):
                return await lostPC(drop, e)
            case .reply(let r):
                if r.status == 401 { return .stop(.authFailed) }
                if r.status == 200, let c = try? r.decode(CommitResponse.self), c.status == "stored", c.dropId == id,
                   SyncEngine.receiptProblems(drop, c.receipts).isEmpty {
                    return await accept(drop, receipts: c.receipts, warnings: c.warnings ?? [])
                }
                // 404 (nothing committed yet), 5xx, or a stored drop that does not match: send what the PC lacks.
                if r.status == 404 { held = r.apiError?.stagedFiles ?? [:] }
            }
        }

        var sentAny = false
        for file in drop.files {
            if Task.isCancelled { if sentAny { setPartial(id, true) }; return .stop(.cancelled) }
            if clock.now >= deadline { if sentAny { setPartial(id, true) }; return .stop(.budget) }
            // The PC holds exactly these bytes already (same sha256): not sent again. Its receipt comes back with the commit,
            // and `receiptProblems` checks it against the phone's own numbers like any other.
            if let have = held[file.name], have.lowercased() == file.sha256.lowercased() { sentAny = true; continue }
            switch await call({ try await client.putFile(dropId: id, file: file) }) {
            case .cancelled:
                if sentAny { setPartial(id, true) }
                return .stop(.cancelled)
            case .transport(let e):
                return await lostPC(drop, e)
            case .reply(let r):
                switch classify(r, ok: [200, 201], what: "the upload of \(file.name)") {
                case .stop(let reason):
                    return .stop(reason)
                case .fail(let message, let retryable):
                    return await fail(drop, message, retryable: retryable)
                case .ok:
                    guard let put = try? r.decode(PutResponse.self) else {
                        return await fail(drop, "The PC's receipt for \(file.name) could not be read", retryable: true)
                    }
                    if let problem = SyncEngine.receiptProblem(put.receipt, file: file, dropId: id) {
                        return await fail(drop, "The PC's receipt does not match what was sent: \(problem)", retryable: true)
                    }
                    sentAny = true
                }
            }
        }

        if Task.isCancelled { setPartial(id, true); return .stop(.cancelled) }
        switch await call({ try await client.commit(dropId: id, manifest: drop.manifest) }) {
        case .cancelled:
            setPartial(id, true)
            return .stop(.cancelled)
        case .transport(let e):
            return await lostPC(drop, e)
        case .reply(let r):
            switch classify(r, ok: [200], what: "the commit") {
            case .stop(let reason):
                return .stop(reason)
            case .fail(let message, let retryable):
                return await fail(drop, message, retryable: retryable)
            case .ok:
                guard let c = try? r.decode(CommitResponse.self) else {
                    return await fail(drop, "The PC's commit reply could not be read", retryable: true)
                }
                guard c.status == "stored" else {
                    return await fail(drop, "The PC did not store the drop (status \"\(c.status)\")", retryable: true)
                }
                guard c.dropId == id else {
                    return await fail(drop, "The PC's commit reply is for another drop (\(c.dropId))", retryable: true)
                }
                let problems = SyncEngine.receiptProblems(drop, c.receipts)
                guard problems.isEmpty else {
                    return await fail(drop, "The PC's receipts do not match what was sent: " + problems.joined(separator: "; "),
                                      retryable: true)
                }
                return await accept(drop, receipts: c.receipts, warnings: c.warnings ?? [])
            }
        }
    }

    /// Marks the drop delivered (MGStore re-checks every file's receipt before it agrees).
    private func accept(_ drop: OutboxDrop, receipts: [SyncReceipt], warnings: [String]) async -> DropOutcome {
        let mine = receipts.filter { r in drop.files.contains { $0.name == r.name } }
        do {
            try await outbox.markDelivered(drop.dropId, receipts: mine)
            setPartial(drop.dropId, false)
            return .delivered(mine, warnings: warnings)
        } catch {
            return await fail(drop, "The outbox did not accept the receipts: \(error)", retryable: true)
        }
    }

    private func fail(_ drop: OutboxDrop, _ message: String, retryable: Bool) async -> DropOutcome {
        _ = try? await outbox.markFailed(drop.dropId, error: message)
        failures[drop.dropId] = (clock.now, drop.attempts + 1)
        return .failed(DropFailure(dropId: drop.dropId, reason: message, retryable: retryable))
    }

    /// The PC stopped answering in the middle of a drop: count the failed attempt and end this sync.
    private func lostPC(_ drop: OutboxDrop, _ error: TransportError) async -> DropOutcome {
        let why = SyncMessages.unreachable(nil) + " (\(error))"
        _ = try? await outbox.markFailed(drop.dropId, error: "Lost the PC while sending: \(error)")
        failures[drop.dropId] = (clock.now, drop.attempts + 1)
        return .stop(.unreachable(why))
    }

    // MARK: - Receipts (5.5)

    /// nil when `receipt` is the PC's receipt for exactly `file`: same name, bytes, sha256 and records (and drop id, when
    /// the PC says one).
    static func receiptProblem(_ receipt: SyncReceipt, file: OutboxFile, dropId: String) -> String? {
        var problems: [String] = []
        if receipt.name != file.name { problems.append("name \(receipt.name ?? "none") != \(file.name)") }
        if receipt.bytes != file.bytes { problems.append("\(file.name): PC counted \(receipt.bytes) bytes, sent \(file.bytes)") }
        if receipt.sha256.lowercased() != file.sha256.lowercased() {
            problems.append("\(file.name): PC hashed \(receipt.sha256.prefix(12))…, sent \(file.sha256.prefix(12))…")
        }
        if receipt.records != file.records {
            problems.append("\(file.name): PC counted \(receipt.records) records, sent \(file.records)")
        }
        if let d = receipt.dropId, d != dropId { problems.append("\(file.name): receipt is for drop \(d)") }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    /// Every file of the drop needs a matching receipt; receipts for other files are ignored.
    static func receiptProblems(_ drop: OutboxDrop, _ receipts: [SyncReceipt]) -> [String] {
        drop.files.compactMap { file -> String? in
            guard let r = receipts.first(where: { $0.name == file.name }) else { return "no receipt for \(file.name)" }
            return receiptProblem(r, file: file, dropId: drop.dropId)
        }
    }

    // MARK: - Retry delay (5.5: exponential backoff 1 min -> 1 h)

    /// The ladder step for the n-th failure in a row (1 -> 1 min, 2 -> 2, 3 -> 5, 4 -> 15, 5 and more -> 60).
    static func backoffDelay(failedAttempts: Int) -> TimeInterval {
        retryLadder[min(retryLadder.count - 1, max(0, failedAttempts - 1))]
    }

    /// A failed sync (PC unreachable, key refused): count it and set when background triggers may try again.
    private func noteFailure(_ why: String) {
        var s = st
        s.consecutiveFailures += 1
        s.nextRetryAt = clock.now.addingTimeInterval(SyncEngine.backoffDelay(failedAttempts: s.consecutiveFailures))
        s.lastError = why
        s.lastErrorAt = clock.now
        st = s
    }

    /// An error that is not a retry matter (version mismatch): kept for the sync panel only.
    private func recordError(_ why: String) {
        var s = st
        s.lastError = why
        s.lastErrorAt = clock.now
        st = s
    }

    // MARK: - Sync panel, reset, "PC not receiving" (P9734)

    /// Settings > Strap & sync > phone-to-PC panel. Reads the outbox; talks to nobody.
    public func panel(stallAfterHours: Double = 3) async -> SyncPanel {
        await ensureLedger()
        let pending = (try? await outbox.pending()) ?? []
        let s = st
        let now = clock.now
        var stalledSince: Date?
        var waiting = !pending.isEmpty
        if !waiting { waiting = (await unsyncedDayCount(pending: pending) ?? 0) > 0 }
        // Evidence the PC was actually tried and did not take it (not just a phone that was closed for a night).
        let triedAndFailed = s.consecutiveFailures > 0 || pending.contains { $0.attempts > 0 }
        if waiting, triedAndFailed {
            // Counted from the later of the last acceptance and when the oldest waiting drop was built, so a drop built a
            // minute ago is not "stuck" just because the PC was idle for a day.
            let ref = max(s.lastAcceptedAt ?? ledger.lastSynced ?? .distantPast, pending.map { $0.createdAt }.min() ?? .distantPast)
            let since = ref == .distantPast ? s.lastErrorAt : ref
            if let since, now.timeIntervalSince(since) >= stallAfterHours * 3600 { stalledSince = since }
        }
        return SyncPanel(
            state: status.state, pcName: status.pcName, lastSuccess: ledger.lastSynced,
            lastAcceptedAt: s.lastAcceptedAt, queueDrops: pending.count,
            queueBytes: pending.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.bytes } },
            bytesDelivered: s.bytesDelivered, lastError: s.lastError ?? status.error, lastErrorAt: s.lastErrorAt,
            nextRetryAt: s.nextRetryAt, consecutiveFailures: s.consecutiveFailures, authFailures: s.authFailures,
            authFailuresToRepair: SyncEngine.authFailuresToRepair, needsRepair: s.needsRepair, stalledSince: stalledSince,
            banner: stalledSince.map { SyncMessages.pcNotReceiving(since: $0, now: now) },
            lastStop: s.lastStop, lastStopAt: s.lastStopAt)
    }

    /// Settings > "Reset": clears the re-pair latch, the auth counter, the retry ladder and the in-memory drop delays, then
    /// tries once. It never deletes queued data (the outbox is not touched; failed attempt counts stay as history).
    public func resetSync(budget: Duration = .seconds(60)) async -> SyncOutcome {
        await ensureLedger()
        var s = st
        s.needsRepair = false
        s.authFailures = 0
        s.consecutiveFailures = 0
        s.nextRetryAt = nil
        st = s
        failures.removeAll()
        await persistLedger()
        return await sync(.manual, budget: budget)
    }

    /// Bytes still in the outbox (what a stopped sync left).
    private func queuedBytes() async -> Int {
        let pending = (try? await outbox.pending()) ?? []
        return pending.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.bytes } }
    }

    private func isPartial(_ id: String) -> Bool { (st.partialDrops ?? []).contains(id) }

    private func setPartial(_ id: String, _ partial: Bool) {
        var s = st
        var list = s.partialDrops ?? []
        if partial { if !list.contains(id) { list.append(id) } } else { list.removeAll { $0 == id } }
        s.partialDrops = list.isEmpty ? nil : Array(list.suffix(200))
        st = s
    }

    private func isBackedOff(_ drop: OutboxDrop, bypass: Bool) -> Bool {
        guard !bypass, let last = failures[drop.dropId] else { return false }
        return clock.now < last.at.addingTimeInterval(SyncEngine.backoffDelay(failedAttempts: max(last.attempts, drop.attempts)))
    }

    /// T9988: one drop of each kind in turn (day, streams, raw, day, ...), each kind in `uploadOrder`. Day drops used to go
    /// first and all of them: every sync rebuilt the dirty days as new drops, so a short sync never reached streams or
    /// raw. A day drop that a newer drop of the same day replaces goes last (the PC takes the day version with the latest
    /// `generated_at`, so the late arrival of the old one changes nothing there).
    static func interleaved(_ drops: [OutboxDrop]) -> [OutboxDrop] {
        let sorted = drops.sorted(by: uploadOrder)
        var newestDay: [String: Date] = [:]
        for d in sorted where d.kind == .day {
            let key = d.localDay?.iso ?? d.dropId
            if let seen = newestDay[key], seen >= d.createdAt { continue }
            newestDay[key] = d.createdAt
        }
        func superseded(_ d: OutboxDrop) -> Bool {
            d.kind == .day && (newestDay[d.localDay?.iso ?? d.dropId].map { $0 > d.createdAt } ?? false)
        }
        var queues: [[OutboxDrop]] = [
            sorted.filter { $0.kind == .ecg },      // T9821: a few hundred KB at most; goes first
            sorted.filter { $0.kind == .day && !superseded($0) },
            sorted.filter { $0.kind == .streams },
            sorted.filter { $0.kind == .raw },
        ]
        var out: [OutboxDrop] = []
        while queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where !queues[i].isEmpty { out.append(queues[i].removeFirst()) }
        }
        return out + sorted.filter(superseded)
    }

    /// Day drops first (by day), then streams (by strap time), then raw; ties by creation time and id.
    static func uploadOrder(_ a: OutboxDrop, _ b: OutboxDrop) -> Bool {
        func rank(_ k: DropKind) -> Int { k == .ecg ? -1 : (k == .day ? 0 : (k == .streams ? 1 : 2)) }
        if rank(a.kind) != rank(b.kind) { return rank(a.kind) < rank(b.kind) }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.dropId < b.dropId
    }

    // MARK: - Results (5.6)

    /// The last poll's `primary_problem`, as a sentence (nil = none).
    private var mapProblem: String?
    /// V3SYNC: results the store refused in this pass (kept as error results); reported as warnings, not as a failed pull.
    private var resultNotes: [String] = []

    /// Decodes one fetched result file and stores it in its slot. nil = stored (the caller counts it); a sentence = the
    /// store failed even for the error placeholder, so the pass stops. Shared by the bundle and the per-file path.
    private func applyResult(_ item: ResultItem, day: LocalDay, body: Data) async -> String? {
        var result: LabResult
        do {
            result = try MGJSON.decoder().decode(LabResult.self, from: body)
        } catch {
            // Keep the slot (and the cursor moving) with a visible error result instead of losing it (R6).
            result = LabResult(modelId: item.modelId, modelVersion: item.modelVersion, date: day, metrics: [],
                               inputsHash: item.inputsHash, status: "error",
                               reason: "The result file could not be read by the app: \(error)")
        }
        // The body must be the result the index promised (model, version, day), or a swapped file would be stored.
        // A mismatch is stored as an error result in the slot the list named (never the swapped body), so the
        // cursor still advances past it instead of every later sync stopping here.
        if result.modelId != item.modelId || result.modelVersion != item.modelVersion || result.date != day {
            result = LabResult(modelId: item.modelId, modelVersion: item.modelVersion, date: day, metrics: [],
                               inputsHash: item.inputsHash, status: "error",
                               reason: "Result \(item.name) held \(result.modelId)@\(result.modelVersion) for \(result.date), not what the list said; the body was not stored")
        }
        if result.inputsHash == nil { result.inputsHash = item.inputsHash }
        do {
            try await results.store(result, sha256: item.sha256.lowercased(), seq: item.seq)
            return nil
        } catch {
            // V3SYNC: a result the store refuses (MGStore throws `invalidMetric` for a bad imported metric) used to
            // end the pass here, so the cursor never passed it and no later result ever arrived (2026-10-14:
            // pc.history 2026-09-13 seq 15638, metric variant "apple"). Keep it as a visible error result in its
            // slot, like a body the app cannot read, so the cursor moves on; the refusal is shown as a warning.
            let why = "Result \(item.name) for \(item.date) was refused by the phone's store, kept as an error result: \(error)"
            let placeholder = LabResult(modelId: item.modelId, modelVersion: item.modelVersion, date: day, metrics: [],
                                        inputsHash: item.inputsHash, status: "error", reason: why)
            do {
                try await results.store(placeholder, sha256: item.sha256.lowercased(), seq: item.seq)
                resultNotes.append(why)
                return nil
            } catch {
                return "Result \(item.name) could not be stored: \(error)"
            }
        }
    }

    /// T9809: the PC's primary-source map rides on the results poll; a PC without it (nil) leaves the stored map alone.
    /// A PC that reports `primary_problem` (bad file) never replaces the last good map; the error is shown instead.
    private func applyPrimary(_ map: [String: String]?, problem: String?) {
        mapProblem = nil
        if let bad = problem {
            mapProblem = "The PC's primary-source map is not valid, so the last good one stays: \(bad)"
        } else if let map, map != ledger.primary {
            ledger.primary = map
            ledgerDirty = true
        }
    }

    /// Round 8 (audit 4.4): the PC logged phones whose results cursor kept restarting at 0 and re-reading everything.
    /// A pass that starts below where the last one started, or on a PC whose newest seq is below the phone's cursor, says
    /// so in the sync log with the reason.
    private func noteResultsCursor(since: Int, head: Int, route: String) async {
        if let was = ledger.lastResultsSince, since < was {
            await syncLog("results cursor restarted: this pass starts at \(since), the last one started at \(was). The phone's "
                          + "result store is behind its saved cursor (cleared, reinstalled or restored), so results are read again from \(since) [\(route)]")
        }
        if head < since {
            let why = "The PC's newest result number (\(head)) is below the phone's (\(since)): the PC's results index was reset, so newer results arrive only once it passes \(since)"
            await syncLog(why)
            resultNotes.append(why)
        }
        if ledger.lastResultsSince != since {
            ledger.lastResultsSince = since
            ledgerDirty = true
        }
    }

    private func syncLog(_ text: String) async { await onLog?(text) }

    /// Content bytes asked per bundle page; the PC always sends at least one item.
    static let bundleMaxBytes = 2 * 1024 * 1024
    /// Pages one pass may fetch (stop condition for the loop; 400 pages is far more than 6 days of results).
    static let bundleMaxPages = 400
    /// A PC Lab that answered 404 to the bundle route is not asked again until the app relaunches.
    private var bundleUnsupported = false

    /// Round 8 (audit top-25 #22): results come in bundles (`GET /v1/results/bundle`, one GET per page of up to
    /// `bundleMaxBytes` of files instead of one GET per file); a PC Lab without the route (404) is read the old way.
    private func fetchResults(client: PCLabClient, deadline: Date) async -> (fetched: Int, stop: StopReason?, problem: String?) {
        if !bundleUnsupported, let r = await fetchResultsBundle(client: client, deadline: deadline) { return r }
        return await fetchResultsPerFile(client: client, deadline: deadline)
    }

    /// nil = this PC Lab has no bundle route (the caller falls back to the per-file path).
    private func fetchResultsBundle(client: PCLabClient, deadline: Date) async -> (fetched: Int, stop: StopReason?, problem: String?)? {
        var fetched = 0
        var since = await results.resultsCursor
        var pages = 0
        mapProblem = nil
        while true {
            if Task.isCancelled { return (fetched, .cancelled, nil) }
            if clock.now >= deadline { return (fetched, .budget, nil) }
            let page: ResultsBundlePage
            let contents: [Data?]
            switch await call({ try await client.resultsBundle(since: since, maxBytes: SyncEngine.bundleMaxBytes) }) {
            case .cancelled:
                return (fetched, .cancelled, nil)
            case .transport(let e):
                return (fetched, .unreachable(SyncMessages.unreachable(nil) + " (\(e))"), nil)
            case .reply(let r):
                if r.status == 404 && pages == 0 {
                    bundleUnsupported = true
                    await syncLog("PC Lab has no results bundle route (HTTP 404): reading results one file at a time; restart PC Lab to get the new route")
                    return nil
                }
                switch classify(r, ok: [200], what: "the results bundle") {
                case .stop(let reason): return (fetched, reason, nil)
                case .fail(let message, _): return (fetched, nil, message)
                case .ok: break
                }
                guard let decoded = try? r.decode(ResultsBundlePage.self) else {
                    return (fetched, nil, "The PC's results bundle could not be read")
                }
                page = decoded
                contents = ResultsBundlePage.contents(of: r.body)
            }
            guard contents.count == page.items.count else {
                return (fetched, nil, "The PC's results bundle held \(page.items.count) items but \(contents.count) files")
            }
            if pages == 0 { await noteResultsCursor(since: since, head: page.seq, route: "bundle") }
            applyPrimary(page.primary, problem: page.primaryProblem)
            if let missing = page.missingFiles, missing > 0 {
                resultNotes.append("The PC could not find \(missing) result file(s) it had listed; they arrive when it has them")
            }
            // In seq order, so the stored cursor (highest seq) never skips a result.
            let todo = zip(page.items, contents).filter { $0.0.seq > since }.sorted { $0.0.seq < $1.0.seq }
            for (n, entry) in todo.enumerated() {
                let (item, content) = entry
                if Task.isCancelled { return (fetched, .cancelled, nil) }
                await onProgress?(SyncProgress(phase: .fetchingResults, done: fetched, total: fetched + todo.count - n))
                guard let day = LocalDay(iso: item.date) else {
                    return (fetched, nil, "Result \(item.name) has a bad date (\(item.date))")
                }
                // The bundle carries the newest file for the name, so its bytes can be newer than the index item's
                // sha256 (RESULTS-BUNDLE.md): the content is what is checked (model, version, day), not the item's hash.
                if let problem = await applyResult(item, day: day, body: content ?? Data()) { return (fetched, nil, problem) }
                fetched += 1
            }
            if page.complete { return (fetched, nil, nil) }
            // Watchdog: a page that does not move the cursor forward would repeat for ever.
            guard page.nextSince > since else {
                return (fetched, nil, "The PC's results bundle did not move forward (next \(page.nextSince) after \(since))")
            }
            pages += 1
            if pages >= SyncEngine.bundleMaxPages {
                return (fetched, nil, "The PC's results bundle needed more than \(SyncEngine.bundleMaxPages) pages; the rest follows next sync")
            }
            since = page.nextSince
        }
    }

    private func fetchResultsPerFile(client: PCLabClient, deadline: Date) async -> (fetched: Int, stop: StopReason?, problem: String?) {
        let since = await results.resultsCursor
        let index: ResultsIndex
        switch await call({ try await client.results(since: since) }) {
        case .cancelled:
            return (0, .cancelled, nil)
        case .transport(let e):
            return (0, .unreachable(SyncMessages.unreachable(nil) + " (\(e))"), nil)
        case .reply(let r):
            switch classify(r, ok: [200], what: "the results list") {
            case .stop(let reason): return (0, reason, nil)
            case .fail(let message, _): return (0, nil, message)
            case .ok: break
            }
            guard let decoded = try? r.decode(ResultsIndex.self) else { return (0, nil, "The PC's results list could not be read") }
            index = decoded
        }
        await noteResultsCursor(since: since, head: index.seq, route: "per-file list")
        applyPrimary(index.primary, problem: index.primaryProblem)

        var fetched = 0
        // In seq order, stopping at the first problem, so the stored cursor (highest seq) never skips a result.
        let todo = index.items.filter({ $0.seq > since }).sorted(by: { $0.seq < $1.seq })
        for item in todo {
            if Task.isCancelled { return (fetched, .cancelled, nil) }
            if clock.now >= deadline { return (fetched, .budget, nil) }
            await onProgress?(SyncProgress(phase: .fetchingResults, done: fetched, total: todo.count))
            guard let day = LocalDay(iso: item.date) else {
                return (fetched, nil, "Result \(item.name) has a bad date (\(item.date))")
            }
            switch await call({ try await client.result(date: item.date, name: item.name) }) {
            case .cancelled:
                return (fetched, .cancelled, nil)
            case .transport(let e):
                return (fetched, .unreachable(SyncMessages.unreachable(nil) + " (\(e))"), nil)
            case .reply(let r):
                switch classify(r, ok: [200], what: "result \(item.name)") {
                case .stop(let reason): return (fetched, reason, nil)
                case .fail(let message, _): return (fetched, nil, message)
                case .ok: break
                }
                guard r.body.count == item.bytes, SyncHash.sha256Hex(r.body) == item.sha256.lowercased() else {
                    return (fetched, nil, "Result \(item.name) failed its checksum; it is fetched again next time")
                }
                if let problem = await applyResult(item, day: day, body: r.body) { return (fetched, nil, problem) }
                fetched += 1
            }
        }
        return (fetched, nil, nil)
    }

    // MARK: - Profile (wave 2, 2026-10-11)

    /// PUT /v1/profile when the profile differs from the one the PC last stored (`ledger.profileSha`). An empty profile
    /// is not sent. Returns a sentence when it could not go (a PC Lab without the route says to restart it).
    private func pushProfile(client: PCLabClient) async -> String? {
        guard let source = profileSource, let profile = await source(), !SyncEngine.isEmpty(profile) else { return nil }
        guard let body = try? MGJSON.encoder().encode(profile) else { return "The profile could not be encoded" }
        let sha = SyncHash.sha256Hex(body)
        if ledger.profileSha == sha { return nil }
        await onProgress?(SyncProgress(phase: .profile, done: 0, total: 1))
        switch await call({ try await client.putProfile(body) }) {
        case .cancelled:
            return nil
        case .transport(let e):
            return "The profile did not reach the PC (\(e)); it goes again at the next sync"
        case .reply(let r):
            if r.status == 404 {
                return "PC Lab has no /v1/profile yet: restart PC Lab so it gets the new route; the profile goes then"
            }
            guard r.status == 200 else {
                let why = r.apiError?.errors?.joined(separator: "; ") ?? r.apiError?.reason ?? "HTTP \(r.status)"
                return "The PC did not store the profile: \(why)"
            }
            ledger.profileSha = sha
            ledgerDirty = true
            return nil
        }
    }

    /// A profile with no field filled in (nothing for the PC to use).
    static func isEmpty(_ p: Profile) -> Bool {
        p.birthDate == nil && p.sex == nil && p.heightCm == nil && p.weightKg == nil && p.hrMaxMeasured == nil
            && p.hrRestBaseline == nil && (p.medications ?? []).isEmpty && p.fitzpatrickSkinType == nil
            && p.vitaminDLocation == nil && (p.bodySizes ?? [:]).isEmpty
    }

    // MARK: - Ledger and status helpers

    private func ensureLedger() async {
        guard !ledgerLoaded else { return }
        ledgerLoaded = true
        ledger = SyncLedger.decode(await ledgerStore.load())
    }

    private func persistLedger() async {
        guard ledgerLoaded, ledgerDirty else { return }
        ledger.prune(today: LocalDay(date: clock.now, calendar: calendar))
        if let data = try? ledger.encoded() {
            do {
                try await ledgerStore.save(data)
                ledgerDirty = false
            } catch {
                // Not fatal: delivery is recorded in the outbox. Freshness shows "unknown" until the next save works.
            }
        }
    }

    private func recordDelivered(_ drop: OutboxDrop) {
        guard let manifest = try? MGJSON.decoder().decode(SyncManifest.self, from: drop.manifest) else { return }
        let generated = RFC3339.parse(manifest.generatedAt) ?? clock.now
        ledger.record(SyncLedger.Drop(
            dropId: drop.dropId, kind: drop.kind, localDate: manifest.localDate, generatedAt: generated,
            deliveredAt: clock.now, files: drop.files.map { LedgerFile(name: $0.name, sha256: $0.sha256) }))
        ledgerDirty = true
    }

    private func noteReachable(_ reachable: Bool) async {
        guard lastReachable != reachable else { return }
        lastReachable = reachable
        await notifier.reachabilityChanged(reachable)
    }

    /// Distinct local days that still have something to send: dirty days plus days of undelivered day / stream drops.
    private func unsyncedDayCount(pending: [OutboxDrop]?) async -> Int? {
        guard let dirty = try? await days.dirtyDays() else { return nil }
        let waiting: [OutboxDrop]
        if let pending { waiting = pending } else {
            guard let p = try? await outbox.pending() else { return nil }
            waiting = p
        }
        var set = Set(dirty.map(\.iso))
        for drop in waiting where drop.kind != .raw {
            if let day = drop.localDay { set.insert(day.iso) }
        }
        return set.count
    }
}

/// Totals of one sync's delivered drops, for the batched SYNC_RECEIPT notification ("PC got 3 h of data (412 KB)").
private struct DeliveryAccumulator {
    var pcName: String?
    var drops = 0
    var files = 0
    var bytes = 0
    var records = 0
    var rangeStart: Date?
    var rangeEnd: Date?
    var lastReceipt: SyncReceipt?

    init(pcName: String?) { self.pcName = pcName }

    mutating func add(_ drop: OutboxDrop, receipts: [SyncReceipt]) {
        drops += 1
        files += drop.files.count
        bytes += drop.files.reduce(0) { $0 + $1.bytes }
        records += drop.files.reduce(0) { $0 + $1.records }
        for r in receipts {
            if rangeStart == nil || r.rangeStart < rangeStart! { rangeStart = r.rangeStart }
            if rangeEnd == nil || r.rangeEnd > rangeEnd! { rangeEnd = r.rangeEnd }
            if lastReceipt == nil || r.receivedAt >= lastReceipt!.receivedAt { lastReceipt = r }
        }
    }

    var summary: DeliverySummary? {
        drops == 0 ? nil : DeliverySummary(drops: drops, files: files, bytes: bytes, records: records,
                                           rangeStart: rangeStart, rangeEnd: rangeEnd, pcName: pcName)
    }
}
