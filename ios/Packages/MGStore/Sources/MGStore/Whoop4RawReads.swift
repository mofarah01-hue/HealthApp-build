import Foundation
import GRDB

// 0.6.0.12 — the "Raw 4.0" screen reads the newest WHOOP 4.0 history frames straight from the raw archive (every strap frame is
// stored raw: docs/features/RAW-ARCHIVE-EVERYTHING.md). Read only.
//
// WRITTEN, NOT COMPILED here (MGStore needs GRDB, which the Linux harness does not build); the SQL is the shape of
// `commandTestObservations` and `recentRecords`.

extension MGStore {
    /// The newest `limit` raw frames of packet type 47 (HISTORICAL_DATA), newest first, as stored. A 5/MG's type-47 frames are in the
    /// same table; the 4.0 decoder (`Whoop4RawRecord.decode`) refuses them (start byte and version), so they are skipped there.
    public func recentHistoryFrames(limit: Int) async throws -> [[UInt8]] {
        let n = max(1, min(limit, 20_000))
        return try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT bytes FROM raw_frame WHERE packet_type = 47 ORDER BY id DESC LIMIT ?",
                             arguments: [n]).map { row -> [UInt8] in
                let data: Data = row["bytes"]
                return [UInt8](data)
            }
        }
    }
}
