import CryptoKit
import Foundation
import MGDomain

// Apple Health -> PC without Mo (T9739, fix brief C; docs/features/APPLE-HEALTH-AUTO.md). Pure Swift, tested on a Mac.
//
//   read   : per type, ask the provider for what is new since the stored anchor (HKAnchoredObjectQuery in the real one)
//   queue  : new samples become JSON bodies in the saved state, TOGETHER with the new anchor, in one save. A failed save
//            leaves both as they were, so a sample is never both "read" and not queued.
//   send   : every queued body goes to POST /v1/health-samples (format A of pclab/mglab/import_shortcut.py). Only the PC's
//            answer removes a body from the queue; no answer (no Tailscale, PC off, 5xx, 401) keeps it for the next run.
//            A body the PC refuses for good (400) is moved to `rejected`, kept with the reason, never deleted.
// The PC dedups by body hash and unions samples by (type, start, end, source), so a resend after a lost answer is harmless.

// MARK: - Ports

public struct HealthAutoSample: Codable, Hashable, Sendable {
    public var typeID: String
    public var value: Double
    public var unit: String
    public var start: Date
    public var end: Date
    public var source: String
    public var device: String?
    public var uuid: String
    /// Extra text the PC keeps in request.json but does not use yet (workout activity, ECG classification).
    public var extras: [String: String]
    /// P9817 (#2): set when the sample could not be cast or unit-converted. It is still sent: `value` becomes the text
    /// HealthKit gave (`rawValueText`), `unit` stays as given, and the PC marks it `raw_fallback`. Nothing is lost.
    public var rawFallbackReason: String?
    public var rawValueText: String?

    /// A sample that failed conversion, kept as given (type id, uuid, dates, source, value text, unit text).
    public static func rawFallback(typeID: String, uuid: String, start: Date, end: Date, source: String, device: String?,
                                   valueText: String, unit: String, reason: String) -> HealthAutoSample {
        var s = HealthAutoSample(typeID: typeID, value: 0, unit: unit, start: start, end: end, source: source, device: device,
                                 uuid: uuid)
        s.rawFallbackReason = reason
        s.rawValueText = valueText
        return s
    }

    public init(typeID: String, value: Double, unit: String, start: Date, end: Date, source: String, device: String? = nil,
                uuid: String, extras: [String: String] = [:]) {
        self.typeID = typeID
        self.value = value
        self.unit = unit
        self.start = start
        self.end = end
        self.source = source
        self.device = device
        self.uuid = uuid
        self.extras = extras
    }
}

public struct HealthAutoBatch: Sendable {
    public var samples: [HealthAutoSample]
    public var newAnchor: Data?
    /// The provider stopped at its page limit: ask again with `newAnchor`.
    public var hasMore: Bool
    /// P9817 (#2): samples the provider got but could not store even as a raw fallback. The engine does NOT move the anchor
    /// when this is above 0, so they are asked for again.
    public var unstored: Int
    /// P9817 (#7): this type does not exist on this iOS version / build. Not an empty read.
    public var unsupported: Bool

    public init(samples: [HealthAutoSample] = [], newAnchor: Data? = nil, hasMore: Bool = false, unstored: Int = 0,
                unsupported: Bool = false) {
        self.samples = samples
        self.newAnchor = newAnchor
        self.hasMore = hasMore
        self.unstored = unstored
        self.unsupported = unsupported
    }
}

public protocol HealthAutoProvider: Sendable {
    var authState: HealthAuthState { get async }
    /// Read-only permission sheet for every type of `HealthAutoCatalogue.all`.
    func requestAuthorization() async throws
    /// Samples of `type` added since `anchor`. nil anchor = first run: only samples starting at or after `since`.
    func changes(for type: HealthAutoType, anchor: Data?, since: Date) async throws -> HealthAutoBatch
    /// T10033: samples of `type` that START at or after `from`, oldest first, one page (`hasMore` = ask again from the
    /// newest start). No anchor: the recent-days lane reads by date, beside the anchored history pull.
    func recent(for type: HealthAutoType, from: Date) async throws -> HealthAutoBatch
    /// Ids of the types the permission sheet has already been shown for (nil = this provider cannot tell). HealthKit never
    /// says whether READ access was granted; this only separates "never asked" from "asked".
    func askedTypeIDs(_ types: [HealthAutoType]) async -> Set<String>?
}

extension HealthAutoProvider {
    public func askedTypeIDs(_ types: [HealthAutoType]) async -> Set<String>? { nil }
    /// A provider without a date query has no recent lane: the anchored pull is all there is.
    public func recent(for type: HealthAutoType, from: Date) async throws -> HealthAutoBatch { HealthAutoBatch() }
}

public protocol HealthAutoStorage: Sendable {
    func load() async -> Data?
    func save(_ data: Data) async throws
}

public struct ClosureHealthAutoStorage: HealthAutoStorage {
    private let read: @Sendable () async -> Data?
    private let write: @Sendable (Data) async throws -> Void

    public init(read: @escaping @Sendable () async -> Data?, write: @escaping @Sendable (Data) async throws -> Void) {
        self.read = read
        self.write = write
    }

    public func load() async -> Data? { await read() }
    public func save(_ data: Data) async throws { try await write(data) }
}

public enum HealthAutoUploadResult: Sendable, Equatable {
    /// The PC answered 200 or 201: it has the samples.
    case accepted
    /// The PC refused this body for good (400/413): retrying cannot help.
    case rejected(String)
    /// Not delivered (offline, 401, 5xx ...): keep it and try again.
    case retry(String)
    /// Hup2 (Nov 6 2026): the caller was released (the run's time limit) but the transfer goes on in the background session.
    /// Not a failure: the batch stays queued, nothing is marked as an error, and when the PC's answer arrives
    /// `HealthAutoSync.recordAccepted` removes it. Until then the batch is not sent again.
    case pending(String)
}

public protocol HealthAutoUploader: Sendable {
    func upload(_ body: Data) async -> HealthAutoUploadResult
    /// Same, told which batch keys the body carries (one key, or several for a merged body): lets the uploader tag the transfer
    /// so a late answer can be matched to the batches. Default: `upload(_:)`.
    func upload(_ body: Data, keys: [String]) async -> HealthAutoUploadResult
    /// Keys of the batches that have a transfer under way right now (also from an earlier launch). Default: none.
    func inFlightKeys() async -> Set<String>
}

extension HealthAutoUploader {
    public func upload(_ body: Data, keys: [String]) async -> HealthAutoUploadResult { await upload(body) }
    public func inFlightKeys() async -> Set<String> { [] }
}

// MARK: - Payload

