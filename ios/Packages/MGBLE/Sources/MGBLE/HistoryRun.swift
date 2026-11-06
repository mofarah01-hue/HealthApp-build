import Foundation
import MGDomain
import WhoopProtocol

/// One `downloadHistory()` (ALG-003, APP-003; ARCHITECTURE §4.4.4). The ack is sent only after the durable write:
///
///     idle ─22 [00]─► awaiting START ─START─► receiving ─records─► receiving
///     receiving ─END─► storing ─HistorySink.store returns─► acking ─23 [01]+token, write-ack─► recordAck(.acked)
///     receiving ─COMPLETE─► re-kick 22 if this run moved the trim AND stored new rows (≤ 24 runs/connection), else done
///     any ─60 s without an offload frame─► stalled (no ack; the strap re-serves the chunk next session)
///     storing ─throws─► ABORT 20 [00], persistStalled: no ack now or for the rest of this connection
///
/// T9997 (Oct 16 2026): the store, the ack write and the journal write are each waited for a bounded time; a run that
/// ends for any reason leaves nothing hanging. T10003: a chunk already stored on this app run is acked again without
/// decoding or storing it (`AckedLedger`), and the run logs how many chunks were new, how many re-served, and the
/// strap's trim before and after, so the log shows whether the strap honours our acks.
///
/// Sources: noop:Strand/Collect/Backfiller.swift L361-390 (state machine, token offsets), L584-972 (`finishChunk`:
/// persist → cursor → ack); BLEManager L2504-2505 (ack payload), L2578-2582 (start), L2643-2660 (watchdog),
/// L345-440 (`BackfillContinuation`: cap 24, re-kick only on trim advance + new rows); noop:docs/PROTOCOL_TRANSPORT.md
/// "History sequencing and storage ownership" (ack only after commit; never rebuild the 8 bytes; abort is not a trim).
@MainActor
final class HistoryRun {
    let inbox = FrameInbox()
    var onProgress: (@MainActor (HistoryProgress) -> Void)?
    /// r9q (D-TRENDS-1): a chunk held optical windows the strap flagged 50 Hz (flags bit 7 clear): first window's strap unix
    /// second and how many. Fired once per chunk this run decoded (a duplicate chunk is not decoded, so not reported twice).
    var onFiftyHz: (@MainActor (Int64, Int) -> Void)?
    private(set) var runsUsed = 0

    /// Raw-optical offload watchdog (added 2026-10-11, Mo's brief). Checked at every offload frame while `armed()`
    /// (the raw optical switch is on): a session older than `maxSeconds`, or `maxNoProgress` chunk requests in a row
    /// answered by a chunk this session already acked (or the store already had), trips it — `tripped(reason)` runs
    /// (the link stops raw optical), then ABORT_HISTORICAL_TRANSMITS (20): a stop request, not a trim, so nothing
    /// unacked is lost on the strap.
    struct Watchdog {
        let maxSeconds: Double
        let maxNoProgress: Int
        let armed: @MainActor () -> Bool
        let tripped: @MainActor (String) async -> Void
    }
    var watchdog: Watchdog?
    private var seenTokens: Set<[UInt8]> = []
    /// R22 records (packet 47, layout byte 22 @9) received in this download — kept raw by RecordMapper; counted for
    /// the R22 watch (2026-10-11).
    private var r22Records = 0
    private(set) var chunksWithoutProgress = 0

    private let channel: CommandChannel
    private let sink: any HistorySink
    private let clock: any MGDomain.Clock
    private let strapId: StrapID
    private let timing: StrapTiming
    private let runBudget: Int
    private let log: @MainActor (String) -> Void
    /// Chunks already stored (and so acked or ackable) on this app run, shared by every download of the link (T10003).
    private let ledger: AckedLedger

    private var abortRequested = false
    private var lostReason: String?
    /// T9997: set by `abandon` when a newer `downloadHistory` found this run dead; it must send nothing more.
    private var abandoned = false
    let startedAt: Date
    /// T9997: last frame received or chunk acked — a run that has been silent for a long time is dead.
    private(set) var lastActivityAt: Date
    private var gate: WaitGate?
    private var duplicatesInARow = 0
    private var firstTrim: UInt32?
    private var lastTrimSeen: UInt32?
    private var freshChunks = 0
    private var chunksStored = 0
    private var chunksAcked = 0
    private var duplicateChunks = 0
    private var recordsInserted = 0
    private var firstTs: Int64?
    private var lastTs: Int64?
    private var lastAck: AckResult?
    private var lastAckAt: Date?
    /// T10013 (r8b): the finish line is fixed when the run starts (it used to move to "now" at every progress update, so the
    /// percent could never reach 100 while the strap's newest chunk trailed it).
    private let targetTs: Int64
    private var caughtUp = false
    /// Request→data wait per step (the first frame after a request or an ack), last 50, for diagnosing the tail.
    private(set) var waits = ChunkWaitLog()
    private var waitSince: Date?

