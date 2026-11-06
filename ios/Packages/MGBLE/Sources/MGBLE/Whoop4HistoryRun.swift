// Ported from ryanbr/noop @ 2a1de76 (main, 2026-10-25): Strand/Collect/Backfiller.swift (`ingest`, `endData`, `finishChunk`:
// persist, then cursor, then ack), Strand/BLE/BLEManager.swift (`ackHistoricalChunk` L2526, `beginBackfill`), docs/PROTOCOL_TRANSPORT.md
// "WHOOP 4 history lifecycle". PolyForm Noncommercial 1.0.0. Required Notice: Copyright 2026 NoopApp.
import Foundation
import MGDomain
import WhoopProtocol

/// WHOOP 4.0 frames → MGDomain records (the 4.0 twin of `RecordMapper`, whose offsets are the 5/MG's +4).
enum Whoop4RecordMapper {
    /// One chunk, closed by a HISTORY_END. EVERY frame of the chunk and the METADATA frames around it go into `rawFrames`, decoded
    /// or not (project rule: archive everything the strap sends, raw), so a chunk the store has committed can be read again from
    /// the raw archive even if a field has no decoder yet (4.0 history v24 SpO₂, skin temperature and respiration stay raw counts
    /// here: decoded, untested). Timestamps use the identity clock reference: a strap whose clock is wrong has its decoded rows
    /// dropped by the plausibility gate, never mis-dated; the raw frames stay.
    static func historyChunk(frames: [[UInt8]], token: HistoryEndToken, strapId: StrapID, receivedAt: Date, wallNow: Int,
                             metaFrames: [[UInt8]]) -> HistoryChunk {
        let parsed = frames.map { parseFrame($0, family: .whoop4) }
        let streams = extractHistoricalStreams(parsed, deviceClockRef: wallNow, wallClockRef: wallNow, family: .whoop4,
                                               wallNow: wallNow)
        let hr = streams.hr.filter { $0.bpm > 0 }.map { HRPoint(ts: Int64($0.ts), bpm: Double($0.bpm), source: .history) }
        var ords = RROrdinals()
        let rr = streams.rr.map { beat -> RRPoint in
            let ts = Int64(beat.ts)
            return RRPoint(ts: ts, ord: ords.next(for: ts), rrMs: Double(beat.rrMs), source: .history)
        }
        let battery: [BatteryReading] = streams.battery.compactMap { b in
            b.soc.map { BatteryReading(ts: Int64(b.ts), percent: $0, charging: b.charging) }
        }
        var events: [StrapEvent] = []
        var raw: [RawFrame] = []
        for (frame, p) in zip(frames, parsed) {
            if frame.count > 4, frame[4] == 48, p.ok, p.crcOK != false, let e = strapEvent(frame: frame, parsed: p),
               isPlausibleHistoricalUnix(Int(e.ts), wallNow: wallNow) {
                events.append(e)
            }
            raw.append(RawFrame(receivedAt: receivedAt, packetType: frame.count > 4 ? Int(frame[4]) : 0, bytes: Data(frame)))
        }
        raw += metaFrames.map { RawFrame(receivedAt: receivedAt, packetType: $0.count > 4 ? Int($0[4]) : 0, bytes: Data($0)) }
        let batch = StrapRecordBatch(strapId: strapId, hr: hr, rr: rr, events: events, battery: battery, rawFrames: raw)
        let stamps = hr.map(\.ts) + rr.map(\.ts) + events.map(\.ts)
        let endToken = Data(token.bytes)
        return HistoryChunk(chunkId: HistoryChunk.makeID(strapId: strapId, endToken: endToken), strapId: strapId,
                            endToken: endToken, trim: token.trim, firstTs: stamps.min(), lastTs: stamps.max(), records: batch,
                            frameCount: frames.count)
    }

