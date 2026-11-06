import Foundation
import GRDB
import MGDomain

/// Mo's keep / drop marks for comparison-group members (APP-117). Drop hides, never deletes.
public enum GroupMarkValue: String, Codable, Sendable, CaseIterable {
    case read = "read"
    case keep = "keep"
    case drop = "drop"
}

public struct GroupMarkEntry: Sendable, Equatable {
    public var groupId: String
    public var variant: String
    public var mark: GroupMarkValue
    public var at: Date

    public init(groupId: String, variant: String, mark: GroupMarkValue, at: Date) {
        self.groupId = groupId; self.variant = variant; self.mark = mark; self.at = at
    }
}

/// Metrics, series, PC lab results, group marks and the key-value store.
extension MGStore: ResultsSink {

    // MARK: Metrics

    /// Upserts metrics for `day` (D13: the pipeline decides the day; nightly metrics belong to the wake day). Key
    /// (local_day, name, variant, window, computed_on), absent variant/window stored as "" (§4.5). Every metric must
    /// pass `Metric.validate()` (R6) or nothing in the batch is written. Unchanged metrics do not dirty the day, and neither does one whose only change is its `at` stamp (T9988).
    /// Returns how many rows changed.
    @discardableResult
    public func upsertMetrics(_ metrics: [Metric], day: LocalDay) async throws -> Int {
        for m in metrics {
            let problems = m.validate()
            if !problems.isEmpty { throw MGStoreError.invalidMetric(name: m.name, violations: problems) }
        }
        let now = nowUnix
        return try syncWrite { db in
            var changed = 0
            for m in metrics {
                let json = try DocJSON.encode(m)
                let key = MetricKeyID(metric: m, day: day)
                let args: StatementArguments = [key.day.iso, key.name, key.variant, key.window, key.computedOn.rawValue]
                let stored = try Data.fetchOne(db, sql: """
                    SELECT json FROM metric
                    WHERE local_day = ? AND name = ? AND variant = ? AND metric_window = ? AND computed_on = ?
                    """, arguments: args)
                if stored == json { continue }
                // T9988: a recompute that only moved the `at` stamp is not a change. The row takes the new stamp, but the
                // day is not marked dirty: every compute used to dirty every day it touched, so each sync rebuilt the day
                // as a new content-hash drop (~400 KB) with the same data in it.
                if let stored, var old = try? DocJSON.decode(Metric.self, stored) {
                    old.at = m.at
                    if (try? DocJSON.encode(old)) == json {
                        try db.execute(sql: """
                            UPDATE metric SET at_unix = ?, json = ?, updated_at = ?
                            WHERE local_day = ? AND name = ? AND variant = ? AND metric_window = ? AND computed_on = ?
                            """, arguments: [m.at.unix, json, now, key.day.iso, key.name, key.variant, key.window,
                                             key.computedOn.rawValue])
                        continue
                    }
                }
                try db.execute(sql: """
                    INSERT INTO metric (local_day, name, variant, metric_window, computed_on, at_unix, json, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(local_day, name, variant, metric_window, computed_on) DO UPDATE SET
                        at_unix = excluded.at_unix, json = excluded.json, updated_at = excluded.updated_at
                    """, arguments: [key.day.iso, key.name, key.variant, key.window, key.computedOn.rawValue,
                                     m.at.unix, json, now])
                changed += 1
            }
            if changed > 0 { try markDirty(db, day.iso) }
            return changed
        }
    }

    /// SQL conditions: imported history (`ImportedHistory`), and its negation. The pipelines, the Health mirror, day
    /// drops and the context engine read only the app's own metrics; history screens opt in (`includingImported`).
    static let vendorRows = "(computed_on = 'pc' AND variant IN ("
        + ImportedHistory.variants.map { "'\($0)'" }.joined(separator: ", ") + "))"
    /// Ours on the imported backlog (`pc.history-derived`, variants `<id>:import`; wave 2, 2026-10-11).
    static let derivedRows = "(computed_on = 'pc' AND variant LIKE '_%" + ImportedHistory.derivedSuffix + "')"
    static let importedRows = "(" + vendorRows + " OR " + derivedRows + ")"
    static let ownOnly = "NOT " + importedRows

