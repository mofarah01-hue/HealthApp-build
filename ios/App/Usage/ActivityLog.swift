import Foundation
import MGContext

// B-6 (Oct 14 2026): Settings › Usage › "What's running today". The tally itself is MGContext.ActivityTally (pure,
// tested); this keeps today's one in a tiny JSON next to background-runs.json (not the database: it must work while
// the store is busy). Hooks only call `record` / `setOn` at places that already run; nothing here starts work.
enum ActivityLog {
    private static let lock = NSLock()
    private static var cache: ActivityTally?
    private static var launched = false

    private static var fileURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("MG", isDirectory: true).appendingPathComponent("activity-today.json")
    }

    private static func loadLocked() -> ActivityTally {
        if let cache { return cache }
        var t = ActivityTally()
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ActivityTally.self, from: data) { t = decoded }
        if !launched { launched = true; t.dropOpenIntervals() }     // an interval open at the last kill has no known end
        cache = t
        return t
    }

    private static func mutate(_ change: (inout ActivityTally) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var t = loadLocked()
        change(&t)
        cache = t
        guard let url = fileURL, let data = try? JSONEncoder().encode(t) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func record(_ kind: ActivityTally.Kind, duration: Double, now: Date = Date(), calendar: Calendar = .current) {
        mutate { $0.record(kind, duration: duration, now: now, calendar: calendar) }
    }

    static func setOn(_ kind: ActivityTally.Kind, _ on: Bool, now: Date = Date(), calendar: Calendar = .current) {
        mutate { $0.setOn(kind, on, now: now, calendar: calendar) }
    }

    static func today() -> ActivityTally {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }
}