public enum HealthAutoPayload {
    /// Samples per POST. 1500 samples are about 400 KB of JSON, well under the PC's 8 MB limit.
    public static let maxSamplesPerBatch = 1500

    /// "2026-10-11T07:00:00-07:00": ISO 8601 WITH the offset (the PC refuses a start without one); UTC is "+00:00", not "Z".
    public static func iso(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let a = abs(offset)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, sign, a / 3600, (a % 3600) / 60)
    }

    /// The JSON body of one POST: `{"v":1,"app":"HealthApp","sent_at":…,"samples":[{type,value,unit,start,end,source,…}]}`.
    public static func body(_ samples: [HealthAutoSample], sentAt: Date, timeZone: TimeZone) -> Data {
        func object(_ s: HealthAutoSample) -> [String: Any] {
            var o: [String: Any] = ["type": s.typeID, "value": s.rawValueText ?? s.value, "unit": s.unit,
                                    "start": iso(s.start, timeZone: timeZone), "end": iso(s.end, timeZone: timeZone),
                                    "source": s.source, "uuid": s.uuid]
            if let d = s.device { o["device"] = d }
            for (k, v) in s.extras where o[k] == nil { o[k] = v }
            if let why = s.rawFallbackReason { o["raw_fallback"] = true; o["raw_reason"] = why }
            return o
        }
        let doc: [String: Any] = ["v": 1, "app": "HealthApp", "sent_at": iso(sentAt, timeZone: timeZone),
                                  "samples": samples.map(object)]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data()
    }

    /// Hup2: how a transfer is labelled so its answer can be matched to batches after the caller is gone ("health:" + keys).
    public static func taskDescription(keys: [String]) -> String { "health:" + keys.joined(separator: ",") }

    /// The batch keys in a task description made by `taskDescription(keys:)`; empty for any other description.
    public static func keys(inTaskDescription d: String) -> [String] {
        guard d.hasPrefix("health:") else { return [] }
        return d.dropFirst("health:".count).split(separator: ",").map(String.init)
    }

    /// T9988: what a body says without its `sent_at` (the only part that changes when the same samples are read again),
    /// as 16 hex characters of its SHA-256. Two bodies with the same key carry the same samples.
    public static func contentKey(_ body: Data) -> String {
        var canonical = body
        if var doc = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            doc["sent_at"] = nil
            canonical = (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? body
        }
        return SHA256.hash(data: canonical).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Several bodies as one: the `samples` joined in order, the envelope (`v`, `app`) of the first and the NEWEST `sent_at`.
    /// nil when a body cannot be read or the envelopes differ (the caller then sends them one by one).
    public static func merge(_ bodies: [Data]) -> Data? {
        guard bodies.count > 1 else { return bodies.first }
        var docs: [[String: Any]] = []
        for b in bodies {
            guard let d = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any], d["samples"] is [Any] else { return nil }
            docs.append(d)
        }
        func envelope(_ d: [String: Any]) -> NSDictionary {
            var e = d
            e["samples"] = nil
            e["sent_at"] = nil
            return NSDictionary(dictionary: e)
        }
        guard docs.dropFirst().allSatisfy({ envelope($0).isEqual(envelope(docs[0])) }) else { return nil }
        var out = docs[0]
        out["samples"] = docs.flatMap { $0["samples"] as? [Any] ?? [] }
        out["sent_at"] = docs.last?["sent_at"]
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// Splits into POST-sized groups, order kept.
    public static func chunks(_ samples: [HealthAutoSample], size: Int = maxSamplesPerBatch) -> [[HealthAutoSample]] {
        guard !samples.isEmpty, size > 0 else { return [] }
        return stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }
}

// MARK: - Saved state

/// The provider's answer while the phone is locked (HealthKit errorDatabaseInaccessible): not a fault, a wait for unlock.
public struct HealthAutoLocked: Error, CustomStringConvertible, Sendable {
    public init() {}
    public var description: String { "Apple Health is locked until the phone is unlocked" }
}

public struct HealthAutoState: Codable, Equatable, Sendable {
    public struct Queued: Codable, Equatable, Sendable {
        public var id: UUID
        public var body: Data
        public var sampleCount: Int
        public var createdAt: Date
        public var attempts: Int
        public var lastError: String?
        /// `HealthAutoPayload.contentKey(body)`; nil on a state saved before T9988.
        public var key: String?
    }

    public struct Rejected: Codable, Equatable, Sendable {
        public var at: Date
        public var reason: String
        public var sampleCount: Int
        public var body: Data
    }

    /// P9817: what came back per type (for Settings > Apple Health). Optional so a state saved before it still decodes.
    public var typeStats: [String: HealthAutoTypeStat]?
    /// Round 5 (#8/#11): per type, uuids already queued (and counted) while the anchor is held back by an unstored sample.
    /// The next read of that page skips them, so the queue and the per-type statistics do not grow on every retry.
    /// Cleared for a type when its anchor advances.
    public var pendingUUIDs: [String: [String]]?
    /// P9817: nil/false = anchors were made under the old 30-day first read; they are dropped once so ALL history is read.
    public var historyReset: Bool?
    public var anchors: [String: Data] = [:]
    /// r9u: only a state saved before 2026-10-17 holds bodies here. The engine moves them into the `HealthAutoQueue` the first
    /// time it loads and saves `[]`; the live queue is the queue store, so this field stays empty and a save stays small.
    public var queue: [Queued] = []
    /// r9u: what the queue store held at the last look (counts only; bodies are never in the state).
    public var queuedBatches: Int?
    public var queuedBytes: Int?
    public var queuedSampleCount: Int?
    public var rejected: [Rejected] = []
    /// T9988: content keys of the bodies the PC accepted (newest last, at most `HealthAutoSync.maxSentKeys`). A batch whose
    /// samples were already accepted (a re-read after an anchor reset, a retry whose answer was lost) is not sent again.
    public var sentKeys: [String]?
    /// When the anchored HISTORY pull (`read`) last ran. Saved under the old name `lastRead`; use `lastHistoryRead`.
    public var lastRead: Date?
    /// Nov 5 2026: when the by-date lanes (the observer lane and the recent-days lane) last read a type. Apart from the history
    /// pull, so a stalled history pull ("Oct 17") cannot look like nothing was read while the observer read every hour.
    public var lastRecentRead: Date?
    public var lastHistoryRead: Date? {
        get { lastRead }
        set { lastRead = newValue }
    }
    public var lastReached: Date?
    /// Why the last run did not do everything (blank = it did).
    public var lastProblem: String?
    /// V3: the latest wake the app has seen (strap flag or phone); types pulled "after wake" are due once it is newer than their last read.
    public var lastWake: Date?
    /// T10033: per type, where the recent-days lane reads from next (nil = the start of the window).
    public var recentFrom: [String: Date]?
    /// 0.6.0.7 (Oct 28 2026, background sync stalled Oct 27-28): when an observer callback last arrived, per type.
    public var lastDelivery: [String: Date]?
    /// The last read failure of any lane and when; a locked phone counts here too, with what it waits for.
    public var lastReadError: String?
    public var lastReadErrorAt: Date?
    /// Types whose observed read found Apple Health locked: read again when the phone unlocks (`runAtUnlock`).
    public var lockedTypes: [String]?

