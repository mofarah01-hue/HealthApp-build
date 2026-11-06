import Foundation
import GRDB
import MGDomain

// r8l 2026-10-17 (audit §3.3, §3.4): the per-hour state of `raw_frame`.
//
// `raw_hour` (Schema v11) has one row per UTC hour of raw frames: `frames`, `bytes` (kept by triggers on insert and
// delete, so a frame written by any code path is counted), `exported_frames` / `confirmed_frames`, and two
// WATERMARKS: `exported_wm` / `confirmed_wm`. A frame is exported (PC-confirmed) when its own flag is 1 OR its `id` is
// <= its hour's watermark. Marking a drop exported or confirmed is therefore one UPDATE on the hour row, not one UPDATE
// per frame.
//
// Why "id <= watermark" is sound. A raw drop covers every not-yet-exported frame of its range (`rawFramesFile`), so all
// frames of the hour with an id below the drop's highest id are in that drop or were exported before. Ids only grow
// (new frames always get a higher id), so a frame stored later is above the watermark and goes out in a later drop.
//
// Confirmation is the careful part. A late drop for an hour can be delivered while an earlier drop of the same hour
// is still not (failed / waiting): moving the watermark to the late drop's highest id would then confirm frames the PC
// never received. So the watermark moves only when NO other raw drop touching the hour is undelivered; otherwise the
// drop's own frames get the old per-row `pc_confirmed = 1` flag (the exception path) and the hour's counter is recounted.
extension MGStore {

    /// Seconds in one `raw_hour` row (= `streamWindowSeconds`, also written as the literal 3600 in the Schema v11
    /// triggers).
    static var rawHourSeconds: Int64 { streamWindowSeconds }

