import Foundation
import GRDB
import MGDomain

/// Events (contract eventBase + typed payload, stored as the full MGJSON object), the strap write audit log and the
/// Apple Health intake. Every change bumps `revision` (v0.5 proposal, D10) and marks the event's local day dirty
/// (D13: an event belongs to the local calendar date of `at`). Remove is soft: `removed: true`, kept and exported
/// (UX §7 "Remove"; the PC merges per id, highest revision wins, removed kept — §5.4).
extension MGStore: StrapWriteLog, HealthSampleSink {

    // MARK: Events

    /// Inserts or updates an event by `id`.
    /// - New id: stored with `revision = max(1, event.revision)`.
    /// - Known id, different content: stored with `revision = stored + 1` (the caller's revision is ignored).
    /// - Known id, same content (apart from revision): nothing changes, the day is not dirtied.
    /// Moving `at` to another day dirties both days. Returns the event as stored.
    @discardableResult
    public func upsertEvent(_ event: EventRecord) async throws -> EventRecord {
        try syncWrite { db in try upsertEventRow(db, event) }
    }

    /// Soft remove (UX §7): `removed = true`, revision + 1. The row stays and goes out in `events.jsonl`.
    @discardableResult
    public func removeEvent(id: UUID) async throws -> EventRecord {
        try syncWrite { db in try setRemoved(db, id: id, removed: true) }
    }

    /// Undo of a soft remove (UX §7 "5 s undo"): `removed = false`, revision + 1.
    @discardableResult
    public func restoreEvent(id: UUID) async throws -> EventRecord {
        try syncWrite { db in try setRemoved(db, id: id, removed: false) }
    }

    public func event(id: UUID) async throws -> EventRecord? {
        try syncRead { db in
            try Data.fetchOne(db, sql: "SELECT json FROM event WHERE id = ?", arguments: [id.uuidString])
        }.map { try DocJSON.decode(EventRecord.self, $0) }
    }

    /// Events of one local day, ordered by `at` then id.
    public func events(on day: LocalDay, includeRemoved: Bool = false) async throws -> [EventRecord] {
        let rows = try syncRead { db in
            try Data.fetchAll(db, sql: """
                SELECT json FROM event WHERE local_day = ? AND (? = 1 OR removed = 0) ORDER BY at_unix, id
                """, arguments: [day.iso, includeRemoved])
        }
        return try rows.map { try DocJSON.decode(EventRecord.self, $0) }
    }