    private enum ChunkOutcome {
        case acked(newRows: Int, duplicate: Bool)
        case stop(HistoryEndReason)
    }

    init(channel: CommandChannel, sink: any HistorySink, clock: any MGDomain.Clock, strapId: StrapID,
         timing: StrapTiming, runBudget: Int, ledger: AckedLedger? = nil,   // nil = a fresh ledger (a default AckedLedger() is built off the main actor)
         log: @escaping @MainActor (String) -> Void) {
        self.ledger = ledger ?? AckedLedger()
        self.channel = channel
        self.sink = sink
        self.clock = clock
        self.strapId = strapId
        self.timing = timing
        self.runBudget = runBudget
        self.log = log
        self.startedAt = clock.now
        self.lastActivityAt = clock.now
        self.targetTs = Int64(clock.now.timeIntervalSince1970)
    }

    /// Stop at the next frame boundary; a chunk already being stored is still acked (it is committed).
    func abort() {
        abortRequested = true
        inbox.close()
    }

    func linkLost(_ reason: String) {
        lostReason = reason
        inbox.close()
        gate?.interruptIfAllowed()   // T9997: a write to a dead link never answers; stop waiting for it
    }

    /// T9997: a newer `downloadHistory` found this run silent for too long (app suspended mid-store, a write that never
    /// answered). It ends at its next step and sends nothing more.
    func abandon(_ reason: String) {
        abandoned = true
        lostReason = reason
        inbox.close()
        gate?.interruptIfAllowed()
    }

    /// Pure rule for "this run is dead" (T9997): no activity for `maxIdle` s. Age alone never kills a run (review Oct 16
    /// 2026): a long first download that keeps storing chunks is healthy; `maxAge` is kept for the log line only.
    static func looksDead(idle: Double, age: Double, maxIdle: Double, maxAge: Double) -> Bool {
        idle >= maxIdle
    }

    // MARK: Bounded waits (T9997)

    private final class WaitGate: @unchecked Sendable {
        var done = false
        var timer: Task<Void, Never>?
        var interrupt: (() -> Void)?
        var interruptible = false
        func interruptIfAllowed() { if interruptible { interrupt?() } }
    }