    /// EVENT (type 48) on a 4.0: number at frame[6], strap RTC unix seconds at 8 (WhoopProtocol schema `event_timestamp`).
    static func strapEvent(frame: [UInt8], parsed p: ParsedFrame) -> StrapEvent? {
        guard frame.count > 8 + 4 + 4, let ts = p.parsed["event_timestamp"]?.intValue else { return nil }
        let number = Int(frame[6])
        let name = RecordMapper.eventName(p.parsed["event"]?.stringValue) ?? "EVENT_\(number)"
        let body = Array(frame[7..<(frame.count - 4)])
        return StrapEvent(ts: Int64(ts), number: number, name: name, payloadHex: body.hexLower)
    }
}

/// One WHOOP 4.0 `downloadHistory()`. The ack is sent only after the chunk, raw frames included, is stored:
///
///     idle ─22 [00]─► receiving (open from the outset; START(49/1) only clears what was collected before it)
///     receiving ─type 47/48/50 frames─► kept for the next END (noop: ONE START, then repeated ENDs)
///     receiving ─END(49/2)─► storing ─HistorySink.store returns─► acking ─23 [01]+frame[17..<25], write-ack─► receiving
///        (every END is stored and acked with its own token, an END with no records too; never an abort)
///     receiving ─COMPLETE(49/3)─► re-kick 22 when the trim moved and (new rows, or the strap's newest is > 300 s ahead of ours)
///     receiving ─idle timeout─► one silent retry; with frames seen, a re-kick on the same gap rule; else stalled (no ack)
///     storing ─throws─► ABORT 20, no more acks
///
/// Ack = command 23, which DELETES the chunk on the strap (inventory §5), so the store comes first, always: a store that
/// throws or times out sends no ack (noop PROTOCOL_TRANSPORT.md: "Local storage failure therefore withholds it").
@MainActor
final class Whoop4HistoryRun {
    let inbox = FrameInbox()
    var onProgress: (@MainActor (HistoryProgress) -> Void)?
    private(set) var runsUsed = 0
    let startedAt: Date
    private(set) var lastActivityAt: Date

    private let channel: CommandChannel
    private let sink: any HistorySink
    private let clock: any MGDomain.Clock
    private let strapId: StrapID
    private let timing: StrapTiming
    private let runBudget: Int
    private let ledger: AckedLedger
    private let log: @MainActor (String) -> Void

    private var abortRequested = false
    private var lostReason: String?
    private var chunksStored = 0
    private var chunksAcked = 0
    private var duplicateChunks = 0
    private var recordsInserted = 0
    private var firstTs: Int64?
    private var lastTs: Int64?
    private var lastAck: AckResult?
    private var lastAckAt: Date?
    private var duplicatesInARow = 0
    private let targetTs: Int64
    private var caughtUp = false

    private enum ChunkOutcome {
        case acked(newRows: Int, duplicate: Bool)
        case stop(HistoryEndReason)
    }

    init(channel: CommandChannel, sink: any HistorySink, clock: any MGDomain.Clock, strapId: StrapID, timing: StrapTiming,
         runBudget: Int, ledger: AckedLedger, log: @escaping @MainActor (String) -> Void) {
        self.channel = channel
        self.sink = sink
        self.clock = clock
        self.strapId = strapId
        self.timing = timing
        self.runBudget = runBudget
        self.ledger = ledger
        self.log = log
        self.startedAt = clock.now
        self.lastActivityAt = clock.now
        self.targetTs = Int64(clock.now.timeIntervalSince1970)
    }

    /// Set by the link: false once the connection this run started on is gone, so a late write never reaches a newer one.
    var isCurrent: @MainActor () -> Bool = { true }
    /// Set by the link: the newest record time stored from history before this run (nil = none known), and the strap's newest
    /// stored record (GET_DATA_RANGE; the Bool says whether a fresh read may be sent). Together they decide a re-kick.
    var frontierTs: Int64?
    var rangeNewest: @MainActor (_ allowSend: Bool) async -> Int? = { _ in nil }

    /// Writes only while this run's own connection is the live one; false = nothing was sent.
    private func sendIfCurrent(_ opcode: UInt8, _ payload: [UInt8]) async -> Bool {
        guard lostReason == nil, isCurrent() else { return false }
        return (try? await channel.send(.test(opcode: opcode, payload: payload), awaitResponse: false)) != nil
    }