    /// Events with `at` in [from, to], optionally of the given types, ordered by `at` then id.
    public func events(from: Date, to: Date, types: [EventType]? = nil,
                       includeRemoved: Bool = false) async throws -> [EventRecord] {
        let rows = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT type, json FROM event WHERE at_unix BETWEEN ? AND ? AND (? = 1 OR removed = 0)
                ORDER BY at_unix, id
                """, arguments: [from.unix, to.unix, includeRemoved])
        }
        let wanted = types.map { Set($0.map(\.rawValue)) }
        var out: [EventRecord] = []
        for row in rows {
            let type: String = row["type"]
            if let wanted, !wanted.contains(type) { continue }
            let json: Data = row["json"]
            out.append(try DocJSON.decode(EventRecord.self, json))
        }
        return out
    }

    /// Every event of the given types, whenever it happened, oldest first, removed ones left out (Settings › Profile
    /// lists of injuries and body-composition entries; tracker #42, 2026-10-11). Types are inlined from EventType's raw
    /// values (a closed set of [a-z_] words), never from free text.
    public func events(ofTypes types: [EventType]) async throws -> [EventRecord] {
        guard !types.isEmpty else { return [] }
        let list = types.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        let rows = try syncRead { db in
            try Data.fetchAll(db, sql: "SELECT json FROM event WHERE type IN (\(list)) AND removed = 0 ORDER BY at_unix, id")
        }
        return try rows.map { try DocJSON.decode(EventRecord.self, $0) }
    }

    func upsertEventRow(_ db: Database, _ incoming: EventRecord) throws -> EventRecord {
        let id = incoming.id.uuidString
        let existing = try Row.fetchOne(db, sql: "SELECT revision, json, local_day FROM event WHERE id = ?",
                                        arguments: [id])
        var event = incoming
        if let existing {
            let storedRevision: Int = existing["revision"]
            let storedJSON: Data = existing["json"]
            event.revision = storedRevision
            if try DocJSON.encode(event) == storedJSON { return try DocJSON.decode(EventRecord.self, storedJSON) }
            event.revision = storedRevision + 1
            let oldDay: String = existing["local_day"]
            if oldDay != localDay(event.at).iso, event.type != .strapWrite { try markDirty(db, oldDay) }
        } else {
            event.revision = max(1, incoming.revision)
        }
        let json = try DocJSON.encode(event)
        let day = localDay(event.at).iso
        try db.execute(sql: """
            INSERT INTO event (id, type, at_unix, local_day, logged_at, source, revision, removed, json, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                type = excluded.type, at_unix = excluded.at_unix, local_day = excluded.local_day,
                logged_at = excluded.logged_at, source = excluded.source, revision = excluded.revision,
                removed = excluded.removed, json = excluded.json, updated_at = excluded.updated_at
            """, arguments: [id, event.type.rawValue, event.at.unix, day, event.loggedAt?.unix,
                             event.source.rawValue, event.revision, event.removed, json, nowUnix])
        // r8a 2026-10-17 (audit §4.1, T10002): a strap write is an audit-log row, not day content. Logging one (a SET_CLOCK
        // on every reconnect) must not make its day "changed" and re-send the whole day drop. The row still goes out in
        // `events.jsonl` of that day's next drop, which something else dirtied.
        if event.type != .strapWrite { try markDirty(db, day) }
        return event
    }

    func setRemoved(_ db: Database, id: UUID, removed: Bool) throws -> EventRecord {
        guard let json = try Data.fetchOne(db, sql: "SELECT json FROM event WHERE id = ?",
                                           arguments: [id.uuidString]) else {
            throw MGStoreError.unknownEvent(id)
        }
        var event = try DocJSON.decode(EventRecord.self, json)
        guard event.removed != removed else { return event }
        event.removed = removed
        return try upsertEventRow(db, event)
    }

    // MARK: StrapWriteLog

    /// Every strap write (prior value, payload, readback, restored) persisted as a contract `strap_write` event (§4.3,
    /// contract strapWriteEvent; PLAN rule 5) through MGDomain's `StrapWriteEntry.contractFields`, on the same path as
    /// every other event. `at` = `entry.confirmedAt`, which the caller sets to when the write was made (r8a 2026-10-17:
    /// the clock sync used to pass the pairing-consent time, which dated every SET_CLOCK on Oct 11); `standingConsent`
    /// goes in `note` (the contract has no field for it). Never dirties the event's day (see `upsertEventRow`).
    public func log(_ entry: StrapWriteEntry) async throws {
        let event = EventRecord(at: entry.confirmedAt, loggedAt: clock.now, source: .manual,
                                note: entry.standingConsent ? MGStore.standingConsentNote : MGStore.sheetConsentNote,
                                payload: .strapWrite(entry.contractFields))
        _ = try syncWrite { db in try upsertEventRow(db, event) }
    }

    static let standingConsentNote = "standing consent (pairing)"
    static let sheetConsentNote = "confirmed in the write sheet"

    /// The strap write log, newest first (by confirmation time, then the order the writes were logged — the 16 unlock
    /// writes share one confirmation). For the strap sheet's write log (WP-13). `restored` comes back as stored.
    public func strapWriteEntries(limit: Int = 200) async throws -> [StrapWriteEntry] {
        try strapWriteRows(limit: limit)
    }

    /// The value to restore for `command` (+ flag `key`): the prior (pre-write) value logged by the **earliest**
    /// non-restore write since the most recent restore write (`restored == true`) for that command + key, or since the
    /// start of the log if there was none — i.e. the original value before the current unlock streak. So running the
    /// unlock twice without a restore still returns the value from before the first unlock (the second unlock's prior
    /// is the first unlock's written value), and after a restore only the next unlock's prior counts. Writes that
    /// logged no prior value are ignored. Nil when nothing in the current streak logged a prior. Lets the unlock
    /// restore work after an app restart (WP-04).
    ///
    /// For SET_FF_VALUE (120) `key` is the flag name, matched against the entry's `name` or the key carried in its
    /// payload (`[01] + key NUL-padded to 32 bytes + …`; since 2026-10-11 the 65-byte body of MGBLE Commands.swift
    /// `setR22Packets`, value text NUL-padded to 32; the old 40-byte form has the key at the same offset);
    /// `key` nil matches any entry of `command`.
    public func latestPriorValue(command: UInt8, key: String?) async throws -> String? {
        var original: String?
        for e in try strapWriteRows(limit: nil) {          // newest first
            guard e.command == Int(command) else { continue }
            if let key, e.name != key, MGStore.flagKey(payloadHex: e.payloadHex) != key { continue }
            if e.restored == true { break }                 // the streak starts after the latest restore
            if let prior = e.priorValue { original = prior } // keep overwriting: the earliest one wins
        }
        return original
    }

    func strapWriteRows(limit: Int?) throws -> [StrapWriteEntry] {
        let rows = try syncRead { db in
            try Data.fetchAll(db, sql: """
                SELECT json FROM event WHERE type = 'strap_write'
                ORDER BY at_unix DESC, updated_at DESC, rowid DESC LIMIT ?
                """, arguments: [limit ?? -1])
        }
        var out: [StrapWriteEntry] = []
        for json in rows {
            let event = try DocJSON.decode(EventRecord.self, json)
            guard case .strapWrite(let f) = event.payload else { continue }
            out.append(StrapWriteEntry(fields: f, standingConsent: event.note == MGStore.standingConsentNote))
        }
        return out
    }

    /// The flag key inside a SET_FF_VALUE payload: bytes 1..<33 up to the first NUL, as UTF-8. Nil if not that shape.
    static func flagKey(payloadHex: String) -> String? {
        let hex = Array(payloadHex.utf8)
        guard hex.count >= 66, hex.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var bytes: [UInt8] = []
        var i = 0
        while i < 66 {
            guard let hi = nibble(hex[i]), let lo = nibble(hex[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        guard bytes[0] == 0x01 else { return nil }
        let name = bytes[1...].prefix { $0 != 0 }
        guard !name.isEmpty else { return nil }
        return String(decoding: name, as: UTF8.self)
    }

    // MARK: HealthSampleSink

    /// Apple Health samples as events, one transaction. Re-reading an unchanged sample (same id, same content) changes
    /// nothing, so a Health re-read does not dirty days or grow revisions.
    public func ingest(_ events: [EventRecord]) async throws {
        guard !events.isEmpty else { return }
        try syncWrite { db in
            for e in events { _ = try upsertEventRow(db, e) }
        }
    }

    public func anchor(for type: String) async -> Data? {
        try? syncRead { db in
            try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: ["hk_anchor." + type])
        }
    }

    public func setAnchor(_ data: Data, for type: String) async throws {
        try syncWrite { db in try putKV(db, "hk_anchor." + type, data) }
    }
}
