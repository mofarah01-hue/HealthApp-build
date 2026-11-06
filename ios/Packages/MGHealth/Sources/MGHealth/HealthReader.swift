import Foundation
import MGDomain

/// What the HealthKit layer provides to the reader (the real one: `HealthKitProvider`; tests: a stub).
public struct HealthChangeBatch: Sendable {
    public var records: [HealthSampleRecord]
    /// uuids of Health objects deleted since the anchor.
    public var deleted: [UUID]
    /// The anchor to store once `records` are safely in the store. Nil = the provider has none to give.
    public var newAnchor: Data?

    public init(records: [HealthSampleRecord] = [], deleted: [UUID] = [], newAnchor: Data? = nil) {
        self.records = records
        self.deleted = deleted
        self.newAnchor = newAnchor
    }
}

public protocol HealthDataProvider: Sendable {
    var authState: HealthAuthState { get async }

    /// Shows the Health permission sheet for every `HealthReadType` (read only; the mirror asks for write access
    /// separately, only when it is switched on).
    func requestReadAuthorization() async throws

    /// Samples of `type` added or changed since `anchor` (nil = first run: only samples starting at or after `since`).
    /// - The provider must already have excluded this build's own source in the query (see `OwnSourceRule`).
    /// - For the hourly-summarised types (`HealthReadType.granularity != .perSample`) it returns, for every hour the
    ///   changes touch, ALL samples of that hour, so the mapper can recompute the whole hour (an anchored query alone
    ///   would return only the new samples and the hour's event would be overwritten with a partial summary).
    func changes(for type: HealthReadType, anchor: Data?, since: Date) async throws -> HealthChangeBatch
}

/// Soft-removes events whose Health object was deleted (the event is kept and flagged `removed`, UX §7). MGStore has
/// `removeEvent(id:)`; the app adapts it (an unknown id is not an error). Optional: without it deletions in Health are
/// counted in the report and the events stay.
public protocol HealthEventRemoving: Sendable {
    func markRemoved(ids: [UUID]) async throws
}

public struct HealthSyncReport: Sendable, Equatable {
    public var state: HealthAuthState
    /// The sentence to show instead of Health values when `state` is not usable (R6).
    public var message: String?
    /// Events handed to the store.
    public var ingested = 0
    public var perType: [String: Int] = [:]
    /// Samples dropped by the own-source rule after the query (normally 0: the query already excludes them).
    public var skippedOwnSource = 0
    public var skippedInvalid = 0
    public var deletedSeen = 0
    public var deletedRemoved = 0
    /// One line per type that failed; its anchor was not advanced, so the next run retries it.
    public var errors: [String] = []

    public init(state: HealthAuthState, message: String? = nil) {
        self.state = state
        self.message = message
    }
}

/// Reads Apple Health into the store (ARCHITECTURE.md 4.10). One pass per type: read the stored anchor, ask the provider
/// for changes, drop this app's own samples, map to events, `ingest`, and only then store the new anchor — so a failed
/// ingest leaves the anchor where it was and the same samples come again next time (ingest is idempotent per event id).
public actor HealthReader {
    private let provider: any HealthDataProvider
    private let sink: any HealthSampleSink
    private let removal: (any HealthEventRemoving)?
    private let own: OwnSourceRule
    private let clock: any MGDomain.Clock
    private let types: [HealthReadType]
    private let firstRunLookbackDays: Int
    private let mapper = HealthEventMapper()

    public init(provider: any HealthDataProvider, sink: any HealthSampleSink, removal: (any HealthEventRemoving)? = nil,
                own: OwnSourceRule, clock: any MGDomain.Clock = SystemClock(),
                types: [HealthReadType] = HealthReadType.allCases, firstRunLookbackDays: Int = 90) {
        self.provider = provider
        self.sink = sink
        self.removal = removal
        self.own = own
        self.clock = clock
        self.types = types
        self.firstRunLookbackDays = firstRunLookbackDays
    }

    public func authState() async -> HealthAuthState { await provider.authState }

    /// Asks for read access. Does nothing when Health is not usable (entitlement missing, unavailable).
    public func requestAccess() async throws {
        guard await provider.authState.isUsable else { return }
        try await provider.requestReadAuthorization()
    }

    public func sync() async -> HealthSyncReport {
        let state = await provider.authState
        var report = HealthSyncReport(state: state, message: state.message)
        guard state.isUsable else { return report }       // every Health value stays blank, with the reason

        let now = clock.now
        let since = now.addingTimeInterval(-Double(firstRunLookbackDays) * 86_400)
        for type in types {
            let anchor = await sink.anchor(for: type.rawValue)
            do {
                let batch = try await provider.changes(for: type, anchor: anchor, since: since)
                let kept = batch.records.filter { !own.isOwn($0) }
                report.skippedOwnSource += batch.records.count - kept.count
                let mapped = mapper.map(kept, loggedAt: now)
                report.skippedInvalid += mapped.skippedInvalid
                try await sink.ingest(mapped.events)
                report.ingested += mapped.events.count
                report.perType[type.rawValue] = mapped.events.count
                if !batch.deleted.isEmpty {
                    report.deletedSeen += batch.deleted.count
                    // Deleted raw samples of a summarised hour cannot be mapped back to the hour's event.
                    if let removal, type.granularity == .perSample {
                        try await removal.markRemoved(ids: batch.deleted.map { HealthEventMapper.eventID(forSample: $0) })
                        report.deletedRemoved += batch.deleted.count
                    }
                }
                // Last, so any failure above leaves the anchor where it was and the same changes come again.
                if let newAnchor = batch.newAnchor { try await sink.setAnchor(newAnchor, for: type.rawValue) }
            } catch {
                report.errors.append("\(type.rawValue): \(error)")
            }
        }
        return report
    }
}
