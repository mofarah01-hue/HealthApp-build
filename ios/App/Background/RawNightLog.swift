import Foundation
import MGContext
import os

// 0.5.8.1 "Raw night": the per-minute R20 / R21 tally and the strap link's down / up times (MGContext `RawNightCounter`),
// kept in a small JSON file in Application Support/MG (like BackgroundRunLog: it works while the store is busy). Written at
// most once a minute per stream, so a locked phone costs almost nothing; default file protection (until first unlock) so the
// writes go through while the phone is locked.

enum RawNightLog {
    private static let lock = NSLock()
    private static var cache: RawNightCounter?
    private static let log = Logger(subsystem: "mgapp", category: "raw-night")

    static var fileURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("MG", isDirectory: true).appendingPathComponent("raw-night.json")
    }

    static func noteR20(at: Date) { mutate { $0.noteR20(at: at) } }
    static func noteR21(at: Date) { mutate { $0.noteR21(at: at) } }
    static func noteLink(up: Bool, at: Date) { mutate { $0.noteLink(up: up, at: at) } }

    static func current() -> RawNightCounter {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    private static func mutate(_ change: (inout RawNightCounter) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        var c = loadLocked()
        guard change(&c) else { return }
        cache = c
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(c).write(to: url, options: .atomic)
        } catch {
            log.error("raw night log not written: \(String(describing: error), privacy: .public)")
        }
    }

    private static func loadLocked() -> RawNightCounter {
        if let cache { return cache }
        let c = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(RawNightCounter.self, from: $0) }
            ?? RawNightCounter()
        cache = c
        return c
    }
}
