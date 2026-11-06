import Foundation

// r9u (2026-10-17, CRITICAL for 0.6.0): the upload queue of the automatic Apple Health read lives in its own store, one row per
// POST body, NOT inside the saved-state JSON. On Mo's phone that JSON had grown to 288 MB (753 bodies) and was decoded and
// re-encoded on every change, which ate the run's time limit, held about 1.2 GB of memory and kept Apple Health off the PC
// since Oct 15. Now a save is O(one batch): the state keeps anchors and statistics only.

/// One POST body waiting for the PC. `body` is the plain JSON (the store may keep it deflated).
public struct HealthQueuedBatch: Equatable, Sendable {
    public var id: UUID
    /// `HealthAutoPayload.contentKey(body)`; nil for a batch moved over from a state saved before T9988.
    public var key: String?
    public var body: Data
    public var sampleCount: Int
    public var createdAt: Date
    public var attempts: Int
    public var lastError: String?

    public init(id: UUID = UUID(), key: String?, body: Data, sampleCount: Int, createdAt: Date, attempts: Int = 0,
                lastError: String? = nil) {
        self.id = id; self.key = key; self.body = body; self.sampleCount = sampleCount; self.createdAt = createdAt
        self.attempts = attempts; self.lastError = lastError
    }
}

/// What is waiting, without loading any body.
public struct HealthQueueStats: Equatable, Sendable {
    public var batches: Int
    public var samples: Int
    /// Plain (undeflated) JSON bytes of all waiting bodies: what one pass of uploads will have to send.
    public var bytes: Int

    public init(batches: Int = 0, samples: Int = 0, bytes: Int = 0) {
        self.batches = batches; self.samples = samples; self.bytes = bytes
    }

    /// "3 batches, 1.2 MB, 4500 samples" for the compute log and the status post.
    public var text: String {
        let mb = Double(bytes) / 1_048_576
        return "\(batches) batch\(batches == 1 ? "" : "es"), " + String(format: "%.1f", mb) + " MB, \(samples) sample\(samples == 1 ? "" : "s")"
    }
}

/// Where queued POST bodies are kept. Every call touches one batch or a small page; nothing ever loads the whole queue.
public protocol HealthAutoQueue: Sendable {
    /// Adds batches at the end. Idempotent by `id`; a batch whose `key` is already queued is skipped (same samples).
    func append(_ items: [HealthQueuedBatch]) async throws
    /// The OLDEST `limit` batches, oldest first (Mo, Nov 5: "the backlog is always sent before live data"; this was newest first
    /// from T10033, Oct 23, until the queue got a cap that bounds the backlog).
    func peek(limit: Int) async throws -> [HealthQueuedBatch]
    /// Deletes a batch. Called only after the PC confirmed it (or refused it for good and the refusal was saved).
    func remove(id: UUID) async throws
    func markError(id: UUID, error: String) async throws
    func stats() async throws -> HealthQueueStats
}

/// In memory: tests, and the fallback when no store is given.
public actor MemoryHealthAutoQueue: HealthAutoQueue {
    private var rows: [HealthQueuedBatch] = []
    /// Largest number of bodies one `peek` returned; a test asserts the engine never asks for the whole queue.
    public private(set) var largestPeek = 0
    public private(set) var failAppend = false

    public init() {}

    public func setFailAppend(_ v: Bool) { failAppend = v }

    public func append(_ items: [HealthQueuedBatch]) async throws {
        if failAppend { throw MemoryQueueFailure() }
        for it in items {
            if rows.contains(where: { $0.id == it.id }) { continue }
            if let k = it.key, rows.contains(where: { $0.key == k }) { continue }
            rows.append(it)
        }
    }

    public func peek(limit: Int) async throws -> [HealthQueuedBatch] {
        let out = Array(rows.prefix(max(0, limit)))                // oldest first (Nov 5)
        largestPeek = max(largestPeek, out.count)
        return out
    }

    public func remove(id: UUID) async throws { rows.removeAll { $0.id == id } }

    public func markError(id: UUID, error: String) async throws {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].attempts += 1
        rows[i].lastError = error
    }

    public func stats() async throws -> HealthQueueStats {
        HealthQueueStats(batches: rows.count, samples: rows.reduce(0) { $0 + $1.sampleCount },
                         bytes: rows.reduce(0) { $0 + $1.body.count })
    }
}

public struct MemoryQueueFailure: Error {}
