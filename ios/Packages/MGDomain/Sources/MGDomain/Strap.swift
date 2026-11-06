import CryptoKit
import Foundation

// Strap records, independent of WhoopProtocol's types: MGBLE maps decoded frames into these, MGStore stores them
// (ARCHITECTURE.md 4.3, 4.5). Timestamps `ts` are the strap clock in unix seconds. CodingKeys use the stream CSV
// column names of ARCHITECTURE.md 5.4 (`StreamKind.csvHeader`).

/// Pseudonymous strap id: `"s_"` + the first 16 hex digits of SHA-256(install salt + peripheral UUID). Never the BLE
/// address or the serial (contract daySummary.strap_id). Coded as a plain string.
public struct StrapID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(raw: String) { self.raw = raw }

    /// The one place the id is derived. Input bytes: the install salt, then the UTF-8 of `peripheralID.uuidString`
    /// (uppercase, as CoreBluetooth reports it).
    public static func derive(installSalt: Data, peripheralID: UUID) -> StrapID {
        var input = installSalt
        input.append(contentsOf: Array(peripheralID.uuidString.utf8))
        let hex = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return StrapID(raw: "s_" + hex.prefix(16))
    }

    public var description: String { raw }

    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

/// Where a sample came from: the 5/MG live stream, a history download, or the standard 0x2A37 HR profile.
public enum StreamSource: String, Codable, Sendable, CaseIterable {
    case live = "live"
    case history = "history"
    case std2A37 = "std_2a37"
}

public struct HRPoint: Codable, Hashable, Sendable {
    public var ts: Int64
    public var bpm: Double
    public var source: StreamSource

    public init(ts: Int64, bpm: Double, source: StreamSource) {
        self.ts = ts
        self.bpm = bpm
        self.source = source
    }
}

/// `ord` = emission order inside one second; the first sort key after `ts` (noop #823, WhoopStore rrInterval.ord).
public struct RRPoint: Codable, Hashable, Sendable {
    public var ts: Int64
    public var ord: Int
    public var rrMs: Double
    public var source: StreamSource

    public init(ts: Int64, ord: Int, rrMs: Double, source: StreamSource) {
        self.ts = ts
        self.ord = ord
        self.rrMs = rrMs
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case ts = "ts"
        case ord = "ord"
        case rrMs = "rr_ms"
        case source = "source"
    }
}

/// One R18 per-second record. `skinTempRaw`, `spo2Byte` are raw strap counts, not °C or % (project rule 4).
public struct R18Second: Codable, Hashable, Sendable {
    public var ts: Int64
    public var hr: Double?
    public var rrCount: Int
    public var gx: Double?
    public var gy: Double?
    public var gz: Double?
    public var steps: Int?
    public var activityClass: Int?
    public var skinTempRaw: Int?
    public var sleepState: Int?
    public var spo2Byte: Int?
    public var optical50Hz: Bool?
    /// Wave 4: the record's own optical signal-quality fields (decoded, untested; research). Not a stream CSV column
    /// (not in CodingKeys): MGStore keeps them in r18_second's `q_*` columns.
    public var quality: R18Quality? = nil
    /// T9746: the strap's own gravity-removed motion magnitude (R18 byte 41, g; decoded, asserted on a fixture by
    /// `DeepCaptureChannelsTests`) and the two auxiliary thermal channels (bytes 69 / 71, raw i16, raw / 10 = °C,
    /// decoded, untested). Not stream CSV columns (not in CodingKeys): MGStore keeps them in r18_second.
    public var dynAccel: Double? = nil
    public var tempAux1Raw: Int? = nil
    public var tempAux2Raw: Int? = nil

    public init(
        ts: Int64,
        hr: Double? = nil,
        rrCount: Int,
        gx: Double? = nil,
        gy: Double? = nil,
        gz: Double? = nil,
        steps: Int? = nil,
        activityClass: Int? = nil,
        skinTempRaw: Int? = nil,
        sleepState: Int? = nil,
        spo2Byte: Int? = nil,
        optical50Hz: Bool? = nil,
        quality: R18Quality? = nil,
        dynAccel: Double? = nil,
        tempAux1Raw: Int? = nil,
        tempAux2Raw: Int? = nil
    ) {
        self.ts = ts
        self.hr = hr
        self.rrCount = rrCount
        self.gx = gx
        self.gy = gy
        self.gz = gz
        self.steps = steps
        self.activityClass = activityClass
        self.skinTempRaw = skinTempRaw
        self.sleepState = sleepState
        self.spo2Byte = spo2Byte
        self.optical50Hz = optical50Hz
        self.quality = quality
        self.dynAccel = dynAccel
        self.tempAux1Raw = tempAux1Raw
        self.tempAux2Raw = tempAux2Raw
    }

