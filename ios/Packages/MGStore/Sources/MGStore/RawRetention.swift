import Foundation
import GRDB
import MGDomain

/// What one `pruneConfirmed(maxBatches:)` call did (r8l, 2026-10-17). Counts are rows, bytes are freed payload bytes.
public struct PruneReport: Sendable, Equatable {
    public var at: Date
    public var rawFrames = 0
    /// hr_sample / rr_interval / r18_second rows deleted.
    public var perSecondRows: [String: Int] = [:]
    /// Raw-motion rows whose packed columns were emptied.
    public var motionPacked = 0
    /// Outbox copies emptied (rows, sizes, sha256 and receipts stay) and the bytes they held.
    public var outboxCopies = 0
    public var outboxBytes = 0
    /// `ppg_block` rows whose payload was emptied and the bytes it held.
    public var ppgRows = 0
    public var ppgBytes: Int64 = 0
    /// Older `lab_result` versions deleted (the newest per date and model stays).
    public var labResults = 0
    /// Outbox copies now held deflated, and the bytes that saved.
    public var outboxCompressed = 0
    public var outboxCompressedSavedBytes: Int64 = 0
    /// Transactions that changed something.
    public var batches = 0
    /// Nothing left to do under the rules; false = stopped at `maxBatches` (call again) or at `error`.
    public var complete = false
    public var error: String?

    public init(at: Date) { self.at = at }

    /// The same numbers in the shape `lastPhoneRetention` keeps (Strap & sync).
    public var phoneRetention: PhoneRetentionReport {
        PhoneRetentionReport(at: at, rawFrames: rawFrames, perSecondRows: perSecondRows, outboxCopies: outboxCopies,
                             outboxBytes: outboxBytes)
    }
}

public struct RawRetentionReport: Sendable, Equatable {
    /// Frames newly pinned (keep 0 → 1) around events and strap events.
    public var pinnedAroundEvents: Int
    /// Frames newly pinned by the random daily background block.
    public var pinnedDailyBlocks: Int
    /// Unpinned frames older than the ring buffer, deleted.
    public var pruned: Int

    public init(pinnedAroundEvents: Int, pinnedDailyBlocks: Int, pruned: Int) {
        self.pinnedAroundEvents = pinnedAroundEvents; self.pinnedDailyBlocks = pinnedDailyBlocks; self.pruned = pruned
    }
}

/// CHANGED 2026-10-11 (Mo, strap-raw-optical brief D; replaces ALG-006 v1's ring and upload rule). It used to say:
/// "raw strap frames live in a 48 h ring buffer; frames pinned with `keep = 1` survive it and are the only raw that is
/// uploaded (D11)". Now EVERY raw frame is uploaded (raw drops; since #74, 2026-10-11, on any connection outside Low
/// Data Mode, with every sync: MGDomain `RawUploadPolicy`), and the phone deletes raw
/// frames and per-second rows (hr_sample, rr_interval, r18_second) only when they are older than 30 days
/// (`phoneKeepSeconds`) AND confirmed received by the PC (the drop that carried them is delivered with matching
/// receipts: `confirmDeliveredDrop`). Pins below still
/// mark frames `keep = 1` (around events) but no longer decide upload or deletion.
/// CHANGED 2026-10-17 (r8l, audit §3.2): it used to say "ppg_block is never pruned: no ppg stream reaches the PC yet".
/// The PC gets R20 only as raw frames (the same bytes), so `ppg_block` payloads and the outbox copies are now emptied
/// `confirmedHoldSeconds` after the PC confirmed them (`pruneConfirmed(maxBatches:)`); raw frames stay the one copy.
///
/// ALG-006 v1 — raw retention (ALGORITHM-REQUIREMENTS ALG-006; ARCHITECTURE §4.5). Pins:
///
/// | Trigger | Window |
/// |---|---|
/// | strap event 14 DOUBLE_TAP (noop:Strand/Collect/FrameRouter.swift L851-859, ARCHITECTURE §4.4.6) | ±2 min |
/// | strap events 9 WRIST_ON / 10 WRIST_OFF, and `wear` events (wear-state changes) | ±2 min |
/// | `workout` events: start and end ("workout transitions") | ±2 min around each |
/// | `nap` events: end | ±2 min |
/// | `ecg` events: the whole session [at, end] ("all ECG") | ±2 min |
/// | `bp_cuff` events (cuff readings) | ±5 min |
/// | `breathing_event` events | ±30 min (the low end of ALG-006's 30–60 min) |
/// | one random 5-min block per completed local day that has frames ("random daily background sample") | 5 min |
extension MGStore {

