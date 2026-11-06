import Foundation
import GRDB

// 0.6.0.12 — the WHOOP 4.0 LED settings reads (GET 40 / 42 / 44) are kept as one ASCII line each in `raw_frame` (pinned, `keep = 1`),
// like the Command test marks (CommandTestLog.swift), so the next raw drop carries them to the PC and a relaunch can still show
// them. The line format is `Whoop4LedRead.line` (MGBLE): `ledread cmd=40 at=<unix s> worn=1 result=SUCCESS reply=<hex>`.
//
// WRITTEN, NOT COMPILED here (MGStore needs GRDB, which the Linux harness does not build).

extension MGStore {
    /// `raw_frame.packet_type` of a LED read note (same value as MGBLE `Whoop4LedRead.notePacketType`). Not a strap packet type.
    public static let ledReadPacketType: UInt8 = 0xFD

    public func logLedRead(line: String, strapId: String, at: Date) async throws {
        let note = Data(line.utf8)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO raw_frame (strap_id, received_at, packet_type, crc32, bytes, keep, chunk_id)
                VALUES (?, ?, ?, ?, ?, 1, NULL)
                ON CONFLICT(strap_id, received_at, packet_type, crc32) DO NOTHING
                """, arguments: [strapId, at.timeIntervalSince1970, Self.ledReadPacketType,
                                 Int64(CRC32.checksum(note)), note])
        }
    }

    /// The saved read lines, newest first.
    public func recentLedReadLines(limit: Int) async throws -> [String] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT bytes FROM raw_frame WHERE packet_type = ? ORDER BY received_at DESC, id DESC LIMIT ?",
                             arguments: [Self.ledReadPacketType, max(1, min(limit, 500))]).compactMap { row -> String? in
                let data: Data = row["bytes"]
                return String(data: data, encoding: .utf8)
            }
        }
    }
}