    enum CodingKeys: String, CodingKey {
        case ts = "ts"
        case hr = "hr"
        case rrCount = "rr_count"
        case gx = "gx"
        case gy = "gy"
        case gz = "gz"
        case steps = "steps"
        case activityClass = "activity_class"
        case skinTempRaw = "skin_temp_raw"
        case sleepState = "sleep_state"
        case spo2Byte = "spo2_byte"
        case optical50Hz = "optical_50hz"
    }
}

/// Wave 4 (2026-10-11): an R18 record's optical signal-quality fields, decoded, untested (OpenStrap protocol
/// gen5_records.dart L339-358, L388-430 @6e8c570; WhoopProtocol Interpreter @75/77/79, @108/109, @113):
/// - `saturated`: any of the three per-channel words at frame 75/77/79 (inner 67/69/71) has a saturation-majority bit
///   (bits 12-15: > 20 of 25 samples rail-pinned on a photodiode) — a quality gate, not a measurement;
/// - `psnrB` / `psnrA`: frame 108 / 109 (inner 100 / 101) as SIGNED dB for the selected HR source; −128 = unavailable
///   (stored nil);
/// - `logVariance`: f32 at frame 113 (inner 105), the band's per-second log-variance quality (~ −5.3…0; lower =
///   quieter); 0 or not finite = unset (nil).
public struct R18Quality: Codable, Hashable, Sendable {
    public var saturated: Bool
    public var psnrA: Int?
    public var psnrB: Int?
    public var logVariance: Double?

    public init(saturated: Bool, psnrA: Int?, psnrB: Int?, logVariance: Double?) {
        self.saturated = saturated
        self.psnrA = psnrA
        self.psnrB = psnrB
        self.logVariance = logVariance
    }

    /// From the raw fields: three u16 words, two u8 bytes (read as i8), the f32.
    public static func decode(words: [Int?], ampA: Int?, ampB: Int?, f32: Double?) -> R18Quality? {
        guard words.contains(where: { $0 != nil }) || ampA != nil || ampB != nil || f32 != nil else { return nil }
        func db(_ u: Int?) -> Int? {
            guard let u else { return nil }
            let s = u >= 128 ? u - 256 : u
            return s == -128 ? nil : s
        }
        let sat = words.compactMap { $0 }.contains { $0 & 0xF000 != 0 }
        let lv = f32.flatMap { $0.isFinite && $0 != 0 ? $0 : nil }
        return R18Quality(saturated: sat, psnrA: db(ampB), psnrB: db(ampA), logVariance: lv)
    }
}

/// A block of R26 PPG samples: value = base + sample (raw counts).
public struct PPGBlock: Codable, Hashable, Sendable {
    public var ts: Int64
    public var rateHz: Double
    public var base: Int32
    public var samples: [Int32]

    public init(ts: Int64, rateHz: Double, base: Int32, samples: [Int32]) {
        self.ts = ts
        self.rateHz = rateHz
        self.base = base
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case ts = "ts"
        case rateHz = "rate_hz"
        case base = "base"
        case samples = "samples"
    }
}

/// One R20 optical record (added 2026-10-11, strap-raw-optical phase C): five blocks, each a 21-byte head and two
/// reading slots of `sampleCount` samples, 25 Hz. Samples are RAW signed 20-bit ADC counts — no unit, no wavelength:
/// blocks are kept by INDEX. (OpenStrap labels blocks 0/1/2/3/4 green/red/"fourth"/IR/ambient; that is a CLAIM with
/// its provenance stripped and is never stored here.) Layout: WhoopProtocol `Whoop5RawOptical` (noop, VERIFIED against
/// a real 29,203-record corpus for the type-47 form; the live type-43 form is DECODED).
public struct R20Record: Codable, Hashable, Sendable {
    /// Strap unix seconds (u32 @15).
    public var ts: Int64
    /// Record counter (u32 @11), +1 per record.
    public var recordIndex: Int64
    /// "live" (108 on, packet 43) or "history" (banked, packet 47).
    public var source: String
    public var blocks: [R20Block]

