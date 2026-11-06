import Foundation
import GRDB
import MGDomain

/// One row of the history ack journal (APP-003), for the strap sheet's write/ack log.
public struct HistoryChunkJournalEntry: Sendable, Equatable {
    public var chunkId: String
    public var strapId: String
    public var firstTs: Int64?
    public var lastTs: Int64?
    public var trim: UInt32?
    public var endTokenHex: String?
    public var records: Int
    public var inserted: Int
    public var frameCount: Int
    public var served: Int
    public var storedAt: Date?
    public var ackResult: AckResult?
    public var ackedAt: Date?

    public init(chunkId: String, strapId: String, firstTs: Int64?, lastTs: Int64?, trim: UInt32?,
                endTokenHex: String?, records: Int, inserted: Int, frameCount: Int, served: Int, storedAt: Date?,
                ackResult: AckResult?, ackedAt: Date?) {
        self.chunkId = chunkId; self.strapId = strapId; self.firstTs = firstTs; self.lastTs = lastTs
        self.trim = trim; self.endTokenHex = endTokenHex; self.records = records; self.inserted = inserted
        self.frameCount = frameCount; self.served = served; self.storedAt = storedAt; self.ackResult = ackResult
        self.ackedAt = ackedAt
    }
}

/// Reads of stored strap streams for the pipelines (MGSignal, WP-22) and the Live tab. Ranges are strap-ts seconds,
/// inclusive. `strapId` nil = every strap. Rows come back in a fixed order (R-R by ts, then ord — heart order).
extension MGStore {

