import Foundation
import GRDB

/// What takes room inside the database, for Settings › Usage (tracker #40, 2026-10-11). Read-only. Blob sizes come
/// from `length()`, which SQLite answers without reading the blob itself. The raw-frame counters come from the per-hour
/// state table `raw_hour` (r8l 2026-10-17, audit §3.3; it used to COUNT/SUM over `raw_frame` here), kept by triggers and
/// watermarks, so they cost one row per hour. Runs only when the Usage page asks (on open and on "Measure again").
public struct StoreStorageReport: Sendable, Equatable {
    /// page_count × page_size: the main file's size (the WAL file is separate, measured by the app).
    public var pageBytes: Int64
    /// Free pages inside the file (freelist_count × page_size), reusable without growing it.
    public var freePageBytes: Int64
    public var rawFrames: Int
    public var rawFrameBytes: Int64
    /// Raw frames the PC has not confirmed yet (MGStore never prunes them).
    public var rawFramesUnconfirmed: Int
    /// Compressed drop copies kept for re-sending (outbox_file.blob; emptied 30 days after the PC confirms).
    public var outboxBytes: Int64
    /// PPG samples + R20 optical blocks (ppg_block).
    public var opticalBytes: Int64
}

extension MGStore {
    public func storageReport() async throws -> StoreStorageReport {
        try syncRead { db in
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let free = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let raw = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(frames), 0) AS n, COALESCE(SUM(bytes), 0) AS b,
                       COALESCE(SUM(frames - confirmed_frames), 0) AS u
                FROM raw_hour
                """)
            let outbox = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(blob)), 0) FROM outbox_file") ?? 0
            let optical = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(length(samples)), 0) + COALESCE(SUM(length(r20_blocks)), 0) FROM ppg_block
                """) ?? 0
            return StoreStorageReport(pageBytes: pages * pageSize, freePageBytes: free * pageSize,
                                      rawFrames: raw?["n"] ?? 0, rawFrameBytes: raw?["b"] ?? 0,
                                      rawFramesUnconfirmed: raw?["u"] ?? 0, outboxBytes: outbox,
                                      opticalBytes: optical)
        }
    }
}
