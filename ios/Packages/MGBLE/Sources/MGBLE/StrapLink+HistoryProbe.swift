import Foundation
import MGDomain
import WhoopProtocol

// "Test: read history without deleting" (wave W12b, tracker #111/#119; Mo 2026-10-11 ~23:30 PT: "read without deleting
// of course"). A research test of what the strap does when a chunk is received but NOT acknowledged:
//
//   1. GET_DATA_RANGE (34 [00], a read): the read-page cursor (body offset 5) and the acknowledged/trim boundary (13)
//   2. SEND_HISTORICAL_DATA (22)
//   3. receive the first chunk (START … END) and STORE it like any history chunk — never send HISTORICAL_DATA_RESULT (23)
//   4. ABORT_HISTORICAL_TRANSMITS (20): a stop request, not a trim
//   5. GET_DATA_RANGE again
//   6. the same request again (22 → first chunk, stored → 20), byte-compared with the first, then GET_DATA_RANGE once more
//
// It never loses data: everything received is stored (the store is idempotent: the normal download later stores the
// same chunk as a duplicate and acks it), and nothing is acknowledged, so the strap keeps it too. FORCE_TRIM (25) and
// SET_READ_POINTER (33) are not sent by this test (T87: nothing forbids them any more); no other command is sent. The normal download refuses to start
// while this runs (`downloadHistory` guards `historyProbe == nil`), and this refuses while a download runs.
// app/tools/check_strap_safety.py rule DATA-RANGE-PROBE pins all of that.
//
// Sources (live, ryanbr/noop @ e580175): docs/PROTOCOL_TRANSPORT.md "Data range — command 34" (65-byte SUCCESS body:
// revision 1, boundary A @1, read-page cursor B @5, write-page cursor C @9, acknowledged/trim boundary D @13, write-wrap
// @17, capacity @21, record estimate @25; FAILURE = revision 1 + 64 zero bytes; a PENDING reply first) and L443-446
// ("a fresh history attempt starts again from the acknowledged boundary … unacknowledged records can therefore recur");
// docs/BLE_REVERSE_ENGINEERING.md L343-349 (without acking, the strap re-serves the same early chunk; trim_cursor frozen).
// DECODED, untested on Mo's strap until he runs it.

/// A GET_DATA_RANGE reply's ring pointers. Page slots, not times (PROTOCOL_TRANSPORT: "Read and write positions are page
/// slots, not timestamps").
public struct StrapDataRange: Equatable, Sendable {
    public let boundaryA: UInt32
    public let readCursor: UInt32
    public let writeCursor: UInt32
    public let trimBoundary: UInt32
    public let writeWrap: UInt32
    public let capacity: UInt32
    public let recordEstimate: UInt32

    /// (reading, nil) or (nil, why not). Accepted only as a SUCCESS reply to 34 with revision 1, at least the fields up
    /// to the record estimate, and not the all-zero failure body.
    public static func read(_ response: CommandResponse?) -> (StrapDataRange?, String?) {
        guard let r = response else { return (nil, "no reply to GET_DATA_RANGE") }
        guard r.command == 34 else { return (nil, "reply to command \(r.command), not 34") }
        guard r.result == .success else { return (nil, "the strap answered \(r.result.label)") }
        let b = r.body
        guard b.count >= 29 else { return (nil, "reply body \(b.count) bytes, too short for the ring pointers") }
        guard b[0] == 0x01 else { return (nil, "reply revision \(b[0]), not 1") }
        guard b[1...].contains(where: { $0 != 0 }) else { return (nil, "the strap's range read failed (all zero)") }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        }
        return (StrapDataRange(boundaryA: u32(1), readCursor: u32(5), writeCursor: u32(9), trimBoundary: u32(13),
                               writeWrap: u32(17), capacity: u32(21), recordEstimate: u32(25)), nil)
    }

    public var words: String {
        "read cursor \(readCursor) · trim boundary \(trimBoundary) · write cursor \(writeCursor) (of \(capacity) pages)"
    }
}

/// One chunk the test received: its record frames (between START and END) and END token, and what the store did.
public struct HistoryProbeChunk: Equatable, Sendable {
    public var records: [[UInt8]] = []
    public var token: HistoryEndToken?
    public var stored = false
    public var inserted = 0
    public var duplicate = false
    public var problem: String?

