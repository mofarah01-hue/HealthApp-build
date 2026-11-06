import Foundation
import MGContext
import os

// Settings › Usage (tracker #40, 2026-10-11): a small log of every background-task run — when it started and ended,
// how it ended (finished, or iOS took the time back), what the job said, and the CPU it used. iOS keeps no history of
// BGTaskScheduler runs an app can read, so without this the page could not say whether background work runs at all.
//
// A JSON file in Application Support/MG (not the database: it must work while the store is busy or failed to open),
// written at start and at end, so a run the app did not survive shows as "did not finish". Last 14 days, 400 runs.

enum BackgroundRunLog {
    private struct Entry: Codable {
        var id: UUID
        var record: BackgroundRunRecord
        var cpuAtStart: Double?
    }

    static let keepDays: TimeInterval = 14 * 86_400
    static let maxEntries = 400

    private static let lock = NSLock()
    private static var cache: [Entry]?
    private static let log = Logger(subsystem: "mgapp", category: "background-runs")

    static var fileURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("MG", isDirectory: true).appendingPathComponent("background-runs.json")
    }

    /// A run starts; returns its id for `end`.
    static func begin(_ role: BackgroundTaskRole, at: Date = Date()) -> UUID {
        let id = UUID()
        let cpu = ProcessUsage.cpuSeconds()
        mutate { entries in
            entries.append(Entry(id: id, record: BackgroundRunRecord(role: role.rawValue, start: at), cpuAtStart: cpu))
        }
        return id
    }

    /// The run ended: "finished", or "expired" when iOS took the time back.
    static func end(_ id: UUID, outcome: String, at: Date = Date()) {
        let cpu = ProcessUsage.cpuSeconds()
        mutate { entries in
            guard let i = entries.lastIndex(where: { $0.id == id }), entries[i].record.end == nil else { return }
            entries[i].record.end = at
            entries[i].record.outcome = outcome
            if let start = entries[i].cpuAtStart, let cpu {
                entries[i].record.cpuSeconds = max(0, cpu - start)
            }
        }
    }

    /// What the job said, on the newest unfinished run of `role` ("skipped: Raw strap frames are waiting: Low Data
    /// Mode is on…").
    static func note(_ role: BackgroundTaskRole, _ text: String) {
        mutate { entries in
            guard let i = entries.lastIndex(where: { $0.record.role == role.rawValue && $0.record.end == nil })
            else { return }
            entries[i].record.note = text
        }
    }

    static func all() -> [BackgroundRunRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().map(\.record)
    }

    private static func mutate(_ change: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        change(&entries)
        let cutoff = Date().addingTimeInterval(-keepDays)
        entries.removeAll { $0.record.start < cutoff }
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        cache = entries
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            log.error("background run log not written: \(String(describing: error), privacy: .public)")
        }
    }

    private static func loadLocked() -> [Entry] {
        if let cache { return cache }
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            cache = []
            return []
        }
        cache = entries
        return entries
    }
}
