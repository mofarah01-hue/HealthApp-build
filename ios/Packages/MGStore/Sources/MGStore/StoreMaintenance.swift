import Foundation
import GRDB
import MGDomain

// r9u (2026-10-17): file maintenance with a report. 0.5.9 only ran `vacuumIfNeeded()` at the end of the `.compute` BGTask, which
// the streaming rule skips while raw streams keep the app awake, so on Mo's phone it never ran: auto_vacuum was 0, 119,655 free
// pages (about 467 MB) sat in the file and the WAL was 305 MB. `runMaintenance()` is its own entry point: the app calls it
// while the phone charges and the app is open and idle (AppModel+Maintenance.swift) and from the `.compute` task. It logs
// what it found and did, with file sizes before and after, and the checkpoint's own answer (busy / frames).

/// The three numbers of `PRAGMA wal_checkpoint(TRUNCATE)`.
public struct StoreCheckpoint: Equatable, Sendable, CustomStringConvertible {
    /// SQLite could not finish: a reader held the WAL open (waited up to the 5 s busy timeout).
    public var busy: Bool
    /// Frames in the WAL when the checkpoint ran (-1 when the database is not in WAL mode).
    public var walFrames: Int
    /// Frames moved into the database file.
    public var checkpointedFrames: Int
    /// Set when the pragma itself threw.
    public var error: String?

    public var description: String {
        if let error { return "checkpoint failed (\(error))" }
        return "checkpoint \(busy ? "BUSY (a reader kept the WAL open)" : "done"): \(walFrames) WAL frames, \(checkpointedFrames) moved to the file"
    }
}

public struct StoreMaintenanceReport: Equatable, Sendable, CustomStringConvertible {
    public var dbBytesBefore: Int64
    public var dbBytesAfter: Int64
    public var walBytesBefore: Int64
    public var walBytesAfter: Int64
    public var freePagesBefore: Int
    public var freePagesAfter: Int
    /// "full VACUUM (converted to auto_vacuum=INCREMENTAL)", "incremental_vacuum, N chunks", or "nothing to do".
    public var action: String
    /// Why the compaction did not run or stopped (not enough free disk, a failure); nil = it did what it set out to.
    public var problem: String?
    public var checkpointBefore: StoreCheckpoint
    public var checkpointAfter: StoreCheckpoint
    public var seconds: Double

    public static func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }

    public var description: String {
        "database file \(Self.mb(dbBytesBefore)) -> \(Self.mb(dbBytesAfter)), WAL \(Self.mb(walBytesBefore)) -> \(Self.mb(walBytesAfter)), "
            + "free pages \(freePagesBefore) -> \(freePagesAfter); \(action)" + (problem.map { " (\($0))" } ?? "")
            + "; before: \(checkpointBefore); after: \(checkpointAfter); \(String(format: "%.1f", seconds)) s"
    }
}

extension MGStore {
    /// Pages one `incremental_vacuum` step returns (80 MB at 4 KB pages); the loop yields and checks for cancellation between steps.
    static let incrementalVacuumStepPages = 20_000
    /// At most this many steps per call (about 4 GB), so one call is bounded.
    static let incrementalVacuumMaxSteps = 50

    func databaseFileURL() -> URL? {
        guard let pool = dbWriter as? DatabasePool else { return nil }
        return URL(fileURLWithPath: pool.path)
    }

    func fileBytes(_ url: URL?) -> Int64 {
        guard let url else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func checkpointResult() -> StoreCheckpoint {
        do {
            return try syncWriteWithoutTransaction { db in
                let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                let busy: Int = row?[0] ?? 0
                let log: Int = row?[1] ?? -1
                let done: Int = row?[2] ?? -1
                return StoreCheckpoint(busy: busy != 0, walFrames: log, checkpointedFrames: done, error: nil)
            }
        } catch {
            return StoreCheckpoint(busy: false, walFrames: -1, checkpointedFrames: -1, error: "\(error)")
        }
    }

    /// Checkpoint, compact, checkpoint, and say what happened. Never throws: a failure is in `problem`. Heavy (a full VACUUM
    /// rewrites the file and blocks every other store call), so only while charging; `Task.isCancelled` stops the
    /// incremental loop between steps.
    /// `allowFullVacuum: false` (the app is open with raw streams running) leaves the one-time full VACUUM, which blocks every store
    /// call for minutes, to the charging background task; the incremental steps (80 MB each) still run.
    public func runMaintenance(allowFullVacuum: Bool = true) async -> StoreMaintenanceReport {
        let started = Date()
        let url = databaseFileURL()
        let wal = url.map { URL(fileURLWithPath: $0.path + "-wal") }
        let dbBefore = fileBytes(url), walBefore = fileBytes(wal)
        let freeBefore = (try? syncRead { db in try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0 }) ?? 0
        let pageSize = (try? syncRead { db in try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096 }) ?? 4096
        let cpBefore = checkpointResult()

        var action = "nothing to do"
        var problem: String?
        let mode = (try? syncRead { db in try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0 }) ?? 0
        if mode == 2 {
            var steps = 0
            while steps < Self.incrementalVacuumMaxSteps, !Task.isCancelled {
                let left = (try? syncRead { db in try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0 }) ?? 0
                if left == 0 { break }
                do {
                    try syncWriteWithoutTransaction { db in
                        try db.execute(sql: "PRAGMA incremental_vacuum(\(Self.incrementalVacuumStepPages))")
                    }
                } catch {
                    problem = "incremental_vacuum failed: \(error)"
                    break
                }
                steps += 1
                await Task.yield()
            }
            if steps > 0 { action = "incremental_vacuum, \(steps) step\(steps == 1 ? "" : "s")" }
            if Task.isCancelled, problem == nil { problem = "stopped when iOS took the time back; the rest is done next time" }
        } else if url != nil, !allowFullVacuum {
            problem = "the one-time full VACUUM waits for the charging background task (raw streams are on and would stall)"
        } else if url != nil {
            // auto_vacuum = 0: one full VACUUM converts the file to INCREMENTAL. In WAL mode it needs room for the compacted copy,
            // the WAL it goes through and the old file until the checkpoint: about the file plus twice its live data.
            let live = max(0, dbBefore - Int64(freeBefore) * Int64(pageSize))
            let need = dbBefore + 2 * live
            let fsAttrs = try? FileManager.default.attributesOfFileSystem(forPath: url?.path ?? "/")
            let free = (fsAttrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            if free < need {
                problem = "full VACUUM skipped: needs about \(StoreMaintenanceReport.mb(need)) free, the phone has \(StoreMaintenanceReport.mb(free))"
            } else {
                do {
                    try syncWriteWithoutTransaction { db in
                        try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                        try db.execute(sql: "VACUUM")
                    }
                    action = "full VACUUM (converted to auto_vacuum=INCREMENTAL)"
                } catch {
                    problem = "VACUUM failed: \(error)"
                }
            }
        }

        let cpAfter = checkpointResult()
        let freeAfter = (try? syncRead { db in try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0 }) ?? 0
        return StoreMaintenanceReport(dbBytesBefore: dbBefore, dbBytesAfter: fileBytes(url), walBytesBefore: walBefore,
                                      walBytesAfter: fileBytes(wal), freePagesBefore: freeBefore, freePagesAfter: freeAfter,
                                      action: action, problem: problem, checkpointBefore: cpBefore, checkpointAfter: cpAfter,
                                      seconds: Date().timeIntervalSince(started))
    }
}
