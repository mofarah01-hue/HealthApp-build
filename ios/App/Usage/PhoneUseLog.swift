import Foundation
import MGContext
import UIKit

// T9818: phone-use log. Records iOS's protected-data notifications (unlocked = data available, locked = data about to
// become unavailable) plus lifecycle marks in a small JSON next to activity-today.json (not the database: it must work
// while the store is busy). Only runs while our process is alive. No Screen Time entitlement, no extension.
// Design (Codex review of round 5):
//  - an ACTOR owns the log; every observer yields into one AsyncStream (yield is synchronous, so the order the
//    notifications arrived in is the order they are applied) and a single task drains it;
//  - the log is never edited to "fix" it: a launch mark, suspended marks and `observed` readings are appended, and
//    MGContext.PhoneUseSessions replays the whole thing (duplicates / out-of-order cannot keep a session open;
//    a session the app cannot vouch for becomes a gap, not minutes);
//  - each finished session is upserted as a `screen_time` event (kind use, route lock_unlock) with a stable id, in
//    start order, awaited, retried; a failure stops the pass and the next flush resumes (nothing is dropped silently);
//  - retention: the local log keeps `keepDays` (compacted, never cutting an open run). The event database is never
//    hard-deleted by this feature (store rule: removals are soft); per-session rows are small and written once.
actor PhoneUseLog {
    static let shared = PhoneUseLog()

    /// Lock-protected copy of the log for the synchronous Usage page (`built(calendar:)`).
    final class Snapshot: @unchecked Sendable {
        private let l = NSLock()
        private var t: [PhoneUseSessions.Transition] = []
        func set(_ x: [PhoneUseSessions.Transition]) { l.lock(); t = x; l.unlock() }
        func get() -> [PhoneUseSessions.Transition] { l.lock(); defer { l.unlock() }; return t }
    }
    nonisolated let snapshot = Snapshot()

    enum Input: Sendable {
        case transition(PhoneUseSessions.Transition)
        case flush
    }

    private var transitions: [PhoneUseSessions.Transition] = []
    private var loaded = false
    private var started = false
    private var sink: (@Sendable (PhoneUseSessions.Session) async throws -> Void)?
    private var delivered: [UUID: Date] = [:]            // session id -> end that was written (this process)
    private var calendar = Calendar.current
    private var continuation: AsyncStream<Input>.Continuation?
    private static let keepDays = 14.0
    private static let retries = 3

    private var fileURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("MG", isDirectory: true).appendingPathComponent("phone-use.json")
    }

    /// Synchronous, for the Usage page.
    nonisolated func built(calendar: Calendar) -> PhoneUseSessions.Built {
        PhoneUseSessions.build(snapshot.get(), calendar: calendar)
    }

    /// Once, at app start. `sink` writes one session as an event (throws on a store failure).
    @MainActor static func start(calendar: Calendar, now: Date = Date(),
                          sink: @escaping @Sendable (PhoneUseSessions.Session) async throws -> Void) {
        guard !Watch.started else { return }
        Watch.started = true
        let (stream, cont) = AsyncStream<Input>.makeStream(bufferingPolicy: .unbounded)
        let nc = NotificationCenter.default
        func add(_ name: Notification.Name, _ make: @escaping @Sendable (Date) -> PhoneUseSessions.Transition) {
            Watch.tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                cont.yield(.transition(make(Date())))        // time stamped on arrival, order kept by the stream
            })
        }
        add(UIApplication.protectedDataDidBecomeAvailableNotification) { .init(at: $0, unlocked: true) }
        add(UIApplication.protectedDataWillBecomeUnavailableNotification) { .init(at: $0, unlocked: false) }
        // No mark for didEnterBackground: the app keeps running in the background (Bluetooth) and phone use outside it
        // must count. Suspension shows as a hole in the heartbeats below (MGContext.PhoneUseSessions.heartbeatGap).
        // read on the main queue the observer runs on (the closure itself is not main-actor typed)
        add(UIApplication.willEnterForegroundNotification) { at in
            .observed(at, unlocked: MainActor.assumeIsolated { UIApplication.shared.isProtectedDataAvailable })
        }
        // Launch: a mark closes (as a gap) whatever the last process left open, then the real state is read.
        cont.yield(.transition(.launch(now)))
        cont.yield(.transition(.observed(now, unlocked: UIApplication.shared.isProtectedDataAvailable)))
        cont.yield(.flush)
        Watch.timer = Timer.scheduledTimer(withTimeInterval: PhoneUseSessions.heartbeatEvery, repeats: true) { _ in
            cont.yield(.transition(.heartbeat(Date(), unlocked: MainActor.assumeIsolated { UIApplication.shared.isProtectedDataAvailable })))
        }
        Task { await shared.run(stream: stream, continuation: cont, calendar: calendar, sink: sink) }
    }

    @MainActor private enum Watch {
        static var started = false
        static var tokens: [NSObjectProtocol] = []
        static var timer: Timer?
    }

    private func run(stream: AsyncStream<Input>, continuation: AsyncStream<Input>.Continuation,
                     calendar: Calendar, sink: @escaping @Sendable (PhoneUseSessions.Session) async throws -> Void) async {
        guard !started else { return }
        started = true
        self.sink = sink
        self.calendar = calendar
        self.continuation = continuation
        load()
        loadDelivered()
        for await input in stream {
            switch input {
            case .transition(let t):
                if t.mark == .heartbeat { transitions = PhoneUseSessions.appendHeartbeat(transitions, t) } else { transitions.append(t) }
                save(now: t.at)
                // A lock, or any lifecycle change, can finish a session: send what is ready.
                if t.mark != nil || !t.unlocked { await flush() }
            case .flush:
                await flush()
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let t = try? JSONDecoder().decode([PhoneUseSessions.Transition].self, from: data) { transitions = t }
        snapshot.set(transitions)
    }

    // The delivered set survives a restart, so a resync does not rewrite every session (rows are upserts by id, so
    // this only saves work). Pruned to sessions still in the log.
    private var deliveredURL: URL? { fileURL?.deletingLastPathComponent().appendingPathComponent("phone-use-delivered.json") }

    private func loadDelivered() {
        guard let url = deliveredURL, let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        for (k, v) in m { if let id = UUID(uuidString: k) { delivered[id] = v } }
    }

    private func saveDelivered(keeping ids: Set<UUID>) {
        delivered = delivered.filter { ids.contains($0.key) }
        guard let url = deliveredURL,
              let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: delivered.map { ($0.key.uuidString, $0.value) })) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func save(now: Date) {
        transitions = PhoneUseSessions.compact(transitions, before: now.addingTimeInterval(-Self.keepDays * 86_400))
        snapshot.set(transitions)
        guard let url = fileURL, let data = try? JSONEncoder().encode(transitions) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Finished sessions, in start order, each awaited and retried; stops at the first one that still fails (the next
    /// flush starts there again). Same id + same end already written in this process: skipped.
    private func flush() async {
        guard let sink else { return }
        let built = PhoneUseSessions.build(transitions, calendar: calendar)
        for s in built.sessions.sorted(by: { $0.start < $1.start }) {
            let id = PhoneUseSessions.event(s).id
            if delivered[id] == s.end { continue }
            var ok = false
            for attempt in 0..<Self.retries {
                do { try await sink(s); ok = true; break } catch {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
                }
            }
            guard ok else { return }
            delivered[id] = s.end
            saveDelivered(keeping: Set(built.sessions.map { PhoneUseSessions.event($0).id }))
        }
    }
}
