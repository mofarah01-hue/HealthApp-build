import Foundation
import MGDomain

/// The commit body of POST /v1/drops/{id}/commit (ARCHITECTURE.md 5.4; schema `syncManifest` in
/// app/shared/contract/sync-api.schema.json). Dates are written as RFC 3339 text in the phone's time zone.
/// `strap_ts_start` / `strap_ts_end` are written as explicit `null` for day drops, as in the §5.4 example.
public struct SyncManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var bytes: Int
        public var sha256: String
        public var records: Int
        public var media: String

        public init(name: String, bytes: Int, sha256: String, records: Int, media: String) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
            self.records = records
            self.media = media
        }
    }

    public var syncAPI: String
    public var contractVersion: String
    public var dropId: String
    public var kind: DropKind
    /// A day drop: exactly summary.json's `strap_id`, which is "unknown" before any strap was seen (BRIEF rule).
    /// Streams and raw: `MGStore.primaryStrapId()`, never "unknown".
    public var strapId: String
    public var localDate: String
    public var rangeStart: String
    public var rangeEnd: String
    public var strapTsStart: Int64?
    public var strapTsEnd: Int64?
    public var generatedAt: String
    public var appVersion: String
    public var files: [File]
    /// The phone's IANA zone for `localDate` (round 8, audit 4.6): the PC files and words the day in it. Optional and
    /// additive; written on day drops only, and left out when nil so older PCs see the manifest they always saw.
    public var tz: String?

    enum CodingKeys: String, CodingKey {
        case syncAPI = "sync_api"
        case contractVersion = "contract_version"
        case dropId = "drop_id"
        case kind
        case strapId = "strap_id"
        case localDate = "local_date"
        case rangeStart = "range_start"
        case rangeEnd = "range_end"
        case strapTsStart = "strap_ts_start"
        case strapTsEnd = "strap_ts_end"
        case generatedAt = "generated_at"
        case appVersion = "app_version"
        case files
        case tz
    }

    public init(syncAPI: String = ContractInfo.syncAPI, contractVersion: String = ContractInfo.version,
                dropId: String, kind: DropKind, strapId: String, localDate: String, rangeStart: String,
                rangeEnd: String, strapTsStart: Int64?, strapTsEnd: Int64?, generatedAt: String, appVersion: String,
                files: [File], tz: String? = nil) {
        self.syncAPI = syncAPI
        self.contractVersion = contractVersion
        self.dropId = dropId
        self.kind = kind
        self.strapId = strapId
        self.localDate = localDate
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.strapTsStart = strapTsStart
        self.strapTsEnd = strapTsEnd
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.files = files
        self.tz = tz
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(syncAPI, forKey: .syncAPI)
        try c.encode(contractVersion, forKey: .contractVersion)
        try c.encode(dropId, forKey: .dropId)
        try c.encode(kind, forKey: .kind)
        try c.encode(strapId, forKey: .strapId)
        try c.encode(localDate, forKey: .localDate)
        try c.encode(rangeStart, forKey: .rangeStart)
        try c.encode(rangeEnd, forKey: .rangeEnd)
        if let v = strapTsStart { try c.encode(v, forKey: .strapTsStart) } else { try c.encodeNil(forKey: .strapTsStart) }
        if let v = strapTsEnd { try c.encode(v, forKey: .strapTsEnd) } else { try c.encodeNil(forKey: .strapTsEnd) }
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(files, forKey: .files)
        try c.encodeIfPresent(tz, forKey: .tz)
    }
}

/// Turns what MGStore exports into `OutboxDrop`s: counts the records, hashes the bytes exactly as they will be
/// uploaded, computes the drop id, writes the manifest. Pure apart from `clock` and compression.
struct DropBuilder {
    let calendar: Calendar
    let appVersion: String
    let clock: any MGDomain.Clock
    let deflater: any Deflating

    private var timeZone: TimeZone { calendar.timeZone }

    private func iso(_ date: Date) -> String { RFC3339.format(date, timeZone: timeZone) }

