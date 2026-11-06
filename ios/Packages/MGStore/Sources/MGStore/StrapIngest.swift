import Foundation
import GRDB
import MGDomain

/// Strap rows in: history chunks (HistorySink, APP-003 / ALG-003) and live batches (LiveSink).
extension MGStore: HistorySink, LiveSink {

    // MARK: HistorySink

    /// Stores one history chunk in **one transaction** and returns only after COMMIT (§4.3, §4.4.4): decoded rows,
    /// raw frames and the `history_chunk` journal row land together or not at all. MGBLE sends the HISTORY_END ack
    /// (23) only after this returns (noop:Strand/Collect/Backfiller.swift L851-970: insert → cursor → ack).
    ///
    /// Re-served chunk (same `chunkId`, e.g. a lost ack): decoded rows hit their natural keys and insert nothing,
    /// raw frames are skipped (their receive time differs, so their key would not dedupe), the journal row only counts
    /// the re-serve; the receipt says `duplicate: true` and the call succeeds so MGBLE can ack again.
    ///
    /// Before COMMIT it checks the writer is at `synchronous = FULL`; if not it throws `notDurable` and rolls back,
    /// so no ack is sent on a commit that a power cut could undo.
    public func store(_ chunk: HistoryChunk) async throws -> StoredChunkReceipt {
        try storeChunkSync(chunk)
    }

    func storeChunkSync(_ chunk: HistoryChunk) throws -> StoredChunkReceipt {
        let now = nowUnix
        return try syncWrite { db in
            let level = try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
            guard level == 2 else { throw MGStoreError.notDurable(synchronous: level) }

            // A journal row without stored_at is a stub left by recordAck for a chunk whose store failed: not a duplicate.
            let existed = try Int.fetchOne(db, sql: """
                SELECT 1 FROM history_chunk WHERE chunk_id = ? AND stored_at IS NOT NULL
                """, arguments: [chunk.chunkId]) != nil
            try touchStrap(db, chunk.strapId.raw, at: now)
            var inserted = try insertDecoded(db, chunk.records, strapId: chunk.strapId.raw)
            try fault(.chunkAfterDecodedRows)
            if !existed {
                inserted += try insertRawFrames(db, chunk.records.rawFrames, strapId: chunk.strapId.raw,
                                                chunkId: chunk.chunkId)
            }
            try fault(.chunkBeforeJournal)
            if existed {
                try db.execute(sql: "UPDATE history_chunk SET served = served + 1 WHERE chunk_id = ?",
                               arguments: [chunk.chunkId])
            } else {
                let r = chunk.records
                let offered = r.recordCount
                try db.execute(sql: """
                    INSERT INTO history_chunk (chunk_id, strap_id, first_ts, last_ts, trim, end_token_hex, records,
                        inserted, frame_count, served, stored_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                    ON CONFLICT(chunk_id) DO UPDATE SET
                        strap_id = excluded.strap_id, first_ts = excluded.first_ts, last_ts = excluded.last_ts,
                        trim = excluded.trim, end_token_hex = excluded.end_token_hex, records = excluded.records,
                        inserted = excluded.inserted, frame_count = excluded.frame_count, served = 1,
                        stored_at = excluded.stored_at
                    """, arguments: [chunk.chunkId, chunk.strapId.raw, chunk.firstTs, chunk.lastTs,
                                     Int64(chunk.trim), Hex.string(chunk.endToken), offered, inserted,
                                     chunk.frameCount, now])
            }
            return StoredChunkReceipt(chunkId: chunk.chunkId, inserted: inserted, duplicate: existed)
        }
    }

