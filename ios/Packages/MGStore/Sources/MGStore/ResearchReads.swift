import Foundation
import GRDB

// Live › research screens (W10, tracker #91, 2026-10-11): what the phone holds, read only. The record inspector reads
// the newest decoded rows of each kind; the capture session counts raw frames by packet type inside its span; the
// retention screen reads what raw is on the phone, what the PC confirmed and the oldest of each.

/// One decoded record for the inspector: kind, time, key fields as text (raw counts stay counts).
public struct StoreRecordRow: Sendable, Equatable {
    public var kind: String
    public var at: Date
    public var fields: [String]
}

/// What raw the phone holds and how much of it the PC confirmed (Live › Raw retention).
public struct RawRetentionStatus: Sendable, Equatable {
    public var rawFrames: Int
    public var rawBytes: Int64
    public var rawUnconfirmed: Int
    public var oldestRaw: Date?
    public var oldestConfirmedRaw: Date?
    public var oldestUnconfirmedRaw: Date?
    /// hr_sample / rr_interval / r18_second: rows and the oldest second (unix s).
    public var perSecond: [(table: String, rows: Int, oldest: Int64?)]

    public static func == (a: RawRetentionStatus, b: RawRetentionStatus) -> Bool {
        a.rawFrames == b.rawFrames && a.rawBytes == b.rawBytes && a.rawUnconfirmed == b.rawUnconfirmed
            && a.oldestRaw == b.oldestRaw && a.oldestConfirmedRaw == b.oldestConfirmedRaw
            && a.oldestUnconfirmedRaw == b.oldestUnconfirmedRaw
            && a.perSecond.map { "\($0.table)|\($0.rows)|\($0.oldest ?? -1)" }
                == b.perSecond.map { "\($0.table)|\($0.rows)|\($0.oldest ?? -1)" }
    }
}

/// The strap's own on-chip values over a window (Decode lab "Strap vs ours", T90): mean and count per kind.
public struct StrapOnChip: Sendable {
    public var hr: (mean: Double, n: Int)?
    public var rr: (mean: Double, n: Int)?
    public var batteryPercent: Double?
    /// Raw counts (R18 skin_temp_raw / spo2_byte): they stay counts.
    public var skinTempRaw: (mean: Double, n: Int)?
    public var spo2Byte: (mean: Double, n: Int)?
}

extension MGStore {
    /// The newest `limit` decoded records across kinds (R18 seconds, HR, R-R, strap events, raw frames), newest first.
    public func recentRecords(limit: Int = 40) async throws -> [StoreRecordRow] {
        let n = max(1, min(limit, 200))
        return try syncRead { db in
            var out: [StoreRecordRow] = []
            for r in try Row.fetchAll(db, sql: """
                SELECT ts, hr, rr_count, steps, activity_class, skin_temp_raw, sleep_state, spo2_byte
                FROM r18_second ORDER BY ts DESC LIMIT ?
                """, arguments: [n]) {
                var f: [String] = []
                if let hr: Double = r["hr"] { f.append("HR \(Int(hr.rounded()))") }
                f.append("R-R \(r["rr_count"] as Int? ?? 0)")
                if let s: Int = r["steps"] { f.append("step counter \(s)") }
                if let a: Int = r["activity_class"] { f.append("activity class \(a)") }
                if let t: Int = r["skin_temp_raw"] { f.append("skin temp raw \(t) (count)") }
                if let sl: Int = r["sleep_state"] { f.append("sleep state \(sl)") }
                if let o: Int = r["spo2_byte"] { f.append("SpO2 byte \(o) (count)") }
                out.append(StoreRecordRow(kind: "R18 second", at: Date(timeIntervalSince1970: TimeInterval(r["ts"] as Int64)),
                                          fields: f))
            }
            for r in try Row.fetchAll(db, sql: "SELECT ts, source, bpm FROM hr_sample ORDER BY ts DESC LIMIT ?",
                                      arguments: [n]) {
                let bpm: Double = r["bpm"]
                out.append(StoreRecordRow(kind: "HR sample", at: Date(timeIntervalSince1970: TimeInterval(r["ts"] as Int64)),
                                          fields: ["\(Int(bpm.rounded())) bpm", "source \(r["source"] as String)"]))
            }
            for r in try Row.fetchAll(db, sql: "SELECT ts, ord, rr_ms FROM rr_interval ORDER BY ts DESC, ord DESC LIMIT ?",
                                      arguments: [n]) {
                let ms: Double = r["rr_ms"]
                out.append(StoreRecordRow(kind: "R-R interval", at: Date(timeIntervalSince1970: TimeInterval(r["ts"] as Int64)),
                                          fields: ["\(Int(ms.rounded())) ms", "beat \(r["ord"] as Int)"]))
            }
            for r in try Row.fetchAll(db, sql: "SELECT ts, number, name, payload_hex FROM strap_event ORDER BY ts DESC LIMIT ?",
                                      arguments: [n]) {
                let hex: String = r["payload_hex"]
                out.append(StoreRecordRow(kind: "Strap event", at: Date(timeIntervalSince1970: TimeInterval(r["ts"] as Int64)),
                                          fields: ["\(r["number"] as Int) \(r["name"] as String)",
                                                   hex.isEmpty ? "no payload" : "payload \(hex.prefix(24))"]))
            }
            for r in try Row.fetchAll(db, sql: """
                SELECT received_at, packet_type, length(bytes) AS n,
                       (pc_confirmed = 1 OR id <= COALESCE((SELECT h.confirmed_wm FROM raw_hour h
                           WHERE h.hour = (CAST(raw_frame.received_at AS INTEGER) / 3600) * 3600), 0)) AS pc_confirmed
                FROM raw_frame
                ORDER BY received_at DESC LIMIT ?
                """, arguments: [n]) {
                out.append(StoreRecordRow(kind: "Raw frame", at: Date(timeIntervalSince1970: r["received_at"] as Double),
                                          fields: ["packet type \(r["packet_type"] as Int)", "\(r["n"] as Int) bytes",
                                                   (r["pc_confirmed"] as Int) == 1 ? "PC confirmed" : "not confirmed yet"]))
            }
            return Array(out.sorted { $0.at > $1.at }.prefix(n))
        }
    }