    /// The imported rows a model's result owns: a newer result of that model replaces them for its day, and never
    /// touches the other model's (a pc.history result must not delete pc.history-derived rows, BUILD-LOG 12:52).
    static func rowsOwned(by modelId: String) -> String? {
        switch modelId {
        case ImportedHistory.modelId: return vendorRows
        case ImportedHistory.derivedModelId: return derivedRows
        default: return nil
        }
    }

    /// Every metric of the app's own stored for `day`, in a fixed order (name, variant, window, computed_on).
    public func metrics(on day: LocalDay) async throws -> [Metric] {
        try await metrics(on: day, includingImported: false)
    }

    /// Every metric stored for `day`, imported history included when asked.
    public func metrics(on day: LocalDay, includingImported: Bool) async throws -> [Metric] {
        let rows = try syncRead { db in
            try Data.fetchAll(db, sql: """
                SELECT json FROM metric WHERE local_day = ? \(includingImported ? "" : "AND " + MGStore.ownOnly)
                ORDER BY name, variant, metric_window, computed_on
                """, arguments: [day.iso])
        }
        return try rows.map { try DocJSON.decode(Metric.self, $0) }
    }

    /// One metric name across days (Explore trends, baselines), ordered by day then variant; the app's own only.
    public func metrics(named name: String, from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        try await metrics(named: name, from: from, to: to, includingImported: false)
    }

