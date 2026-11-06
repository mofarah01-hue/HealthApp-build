import CryptoKit
import Foundation
import MGDomain

// The three id / hash rules the phone and the PC must compute identically. The rules are the ones approved in
// BRIEF.md "Interface clarifications" (WP-01); the PC's own copies are mglab/datastore.py `day_content_address` and
// `inputs_hash`, and the simulated phone in app/pclab/sim/phone_sim.py. Known answers for the fixture day are in
// Tests/MGSyncTests/HashingTests.swift (computed in Python and confirmed against a running PC Lab).

public enum SyncHash {
    /// Lowercase hex SHA-256.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    /// Plain string order, as Python's `sorted()` on `str`: by code point, which for UTF-8 is byte order. (Swift's own
    /// `<` on String compares by Unicode canonical equivalence, which can differ for non-ASCII; file names and hash
    /// lines here are ASCII, and this keeps it exact anyway.)
    static func byteOrder(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }
}

public enum DropIDs {
    /// `day_<date>_` + the first 16 hex of SHA-256 of the files' lowercase-hex SHA-256s **sorted by file name**, joined
    /// with `,` (no spaces), UTF-8. Content-addressed: same bytes, same id. A mismatch is only a warning on the PC.
    public static func day(date: LocalDay, files: [(name: String, sha256: String)]) -> String {
        let joined = files
            .sorted { SyncHash.byteOrder($0.name, $1.name) }
            .map { $0.sha256.lowercased() }
            .joined(separator: ",")
        return "day_\(date.iso)_" + String(SyncHash.sha256Hex(joined).prefix(16))
    }

    /// `streams_<strap_id>_<kind>_<strap_ts_start>_<strap_ts_end>`: keyed by strap timestamp (PLAN §2), the exact
    /// `(from, to)` from `MGStore.pendingStreamRanges()`.
    public static func streams(strapId: String, kind: StreamKind, from: Int64, to: Int64) -> String {
        "streams_\(strapId)_\(kind.rawValue)_\(from)_\(to)"
    }

    /// `raw_<strap_id>_<strap_ts_start>_<strap_ts_end>`.
    public static func raw(strapId: String, from: Int64, to: Int64) -> String {
        "raw_\(strapId)_\(from)_\(to)"
    }

    /// `ecg_<event id>` (T9821): one live-ECG session; the id is the saved reading's event id, so a retry is the same drop.
    public static func ecg(eventId: UUID) -> String {
        "ecg_\(eventId.uuidString)"
    }
}

public enum InputsHash {
    /// Lowercase-hex SHA-256 of the lines `<file name>:<sha256>`, plain string-sorted, joined with `\n`, no trailing
    /// newline, UTF-8. `name` is the file name as in the manifest (`summary.json`, `rr.csv.deflate`). Two stream drops
    /// of one kind have the same name and different hashes; both lines are kept.
    public static func compute(_ files: [(name: String, sha256: String)]) -> String {
        let lines = files
            .map { "\($0.name):\($0.sha256.lowercased())" }
            .sorted(by: SyncHash.byteOrder)
        return SyncHash.sha256Hex(lines.joined(separator: "\n"))
    }

    /// Is a PC result computed on what the phone has delivered? (ARCHITECTURE.md 5.6: "a result computed on older data
    /// shows 'PC · from <date> (older data)' and is never taken for current".)
    ///
    /// The PC's models pick their own inputs from what is stored for a date: the latest day version's files, the
    /// streams (all drops, all kinds), the raw files. A model may use any non-empty selection of those groups, so the
    /// result is `.current` when its `inputs_hash` equals the hash of some selection of the groups the phone has
    /// delivered for that date (at most 63 candidates: day, rr, hr, r18, strap_events, raw). A model that used an
    /// older day version, or a stream drop the phone has since superseded, matches none: `.olderData`.
    public static func freshness(resultHash: String?, delivered: DeliveredInputs) -> ResultFreshness {
        guard let wanted = resultHash?.lowercased(), !wanted.isEmpty else { return .unknown }
        let keys = delivered.groups.filter { !$0.value.isEmpty }.keys.sorted()
        guard !keys.isEmpty else { return .unknown }
        for mask in 1..<(1 << keys.count) {
            var files: [(name: String, sha256: String)] = []
            for (i, key) in keys.enumerated() where mask & (1 << i) != 0 {
                files += (delivered.groups[key] ?? []).map { (name: $0.name, sha256: $0.sha256) }
            }
            if compute(files) == wanted { return .current }
        }
        return .olderData
    }
}