    /// Pins frames whose receive time is in [from, to]. Returns frames newly pinned.
    @discardableResult
    public func pinRawFrames(from: Date, to: Date) async throws -> Int {
        try syncWrite { db in try pin(db, from.unix, to.unix) }
    }

    /// Deletes raw frames received before `now − 30 days` that the PC has confirmed (2026-10-11; it used to delete
    /// unpinned frames older than 48 h, uploaded or not). Returns frames deleted.
    @discardableResult
    public func pruneRawFrames(now: Date? = nil) async throws -> Int {
        try await pruneConfirmed(now: now).rawFrames
    }

    /// Seconds a CONFIRMED copy is held before it is dropped from the phone (r8l, 2026-10-17, audit §3.2; Mo approved the
    /// retention design with the audit, "3-7 days after the PC confirms"; Mo had chosen 30, so 30 it stays until he says otherwise). Applies to the outbox copies (after
    /// delivery with matching receipts) and the `ppg_block` payloads (after the PC has confirmed the raw frames they came
    /// from). Raw frames and per-second rows keep `phoneKeepSeconds` (30 days). Before r8l the outbox copies were held 30 days.
    /// 30 days: Mo's own choice (2026-10-11, "Yes, after 30 days"). r8l had set 5 days from the audit; the brain put it
    /// back to 30 (2026-10-17) because Mo chose 30 explicitly - shortening it is his call (asked in the round 8 report).
    /// CHANGED 2026-10-17 ~8 PM PT (Mo, D-DB-060 (C)): 7 days after the PC confirms; was 30 days (Mo, Oct 11).
    public static let confirmedHoldSeconds: TimeInterval = 7 * 86_400

    /// Rows per transaction in `pruneConfirmed`; every step deletes or empties at most this many rows per batch.
    public static let pruneBatchRows = 2000

    /// `ppg_block` is stamped with the strap's clock, raw frames with the phone's receive time. History synced late
    /// arrives long after its seconds, so a `ppg_block` second is only emptied once its time is this far (3 days) before
    /// the oldest raw hour the PC has not confirmed: a late-arriving second's frames are then never an unconfirmed frame.
    static let ppgReceiveLagSeconds: Int64 = 3 * 86_400

    /// The retention pass for the App to call when the phone is idle / charging (App wiring: the brain, later). Runs at
    /// most `maxBatches` small transactions (`pruneBatchRows` rows each), so a big backlog never holds the database for
    /// long; call it again until `complete`. Never throws: a failure stops the pass and comes back in `error`.
    /// Only data the PC has CONFIRMED is touched; nothing unconfirmed is ever deleted or emptied:
    /// - raw frames and raw-motion payloads: confirmed and older than `confirmedHoldSeconds` (7 d, D-DB-060, 2026-10-17;
    ///   was `phoneKeepSeconds`, 30 d); hr / rr / r18 rows: confirmed and older than `phoneKeepSeconds` (30 d, screens read them);
    /// - outbox copies of delivered drops: `confirmedHoldSeconds` after delivery (receipts matched); the row, sizes,
    ///   sha256 and receipt stay, only the blob goes;
    /// - `ppg_block` payloads (`samples`, `r20_blocks`): `confirmedHoldSeconds` old and covered by confirmed raw (see
    ///   `ppgReceiveLagSeconds`); the row (ts, rate) stays and `pruned_at` says when;
    /// - `lab_result`: only the newest (highest `seq`) per (date, model_id) is kept;
    /// - housekeeping: outbox copies written before v12 are deflated at rest.
    public func pruneConfirmed(maxBatches: Int, now: Date? = nil) async -> PruneReport {
        let nowDate = now ?? clock.now
        var report = PruneReport(at: nowDate)
        do {
            try runPrune(&report, maxBatches: max(0, maxBatches), now: nowDate)
            if report.complete { try storeRetentionReport(report) }
        } catch {
            report.error = "\(error)"
        }
        return report
    }

