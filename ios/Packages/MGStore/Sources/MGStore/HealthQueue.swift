import Foundation
import GRDB
import MGDomain

// r9u (2026-10-17, CRITICAL for 0.6.0): the Apple Health upload queue as a table, one row per POST body (migration
// "v13-health-queue"). Until 0.5.9 the queue lived inside the kv value `mghealth.auto_sync` (anchors + queue as one JSON
// document); on Mo's phone it held 753 bodies, 288 MB, and every change re-encoded and re-saved all of it.
//
//   append / peek(oldest N) / remove (after the PC's receipt) / markError / stats : each touches one row or a small page.
//   migrateHealthQueueFromKV : moves the bodies of the old kv document into the table, streaming (never a decoded 288 MB
//   object tree), 50 rows per transaction, idempotent by batch id, then writes the document back without them.

/// One queued POST body. `body` is the plain JSON; the table holds it deflated.
public struct HealthQueueRow: Equatable, Sendable {
    public var id: UUID
    public var key: String?
    public var createdAt: Date
    public var attempts: Int
    public var lastError: String?
    public var sampleCount: Int
    public var body: Data

    public init(id: UUID, key: String?, createdAt: Date, attempts: Int, lastError: String?, sampleCount: Int, body: Data) {
        self.id = id; self.key = key; self.createdAt = createdAt; self.attempts = attempts; self.lastError = lastError
        self.sampleCount = sampleCount; self.body = body
    }
}

public struct HealthQueueCounts: Equatable, Sendable {
    public var batches: Int
    public var samples: Int
    /// Plain JSON bytes of all waiting bodies (`body_bytes`), not the deflated size on disk.
    public var bytes: Int
    /// What the bodies take in the file (deflated).
    public var storedBytes: Int
}

public struct HealthQueueMigration: Equatable, Sendable {
    /// Entries found in the old document's `queue` array.
    public var found: Int
    /// Entries now in the table (moved by this call or by an earlier, interrupted one).
    public var inTable: Int
    public var valueBytesBefore: Int
    public var valueBytesAfter: Int
}

extension MGStore {
    /// Rows per transaction while moving the old queue over.
    static let healthQueueMigrationBatch = 50

    // MARK: Queue