    public init(ts: Int64, recordIndex: Int64, source: String, blocks: [R20Block]) {
        self.ts = ts
        self.recordIndex = recordIndex
        self.source = source
        self.blocks = blocks
    }

    /// Storage form: per block `[21-byte head][sampleCount × i32 LE slot A][sampleCount × i32 LE slot B]`, five
    /// blocks back to back. Self-describing: the head's first byte is the sample count.
    public var packed: Data {
        var d = Data()
        for b in blocks {
            d.append(contentsOf: b.head)
            for v in b.slotA + b.slotB {
                let u = UInt32(bitPattern: v)
                d.append(contentsOf: [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8(u >> 24)])
            }
        }
        return d
    }

    /// Inverse of `packed`; nil when the bytes are not that layout.
    public static func blocks(packed: Data) -> [R20Block]? {
        let bytes = [UInt8](packed)
        var out: [R20Block] = []
        var i = 0
        while i < bytes.count {
            guard i + 21 <= bytes.count else { return nil }
            let head = Array(bytes[i..<(i + 21)])
            let n = Int(head[0])
            i += 21
            guard i + n * 8 <= bytes.count else { return nil }
            func read(_ count: Int) -> [Int32] {
                (0..<count).map { k in
                    let o = i + k * 4
                    return Int32(bitPattern: UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8) | (UInt32(bytes[o + 2]) << 16)
                                 | (UInt32(bytes[o + 3]) << 24))
                }
            }
            let a = read(n)
            i += n * 4
            let b = read(n)
            i += n * 4
            out.append(R20Block(index: out.count, head: head, slotA: a, slotB: b))
        }
        return out
    }
}

public struct R20Block: Codable, Hashable, Sendable {
    public var index: Int
    /// The 21 head bytes verbatim (sample count, source/drive, detector/range/offset per slot — WhoopProtocol
    /// `Whoop5OpticalBlockConfig` reads them; what they select is not established).
    public var head: [UInt8]
    public var slotA: [Int32]
    public var slotB: [Int32]

    public init(index: Int, head: [UInt8], slotA: [Int32], slotB: [Int32]) {
        self.index = index
        self.head = head
        self.slotA = slotA
        self.slotB = slotB
    }
}

/// A strap EVENT (packet 48): e.g. 14 DOUBLE_TAP, 9 WRIST_ON, 10 WRIST_OFF (names from whoop_protocol.json).
public struct StrapEvent: Codable, Hashable, Sendable {
    public var ts: Int64
    public var number: Int
    public var name: String
    public var payloadHex: String

    public init(ts: Int64, number: Int, name: String, payloadHex: String) {
        self.ts = ts
        self.number = number
        self.name = name
        self.payloadHex = payloadHex
    }

    enum CodingKeys: String, CodingKey {
        case ts = "ts"
        case number = "number"
        case name = "name"
        case payloadHex = "payload_hex"
    }
}

public struct BatteryReading: Codable, Hashable, Sendable {
    public var ts: Int64
    public var percent: Double
    public var charging: Bool?

    public init(ts: Int64, percent: Double, charging: Bool? = nil) {
        self.ts = ts
        self.percent = percent
        self.charging = charging
    }
}

/// One raw strap frame as received (kept per ALG-006; uploaded only when pinned, D11).
public struct RawFrame: Codable, Hashable, Sendable {
    public var receivedAt: Date
    public var packetType: Int
    public var bytes: Data

    public init(receivedAt: Date, packetType: Int, bytes: Data) {
        self.receivedAt = receivedAt
        self.packetType = packetType
        self.bytes = bytes
    }

    enum CodingKeys: String, CodingKey {
        case receivedAt = "received_at"
        case packetType = "packet_type"
        case bytes = "bytes"
    }
}

// MARK: - Strap settings snapshot (added 2026-10-11, strap-raw-optical phase A)

