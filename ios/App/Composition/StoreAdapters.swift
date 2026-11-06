import Foundation
import MGDomain
import MGHealth
import MGStore
import MGSync

// WP-23a — MGStore behind the other packages' ports (BRIEF WP-14 row: "MGStore conforms via empty extensions in WP-23's
// composition"; SyncLedgerStore / MirrorStateStore as closures over MGStore kv; adapters for HealthMirrorSource and
// HealthEventRemoving), the NightSounds sink, and the one `.saveEvent` path every writer uses.
//
// WRITTEN, NOT COMPILED.

// MGSync ports: MGStore already has exactly these methods (StrapIngest.swift `primaryStrapId()`, RawRetention.swift
// `pendingRawRanges()` / `rawFramesFile(from:to:)`).
extension MGStore: StrapIDSource {}
extension MGStore: RawExportSource {}

/// The `.saveEvent` path (BRIEF WP-12/13/18 row): `loggedAt` = now when missing; a swallowing symptom with no `follows`
/// is linked to the latest food event before it; then stored (new id → revision 1, same id → the store bumps it).
/// SAMPLE mode is refused by the callers before this runs.
enum EventSaving {
    static func prepare(_ event: EventRecord, now: Date, store: MGStore) async throws -> EventRecord {
        var e = event
        if e.loggedAt == nil { e.loggedAt = now }
        if case .symptom(let s) = e.payload, s.kind == .swallowing, e.follows == nil {
            let meals = try await store.events(from: e.at.addingTimeInterval(-12 * 3600), to: e.at, types: [.food])
            e.follows = meals.last(where: { $0.at <= e.at })?.at
        }
        return e
    }

    @discardableResult
    static func save(_ event: EventRecord, now: Date, store: MGStore) async throws -> EventRecord {
        try await store.upsertEvent(try await prepare(event, now: now, store: store))
    }
}

/// Apple Health deletions → soft remove (UX §7: kept, flagged `removed`). An unknown id is not an error (MGHealth doc).
struct StoreHealthRemoval: HealthEventRemoving {
    let store: MGStore

    func markRemoved(ids: [UUID]) async throws {
        for id in ids {
            do {
                _ = try await store.removeEvent(id: id)
            } catch let e as MGStoreError {
                if case .unknownEvent = e { continue }
                throw e
            }
        }
    }
}

/// What the (opt-in, off by default, D12) Health mirror draws from. Only measured / directly derived values; the
/// mirror's own policy refuses research / estimate tiers (MGHealth `MirrorPolicy`).
struct StoreMirrorSource: HealthMirrorSource {
    let store: MGStore

    func heartRate(from: Date, to: Date) async throws -> [HeartRateReading] {
        try await store.hrSamples(from: Int64(from.timeIntervalSince1970), to: Int64(to.timeIntervalSince1970))
            .filter { $0.bpm > 0 }
            .map { HeartRateReading(at: Date(timeIntervalSince1970: TimeInterval($0.ts)), bpm: $0.bpm) }
    }

    func restingHeartRate(day: LocalDay) async throws -> MirrorDailyValue? {
        try await daily(MetricKey.rhr.rawValue, day: day)
    }

    func hrvSDNN(day: LocalDay) async throws -> MirrorDailyValue? {
        try await daily(MetricKey.hrvSdnn.rawValue, day: day)
    }

    func sleepWindow(day: LocalDay) async throws -> MirrorSleepWindow? {
        let ms = try await store.metrics(on: day)
        guard let onset = Self.primary(ms, MetricKey.sleepOnset.rawValue),
              let wake = Self.primary(ms, MetricKey.wakeTime.rawValue),
              let a = onset.value, let b = wake.value, b > a else { return nil }
        return MirrorSleepWindow(onset: Date(timeIntervalSince1970: a), wake: Date(timeIntervalSince1970: b),
                                 tier: wake.tier, method: wake.method)
    }

    func events(from: Date, to: Date, types: [EventType]) async throws -> [EventRecord] {
        try await store.events(from: from, to: to, types: types, includeRemoved: true)
    }

    private func daily(_ name: String, day: LocalDay) async throws -> MirrorDailyValue? {
        guard let m = Self.primary(try await store.metrics(on: day), name), let v = m.value else { return nil }
        return MirrorDailyValue(value: v, at: m.at, tier: m.tier, method: m.method)
    }

    private static func primary(_ ms: [Metric], _ name: String) -> Metric? {
        let named = ms.filter { $0.name == name && $0.value != nil }
        return named.first { $0.primary == true } ?? named.first
    }
}