    /// The frame ids of a `raw_export.frame_ids` blob (u64 LE each).
    static func rawFrameIDs(_ blob: Data) -> [Int64] {
        let bytes = [UInt8](blob)
        var out: [Int64] = []
        out.reserveCapacity(bytes.count / 8)
        var i = 0
        while i + 7 < bytes.count {
            var u: UInt64 = 0
            for k in 0..<8 { u |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
            out.append(Int64(bitPattern: u))
            i += 8
        }
        return out
    }

    /// The hours (starts) that [from, to] touches.
    static func rawHours(from: Int64, to: Int64) -> [Int64] {
        guard to >= from else { return [] }
        var out: [Int64] = []
        var h = windowStart(from)
        while h <= to { out.append(h); h += rawHourSeconds }
        return out
    }

    /// `enqueue` of a raw drop: the frames of the offered file (`raw_export.frame_ids`) become exported — one watermark
    /// and one counter update per hour, no per-frame writes.
    func noteRawExported(_ db: Database, from: Int64, to: Int64) throws {
        guard let blob = try Data.fetchOne(db, sql: """
            SELECT frame_ids FROM raw_export WHERE ts_from = ? AND ts_to = ? AND state = 'offered'
            """, arguments: [from, to]) else { return }
        let ids = Set(MGStore.rawFrameIDs(blob))
        if !ids.isEmpty {
            var oldWm: [Int64: Int64] = [:]
            for h in MGStore.rawHours(from: from, to: to) {
                oldWm[h] = try Int64.fetchOne(db, sql: "SELECT exported_wm FROM raw_hour WHERE hour = ?", arguments: [h]) ?? 0
            }
            var newWm: [Int64: Int64] = [:]
            var added: [Int64: Int] = [:]
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT id, CAST(received_at AS INTEGER) AS s, exported FROM raw_frame
                WHERE received_at >= ? AND received_at < ?
                """, arguments: [Double(from), Double(to) + 1])
            while let row = try cursor.next() {
                let id: Int64 = row["id"]
                guard ids.contains(id) else { continue }
                let s: Int64 = row["s"]
                let flag: Int = row["exported"]
                let h = MGStore.windowStart(s)
                if flag == 0 && id > (oldWm[h] ?? 0) { added[h, default: 0] += 1 }
                newWm[h] = max(newWm[h] ?? 0, id)
            }
            for (h, wm) in newWm {
                try db.execute(sql: """
                    UPDATE raw_hour SET exported_wm = max(exported_wm, ?), exported_frames = exported_frames + ?
                    WHERE hour = ?
                    """, arguments: [wm, added[h] ?? 0, h])
            }
        }
        try db.execute(sql: "UPDATE raw_export SET state = 'enqueued', at = ? WHERE ts_from = ? AND ts_to = ?",
                       arguments: [nowUnix, from, to])
    }

    /// `markDelivered` of a raw drop (same transaction): the PC has the drop's frames. See the type comment for why
    /// the watermark only moves when no other raw drop of those hours is undelivered.
    func noteRawConfirmed(_ db: Database, from: Int64, to: Int64) throws {
        guard let blob = try Data.fetchOne(db, sql: """
            SELECT frame_ids FROM raw_export WHERE ts_from = ? AND ts_to = ? AND state = 'enqueued'
            """, arguments: [from, to]) else { return }
        let hours = MGStore.rawHours(from: from, to: to)
        var othersOpen = false
        for h in hours {
            if try Int.fetchOne(db, sql: """
                SELECT 1 FROM outbox_drop
                WHERE kind = 'raw' AND state != 'delivered' AND strap_ts_start <= ? AND strap_ts_end >= ? LIMIT 1
                """, arguments: [h + MGStore.rawHourSeconds - 1, h]) != nil {
                othersOpen = true
                break
            }
        }
        if !othersOpen {
            // every exported frame of these hours is in a delivered drop: confirmed = exported
            for h in hours {
                try db.execute(sql: """
                    UPDATE raw_hour SET confirmed_wm = max(confirmed_wm, exported_wm), confirmed_frames = exported_frames
                    WHERE hour = ?
                    """, arguments: [h])
            }
            return
        }
        let stmt = try db.cachedStatement(sql: "UPDATE raw_frame SET pc_confirmed = 1 WHERE id = ? AND pc_confirmed = 0")
        for id in MGStore.rawFrameIDs(blob) { try stmt.execute(arguments: [id]) }
        for h in hours { try recountConfirmed(db, hour: h) }
    }

    /// Recounts one hour's `confirmed_frames` from the frames (flag or watermark). The exception path and the check.
    func recountConfirmed(_ db: Database, hour h: Int64) throws {
        try db.execute(sql: """
            UPDATE raw_hour SET confirmed_frames = (
                SELECT COUNT(*) FROM raw_frame WHERE received_at >= ? AND received_at < ?
                  AND (pc_confirmed = 1 OR id <= raw_hour.confirmed_wm))
            WHERE hour = ?
            """, arguments: [Double(h), Double(h + MGStore.rawHourSeconds), h])
    }

    /// Hours whose stored counters differ from a recount of `raw_frame` (frames, bytes, exported, confirmed). Empty =
    /// consistent. Scans the whole table: for tests and a manual check, never on a timer.
    public func rawHourMismatches() async throws -> [Int64] {
        try syncRead { db in
            var bad: [Int64] = []
            for row in try Row.fetchAll(db, sql: "SELECT hour, frames, bytes, exported_frames, confirmed_frames FROM raw_hour") {
                let h: Int64 = row["hour"]
                guard let c = try Row.fetchOne(db, sql: """
                    SELECT COUNT(*) AS n, COALESCE(SUM(length(f.bytes)), 0) AS b,
                           COALESCE(SUM(f.exported = 1 OR f.id <= h.exported_wm), 0) AS e,
                           COALESCE(SUM(f.pc_confirmed = 1 OR f.id <= h.confirmed_wm), 0) AS c
                    FROM raw_frame f, raw_hour h
                    WHERE h.hour = ? AND f.received_at >= h.hour AND f.received_at < h.hour + 3600
                    """, arguments: [h]) else { continue }
                let same = (row["frames"] as Int) == (c["n"] as Int) && (row["bytes"] as Int64) == (c["b"] as Int64)
                    && (row["exported_frames"] as Int) == (c["e"] as Int)
                    && (row["confirmed_frames"] as Int) == (c["c"] as Int)
                if !same { bad.append(h) }
            }
            return bad.sorted()
        }
    }
}
