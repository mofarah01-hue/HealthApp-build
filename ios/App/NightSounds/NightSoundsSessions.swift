import Foundation

// Listening sessions (WP-26): WHEN the microphone was listening, never what it heard. The Night "Sounds" lane needs
// this to tell "listened and heard nothing" from "wasn't listening" (UX 8.2: "Not listening last night - switch on in
// Tonight"); an event list alone cannot. Times only, in a small JSON file under Application Support. It is a local
// file, not a contract event and not part of any sync drop.
//
// WRITTEN, NOT COMPILED.

struct NightSoundsSession: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var start: Date
    /// nil while running, or if the app died: `lastAlive` stands in.
    var end: Date?
    var lastAlive: Date

    var effectiveEnd: Date { end ?? lastAlive }

    func overlaps(from: Date, to: Date) -> Bool { start < to && effectiveEnd > from }
}

protocol NightSoundsSessionLog: Sendable {
    func begin(at: Date) -> UUID
    func heartbeat(id: UUID, at: Date)
    func end(id: UUID, at: Date)
    func sessions(overlappingFrom from: Date, to: Date) -> [NightSoundsSession]
}

final class NightSoundsFileSessionLog: NightSoundsSessionLog, @unchecked Sendable {
    private let fileURL: URL
    private let keepLast: Int
    private let lock = NSLock()

    init(fileURL: URL, keepLast: Int = 120) {
        self.fileURL = fileURL
        self.keepLast = keepLast
    }

    /// Application Support/NightSounds/sessions.json.
    static func standard() -> NightSoundsFileSessionLog {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("NightSounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return NightSoundsFileSessionLog(fileURL: dir.appendingPathComponent("sessions.json"))
    }

    func begin(at: Date) -> UUID {
        let id = UUID()
        mutate { list in list.append(NightSoundsSession(id: id, start: at, end: nil, lastAlive: at)) }
        return id
    }

    func heartbeat(id: UUID, at: Date) {
        mutate { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            // Throttle: a write every 2 minutes is plenty for "when did it die".
            if at.timeIntervalSince(list[i].lastAlive) >= 120 { list[i].lastAlive = at }
        }
    }

    func end(id: UUID, at: Date) {
        mutate { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            list[i].end = at
            list[i].lastAlive = at
        }
    }

    func sessions(overlappingFrom from: Date, to: Date) -> [NightSoundsSession] {
        lock.lock()
        defer { lock.unlock() }
        return load().filter { $0.overlaps(from: from, to: to) }.sorted { $0.start < $1.start }
    }

    private func mutate(_ change: (inout [NightSoundsSession]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var list = load()
        let before = list
        change(&list)
        guard list != before else { return }
        if list.count > keepLast { list.removeFirst(list.count - keepLast) }
        save(list)
    }

    private func load() -> [NightSoundsSession] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([NightSoundsSession].self, from: data)) ?? []
    }

    private func save(_ list: [NightSoundsSession]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
