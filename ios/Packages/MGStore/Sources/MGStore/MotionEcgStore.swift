import Foundation
import GRDB
import MGDomain

/// Raw motion seconds and ECG traces (wave W8, 2026-10-11 19:50 PT; tables from migration "v6-w8-motion-ecg").
/// The raw frames of both streams are in `raw_frame` like every other frame and go to the PC in raw drops; an `ecg` event
/// pins its frames (RawRetention: at − 2 min … end + 2 min).
extension MGStore {
    /// Raw-motion seconds with strap ts in [from, to], oldest first (one strap: the first stored copy of each second).
    public func motionSeconds(from: Int64, to: Int64, strapId: StrapID? = nil) async throws -> [MotionSecond] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, fraction, accel_n, gyro_n, source, packed FROM motion_second
                WHERE ts BETWEEN ? AND ? AND (? IS NULL OR strap_id = ?)
                ORDER BY ts, strap_id
                """, arguments: [from, to, strapId?.raw, strapId?.raw]).map { row in
                MotionSecond(ts: row["ts"], fraction: row["fraction"], accelCount: row["accel_n"],
                             gyroCount: row["gyro_n"], source: row["source"], packed: row["packed"])
            }
        }
    }

    /// The per-second accelerometer summaries in [from, to] (the stored `acc_*` columns; no sample decoding), oldest first.
    public func motionSummaries(from: Int64, to: Int64, strapId: StrapID? = nil) async throws -> [MotionAccelSummary] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, accel_n, acc_mean, acc_sd, enmo_lsb FROM motion_second
                WHERE ts BETWEEN ? AND ? AND (? IS NULL OR strap_id = ?) AND acc_mean IS NOT NULL
                ORDER BY ts, strap_id
                """, arguments: [from, to, strapId?.raw, strapId?.raw]).map { row in
                MotionAccelSummary(ts: row["ts"], n: row["accel_n"], meanMagLSB: row["acc_mean"], sdMagLSB: row["acc_sd"],
                                   enmoLSB: row["enmo_lsb"])
            }
        }
    }

    /// How many raw-motion seconds are stored in [from, to] (Settings › Usage, the Live line).
    public func motionSecondCount(from: Int64, to: Int64) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM motion_second WHERE ts BETWEEN ? AND ?",
                             arguments: [from, to]) ?? 0
        }
    }

    /// Stores a reading's samples once. A second save under the same event id changes nothing (never overwritten).
    @discardableResult
    public func saveEcgTrace(_ trace: EcgTrace, startedAt: Date) async throws -> Bool {
        let packets = try JSONEncoder().encode(trace.packets)
        return try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO ecg_trace (event_id, strap_id, started_at, samples, packets) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(event_id) DO NOTHING
                """, arguments: [trace.eventId.uuidString, trace.strapId?.raw, startedAt.timeIntervalSince1970,
                                 trace.sampleBytes, packets])
            return db.changesCount > 0
        }
    }

    public func ecgTrace(eventId: UUID) async throws -> EcgTrace? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT strap_id, samples, packets FROM ecg_trace WHERE event_id = ?
                """, arguments: [eventId.uuidString]) else { return nil }
            let bytes: Data = row["samples"]
            let packetsJSON: Data = row["packets"]
            let strap: String? = row["strap_id"]
            guard let samples = EcgTrace.samples(from: bytes),
                  let packets = try? JSONDecoder().decode([EcgTracePacket].self, from: packetsJSON) else { return nil }
            return EcgTrace(eventId: eventId, strapId: strap.map { StrapID(raw: $0) }, samples: samples,
                            packets: packets)
        }
    }
}
