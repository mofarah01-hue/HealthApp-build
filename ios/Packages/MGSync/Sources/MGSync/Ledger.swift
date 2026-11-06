import Foundation
import MGDomain

/// Where the delivery ledger is kept (a few hundred KB of JSON at most). The app passes closures over MGStore's
/// key-value table (`value(forKey:)` / `setValue(_:forKey:)`, key `mgsync.ledger`), or a file under Application Support.
public protocol SyncLedgerStore: Sendable {
    func load() async -> Data?
    func save(_ data: Data) async throws
}

public actor InMemorySyncLedgerStore: SyncLedgerStore {
    private var data: Data?

    public init() {}

    public func load() async -> Data? { data }

    public func save(_ data: Data) async throws { self.data = data }
}

public struct ClosureSyncLedgerStore: SyncLedgerStore {
    private let read: @Sendable () async -> Data?
    private let write: @Sendable (Data) async throws -> Void

    public init(read: @escaping @Sendable () async -> Data?, write: @escaping @Sendable (Data) async throws -> Void) {
        self.read = read
        self.write = write
    }

    public func load() async -> Data? { await read() }
    public func save(_ data: Data) async throws { try await write(data) }
}

/// What MGSync remembers about delivered drops, because the `SyncOutbox` port only lists drops that are NOT delivered:
/// - the file names and hashes of every delivered drop of the last 30 days, to tell a current PC result from one
///   computed on older data (`InputsHash.freshness`, ARCHITECTURE.md 5.6);
/// - when the last full sync finished and the last receipt, so the status line survives a relaunch.
/// Losing it costs nothing but freshness ("unknown") and the "last synced" time: delivery itself is recorded in the
/// outbox by `markDelivered`.
struct SyncLedger: Codable, Equatable {
    struct Drop: Codable, Equatable {
        var dropId: String
        var kind: DropKind
        var localDate: String
        /// Manifest `generated_at`: the PC picks the day version with the latest one.
        var generatedAt: Date
        var deliveredAt: Date
        var files: [LedgerFile]
    }

    static let keepDays = 30

    var lastSynced: Date?
    var lastReceipt: SyncReceipt?
    var drops: [Drop] = []
    /// sha256 of the profile the PC last stored (PUT /v1/profile, wave 2): the profile goes again only when it changed.
    var profileSha: String?
    /// T9809: the PC's primary-source map as of the last results poll (metric name -> "phone:<variant>" or
    /// "pc.<model>@<ver>[#variant]"). Kept so the app shows the same pick offline. Optional: older ledgers decode.
    var primary: [String: String]?
    /// Round 8: the results cursor the last results pass started from. A later pass that starts lower than this is a
    /// cursor restart (the phone's result store was cleared or reinstalled) and is written to the sync log with its
    /// reason. Optional so older ledgers decode.
    var lastResultsSince: Int?
    /// Retry / auth state that must survive a relaunch (P9734, 2026-10-14). Optional so older ledgers still decode.
    var syncState: PersistedSyncState?

    mutating func record(_ drop: Drop) {
        drops.removeAll { $0.dropId == drop.dropId }
        drops.append(drop)
    }

    /// Forget drops older than `keepDays` before `today`.
    mutating func prune(today: LocalDay) {
        let cutoff = today.adding(days: -SyncLedger.keepDays).iso
        drops.removeAll { $0.localDate < cutoff }
    }

    /// The groups the PC would hand a model for `date`: the latest day version's files, every stream drop's file by
    /// kind, every raw file (datastore.py `day_inputs`).
    func deliveredInputs(for date: LocalDay) -> DeliveredInputs {
        let ofDay = drops.filter { $0.localDate == date.iso }
        var groups: [String: [LedgerFile]] = [:]
        let days = ofDay.filter { $0.kind == .day }
        if let latest = days.max(by: { ($0.generatedAt, $0.deliveredAt) < ($1.generatedAt, $1.deliveredAt) }) {
            groups["day"] = latest.files
        }
        for drop in ofDay where drop.kind == .streams {
            for file in drop.files {
                let kind = file.name.hasSuffix(".csv.deflate") ? String(file.name.dropLast(".csv.deflate".count)) : file.name
                groups[kind, default: []].append(file)
            }
        }
        let raw = ofDay.filter { $0.kind == .raw }.flatMap(\.files)
        if !raw.isEmpty { groups["raw"] = raw }
        return DeliveredInputs(groups: groups)
    }

    func encoded() throws -> Data { try MGJSON.encoder().encode(self) }

    static func decode(_ data: Data?) -> SyncLedger {
        guard let data, let ledger = try? MGJSON.decoder().decode(SyncLedger.self, from: data) else { return SyncLedger() }
        return ledger
    }
}

/// What the engine remembers between launches about how syncing to the PC is going. Nothing here is user data; losing it
/// only resets the retry ladder and the "PC not receiving since" clock (P9734, 2026-10-14).
struct PersistedSyncState: Codable, Equatable {
    /// Latched only after `SyncEngine.authFailuresToRepair` rejected keys in a row (each after a good /v1/health).
    var needsRepair = false
    var authFailures = 0
    /// Syncs in a row that could not reach the PC or were refused the key; drives the 1/2/5/15/60 min ladder.
    var consecutiveFailures = 0
    var nextRetryAt: Date?
    var lastAttemptAt: Date?
    var lastError: String?
    var lastErrorAt: Date?
    /// The last time the PC accepted a drop (a matching receipt).
    var lastAcceptedAt: Date?
    var bytesDelivered = 0
    /// T9988: drop ids that were cut off part-way (budget, cancel, app left). The next upload asks the PC which files it
    /// already holds and sends only the rest. Optional so older ledgers decode.
    var partialDrops: [String]?
    /// T9988: the last sync that stopped with work left ("stopped, 2.4 MB left"); nil after a sync that finished. Shown in
    /// Settings > Strap & sync. While set, a strap-wake sync may run inside the usual one-hour gap.
    var lastStop: String?
    var lastStopAt: Date?
}