    /// Runs `op`, but gives up waiting after `seconds` (nil = timed out, or interrupted by link loss when
    /// `interruptible`). The operation itself is not cancelled: a store that finishes late still commits, it is just
    /// never acked by this run.
    private func bounded<T>(_ seconds: Double, interruptible: Bool = false,
                            _ op: @escaping @MainActor () async throws -> T) async -> Result<T, Error>? {
        let g = WaitGate()
        g.interruptible = interruptible
        gate = g
        defer { if gate === g { gate = nil } }
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>?, Never>) in
            let finish: (Result<T, Error>?) -> Void = { r in
                if g.done { return }
                g.done = true
                g.timer?.cancel()
                g.interrupt = nil
                cont.resume(returning: r)
            }
            g.interrupt = { finish(nil) }
            Task { @MainActor in
                do { finish(.success(try await op())) } catch { finish(.failure(error)) }
            }
            g.timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                finish(nil)
            }
        }
    }

    private enum SendOutcome { case ok, failed(Error), timedOut }

    private func sendBounded(_ command: StrapCommand) async -> SendOutcome {
        // Review Oct 16 2026: an abandoned or link-lost run sends nothing more. The channel is shared, so a late abort (20)
        // from a dropped run's store timeout would otherwise kill the download that replaced it.
        if abandoned || lostReason != nil { return .timedOut }
        let ch = channel
        let r = await bounded(timing.historyWriteTimeout, interruptible: true) {
            _ = try await ch.send(command, awaitResponse: false)
        }
        switch r {
        case nil: return .timedOut
        case .failure(let e)?: return .failed(e)
        case .success?: return .ok
        }
    }

    func execute() async -> HistorySummary {
        publishProgress()
        var lastTrim: UInt32?
        runs: while true {
            if abortRequested { return await finishAborted() }
            guard runsUsed < runBudget else { return summary(.chunkCap) }
            runsUsed += 1
            switch await sendBounded(.sanctioned(.sendHistoricalData)) {
            case .ok: break
            case .failed(let error):
                return summary(.disconnected("SEND_HISTORICAL_DATA failed: \(describeError(error))"))
            case .timedOut:
                return summary(.disconnected("SEND_HISTORICAL_DATA write got no answer in \(Int(timing.historyWriteTimeout)) s"))
            }
            waitSince = clock.now
            var chunkFrames: [[UInt8]] = []
            var chunkMeta: [[UInt8]] = []       // T9746: METADATA frames (49 / 56) are kept raw with the chunk
            var chunkOpen = false
            var newRowsThisRun = 0
            var trimMovedThisRun = false
            receiving: while true {
                switch await inbox.next(timeout: timing.historyIdleTimeout) {
                case .closed:
                    if abortRequested { return await finishAborted() }
                    return summary(.disconnected(lostReason))
                case .timeout:
                    log("history: no offload frame for \(Int(timing.historyIdleTimeout)) s — stalled; "
                        + "unacked data stays on the strap")
                    return summary(.stalled)
                case .frame(let frame):
                    lastActivityAt = clock.now
                    if let since = waitSince {
                        waitSince = nil
                        noteWait(clock.now.timeIntervalSince(since))
                    }
                    if let reason = watchdogReason() { return await finishWatchdog(reason) }
                    guard frame.count > 8 else { continue receiving }
                    let type = frame[8]
                    if type == 47, frame.count > 9, frame[9] == 22 { r22Records += 1 }
                    guard type == 49 || type == 56 else {   // not METADATA: a record of the open chunk
                        if chunkOpen { chunkFrames.append(frame) }
                        continue receiving
                    }
                    chunkMeta.append(frame)
                    switch classifyHistoricalMeta(parseFrame(frame, family: .whoop5)) {
                    case .start:
                        chunkOpen = true
                        chunkFrames.removeAll(keepingCapacity: true)
                        chunkMeta = [frame]
                    case .end:
                        guard let token = HistoryEndToken(endFrame: frame) else { continue receiving }
                        let frames = chunkFrames
                        let meta = chunkMeta
                        chunkFrames.removeAll(keepingCapacity: true)
                        chunkMeta.removeAll(keepingCapacity: true)
                        switch await storeThenAck(frames: frames, meta: meta, token: token) {
                        case .acked(let newRows, let duplicate):
                            newRowsThisRun += newRows
                            if lastTrim != token.trim { trimMovedThisRun = true }
                            lastTrim = token.trim
                            if firstTrim == nil { firstTrim = token.trim }
                            lastTrimSeen = token.trim
                            duplicatesInARow = duplicate ? duplicatesInARow + 1 : 0
                            if !duplicate { freshChunks += 1 }
                            if duplicatesInARow >= timing.maxDuplicateChunksPerRun {
                                // The strap keeps re-serving what the phone holds; stop asking (a stop request, not a trim).
                                let why = "the strap re-sent \(duplicatesInARow) chunks in a row that the phone already holds "
                                    + "(trim \(firstTrim.map(String.init) ?? "?") to \(token.trim))"
                                log("history: \(why) — run ended, all of them acked")
                                _ = await finishAborted()
                                return summary(.reserved(why))
                            }
                            // Progress = a chunk neither acked earlier this session nor already in the store.
                            let fresh = seenTokens.insert(token.bytes).inserted && !duplicate
                            chunksWithoutProgress = fresh ? 0 : chunksWithoutProgress + 1
                            if let reason = watchdogReason() { return await finishWatchdog(reason) }
                        case .stop(let reason):
                            return summary(reason)
                        }
                    case .complete:
                        log("history: run \(runsUsed) ended — \(freshChunks) new chunk(s), \(duplicateChunks) already held "
                            + "(acked again, not stored again); strap trim "
                            + "\(firstTrim.map(String.init) ?? "-") to \(lastTrimSeen.map(String.init) ?? "-")")
                        let moreLikely = trimMovedThisRun && newRowsThisRun > 0
                        if moreLikely && runsUsed < runBudget { continue runs }
                        if !moreLikely {
                            caughtUp = true       // the strap has nothing more: the words say "caught up to …"
                            publishProgress()
                        }
                        return summary(moreLikely ? .chunkCap : .complete)
                    case .other:
                        continue receiving
                    }
                }
            }
        }
    }

    private func storeThenAck(frames: [[UInt8]], meta: [[UInt8]] = [], token: HistoryEndToken) async -> ChunkOutcome {
        let sid = strapId
        let receivedAt = clock.now
        let wallNow = Int(receivedAt.timeIntervalSince1970)
        let chunkId = HistoryChunk.makeID(strapId: sid, endToken: Data(token.bytes))

        // T10003: a chunk this app run already stored is not decoded or stored again; it is acked again, at once, because the
        // ack is what lets the strap move on (noop Backfiller: re-served chunk is acked, not re-inserted).
        if ledger.contains(chunkId) {
            if let stop = await sendAck(token, chunkId: chunkId, journalIt: false) { return stop }
            duplicateChunks += 1
            return .acked(newRows: 0, duplicate: true)
        }

        // Decode off the main actor (noop Backfiller L603-640); the store → ack order below is unaffected.
        let chunk = await Task.detached(priority: .utility) {
            RecordMapper.historyChunk(frames: frames, token: token, strapId: sid, receivedAt: receivedAt,
                                      wallNow: wallNow, metaFrames: meta)
        }.value

        let fifty = chunk.records.ppg.filter { $0.rateHz == 50 }
        if let first = fifty.map({ $0.ts }).min() { onFiftyHz?(first, fifty.count) }

        // 1. The durable write. Nothing is acked unless this returns. T9997: it is waited for at most
        // `historyStoreTimeout` (an app suspended mid-write never returned and held the whole download open).
        let receipt: StoredChunkReceipt
        let sink = self.sink
        switch await bounded(timing.historyStoreTimeout, { try await sink.store(chunk) }) {
        case nil:
            let reason = "saving \(chunk.chunkId) took more than \(Int(timing.historyStoreTimeout)) s"
            log("history: \(reason) — NOT acked; run ended, the strap re-serves it")
            _ = await sendBounded(.sanctioned(.abortHistoricalTransmits))
            return .stop(.stalled)
        case .failure(let error)?:
            let reason = "store failed for \(chunk.chunkId): \(describeError(error))"
            log("history: \(reason) — NOT acked; no more acks on this connection")
            // A stop request, not a trim: everything unacked stays on the strap and is re-served later.
            _ = await sendBounded(.sanctioned(.abortHistoricalTransmits))
            return .stop(.persistStalled(reason))
        case .success(let r)?:
            receipt = r
        }
        ledger.insert(chunkId)
        chunksStored += 1
        if receipt.duplicate { duplicateChunks += 1 }
        recordsInserted += receipt.inserted
        if let f = chunk.firstTs { firstTs = min(firstTs ?? f, f) }
        if let l = chunk.lastTs { lastTs = max(lastTs ?? l, l) }

        // 2. The ack: [01] + the END's own 8 bytes, written with response. Its write-ack is the delivery proof.
        if let stop = await sendAck(token, chunkId: chunk.chunkId, journalIt: true) { return stop }
        return .acked(newRows: receipt.inserted, duplicate: receipt.duplicate)
    }

    /// Sends 23 for `token`; nil = acked, otherwise the reason to stop. Never acks on a lost or abandoned run (the token
    /// belongs to the connection it came from).
    private func sendAck(_ token: HistoryEndToken, chunkId: String, journalIt: Bool) async -> ChunkOutcome? {
        if abandoned || lostReason != nil {
            log("history: link gone before the ack for \(chunkId) — not acked; the strap re-serves it")
            return .stop(.disconnected(lostReason))
        }
        switch await sendBounded(.sanctioned(.historicalDataResult(token: token))) {
        case .ok:
            break
        case .failed(let error):
            if journalIt { await journal(chunkId, .writeFailed) }
            return .stop(.disconnected("ack write failed: \(describeError(error))"))
        case .timedOut:
            if journalIt { await journal(chunkId, .writeFailed) }
            return .stop(.disconnected(lostReason ?? "ack write got no answer in \(Int(timing.historyWriteTimeout)) s"))
        }
        chunksAcked += 1
        lastActivityAt = clock.now
        waitSince = clock.now      // the next wait: ack → the strap's next data
        if journalIt { await journal(chunkId, .acked) }
        publishProgress()
        return nil
    }

    private func journal(_ chunkId: String, _ result: AckResult) async {
        let at = clock.now
        lastAck = result
        lastAckAt = at
        let sink = self.sink
        switch await bounded(timing.historyStoreTimeout, { try await sink.recordAck(chunkId: chunkId, result: result, at: at) }) {
        case nil:
            log("history: ack journal for \(chunkId) (\(result.rawValue)) took more than \(Int(timing.historyStoreTimeout)) s — skipped")
        case .failure(let error)?:
            log("history: ack journal failed for \(chunkId) (\(result.rawValue)) — \(describeError(error))")
        case .success?:
            break
        }
    }

    private func watchdogReason() -> String? {
        guard let w = watchdog, w.armed() else { return nil }
        let elapsed = clock.now.timeIntervalSince(startedAt)
        if elapsed >= w.maxSeconds {
            return "the history download ran \(Int(elapsed / 60)) min (limit \(Int(w.maxSeconds / 60)) min) with raw optical on"
        }
        if chunksWithoutProgress >= w.maxNoProgress {
            return "\(chunksWithoutProgress) chunk requests in a row brought no new data (the strap re-sent chunks it had "
                + "already sent)"
        }
        return nil
    }

    private func finishWatchdog(_ reason: String) async -> HistorySummary {
        log("history: watchdog — \(reason); raw optical stopped, download stopped (nothing on the strap is lost)")
        await watchdog?.tripped(reason)
        abortRequested = true
        return await finishAborted()
    }

    private func finishAborted() async -> HistorySummary {
        _ = await sendBounded(.sanctioned(.abortHistoricalTransmits))
        return summary(.aborted)
    }

    private func publishProgress() {
        onProgress?(HistoryProgress(startedAt: startedAt, chunksStored: chunksStored, recordsStored: recordsInserted,
                                    firstTs: firstTs, newestTs: lastTs,
                                    targetTs: targetTs,
                                    lastAck: lastAck, lastAckAt: lastAckAt, caughtUp: caughtUp))
    }

    private func noteWait(_ seconds: Double) {
        waits.add(seconds: seconds, step: runsUsed + chunksAcked)
        if seconds >= 2 { log("history: waited \(String(format: "%.1f", seconds)) s for the strap's next data (step \(runsUsed + chunksAcked))") }
    }

    private func summary(_ reason: HistoryEndReason) -> HistorySummary {
        if let line = waits.summaryLine() { log("history: " + line) }
        return HistorySummary(startedAt: startedAt, endedAt: clock.now, chunksStored: chunksStored, chunksAcked: chunksAcked,
                       duplicateChunks: duplicateChunks, recordsInserted: recordsInserted, endReason: reason,
                       firstTs: firstTs, lastTs: lastTs, r22Records: r22Records)
    }
}