    public init() {}

    public var queuedSamples: Int { queuedSampleCount ?? queue.reduce(0) { $0 + $1.sampleCount } }
}

/// What one Health type has delivered so far (counts and times only, no values).
public struct HealthAutoTypeStat: Codable, Equatable, Sendable {
    public var samples = 0
    public var lastSampleEnd: Date?
    public var lastReadAt: Date?
    /// Source name -> samples (the Watch, the iPhone, a third-party app ...).
    public var sources: [String: Int] = [:]
    /// P9817 (#7): the reader said this iOS version / build has no such type.
    public var unsupported: Bool?
    /// P9817 (#2): samples sent as raw fallbacks (cast or unit conversion failed).
    public var rawFallbacks: Int?
    /// V3: when a read of this type last caught up to the end of what HealthKit has (nil = never, or a history pull is still
    /// being spread over runs). The poll schedule and the "N of M caught up" progress read this, not `lastReadAt`.
    public var lastCompleteAt: Date?

    public init() {}
}

public struct HealthAutoTypeRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var text: String
    public var hasData: Bool
}

/// Settings > Apple Health, one line per type: "Blood Oxygen: no data ..." vs "Heart Rate: 14 samples, last 9:05 AM".
public enum HealthAutoTypeStatus {
    /// "HKQuantityTypeIdentifierOxygenSaturation" -> "Blood Oxygen"; other ids -> spaced words ("Walking Heart Rate Average").
    public static func name(_ id: String) -> String {
        var s = id
        for p in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKDataTypeIdentifier", "HKWorkoutTypeIdentifier",
                   "HKCorrelationTypeIdentifier", "HKClinicalTypeIdentifier", "HKWorkoutRouteTypeIdentifier"]
        where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.isEmpty { return id == HealthAutoCatalogue.workoutID ? "Workouts" : (id == "HKWorkoutRouteTypeIdentifier" ? "Workout Routes" : id) }
        if s == "OxygenSaturation" { return "Blood Oxygen" }
        if s == "Electrocardiogram" { return "ECG" }
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0, ch.isUppercase, let last = out.last, !last.isUppercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    public static func rows(types: [HealthAutoType], state: HealthAutoState, asked: Set<String>?, now: Date,
                            timeZone: TimeZone) -> [HealthAutoTypeRow] {
        let all = types.map { t -> HealthAutoTypeRow in
            let name = Self.name(t.id)
            if !t.isSafeInThisBuild { return .init(id: t.id, name: name, text: HealthAutoType.notInBuildText, hasData: false) }
            guard let st = state.typeStats?[t.id], st.lastReadAt != nil else {
                return .init(id: t.id, name: name, text: "not read yet", hasData: false)
            }
            if st.unsupported == true {
                let need = t.minIOS.map { " (needs iOS \($0) or newer, or an entitlement this build does not carry)" } ?? ""
                return .init(id: t.id, name: name, text: "unsupported on this iOS version\(need)", hasData: false)
            }
            if st.samples > 0 {
                let from = st.sources.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3)
                    .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                let last = HealthAutoStatusLine.when(st.lastSampleEnd, never: "unknown", now: now, timeZone: timeZone)
                let raw = (st.rawFallbacks ?? 0) > 0 ? "; \(st.rawFallbacks ?? 0) kept as raw text (conversion failed)" : ""
                return .init(id: t.id, name: name, text: "\(st.samples) sample\(st.samples == 1 ? "" : "s"), last \(last); from \(from)\(raw)",
                             hasData: true)
            }
            if let asked, !asked.contains(t.id) {
                return .init(id: t.id, name: name, text: "permission request not shown yet for this type; no sample read",
                             hasData: false)
            }
            return .init(id: t.id, name: name,
                         text: "unknown (HealthKit doesn't tell apps whether read is allowed): no sample read, last sample time none; "
                             + "check Health > Sharing > Apps > this app", hasData: false)
        }
        return all.filter(\.hasData).sorted { $0.name < $1.name } + all.filter { !$0.hasData }.sorted { $0.name < $1.name }
    }
}

/// What the Settings line shows.
public enum HealthAutoStatusLine {
    /// A time of day, or "Oct 14, 9:05 AM" for an earlier day; `never` when there is none (a blank carries its reason).
    static func when(_ d: Date?, never: String, now: Date, timeZone: TimeZone) -> String {
        guard let d else { return never }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let t = ClockText.hm(d, timeZone: timeZone)
        if cal.isDate(d, inSameDayAs: now) { return t }
        let c = cal.dateComponents([.month, .day], from: d)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[max(0, min(11, (c.month ?? 1) - 1))]) \(c.day ?? 1), \(t)"
    }

    /// "Apple Health: last read 9:05 AM, last reached the PC 9:06 AM, 0 samples queued". A time from an earlier day gets its
    /// date. A blank carries its reason, never a made-up time.
    public static func text(_ s: HealthAutoState, now: Date, timeZone: TimeZone, types: [HealthAutoType]? = nil) -> String {
        func when(_ d: Date?, never: String) -> String { Self.when(d, never: never, now: now, timeZone: timeZone) }
        let why = s.lastProblem.map { " (\($0))" } ?? ""
        let lastAny = [s.lastRead, s.lastRecentRead].compactMap { $0 }.max()      // either lane: a stalled history pull is not "never read"
        let read = when(lastAny, never: "not yet" + why)
        let reached = when(s.lastReached, never: "not yet" + (lastAny == nil ? "" : why))
        let n = s.queuedSamples
        var line = "Apple Health: last read \(read), last reached the PC \(reached), \(n) sample\(n == 1 ? "" : "s") queued"
        if !s.rejected.isEmpty {
            line += ", \(s.rejected.reduce(0) { $0 + $1.sampleCount }) refused by the PC (kept on the phone)"
        }
        if let types {
            // V3 progress: the first pull of all history is spread over runs.
            let safe = types.filter { $0.isSafeInThisBuild && $0.kind != .correlation }
            let done = safe.filter { s.typeStats?[$0.id]?.lastCompleteAt != nil }.count
            if done < safe.count { line += ", history: \(done) of \(safe.count) types caught up (continues on the next sync)" }
        }
        if lastAny != nil, let p = s.lastProblem { line += " - \(p)" }
        return line
    }
}