    private func isoUTC(_ unix: Int64) -> String {
        RFC3339.format(Date(timeIntervalSince1970: Double(unix)), timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private func manifestData(_ manifest: SyncManifest) throws -> Data {
        try MGJSON.encoder().encode(manifest)
    }

    private func file(_ name: String, _ blob: Data, records: Int) -> OutboxFile {
        OutboxFile(name: name, bytes: blob.count, sha256: SyncHash.sha256Hex(blob), records: records, blob: blob)
    }

    private func media(_ name: String) -> String {
        if name.hasSuffix(".jsonl") { return "application/x-ndjson" }
        if name.hasSuffix(".json") { return "application/json" }
        return "application/octet-stream"
    }

    private func manifestFiles(_ files: [OutboxFile]) -> [SyncManifest.File] {
        files.map { SyncManifest.File(name: $0.name, bytes: $0.bytes, sha256: $0.sha256, records: $0.records,
                                      media: media($0.name)) }
    }

    /// A `day` drop: `summary.json`, `events.jsonl`, `series.json` byte for byte as MGStore exported them.
    func dayDrop(_ bundle: DayBundleFiles) throws -> OutboxDrop {
        let files = [
            file("events.jsonl", bundle.events, records: RecordCounter.jsonLines(bundle.events)),
            file("series.json", bundle.series, records: try RecordCounter.seriesCount(bundle.series)),
            file("summary.json", bundle.summary, records: try RecordCounter.summaryMetrics(bundle.summary)),
        ]
        let strapId = try RecordCounter.summaryStrapId(bundle.summary)
        let dropId = DropIDs.day(date: bundle.day, files: files.map { (name: $0.name, sha256: $0.sha256) })
        let dayStart = bundle.day.start(in: timeZone)
        let dayEnd = bundle.day.adding(days: 1).start(in: timeZone).addingTimeInterval(-1)
        let now = clock.now
        let manifest = SyncManifest(
            dropId: dropId, kind: .day, strapId: strapId, localDate: bundle.day.iso,
            rangeStart: iso(dayStart), rangeEnd: iso(dayEnd), strapTsStart: nil, strapTsEnd: nil,
            generatedAt: iso(now), appVersion: appVersion, files: manifestFiles(files), tz: timeZone.identifier)
        return OutboxDrop(dropId: dropId, kind: .day, localDay: bundle.day, manifest: try manifestData(manifest),
                          files: files, createdAt: now)
    }

    /// A `streams` drop for one `(kind, from, to)` offered by `pendingStreamRanges()`: `<kind>.csv.deflate`.
    func streamsDrop(strapId: StrapID, kind: StreamKind, from: Int64, to: Int64, csv: Data) throws -> OutboxDrop {
        let rows = try RecordCounter.csvRows(csv, kind: kind)
        let compressed = try deflater.deflate(csv)
        let files = [file("\(kind.rawValue).csv.deflate", compressed, records: rows)]
        let dropId = DropIDs.streams(strapId: strapId.raw, kind: kind, from: from, to: to)
        let localDay = LocalDay(date: Date(timeIntervalSince1970: Double(from)), calendar: calendar)
        let now = clock.now
        let manifest = SyncManifest(
            dropId: dropId, kind: .streams, strapId: strapId.raw, localDate: localDay.iso,
            rangeStart: isoUTC(from), rangeEnd: isoUTC(to), strapTsStart: from, strapTsEnd: to,
            generatedAt: iso(now), appVersion: appVersion, files: manifestFiles(files))
        return OutboxDrop(dropId: dropId, kind: .streams, localDay: localDay, strapTsStart: from, strapTsEnd: to,
                          manifest: try manifestData(manifest), files: files, createdAt: now)
    }

    /// An `ecg` drop (T9821): `ecg_session.json` = the saved `EcgTrace` as JSON (raw signed counts, every packet with the
    /// phone's receive time), drop id `ecg_<event id>`. The manifest's `strap_id` is the strap that recorded it (or
    /// "unknown"); the PC reads the event id from the drop id. Range = first and last packet arrival.
    func ecgDrop(trace: EcgTrace, startedAt: Date) throws -> OutboxDrop {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(trace)
        let files = [file("ecg_session.json", json, records: 1)]
        let dropId = DropIDs.ecg(eventId: trace.eventId)
        let first = trace.packets.first.map { Date(timeIntervalSince1970: $0.receivedAt) } ?? startedAt
        let last = trace.packets.last.map { Date(timeIntervalSince1970: $0.receivedAt) } ?? startedAt
        let localDay = LocalDay(date: first, calendar: calendar)
        let now = clock.now
        let manifest = SyncManifest(
            dropId: dropId, kind: .ecg, strapId: trace.strapId?.raw ?? "unknown", localDate: localDay.iso,
            rangeStart: iso(first), rangeEnd: iso(last), strapTsStart: nil, strapTsEnd: nil,
            generatedAt: iso(now), appVersion: appVersion, files: manifestFiles(files), tz: timeZone.identifier)
        return OutboxDrop(dropId: dropId, kind: .ecg, localDay: localDay, manifest: try manifestData(manifest),
                          files: files, createdAt: now)
    }

    /// A `raw` drop: `frames.bin.deflate` (since 2026-10-11 every raw frame, not only kept ones; when it goes is the
    /// #74 gate, MGDomain `RawUploadPolicy` — it used to say "the caller decides Wi-Fi + charging").
    func rawDrop(strapId: StrapID, from: Int64, to: Int64, frames: Data, frameCount: Int) throws -> OutboxDrop {
        let compressed = try deflater.deflate(frames)
        let files = [file("frames.bin.deflate", compressed, records: frameCount)]
        let dropId = DropIDs.raw(strapId: strapId.raw, from: from, to: to)
        let localDay = LocalDay(date: Date(timeIntervalSince1970: Double(from)), calendar: calendar)
        let now = clock.now
        let manifest = SyncManifest(
            dropId: dropId, kind: .raw, strapId: strapId.raw, localDate: localDay.iso,
            rangeStart: isoUTC(from), rangeEnd: isoUTC(to), strapTsStart: from, strapTsEnd: to,
            generatedAt: iso(now), appVersion: appVersion, files: manifestFiles(files))
        return OutboxDrop(dropId: dropId, kind: .raw, localDay: localDay, strapTsStart: from, strapTsEnd: to,
                          manifest: try manifestData(manifest), files: files, createdAt: now)
    }
}
