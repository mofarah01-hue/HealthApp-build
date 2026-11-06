import Foundation
import GRDB
import MGDomain

/// The MGStore schema (ARCHITECTURE §4.5). One migration per string id `"v1-…"`; never edit a shipped migration,
/// add a new one (noop:Packages/WhoopStore/Sources/WhoopStore/Database.swift — string-id migrator pattern).
///
/// Strap stream tables use `id INTEGER PRIMARY KEY` (stable through VACUUM, used as the insert sequence for stream
/// export bookkeeping) plus a UNIQUE natural key, so every strap insert is `INSERT … ON CONFLICT(<key>) DO NOTHING`
/// and `changesCount` reports the rows actually inserted (noop StreamStore.insert pattern).
///
/// Columns added beyond the §4.5 table (additive bookkeeping, no §4.3/§5 interface affected):
/// `history_chunk.inserted/frame_count/served`, `day_dirty.gen`, `raw_frame.exported`, and the tables
/// `counter`, `stream_window`, `stream_export`, `raw_export`. The metric key column `window` is named `metric_window`
/// because WINDOW is an SQLite keyword (window functions, SQLite ≥ 3.25).
enum Schema {
    static func migrator(calendar: Calendar = .current) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-schema") { db in
            try db.execute(sql: """
                CREATE TABLE strap (
                    id TEXT PRIMARY KEY NOT NULL,
                    peripheral_uuid TEXT, family TEXT, firmware TEXT, model TEXT,
                    first_seen REAL NOT NULL, last_seen REAL NOT NULL
                );
                CREATE TABLE hr_sample (
                    id INTEGER PRIMARY KEY,
                    strap_id TEXT NOT NULL, ts INTEGER NOT NULL, source TEXT NOT NULL,
                    bpm REAL NOT NULL,
                    UNIQUE (strap_id, ts, source)
                );
                CREATE INDEX hr_sample_ts ON hr_sample (ts);
                CREATE TABLE rr_interval (
                    id INTEGER PRIMARY KEY,
                    strap_id TEXT NOT NULL, ts INTEGER NOT NULL, ord INTEGER NOT NULL, source TEXT NOT NULL,
                    rr_ms REAL NOT NULL,
                    UNIQUE (strap_id, ts, ord, source)
                );
                CREATE INDEX rr_interval_ts ON rr_interval (ts, ord);
                CREATE TABLE r18_second (
                    id INTEGER PRIMARY KEY,
                    strap_id TEXT NOT NULL, ts INTEGER NOT NULL,
                    hr REAL, rr_count INTEGER NOT NULL, gx REAL, gy REAL, gz REAL, steps INTEGER,
                    activity_class INTEGER, skin_temp_raw INTEGER, sleep_state INTEGER, spo2_byte INTEGER,
                    optical_50hz INTEGER,
                    UNIQUE (strap_id, ts)
                );
                CREATE INDEX r18_second_ts ON r18_second (ts);
                CREATE TABLE ppg_block (
                    id INTEGER PRIMARY KEY,
                    strap_id TEXT NOT NULL, ts INTEGER NOT NULL,
                    rate_hz REAL NOT NULL, base INTEGER NOT NULL, samples BLOB NOT NULL,
                    UNIQUE (strap_id, ts)
                );
                CREATE INDEX ppg_block_ts ON ppg_block (ts);
                CREATE TABLE strap_event (
                    id INTEGER PRIMARY KEY,
                    strap_id TEXT NOT NULL, ts INTEGER NOT NULL, number INTEGER NOT NULL,
                    name TEXT NOT NULL, payload_hex TEXT NOT NULL,
                    UNIQUE (strap_id, ts, number)
                );
                CREATE INDEX strap_event_ts ON strap_event (ts);
                CREATE TABLE battery (
                    id INTEGER PRIMARY KEY,
                    strap_id TEXT NOT NULL, ts INTEGER NOT NULL,
                    percent REAL NOT NULL, charging INTEGER,
                    UNIQUE (strap_id, ts)
                );
                CREATE TABLE raw_frame (
                    id INTEGER PRIMARY KEY,
                    strap_id TEXT NOT NULL, received_at REAL NOT NULL, packet_type INTEGER NOT NULL,
                    crc32 INTEGER NOT NULL,
                    bytes BLOB NOT NULL, keep INTEGER NOT NULL DEFAULT 0, chunk_id TEXT,
                    exported INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (strap_id, received_at, packet_type, crc32)
                );
                CREATE INDEX raw_frame_received ON raw_frame (received_at);
                CREATE TABLE history_chunk (
                    chunk_id TEXT PRIMARY KEY NOT NULL,
                    strap_id TEXT NOT NULL, first_ts INTEGER, last_ts INTEGER, trim INTEGER,
                    end_token_hex TEXT, records INTEGER NOT NULL DEFAULT 0, inserted INTEGER NOT NULL DEFAULT 0,
                    frame_count INTEGER NOT NULL DEFAULT 0, served INTEGER NOT NULL DEFAULT 0,
                    stored_at REAL, ack_result TEXT, acked_at REAL
                );
                CREATE TABLE event (
                    id TEXT PRIMARY KEY NOT NULL,
                    type TEXT NOT NULL, at_unix REAL NOT NULL, local_day TEXT NOT NULL, logged_at REAL,
                    source TEXT NOT NULL, revision INTEGER NOT NULL, removed INTEGER NOT NULL,
                    json BLOB NOT NULL, updated_at REAL NOT NULL
                );
                CREATE INDEX event_day ON event (local_day);
                CREATE INDEX event_at ON event (at_unix);
                CREATE TABLE metric (
                    local_day TEXT NOT NULL, name TEXT NOT NULL, variant TEXT NOT NULL, metric_window TEXT NOT NULL,
                    computed_on TEXT NOT NULL,
                    at_unix REAL NOT NULL, json BLOB NOT NULL, updated_at REAL NOT NULL,
                    PRIMARY KEY (local_day, name, variant, metric_window, computed_on)
                );
                CREATE INDEX metric_name ON metric (name, local_day);
                CREATE TABLE series (
                    local_day TEXT NOT NULL, name TEXT NOT NULL, variant TEXT NOT NULL,
                    json BLOB NOT NULL, updated_at REAL NOT NULL,
                    PRIMARY KEY (local_day, name, variant)
                );
                CREATE TABLE lab_result (
                    date TEXT NOT NULL, model_id TEXT NOT NULL, model_version TEXT NOT NULL, inputs_hash TEXT NOT NULL,
                    json BLOB NOT NULL, sha256 TEXT NOT NULL, received_at REAL NOT NULL, seq INTEGER NOT NULL,
                    PRIMARY KEY (date, model_id, model_version, inputs_hash)
                );
                CREATE TABLE group_mark (
                    group_id TEXT NOT NULL, variant TEXT NOT NULL, mark TEXT NOT NULL, at REAL NOT NULL,
                    PRIMARY KEY (group_id, variant)
                );
                CREATE TABLE group_mark_log (
                    id INTEGER PRIMARY KEY,
                    group_id TEXT NOT NULL, variant TEXT NOT NULL, mark TEXT NOT NULL, at REAL NOT NULL
                );
                CREATE TABLE outbox_drop (
                    drop_id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL, local_day TEXT, strap_ts_start INTEGER, strap_ts_end INTEGER,
                    manifest_json BLOB NOT NULL, state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT, created_at REAL NOT NULL, delivered_at REAL
                );
                CREATE TABLE outbox_file (
                    drop_id TEXT NOT NULL, name TEXT NOT NULL,
                    bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, records INTEGER NOT NULL, blob BLOB NOT NULL,
                    receipt_json BLOB,
                    PRIMARY KEY (drop_id, name)
                );
                CREATE TABLE day_dirty (
                    local_day TEXT PRIMARY KEY NOT NULL, since REAL NOT NULL, gen INTEGER NOT NULL
                );
                CREATE TABLE kv (
                    key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL
                );
                CREATE TABLE counter (
                    name TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL
                );
                CREATE TABLE stream_window (
                    kind TEXT NOT NULL, window_start INTEGER NOT NULL,
                    dirty INTEGER NOT NULL, exports INTEGER NOT NULL DEFAULT 0, exported_id INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (kind, window_start)
                );
                CREATE TABLE stream_export (
                    kind TEXT NOT NULL, ts_from INTEGER NOT NULL, ts_to INTEGER NOT NULL,
                    window_start INTEGER, id_snapshot INTEGER NOT NULL, state TEXT NOT NULL, at REAL NOT NULL,
                    PRIMARY KEY (kind, ts_from, ts_to)
                );
                CREATE TABLE raw_export (
                    ts_from INTEGER NOT NULL, ts_to INTEGER NOT NULL,
                    frame_ids BLOB NOT NULL, state TEXT NOT NULL, at REAL NOT NULL,
                    PRIMARY KEY (ts_from, ts_to)
                );
                """)
        }
        // Added 2026-10-11 (strap-raw-optical phase A): read-only strap settings snapshots (117/118/128). One row per
        // snapshot; `json` is the `StrapFlagSnapshot` (MGJSON). The strap's reply frames go to `raw_frame`, pinned.
        migrator.registerMigration("v2-strap-flag-snapshot") { db in
            try db.execute(sql: """
                CREATE TABLE strap_flag_snapshot (
                    id INTEGER PRIMARY KEY,
                    strap_id TEXT NOT NULL, read_at REAL NOT NULL, firmware TEXT, json BLOB NOT NULL,
                    UNIQUE (strap_id, read_at)
                );
                """)
        }
        // Added 2026-10-11 (strap-raw-optical phase C): R20 optical records live in `ppg_block`, one row per strap second
        // (its UNIQUE (strap_id, ts) stays). A second can hold a v26 PPG window (`base` / `samples`, empty blob when
        // there is none) and an R20 record (`r20_*`, NULL when there is none); each insert fills only its own half.
        // `r20_blocks` = MGDomain `R20Record.packed`; `r20_source` "live" (108) or "history" (banked, 107).
        migrator.registerMigration("v3-ppg-block-r20") { db in
            try db.execute(sql: """
                ALTER TABLE ppg_block ADD COLUMN r20_source TEXT;
                ALTER TABLE ppg_block ADD COLUMN r20_record_index INTEGER;
                ALTER TABLE ppg_block ADD COLUMN r20_blocks BLOB;
                """)
        }
        // Added 2026-10-11 (strap-raw-optical phase D): what the PC has confirmed. A raw frame is confirmed when the raw
        // drop that carried it is delivered (receipts matched, `markDelivered`); a stream export range likewise. Only
        // confirmed data older than `MGStore.phoneKeepSeconds` is ever pruned. Drops delivered before this migration
        // are confirmed here once.
        migrator.registerMigration("v4-pc-confirmed") { db in
            try db.execute(sql: """
                ALTER TABLE raw_frame ADD COLUMN pc_confirmed INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE stream_export ADD COLUMN pc_confirmed INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX raw_frame_confirmed ON raw_frame (pc_confirmed, received_at);
                """)
            for dropId in try String.fetchAll(db, sql: "SELECT drop_id FROM outbox_drop WHERE state = 'delivered'") {
                try MGStore.confirmDeliveredDropFlags(db, dropId)
            }
        }
        // Added 2026-10-11 (Mo: "Yes, after 30 days"): when a delivered drop's stored compressed copy is removed, the
        // outbox row and its sizes, sha256 and receipt stay; this column says when the copy went (`blob` is then empty).
        migrator.registerMigration("v5-outbox-blob-pruned") { db in
            try db.execute(sql: """
                ALTER TABLE outbox_file ADD COLUMN blob_pruned_at REAL;
                """)
        }
        // Wave 4 (2026-10-11): the R18 record's optical signal-quality fields (MGDomain `R18Quality`; decoded,
        // untested). Not part of the r18 stream CSV. NULL on rows stored before this migration.
        migrator.registerMigration("w4-r18-quality") { db in
            try db.execute(sql: """
                ALTER TABLE r18_second ADD COLUMN q_saturated INTEGER;
                ALTER TABLE r18_second ADD COLUMN q_psnr_a INTEGER;
                ALTER TABLE r18_second ADD COLUMN q_psnr_b INTEGER;
                ALTER TABLE r18_second ADD COLUMN q_logvar REAL;
                """)
        }
        // Added 2026-10-11 19:50 PT (wave W8): raw motion (R21) one compact row per strap second (`packed` = MGDomain
        // `MotionPack` of the raw i16 columns; `acc_*` / `enmo_lsb` = MGDomain `MotionAccelSummary`, counts), and the samples of a saved ECG reading (`ecg_trace`, the `ecg` event's
        // `samples_ref`). Raw counts only. The raw frames themselves stay in `raw_frame` like every other frame.
        migrator.registerMigration("v6-w8-motion-ecg") { db in
            try db.execute(sql: """
                CREATE TABLE motion_second (
                    id INTEGER PRIMARY KEY,
                    strap_id TEXT NOT NULL, ts INTEGER NOT NULL, fraction INTEGER NOT NULL,
                    accel_n INTEGER NOT NULL, gyro_n INTEGER NOT NULL, source TEXT NOT NULL, packed BLOB NOT NULL,
                    acc_mean REAL, acc_sd REAL, enmo_lsb REAL,
                    UNIQUE (strap_id, ts)
                );
                CREATE INDEX motion_second_ts ON motion_second (ts);
                CREATE TABLE ecg_trace (
                    event_id TEXT PRIMARY KEY NOT NULL,
                    strap_id TEXT, started_at REAL NOT NULL, samples BLOB NOT NULL, packets BLOB NOT NULL
                );
                """)
        }
        // Added 2026-10-13 (T87): Settings › Command test. One row per command sent from that page, with Mo's mark
        // ("worked" / "nothing" / "red"). The mark is also written to `raw_frame` so it goes to the PC in the raw drops.
        migrator.registerMigration("v7-command-test") { db in
            try db.execute(sql: """
                CREATE TABLE command_test (
                    id INTEGER PRIMARY KEY,
                    number INTEGER NOT NULL, payload_hex TEXT NOT NULL, sent_at REAL NOT NULL, mark TEXT
                );
                """)
        }
        // Added 2026-10-14 (T9746; Mo: archive everything decoded): R18's gravity-removed dynamic acceleration (g) and the
        // two auxiliary thermal channels (raw i16, raw / 10 = °C), decoded and asserted on a fixture but never stored.
        // NULL on rows stored before this migration (the strap has already deleted those records after the ack).
        migrator.registerMigration("v8-r18-dynamic-accel") { db in
            try db.execute(sql: """
                ALTER TABLE r18_second ADD COLUMN dyn_accel REAL;
                ALTER TABLE r18_second ADD COLUMN temp_aux1_raw INTEGER;
                ALTER TABLE r18_second ADD COLUMN temp_aux2_raw INTEGER;
                """)
        }
        // r8a 2026-10-17 (audit §4.1, T10002): SET_CLOCK `strap_write` events were dated at the pairing consent (Oct 11)
        // instead of when they were written, so that day was "changed" after every reconnect. The real write time is
        // recoverable: every row keeps `logged_at` (the clock at logging). Moves those events to that time and day, once.
        migrator.registerMigration("v9-redate-clock-writes") { db in
            try Schema.redateClockWrites(db, calendar: calendar)
        }
        // r8a 2026-10-17 (audit §3.3): `pendingRawRanges` / `rawFramesFile` filter `exported = 0`. Partial index: it holds
        // only the not yet exported rows, so the scan stays small however big the table grows (covering for received_at).
        migrator.registerMigration("v10-raw-frame-unexported-index") { db in
            try db.execute(sql: """
                CREATE INDEX raw_frame_unexported ON raw_frame (received_at) WHERE exported = 0;
                """)
        }
        // r8l 2026-10-17 (audit §3.3, §3.4): one state row per UTC hour of raw frames, kept by triggers so Usage and
        // Research read counters instead of COUNT/SUM over `raw_frame`, and so exported / PC-confirmed become a
        // WATERMARK per hour (`exported_wm`, `confirmed_wm`: frames of that hour with id <= wm) instead of one UPDATE per
        // frame. The per-row `exported` / `pc_confirmed` columns stay readable: a frame counts as exported (confirmed)
        // when its flag is 1 (old rows, and the rare out-of-order confirmation) OR its id is <= the hour's watermark.
        // Nothing writes `exported = 1` any more, so the partial index of v10 (every row would now be in it) is dropped:
        // `pendingRawRanges` reads this table instead. Hour = (CAST(received_at AS INTEGER) / 3600) * 3600
        // (`MGStore.streamWindowSeconds`).
        migrator.registerMigration("v11-raw-hour") { db in
            try db.execute(sql: """
                CREATE TABLE raw_hour (
                    hour INTEGER PRIMARY KEY NOT NULL,
                    frames INTEGER NOT NULL DEFAULT 0,
                    bytes INTEGER NOT NULL DEFAULT 0,
                    exported_frames INTEGER NOT NULL DEFAULT 0,
                    confirmed_frames INTEGER NOT NULL DEFAULT 0,
                    exported_wm INTEGER NOT NULL DEFAULT 0,
                    confirmed_wm INTEGER NOT NULL DEFAULT 0
                );
                DROP INDEX IF EXISTS raw_frame_unexported;
                INSERT INTO raw_hour (hour, frames, bytes, exported_frames, confirmed_frames)
                    SELECT (CAST(received_at AS INTEGER) / 3600) * 3600, COUNT(*), COALESCE(SUM(length(bytes)), 0),
                           COALESCE(SUM(exported), 0), COALESCE(SUM(pc_confirmed), 0)
                    FROM raw_frame GROUP BY 1;
                CREATE TRIGGER raw_hour_insert AFTER INSERT ON raw_frame BEGIN
                    INSERT INTO raw_hour (hour, frames, bytes)
                    VALUES ((CAST(NEW.received_at AS INTEGER) / 3600) * 3600, 1, length(NEW.bytes))
                    ON CONFLICT(hour) DO UPDATE SET frames = frames + 1, bytes = bytes + excluded.bytes;
                END;
                CREATE TRIGGER raw_hour_delete AFTER DELETE ON raw_frame BEGIN
                    UPDATE raw_hour SET
                        frames = frames - 1,
                        bytes = bytes - length(OLD.bytes),
                        exported_frames = exported_frames - (OLD.exported = 1 OR OLD.id <= exported_wm),
                        confirmed_frames = confirmed_frames - (OLD.pc_confirmed = 1 OR OLD.id <= confirmed_wm)
                    WHERE hour = (CAST(OLD.received_at AS INTEGER) / 3600) * 3600;
                END;
                """)
        }
        // r8l 2026-10-17 (audit §3.2): `outbox_file.blob_enc` says how the stored copy is held: NULL = not looked at yet
        // (rows from before this migration), 'none' = as the file is (already deflated, small, or it did not shrink),
        // 'zlib' = deflated at rest (day drops are plain JSON on the wire: the PC takes only summary.json / events.jsonl /
        // series.json by name, so they are compressed here only; `bytes` / `sha256` stay those of the plain file).
        // `ppg_block.pruned_at` = when `samples` / `r20_blocks` were emptied (row, ts, rate kept); partial index so
        // the prune pass never rescans pruned rows.
        migrator.registerMigration("v12-outbox-at-rest-ppg-pruned") { db in
            try db.execute(sql: """
                ALTER TABLE outbox_file ADD COLUMN blob_enc TEXT;
                ALTER TABLE ppg_block ADD COLUMN pruned_at REAL;
                CREATE INDEX ppg_block_unpruned ON ppg_block (ts) WHERE pruned_at IS NULL;
                """)
        }
        // r9u 2026-10-17 (CRITICAL for 0.6.0): the Apple Health upload queue as a table, one row per POST body (HealthQueue.swift).
        // Only creates the table; the bodies of the old queue (inside the kv value `mghealth.auto_sync`, 288 MB on Mo's phone) are
        // moved by `migrateHealthQueueFromKV`, in 50-row transactions off the main thread, not inside this one-transaction step.
        // `seq` is the send order (oldest first); `id` is the batch id of the old queue entry, so a re-run changes nothing;
        // `key` is the content key (same samples = same key); `body` is deflated when `body_enc = 'zlib'`; `body_bytes` is the
        // plain size.
        migrator.registerMigration("v13-health-queue") { db in
            try db.execute(sql: """
                CREATE TABLE health_queue (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    key TEXT,
                    created_at REAL NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    sample_count INTEGER NOT NULL,
                    body BLOB NOT NULL,
                    body_enc TEXT,
                    body_bytes INTEGER NOT NULL
                );
                CREATE INDEX health_queue_key ON health_queue (key) WHERE key IS NOT NULL;
                """)
        }
        return migrator
    }

    /// Moves `strap_write` events of SET_CLOCK (146, or the deprecated 10) written under the standing consent whose `at`
    /// is more than an hour away from `logged_at` to `logged_at`: `at_unix`, `local_day`, the JSON `at` and
    /// `confirmedAt`, `revision + 1`. The old and the new day are marked dirty once (the PC merges events per id, highest
    /// revision wins; whether it also drops the copy in the old day's file is not known here). Rows without `logged_at`
    /// cannot be recovered and stay as they are.
    static func redateClockWrites(_ db: Database, calendar: Calendar) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, json, local_day FROM event
            WHERE type = 'strap_write' AND logged_at IS NOT NULL AND ABS(logged_at - at_unix) > 3600
            """)
        var touched: Set<String> = []
        for row in rows {
            let id: String = row["id"]
            let json: Data = row["json"]
            let oldDay: String = row["local_day"]
            // An undecodable row must never stop the store from opening: it is left as it is.
            guard var event = try? DocJSON.decode(EventRecord.self, json) else { continue }
            guard let loggedAt = event.loggedAt, event.note == MGStore.standingConsentNote,
                  case .strapWrite(var fields) = event.payload, fields.command == 146 || fields.command == 10 else {
                continue
            }
            event.at = loggedAt
            fields.confirmedAt = loggedAt
            event.payload = .strapWrite(fields)
            event.revision += 1
            guard let newJSON = try? DocJSON.encode(event) else { continue }
            let newDay = LocalDay(date: loggedAt, calendar: calendar).iso
            try db.execute(sql: """
                UPDATE event SET at_unix = ?, local_day = ?, revision = ?, json = ?, updated_at = ? WHERE id = ?
                """, arguments: [loggedAt.timeIntervalSince1970, newDay, event.revision, newJSON,
                                 Date().timeIntervalSince1970, id])
            touched.insert(oldDay)
            touched.insert(newDay)
        }
        for day in touched {
            try db.execute(sql: """
                INSERT INTO counter (name, value) VALUES ('day_dirty_gen', 1)
                ON CONFLICT(name) DO UPDATE SET value = value + 1
                """)
            let gen = try Int64.fetchOne(db, sql: "SELECT value FROM counter WHERE name = 'day_dirty_gen'") ?? 1
            try db.execute(sql: """
                INSERT INTO day_dirty (local_day, since, gen) VALUES (?, ?, ?)
                ON CONFLICT(local_day) DO UPDATE SET gen = excluded.gen
                """, arguments: [day, Date().timeIntervalSince1970, gen])
        }
    }
}
