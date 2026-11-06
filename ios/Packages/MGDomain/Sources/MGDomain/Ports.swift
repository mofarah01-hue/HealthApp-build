import Foundation

// Cross-module ports (ARCHITECTURE.md 4.2, 4.3, 5.9). Declared here so MGBLE, MGStore, MGSync, MGHealth and the app
// agree without depending on each other.

// MARK: - Strap -> store

public protocol HistorySink: Sendable {
    /// One transaction, synchronous=FULL; returns only after COMMIT. Storing the same chunk twice inserts nothing and
    /// succeeds. The caller acks the strap only after this returns (ALG-003).
    func store(_ chunk: HistoryChunk) async throws -> StoredChunkReceipt
    func recordAck(chunkId: String, result: AckResult, at: Date) async throws
}

public protocol LiveSink: Sendable {
    func append(_ batch: StrapRecordBatch) async throws
}

// MARK: - Strap writes (PLAN rule 5)

/// One logged strap write: prior value, payload, readback. Persisted as a `strap_write` event (contract strapWriteEvent);
/// `contractFields` / `init(fields:standingConsent:)` are the one mapping to and from `StrapWriteFields`.
/// `standingConsent` has no contract field yet; MGStore decides where it goes (flagged for contract v0.5).
public struct StrapWriteEntry: Hashable, Sendable {
    public var command: Int
    public var name: String
    public var payloadHex: String
    public var priorValue: String?
    public var readback: String?
    public var confirmedAt: Date
    public var result: String
    public var standingConsent: Bool
    /// Contract strapWriteEvent `restored`: true marks a write that IS a restore, i.e. it wrote a logged prior value
    /// back (`restoreUnlock()`). The original unlock writes, and every other write, leave it nil. Added 2026-10-11
    /// (found by WP-05, approved by main).
    public var restored: Bool?

    public init(
        command: Int,
        name: String,
        payloadHex: String,
        priorValue: String? = nil,
        readback: String? = nil,
        confirmedAt: Date,
        result: String,
        standingConsent: Bool,
        restored: Bool? = nil
    ) {
        self.command = command
        self.name = name
        self.payloadHex = payloadHex
        self.priorValue = priorValue
        self.readback = readback
        self.confirmedAt = confirmedAt
        self.result = result
        self.standingConsent = standingConsent
        self.restored = restored
    }

    /// From a stored `strap_write` event's fields. `standingConsent` isn't in the contract, so the caller supplies it.
    public init(fields f: StrapWriteFields, standingConsent: Bool) {
        self.init(command: f.command, name: f.name ?? "", payloadHex: f.payloadHex, priorValue: f.priorValue,
                  readback: f.readback, confirmedAt: f.confirmedAt, result: f.result ?? "",
                  standingConsent: standingConsent, restored: f.restored)
    }

    /// The contract strapWriteEvent fields of this entry, `restored` included.
    public var contractFields: StrapWriteFields {
        StrapWriteFields(command: command, name: name, payloadHex: payloadHex, priorValue: priorValue,
                         readback: readback, confirmedAt: confirmedAt, result: result, restored: restored)
    }
}

public protocol StrapWriteLog: Sendable {
    func log(_ entry: StrapWriteEntry) async throws
}

/// What the confirm sheet shows before any non-standing strap write (APP-002, D7).
public struct StrapWritePlan: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var reason: String
    public var items: [PlannedWrite]
    public var restorable: Bool?
    public var risks: [String]

    public init(
        id: UUID = UUID(),
        title: String,
        reason: String,
        items: [PlannedWrite],
        restorable: Bool? = nil,
        risks: [String] = []
    ) {
        self.id = id
        self.title = title
        self.reason = reason
        self.items = items
        self.restorable = restorable
        self.risks = risks
    }
}

public struct PlannedWrite: Hashable, Sendable {
    public var name: String
    public var command: Int
    public var payloadHex: String
    /// Read from the strap before the sheet is shown; nil = could not be read (the sheet says so).
    public var currentValue: String?

    public init(name: String, command: Int, payloadHex: String, currentValue: String? = nil) {
        self.name = name
        self.command = command
        self.payloadHex = payloadHex
        self.currentValue = currentValue
    }
}

public enum StrapWriteDecision: Hashable, Sendable {
    case confirmed(at: Date)
    case declined
}

public protocol StrapWriteConfirmer: Sendable {
    func confirm(_ plan: StrapWritePlan) async -> StrapWriteDecision
}

// MARK: - Apple Health -> store

public protocol HealthSampleSink: Sendable {
    func ingest(_ events: [EventRecord]) async throws
    func anchor(for type: String) async -> Data?
    func setAnchor(_ data: Data, for type: String) async throws
}

// MARK: - Time

/// Everything that reads "now" takes a Clock, so tests can fix it.
/// Note: the Swift standard library also has a `Clock` protocol; modules importing MGDomain get this one
/// (declarations in an imported module shadow the standard library's). Qualify as `MGDomain.Clock` if a compiler
/// ever reports an ambiguity.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

public struct FixedClock: Clock {
    public var now: Date
    public init(_ now: Date) { self.now = now }
    public init(now: Date) { self.now = now }
}

// MARK: - Sync (ARCHITECTURE.md 5.9)

/// The three files of a `day` drop (ARCHITECTURE.md 5.4), as uploaded.
public struct DayBundleFiles: Hashable, Sendable {
    public var day: LocalDay
    public var summary: Data
    public var events: Data
    public var series: Data