struct UnstoredSamples: Error, CustomStringConvertible {
    let count: Int
    var description: String { "\(count) sample\(count == 1 ? "" : "s") could not be stored, will be asked for again" }
}

// MARK: - Engine

public actor HealthAutoSync {
    private let provider: any HealthAutoProvider
    private let storage: any HealthAutoStorage
    private let queue: any HealthAutoQueue
    private let uploader: any HealthAutoUploader
    private let clock: any MGDomain.Clock
    private let timeZone: @Sendable () -> TimeZone
    private let types: [HealthAutoType]
    /// nil = the first read of a type takes ALL history (Mo, P9817: "we want it all to come here"); a number limits it.
    private let firstRunLookbackDays: Int?
    private let maxPagesPerType: Int
    /// V3: pages one run may read of a type whose history is not fully pulled yet, so every type progresses each run.
    private let firstPullPagesPerRun: Int
    /// P9817 (#5): one run reads at most this many pages and this many seconds in total (a background run is cut off by iOS
    /// anyway); what is left resumes from the saved anchors on the next run. Cancelling the calling Task (the BGTask
    /// expiration handler does) stops it at the next page.
    private let maxPagesPerRun: Int
    private let runSeconds: TimeInterval
    /// The time this run may use: `runSeconds` for `run`, the caller's for `runObserved` (an observer callback is short).
    private var limit: TimeInterval = 25
    /// Types delivered while a pass was running; the observed pass reads them before it ends.
    private var pendingObserved: Set<String> = []
    /// Reading may use this share of `runSeconds`; the rest is kept for sending what was queued.
    private let readShare = 0.7
    private var pagesThisRun = 0
    private var runStart = Date.distantPast
    private var pausedByBudget = false
    /// T9988: how many accepted-batch keys are remembered (16 hex characters each, about 20 bytes in the saved state).
    /// T9991 (d): 10,000 (about 200 KB, saved with the rest of the state), up from 1,000 - a years-long first read sends
    /// more batches than that, and a re-read after an anchor reset would send the oldest ones again.
    static let maxSentKeys = 10_000
    /// r9u: reading stops while the queue holds this many POST bodies or this many bytes of plain JSON, so the queue cannot grow
    /// without bound when the PC is away. 50 bodies of up to 1500 samples (about 0.5 MB each) is about 25 MB: more than one
    /// run can send (a 25 s run sends a few dozen at LAN speed), little enough that the phone never carries a backlog it
    /// cannot clear in a few runs. Uploads always come before reads.
    static let maxQueuedBodies = 50
    static let maxQueuedBytes = 25 * 1_048_576
    /// Nov 5 2026: small queued bodies are sent as one POST. A body under this many samples starts a merge; bodies are merged
    /// up to `HealthAutoPayload.maxSamplesPerBatch` samples, looking at most `coalesceWindow` bodies deep (each is loaded).
    static let coalesceBelow = HealthAutoPayload.maxSamplesPerBatch / 2
    static let coalesceWindow = 8
    /// Hup2: one pass looks past at most this many batches whose transfer is already in flight (each look loads the bodies before it).
    static let maxWaitingSkips = 8
    /// Share of the run's time the upload before reading may use (the rest is for reading; the closing upload uses what is left).
    private let drainFirstShare = 0.5
    private var backlogFull = false
    private let enabled: @Sendable () async -> Bool
    private var state = HealthAutoState()
    private var loaded = false
    private var running = false
    /// The saved state exists but cannot be decoded: nothing is read or saved, so the unreadable file is never overwritten.
    private var unreadable = false

    public init(provider: any HealthAutoProvider, storage: any HealthAutoStorage, queue: (any HealthAutoQueue)? = nil,
                uploader: any HealthAutoUploader,
                clock: any MGDomain.Clock = SystemClock(), timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
                types: [HealthAutoType] = HealthAutoCatalogue.all, firstRunLookbackDays: Int? = nil, maxPagesPerType: Int = 40,
                firstPullPagesPerRun: Int = 4, maxPagesPerRun: Int = 60, runSeconds: TimeInterval = 25,
                enabled: @escaping @Sendable () async -> Bool = { true }) {
        self.enabled = enabled
        self.provider = provider
        self.storage = storage
        self.queue = queue ?? MemoryHealthAutoQueue()
        self.uploader = uploader
        self.clock = clock
        self.timeZone = timeZone
        self.types = types
        self.firstRunLookbackDays = firstRunLookbackDays
        self.maxPagesPerType = maxPagesPerType
        self.firstPullPagesPerRun = firstPullPagesPerRun
        self.maxPagesPerRun = maxPagesPerRun
        self.runSeconds = runSeconds
    }

    private var queueIsFull: Bool {
        (state.queuedBatches ?? 0) >= Self.maxQueuedBodies || (state.queuedBytes ?? 0) >= Self.maxQueuedBytes
    }

    private func refreshQueueStats() async {
        guard let st = try? await queue.stats() else { return }
        state.queuedBatches = st.batches
        state.queuedBytes = st.bytes
        state.queuedSampleCount = st.samples
    }

    /// Nov 5 2026 (Mo: "a backlog must never get that big"): what the queue can still take before its cap, read from the store.
    private func room() async -> (bodies: Int, bytes: Int) {
        await refreshQueueStats()
        return (max(0, Self.maxQueuedBodies - (state.queuedBatches ?? 0)), max(0, Self.maxQueuedBytes - (state.queuedBytes ?? 0)))
    }

    /// The longest start of `batches` that fits under the cap (none when the queue is full): nothing is ever queued past it.
    private func fitting(_ batches: [HealthQueuedBatch]) async -> [HealthQueuedBatch] {
        var r = await room()
        var out: [HealthQueuedBatch] = []
        for b in batches {
            guard r.bodies > 0, b.body.count <= r.bytes else { break }
            out.append(b)
            r.bodies -= 1
            r.bytes -= b.body.count
        }
        return out
    }

    private var overBudget: Bool {
        Task.isCancelled || pagesThisRun >= maxPagesPerRun || clock.now.timeIntervalSince(runStart) > limit * readShare
    }

    /// Round 5 (#5): runs `op` as a child that is cancelled at `deadline` (and when the caller is cancelled). A provider
    /// or uploader that honours cancellation (the real ones stop their HealthKit queries / URLSession task) is cut off
    /// there; one that does not simply finishes late.
    private func bounded<T: Sendable>(until deadline: Date, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let wait = max(0, deadline.timeIntervalSince(clock.now))
        let work = Task { try await op() }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            work.cancel()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel(); timer.cancel() }
    }

    public func status() async -> HealthAutoState {
        await loadIfNeeded()
        return state
    }

    /// r9u: what is waiting to go to the PC (counts from the queue store; no body is loaded). nil if the store cannot answer.
    public func queueStats() async -> HealthQueueStats? {
        await loadIfNeeded()
        return try? await queue.stats()
    }

    public func statusLine() async -> String {
        await loadIfNeeded()
        return HealthAutoStatusLine.text(state, now: clock.now, timeZone: timeZone(), types: types)
    }

    /// One line per catalogue type for Settings (what came back, last sample time, or why nothing did).
    public func typeRows() async -> [HealthAutoTypeRow] {
        await loadIfNeeded()
        let asked = await provider.askedTypeIDs(types)
        return HealthAutoTypeStatus.rows(types: types, state: state, asked: asked, now: clock.now, timeZone: timeZone())
    }

    /// Asks for read access (once; HealthKit never asks twice).
    public func requestAccess() async throws {
        guard await provider.authState.isUsable else { return }
        try await provider.requestAuthorization()
    }

    /// One pass: read what is new, queue it, send the queue. Safe to call from every trigger (launch, foreground, observer
    /// callback, background refresh); a call that arrives while one runs returns at once.
    @discardableResult
    public func run(trigger: HealthPollTrigger = .manual) async -> HealthAutoState {
        await loadIfNeeded()
        guard !running, !unreadable, await enabled() else { return state }     // not enabled: SAMPLE mode sends nothing
        running = true
        defer { running = false }
        pagesThisRun = 0
        pausedByBudget = false
        runStart = clock.now
        limit = runSeconds
        // r9u: send first, read second. A backlog is cleared, oldest first, before any new sample is read, and reading stops at
        // the cap (Mo, Nov 5: "the backlog is always sent before live data"; this replaced T10033's newest-first send, which
        // let a queue of 1,325 bodies build up behind the live ones).
        let early = await flush(until: runStart.addingTimeInterval(limit * drainFirstShare))
        await refreshQueueStats()
        if queueIsFull {
            let note = "queue is full (\(state.queuedBatches ?? 0) batches); sending before reading more"
            state.lastProblem = [early, note].compactMap { $0 }.joined(separator: "; ")
        } else {
            // T10033: while a type's history pull is not caught up, the last days are read on their own first (by date).
            if recentLaneNeeded { await readRecentLane() }
            await read(trigger)
            if let early, !(state.lastProblem ?? "").contains(early) {
                state.lastProblem = [state.lastProblem, early].compactMap { $0 }.joined(separator: "; ")
            }
        }
        if let late = await flush(until: runStart.addingTimeInterval(limit)) {
            state.lastProblem = [state.lastProblem, late].compactMap { $0 }.joined(separator: "; ")
        }
        await refreshQueueStats()
        await persistBestEffort()
        return state
    }

    // MARK: Observer lane (0.6.0.7)

    /// An HKObserverQuery callback for `typeIDs`: only the newest samples of those types (from each one's recent cursor,
    /// at most the last `recentDays`), queued, then sent with what is left of `seconds`. Kept short so the observer's
    /// completion is called well inside iOS's background window; the history pull stays with `run`. A call that arrives
    /// while another pass runs only records the delivery: the running pass, or the next one, reads it.
    /// A locked phone (Apple Health unreadable) is not a failure: the types wait for `runAtUnlock`.
    /// Nov 5 2026: `afterLocal` is called once the samples are queued and the cursor saved on the phone, BEFORE the first upload
    /// starts, and on every early exit too. The app calls HealthKit's observer completion handler from it, so the handler never
    /// waits for the network; the upload (a background URLSession transfer) goes on after it.
    @discardableResult
    public func runObserved(typeIDs: [String], seconds: TimeInterval = 20,
                            afterLocal: (@Sendable () -> Void)? = nil) async -> HealthAutoState {
        await loadIfNeeded()
        guard !unreadable else { afterLocal?(); return state }
        let now = clock.now
        var delivered = state.lastDelivery ?? [:]
        for id in typeIDs { delivered[id] = now }
        state.lastDelivery = delivered
        if running { pendingObserved.formUnion(typeIDs) }
        guard !running, await enabled() else { await persistBestEffort(); afterLocal?(); return state }
        running = true
        defer { running = false }
        pagesThisRun = 0
        pausedByBudget = false
        runStart = now
        limit = seconds
        var wanted = Set(typeIDs)
        var locked = Set(state.lockedTypes ?? []).subtracting(wanted)
        let usable = (await provider.authState).isUsable
        while usable, !wanted.isEmpty {
            pendingObserved.subtract(wanted)
            for type in types where wanted.contains(type.id) {
                if overBudget { break }
                do {
                    try await readRecent(type, from: state.recentFrom?[type.id], now: now)
                } catch is HealthAutoLocked {
                    locked.insert(type.id)
                    state.lastReadError = "Apple Health locked (phone locked); read again at unlock"
                    state.lastReadErrorAt = now
                } catch {
                    state.lastReadError = "\(type.id.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")): \(error)"
                    state.lastReadErrorAt = now
                }
            }
            // deliveries that came in while this pass read (from `runObserved` calls that found it running)
            wanted = overBudget ? [] : pendingObserved.subtracting(locked)
        }
        state.lockedTypes = locked.isEmpty ? nil : locked.sorted()
        await persistBestEffort()          // samples are in the queue store; the cursor and delivery times are saved too
        afterLocal?()
        if let late = await flush(until: runStart.addingTimeInterval(limit)) {
            state.lastProblem = late
        }
        await refreshQueueStats()
        await persistBestEffort()
        return state
    }

    /// The phone was unlocked (protected data available): read the types an observer found locked. Nothing waiting = no-op.
    @discardableResult
    public func runAtUnlock(seconds: TimeInterval = 20) async -> HealthAutoState {
        await loadIfNeeded()
        guard let ids = state.lockedTypes, !ids.isEmpty else { return state }
        return await runObserved(typeIDs: ids, seconds: seconds)
    }

    /// One recent-lane read of `type` from `cursor` (nil = `recentDays` ago), queued, cursor moved. Throws what the provider
    /// throws (the cursor then stays, so the samples are asked for again).
    private func readRecent(_ type: HealthAutoType, from cursor: Date?, now: Date) async throws {
        let floor = now.addingTimeInterval(-Self.recentDays * 86_400)
        let from = max(cursor ?? floor, floor)
        // Nov 5: a full queue is not read past (the cursor stays); the PC takes the backlog first.
        guard await room().bodies > 0 else { return }
        let provider = self.provider
        let batch = try await bounded(until: runStart.addingTimeInterval(limit * readShare)) {
            try await provider.recent(for: type, from: from)
        }
        guard !batch.unsupported else { return }
        var newBatches: [HealthQueuedBatch] = []
        for group in HealthAutoPayload.chunks(batch.samples) {
            let body = HealthAutoPayload.body(group, sentAt: now, timeZone: timeZone())
            let key = HealthAutoPayload.contentKey(body)
            if state.sentKeys?.contains(key) == true { continue }
            newBatches.append(HealthQueuedBatch(key: key, body: body, sampleCount: group.count, createdAt: now))
        }
        if !newBatches.isEmpty {
            let fits = await fitting(newBatches)
            if !fits.isEmpty { try await queue.append(fits) }
            if fits.count < newBatches.count { return }      // cap reached: the cursor stays, the rest is read next time
        }
        guard batch.unstored == 0 else { return }
        state.lastRecentRead = now
        var next = max(from, now.addingTimeInterval(-Self.recentOverlap(for: type)))
        if batch.hasMore, let newest = batch.samples.map(\.start).max() {
            next = newest > from ? newest : from.addingTimeInterval(1)
        }
        var map = state.recentFrom ?? [:]
        map[type.id] = next
        state.recentFrom = map
        var stats = state.typeStats ?? [:]
        var stat = stats[type.id] ?? HealthAutoTypeStat()
        stat.lastReadAt = now
        if let end = batch.samples.map(\.end).max(), stat.lastSampleEnd.map({ end > $0 }) ?? true { stat.lastSampleEnd = end }
        stats[type.id] = stat
        state.typeStats = stats
    }

    // MARK: Read

    /// V3: the app saw the night end (strap flag or phone). Returns true when it is a wake not seen before, so the caller runs
    /// the after-wake types now.
    public func noteWake(_ wake: Date) async -> Bool {
        await loadIfNeeded()
        guard !unreadable, state.lastWake.map({ wake > $0 }) ?? true else { return false }
        state.lastWake = wake
        await persistBestEffort()
        return true
    }

    private func read(_ trigger: HealthPollTrigger) async {
        let auth = await provider.authState
        guard auth.isUsable else {
            state.lastProblem = auth.message ?? "Apple Health is not usable"
            await persistBestEffort()
            return
        }
        let now = clock.now
        let since = firstRunLookbackDays.map { now.addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
        if state.historyReset != true {
            // Anchors from the old 30-day first read would skip older history: drop them once (the PC unions repeats).
            state.anchors = [:]
            state.typeStats = nil
            state.historyReset = true
            await persistBestEffort()
        }
        backlogFull = false
        var problems: [String] = []
        var complete: [String: Date] = [:]
        for (id, st) in state.typeStats ?? [:] { if let d = st.lastCompleteAt { complete[id] = d } }
        let plan = HealthPollSchedule.plan(types, trigger: trigger, complete: complete, wakeAt: state.lastWake, now: now)
        for type in plan {
            if backlogFull { break }
            if overBudget { pausedByBudget = true; break }
            do {
                try await readType(type, since: since, now: now)
            } catch {
                // The anchor did not move, so the next run asks again (e.g. the phone is locked: Health is unreadable).
                if overBudget { pausedByBudget = true; break }       // cut off by the run's deadline: a pause, not a fault
                problems.append("\(type.id.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")): \(error)")
            }
        }
        state.lastRead = now
        state.lastProblem = problems.isEmpty ? nil : "\(problems.count) type\(problems.count == 1 ? "" : "s") unreadable, tried again next time: "
            + problems.prefix(3).joined(separator: "; ")
        if pausedByBudget {
            let note = "paused at this run's limit; the rest resumes from the saved anchors next run"
            state.lastProblem = [state.lastProblem, note].compactMap { $0 }.joined(separator: "; ")
        }
        if backlogFull {
            let note = "queue is full (\(state.queuedBatches ?? 0) batches); the rest is read once the PC has taken them"
            state.lastProblem = [state.lastProblem, note].compactMap { $0 }.joined(separator: "; ")
        }
        await persistBestEffort()
    }

    private func readType(_ type: HealthAutoType, since: Date, now: Date) async throws {
        var pages = 0
        let pageCap = state.typeStats?[type.id]?.lastCompleteAt == nil ? min(firstPullPagesPerRun, maxPagesPerType) : maxPagesPerType
        repeat {
            if overBudget { pausedByBudget = true; return }
            pages += 1
            pagesThisRun += 1
            let provider = self.provider, anchor = state.anchors[type.id]
            let batch = try await bounded(until: runStart.addingTimeInterval(limit * readShare)) {
                try await provider.changes(for: type, anchor: anchor, since: since)
            }
            var next = state
            var stat = next.typeStats?[type.id] ?? HealthAutoTypeStat()
            stat.lastReadAt = now
            stat.unsupported = batch.unsupported ? true : nil
            if batch.unstored == 0 && !batch.hasMore { stat.lastCompleteAt = now }
            // #11: samples already queued on an earlier pass over this held page are neither queued nor counted again.
            let held = Set(next.pendingUUIDs?[type.id] ?? [])
            let fresh = batch.samples.filter { !held.contains($0.uuid) }
            for s in fresh {
                if s.rawFallbackReason != nil { stat.rawFallbacks = (stat.rawFallbacks ?? 0) + 1 }
                stat.samples += 1
                stat.sources[s.source, default: 0] += 1
                if stat.lastSampleEnd.map({ s.end > $0 }) ?? true { stat.lastSampleEnd = s.end }
            }
            var stats = next.typeStats ?? [:]
            stats[type.id] = stat
            next.typeStats = stats
            var newBatches: [HealthQueuedBatch] = []
            for group in HealthAutoPayload.chunks(fresh) {
                let body = HealthAutoPayload.body(group, sentAt: now, timeZone: timeZone())
                let key = HealthAutoPayload.contentKey(body)
                if next.sentKeys?.contains(key) == true { continue }      // the PC already took exactly these samples
                newBatches.append(HealthQueuedBatch(key: key, body: body, sampleCount: group.count, createdAt: now))
            }
            // r9u: the bodies go to the queue store FIRST, then the state (anchor) is saved. A failure of the first leaves the
            // anchor where it was (read again next time); a failure of the second leaves the bodies queued and the anchor
            // behind, so the next read finds the same samples and the store skips them by content key. Nothing is lost.
            // Nov 5: a page that does not fit under the cap is not queued at all and the anchor stays (all or nothing, because
            // the anchor moves with the page): it is read again once the PC has taken the backlog.
            if !newBatches.isEmpty {
                if await fitting(newBatches).count < newBatches.count { backlogFull = true; return }
                try await queue.append(newBatches)
            }
            // #2: a sample the provider could not store keeps the anchor where it was; the stored ones are still queued
            // (the PC unions by uuid, so asking for them again is harmless).
            if batch.unstored == 0, let a = batch.newAnchor {
                next.anchors[type.id] = a
                next.pendingUUIDs?[type.id] = nil
                if next.pendingUUIDs?.isEmpty == true { next.pendingUUIDs = nil }
            } else if batch.unstored > 0 {
                var pending = next.pendingUUIDs ?? [:]
                pending[type.id] = Array(held.union(fresh.map(\.uuid))).sorted()
                next.pendingUUIDs = pending
            }
            if next != state {
                if fresh.isEmpty && next.anchors == state.anchors && next.pendingUUIDs == state.pendingUUIDs {
                    state = next            // only the read time moved: written with the run's closing save
                } else {
                    do {
                        try await save(next)    // queue and anchor move together, or neither does
                    } catch {
                        for b in newBatches { try? await queue.remove(id: b.id) }     // undo the append (best effort; a leftover is a harmless duplicate)
                        throw error
                    }
                    state = next
                }
            }
            await refreshQueueStats()
            if queueIsFull {
                _ = await flush(until: runStart.addingTimeInterval(limit))
                await refreshQueueStats()
                if queueIsFull { backlogFull = true; return }   // PC not there: stop reading, keep anchors
            }
            if batch.unstored > 0 {
                if overBudget { pausedByBudget = true; return }      // cut off by the deadline: reported as a pause
                throw UnstoredSamples(count: batch.unstored)     // reported in lastProblem; the anchor did not move
            }
            guard batch.hasMore, batch.newAnchor != nil else { return }
        } while pages < pageCap
    }

    // MARK: Recent lane (T10033)

    /// Days the recent lane covers. Mo, Oct 23: "send newest first" after 655 old bodies held every new sample back for days.
    static let recentDays = 14.0
    /// Pages of one type per run, and the lane's share of the run's page budget, so the history pull still moves.
    static let recentPagesPerType = 2
    /// A finished type is read again from this long before the run, to catch samples the Watch syncs late.
    static let recentOverlap: TimeInterval = 2 * 3600
    /// D-SLEEP-LOW-6 (Nov 5 2026): a night's samples are written to Health in chunks after they happened (WHOOP when the
    /// strap syncs, the Watch when it syncs), with a START hours before the write. The 2-hour overlap missed every chunk
    /// that started before it, so the PC could hold only the last chunk of a night. Sleep is read again from 36 hours back,
    /// the whole last night and the evening before it.
    static let sleepRecentOverlap: TimeInterval = 36 * 3600
    static func recentOverlap(for type: HealthAutoType) -> TimeInterval {
        type.id == "HKCategoryTypeIdentifierSleepAnalysis" ? sleepRecentOverlap : recentOverlap
    }

    private var recentLaneNeeded: Bool {
        types.contains { state.typeStats?[$0.id]?.lastCompleteAt == nil }
    }

    /// Reads the last `recentDays` by date, per type, stalest cursor first (so every type gets its turn across runs), and
    /// queues what it finds. Duplicates of the anchored pull are harmless: the PC unions by (type, start, end, source).
    private func readRecentLane() async {
        guard (await provider.authState).isUsable else { return }
        let now = clock.now
        let floor = now.addingTimeInterval(-Self.recentDays * 86_400)
        let cap = max(1, maxPagesPerRun / 2)
        var lanePages = 0
        let order = types.sorted { (state.recentFrom?[$0.id] ?? .distantPast) < (state.recentFrom?[$1.id] ?? .distantPast) }
        for type in order {
            for _ in 0..<Self.recentPagesPerType {
                if lanePages >= cap || overBudget { return }
                guard await room().bodies > 0 else { return }       // Nov 5: never past the cap
                lanePages += 1         // its own cap: the history pull keeps its whole page budget
                let from = max(state.recentFrom?[type.id] ?? floor, floor)
                let provider = self.provider
                guard let batch = try? await bounded(until: runStart.addingTimeInterval(limit * readShare), {
                    try await provider.recent(for: type, from: from)
                }), !batch.unsupported else { break }
                var newBatches: [HealthQueuedBatch] = []
                for group in HealthAutoPayload.chunks(batch.samples) {
                    let body = HealthAutoPayload.body(group, sentAt: now, timeZone: timeZone())
                    let key = HealthAutoPayload.contentKey(body)
                    if state.sentKeys?.contains(key) == true { continue }
                    newBatches.append(HealthQueuedBatch(key: key, body: body, sampleCount: group.count, createdAt: now))
                }
                if !newBatches.isEmpty {
                    let fits = await fitting(newBatches)
                    if !fits.isEmpty { do { try await queue.append(fits) } catch { return } }   // cursor stays: read again next run
                    if fits.count < newBatches.count { return }                   // cap reached: cursor stays, the rest next run
                }
                guard batch.unstored == 0 else { break }                          // cursor stays for the unstored ones
                state.lastRecentRead = now
                var next = max(from, now.addingTimeInterval(-Self.recentOverlap(for: type)))    // read to the end: only late samples left
                if batch.hasMore, let newest = batch.samples.map(\.start).max() {
                    next = newest > from ? newest : from.addingTimeInterval(1)       // page on; never stuck on one start
                }
                var map = state.recentFrom ?? [:]
                map[type.id] = next
                state.recentFrom = map
                if !batch.hasMore { break }
            }
        }
    }

    // MARK: Send

    /// Sends the OLDEST queued bodies first (Nov 5; small ones merged into one POST), until the queue is empty, `deadline` passes, the run is cancelled or the
    /// PC does not answer. Returns the reason it stopped early (nil = the queue is empty). Only the PC's answer removes a body.
    private func flush(until deadline: Date) async -> String? {
        var failed: String?
        let uploader = self.uploader
        var skip = 0         // bodies left in place this pass (a save failed): look further down, never at the same one twice
        var coalesce = true  // off for the rest of this pass once a merged body was refused
        var waiting = 0      // batches skipped because their transfer is already in flight
        while true {
            if Task.isCancelled { failed = failed ?? "stopped by iOS before everything was sent; resumes next run"; break }
            if clock.now > deadline { failed = failed ?? "paused at this run's time limit; the rest is sent next run"; break }
            guard let page = try? await queue.peek(limit: skip + 1), page.count > skip else { break }
            let item = page[skip]
            let key = item.key ?? HealthAutoPayload.contentKey(item.body)
            if state.sentKeys?.contains(key) == true {      // T9988: queued before its twin was accepted; nothing to send
                if (try? await queue.remove(id: item.id)) == nil { skip += 1 }
                continue
            }
            // Hup2: a transfer of this batch is already under way (detached at an earlier run's limit, or from an earlier launch).
            // A second POST would only be answered "duplicate": leave the batch in place and look at the next one (oldest first
            // still), up to `maxWaitingSkips` of them; the transfer's answer removes it (`recordAccepted`).
            let inFlight = await uploader.inFlightKeys()
            if inFlight.contains(key) {
                skip += 1
                waiting += 1
                if waiting >= Self.maxWaitingSkips { break }
                continue
            }
            // Nov 5: small bodies that follow are merged into this POST (fewer, bigger uploads), up to 1,500 samples.
            var group = [item]
            if coalesce, item.sampleCount < Self.coalesceBelow,
               let wider = try? await queue.peek(limit: skip + Self.coalesceWindow) {
                var total = item.sampleCount
                for cand in wider.dropFirst(skip + 1) {
                    if total + cand.sampleCount > HealthAutoPayload.maxSamplesPerBatch { break }
                    let candKey = cand.key ?? HealthAutoPayload.contentKey(cand.body)
                    if state.sentKeys?.contains(candKey) == true || inFlight.contains(candKey) { break }
                    group.append(cand)
                    total += cand.sampleCount
                }
            }
            var body = item.body
            var keys = [key]
            if group.count > 1 {
                if let merged = HealthAutoPayload.merge(group.map(\.body)) {
                    body = merged
                    keys = group.map { $0.key ?? HealthAutoPayload.contentKey($0.body) }
                } else {
                    group = [item]          // a body that cannot be merged goes alone
                }
            }
            let sending = body
            let sendKeys = keys
            let answer = (try? await bounded(until: deadline) { await uploader.upload(sending, keys: sendKeys) }) ?? .retry("cancelled at the run's time limit")
            switch answer {
            case .accepted:
                // The PC confirmed it: record that first, then delete the body. If the delete fails the key makes the
                // next pass drop it without sending; if the save fails the body stays and the resend is harmless.
                if await markSent(keys) {
                    for g in group {
                        if (try? await queue.remove(id: g.id)) == nil { skip += 1 }
                    }
                } else { skip += group.count }
            case .rejected(let why):
                if group.count > 1 {
                    // The PC refused the merged body: which part is bad is unknown. Send the parts one by one from here on.
                    coalesce = false
                    continue
                }
                var next = state
                next.rejected.append(.init(at: clock.now, reason: why, sampleCount: item.sampleCount, body: item.body))
                if (try? await save(next)) != nil {
                    state = next
                    if (try? await queue.remove(id: item.id)) == nil { skip += 1 }
                } else { skip += 1 }
                failed = failed ?? "the PC refused a batch: \(why)"
            case .pending:
                // Hup2: the run's limit released the caller but the transfer goes on. Not an error (no markError, no stop): the
                // batches stay, are skipped while it runs, and the PC's answer removes them. The deadline ends the loop next.
                skip += group.count
            case .retry(let why):
                for g in group { try? await queue.markError(id: g.id, error: why) }
                failed = failed ?? "not delivered to the PC yet: \(why)"
                return failed           // stop at the first failure: the PC is not there, the rest would fail too
            }
        }
        return failed
    }

    /// Records `keys` as accepted (sentKeys, saved) and returns whether the save worked. The state is re-read after the save
    /// (another call may have run meanwhile), so a key added in between is not lost.
    private func markSent(_ keys: [String]) async -> Bool {
        func apply(_ s: inout HealthAutoState) {
            let have = Set(s.sentKeys ?? [])
            s.sentKeys = Array(((s.sentKeys ?? []) + keys.filter { !have.contains($0) }).suffix(HealthAutoSync.maxSentKeys))
            s.lastReached = clock.now
        }
        var next = state
        apply(&next)
        guard (try? await save(next)) != nil else { return false }
        apply(&state)
        return true
    }

    /// Hup2 (Nov 6 2026): the PC answered 200/201 for a transfer nobody was waiting for any more (detached at a run's time limit,
    /// or finished after the app was relaunched). Remembers the keys as sent and removes those batches from the front of the
    /// queue; any left deeper in are dropped without a POST when a run reaches them (`flush` checks `sentKeys` first).
    public func recordAccepted(keys: [String]) async {
        await loadIfNeeded()
        guard !unreadable, !keys.isEmpty, await markSent(keys) else { return }
        let sent = Set(keys)
        for _ in 0..<(Self.coalesceWindow * 2) {
            guard let head = (try? await queue.peek(limit: 1))?.first,
                  sent.contains(head.key ?? HealthAutoPayload.contentKey(head.body)) else { break }
            if (try? await queue.remove(id: head.id)) == nil { break }
        }
        await refreshQueueStats()
        await persistBestEffort()
    }

    // MARK: Storage

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = await storage.load() else { return }
        if var s = try? JSONDecoder.auto.decode(HealthAutoState.self, from: data) {
            // r9u: a state saved before the queue got its own store carries bodies. Move them over once (the store skips ids it
            // already holds, so a crash in between is harmless), then save the state without them. The app's own migration
            // normally does this before we get here (MGStore.migrateHealthQueueFromKV), so this is the small-state path.
            if !s.queue.isEmpty {
                let old = s.queue.map { HealthQueuedBatch(id: $0.id, key: $0.key, body: $0.body, sampleCount: $0.sampleCount,
                                                          createdAt: $0.createdAt, attempts: $0.attempts, lastError: $0.lastError) }
                if (try? await queue.append(old)) != nil {
                    s.queue = []
                    state = s
                    await persistBestEffort()
                }
            }
            state = s
            await refreshQueueStats()
        } else {
            unreadable = true
            state.lastProblem = "the saved Apple Health queue could not be read; it was left untouched and nothing was read"
        }
    }

    private func save(_ s: HealthAutoState) async throws {
        try await storage.save(try JSONEncoder.auto.encode(s))
    }

    /// For fields that do not matter if one save fails (times, problem text): the next run writes them again.
    private func persistBestEffort() async { try? await save(state) }
}

extension JSONEncoder {
    fileprivate static var auto: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    fileprivate static var auto: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