/// Settings › Apple Health mirror (off by default; no Settings row offers it in B1).
struct MirrorSwitch: MirrorSettingsProviding {
    let live: ContextLiveBox
    var mirrorEnabled: Bool {
        get async {
            let l = await live.get()
            return l.settings.healthMirrorOn && !l.settings.sampleData
        }
    }
}

/// Night sounds → store (WP-26: "events → a sink over MGStore.upsertEvent, refusing in SAMPLE mode").
struct StoreNightSoundsSink: NightSoundsEventSink {
    let store: MGStore
    let live: ContextLiveBox

    struct SampleRefused: Error, CustomStringConvertible {
        var description: String { "Sample data is on, so night sounds are not saved" }
    }

    func record(_ event: EventRecord) async throws {
        if await live.sampleData { throw SampleRefused() }
        try await store.upsertEvent(event)
    }
}

/// Closures over MGStore's key-value table for MGSync's ledger and MGHealth's mirror state (BRIEF WP-14 row).
enum StoreKV {
    static func syncLedger(_ store: MGStore) -> ClosureSyncLedgerStore {
        ClosureSyncLedgerStore(read: { try? await store.value(forKey: AppSettingsStore.syncLedgerKey) },
                               write: { try await store.setValue($0, forKey: AppSettingsStore.syncLedgerKey) })
    }

    /// r9u: the first load moves the old queue (inside this document, 288 MB on Mo's phone) into the `health_queue` table
    /// (MGStore.migrateHealthQueueFromKV, streamed, off the main thread: the engine is an actor and this runs inside its load).
    /// If the move fails the document is left as it is and the engine is handed bytes it cannot decode, so it reads and saves
    /// nothing (it never overwrites the document, which still holds the queue); the next launch tries again.
    static func healthAuto(_ store: MGStore) -> ClosureHealthAutoStorage {
        ClosureHealthAutoStorage(read: {
            do {
                let m = try await store.migrateHealthQueueFromKV(key: AppSettingsStore.healthAutoKey)
                if m.found > 0 {
                    ComputeLog.shared.append(.note, "apple health queue: moved \(m.inTable) of \(m.found) batches from the saved state "
                                             + "into their own table; the state went from \(m.valueBytesBefore / 1_048_576) MB to "
                                             + "\(m.valueBytesAfter / 1024) KB", at: Date())
                }
            } catch {
                ComputeLog.shared.append(.note, "apple health queue: the move out of the saved state FAILED (\(error)); nothing was "
                                         + "changed, Apple Health is paused until it works", at: Date())
                return Data("health queue migration failed: \(error)".utf8)
            }
            return try? await store.value(forKey: AppSettingsStore.healthAutoKey)
        }, write: { try await store.setValue($0, forKey: AppSettingsStore.healthAutoKey) })
    }

    /// r9u: the Health upload queue (MGHealth's port) over MGStore's `health_queue` table.
    static func healthQueue(_ store: MGStore) -> StoreHealthQueue { StoreHealthQueue(store: store) }

    static func mirrorState(_ store: MGStore) -> ClosureMirrorStateStore {
        ClosureMirrorStateStore(read: { try? await store.value(forKey: AppSettingsStore.mirrorStateKey) },
                                write: { try await store.setValue($0, forKey: AppSettingsStore.mirrorStateKey) })
    }
}

/// r9u: MGHealth's queue port over MGStore.
struct StoreHealthQueue: HealthAutoQueue {
    let store: MGStore

    func append(_ items: [HealthQueuedBatch]) async throws {
        try await store.healthQueueAppend(items.map {
            HealthQueueRow(id: $0.id, key: $0.key, createdAt: $0.createdAt, attempts: $0.attempts, lastError: $0.lastError,
                           sampleCount: $0.sampleCount, body: $0.body)
        })
    }

    func peek(limit: Int) async throws -> [HealthQueuedBatch] {
        try await store.healthQueuePeek(limit: limit, oldestFirst: true).map {     // Nov 5: backlog before live data
            HealthQueuedBatch(id: $0.id, key: $0.key, body: $0.body, sampleCount: $0.sampleCount, createdAt: $0.createdAt,
                              attempts: $0.attempts, lastError: $0.lastError)
        }
    }

    func remove(id: UUID) async throws { try await store.healthQueueRemove(id: id) }
    func markError(id: UUID, error: String) async throws { try await store.healthQueueMarkError(id: id, error: error) }

    func stats() async throws -> HealthQueueStats {
        let c = try await store.healthQueueCounts()
        return HealthQueueStats(batches: c.batches, samples: c.samples, bytes: c.bytes)
    }
}