    /// Raw frames received in [from, to] by packet type (capture sessions).
    public func rawFrameCounts(from: Date, to: Date) async throws -> [Int: Int] {
        try syncRead { db in
            var out: [Int: Int] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT packet_type, COUNT(*) AS n FROM raw_frame WHERE received_at BETWEEN ? AND ? GROUP BY packet_type
                """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]) {
                out[r["packet_type"]] = r["n"]
            }
            return out
        }
    }

    /// Raw frames received in [from, to] by packet type with the newest one's time (Decode lab).
    public func rawStreamStats(from: Date, to: Date) async throws -> [(packetType: Int, frames: Int, last: Date)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT packet_type, COUNT(*) AS n, MAX(received_at) AS last FROM raw_frame
                WHERE received_at BETWEEN ? AND ? GROUP BY packet_type ORDER BY packet_type
                """, arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]).map {
                (packetType: $0["packet_type"] as Int, frames: $0["n"] as Int, last: Date(timeIntervalSince1970: $0["last"] as Double))
            }
        }
    }

    /// What the strap reported in [from, to]: mean HR, mean R-R, the newest battery percent, mean skin-temp count and
    /// SpO2 byte (a kind with no rows is nil).
    public func strapOnChip(from: Date, to: Date) async throws -> StrapOnChip {
        let a = Int64(from.timeIntervalSince1970), b = Int64(to.timeIntervalSince1970)
        return try syncRead { db in
            func mean(_ sql: String) throws -> (mean: Double, n: Int)? {
                guard let r = try Row.fetchOne(db, sql: sql, arguments: [a, b]),
                      let n = r["n"] as Int?, n > 0, let m = r["m"] as Double? else { return nil }
                return (m, n)
            }
            return StrapOnChip(
                hr: try mean("SELECT AVG(bpm) AS m, COUNT(*) AS n FROM hr_sample WHERE ts BETWEEN ? AND ?"),
                rr: try mean("SELECT AVG(rr_ms) AS m, COUNT(*) AS n FROM rr_interval WHERE ts BETWEEN ? AND ?"),
                batteryPercent: try Double.fetchOne(db, sql: "SELECT percent FROM battery WHERE ts BETWEEN ? AND ? ORDER BY ts DESC LIMIT 1",
                                                    arguments: [a, b]),
                skinTempRaw: try mean("SELECT AVG(skin_temp_raw) AS m, COUNT(skin_temp_raw) AS n FROM r18_second WHERE ts BETWEEN ? AND ?"),
                spo2Byte: try mean("SELECT AVG(spo2_byte) AS m, COUNT(spo2_byte) AS n FROM r18_second WHERE ts BETWEEN ? AND ?"))
        }
    }

    public func rawRetentionStatus() async throws -> RawRetentionStatus {
        try syncRead { db in
            // r8l 2026-10-17 (audit §3.3): counters from `raw_hour` (one row per hour); the oldest confirmed / unconfirmed
            // frame is looked up inside the one hour that holds it, not by scanning `raw_frame`.
            let raw = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(frames), 0) AS n, COALESCE(SUM(bytes), 0) AS b,
                       COALESCE(SUM(frames - confirmed_frames), 0) AS u
                FROM raw_hour
                """)
            func oldestIn(hour: Int64?, confirmed: Bool) throws -> Double? {
                guard let h = hour else { return nil }
                let cond = confirmed ? "(pc_confirmed = 1 OR id <= wm)" : "(pc_confirmed = 0 AND id > wm)"
                return try Double.fetchOne(db, sql: """
                    SELECT MIN(received_at) FROM raw_frame,
                        (SELECT confirmed_wm AS wm FROM raw_hour WHERE hour = ?)
                    WHERE received_at >= ? AND received_at < ? AND \(cond)
                    """, arguments: [h, Double(h), Double(h + MGStore.rawHourSeconds)])
            }
            let oldest = try Double.fetchOne(db, sql: "SELECT MIN(received_at) FROM raw_frame")
            let oc = try oldestIn(hour: try Int64.fetchOne(db, sql: "SELECT MIN(hour) FROM raw_hour WHERE confirmed_frames > 0"),
                                  confirmed: true)
            let ou = try oldestIn(hour: try Int64.fetchOne(db, sql: "SELECT MIN(hour) FROM raw_hour WHERE frames > confirmed_frames"),
                                  confirmed: false)
            func date(_ v: Double?) -> Date? { v.map { Date(timeIntervalSince1970: $0) } }
            var per: [(table: String, rows: Int, oldest: Int64?)] = []
            for t in ["hr_sample", "rr_interval", "r18_second"] {
                let r = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, MIN(ts) AS o FROM \(t)")
                per.append((t, r?["n"] ?? 0, r?["o"]))
            }
            return RawRetentionStatus(rawFrames: raw?["n"] ?? 0, rawBytes: raw?["b"] ?? 0, rawUnconfirmed: raw?["u"] ?? 0,
                                      oldestRaw: date(oldest), oldestConfirmedRaw: date(oc),
                                      oldestUnconfirmedRaw: date(ou), perSecond: per)
        }
    }
}
