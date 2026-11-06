import Foundation
import GRDB
import MGDomain

/// The sync outbox (§4.5 `outbox_drop` / `outbox_file`, §5.5). A drop's bytes are kept here until the PC's receipts
/// match. CHANGED 2026-10-11 (Mo, in chat: "Yes, after 30 days"); this line used to read "nothing is ever deleted
/// because of a sync (§5.5)". Now `pruneConfirmed` (RawRetention.swift) empties the stored compressed copy of an outbox
/// file once its drop was delivered with matching receipts more than 30 days ago; the outbox row, sizes, sha256 and
/// receipt are kept (`blob_pruned_at` says when the copy went). Nothing undelivered is ever touched.
/// CHANGED 2026-10-17 (r8l, audit §3.2, approved by Mo with the audit): the hold is now `MGStore.confirmedHoldSeconds`
/// (`confirmedHoldSeconds` after delivery: 30 days, Mo 2026-10-11). Copies of plain files (the day drops'
/// JSON) are also stored deflated (`blob_enc`), inflated again by `pending()`.
extension MGStore: SyncOutbox {

    /// Stores a drop and its file bytes in one transaction. Idempotent by `drop_id`: a drop already in the outbox is
    /// left as it is (content-addressed / strap-ts ids mean same id = same bytes). Side effects, same transaction:
    /// - `day` drop: the day stops being dirty up to the change generation its last `dayBundle` read (a change made
    ///   after that bundle keeps it dirty);
    /// - `streams` drop: the offered range is marked enqueued (see `pendingStreamRanges`);
    /// - `raw` drop: the frames offered for that range are marked exported (see `rawFramesFile`).
    public func enqueue(_ drop: OutboxDrop) async throws {
        let dayGen = drop.localDay.flatMap { bundleGen[$0.iso] }
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO outbox_drop (drop_id, kind, local_day, strap_ts_start, strap_ts_end, manifest_json, state,
                    attempts, last_error, created_at, delivered_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(drop_id) DO NOTHING
                """, arguments: [drop.dropId, drop.kind.rawValue, drop.localDay?.iso, drop.strapTsStart,
                                 drop.strapTsEnd, drop.manifest, drop.state.rawValue, drop.attempts, drop.lastError,
                                 drop.createdAt.unix, drop.deliveredAt?.unix])
            let fileStmt = try db.cachedStatement(sql: """
                INSERT INTO outbox_file (drop_id, name, bytes, sha256, records, blob, blob_enc) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(drop_id, name) DO NOTHING
                """)
            for f in drop.files {
                let (stored, enc) = MGStore.atRest(name: f.name, blob: f.blob)
                try fileStmt.execute(arguments: [drop.dropId, f.name, f.bytes, f.sha256, f.records, stored, enc])
            }
            switch drop.kind {
            case .day:
                if let day = drop.localDay, let gen = dayGen {
                    try db.execute(sql: "DELETE FROM day_dirty WHERE local_day = ? AND gen <= ?",
                                   arguments: [day.iso, gen])
                }
            case .streams:
                if let from = drop.strapTsStart, let to = drop.strapTsEnd,
                   let kind = MGStore.streamKind(fileNames: drop.files.map(\.name)) {
                    try noteStreamsEnqueued(db, kind: kind, from: from, to: to)
                }
            case .raw:
                if let from = drop.strapTsStart, let to = drop.strapTsEnd {
                    try noteRawExported(db, from: from, to: to)
                }
            case .ecg:
                break      // T9821: nothing to mark; the saved trace stays on the phone like every other record
            }
        }
        if let day = drop.localDay, drop.kind == .day { bundleGen[day.iso] = nil }
    }

    /// Drops not yet delivered (pending, uploading or failed), oldest first, with their file bytes.
    public func pending() async throws -> [OutboxDrop] {
        try syncRead { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT drop_id, kind, local_day, strap_ts_start, strap_ts_end, manifest_json, state, attempts,
                       last_error, created_at, delivered_at
                FROM outbox_drop WHERE state != 'delivered' ORDER BY created_at, drop_id
                """)
            return try rows.compactMap { row -> OutboxDrop? in
                let dropId: String = row["drop_id"]
                let kindRaw: String = row["kind"]
                let stateRaw: String = row["state"]
                guard let kind = DropKind(rawValue: kindRaw), let state = OutboxState(rawValue: stateRaw) else {
                    return nil
                }
                let files = try Row.fetchAll(db, sql: """
                    SELECT name, bytes, sha256, records, blob, blob_enc FROM outbox_file WHERE drop_id = ? ORDER BY name
                    """, arguments: [dropId]).map { f in
                    let enc: String? = f["blob_enc"]
                    return OutboxFile(name: f["name"], bytes: f["bytes"], sha256: f["sha256"], records: f["records"],
                                      blob: try MGStore.fromRest(f["blob"], enc: enc))
                }
                let day: String? = row["local_day"]
                let created: Double = row["created_at"]
                let delivered: Double? = row["delivered_at"]
                return OutboxDrop(dropId: dropId, kind: kind, localDay: day.flatMap { LocalDay(iso: $0) },
                                  strapTsStart: row["strap_ts_start"], strapTsEnd: row["strap_ts_end"],
                                  manifest: row["manifest_json"], files: files, state: state,
                                  attempts: row["attempts"], lastError: row["last_error"],
                                  createdAt: Date(timeIntervalSince1970: created),
                                  deliveredAt: delivered.map(Date.init(timeIntervalSince1970:)))
            }
        }
    }

    /// Marks a drop delivered and keeps each file's receipt. Second line of the §5.5 rule (MGSync checks first): every
    /// file needs a receipt with the same `name`, `bytes`, `sha256` and `records`, read from the receipt's contract keys;
    /// otherwise this throws `receiptMismatch` and the drop stays undelivered.
    public func markDelivered(_ dropId: String, receipts: [SyncReceipt]) async throws {
        var byName: [String: (json: Data, obj: [String: Any])] = [:]
        for r in receipts {
            let json = try DocJSON.encode(r)
            let obj = try DocJSON.object(json)
            byName[try DocJSON.string(obj, "name", what: "syncReceipt")] = (json, obj)
        }
        let now = nowUnix
        try syncWrite { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM outbox_drop WHERE drop_id = ?", arguments: [dropId]) != nil
            else { throw MGStoreError.unknownDrop(dropId) }
            let files = try Row.fetchAll(db, sql: "SELECT name, bytes, sha256, records FROM outbox_file WHERE drop_id = ?",
                                         arguments: [dropId])
            for f in files {
                let name: String = f["name"], bytes: Int = f["bytes"], sha: String = f["sha256"]
                let records: Int = f["records"]
                guard let receipt = byName[name] else {
                    throw MGStoreError.receiptMismatch(dropId: dropId, detail: "no receipt for \(name)")
                }
                let rBytes = DocJSON.int(receipt.obj, "bytes"), rRecords = DocJSON.int(receipt.obj, "records")
                let rSha = (receipt.obj["sha256"] as? String)?.lowercased()
                guard rBytes == bytes, rRecords == records, rSha == sha.lowercased() else {
                    throw MGStoreError.receiptMismatch(dropId: dropId, detail:
                        "\(name): phone \(bytes) B / \(records) rec / \(sha), PC \(rBytes.map(String.init) ?? "-") B / "
                        + "\(rRecords.map(String.init) ?? "-") rec / \(rSha ?? "-")")
                }
                try db.execute(sql: "UPDATE outbox_file SET receipt_json = ? WHERE drop_id = ? AND name = ?",
                               arguments: [receipt.json, dropId, name])
            }
            try db.execute(sql: """
                UPDATE outbox_drop SET state = 'delivered', delivered_at = ?, last_error = NULL WHERE drop_id = ?
                """, arguments: [now, dropId])
            try confirmDeliveredDrop(db, dropId)   // same transaction: delivered ⇔ its data is confirmed
        }
    }

    /// Marks what a DELIVERED drop carried as confirmed by the PC (2026-10-11): a raw drop's frames (the ids recorded
    /// when its file was built, `raw_export.frame_ids`), a streams drop's export range (`stream_export`). Nothing for a
    /// drop that is not delivered, and nothing for a day drop (its rows are never pruned).
    /// The live path (r8l): a raw drop moves its hours' watermark (`noteRawConfirmed`); everything else is the static
    /// `confirmDeliveredDropFlags` below.
    func confirmDeliveredDrop(_ db: Database, _ dropId: String) throws {
        if let row = try Row.fetchOne(db, sql: """
            SELECT strap_ts_start, strap_ts_end FROM outbox_drop WHERE drop_id = ? AND state = 'delivered' AND kind = 'raw'
            """, arguments: [dropId]) {
            if let from: Int64 = row["strap_ts_start"], let to: Int64 = row["strap_ts_end"] {
                try noteRawConfirmed(db, from: from, to: to)
            }
            return
        }
        try MGStore.confirmDeliveredDropFlags(db, dropId)
    }

    /// Streams drops, and the per-frame raw flagging Schema v4 runs before `raw_hour` exists.
    static func confirmDeliveredDropFlags(_ db: Database, _ dropId: String) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT kind, strap_ts_start, strap_ts_end FROM outbox_drop WHERE drop_id = ? AND state = 'delivered'
            """, arguments: [dropId]) else { return }
        let kind: String = row["kind"]
        let start: Int64? = row["strap_ts_start"]
        let end: Int64? = row["strap_ts_end"]
        guard let from = start, let to = end else { return }
        switch kind {
        case DropKind.streams.rawValue:
            let names = try String.fetchAll(db, sql: "SELECT name FROM outbox_file WHERE drop_id = ?", arguments: [dropId])
            guard let stream = streamKind(fileNames: names) else { return }
            try db.execute(sql: """
                UPDATE stream_export SET pc_confirmed = 1
                WHERE kind = ? AND ts_from = ? AND ts_to = ? AND state = 'enqueued'
                """, arguments: [stream.rawValue, from, to])
        case DropKind.raw.rawValue:
            guard let blob = try Data.fetchOne(db, sql: """
                SELECT frame_ids FROM raw_export WHERE ts_from = ? AND ts_to = ? AND state = 'enqueued'
                """, arguments: [from, to]) else { return }
            let stmt = try db.cachedStatement(sql: "UPDATE raw_frame SET pc_confirmed = 1 WHERE id = ?")
            for id in MGStore.rawFrameIDs(blob) { try stmt.execute(arguments: [id]) }
        default:
            return
        }
    }

    /// Failed attempt: state `failed`, attempts + 1, the error kept. MGSync owns the backoff (§5.5).
    public func markFailed(_ dropId: String, error: String) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE outbox_drop SET state = 'failed', attempts = attempts + 1, last_error = ?
                WHERE drop_id = ? AND state != 'delivered'
                """, arguments: [error, dropId])
            if db.changesCount == 0,
               try Int.fetchOne(db, sql: "SELECT 1 FROM outbox_drop WHERE drop_id = ?", arguments: [dropId]) == nil {
                throw MGStoreError.unknownDrop(dropId)
            }
        }
    }

    /// Upload started (not in the SyncOutbox port; optional for MGSync's status line).
    public func markUploading(_ dropId: String) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE outbox_drop SET state = 'uploading' WHERE drop_id = ? AND state != 'delivered'
                """, arguments: [dropId])
        }
    }

    /// Stream kind of a `streams` drop from its file name `<kind>.csv.deflate` (§5.4).
    static func streamKind(fileNames: [String]) -> StreamKind? {
        for name in fileNames {
            guard name.hasSuffix(".csv.deflate") else { continue }
            if let kind = StreamKind(rawValue: String(name.dropLast(".csv.deflate".count))) { return kind }
        }
        return nil
    }

    // MARK: Copies held deflated (r8l, audit §3.2)

    /// Smallest file worth deflating at rest.
    static let atRestMinBytes = 512

    /// What to store for a file: deflated (`"zlib"`, raw DEFLATE) when that is smaller, else as is (`"none"`). Files
    /// already named `.deflate` are never compressed again. The PC is sent the plain file (`pending()` inflates), and
    /// `bytes` / `sha256` stay those of the plain file.
    static func atRest(name: String, blob: Data) -> (Data, String) {
        if name.hasSuffix(".deflate") || blob.count < atRestMinBytes { return (blob, "none") }
        if let z = try? (blob as NSData).compressed(using: .zlib), z.length < blob.count { return (z as Data, "zlib") }
        return (blob, "none")
    }

    /// Back to the file as it goes out.
    static func fromRest(_ blob: Data, enc: String?) throws -> Data {
        guard enc == "zlib" else { return blob }
        return try (blob as NSData).decompressed(using: .zlib) as Data
    }
}