    /// The phone-side retention pass (2026-10-11), run to the end: everything `pruneConfirmed(maxBatches:)` does, with no
    /// batch limit. A per-second row is confirmed when a delivered streams drop of its kind covered its strap second and
    /// was built after the row existed (`id <= id_snapshot`). The report is kept (`lastPhoneRetention`) so Strap & sync can
    /// show it. Changed r8l 2026-10-17: the outbox copies go `confirmedHoldSeconds` (30 days) after delivery (Mo
    /// had said "Yes, after 30 days" on 2026-10-11; the retention design of the 2026-10-17 audit replaces it).
    public func pruneConfirmed(now: Date? = nil) async throws -> PhoneRetentionReport {
        let nowDate = now ?? clock.now
        var report = PruneReport(at: nowDate)
        try runPrune(&report, maxBatches: Int.max, now: nowDate)
        try storeRetentionReport(report)
        return report.phoneRetention
    }

    private func storeRetentionReport(_ report: PruneReport) throws {
        let legacy = report.phoneRetention
        try syncWrite { db in try putKV(db, MGStore.phoneRetentionKey, try DocJSON.encode(legacy)) }
    }

    private enum PruneStep: CaseIterable { case rawFrames, hr, rr, r18, motion, outbox, ppg, labResult, compress }

    private func runPrune(_ report: inout PruneReport, maxBatches: Int, now: Date) throws {
        var done = Set<PruneStep>()
        while report.batches < maxBatches && done.count < PruneStep.allCases.count {
            for step in PruneStep.allCases where !done.contains(step) {
                if report.batches >= maxBatches { break }
                let r = try syncWrite { db in try pruneStep(step, db, now: now) }
                let size = step == .compress ? 8 : (step == .labResult ? 500 : MGStore.pruneBatchRows)
                if r.rows < size { done.insert(step) }
                guard r.rows > 0 else { continue }
                report.batches += 1
                switch step {
                case .rawFrames: report.rawFrames += r.rows
                case .hr: report.perSecondRows["hr_sample", default: 0] += r.rows
                case .rr: report.perSecondRows["rr_interval", default: 0] += r.rows
                case .r18: report.perSecondRows["r18_second", default: 0] += r.rows
                case .motion: report.motionPacked += r.rows
                case .outbox: report.outboxCopies += r.rows; report.outboxBytes += Int(r.bytes)
                case .ppg: report.ppgRows += r.rows; report.ppgBytes += r.bytes
                case .labResult: report.labResults += r.rows
                case .compress: report.outboxCompressed += r.rows; report.outboxCompressedSavedBytes += r.bytes
                }
            }
        }
        report.complete = done.count == PruneStep.allCases.count
    }