/// One feature flag as the strap reported it through GET_FF_VALUE (128). The value is accepted only when the reply
/// says SUCCESS (result 1) AND echoes the requested key in its 32-byte key field (noop docs/PROTOCOL_CONFIGURATION.md
/// "Configuration reads — commands 121 and 128": a FAILURE reply also echoes the key, with a zero value field).
public struct StrapFlagReading: Codable, Hashable, Sendable {
    public var key: String
    /// The value text the strap formatted ("0", "1", "2", or a decimal), up to the first NUL of its 32-byte field.
    /// nil = no value accepted (see `status`). An empty string = SUCCESS with an all-zero value field, which the
    /// firmware also returns when the stored value could not be read (same source) — shown, never trusted.
    public var value: String?
    /// "ok", or why there is no trusted value: "empty value field", "FAILURE", "UNSUPPORTED", "no reply",
    /// "key not echoed", "not decoded …", "not read: …".
    public var status: String

    public init(key: String, value: String?, status: String) {
        self.key = key
        self.value = value
        self.status = status
    }
}

/// Every feature flag the strap listed (117 / 118 enumeration) with the value read for each (128). Read-only:
/// taking it writes nothing to the strap. `replyFrames` are the strap's COMMAND_RESPONSE frames, verbatim; MGStore
/// keeps them as pinned raw frames so they reach the PC (they are not part of the JSON form).
public struct StrapFlagSnapshot: Codable, Hashable, Sendable {
    public var strapId: StrapID
    public var firmware: String?
    public var readAt: Date
    /// The count the strap announced on 117 (one byte on 50.42.1.0); nil when it did not answer.
    public var announcedCount: Int?
    /// Why the 118 walk stopped ("cursor exhausted (index 0xFF)", a client-side cap, a timeout …).
    public var walkStop: String
    public var readings: [StrapFlagReading]
    public var replyFrames: [RawFrame]

    public init(strapId: StrapID, firmware: String?, readAt: Date, announcedCount: Int?, walkStop: String,
                readings: [StrapFlagReading], replyFrames: [RawFrame] = []) {
        self.strapId = strapId
        self.firmware = firmware
        self.readAt = readAt
        self.announcedCount = announcedCount
        self.walkStop = walkStop
        self.readings = readings
        self.replyFrames = replyFrames
    }

    /// The accepted value of `key` ("ok" readings only).
    public func value(of key: String) -> String? {
        readings.first { $0.key == key && $0.status == "ok" }?.value
    }

    enum CodingKeys: String, CodingKey {
        case strapId = "strap_id"
        case firmware
        case readAt = "read_at"
        case announcedCount = "announced_count"
        case walkStop = "walk_stop"
        case readings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strapId = try c.decode(StrapID.self, forKey: .strapId)
        firmware = try c.decodeIfPresent(String.self, forKey: .firmware)
        readAt = try c.decode(Date.self, forKey: .readAt)
        announcedCount = try c.decodeIfPresent(Int.self, forKey: .announcedCount)
        walkStop = try c.decode(String.self, forKey: .walkStop)
        readings = try c.decode([StrapFlagReading].self, forKey: .readings)
        replyFrames = []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(strapId, forKey: .strapId)
        try c.encodeIfPresent(firmware, forKey: .firmware)
        try c.encode(readAt, forKey: .readAt)
        try c.encodeIfPresent(announcedCount, forKey: .announcedCount)
        try c.encode(walkStop, forKey: .walkStop)
        try c.encode(readings, forKey: .readings)
    }
}

/// Watching for R22 records after the one enable_r22_packets = '1' write (Mo, 2026-10-11: "Single write, then see").
/// R22 (packet 47, layout 22, a ~188-byte record a second) is banked into history, so it can only show up in the
/// offloads AFTER the write. The watch counts offloads that carried data recorded at least `minSecondsAfterWrite` after
/// the write; once `offloadsNeeded` of them brought no R22 record, the verdict is `noneYet` and the Strap sheet says
/// which version flag the strap may also need. Nothing here writes to the strap.
public struct R22Watch: Codable, Hashable, Sendable {
    public static let offloadsNeeded = 2
    public static let minSecondsAfterWrite: Int64 = 60

    public var writtenAt: Date
    /// The most-preferred R22 version flag the strap answered for when none read '1' at the write
    /// (noop PROTOCOL_CONFIGURATION preference 9, 6, 5, 4, 3, 2); nil when one already read '1'.
    public var hintFlag: String?
    public var offloadsAfterWrite: Int
    public var r22Records: Int
    public var firstR22At: Date?