public enum ResultFreshness: String, Sendable, Equatable {
    /// The result's inputs are what the PC holds from this phone now.
    case current
    /// Computed on data the phone has since replaced or added to.
    case olderData = "older_data"
    /// No hash on the result, or nothing delivered for that date is known to this phone (e.g. a fresh install).
    case unknown
}

/// What the phone delivered for one local date, grouped the way the PC groups model inputs.
public struct DeliveredInputs: Equatable, Sendable {
    /// "day" (latest version's three files), "rr" / "hr" / "r18" / "strap_events" (every stream drop of that kind), "raw".
    public var groups: [String: [LedgerFile]]

    public init(groups: [String: [LedgerFile]] = [:]) { self.groups = groups }
}

/// One delivered file: its manifest name and sha256 of the bytes as uploaded.
public struct LedgerFile: Codable, Hashable, Sendable {
    public var name: String
    public var sha256: String

    public init(name: String, sha256: String) {
        self.name = name
        self.sha256 = sha256
    }
}

// MARK: - Records

/// The `records` number of a manifest file and of its receipt: metrics in a summary, lines in a jsonl, data rows in a
/// CSV, frames in a raw file, series in series.json (ARCHITECTURE.md 5.4). Same counting as the PC's `inspect_*`
/// (datastore.py), which the phone's number is compared with.
enum RecordCounter {
    private static func object(_ data: Data, _ what: String) throws -> [String: Any] {
        do {
            guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SyncError.badFile("\(what): the top level is not a JSON object")
            }
            return o
        } catch let e as SyncError {
            throw e
        } catch {
            throw SyncError.badFile("\(what): not JSON (\(error))")
        }
    }

    /// `metrics` of summary.json.
    static func summaryMetrics(_ data: Data) throws -> Int {
        guard let metrics = try object(data, "summary.json")["metrics"] as? [Any] else {
            throw SyncError.badFile("summary.json: `metrics` is not an array")
        }
        return metrics.count
    }

    /// `strap_id` of summary.json: "unknown" before any strap was seen, else `s_` + 16 hex (BRIEF rule).
    static func summaryStrapId(_ data: Data) throws -> String {
        guard let id = try object(data, "summary.json")["strap_id"] as? String else {
            throw SyncError.badFile("summary.json: `strap_id` is missing")
        }
        guard id == "unknown" || isStrapId(id) else {
            throw SyncError.badFile("summary.json: strap_id \"\(id)\" is neither \"unknown\" nor s_ + 16 hex")
        }
        return id
    }

    static func isStrapId(_ id: String) -> Bool {
        let b = Array(id.utf8)
        guard b.count == 18, b[0] == 0x73, b[1] == 0x5F else { return false }       // "s_"
        return b[2...].allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// `series` of series.json.
    static func seriesCount(_ data: Data) throws -> Int {
        guard let series = try object(data, "series.json")["series"] as? [Any] else {
            throw SyncError.badFile("series.json: `series` is not an array")
        }
        return series.count
    }

    /// Lines of events.jsonl that are not blank (blank = empty or only spaces / tabs / CR, as the PC skips them).
    static func jsonLines(_ data: Data) -> Int {
        data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .filter { line in !line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D } }
            .count
    }

    /// Data rows of a stream CSV: non-empty lines after the header. Throws when the header is not the one
    /// ARCHITECTURE.md 5.4 fixes for `kind` (the PC would answer 422 `bad_format`).
    static func csvRows(_ data: Data, kind: StreamKind) throws -> Int {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard let first = lines.first, String(decoding: first, as: UTF8.self) == kind.csvHeader else {
            throw SyncError.badFile("\(kind.rawValue).csv: header is not \"\(kind.csvHeader)\"")
        }
        return lines.dropFirst().filter { !$0.isEmpty }.count
    }
}

// MARK: - Compression

/// Raw DEFLATE (RFC 1951): what the PC reads with `zlib.decompress(b, -15)` (ARCHITECTURE.md 5.4).
public protocol Deflating: Sendable {
    func deflate(_ data: Data) throws -> Data
}

/// `(data as NSData).compressed(using: .zlib)`. Apple's `.zlib` algorithm writes a raw DEFLATE stream (no zlib header),
/// which is the shape ARCHITECTURE.md 5.4 requires. NOT checked on a device from here: if it were wrong the PC answers
/// 422 `bad_format` ("not raw DEFLATE") and the outbox keeps the drop, so the failure is loud (see the report).
public struct RawDeflate: Deflating {
    public init() {}

    public func deflate(_ data: Data) throws -> Data {
        do {
            return try (data as NSData).compressed(using: .zlib) as Data
        } catch {
            throw SyncError.badFile("compression failed (\(error))")
        }
    }
}