    public init() {}
}

public struct HistoryProbeResult: Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var before: StrapDataRange?
    public var afterFirst: StrapDataRange?
    public var afterRepeat: StrapDataRange?
    public var rangeProblems: [String] = []
    public var first = HistoryProbeChunk()
    public var second = HistoryProbeChunk()
    /// Why the test stopped early (link lost, …); nil = it ran every step.
    public var stopped: String?

    public init(startedAt: Date) {
        self.startedAt = startedAt
        self.endedAt = startedAt
    }

    private var readings: [StrapDataRange] { [before, afterFirst, afterRepeat].compactMap { $0 } }

    /// nil = fewer than two readings to compare.
    public var trimMoved: Bool? { readings.count < 2 ? nil : Set(readings.map(\.trimBoundary)).count > 1 }
    public var readCursorMoved: Bool? { readings.count < 2 ? nil : Set(readings.map(\.readCursor)).count > 1 }
    /// The same END token and byte-identical record frames both times; nil = not two chunks to compare.
    public var chunkRepeated: Bool? {
        guard let a = first.token, let b = second.token else { return nil }
        return a == b && first.records == second.records
    }

    /// The result in words, for the Live › Research row.
    public var lines: [String] {
        var out: [String] = []
        func range(_ label: String, _ r: StrapDataRange?) {
            out.append("\(label): " + (r?.words ?? "not read"))
        }
        range("Before", before)
        range("After the first chunk (not acknowledged, then abort)", afterFirst)
        range("After asking again", afterRepeat)
        out.append("Trim boundary moved: " + yesNo(trimMoved) + " · read cursor moved: " + yesNo(readCursorMoved))
        switch chunkRepeated {
        case .some(true):
            out.append("Chunk repeated: yes — the same END token and the same \(first.records.count) record frames")
        case .some(false):
            out.append("Chunk repeated: no — " + (first.token != second.token ? "a different END token"
                                                  : "same END token, different record bytes"))
        case .none:
            out.append("Chunk repeated: can't tell — " + (first.problem ?? second.problem ?? "not two chunks to compare"))
        }
        let stored = [first, second].filter(\.stored)
        out.append("Stored on the phone: \(stored.count) chunk(s), \(stored.map(\.inserted).reduce(0, +)) new records. "
                   + "Nothing was acknowledged, so the strap keeps every record too.")
        out += rangeProblems
        if let stopped { out.append("Stopped early: \(stopped)") }
        return out
    }

    private func yesNo(_ b: Bool?) -> String { b.map { $0 ? "yes" : "no" } ?? "can't tell" }
}

/// The test's frame hand-off (StrapLink+Live routes offload frames here while it runs).
@MainActor
final class HistoryProbe {
    var inbox: FrameInbox?
    var lostReason: String?

    func linkLost(_ reason: String) {
        lostReason = reason
        inbox?.close()
    }
}

extension StrapLink {
    /// Runs the read-without-deleting test. Refuses while a history download, another test or an ECG reading runs.
    public func runHistoryReadTest() async throws -> HistoryProbeResult {
        guard handshakeDone, let sid = strapId else { throw StrapLinkError.notReady("strap not connected") }
        guard historyRun == nil else { throw StrapLinkError.historyInProgress }
        guard historyProbe == nil else { throw StrapLinkError.notReady("the read-without-deleting test is already running") }
        guard ecgReading == nil else { throw StrapLinkError.notReady("an ECG reading is running") }
        if let reason = persistStalledReason { throw StrapLinkError.persistStalled(reason) }
        let probe = HistoryProbe()
        historyProbe = probe
        defer { historyProbe = nil }
        var result = HistoryProbeResult(startedAt: clock.now)
        logLine("history test: start (read without deleting; no 23 ack will be sent)")

        var problems: [String] = []
        result.before = await probeRange(&problems)
        if let lost = probe.lostReason { return probeFinish(result, problems, stopped: lost) }
        result.first = await probeChunk(probe, sid: sid)
        if let lost = probe.lostReason { return probeFinish(result, problems, stopped: lost) }
        await probeSettle()
        result.afterFirst = await probeRange(&problems)
        if let lost = probe.lostReason { return probeFinish(result, problems, stopped: lost) }
        result.second = await probeChunk(probe, sid: sid)
        if let lost = probe.lostReason { return probeFinish(result, problems, stopped: lost) }
        await probeSettle()
        result.afterRepeat = await probeRange(&problems)
        return probeFinish(result, problems, stopped: probe.lostReason)
    }

