import Foundation
import GRDB
import MGDomain

/// Wave W11 (2026-10-11): reads for the Live back-fill (where stored HR ends) and Settings › Usage (what raw motion
/// stores). Read-only.
extension MGStore {
    /// The newest strap second with a heart rate at or before `ts`: live / history / 0x2A37 samples and history R18
    /// seconds. nil when nothing is stored. Both reads walk the `ts` index from the top.
    public func newestHRSecond(atOrBefore ts: Int64) async throws -> Int64? {
        try syncRead { db in
            let sample = try Int64.fetchOne(db, sql: """
                SELECT ts FROM hr_sample WHERE ts <= ? AND bpm > 0 ORDER BY ts DESC LIMIT 1
                """, arguments: [ts])
            let r18 = try Int64.fetchOne(db, sql: """
                SELECT ts FROM r18_second WHERE ts <= ? AND hr > 0 ORDER BY ts DESC LIMIT 1
                """, arguments: [ts])
            return [sample, r18].compactMap { $0 }.max()
        }
    }

    /// History R18 seconds as HR points (source history) in [from, to] — the Live back-fill draws them like any stored HR.
    public func r18HeartRates(from: Int64, to: Int64) async throws -> [HRPoint] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, hr FROM r18_second WHERE ts BETWEEN ? AND ? AND hr > 0 ORDER BY ts
                """, arguments: [from, to]).map { row in
                HRPoint(ts: row["ts"], bpm: row["hr"] as Double, source: .history)
            }
        }
    }

    /// Raw motion (R21) rows stored on the phone: seconds and the bytes of their packed sample columns.
    public func motionStorage() async throws -> (seconds: Int, bytes: Int64) {
        try syncRead { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, COALESCE(SUM(length(packed)), 0) AS b FROM motion_second
                """)
            return (row?["n"] ?? 0, row?["b"] ?? 0)
        }
    }
}