    func abort() {
        abortRequested = true
        inbox.close()
    }

    func linkLost(_ reason: String) {
        lostReason = reason
        inbox.close()
    }

    func execute() async -> HistorySummary {
        publishProgress()
        var lastTrim: UInt32?
        var emptyGapKicks = 0
        var silentRetries = 0
        runs: while true {
            if abortRequested { return await finishAborted() }
            guard runsUsed < runBudget else { return summary(.chunkCap) }
            runsUsed += 1
            do {
                guard isCurrent() else { return summary(.disconnected(lostReason)) }
                try await channel.send(.test(opcode: Whoop4Command.sendHistoricalData, payload: [0x00]), awaitResponse: false)
            } catch {
                return summary(.disconnected("SEND_HISTORICAL_DATA failed: \(describeError(error))"))
            }
            // noop Backfiller: the stream is open from the outset (`chunkOpen` starts TRUE and stays true after an END): the strap
            // sends ONE START and then repeated ENDs, with the next records following each END. Every frame is collected; every
            // END closes what was collected so far (possibly nothing) and is acked after its own store.
            var chunkFrames: [[UInt8]] = []
            var chunkMeta: [[UInt8]] = []
            var framesThisKick = 0
            var newRowsThisRun = 0
            var trimMovedThisRun = false
            receiving: while true {
                switch await inbox.next(timeout: timing.historyIdleTimeout) {
                case .closed:
                    if abortRequested { return await finishAborted() }
                    return summary(.disconnected(lostReason))
                case .timeout:
                    if framesThisKick == 0, silentRetries < 1, runsUsed < runBudget, lostReason == nil, isCurrent() {
                        silentRetries += 1
                        log("history (4.0): no offload frame for \(Int(timing.historyIdleTimeout)) s after 22 - asking once more")
                        continue runs
                    }
                    if framesThisKick > 0 {
                        let more = await wantsAnotherKick(strict: true, trimMoved: trimMovedThisRun, newRows: newRowsThisRun,
                                                          emptyGapKicks: &emptyGapKicks, allowSend: false)
                        if more, runsUsed < runBudget, lostReason == nil, isCurrent() {
                            log("history (4.0): no offload frame for \(Int(timing.historyIdleTimeout)) s, but the strap still holds "
                                + "newer records and the trim moved - asking again")
                            continue runs
                        }
                    }
                    log("history (4.0): no offload frame for \(Int(timing.historyIdleTimeout)) s - stalled; unacked data stays on the strap")
                    return summary(.stalled)
                case .frame(let frame):
                    lastActivityAt = clock.now
                    guard frame.count > 4 else { continue receiving }
                    framesThisKick += 1
                    guard frame[4] == 49 else {   // not METADATA: a record (47), event (48) or console line (50) of the open chunk
                        chunkFrames.append(frame)
                        continue receiving
                    }
                    switch classifyHistoricalMeta(parseFrame(frame, family: .whoop4)) {
                    case .start:
                        chunkFrames.removeAll(keepingCapacity: true)
                        chunkMeta = [frame]
                    case .end:
                        chunkMeta.append(frame)
                        guard let token = Whoop4Frame.endToken(of: frame) else {
                            log("history (4.0): a HISTORY_END too short to hold its ack block - not stored, not acked")
                            chunkMeta.removeLast()
                            continue receiving
                        }
                        let frames = chunkFrames
                        let meta = chunkMeta
                        chunkFrames.removeAll(keepingCapacity: true)
                        chunkMeta.removeAll(keepingCapacity: true)
                        switch await storeThenAck(frames: frames, meta: meta, token: token) {
                        case .acked(let newRows, let duplicate):
                            newRowsThisRun += newRows
                            if lastTrim != token.trim { trimMovedThisRun = true }
                            lastTrim = token.trim
                            duplicatesInARow = duplicate ? duplicatesInARow + 1 : 0
                            if duplicatesInARow >= timing.maxDuplicateChunksPerRun {
                                let why = "the strap re-sent \(duplicatesInARow) chunks in a row that the phone already holds"
                                log("history (4.0): \(why) - run ended, all of them acked")
                                _ = await finishAborted()
                                return summary(.reserved(why))
                            }
                        case .stop(let reason):
                            return summary(reason)
                        }
                    case .complete:
                        log("history (4.0): run \(runsUsed) ended - \(chunksStored) chunk(s) stored, \(duplicateChunks) already held")
                        let more = await wantsAnotherKick(strict: false, trimMoved: trimMovedThisRun, newRows: newRowsThisRun,
                                                          emptyGapKicks: &emptyGapKicks, allowSend: true)
                        if more && runsUsed < runBudget && lostReason == nil && isCurrent() { continue runs }
                        if !more {
                            caughtUp = true
                            publishProgress()
                        }
                        return summary(more ? .chunkCap : .complete)
                    case .other:
                        chunkMeta.append(frame)
                        continue receiving
                    }
                }
            }
        }
    }