    /// Adds rows at the end of the queue. A row whose `id` is already there, or whose `key` (same samples) is already queued,
    /// is skipped. Returns how many rows were added.
    @discardableResult
    public func healthQueueAppend(_ rows: [HealthQueueRow]) async throws -> Int {
        try syncWrite { db in
            var added = 0
            for r in rows {
                if let k = r.key,
                   try Int.fetchOne(db, sql: "SELECT 1 FROM health_queue WHERE key = ? LIMIT 1", arguments: [k]) != nil { continue }
                let (stored, enc) = Self.healthBodyAtRest(r.body)
                try db.execute(sql: """
                    INSERT OR IGNORE INTO health_queue
                        (id, key, created_at, attempts, last_error, sample_count, body, body_enc, body_bytes)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [r.id.uuidString, r.key, r.createdAt.timeIntervalSince1970, r.attempts, r.lastError,
                                     r.sampleCount, stored, enc, r.body.count])
                added += db.changesCount
            }
            return added
        }
    }

    /// The newest `limit` rows, newest first (T10033), bodies inflated; `oldestFirst: true` (Nov 5: the upload order, the backlog
    /// before live data) returns the oldest rows, oldest first. Ask for few: every body is up to about 0.5 MB.
    public func healthQueuePeek(limit: Int, oldestFirst: Bool = false) async throws -> [HealthQueueRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT id, key, created_at, attempts, last_error, sample_count, body, body_enc
                FROM health_queue ORDER BY seq \(oldestFirst ? "ASC" : "DESC") LIMIT ?
                """, arguments: [max(0, limit)]).compactMap { row -> HealthQueueRow? in
                guard let id = UUID(uuidString: row["id"] as String) else { return nil }
                let stored: Data = row["body"]
                let enc: String? = row["body_enc"]
                guard let body = try? Self.healthBodyFromRest(stored, enc: enc) else { return nil }
                return HealthQueueRow(id: id, key: row["key"], createdAt: Date(timeIntervalSince1970: row["created_at"]),
                                      attempts: row["attempts"], lastError: row["last_error"], sampleCount: row["sample_count"],
                                      body: body)
            }
        }
    }

    /// Deletes a row. The caller does this only for a batch the PC confirmed (or refused for good, after saving the refusal).
    public func healthQueueRemove(id: UUID) async throws {
        try syncWrite { db in try db.execute(sql: "DELETE FROM health_queue WHERE id = ?", arguments: [id.uuidString]) }
    }

    public func healthQueueMarkError(id: UUID, error: String) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE health_queue SET attempts = attempts + 1, last_error = ? WHERE id = ?",
                           arguments: [error, id.uuidString])
        }
    }

    /// Counts only; no body is read.
    public func healthQueueCounts() async throws -> HealthQueueCounts {
        try syncRead { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, COALESCE(SUM(sample_count), 0) AS s, COALESCE(SUM(body_bytes), 0) AS b,
                       COALESCE(SUM(length(body)), 0) AS d
                FROM health_queue
                """)
            return HealthQueueCounts(batches: row?["n"] ?? 0, samples: row?["s"] ?? 0, bytes: row?["b"] ?? 0,
                                     storedBytes: row?["d"] ?? 0)
        }
    }

    static func healthBodyAtRest(_ body: Data) -> (Data, String) {
        if body.count >= 512, let z = try? (body as NSData).compressed(using: .zlib), z.length < body.count { return (z as Data, "zlib") }
        return (body, "none")
    }

    static func healthBodyFromRest(_ stored: Data, enc: String?) throws -> Data {
        guard enc == "zlib" else { return stored }
        return try (stored as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: Migration of the old kv document

    /// Moves the `queue` array of the kv document `key` into `health_queue`, then saves the document with `"queue":[]`.
    ///
    /// Safe on a 288 MB value: the document is read once as bytes and scanned for the array and its objects (no object tree
    /// of the whole document is ever built); each entry is parsed alone (about 0.7 MB), deflated and inserted, 50 per
    /// transaction. Ids that are already in the table are kept as they are, so a run that stopped half way is simply run again.
    /// Nothing is dropped: an entry that cannot be read stops the migration with an error and leaves the document untouched.
    /// Runs on this actor (never the main thread) and yields between transactions.
    @discardableResult
    public func migrateHealthQueueFromKV(key: String) async throws -> HealthQueueMigration {
        guard let data = try syncRead({ db in try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]) })
        else { return HealthQueueMigration(found: 0, inTable: 0, valueBytesBefore: 0, valueBytesAfter: 0) }
        guard let scan = HealthQueueKVScanner.scan(data), !scan.elements.isEmpty else {
            return HealthQueueMigration(found: 0, inTable: 0, valueBytesBefore: data.count, valueBytesAfter: data.count)
        }
        var inTable = 0
        var index = 0
        while index < scan.elements.count {
            let slice = scan.elements[index..<min(index + Self.healthQueueMigrationBatch, scan.elements.count)]
            var rows: [HealthQueueRow] = []
            for (offset, range) in slice.enumerated() {
                rows.append(try Self.healthQueueRow(from: data.subdata(in: range), position: index + offset))
            }
            inTable += try syncWrite { db -> Int in
                for r in rows {
                    let (stored, enc) = Self.healthBodyAtRest(r.body)
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO health_queue
                            (id, key, created_at, attempts, last_error, sample_count, body, body_enc, body_bytes)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [r.id.uuidString, r.key, r.createdAt.timeIntervalSince1970, r.attempts, r.lastError,
                                         r.sampleCount, stored, enc, r.body.count])
                }
                let marks = rows.map { _ in "?" }.joined(separator: ",")
                let present = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM health_queue WHERE id IN (\(marks))",
                                               arguments: StatementArguments(rows.map { $0.id.uuidString })) ?? 0
                // Every entry of this slice must be in the table before the document may lose it (a duplicated id in the old
                // document counts once, so compare with the distinct ids).
                guard present == Set(rows.map(\.id)).count else {
                    throw MGStoreError.coding("health queue migration: \(present) of \(rows.count) entries found after insert")
                }
                return present
            }
            index += slice.count
            await Task.yield()
        }
        // All entries are in the table: save the document without them. Only the bytes of the array change.
        var out = Data()
        out.append(data[data.startIndex..<scan.array.lowerBound])
        out.append(contentsOf: Array("[]".utf8))
        out.append(data[scan.array.upperBound..<data.endIndex])
        let before = data.count, after = out.count
        try syncWrite { db in
            try db.execute(sql: "UPDATE kv SET value = ? WHERE key = ?", arguments: [out, key])
        }
        return HealthQueueMigration(found: scan.elements.count, inTable: inTable, valueBytesBefore: before, valueBytesAfter: after)
    }

    /// One `Queued` of the old document (`HealthAutoState.Queued`, dates as seconds since 1970, `body` as base64) as a row.
    static func healthQueueRow(from json: Data, position: Int) throws -> HealthQueueRow {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let idText = o["id"] as? String, let id = UUID(uuidString: idText),
              let b64 = o["body"] as? String, let body = Data(base64Encoded: b64),
              let created = (o["createdAt"] as? NSNumber)?.doubleValue else {
            throw MGStoreError.coding("health queue migration: entry \(position) of the old queue cannot be read; nothing was changed")
        }
        return HealthQueueRow(id: id, key: o["key"] as? String, createdAt: Date(timeIntervalSince1970: created),
                              attempts: (o["attempts"] as? NSNumber)?.intValue ?? 0, lastError: o["lastError"] as? String,
                              sampleCount: (o["sampleCount"] as? NSNumber)?.intValue ?? 0, body: body)
    }
}

/// Finds the top-level `"queue":[ {...}, {...} ]` of the saved Health document in its bytes, without parsing the rest.
enum HealthQueueKVScanner {
    struct ScanResult: Equatable {
        /// From the `[` to just after the matching `]`.
        var array: Range<Int>
        /// The `{...}` ranges of the array's entries, in order.
        var elements: [Range<Int>]
    }

    static func scan(_ data: Data) -> ScanResult? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ScanResult? in
            let n = raw.count
            let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")

            /// Index just after the string that opens at `i` (raw[i] is a quote).
            func endOfString(_ i: Int) -> Int {
                var j = i + 1
                while j < n {
                    let c = raw[j]
                    if c == backslash { j += 2; continue }
                    if c == quote { return j + 1 }
                    j += 1
                }
                return n
            }
            func skipSpace(_ i: Int) -> Int {
                var j = i
                while j < n, raw[j] == 0x20 || raw[j] == 0x0A || raw[j] == 0x0D || raw[j] == 0x09 { j += 1 }
                return j
            }
            /// Index just after the `{...}` or `[...]` that opens at `i`.
            func endOfContainer(_ i: Int) -> Int {
                var depth = 0
                var j = i
                while j < n {
                    let c = raw[j]
                    if c == quote { j = endOfString(j); continue }
                    if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                    else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                        depth -= 1
                        if depth == 0 { return j + 1 }
                    }
                    j += 1
                }
                return n
            }

            let name = Array("queue".utf8)
            var depth = 0
            var i = 0
            while i < n {
                let c = raw[i]
                if c == quote {
                    let end = endOfString(i)
                    if depth == 1, end - i - 2 == name.count, (0..<name.count).allSatisfy({ raw[i + 1 + $0] == name[$0] }) {
                        var j = skipSpace(end)
                        if j < n, raw[j] == UInt8(ascii: ":") {
                            j = skipSpace(j + 1)
                            if j < n, raw[j] == UInt8(ascii: "[") {
                                let arrayEnd = endOfContainer(j)
                                guard arrayEnd <= n, raw[arrayEnd - 1] == UInt8(ascii: "]") else { return nil }
                                var elements: [Range<Int>] = []
                                var k = j + 1
                                while k < arrayEnd - 1 {
                                    k = skipSpace(k)
                                    if k >= arrayEnd - 1 { break }
                                    if raw[k] == UInt8(ascii: ",") { k += 1; continue }
                                    guard raw[k] == UInt8(ascii: "{") else { return nil }
                                    let e = endOfContainer(k)
                                    elements.append(k..<e)
                                    k = e
                                }
                                return ScanResult(array: j..<arrayEnd, elements: elements)
                            }
                        }
                    }
                    i = end
                    continue
                }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") { depth -= 1 }
                i += 1
            }
            return nil
        }
    }
}