    /// Ack journal (APP-003). A result for a chunk that was never stored (store threw, so MGBLE did not ack) gets a
    /// journal row with `stored_at` NULL, so the journal shows the stall.
    public func recordAck(chunkId: String, result: AckResult, at: Date) async throws {
        let strapId = chunkId.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO history_chunk (chunk_id, strap_id, ack_result, acked_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(chunk_id) DO UPDATE SET ack_result = excluded.ack_result, acked_at = excluded.acked_at
                """, arguments: [chunkId, strapId, result.rawValue, at.unix])
        }
    }

    // MARK: LiveSink

    /// Live HR / R-R / R18 / events / battery / raw frames, one transaction per batch, deduped by natural key.
    public func append(_ batch: StrapRecordBatch) async throws {
        let now = nowUnix
        _ = try syncWrite { db -> Int in
            try touchStrap(db, batch.strapId.raw, at: now)
            let n = try insertDecoded(db, batch, strapId: batch.strapId.raw)
            return n + (try insertRawFrames(db, batch.rawFrames, strapId: batch.strapId.raw, chunkId: nil))
        }
    }

    // MARK: Strap settings snapshot (added 2026-10-11, strap-raw-optical phase A)

    /// Stores one strap settings snapshot in one transaction and returns after COMMIT: the decoded snapshot row, and the
    /// strap's reply frames as raw frames pinned `keep = 1`, so they go to the PC in the next raw drop (D11 uploads only
    /// pinned frames). MGBLE writes the R22 flag only after this returns, so the prior value is on disk first.
    public func storeFlagSnapshot(_ snapshot: StrapFlagSnapshot) async throws {
        let now = nowUnix
        let json = try DocJSON.encode(snapshot)
        try syncWrite { db in
            try touchStrap(db, snapshot.strapId.raw, at: now)
            try db.execute(sql: """
                INSERT INTO strap_flag_snapshot (strap_id, read_at, firmware, json) VALUES (?, ?, ?, ?)
                ON CONFLICT(strap_id, read_at) DO UPDATE SET firmware = excluded.firmware, json = excluded.json
                """, arguments: [snapshot.strapId.raw, snapshot.readAt.unix, snapshot.firmware, json])
            _ = try insertRawFrames(db, snapshot.replyFrames, strapId: snapshot.strapId.raw, chunkId: nil)
            for f in snapshot.replyFrames {
                try db.execute(sql: """
                    UPDATE raw_frame SET keep = 1 WHERE strap_id = ? AND received_at = ? AND packet_type = ? AND crc32 = ?
                    """, arguments: [snapshot.strapId.raw, f.receivedAt.unix, f.packetType,
                                     Int64(CRC32.checksum(f.bytes))])
            }
        }
    }

    /// The newest stored strap settings snapshot (any strap), without its reply frames; nil when none was taken.
    public func latestFlagSnapshot() async throws -> StrapFlagSnapshot? {
        let json = try syncRead { db in
            try Data.fetchOne(db, sql: "SELECT json FROM strap_flag_snapshot ORDER BY read_at DESC, id DESC LIMIT 1")
        }
        return try json.map { try DocJSON.decode(StrapFlagSnapshot.self, $0) }
    }

    // MARK: Strap registry

    /// Records what the BLE layer learned about a strap (§4.5 `strap`). Nil fields keep their stored value.
    public func upsertStrap(id: StrapID, peripheralUUID: String?, family: String?, firmware: String?,
                            model: String?, seenAt: Date) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO strap (id, peripheral_uuid, family, firmware, model, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    peripheral_uuid = COALESCE(excluded.peripheral_uuid, peripheral_uuid),
                    family = COALESCE(excluded.family, family),
                    firmware = COALESCE(excluded.firmware, firmware),
                    model = COALESCE(excluded.model, model),
                    last_seen = MAX(last_seen, excluded.last_seen)
                """, arguments: [id.raw, peripheralUUID, family, firmware, model, seenAt.unix, seenAt.unix])
        }
    }

    /// The most recently seen strap — what MGSync puts in `streams_<strap_id>_…` / `raw_<strap_id>_…` drop ids and
    /// what the day summary's `strap_id` uses. Nil before any strap was seen.
    public func primaryStrapId() async throws -> StrapID? {
        try syncRead { db in try primaryStrap(db)?.id }.map { StrapID(raw: $0) }
    }

    func primaryStrap(_ db: Database) throws -> (id: String, firmware: String?)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT id, firmware FROM strap ORDER BY last_seen DESC, id LIMIT 1")
        else { return nil }
        let id: String = row["id"]
        let firmware: String? = row["firmware"]
        return (id, firmware)
    }

    func touchStrap(_ db: Database, _ strapId: String, at now: Double) throws {
        try db.execute(sql: """
            INSERT INTO strap (id, first_seen, last_seen) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET last_seen = MAX(last_seen, excluded.last_seen)
            """, arguments: [strapId, now, now])
    }

    // MARK: Inserts (ON CONFLICT DO NOTHING; counts rows actually inserted)

    /// Inserts every decoded stream of `batch`; returns rows inserted. Marks touched export windows dirty.
    func insertDecoded(_ db: Database, _ batch: StrapRecordBatch, strapId: String) throws -> Int {
        var total = 0
        var touched: [StreamKind: Set<Int64>] = [:]
        func touch(_ kind: StreamKind, _ ts: Int64) {
            touched[kind, default: []].insert(MGStore.windowStart(ts))
        }

        if !batch.hr.isEmpty {
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO hr_sample (strap_id, ts, source, bpm) VALUES (?, ?, ?, ?)
                ON CONFLICT(strap_id, ts, source) DO NOTHING
                """)
            for p in batch.hr {
                try stmt.execute(arguments: [strapId, p.ts, p.source.rawValue, p.bpm])
                if db.changesCount > 0 { total += 1; touch(.hr, p.ts) }
            }
        }
        if !batch.rr.isEmpty {
            // ord = emission order inside one second, part of the key and the first sort key after ts (noop #823,
            // WhoopStore rrInterval.ord): beats are read back in heart order, never by value.
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO rr_interval (strap_id, ts, ord, source, rr_ms) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(strap_id, ts, ord, source) DO NOTHING
                """)
            for p in batch.rr {
                try stmt.execute(arguments: [strapId, p.ts, p.ord, p.source.rawValue, p.rrMs])
                if db.changesCount > 0 { total += 1; touch(.rr, p.ts) }
            }
        }
        if !batch.seconds.isEmpty {
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO r18_second (strap_id, ts, hr, rr_count, gx, gy, gz, steps, activity_class, skin_temp_raw,
                    sleep_state, spo2_byte, optical_50hz, q_saturated, q_psnr_a, q_psnr_b, q_logvar,
                    dyn_accel, temp_aux1_raw, temp_aux2_raw)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(strap_id, ts) DO NOTHING
                """)
            for s in batch.seconds {
                try stmt.execute(arguments: [strapId, s.ts, s.hr, s.rrCount, s.gx, s.gy, s.gz, s.steps,
                                             s.activityClass, s.skinTempRaw, s.sleepState, s.spo2Byte,
                                             s.optical50Hz, s.quality.map { $0.saturated ? 1 : 0 }, s.quality?.psnrA,
                                             s.quality?.psnrB, s.quality?.logVariance, s.dynAccel, s.tempAux1Raw,
                                             s.tempAux2Raw])
                if db.changesCount > 0 { total += 1; touch(.r18, s.ts) }
            }
        }
        if !batch.ppg.isEmpty {
            // A row that so far holds only an R20 record (empty `samples`) takes the v26 window; a filled one keeps its own.
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO ppg_block (strap_id, ts, rate_hz, base, samples) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(strap_id, ts) DO UPDATE SET rate_hz = excluded.rate_hz, base = excluded.base,
                    samples = excluded.samples
                WHERE length(ppg_block.samples) = 0
                """)
            for b in batch.ppg {
                try stmt.execute(arguments: [strapId, b.ts, b.rateHz, Int64(b.base), MGStore.int32LE(b.samples)])
                total += db.changesCount
            }
        }
        if !batch.r20.isEmpty {
            // R20 (added 2026-10-11): fills the R20 half of the second's row; a row that already has one keeps it.
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO ppg_block (strap_id, ts, rate_hz, base, samples, r20_source, r20_record_index, r20_blocks)
                VALUES (?, ?, 25, 0, x'', ?, ?, ?)
                ON CONFLICT(strap_id, ts) DO UPDATE SET r20_source = excluded.r20_source,
                    r20_record_index = excluded.r20_record_index, r20_blocks = excluded.r20_blocks
                WHERE ppg_block.r20_blocks IS NULL
                """)
            for r in batch.r20 {
                try stmt.execute(arguments: [strapId, r.ts, r.source, r.recordIndex, r.packed])
                total += db.changesCount
            }
        }
        if !batch.motion.isEmpty {
            // Raw motion R21 (wave W8, 2026-10-11 19:50 PT): one compact row per strap second; the first copy of a second
            // wins (live or history), as noop discards duplicate timestamps (RAW_DATA_CAPTURE.md L44-45).
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO motion_second (strap_id, ts, fraction, accel_n, gyro_n, source, packed, acc_mean, acc_sd,
                    enmo_lsb)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(strap_id, ts) DO NOTHING
                """)
            for m in batch.motion {
                let s = m.accelSummary
                try stmt.execute(arguments: [strapId, m.ts, m.fraction, m.accelCount, m.gyroCount, m.source, m.packed,
                                             s?.meanMagLSB, s?.sdMagLSB, s?.enmoLSB])
                total += db.changesCount
            }
        }
        if !batch.events.isEmpty {
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO strap_event (strap_id, ts, number, name, payload_hex) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(strap_id, ts, number) DO NOTHING
                """)
            for e in batch.events {
                try stmt.execute(arguments: [strapId, e.ts, e.number, e.name, e.payloadHex])
                if db.changesCount > 0 { total += 1; touch(.strapEvents, e.ts) }
            }
        }
        if !batch.battery.isEmpty {
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO battery (strap_id, ts, percent, charging) VALUES (?, ?, ?, ?)
                ON CONFLICT(strap_id, ts) DO NOTHING
                """)
            for b in batch.battery {
                try stmt.execute(arguments: [strapId, b.ts, b.percent, b.charging])
                total += db.changesCount
            }
        }
        if !touched.isEmpty {
            let stmt = try db.cachedStatement(sql: """
                INSERT INTO stream_window (kind, window_start, dirty) VALUES (?, ?, 1)
                ON CONFLICT(kind, window_start) DO UPDATE SET dirty = 1
                """)
            for (kind, windows) in touched {
                for w in windows { try stmt.execute(arguments: [kind.rawValue, w]) }
            }
        }
        return total
    }

    /// Raw frames (ALG-006 ring buffer): key (strap_id, received_at, packet_type, crc32), keep = 0 until pinned.
    func insertRawFrames(_ db: Database, _ frames: [RawFrame], strapId: String, chunkId: String?) throws -> Int {
        guard !frames.isEmpty else { return 0 }
        var total = 0
        let stmt = try db.cachedStatement(sql: """
            INSERT INTO raw_frame (strap_id, received_at, packet_type, crc32, bytes, keep, chunk_id)
            VALUES (?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT(strap_id, received_at, packet_type, crc32) DO NOTHING
            """)
        for f in frames {
            try stmt.execute(arguments: [strapId, f.receivedAt.unix, f.packetType, Int64(CRC32.checksum(f.bytes)),
                                         f.bytes, chunkId])
            total += db.changesCount
        }
        return total
    }

    static func windowStart(_ ts: Int64) -> Int64 {
        let w = streamWindowSeconds
        return ts >= 0 ? (ts / w) * w : ((ts - w + 1) / w) * w
    }

    static func int32LE(_ values: [Int32]) -> Data {
        var data = Data(capacity: values.count * 4)
        for v in values {
            let u = UInt32(bitPattern: v)   // bytes taken low-first below = little-endian on any host
            data.append(UInt8(truncatingIfNeeded: u))
            data.append(UInt8(truncatingIfNeeded: u >> 8))
            data.append(UInt8(truncatingIfNeeded: u >> 16))
            data.append(UInt8(truncatingIfNeeded: u >> 24))
        }
        return data
    }

    static func int32Array(_ data: Data) -> [Int32] {
        let bytes = [UInt8](data)
        var out: [Int32] = []
        out.reserveCapacity(bytes.count / 4)
        var i = 0
        while i + 3 < bytes.count {
            let u = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) | (UInt32(bytes[i + 2]) << 16)
                | (UInt32(bytes[i + 3]) << 24)
            out.append(Int32(bitPattern: u))
            i += 4
        }
        return out
    }
}