    /// One metric name across days, imported history included when asked.
    public func metrics(named name: String, from: LocalDay, to: LocalDay,
                        includingImported: Bool) async throws -> [(day: LocalDay, metric: Metric)] {
        let rows = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT local_day, json FROM metric WHERE name = ? AND local_day BETWEEN ? AND ?
                \(includingImported ? "" : "AND " + MGStore.ownOnly)
                ORDER BY local_day, variant, metric_window, computed_on
                """, arguments: [name, from.iso, to.iso])
        }
        var out: [(day: LocalDay, metric: Metric)] = []
        for row in rows {
            let iso: String = row["local_day"]
            let json: Data = row["json"]
            guard let day = LocalDay(iso: iso) else { continue }
            out.append((day, try DocJSON.decode(Metric.self, json)))
        }
        return out
    }

    /// Every metric row of every name in [from, to], imported history included, in one read (R7 / T23: Model status asked
    /// once per metric key, 300+ reads on every launch). Within one name the order is the same as `metrics(named:)`.
    public func metricsAllNames(from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        let rows = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT local_day, json FROM metric WHERE local_day BETWEEN ? AND ?
                ORDER BY local_day, variant, metric_window, computed_on
                """, arguments: [from.iso, to.iso])
        }
        var out: [(day: LocalDay, metric: Metric)] = []
        for row in rows {
            let iso: String = row["local_day"]
            let json: Data = row["json"]
            guard let day = LocalDay(iso: iso) else { continue }
            out.append((day, try DocJSON.decode(Metric.self, json)))
        }
        return out
    }

    /// The oldest day the phone holds a metric row for — of `name`, or of any metric (`name` nil); imported history
    /// included. Explore asks the PC only for days before it (tracker #7, 2026-10-11). Uses the metric_name index.
    public func oldestMetricDay(named name: String?) async throws -> LocalDay? {
        let iso = try syncRead { db -> String? in
            if let name {
                return try String.fetchOne(db, sql: "SELECT MIN(local_day) FROM metric WHERE name = ?", arguments: [name])
            }
            return try String.fetchOne(db, sql: "SELECT MIN(local_day) FROM metric")
        }
        return iso.flatMap { LocalDay(iso: $0) }
    }

    // MARK: Series

    /// Upserts series for `day`, key (local_day, name, variant) read from the contract keys `name` / `variant`.
    @discardableResult
    public func upsertSeries(_ series: [Series], day: LocalDay) async throws -> Int {
        let now = nowUnix
        return try syncWrite { db in
            var changed = 0
            for s in series {
                let json = try DocJSON.encode(s)
                let obj = try DocJSON.object(json)
                let name = try DocJSON.string(obj, "name", what: "series")
                let variant = obj["variant"] as? String ?? ""
                let stored = try Data.fetchOne(db, sql: """
                    SELECT json FROM series WHERE local_day = ? AND name = ? AND variant = ?
                    """, arguments: [day.iso, name, variant])
                if stored == json { continue }
                try db.execute(sql: """
                    INSERT INTO series (local_day, name, variant, json, updated_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(local_day, name, variant) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at
                    """, arguments: [day.iso, name, variant, json, now])
                changed += 1
            }
            if changed > 0 { try markDirty(db, day.iso) }
            return changed
        }
    }

    public func series(on day: LocalDay) async throws -> [Series] {
        let rows = try syncRead { db in
            try Data.fetchAll(db, sql: "SELECT json FROM series WHERE local_day = ? ORDER BY name, variant",
                              arguments: [day.iso])
        }
        return try rows.map { try DocJSON.decode(Series.self, $0) }
    }

    // MARK: ResultsSink (§5.6)

    /// Highest results `seq` stored; MGSync asks the PC for `results?since=<cursor>`.
    public var resultsCursor: Int {
        get async {
            (try? syncRead { db in try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM lab_result") }) ?? 0
        }
    }

    /// Keeps every PC result, key (date, model_id, model_version, inputs_hash) — read from the contract keys. A result
    /// re-fetched with the same key replaces its JSON. Results do not dirty days (they came from the PC).
    ///
    /// An ok `pc.history` or `pc.history-derived` result (imported history, `ImportedHistory`) also becomes that day's
    /// imported rows in `metric`, in the same transaction: its metrics are upserted (computed_on pc and an import
    /// variant, so the key never meets a phone or strap row) and the day's other imported rows OF THAT MODEL — ones the
    /// newer result no longer has — are removed (`rowsOwned(by:)`: the vendors' values and ours-on-the-backlog never
    /// remove each other). Results arrive in seq order, so the newest wins. Imported rows never dirty a day. A metric
    /// that fails `validate()` or is not that model's imported value throws `invalidMetric` and nothing is written.
    public func store(_ result: LabResult, sha256: String, seq: Int) async throws {
        let json = try DocJSON.encode(result)
        let obj = try DocJSON.object(json)
        let date = try DocJSON.string(obj, "date", what: "labResult")
        let model = try DocJSON.string(obj, "model_id", what: "labResult")
        let version = try DocJSON.string(obj, "model_version", what: "labResult")
        let inputs = obj["inputs_hash"] as? String ?? ""
        let owned = MGStore.rowsOwned(by: result.modelId)
        let imported = owned != nil && (result.status ?? "ok") == "ok"
        if imported {
            for m in result.metrics {
                var problems = m.validate()
                if !ImportedHistory.isImported(m) || ImportedHistory.owner(ofVariant: m.variant) != result.modelId {
                    problems.append(result.modelId == ImportedHistory.modelId
                        ? "a pc.history metric must be computed_on pc with variant "
                            + ImportedHistory.variants.joined(separator: " / ")
                        : "a \(result.modelId) metric must be computed_on pc with a variant ending "
                            + ImportedHistory.derivedSuffix)
                }
                if !problems.isEmpty { throw MGStoreError.invalidMetric(name: m.name, violations: problems) }
            }
        }
        let now = nowUnix
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO lab_result (date, model_id, model_version, inputs_hash, json, sha256, received_at, seq)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(date, model_id, model_version, inputs_hash) DO UPDATE SET
                    json = excluded.json, sha256 = excluded.sha256, received_at = excluded.received_at,
                    seq = excluded.seq
                """, arguments: [date, model, version, inputs, json, sha256, now, seq])
            guard imported, let owned else { return }
            var keep = Set<MetricKeyID>()
            for m in result.metrics {
                let key = MetricKeyID(metric: m, day: result.date)
                let mjson = try DocJSON.encode(m)
                keep.insert(key)
                try db.execute(sql: """
                    INSERT INTO metric (local_day, name, variant, metric_window, computed_on, at_unix, json, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(local_day, name, variant, metric_window, computed_on) DO UPDATE SET
                        at_unix = excluded.at_unix, json = excluded.json, updated_at = excluded.updated_at
                    """, arguments: [key.day.iso, key.name, key.variant, key.window, key.computedOn.rawValue,
                                     m.at.unix, mjson, now])
            }
            let held = try Row.fetchAll(db, sql: """
                SELECT name, variant, metric_window FROM metric WHERE local_day = ? AND \(owned)
                """, arguments: [result.date.iso])
            for row in held {
                let key = MetricKeyID(day: result.date, name: row["name"], variant: row["variant"],
                                      window: row["metric_window"], computedOn: .pc)
                if keep.contains(key) { continue }
                try db.execute(sql: """
                    DELETE FROM metric
                    WHERE local_day = ? AND name = ? AND variant = ? AND metric_window = ? AND computed_on = 'pc'
                    """, arguments: [key.day.iso, key.name, key.variant, key.window])
            }
        }
    }

    /// Every stored result for a date, newest `seq` first.
    public func labResults(date: LocalDay) async throws -> [LabResult] {
        let rows = try syncRead { db in
            try Data.fetchAll(db, sql: "SELECT json FROM lab_result WHERE date = ? ORDER BY seq DESC, model_id",
                              arguments: [date.iso])
        }
        return try rows.map { try DocJSON.decode(LabResult.self, $0) }
    }

    /// Every stored result dated `from` or later, leaving out the given models (the imported-history ones are rows in
    /// `metric` already), newest `seq` first. One unreadable row is skipped, not fatal: its date and model come back in
    /// the second value so the screen can say so. Wave 2 (2026-10-11): the phone shows every PC result.
    public func labResults(from: LocalDay, excluding models: [String],
                           newestPerModel: Int = 1_000_000) async throws -> ([LabResult], [String]) {
        // model ids are [A-Za-z0-9_.-] (the PC's result-name rule), so they are inlined as literals; anything else is
        // refused rather than quoted
        let ok = models.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "_.-".contains($0) } }
        guard ok else { throw MGStoreError.coding("lab result filter: model ids must be letters, digits, _ . -: \(models)") }
        let filter = models.isEmpty ? "" : "AND model_id NOT IN (" + models.map { "'\($0)'" }.joined(separator: ", ") + ")"
        // the newest `newestPerModel` of each model (window function; SQLite 3.25+, iOS 13+)
        let rows = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT date, model_id, json FROM (
                    SELECT date, model_id, json, seq,
                           ROW_NUMBER() OVER (PARTITION BY model_id ORDER BY seq DESC) AS rn
                    FROM lab_result WHERE date >= ? \(filter))
                WHERE rn <= ? ORDER BY seq DESC
                """, arguments: [from.iso, max(1, newestPerModel)])
        }
        var out: [LabResult] = []
        var unreadable: [String] = []
        for row in rows {
            let json: Data = row["json"]
            if let r = try? DocJSON.decode(LabResult.self, json) {
                out.append(r)
            } else {
                let d: String = row["date"]
                let m: String = row["model_id"]
                unreadable.append("\(d) \(m)")
            }
        }
        return (out, unreadable)
    }

    /// The newest row of every (name, variant, computed_on) with a day in [from, to], imported history included,
    /// workout windows left out — one query (SQLite takes the bare columns from the MAX(local_day) row). For Explore's
    /// "Every measure" and the metric detail's sources (wave 2, 2026-10-11).
    public func latestMetrics(from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        let rows = try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT json, MAX(local_day) AS newest FROM metric
                WHERE local_day BETWEEN ? AND ? AND metric_window NOT LIKE 'workout%'
                GROUP BY name, variant, computed_on
                """, arguments: [from.iso, to.iso])
        }
        var out: [(day: LocalDay, metric: Metric)] = []
        for row in rows {
            let iso: String = row["newest"]
            let json: Data = row["json"]
            guard let day = LocalDay(iso: iso), let m = try? DocJSON.decode(Metric.self, json) else { continue }
            out.append((day, m))
        }
        return out
    }

    // MARK: Group marks (APP-117)

    /// Sets the current mark and appends to the log (append-only). Never deletes a metric.
    public func setGroupMark(groupId: String, variant: String, mark: GroupMarkValue, at: Date) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO group_mark (group_id, variant, mark, at) VALUES (?, ?, ?, ?)
                ON CONFLICT(group_id, variant) DO UPDATE SET mark = excluded.mark, at = excluded.at
                """, arguments: [groupId, variant, mark.rawValue, at.unix])
            try db.execute(sql: "INSERT INTO group_mark_log (group_id, variant, mark, at) VALUES (?, ?, ?, ?)",
                           arguments: [groupId, variant, mark.rawValue, at.unix])
        }
    }

    public func groupMarks() async throws -> [GroupMarkEntry] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT group_id, variant, mark, at FROM group_mark ORDER BY group_id, variant")
                .compactMap(MGStore.markEntry)
        }
    }

    public func groupMarkLog() async throws -> [GroupMarkEntry] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT group_id, variant, mark, at FROM group_mark_log ORDER BY id")
                .compactMap(MGStore.markEntry)
        }
    }

    static func markEntry(_ row: Row) -> GroupMarkEntry? {
        let raw: String = row["mark"]
        guard let mark = GroupMarkValue(rawValue: raw) else { return nil }
        let at: Double = row["at"]
        return GroupMarkEntry(groupId: row["group_id"], variant: row["variant"], mark: mark,
                              at: Date(timeIntervalSince1970: at))
    }

    // MARK: Key-value (profile, settings, install salt, consents)

    public func value(forKey key: String) async throws -> Data? {
        try syncRead { db in try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]) }
    }

    public func setValue(_ value: Data, forKey key: String) async throws {
        try syncWrite { db in try putKV(db, key, value) }
    }

    /// Every row of the key-value area, for Settings > Export (bug 31). Read-only.
    public func allKeyValues() async throws -> [(key: String, value: Data)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM kv ORDER BY key").map { (key: $0["key"] as String, value: $0["value"] as Data) }
        }
    }

    public func profile() async throws -> Profile? {
        try await value(forKey: "profile").map { try DocJSON.decode(Profile.self, $0) }
    }

    public func setProfile(_ profile: Profile) async throws {
        try await setValue(try DocJSON.encode(profile), forKey: "profile")
    }

    /// P9745: the last PC profile the phone fetched (GET /v1/profile). Kept so the models can use it between fetches.
    public func pcProfile() async throws -> PCProfileSnapshot? {
        try await value(forKey: "pc_profile").map { try DocJSON.decode(PCProfileSnapshot.self, $0) }
    }

    public func setPCProfile(_ snapshot: PCProfileSnapshot) async throws {
        try await setValue(try DocJSON.encode(snapshot), forKey: "pc_profile")
    }

    /// P9745: the profile every model reads: Me profile first, empty fields from the PC snapshot (`EffectiveProfile`).
    public func effectiveProfile() async throws -> Profile? {
        let phone = try await profile()
        let pc = try await pcProfile()
        if phone == nil, pc == nil { return nil }
        return EffectiveProfile.merged(phone: phone, pc: pc, today: LocalDay(date: Date(), calendar: Calendar.current))
    }

    /// The per-install salt for `StrapID` (§4.3: "s_" + 16 hex of SHA256(installSalt + peripheral UUID)). Created
    /// once (32 random bytes from the system CSPRNG) and kept; never leaves the phone.
    public func installSalt() async throws -> Data {
        try syncWrite { db in
            if let salt = try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = 'install_salt'") { return salt }
            var rng = SystemRandomNumberGenerator()
            let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) })
            try putKV(db, "install_salt", salt)
            return salt
        }
    }

    func putKV(_ db: Database, _ key: String, _ value: Data) throws {
        // T140 (2026-10-12): iOS flagged 1 GB of file writes in ~6 h. `saveState` rewrites three documents on most taps and
        // events whether or not anything changed; with `synchronous = FULL` each rewrite is a flushed transaction. A
        // document whose bytes are identical is read, not written (like `upsertMetrics` does for metrics).
        if let stored = try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]), stored == value {
            return
        }
        try db.execute(sql: """
            INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [key, value])
    }
}
