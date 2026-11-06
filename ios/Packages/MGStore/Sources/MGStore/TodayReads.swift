import Foundation
import GRDB
import MGDomain

/// Incremental reads for Today's "Today so far" (wave 6, 2026-10-11): only the rows stored since the reader's last
/// call, so a once-a-minute refresh never re-reads the whole day. Row ids only grow (INTEGER PRIMARY KEY; rows are
/// never renumbered, and the retention prune removes only rows older than 30 days), so a reader that keeps `upTo` and
/// passes it back as `afterId` sees every later insert exactly once — a history offload's backfill of earlier seconds
/// included. Both reads run in one read transaction: `upTo` and the rows come from the same snapshot.
extension MGStore {
    /// Heart-rate rows with id in (afterId, upTo] and ts ≥ `from` (no upper ts bound: a second stamped later than
    /// "now" is kept by the caller and counted once now reaches it).
    public func hrSamplesStored(afterId: Int64, from: Int64) async throws -> (points: [HRPoint], upTo: Int64) {
        try syncRead { db in
            let upTo = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM hr_sample") ?? 0
            // First read of the day: the ts index (left to itself SQLite walks the id range from the first row ever);
            // later reads: the id range only (the ts index would walk the whole day). Plans checked 2026-10-11.
            let sql = afterId == 0
                ? "SELECT ts, bpm, source FROM hr_sample INDEXED BY hr_sample_ts WHERE ts >= ? AND id <= ?"
                : "SELECT ts, bpm, source FROM hr_sample NOT INDEXED WHERE id > ? AND id <= ? AND ts >= ? ORDER BY id"
            let args: StatementArguments = afterId == 0 ? [from, upTo] : [afterId, upTo, from]
            let points = try Row.fetchAll(db, sql: sql, arguments: args).map { row in
                HRPoint(ts: row["ts"], bpm: row["bpm"], source: MGStore.source(row["source"]))
            }
            return (points, upTo)
        }
    }

    /// R18 seconds as above, with only the step-counter columns filled (ts, steps, activity_class; `rrCount` 0).
    public func r18StepsStored(afterId: Int64, from: Int64) async throws -> (rows: [R18Second], upTo: Int64) {
        try syncRead { db in
            let upTo = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM r18_second") ?? 0
            let sql = afterId == 0
                ? "SELECT ts, steps, activity_class FROM r18_second INDEXED BY r18_second_ts WHERE ts >= ? AND id <= ?"
                : "SELECT ts, steps, activity_class FROM r18_second NOT INDEXED WHERE id > ? AND id <= ? AND ts >= ? "
                    + "ORDER BY id"
            let args: StatementArguments = afterId == 0 ? [from, upTo] : [afterId, upTo, from]
            let rows = try Row.fetchAll(db, sql: sql, arguments: args).map { row in
                R18Second(ts: row["ts"], rrCount: 0, steps: row["steps"], activityClass: row["activity_class"])
            }
            return (rows, upTo)
        }
    }
}