    public init(writtenAt: Date, hintFlag: String?, offloadsAfterWrite: Int = 0, r22Records: Int = 0,
                firstR22At: Date? = nil) {
        self.writtenAt = writtenAt
        self.hintFlag = hintFlag
        self.offloadsAfterWrite = offloadsAfterWrite
        self.r22Records = r22Records
        self.firstR22At = firstR22At
    }

    public enum Verdict: Equatable, Sendable {
        /// R22 records have arrived since the write.
        case arriving
        /// Fewer than `offloadsNeeded` offloads with post-write data so far.
        case waiting
        /// `offloadsNeeded` offloads with post-write data, no R22 record.
        case noneYet
    }

    public var verdict: Verdict {
        if r22Records > 0 { return .arriving }
        return offloadsAfterWrite >= Self.offloadsNeeded ? .noneYet : .waiting
    }

    /// One finished history download: its newest record's strap time and how many R22 records it carried.
    public mutating func noteDownload(lastTs: Int64?, r22Records count: Int, at: Date) {
        if count > 0 {
            r22Records += count
            if firstR22At == nil { firstR22At = at }
        }
        if let lastTs, lastTs >= Int64(writtenAt.timeIntervalSince1970) + Self.minSecondsAfterWrite,
           offloadsAfterWrite < Self.offloadsNeeded {
            offloadsAfterWrite += 1
        }
    }
}

/// What one phone-side cleanup (MGStore `pruneConfirmed`) removed — only data the PC confirmed (delivered with matching
/// receipts) that is older than 30 days (Mo, 2026-10-11). Kept by MGStore so Strap & sync can show the last one.
public struct PhoneRetentionReport: Codable, Hashable, Sendable {
    public var at: Date
    public var rawFrames: Int
    /// Rows deleted per table: hr_sample, rr_interval, r18_second.
    public var perSecondRows: [String: Int]
    /// Outbox files whose stored compressed copy was removed (row, sizes, sha256 and receipt stay).
    public var outboxCopies: Int
    /// Bytes those copies held.
    public var outboxBytes: Int

    public init(at: Date, rawFrames: Int = 0, perSecondRows: [String: Int] = [:], outboxCopies: Int = 0,
                outboxBytes: Int = 0) {
        self.at = at
        self.rawFrames = rawFrames
        self.perSecondRows = perSecondRows
        self.outboxCopies = outboxCopies
        self.outboxBytes = outboxBytes
    }

    public var perSecondTotal: Int { perSecondRows.values.reduce(0, +) }
}

/// Everything decoded from one live burst or one history chunk.
public struct StrapRecordBatch: Hashable, Sendable {
    public var strapId: StrapID
    public var hr: [HRPoint]
    public var rr: [RRPoint]
    public var seconds: [R18Second]
    public var ppg: [PPGBlock]
    public var events: [StrapEvent]
    public var battery: [BatteryReading]
    public var rawFrames: [RawFrame]
    /// Decoded R20 optical records (added 2026-10-11); MGStore keeps them in `ppg_block`.
    public var r20: [R20Record]
    /// Raw-motion seconds (R21, added 2026-10-11 19:50 PT, wave W8); MGStore keeps them in `motion_second`.
    public var motion: [MotionSecond]

    public init(
        strapId: StrapID,
        hr: [HRPoint] = [],
        rr: [RRPoint] = [],
        seconds: [R18Second] = [],
        ppg: [PPGBlock] = [],
        events: [StrapEvent] = [],
        battery: [BatteryReading] = [],
        rawFrames: [RawFrame] = [],
        r20: [R20Record] = [],
        motion: [MotionSecond] = []
    ) {
        self.strapId = strapId
        self.hr = hr
        self.rr = rr
        self.seconds = seconds
        self.ppg = ppg
        self.events = events
        self.battery = battery
        self.rawFrames = rawFrames
        self.r20 = r20
        self.motion = motion
    }

    /// Decoded records (raw frames not counted).
    public var recordCount: Int {
        hr.count + rr.count + seconds.count + ppg.count + events.count + battery.count + r20.count + motion.count
    }
    public var isEmpty: Bool { recordCount == 0 && rawFrames.isEmpty }
}