    public init(day: LocalDay, summary: Data, events: Data, series: Data) {
        self.day = day
        self.summary = summary
        self.events = events
        self.series = series
    }
}

/// Decoded strap streams exported as CSV (ARCHITECTURE.md 5.4). `ppg` is "later" and not a case yet.
public enum StreamKind: String, Codable, Sendable, CaseIterable {
    case rr = "rr"
    case hr = "hr"
    case r18 = "r18"
    case strapEvents = "strap_events"

    /// The exact header row (UTF-8, comma, `\n`, empty cell = null). One source for writer, reader and tests.
    public var csvHeader: String {
        switch self {
        case .rr: return "ts,ord,rr_ms,source"
        case .hr: return "ts,bpm,source"
        case .r18: return "ts,hr,rr_count,gx,gy,gz,steps,activity_class,skin_temp_raw,sleep_state,spo2_byte,optical_50hz"
        case .strapEvents: return "ts,number,name,payload_hex"
        }
    }
}

public protocol DayBundleSource: Sendable {
    func dirtyDays() async throws -> [LocalDay]
    func dayBundle(_ day: LocalDay) async throws -> DayBundleFiles
}

public protocol StreamExportSource: Sendable {
    func pendingStreamRanges() async throws -> [(kind: StreamKind, from: Int64, to: Int64)]
    func streamCSV(_ kind: StreamKind, from: Int64, to: Int64) async throws -> Data
}

/// Drop kinds of ARCHITECTURE.md 5.4.
public enum DropKind: String, Codable, Sendable, CaseIterable {
    case day = "day"
    case streams = "streams"
    case raw = "raw"
    /// T9821: one live-ECG session (drop id `ecg_<event id>`, file `ecg_session.json`).
    case ecg = "ecg"
}

/// `outbox_drop.state` (ARCHITECTURE.md 4.5).
public enum OutboxState: String, Codable, Sendable, CaseIterable {
    case pending = "pending"
    case uploading = "uploading"
    case delivered = "delivered"
    case failed = "failed"
}

/// One file of a drop, with the bytes exactly as uploaded (hash and size are of these bytes, ARCHITECTURE.md 5.4).
public struct OutboxFile: Hashable, Sendable {
    public var name: String
    public var bytes: Int
    public var sha256: String
    public var records: Int
    public var blob: Data
    /// The PC's receipt once it arrived (`outbox_file.receipt_json`).
    public var receipt: SyncReceipt?

    public init(name: String, bytes: Int, sha256: String, records: Int, blob: Data, receipt: SyncReceipt? = nil) {
        self.name = name
        self.bytes = bytes
        self.sha256 = sha256
        self.records = records
        self.blob = blob
        self.receipt = receipt
    }
}

/// One queued upload (ARCHITECTURE.md 4.5 `outbox_drop` + `outbox_file`). Added with main's approval 2026-10-11.
public struct OutboxDrop: Hashable, Sendable {
    public var dropId: String
    public var kind: DropKind
    public var localDay: LocalDay?
    public var strapTsStart: Int64?
    public var strapTsEnd: Int64?
    /// The commit manifest (ARCHITECTURE.md 5.4) as JSON bytes.
    public var manifest: Data
    public var files: [OutboxFile]
    public var state: OutboxState
    public var attempts: Int
    public var lastError: String?
    public var createdAt: Date
    public var deliveredAt: Date?

    public init(
        dropId: String,
        kind: DropKind,
        localDay: LocalDay? = nil,
        strapTsStart: Int64? = nil,
        strapTsEnd: Int64? = nil,
        manifest: Data,
        files: [OutboxFile],
        state: OutboxState = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        createdAt: Date,
        deliveredAt: Date? = nil
    ) {
        self.dropId = dropId
        self.kind = kind
        self.localDay = localDay
        self.strapTsStart = strapTsStart
        self.strapTsEnd = strapTsEnd
        self.manifest = manifest
        self.files = files
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
    }
}

public protocol SyncOutbox: Sendable {
    func enqueue(_ drop: OutboxDrop) async throws
    func pending() async throws -> [OutboxDrop]
    func markDelivered(_ dropId: String, receipts: [SyncReceipt]) async throws
    func markFailed(_ dropId: String, error: String) async throws
}

public protocol ResultsSink: Sendable {
    var resultsCursor: Int { get async }
    func store(_ result: LabResult, sha256: String, seq: Int) async throws
}

/// What one sync delivered, for the batched SYNC_RECEIPT notification ("PC got 3 h of data (412 KB)").
/// Added with main's approval 2026-10-11.
public struct DeliverySummary: Hashable, Sendable {
    public var drops: Int
    public var files: Int
    public var bytes: Int
    public var records: Int
    public var rangeStart: Date?
    public var rangeEnd: Date?
    public var pcName: String?

    public init(
        drops: Int,
        files: Int,
        bytes: Int,
        records: Int,
        rangeStart: Date? = nil,
        rangeEnd: Date? = nil,
        pcName: String? = nil
    ) {
        self.drops = drops
        self.files = files
        self.bytes = bytes
        self.records = records
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.pcName = pcName
    }
}

public protocol SyncNotifying: Sendable {
    func delivered(summary: DeliverySummary) async
    func reachabilityChanged(_ reachable: Bool) async
}