    /// One batch of one step in its own transaction. Returns rows touched and bytes freed.
    private func pruneStep(_ step: PruneStep, _ db: Database, now: Date) throws -> (rows: Int, bytes: Int64) {
        let limit = MGStore.pruneBatchRows
        let cutoff = RawUploadPolicy.deleteCutoff(now: now)      // = RawUploadPolicy.mayDelete, as SQL
        let tsCutoff = Int64(cutoff.rounded(.down))
        let hold = now.unix - MGStore.confirmedHoldSeconds
        switch step {
        case .rawFrames:
            // confirmed = own flag OR id at or below its hour's confirmed watermark (RawHourState.swift)
            try db.execute(sql: """
                DELETE FROM raw_frame WHERE id IN (
                    SELECT f.id FROM raw_frame f
                    WHERE f.received_at < ?
                      AND (f.pc_confirmed = 1 OR f.id <= COALESCE((SELECT h.confirmed_wm FROM raw_hour h
                              WHERE h.hour = (CAST(f.received_at AS INTEGER) / 3600) * 3600), 0))
                    ORDER BY f.received_at LIMIT ?)
                """, arguments: [hold, limit])     // D-DB-060 (C), Mo 2026-10-17: raw bytes go 7 d after the PC confirms (was the 30-day cutoff)
            return (db.changesCount, 0)
        case .hr, .rr, .r18:
            let table = step == .hr ? "hr_sample" : (step == .rr ? "rr_interval" : "r18_second")
            let kind: StreamKind = step == .hr ? .hr : (step == .rr ? .rr : .r18)
            try db.execute(sql: """
                DELETE FROM \(table) WHERE id IN (
                    SELECT s.id FROM \(table) s WHERE s.ts < ? AND EXISTS (
                        SELECT 1 FROM stream_export e
                        WHERE e.kind = ? AND e.pc_confirmed = 1 AND s.ts BETWEEN e.ts_from AND e.ts_to
                          AND s.id <= e.id_snapshot)
                    LIMIT ?)
                """, arguments: [tsCutoff, kind.rawValue, limit])
            return (db.changesCount, 0)
        case .motion:
            // Wave W11 (2026-10-11 21:43, raw motion streams whenever the strap is connected): a raw-motion row's packed
            // 100 Hz columns are raw too, so they follow the raw rule — emptied past the cutoff once no raw frame from
            // before the cutoff is still unconfirmed by the PC. The 1 Hz summaries (acc_*, enmo_lsb) stay.
            try db.execute(sql: """
                UPDATE motion_second SET packed = x'' WHERE id IN (
                    SELECT id FROM motion_second WHERE ts < ? AND length(packed) > 0 LIMIT ?)
                  AND NOT EXISTS (SELECT 1 FROM raw_hour WHERE frames > confirmed_frames AND hour < ?)
                """, arguments: [Int64(hold.rounded(.down)), limit, hold])   // D-DB-060 (C): 100 Hz raw follows the 7-day rule; 1 Hz summaries and hr/rr/r18 rows keep the 30-day cutoff
            return (db.changesCount, 0)
        case .outbox:
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS r, length(blob) AS n FROM outbox_file
                WHERE blob_pruned_at IS NULL AND receipt_json IS NOT NULL AND drop_id IN (
                    SELECT drop_id FROM outbox_drop WHERE state = 'delivered' AND delivered_at < ?)
                LIMIT ?
                """, arguments: [hold, limit])
            guard !rows.isEmpty else { return (0, 0) }
            var bytes: Int64 = 0
            var ids: [Int64] = []
            for r in rows {
                bytes += (r["n"] as Int64?) ?? 0
                ids.append(r["r"] as Int64)
            }
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(sql: "UPDATE outbox_file SET blob = x'', blob_enc = NULL, blob_pruned_at = ? WHERE rowid IN (\(marks))",
                           arguments: StatementArguments([now.unix] + ids.map { $0 as any DatabaseValueConvertible }))
            return (ids.count, bytes)
        case .ppg:
            var limitTs = Int64(hold.rounded(.down))
            if let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(hour) FROM raw_hour WHERE frames > confirmed_frames") {
                limitTs = min(limitTs, oldest - MGStore.ppgReceiveLagSeconds)
            }
            let pick = "SELECT id FROM ppg_block WHERE pruned_at IS NULL AND ts < ? ORDER BY ts LIMIT ?"
            let bytes = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(length(samples) + COALESCE(length(r20_blocks), 0)), 0) FROM ppg_block
                WHERE id IN (\(pick))
                """, arguments: [limitTs, limit]) ?? 0
            try db.execute(sql: """
                UPDATE ppg_block SET samples = x'', r20_blocks = NULL, pruned_at = ? WHERE id IN (\(pick))
                """, arguments: [now.unix, limitTs, limit])
            return (db.changesCount, bytes)
        case .labResult:
            // newest `seq` per (date, model_id) stays; the global newest is among them, so `resultsCursor` is unchanged
            try db.execute(sql: """
                DELETE FROM lab_result WHERE rowid IN (
                    SELECT r FROM (
                        SELECT rowid AS r, ROW_NUMBER() OVER (PARTITION BY date, model_id ORDER BY seq DESC) AS rn
                        FROM lab_result) WHERE rn > 1 LIMIT ?)
                """, arguments: [500])
            return (db.changesCount, 0)
        case .compress:
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS r, name, blob FROM outbox_file WHERE blob_enc IS NULL AND blob_pruned_at IS NULL LIMIT 8
                """)
            var saved: Int64 = 0
            for row in rows {
                let blob: Data = row["blob"]
                let name: String = row["name"]
                let id: Int64 = row["r"]
                let (stored, enc) = MGStore.atRest(name: name, blob: blob)
                saved += Int64(blob.count - stored.count)
                try db.execute(sql: "UPDATE outbox_file SET blob = ?, blob_enc = ? WHERE rowid = ?",
                               arguments: [stored, enc, id])
            }
            return (rows.count, saved)
        }
    }

    static let phoneRetentionKey = "phone_retention.last"

    /// The last `pruneConfirmed` report; nil before the first one.
    public func lastPhoneRetention() async throws -> PhoneRetentionReport? {
        guard let data = try await value(forKey: MGStore.phoneRetentionKey) else { return nil }
        return try DocJSON.decode(PhoneRetentionReport.self, data)
    }

    /// The whole ALG-006 pass in one transaction: pin around triggers seen within the ring buffer (plus a day of
    /// look-back for long workouts / ECG ends), pick the daily random blocks, then prune.
    public func runRawRetention(now: Date? = nil) async throws -> RawRetentionReport {
        let nowDate = now ?? clock.now
        let cutoff = nowDate.unix - MGStore.rawRingSeconds
        return try syncWrite { db in
            var aroundEvents = 0
            // Strap events (strap ts = unix seconds after the clock set, ALG-002).
            let strapRows = try Row.fetchAll(db, sql: """
                SELECT ts, number FROM strap_event WHERE number IN (14, 9, 10) AND ts >= ?
                """, arguments: [Int64(cutoff) - 120])
            for row in strapRows {
                let ts: Int64 = row["ts"]
                aroundEvents += try pin(db, Double(ts) - 120, Double(ts) + 120)
            }
            // App events (removed ones too: the moment still happened or was logged; the pin costs only storage).
            let eventRows = try Row.fetchAll(db, sql: """
                SELECT type, at_unix, json FROM event
                WHERE type IN ('wear', 'workout', 'nap', 'ecg', 'bp_cuff', 'breathing_event') AND at_unix >= ?
                """, arguments: [cutoff - 86_400])
            for row in eventRows {
                let type: String = row["type"]
                let at: Double = row["at_unix"]
                let json: Data = row["json"]
                var end: Double?
                if let obj = try? DocJSON.object(json), let s = obj["end"] as? String, let d = ContractDate.parse(s) {
                    end = d.unix
                }
                switch type {
                case "wear":
                    aroundEvents += try pin(db, at - 120, at + 120)
                case "workout":
                    aroundEvents += try pin(db, at - 120, at + 120)
                    if let end { aroundEvents += try pin(db, end - 120, end + 120) }
                case "nap":
                    if let end { aroundEvents += try pin(db, end - 120, end + 120) }
                case "ecg":
                    aroundEvents += try pin(db, at - 120, (end ?? at) + 120)
                case "bp_cuff":
                    aroundEvents += try pin(db, at - 300, at + 300)
                case "breathing_event":
                    aroundEvents += try pin(db, at - 1800, at + 1800)
                default:
                    break
                }
            }
            let daily = try pinDailyBlocks(db, now: nowDate)
            // 2026-10-11: no 48 h ring any more — deletion is `pruneConfirmed` (confirmed by the PC and 30 days old).
            return RawRetentionReport(pinnedAroundEvents: aroundEvents, pinnedDailyBlocks: daily, pruned: 0)
        }
    }

    func pin(_ db: Database, _ from: Double, _ to: Double) throws -> Int {
        try db.execute(sql: "UPDATE raw_frame SET keep = 1 WHERE keep = 0 AND received_at BETWEEN ? AND ?",
                       arguments: [from, to])
        return db.changesCount
    }

    /// One random 5-min block per completed local day that still has frames, chosen once (kept in `kv`), starting at a
    /// randomly chosen frame of that day so the block holds data.
    func pinDailyBlocks(_ db: Database, now: Date) throws -> Int {
        let today = localDay(now).iso
        guard let oldest = try Double.fetchOne(db, sql: "SELECT MIN(received_at) FROM raw_frame") else { return 0 }
        var pinned = 0
        var dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: oldest))
        while true {
            let day = localDay(dayStart).iso
            if day >= today { break }
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let key = "raw_daily_block." + day
            let chosen = try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]) != nil
            if !chosen {
                let times = try Double.fetchAll(db, sql: """
                    SELECT received_at FROM raw_frame WHERE received_at >= ? AND received_at < ? ORDER BY received_at
                    """, arguments: [dayStart.unix, next.unix])
                if let start = times.randomElement() {
                    pinned += try pin(db, start, start + 300)
                    try putKV(db, key, Data(String(start).utf8))
                }
            }
            dayStart = next
        }
        return pinned
    }

    // MARK: Raw upload (since 2026-10-11 every frame, not only kept ones; when: MGDomain RawUploadPolicy, #74 — this
    // line used to say "Wi-Fi + charging decided by the caller")

    /// Ranges of not yet exported frames for `raw_<strap_id>_<from>_<to>` drops (§5.4), unix seconds inclusive:
    /// one per UTC-hour window that ended `streamSettleSeconds` ago. A window's first drop covers the whole window;
    /// frames pinned there later go out as `[first, last]` of those frames, nudged by a second if needed so no two
    /// enqueued raw drops share an id (raw drops are immutable on the PC).
    public func pendingRawRanges() async throws -> [(from: Int64, to: Int64)] {
        let cutoff = Int64(nowUnix.rounded(.down)) - MGStore.streamSettleSeconds
        let w = MGStore.streamWindowSeconds
        return try syncRead { db in
            // r8l 2026-10-17 (audit §3.3): read the per-hour state, not `raw_frame` (it used to scan the table for
            // `exported = 0` on every sync pass). An hour has frames to send when it holds more frames than were exported.
            let windows = try Int64.fetchAll(db, sql: """
                SELECT hour FROM raw_hour WHERE frames > exported_frames AND hour + ? <= ? ORDER BY hour
                """, arguments: [w, cutoff])
            var out: [(from: Int64, to: Int64)] = []
            for start in windows {
                let end = start + w - 1
                func taken(_ a: Int64, _ b: Int64) throws -> Bool {
                    try Int.fetchOne(db, sql: """
                        SELECT 1 FROM raw_export WHERE ts_from = ? AND ts_to = ? AND state = 'enqueued'
                        """, arguments: [a, b]) != nil
                }
                if try !taken(start, end) { out.append((start, end)); continue }
                let wm = try Int64.fetchOne(db, sql: "SELECT exported_wm FROM raw_hour WHERE hour = ?", arguments: [start]) ?? 0
                let span = try Row.fetchOne(db, sql: """
                    SELECT CAST(MIN(received_at) AS INTEGER) AS lo, CAST(MAX(received_at) AS INTEGER) AS hi
                    FROM raw_frame WHERE exported = 0 AND id > ? AND received_at >= ? AND received_at < ?
                    """, arguments: [wm, Double(start), Double(end) + 1])
                guard let span, let lo = span["lo"] as Int64?, let hi = span["hi"] as Int64? else { continue }
                var from = lo, to = hi, unique = false
                while !unique {
                    if try !taken(from, to) { unique = true } else if to < end { to += 1 } else if from > start { from -= 1 } else { break }
                }
                if unique { out.append((from, to)) }
            }
            return out
        }
    }

    /// Frames received in [from, to] (unix seconds, inclusive) **not yet exported**, in the §5.4 raw file layout,
    /// uncompressed: repeated `[u32 LE frame length][u8 packet_type][f64 LE received_at unix][frame bytes]`. The frame
    /// ids are recorded so `enqueue` of the matching raw drop marks exactly these frames exported (a frame pinned
    /// after this call is not marked, and goes out in a later drop).
    public func rawFramesFile(from: Int64, to: Int64) async throws -> (data: Data, frames: Int) {
        let now = nowUnix
        return try syncWrite { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, received_at, packet_type, bytes FROM raw_frame
                WHERE exported = 0 AND received_at >= ? AND received_at < ?
                  AND id > COALESCE((SELECT h.exported_wm FROM raw_hour h
                                     WHERE h.hour = (CAST(raw_frame.received_at AS INTEGER) / 3600) * 3600), 0)
                ORDER BY received_at, packet_type, crc32, strap_id
                """, arguments: [Double(from), Double(to) + 1])
            var out = Data()
            var idBlob = Data()
            for r in rows {
                let id: Int64 = r["id"], at: Double = r["received_at"], type: Int = r["packet_type"]
                let bytes: Data = r["bytes"]
                idBlob.append(MGStore.u64LE(UInt64(bitPattern: id)))
                out.append(MGStore.u32LE(UInt32(bytes.count)))
                out.append(UInt8(truncatingIfNeeded: type))
                out.append(MGStore.u64LE(at.bitPattern))
                out.append(bytes)
            }
            try db.execute(sql: """
                INSERT INTO raw_export (ts_from, ts_to, frame_ids, state, at) VALUES (?, ?, ?, 'offered', ?)
                ON CONFLICT(ts_from, ts_to) DO UPDATE SET frame_ids = excluded.frame_ids, at = excluded.at
                WHERE state = 'offered'
                """, arguments: [from, to, idBlob, now])
            return (out, rows.count)
        }
    }

    static func u32LE(_ v: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
              UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)])
    }

    static func u64LE(_ v: UInt64) -> Data {
        Data((0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) })
    }
}