/// One history chunk, closed by META END. `chunkId` = `"<strapId>:<hex(endToken)>"` (`makeID`), so the same chunk
/// re-served by the strap gets the same id and is stored once (ARCHITECTURE.md 4.4.4).
public struct HistoryChunk: Hashable, Sendable {
    public var chunkId: String
    public var strapId: StrapID
    /// The 8 bytes from the END frame (frame[21..<29]), echoed unchanged in the ack. Never rebuilt.
    public var endToken: Data
    public var trim: UInt32
    public var firstTs: Int64?
    public var lastTs: Int64?
    public var records: StrapRecordBatch
    public var frameCount: Int

    public init(
        chunkId: String,
        strapId: StrapID,
        endToken: Data,
        trim: UInt32,
        firstTs: Int64? = nil,
        lastTs: Int64? = nil,
        records: StrapRecordBatch,
        frameCount: Int
    ) {
        self.chunkId = chunkId
        self.strapId = strapId
        self.endToken = endToken
        self.trim = trim
        self.firstTs = firstTs
        self.lastTs = lastTs
        self.records = records
        self.frameCount = frameCount
    }

    public static func makeID(strapId: StrapID, endToken: Data) -> String {
        strapId.raw + ":" + endToken.map { String(format: "%02x", $0) }.joined()
    }
}

public struct StoredChunkReceipt: Hashable, Sendable {
    public var chunkId: String
    public var inserted: Int
    public var duplicate: Bool

    public init(chunkId: String, inserted: Int, duplicate: Bool) {
        self.chunkId = chunkId
        self.inserted = inserted
        self.duplicate = duplicate
    }
}

/// Ack journal outcome for a history chunk (APP-003).
public enum AckResult: String, Codable, Sendable, CaseIterable {
    case acked = "acked"
    case writeFailed = "write_failed"
    case rejected = "rejected"
    case skipped = "skipped"
}

/// History download progress, for `StrapLinkState.downloadingHistory` (MGBLE) and `ContextInputs.history`
/// (MGContext): "Fetching strap history · 62 % · 3 h 10 of 5 h" (UX-SPEC 4.2). Added to MGDomain with main's approval
/// 2026-10-11 so both packages share one type.
public struct HistoryProgress: Hashable, Sendable {
    public var startedAt: Date
    public var chunksStored: Int
    public var recordsStored: Int
    /// Strap time (unix s) of the first record received this session.
    public var firstTs: Int64?
    /// Strap time (unix s) of the newest record stored so far.
    public var newestTs: Int64?
    /// Strap time the download is heading for (end of the strap's data), when known.
    public var targetTs: Int64?
    public var lastAck: AckResult?
    public var lastAckAt: Date?
    /// T10013 (r8b): the strap said there are no more chunks (HISTORY_COMPLETE with nothing further to fetch). The words
    /// then say "caught up to 9:41 AM" instead of a percent.
    public var caughtUp: Bool

    public init(
        startedAt: Date,
        chunksStored: Int = 0,
        recordsStored: Int = 0,
        firstTs: Int64? = nil,
        newestTs: Int64? = nil,
        targetTs: Int64? = nil,
        lastAck: AckResult? = nil,
        lastAckAt: Date? = nil,
        caughtUp: Bool = false
    ) {
        self.startedAt = startedAt
        self.chunksStored = chunksStored
        self.recordsStored = recordsStored
        self.firstTs = firstTs
        self.newestTs = newestTs
        self.targetTs = targetTs
        self.lastAck = lastAck
        self.lastAckAt = lastAckAt
        self.caughtUp = caughtUp
    }

    /// Strap seconds covered so far; nil until a record has arrived.
    public var coveredSeconds: Int64? {
        guard let a = firstTs, let b = newestTs else { return nil }
        return max(0, b - a)
    }

    /// Strap seconds the whole download spans; nil while the end is unknown.
    public var totalSeconds: Int64? {
        guard let a = firstTs, let t = targetTs, t > a else { return nil }
        return t - a
    }

    /// 0...1, or nil while the end is unknown (show the chunk count instead of a made-up percentage).
    public var fraction: Double? {
        guard let covered = coveredSeconds, let total = totalSeconds else { return nil }
        return min(1, Double(covered) / Double(total))
    }
}
