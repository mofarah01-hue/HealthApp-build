import Foundation
import MGContext

// T9737 (2026-10-14): the compute coordinator's log was in memory only, so a run that iOS froze or killed left no trace
// ("Today is blank after the install" had no visible reason). Every run start, per-day start / end / result, abandon and
// "the previous process died mid-run" is appended to `MG/compute-log.txt` (one `epoch|kind|text` line each, the newest
// `ComputeLogUsage.keep` kept) and Settings › Usage › Compute log shows them. The line format and the section are the
// pure `MGContext.ComputeLogUsage`; this is the file.

final class ComputeLog: @unchecked Sendable {
    static let shared = ComputeLog(url: ComputeLog.defaultURL)

    private let url: URL?
    private let lock = NSLock()
    private var cache: [String]?

    static var defaultURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("MG", isDirectory: true).appendingPathComponent("compute-log.txt")
    }

    init(url: URL?) { self.url = url }

    private func loadLocked() -> [String] {
        if let cache { return cache }
        var out: [String] = []
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
            out = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        cache = out
        return out
    }

    func append(_ kind: ComputeLogUsage.Kind, _ text: String, at: Date) {
        lock.lock()
        defer { lock.unlock() }
        let lines = ComputeLogUsage.appending(ComputeLogUsage.line(at: at, kind: kind, text: text), to: loadLocked())
        cache = lines
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    /// At launch: if the last run in the file never ended, the process died inside it (killed or frozen by iOS).
    /// Writes that fact and returns it so the coordinator can run the days again.
    @discardableResult
    func noteLaunch(build: String, at: Date) -> ComputeLogUsage.Entry? {
        let open = ComputeLogUsage.unfinishedRun(lines())
        if let open {
            let since = MGFormat.time(open.at, calendar: .current)
            append(.processDied, "the run started at \(since) (\(open.text)) never ended: the app was closed or frozen "
                   + "by iOS before it finished", at: at)
        }
        append(.launch, "build \(build)", at: at)
        return open
    }
}

/// V3 (2026-10-15): milliseconds since the process reached `MGApp.init`, for the compute-log launch lines.
/// R7 / T23: it also keeps the first time each launch milestone was reached (the first frame drawn, Today built from
/// stored values, the first live beat, the launch compute done) and writes one summary line with all of them, so the
/// same line can be compared build to build on the phone.
enum LaunchTimer {
    enum Milestone: Int, CaseIterable {
        case firstFrame       // the window showed its first view (the saved front page, or the loading block)
        case dbOpen           // R8o: the database is open and migrated (opened off the main thread)
        case servicesReady    // R8o: the service graph and the model exist
        case todayBuilt       // Today built from stored values
        case firstLive        // the first live heartbeat from the strap
        case computeDone      // the launch compute (today) finished
        var label: String {
            switch self {
            case .firstFrame: return "first frame"
            case .dbOpen: return "database open"
            case .servicesReady: return "services ready"
            case .todayBuilt: return "Today built"
            case .firstLive: return "first live data"
            case .computeDone: return "compute done"
            }
        }
    }

    private final class Marks: @unchecked Sendable {
        let lock = NSLock()
        var ms: [Int: Int] = [:]
    }

    private static let t0 = ProcessInfo.processInfo.systemUptime
    private static let marks = Marks()
    static func mark() { _ = t0 }
    static func sinceLaunch() -> Int { Int((ProcessInfo.processInfo.systemUptime - t0) * 1000) }

    /// Records `m` the first time only; returns the milliseconds when this call was the first, else nil.
    @discardableResult
    static func reached(_ m: Milestone) -> Int? {
        let now = sinceLaunch()
        marks.lock.lock()
        defer { marks.lock.unlock() }
        guard marks.ms[m.rawValue] == nil else { return nil }
        marks.ms[m.rawValue] = now
        return now
    }

    /// R8o: the milliseconds a milestone was reached at, nil if not yet.
    static func ms(_ m: Milestone) -> Int? {
        marks.lock.lock()
        defer { marks.lock.unlock() }
        return marks.ms[m.rawValue]
    }

    /// "first frame 180 ms · Today built 640 ms · first live data not yet · compute done 2300 ms (after launch)".
    static func summary() -> String {
        marks.lock.lock()
        defer { marks.lock.unlock() }
        let parts = Milestone.allCases.map { m in
            marks.ms[m.rawValue].map { "\(m.label) \($0) ms" } ?? "\(m.label) not yet"
        }
        return parts.joined(separator: " · ") + " (after launch)"
    }
}