    private func probeFinish(_ r: HistoryProbeResult, _ problems: [String], stopped: String?) -> HistoryProbeResult {
        var r = r
        r.rangeProblems = problems
        r.stopped = stopped
        r.endedAt = clock.now
        for line in r.lines { logLine("history test: \(line)") }
        return r
    }

    private func probeSettle() async {
        let s = config.timing.probeSettle
        if s > 0 { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    }

    private func probeRange(_ problems: inout [String]) async -> StrapDataRange? {
        do {
            let (reading, why) = StrapDataRange.read(try await channel.send(.sanctioned(.getDataRange),
                                                                            awaitResponse: true))
            if let why { problems.append("GET_DATA_RANGE: \(why)") }
            return reading
        } catch {
            problems.append("GET_DATA_RANGE failed: \(describeError(error))")
            return nil
        }
    }

    /// 22 → the first chunk → store it (never ack) → 20. Frames after the END (a re-sent END, COMPLETE) are dropped
    /// with the closed inbox; the strap keeps them.
    private func probeChunk(_ probe: HistoryProbe, sid: StrapID) async -> HistoryProbeChunk {
        let inbox = FrameInbox()
        probe.inbox = inbox
        var chunk = HistoryProbeChunk()
        do {
            try await channel.send(.sanctioned(.sendHistoricalData), awaitResponse: false)
        } catch {
            probe.inbox = nil
            inbox.close()
            chunk.problem = "SEND_HISTORICAL_DATA failed: \(describeError(error))"
            return chunk
        }
        var open = false
        var frames: [[UInt8]] = []
        receiving: while true {
            switch await inbox.next(timeout: config.timing.historyIdleTimeout) {
            case .closed:
                chunk.problem = probe.lostReason ?? "the link closed"
                break receiving
            case .timeout:
                chunk.problem = "no chunk within \(Int(config.timing.historyIdleTimeout)) s"
                break receiving
            case .frame(let frame):
                guard frame.count > 8 else { continue receiving }
                guard frame[8] == 49 || frame[8] == 56 else {
                    if open { frames.append(frame) }
                    continue receiving
                }
                switch classifyHistoricalMeta(parseFrame(frame, family: .whoop5)) {
                case .start:
                    open = true
                    frames.removeAll(keepingCapacity: true)
                case .end:
                    guard let token = HistoryEndToken(endFrame: frame) else { continue receiving }
                    chunk.records = frames
                    chunk.token = token
                    break receiving
                case .complete:
                    chunk.problem = "the strap had no chunk to send (COMPLETE before any END)"
                    break receiving
                case .other:
                    continue receiving
                }
            }
        }
        probe.inbox = nil
        inbox.close()
        if let token = chunk.token {
            // Stored exactly as a normal download would store it. No ack: the journal says "skipped".
            let at = clock.now
            let data = RecordMapper.historyChunk(frames: chunk.records, token: token, strapId: sid, receivedAt: at,
                                                 wallNow: Int(at.timeIntervalSince1970))
            do {
                let receipt = try await historySink.store(data)
                chunk.stored = true
                chunk.inserted = receipt.inserted
                chunk.duplicate = receipt.duplicate
                try? await historySink.recordAck(chunkId: data.chunkId, result: .skipped, at: clock.now)
            } catch {
                chunk.problem = "store failed (\(describeError(error))); nothing acknowledged, the strap keeps it"
            }
        }
        if probe.lostReason == nil {
            // A stop request, not a trim (noop BLEManager L2690-2697; PROTOCOL_TRANSPORT): nothing unacked is lost.
            _ = try? await channel.send(.sanctioned(.abortHistoricalTransmits), awaitResponse: false)
        }
        return chunk
    }
}
