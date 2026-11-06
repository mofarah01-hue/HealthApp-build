import Foundation
import GRDB
import MGDomain

/// Stream CSV cells (ARCHITECTURE §5.4: UTF-8, comma, `\n`, header row first, empty cell = null). The header row is
/// MGDomain's `StreamKind.csvHeader` (one source). Values: integers in decimal; doubles in Swift's shortest
/// round-trip form (non-finite → empty); booleans 1 / 0; text quoted per RFC 4180 only when it holds a comma, quote
/// or line break.
enum StreamCSV {
    static func cell(_ v: Int64?) -> String { v.map { String($0) } ?? "" }
    static func cell(_ v: Int?) -> String { v.map { String($0) } ?? "" }
    static func cell(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return "\(v)"
    }
    static func cell(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "" }
    static func cell(_ v: String?) -> String {
        guard let v else { return "" }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension MGStore: DayBundleSource, StreamExportSource {

    // MARK: DayBundleSource (§5.4 day drop)

    /// Days with event / metric / series changes not yet captured in an enqueued day drop.
    public func dirtyDays() async throws -> [LocalDay] {
        try syncRead { db in
            try String.fetchAll(db, sql: "SELECT local_day FROM day_dirty ORDER BY local_day")
        }.compactMap { LocalDay(iso: $0) }
    }

    /// The three files of a day drop (§5.4), byte-deterministic for the same stored content (sorted keys, fixed row
    /// order) so the content-addressed `day_<date>_<hash>` id is stable:
    /// - `summary.json`: contract daySummary — every stored metric of the day (blanks included; imported history
    ///   excluded, it came from the PC), `strap_id` of the
    ///   most recently seen strap ("unknown" before any strap was seen), its firmware, the app version.
    /// - `events.jsonl`: every event of the day **including soft-removed ones** (`removed: true`), one JSON object per
    ///   line, each line ending in `\n`, ordered by `at` then id.
    /// - `series.json`: `{"date": D, "series": [...]}`, ordered by name then variant.
    public func dayBundle(_ day: LocalDay) async throws -> DayBundleFiles {
        let snapshot = try syncRead { db -> (gen: Int64, metrics: [Data], events: [Data], series: [Data],
                                              strap: (id: String, firmware: String?)?) in
            let gen = try Int64.fetchOne(db, sql: "SELECT gen FROM day_dirty WHERE local_day = ?",
                                         arguments: [day.iso]) ?? 0
            // Imported history is the PC's own result; it is not sent back (MGStore.ownOnly).
            let metrics = try Data.fetchAll(db, sql: """
                SELECT json FROM metric WHERE local_day = ? AND \(MGStore.ownOnly)
                ORDER BY name, variant, metric_window, computed_on
                """, arguments: [day.iso])
            let events = try Data.fetchAll(db, sql: "SELECT json FROM event WHERE local_day = ? ORDER BY at_unix, id",
                                           arguments: [day.iso])
            let series = try Data.fetchAll(db, sql: "SELECT json FROM series WHERE local_day = ? ORDER BY name, variant",
                                           arguments: [day.iso])
            let strap = try primaryStrap(db)
            return (gen, metrics, events, series, strap)
        }
        bundleGen[day.iso] = snapshot.gen

        let summary = DaySummary(date: day, strapId: snapshot.strap?.id ?? "unknown",
                                 metrics: try snapshot.metrics.map { try DocJSON.decode(Metric.self, $0) },
                                 firmware: snapshot.strap?.firmware, appVersion: appVersion)
        var events = Data()
        for line in snapshot.events {
            events.append(line)
            events.append(0x0A)
        }
        let file = SeriesFile(date: day, series: try snapshot.series.map { try DocJSON.decode(Series.self, $0) })
        return DayBundleFiles(day: day, summary: try DocJSON.encode(summary), events: events,
                              series: try DocJSON.encode(file))
    }

    // MARK: StreamExportSource (§5.4 streams drops)

    /// Stream ranges ready for a `streams` drop, keyed by strap timestamp (PLAN §2). One range per UTC-hour window
    /// (`streamWindowSeconds`) that gained rows since its last export and ended at least `streamSettleSeconds` ago.
    /// - First export of a window: the whole window `[start, start + 3599]`.
    /// - Re-export (late history rows landed in an exported window): `[min ts, max ts]` of the rows added since,
    ///   nudged by a second if needed so no two enqueued drops share an id (drops are immutable on the PC; an
    ///   overlapping file is fine — every CSV row carries its key columns, so the PC de-duplicates).
    /// Each offered range is recorded; `enqueue` of its drop marks the window exported up to the row ids seen here,
    /// so rows landing after this call are offered again next time (never lost).
    public func pendingStreamRanges() async throws -> [(kind: StreamKind, from: Int64, to: Int64)] {
        let cutoff = Int64(nowUnix.rounded(.down)) - MGStore.streamSettleSeconds
        let w = MGStore.streamWindowSeconds
        return try syncWrite { db in
            var out: [(kind: StreamKind, from: Int64, to: Int64)] = []
            let windows = try Row.fetchAll(db, sql: """
                SELECT kind, window_start, exports, exported_id FROM stream_window
                WHERE dirty = 1 AND window_start + ? <= ? ORDER BY window_start, kind
                """, arguments: [w, cutoff])
            for row in windows {
                let kindRaw: String = row["kind"]
                guard let kind = StreamKind(rawValue: kindRaw) else { continue }
                let start: Int64 = row["window_start"]
                let end = start + w - 1
                let exports: Int = row["exports"]
                let exportedId: Int64 = row["exported_id"]
                guard let span = try newRowSpan(db, kind, from: start, to: end, afterId: exportedId) else {
                    try db.execute(sql: "UPDATE stream_window SET dirty = 0 WHERE kind = ? AND window_start = ?",
                                   arguments: [kind.rawValue, start])
                    continue
                }
                var from = exports == 0 ? start : span.minTs
                var to = exports == 0 ? end : span.maxTs
                var unique = false
                while !unique {
                    let taken = try Int.fetchOne(db, sql: """
                        SELECT 1 FROM stream_export WHERE kind = ? AND ts_from = ? AND ts_to = ? AND state = 'enqueued'
                        """, arguments: [kind.rawValue, from, to]) != nil
                    if !taken { unique = true } else if to < end { to += 1 } else if from > start { from -= 1 } else { break }
                }
                guard unique else { continue }   // every id in this window is taken; offered again after more rows land
                try db.execute(sql: """
                    INSERT INTO stream_export (kind, ts_from, ts_to, window_start, id_snapshot, state, at)
                    VALUES (?, ?, ?, ?, ?, 'offered', ?)
                    ON CONFLICT(kind, ts_from, ts_to) DO UPDATE SET
                        window_start = excluded.window_start, id_snapshot = excluded.id_snapshot, at = excluded.at
                    WHERE state = 'offered'
                    """, arguments: [kind.rawValue, from, to, start, span.maxId, nowUnix])
                out.append((kind, from, to))
            }
            return out
        }
    }

    /// Every stored row of `kind` with strap ts in [from, to] (all straps), as §5.4 CSV. Also used by Export (APP-114).
    public func streamCSV(_ kind: StreamKind, from: Int64, to: Int64) async throws -> Data {
        var text = kind.csvHeader + "\n"
        try syncRead { db in
            switch kind {
            case .rr:
                let rows = try Row.fetchAll(db, sql: """
                    SELECT ts, ord, rr_ms, source FROM rr_interval WHERE ts BETWEEN ? AND ?
                    ORDER BY ts, ord, source, strap_id
                    """, arguments: [from, to])
                for r in rows {
                    let ts: Int64 = r["ts"], ord: Int64 = r["ord"], rr: Double = r["rr_ms"], src: String = r["source"]
                    text += [StreamCSV.cell(ts), StreamCSV.cell(ord), StreamCSV.cell(rr), StreamCSV.cell(src)]
                        .joined(separator: ",") + "\n"
                }
            case .hr:
                let rows = try Row.fetchAll(db, sql: """
                    SELECT ts, bpm, source FROM hr_sample WHERE ts BETWEEN ? AND ? ORDER BY ts, source, strap_id
                    """, arguments: [from, to])
                for r in rows {
                    let ts: Int64 = r["ts"], bpm: Double = r["bpm"], src: String = r["source"]
                    text += [StreamCSV.cell(ts), StreamCSV.cell(bpm), StreamCSV.cell(src)].joined(separator: ",") + "\n"
                }
            case .r18:
                let rows = try Row.fetchAll(db, sql: """
                    SELECT ts, hr, rr_count, gx, gy, gz, steps, activity_class, skin_temp_raw, sleep_state, spo2_byte,
                           optical_50hz
                    FROM r18_second WHERE ts BETWEEN ? AND ? ORDER BY ts, strap_id
                    """, arguments: [from, to])
                for r in rows {
                    let ts: Int64 = r["ts"], hr: Double? = r["hr"], rrCount: Int64? = r["rr_count"]
                    let gx: Double? = r["gx"], gy: Double? = r["gy"], gz: Double? = r["gz"]
                    let steps: Int64? = r["steps"], activity: Int64? = r["activity_class"]
                    let skin: Int64? = r["skin_temp_raw"], sleep: Int64? = r["sleep_state"]
                    let spo2: Int64? = r["spo2_byte"], optical: Bool? = r["optical_50hz"]
                    let cells = [StreamCSV.cell(ts), StreamCSV.cell(hr), StreamCSV.cell(rrCount), StreamCSV.cell(gx),
                                 StreamCSV.cell(gy), StreamCSV.cell(gz), StreamCSV.cell(steps),
                                 StreamCSV.cell(activity), StreamCSV.cell(skin), StreamCSV.cell(sleep),
                                 StreamCSV.cell(spo2), StreamCSV.cell(optical)]
                    text += cells.joined(separator: ",") + "\n"
                }
            case .strapEvents:
                let rows = try Row.fetchAll(db, sql: """
                    SELECT ts, number, name, payload_hex FROM strap_event WHERE ts BETWEEN ? AND ?
                    ORDER BY ts, number, strap_id
                    """, arguments: [from, to])
                for r in rows {
                    let ts: Int64 = r["ts"], number: Int64 = r["number"]
                    let name: String = r["name"], payload: String = r["payload_hex"]
                    text += [StreamCSV.cell(ts), StreamCSV.cell(number), StreamCSV.cell(name),
                             StreamCSV.cell(payload)].joined(separator: ",") + "\n"
                }
            }
        }
        return Data(text.utf8)
    }

    /// Min / max ts and max row id of rows of `kind` in [from, to] with id > `afterId`; nil when there are none.
    func newRowSpan(_ db: Database, _ kind: StreamKind, from: Int64, to: Int64,
                    afterId: Int64) throws -> (minTs: Int64, maxTs: Int64, maxId: Int64)? {
        let row: Row?
        switch kind {
        case .rr:
            row = try Row.fetchOne(db, sql: """
                SELECT MIN(ts) AS lo, MAX(ts) AS hi, MAX(id) AS top FROM rr_interval
                WHERE ts BETWEEN ? AND ? AND id > ?
                """, arguments: [from, to, afterId])
        case .hr:
            row = try Row.fetchOne(db, sql: """
                SELECT MIN(ts) AS lo, MAX(ts) AS hi, MAX(id) AS top FROM hr_sample
                WHERE ts BETWEEN ? AND ? AND id > ?
                """, arguments: [from, to, afterId])
        case .r18:
            row = try Row.fetchOne(db, sql: """
                SELECT MIN(ts) AS lo, MAX(ts) AS hi, MAX(id) AS top FROM r18_second
                WHERE ts BETWEEN ? AND ? AND id > ?
                """, arguments: [from, to, afterId])
        case .strapEvents:
            row = try Row.fetchOne(db, sql: """
                SELECT MIN(ts) AS lo, MAX(ts) AS hi, MAX(id) AS top FROM strap_event
                WHERE ts BETWEEN ? AND ? AND id > ?
                """, arguments: [from, to, afterId])
        }
        guard let row else { return nil }
        let lo: Int64? = row["lo"], hi: Int64? = row["hi"], top: Int64? = row["top"]
        guard let lo, let hi, let top else { return nil }
        return (lo, hi, top)
    }

    /// Called by `enqueue` for a `streams` drop: the offered range becomes enqueued and its window is exported up to
    /// the row ids seen when it was offered. A range that was never offered (e.g. built by hand) is only recorded, so
    /// its id cannot be reused.
    func noteStreamsEnqueued(_ db: Database, kind: StreamKind, from: Int64, to: Int64) throws {
        let offered = try Row.fetchOne(db, sql: """
            SELECT window_start, id_snapshot FROM stream_export
            WHERE kind = ? AND ts_from = ? AND ts_to = ? AND state = 'offered'
            """, arguments: [kind.rawValue, from, to])
        guard let offered else {
            try db.execute(sql: """
                INSERT INTO stream_export (kind, ts_from, ts_to, window_start, id_snapshot, state, at)
                VALUES (?, ?, ?, NULL, 0, 'enqueued', ?)
                ON CONFLICT(kind, ts_from, ts_to) DO UPDATE SET state = 'enqueued', at = excluded.at
                """, arguments: [kind.rawValue, from, to, nowUnix])
            return
        }
        let start: Int64 = offered["window_start"]
        let snapshot: Int64 = offered["id_snapshot"]
        try db.execute(sql: """
            UPDATE stream_export SET state = 'enqueued', at = ? WHERE kind = ? AND ts_from = ? AND ts_to = ?
            """, arguments: [nowUnix, kind.rawValue, from, to])
        let end = start + MGStore.streamWindowSeconds - 1
        let stillNew = try newRowSpan(db, kind, from: start, to: end, afterId: snapshot) != nil
        try db.execute(sql: """
            UPDATE stream_window SET exports = exports + 1, exported_id = MAX(exported_id, ?), dirty = ?
            WHERE kind = ? AND window_start = ?
            """, arguments: [snapshot, stillNew, kind.rawValue, start])
    }
}
