import Foundation
import GRDB

/// One send from Settings › Command test (T87, 2026-10-13; table from migration "v7-command-test").
public struct CommandTestRow: Equatable, Sendable {
    public var id: Int64
    public var number: Int
    public var payloadHex: String
    public var sentAt: Date
    /// "worked", "nothing" or "red"; nil = not marked yet.
    public var mark: String?

    public init(id: Int64, number: Int, payloadHex: String, sentAt: Date, mark: String?) {
        self.id = id
        self.number = number
        self.payloadHex = payloadHex
        self.sentAt = sentAt
        self.mark = mark
    }
}

extension MGStore {
    /// `raw_frame.packet_type` of a mark note. Not a strap packet type: the bytes are ASCII text.
    public static let commandTestPacketType: UInt8 = 0xFE

    public func logCommandTest(number: Int, payloadHex: String, at: Date) async throws -> Int64 {
        try syncWrite { db in
            try db.execute(sql: "INSERT INTO command_test (number, payload_hex, sent_at) VALUES (?, ?, ?)",
                           arguments: [number, payloadHex, at.timeIntervalSince1970])
            return db.lastInsertedRowID
        }
    }

    /// Stores the mark with the send and writes it to `raw_frame` (pinned, `keep = 1`) as the ASCII line
    /// `cmdtest id=<id> cmd=<n> payload=<hex> sent=<unix s> mark=<mark>` received at `at`, so the next raw drop carries it.
    public func markCommandTest(id: Int64, mark: String, strapId: String, at: Date) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE command_test SET mark = ? WHERE id = ?", arguments: [mark, id])
            guard let row = try Row.fetchOne(db, sql: "SELECT number, payload_hex, sent_at FROM command_test WHERE id = ?",
                                             arguments: [id]) else { return }
            let number: Int = row["number"], hex: String = row["payload_hex"], sent: Double = row["sent_at"]
            let note = Data("cmdtest id=\(id) cmd=\(number) payload=\(hex) sent=\(Int64(sent)) mark=\(mark)".utf8)
            try db.execute(sql: """
                INSERT INTO raw_frame (strap_id, received_at, packet_type, crc32, bytes, keep, chunk_id)
                VALUES (?, ?, ?, ?, ?, 1, NULL)
                ON CONFLICT(strap_id, received_at, packet_type, crc32) DO NOTHING
                """, arguments: [strapId, at.timeIntervalSince1970, Self.commandTestPacketType,
                                 Int64(CRC32.checksum(note)), note])
        }
    }

    /// P9726 (Raw optical (PPG) section): what Mo saw during the send `id`, written to `raw_frame` (pinned) as the ASCII line
    /// `cmdtest id=<id> cmd=<n> payload=<hex> sent=<unix s> observed=<line>`. The send's mark is not touched; each
    /// observation is its own line, so the PC gets them all in the next raw drop.
    public func observeCommandTest(id: Int64, line: String, strapId: String, at: Date) async throws {
        try syncWrite { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT number, payload_hex, sent_at FROM command_test WHERE id = ?",
                                             arguments: [id]) else { return }
            let number: Int = row["number"], hex: String = row["payload_hex"], sent: Double = row["sent_at"]
            let note = Data("cmdtest id=\(id) cmd=\(number) payload=\(hex) sent=\(Int64(sent)) observed=\(line)".utf8)
            try db.execute(sql: """
                INSERT INTO raw_frame (strap_id, received_at, packet_type, crc32, bytes, keep, chunk_id)
                VALUES (?, ?, ?, ?, ?, 1, NULL)
                ON CONFLICT(strap_id, received_at, packet_type, crc32) DO NOTHING
                """, arguments: [strapId, at.timeIntervalSince1970, Self.commandTestPacketType,
                                 Int64(CRC32.checksum(note)), note])
        }
    }

    /// The saved observation lines, newest first: (command_test id, the text after `observed=`).
    public func commandTestObservations(limit: Int) async throws -> [(id: Int64, line: String)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT bytes FROM raw_frame WHERE packet_type = ? ORDER BY received_at DESC LIMIT ?
                """, arguments: [Self.commandTestPacketType, limit * 4]).compactMap { row -> (id: Int64, line: String)? in
                let data: Data = row["bytes"]
                guard let text = String(data: data, encoding: .utf8), text.hasPrefix("cmdtest id="),
                      let obs = text.range(of: " observed=") else { return nil }
                let idText = text.dropFirst("cmdtest id=".count).prefix { $0.isNumber }
                guard let id = Int64(idText) else { return nil }
                return (id, String(text[obs.upperBound...]))
            }.prefix(limit).map { $0 }
        }
    }

    /// Newest first.
    public func commandTests(limit: Int) async throws -> [CommandTestRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT id, number, payload_hex, sent_at, mark FROM command_test ORDER BY id DESC LIMIT ?",
                             arguments: [limit]).map {
                CommandTestRow(id: $0["id"], number: $0["number"], payloadHex: $0["payload_hex"],
                               sentAt: Date(timeIntervalSince1970: $0["sent_at"]), mark: $0["mark"])
            }
        }
    }
}