/// T10013 (r8b): how long each step waited between asking (request or ack) and the strap's first frame. Bounded to the
/// last `capacity`; `summaryLine` goes into the history log at the end of a run so a slow tail can be told apart from a
/// slow store.
struct ChunkWaitLog: Equatable {
    static let capacity = 50
    struct Item: Equatable { let step: Int; let seconds: Double }
    private(set) var items: [Item] = []
    private(set) var total = 0

    mutating func add(seconds: Double, step: Int) {
        total += 1
        items.append(Item(step: step, seconds: max(0, seconds)))
        if items.count > Self.capacity { items.removeFirst(items.count - Self.capacity) }
    }

    func summaryLine() -> String? {
        guard !items.isEmpty else { return nil }
        let secs = items.map(\.seconds)
        let last = secs.suffix(5).map { String(format: "%.1f", $0) }.joined(separator: " ")
        return "waits request→data: \(total) step(s), longest of the last \(items.count) "
            + "\(String(format: "%.1f", secs.max() ?? 0)) s, last five \(last) s"
    }
}

/// Chunk ids this app run has stored (T10003). A chunk in here was committed before, so a re-serve of it is acked again
/// at once and never decoded or stored twice. Bounded; memory only (a relaunch asks the store, which dedupes by chunk id).
@MainActor
final class AckedLedger {
    static let capacity = 4096
    private var order: [String] = []
    private var ids: Set<String> = []

    func contains(_ chunkId: String) -> Bool { ids.contains(chunkId) }

    func insert(_ chunkId: String) {
        guard ids.insert(chunkId).inserted else { return }
        order.append(chunkId)
        if order.count > Self.capacity { ids.remove(order.removeFirst()) }
    }
}