    /// The newest record this link holds from history: the link's value from earlier runs and this run's own newest.
    private var frontier: Int64? {
        switch (frontierTs, lastTs) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// Re-kick 22? Port of noop `BackfillContinuation.shouldAutoContinue` (BLEManager.swift L340-440; ryanbr/noop main): the trim must
    /// have moved this kick, and either new rows were stored (not `strict`: COMPLETE) or the strap's newest record (GET_DATA_RANGE)
    /// is more than `historyBehindGap` ahead of our newest stored one and not a future-dated RTC. A kick started on the gap alone
    /// stored nothing new, so at most `historyEmptyGapKicks` of those in a row (a phantom gap must not spin). Unknown on either
    /// side = no. The run budget is the caller's check.
    private func wantsAnotherKick(strict: Bool, trimMoved: Bool, newRows: Int, emptyGapKicks: inout Int, allowSend: Bool) async -> Bool {
        guard trimMoved, !abortRequested else { return false }
        if newRows > 0 {
            emptyGapKicks = 0
            if !strict { return true }
        }
        guard newRows > 0 || emptyGapKicks < timing.historyEmptyGapKicks else { return false }
        guard let newest = await rangeNewest(allowSend), let ours = frontier else { return false }
        let wall = Int64(clock.now.timeIntervalSince1970)
        guard Int64(newest) <= wall + timing.historyFutureSkew, Int64(newest) - ours > timing.historyBehindGap else { return false }
        if newRows == 0 { emptyGapKicks += 1 }
        return true
    }

    private func storeThenAck(frames: [[UInt8]], meta: [[UInt8]], token: HistoryEndToken) async -> ChunkOutcome {
        let sid = strapId
        let receivedAt = clock.now
        let wallNow = Int(receivedAt.timeIntervalSince1970)
        let chunkId = HistoryChunk.makeID(strapId: sid, endToken: Data(token.bytes))

        // A chunk this app run already stored is acked again at once, not decoded or stored twice (the strap re-serves what a
        // lost ack left behind).
        if ledger.contains(chunkId) {
            if let stop = await sendAck(token, chunkId: chunkId, journalIt: false) { return stop }
            duplicateChunks += 1
            return .acked(newRows: 0, duplicate: true)
        }

        let chunk = Whoop4RecordMapper.historyChunk(frames: frames, token: token, strapId: sid, receivedAt: receivedAt,
                                                    wallNow: wallNow, metaFrames: meta)
        // 1. The durable write, raw frames included. Nothing is acked unless this returns.
        let receipt: StoredChunkReceipt
        let sink = self.sink
        let stored: Result<StoredChunkReceipt, Error>? = await withBoundedStore(timing.historyStoreTimeout) { try await sink.store(chunk) }
        switch stored {
        case nil:
            log("history (4.0): saving \(chunk.chunkId) took more than \(Int(timing.historyStoreTimeout)) s — NOT acked; the strap re-serves it")
            _ = await sendIfCurrent(Whoop4Command.abortHistoricalTransmits, [0x00])
            return .stop(.stalled)
        case .failure(let error)?:
            let reason = "store failed for \(chunk.chunkId): \(describeError(error))"
            log("history (4.0): \(reason) — NOT acked; no more acks on this connection")
            _ = await sendIfCurrent(Whoop4Command.abortHistoricalTransmits, [0x00])
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

        // 2. The ack: `01` + the END's own 8 bytes, written WITH RESPONSE; the write-ack is the delivery proof.
        if let stop = await sendAck(token, chunkId: chunk.chunkId, journalIt: true) { return stop }
        return .acked(newRows: receipt.inserted, duplicate: receipt.duplicate)
    }

    /// Runs the store, giving up after `seconds` (nil). Whichever side finishes first cancels the other, so a finished store
    /// leaves no sleeping timer and a timed-out store is told to stop (a store that cannot be cancelled still commits; it is
    /// just never acked here).
    private func withBoundedStore<T: Sendable>(_ seconds: Double,
                                               _ op: @escaping @MainActor () async throws -> T) async -> Result<T, Error>? {
        await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>?, Never>) in
            let box = OnceBox<T>(cont)
            box.storeTask = Task { @MainActor in
                do { box.finish(.success(try await op())) } catch { box.finish(.failure(error)) }
            }
            box.timerTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                box.finish(nil)
            }
        }
    }

    private final class OnceBox<T: Sendable>: @unchecked Sendable {
        private var cont: CheckedContinuation<Result<T, Error>?, Never>?
        var storeTask: Task<Void, Never>?
        var timerTask: Task<Void, Never>?
        init(_ cont: CheckedContinuation<Result<T, Error>?, Never>) { self.cont = cont }
        func finish(_ r: Result<T, Error>?) {
            guard let c = cont else { return }
            cont = nil
            if r == nil { storeTask?.cancel() } else { timerTask?.cancel() }
            c.resume(returning: r)
        }
    }

    /// Sends 23 for `token`; nil = acked, otherwise the reason to stop. Never acks on a lost run.
    private func sendAck(_ token: HistoryEndToken, chunkId: String, journalIt: Bool) async -> ChunkOutcome? {
        if lostReason != nil || !isCurrent() {
            log("history (4.0): link gone before the ack for \(chunkId) — not acked; the strap re-serves it")
            return .stop(.disconnected(lostReason))
        }
        do {
            guard isCurrent() else { throw CancellationError() }
            try await channel.send(.test(opcode: Whoop4Command.historicalDataResult, payload: Whoop4Frame.historyAckPayload(token)),
                                   awaitResponse: false)
        } catch {
            if journalIt { await journal(chunkId, .writeFailed) }
            return .stop(.disconnected("ack write failed: \(describeError(error))"))
        }
        chunksAcked += 1
        lastActivityAt = clock.now
        if journalIt { await journal(chunkId, .acked) }
        publishProgress()
        return nil
    }

    private func journal(_ chunkId: String, _ result: AckResult) async {
        let at = clock.now
        lastAck = result
        lastAckAt = at
        do { try await sink.recordAck(chunkId: chunkId, result: result, at: at) } catch {
            log("history (4.0): ack journal failed for \(chunkId) (\(result.rawValue)) — \(describeError(error))")
        }
    }

    private func finishAborted() async -> HistorySummary {
        _ = await sendIfCurrent(Whoop4Command.abortHistoricalTransmits, [0x00])
        return summary(.aborted)
    }

    private func publishProgress() {
        onProgress?(HistoryProgress(startedAt: startedAt, chunksStored: chunksStored, recordsStored: recordsInserted,
                                    firstTs: firstTs, newestTs: lastTs, targetTs: targetTs, lastAck: lastAck,
                                    lastAckAt: lastAckAt, caughtUp: caughtUp))
    }

    private func summary(_ reason: HistoryEndReason) -> HistorySummary {
        HistorySummary(startedAt: startedAt, endedAt: clock.now, chunksStored: chunksStored, chunksAcked: chunksAcked,
                       duplicateChunks: duplicateChunks, recordsInserted: recordsInserted, endReason: reason,
                       firstTs: firstTs, lastTs: lastTs)
    }
}