    public func hrSamples(from: Int64, to: Int64, strapId: StrapID? = nil) async throws -> [HRPoint] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm, source FROM hr_sample
                WHERE ts BETWEEN ? AND ? AND (? IS NULL OR strap_id = ?)
                ORDER BY ts, source, strap_id
                """, arguments: [from, to, strapId?.raw, strapId?.raw]).map { row in
                HRPoint(ts: row["ts"], bpm: row["bpm"], source: MGStore.source(row["source"]))
            }
        }
    }

    /// R-R intervals ordered by (ts, ord): emission order inside a second (noop #823). Never sorted by value.
    public func rrIntervals(from: Int64, to: Int64, strapId: StrapID? = nil) async throws -> [RRPoint] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, ord, rr_ms, source FROM rr_interval
                WHERE ts BETWEEN ? AND ? AND (? IS NULL OR strap_id = ?)
                ORDER BY ts, ord, source, strap_id
                """, arguments: [from, to, strapId?.raw, strapId?.raw]).map { row in
                RRPoint(ts: row["ts"], ord: row["ord"], rrMs: row["rr_ms"], source: MGStore.source(row["source"]))
            }
        }
    }

    public func r18Seconds(from: Int64, to: Int64, strapId: StrapID? = nil) async throws -> [R18Second] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, hr, rr_count, gx, gy, gz, steps, activity_class, skin_temp_raw, sleep_state, spo2_byte,
                       optical_50hz, q_saturated, q_psnr_a, q_psnr_b, q_logvar, dyn_accel, temp_aux1_raw, temp_aux2_raw
                FROM r18_second
                WHERE ts BETWEEN ? AND ? AND (? IS NULL OR strap_id = ?)
                ORDER BY ts, strap_id
                """, arguments: [from, to, strapId?.raw, strapId?.raw]).map { row in
                R18Second(ts: row["ts"], hr: row["hr"], rrCount: row["rr_count"], gx: row["gx"], gy: row["gy"],
                          gz: row["gz"], steps: row["steps"], activityClass: row["activity_class"],
                          skinTempRaw: row["skin_temp_raw"], sleepState: row["sleep_state"],
                          spo2Byte: row["spo2_byte"], optical50Hz: row["optical_50hz"],
                          quality: (row["q_saturated"] as Int?).map {
                              R18Quality(saturated: $0 != 0, psnrA: row["q_psnr_a"], psnrB: row["q_psnr_b"],
                                         logVariance: row["q_logvar"])
                          },
                          dynAccel: row["dyn_accel"], tempAux1Raw: row["temp_aux1_raw"],
                          tempAux2Raw: row["temp_aux2_raw"])
            }
        }
    }

    public func ppgBlocks(from: Int64, to: Int64, strapId: StrapID? = nil) async throws -> [PPGBlock] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, rate_hz, base, samples FROM ppg_block
                WHERE ts BETWEEN ? AND ? AND (? IS NULL OR strap_id = ?) AND length(samples) > 0
                ORDER BY ts, strap_id
                """, arguments: [from, to, strapId?.raw, strapId?.raw]).map { row -> PPGBlock in
                let base: Int64 = row["base"]
                let samples: Data = row["samples"]
                return PPGBlock(ts: row["ts"], rateHz: row["rate_hz"], base: Int32(truncatingIfNeeded: base),
                                samples: MGStore.int32Array(samples))
            }
        }
    }

    /// How many R20 optical records are stored with strap ts in [from, to] (wave 4, #65: the nights log).
    public func r20RecordCount(from: Int64, to: Int64) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppg_block WHERE ts BETWEEN ? AND ? AND r20_blocks IS NOT NULL",
                             arguments: [from, to]) ?? 0
        }
    }

    /// R20 optical records (2026-10-11) with strap ts in [from, to], oldest first.
    public func r20Records(from: Int64, to: Int64, strapId: StrapID? = nil) async throws -> [R20Record] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, r20_source, r20_record_index, r20_blocks FROM ppg_block
                WHERE ts BETWEEN ? AND ? AND (? IS NULL OR strap_id = ?) AND r20_blocks IS NOT NULL
                ORDER BY ts, strap_id
                """, arguments: [from, to, strapId?.raw, strapId?.raw]).compactMap { row -> R20Record? in
                let packed: Data = row["r20_blocks"]
                let ts: Int64 = row["ts"]
                let index: Int64? = row["r20_record_index"]
                let source: String? = row["r20_source"]
                guard let blocks = R20Record.blocks(packed: packed) else { return nil }
                return R20Record(ts: ts, recordIndex: index ?? 0, source: source ?? "", blocks: blocks)
            }
        }
    }

    public func strapEvents(from: Int64, to: Int64, strapId: StrapID? = nil) async throws -> [StrapEvent] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, number, name, payload_hex FROM strap_event
                WHERE ts BETWEEN ? AND ? AND (? IS NULL OR strap_id = ?)
                ORDER BY ts, number, strap_id
                """, arguments: [from, to, strapId?.raw, strapId?.raw]).map { row in
                StrapEvent(ts: row["ts"], number: row["number"], name: row["name"], payloadHex: row["payload_hex"])
            }
        }
    }

    public func batteryReadings(from: Int64, to: Int64, strapId: StrapID? = nil) async throws -> [BatteryReading] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, percent, charging FROM battery
                WHERE ts BETWEEN ? AND ? AND (? IS NULL OR strap_id = ?)
                ORDER BY ts, strap_id
                """, arguments: [from, to, strapId?.raw, strapId?.raw]).map { row in
                BatteryReading(ts: row["ts"], percent: row["percent"], charging: row["charging"])
            }
        }
    }

    /// Newest first.
    public func historyJournal(limit: Int = 200) async throws -> [HistoryChunkJournalEntry] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT chunk_id, strap_id, first_ts, last_ts, trim, end_token_hex, records, inserted, frame_count,
                       served, stored_at, ack_result, acked_at
                FROM history_chunk ORDER BY COALESCE(acked_at, stored_at) DESC, chunk_id LIMIT ?
                """, arguments: [limit]).map { row -> HistoryChunkJournalEntry in
                let trim: Int64? = row["trim"]
                let storedAt: Double? = row["stored_at"]
                let ackedAt: Double? = row["acked_at"]
                let ack: String? = row["ack_result"]
                return HistoryChunkJournalEntry(
                    chunkId: row["chunk_id"], strapId: row["strap_id"], firstTs: row["first_ts"],
                    lastTs: row["last_ts"], trim: trim.map { UInt32(truncatingIfNeeded: $0) },
                    endTokenHex: row["end_token_hex"], records: row["records"], inserted: row["inserted"],
                    frameCount: row["frame_count"], served: row["served"],
                    storedAt: storedAt.map(Date.init(timeIntervalSince1970:)),
                    ackResult: ack.flatMap(AckResult.init(rawValue:)),
                    ackedAt: ackedAt.map(Date.init(timeIntervalSince1970:)))
            }
        }
    }

    /// Counts per table, for diagnostics and tests.
    public func rowCounts() async throws -> [String: Int] {
        try syncRead { db in
            var out: [String: Int] = [:]
            out["hr_sample"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hr_sample") ?? 0
            out["rr_interval"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rr_interval") ?? 0
            out["r18_second"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM r18_second") ?? 0
            out["ppg_block"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppg_block") ?? 0
            out["strap_event"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM strap_event") ?? 0
            out["battery"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
            out["raw_frame"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM raw_frame") ?? 0
            out["history_chunk"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM history_chunk") ?? 0
            out["event"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            out["metric"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metric") ?? 0
            return out
        }
    }

    static func source(_ raw: String) -> StreamSource {
        // Stored values come from StreamSource.rawValue; an unknown value can only mean a newer writer.
        StreamSource(rawValue: raw) ?? .live
    }
}
