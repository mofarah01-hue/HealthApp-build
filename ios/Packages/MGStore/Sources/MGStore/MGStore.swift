import Foundation
import GRDB
import MGDomain

/// The app's durable store (ARCHITECTURE §4.5, D2): SQLite through GRDB 6.29.3.
///
/// Patterns copied from noop's WhoopStore (read, not copied code — noop:Packages/WhoopStore/Sources/WhoopStore/
/// WhoopStore.swift L60-173): an `actor` whose GRDB calls run synchronously on its serial executor; a `DatabasePool`
/// (WAL) on disk and a `DatabaseQueue` in memory for tests; composite natural keys with `ON CONFLICT DO NOTHING`;
/// a string-id migrator. Ours differs on durability: **`PRAGMA synchronous = FULL`** on the writer, because the strap
/// frees its copy of history once it is acked (D2, ARCHITECTURE §12 risk 5; noop:Strand/Collect/Backfiller.swift
/// L851-970 acks only after the durable write).
///
/// File: `Application Support/MG/mg.sqlite` in the app container (`defaultURL()`); iOS's default file protection
/// (until first unlock) is kept so overnight background BLE writes work while the phone is locked.
public actor MGStore {
    /// Raw frame ring buffer of ALG-006 v1 (48 h). No longer prunes anything since 2026-10-11: see `phoneKeepSeconds`.
    public static let rawRingSeconds: TimeInterval = 48 * 3600
    /// Since 2026-10-11 (Mo, strap-raw-optical brief D): raw frames and per-second rows (hr_sample, rr_interval,
    /// r18_second) are deleted from the phone only when older than this AND confirmed received by the PC. The value
    /// and the rule live in MGDomain `RawUploadPolicy` (2026-10-11, #74), where they are tested as a pure function.
    public static let phoneKeepSeconds: TimeInterval = RawUploadPolicy.phoneKeepSeconds
    /// Stream export window (strap-ts seconds, UTC-aligned). One `streams` drop covers at most one window.
    public static let streamWindowSeconds: Int64 = 3600
    /// A window is exported only once its end is at least this far in the past (late live rows settle).
    public static let streamSettleSeconds: Int64 = 900

    let dbWriter: any DatabaseWriter
    let clock: any MGDomain.Clock
    let calendar: Calendar
    let appVersion: String?

    /// `day_dirty.gen` read by the last `dayBundle(day)` per day; `enqueue` of that day's drop clears dirtiness only up
    /// to it, so an edit landing between bundle and enqueue keeps the day dirty.
    var bundleGen: [String: Int64] = [:]

    /// Test-only fault injection (`@testable import MGStore`): thrown inside the write transaction at the named point.
    var faultHook: (@Sendable (FaultPoint) throws -> Void)?

    enum FaultPoint: Sendable { case chunkAfterDecodedRows, chunkBeforeJournal }

    // MARK: - Open

    /// Opens (creating if needed) the store at `url` with a WAL `DatabasePool`, `busyMode = .timeout(5)`, and
    /// `synchronous = FULL` on the writer.
    public init(url: URL, clock: (any MGDomain.Clock)? = nil, calendar: Calendar = .current,
                appVersion: String? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: MGStore.configuration())
        // GRDB 6.29.3 DatabasePool.init → Database.setUpWALMode() runs `PRAGMA synchronous = NORMAL` on the writer
        // AFTER prepareDatabase (GRDB/Core/Database.swift L436-444 @ v6.29.3), so FULL is re-applied here, outside
        // any transaction, on the pool's single writer connection. `store(_:)` checks it before every commit.
        try pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA synchronous = FULL") }
        try Schema.migrator(calendar: calendar).migrate(pool)
        self.dbWriter = pool
        self.clock = clock ?? SystemClock()
        self.calendar = calendar
        self.appVersion = appVersion
    }

    private init(writer: any DatabaseWriter, clock: (any MGDomain.Clock)?, calendar: Calendar,
                 appVersion: String?) throws {
        try Schema.migrator(calendar: calendar).migrate(writer)
        self.dbWriter = writer
        self.clock = clock ?? SystemClock()
        self.calendar = calendar
        self.appVersion = appVersion
    }

    /// An in-memory store for tests and previews (`DatabaseQueue`: GRDB has no in-memory pool).
    public static func inMemory(clock: (any MGDomain.Clock)? = nil, calendar: Calendar = .current,
                                appVersion: String? = nil) throws -> MGStore {
        let queue = try DatabaseQueue(configuration: configuration())
        return try MGStore(writer: queue, clock: clock, calendar: calendar, appVersion: appVersion)
    }

    /// `Application Support/MG/mg.sqlite` (§4.5). Relative to the app container; nothing machine-specific (R7).
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("MG", isDirectory: true).appendingPathComponent("mg.sqlite")
    }

    static func configuration() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            // Readers and the in-memory queue. The pool's writer is overridden by GRDB afterwards (see init).
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA journal_size_limit = \(MGStore.journalSizeLimitBytes)")
        }
        return config
    }

    // MARK: - WAL and file size (audit §3.1, r8a 2026-10-17)

    /// The WAL file is cut back to this size after every checkpoint (SQLite `journal_size_limit`), set on every connection.
    public static let journalSizeLimitBytes: Int = 32 * 1024 * 1024

    /// Folds the whole WAL into the database file and truncates the WAL to zero bytes (`PRAGMA wal_checkpoint(TRUNCATE)`).
    /// Call when the app goes to the background and after a big write burst (a history offload). It waits for open readers
    /// (up to `busyMode`'s 5 s) and, if they never finish, leaves the WAL as it is: a failed checkpoint is never an
    /// error for the caller, the next one tries again. Blocks this actor while it runs, so not from a hot path.
    /// r9u: returns the checkpoint's own answer (busy, WAL frames, frames moved) so the caller can log it.
    @discardableResult
    public func checkpointTruncate() async -> StoreCheckpoint {
        checkpointResult()
    }

    /// One-time conversion to `auto_vacuum = INCREMENTAL` (the file never shrank before: `auto_vacuum` was 0). Runs only
    /// when called, never at open: a `VACUUM` rewrites the whole file (needs about its size in free disk, takes
    /// minutes at 1.3 GB, blocks every other store call meanwhile), so the app calls it while charging.
    /// Returns true when it ran the VACUUM. When the file is already incremental it only returns up to 2000 free pages
    /// (about 8 MB) to the system and returns false. Any failure (disk full, busy) returns false and changes nothing.
    public func vacuumIfNeeded() async -> Bool {
        do {
            return try syncWriteWithoutTransaction { db in
                let mode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
                if mode == 2 {
                    try db.execute(sql: "PRAGMA incremental_vacuum(2000)")
                    return false
                }
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                try db.execute(sql: "VACUUM")
                return true
            }
        } catch {
            return false
        }
    }

    // MARK: - Synchronous GRDB helpers
    // GRDB 6 marks its sync read/write overloads @_disfavoredOverload; these non-async wrappers make overload
    // resolution pick them, so the blocking work runs on this actor's executor (noop WhoopStore L159-173).

    func syncRead<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    func syncWrite<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }

    func syncWriteWithoutTransaction<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.writeWithoutTransaction(block)
    }

    func fault(_ point: FaultPoint) throws {
        if let hook = faultHook { try hook(point) }
    }

    /// Test hook setter (actor-isolated state).
    func setFaultHook(_ hook: (@Sendable (FaultPoint) throws -> Void)?) {
        faultHook = hook
    }

    /// The writer connection's `PRAGMA synchronous` (2 = FULL). Exposed so the app's diagnostics screen and the tests
    /// can show the durability the ack depends on.
    public func writerSynchronousLevel() throws -> Int {
        try dbWriter.writeWithoutTransaction { db in try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1 }
    }

    var nowUnix: Double { clock.now.timeIntervalSince1970 }

    func localDay(_ date: Date) -> LocalDay {
        LocalDay(date: date, calendar: calendar)
    }

    /// Next value of a named monotonic counter (never reused, survives row deletes).
    func nextCounter(_ db: Database, _ name: String) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO counter (name, value) VALUES (?, 1)
            ON CONFLICT(name) DO UPDATE SET value = value + 1
            """, arguments: [name])
        return try Int64.fetchOne(db, sql: "SELECT value FROM counter WHERE name = ?", arguments: [name]) ?? 1
    }

    /// Marks a local day dirty (needs a new day drop). Any event, metric or series write calls this (§4.5).
    func markDirty(_ db: Database, _ day: String) throws {
        let gen = try nextCounter(db, "day_dirty_gen")
        try db.execute(sql: """
            INSERT INTO day_dirty (local_day, since, gen) VALUES (?, ?, ?)
            ON CONFLICT(local_day) DO UPDATE SET gen = excluded.gen
            """, arguments: [day, nowUnix, gen])
    }
}
