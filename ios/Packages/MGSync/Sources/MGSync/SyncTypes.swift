import Foundation
import MGDomain

// Public vocabulary of MGSync (ARCHITECTURE.md 5.7, 5.9). SyncStatus / SyncState / OutboxDrop / DeliverySummary live in
// MGDomain (BRIEF "Interface clarifications"); they are not redefined here.

/// Why a sync is running (ARCHITECTURE.md 5.7).
public enum SyncTrigger: Sendable, Equatable {
    case foreground
    case pathChange
    case backgroundRefresh
    case bleWake
    case manual
    /// The `.rawupload` processing task: raw drops only, with a long budget (no days, streams or results). Since #74
    /// (2026-10-11, Mo: "upload always is fine") every other trigger sends raw drops too, on any connection outside
    /// Low Data Mode (MGDomain `RawUploadPolicy`); it used to be the only one (D11, Wi-Fi + charging).
    case rawUpload
}

/// The strap id that streams and raw drops are keyed by (BRIEF: `MGStore.primaryStrapId()`). MGStore already has this
/// exact method, so the app wires it with an empty extension: `extension MGStore: StrapIDSource {}`.
/// Nil = no strap seen yet: streams and raw drops are not built at all.
public protocol StrapIDSource: Sendable {
    func primaryStrapId() async throws -> StrapID?
}

/// Kept raw frames for `raw_<strap>_<from>_<to>` drops (D11; since #74 sent on any connection outside Low Data Mode). MGStore already has both methods (RawRetention.swift), so
/// the app wires it with `extension MGStore: RawExportSource {}`.
public protocol RawExportSource: Sendable {
    func pendingRawRanges() async throws -> [(from: Int64, to: Int64)]
    /// Uncompressed ARCHITECTURE.md 5.4 raw layout and the number of frames in it.
    func rawFramesFile(from: Int64, to: Int64) async throws -> (data: Data, frames: Int)
}

/// One drop the PC would not take, or that could not be built.
public struct DropFailure: Sendable, Equatable {
    public var dropId: String
    public var reason: String
    /// false = the PC refused it for a reason a retry will not change (it stays in the outbox, shown to Mo).
    public var retryable: Bool

    public init(dropId: String, reason: String, retryable: Bool) {
        self.dropId = dropId
        self.reason = reason
        self.retryable = retryable
    }
}

/// What one `SyncEngine.sync` did.
public struct SyncOutcome: Sendable, Equatable {
    public enum Result: String, Sendable, Equatable {
        /// Everything that was waiting is delivered.
        case synced
        /// The PC answered and there was nothing to send.
        case nothingToSend = "nothing_to_send"
        /// Some drops are delivered or waiting: a drop failed, or the time budget ran out.
        case partial
        /// The PC did not answer (Tailscale off, PC asleep, away).
        case offline
        case notSetUp = "not_set_up"
        /// 401 (pairing reset), 409 (version) or an unreadable Keychain: `SyncEngine.status` carries the sentence.
        case error
        /// Not attempted (Sample data is on, BLE wake inside the 60 min gap).
        case skipped
    }

    public var result: Result
    /// Present when at least one drop was delivered (the SYNC_RECEIPT notification is built from it).
    public var delivered: DeliverySummary?
    public var failures: [DropFailure]
    public var resultsFetched: Int
    public var detail: String?
    /// Warnings the PC attached to stored drops (e.g. "day drop id hash X != Y" when the id rule has drifted between
    /// the two sides). The drops are delivered; these are for the log and the diagnostics screen.
    public var warnings: [String]
    /// Why raw strap frames did not go on this sync (Low Data Mode, no network); nil = they went or there were none.
    /// Added 2026-10-11 (#74) for the sync notice and Settings › Usage.
    public var rawHeld: String?

    public init(
        result: Result,
        delivered: DeliverySummary? = nil,
        failures: [DropFailure] = [],
        resultsFetched: Int = 0,
        detail: String? = nil,
        warnings: [String] = [],
        rawHeld: String? = nil
    ) {
        self.rawHeld = rawHeld
        self.result = result
        self.delivered = delivered
        self.failures = failures
        self.resultsFetched = resultsFetched
        self.detail = detail
        self.warnings = warnings
    }
}

/// Plain-language sentences shown by the app (PLAN.md 2 states). One place, so tests and screens agree.
public enum SyncMessages {
    /// 401 on any authenticated call (ARCHITECTURE.md 5.2 step 4).
    public static let pairingReset = "Pairing was reset — pair again"
    public static let sampleMode = "Sample data is on, so nothing is sent to the PC"
    public static let notPaired = "Not paired with a PC Lab yet"
    public static let keychainUnreadable = "The pairing could not be read from the Keychain — pair again"

    public static func contractMismatch(pcMajor: String) -> String {
        "PC Lab speaks contract \(pcMajor).x; update one side"
    }

    public static func syncAPIMismatch(pc: String) -> String {
        "PC Lab speaks sync API \(pc); update one side"
    }

    public static func unreachable(_ pc: String?) -> String {
        "Can't reach \(pc ?? "the PC Lab") — is Tailscale on, and is the PC awake?"
    }
}

/// Errors thrown by `SyncEngine.pair` and the helpers. Sync itself never throws: it reports a `SyncOutcome`.
public enum SyncError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The pairing link points at a host that is not a Tailscale name or address (privacy: BRIEF "nothing leaves the
    /// phone except to Mo's own PC over Tailscale"). `pair(_:deviceName:allowAnyHost:)` can override.
    case hostNotAllowed(String)
    /// The PC refused the pairing code (wrong, used, or older than 10 minutes).
    case pairingRejected(String)
    /// Contract or sync API major version differs (409).
    case versionMismatch(String)
    /// 401 on an authenticated call.
    case pairingReset
    case unreachable(String)
    /// The PC answered with something that is not the documented shape.
    case unexpected(String)
    /// A file handed to the engine is not what ARCHITECTURE.md 5.4 says (so it is not sent).
    case badFile(String)
    case credentialStore(String)

    public var description: String {
        switch self {
        case .hostNotAllowed(let s), .pairingRejected(let s), .versionMismatch(let s), .unreachable(let s),
             .unexpected(let s), .badFile(let s), .credentialStore(let s):
            return s
        case .pairingReset:
            return SyncMessages.pairingReset
        }
    }

    public var errorDescription: String? { description }
}

extension Duration {
    /// Seconds as a Double (the engine's budget arithmetic).
    var totalSeconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Major part of a dotted version string ("0.4" -> "0"); "" when it is not a string with digits first.
enum VersionText {
    static func major(_ version: String?) -> String {
        guard let v = version?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return "" }
        return String(v.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}

/// What Settings > Strap & sync shows for the phone-to-PC half (P9734, 2026-10-14). Plain values; the app formats them
/// (12-hour Pacific times). Built by `SyncEngine.panel`.
public struct SyncPanel: Sendable, Equatable {
    public var state: SyncState
    public var pcName: String?
    /// The last full sync (everything delivered, results fetched).
    public var lastSuccess: Date?
    /// The last time the PC accepted a drop.
    public var lastAcceptedAt: Date?
    /// Drops the PC has not confirmed yet. They stay on the phone until it does.
    public var queueDrops: Int
    public var queueBytes: Int
    /// Bytes the PC has confirmed since pairing.
    public var bytesDelivered: Int
    /// Engineering detail (HTTP status, transport error), not a friendly sentence.
    public var lastError: String?
    public var lastErrorAt: Date?
    public var nextRetryAt: Date?
    public var consecutiveFailures: Int
    public var authFailures: Int
    public var authFailuresToRepair: Int
    public var needsRepair: Bool
    /// Non-nil when the PC has not accepted an upload for the stall threshold while something waits.
    public var stalledSince: Date?
    /// "PC not receiving since 2:21 AM"; nil when nothing is stuck.
    public var banner: String?
    /// T9988: "stopped, 2.4 MB left" after a sync that ran out of time or was interrupted; nil once a sync finishes.
    public var lastStop: String?
    public var lastStopAt: Date?
}

extension SyncMessages {
    /// "2.4 MB" / "340 KB" (decimal, like the PC's sizes).
    public static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(max(1, (bytes + 999) / 1000)) KB"
    }

    /// T9988: a sync that ended with work left says so: "stopped, 2.4 MB left".
    public static func stopped(leftBytes: Int) -> String {
        leftBytes > 0 ? "stopped, \(size(leftBytes)) left" : "stopped before the PC's results were fetched"
    }

    /// One rejected key is not a re-pair (P9734): "The PC did not accept this phone's key (1 of 3); trying again".
    public static func keyNotAcceptedYet(n: Int, of total: Int) -> String {
        "The PC did not accept this phone's key (\(n) of \(total)); trying again"
    }

    /// "PC not receiving since 2:21 AM" (12-hour, in `timeZone`, the phone's zone by default); a day name is added when it
    /// was not today.
    public static func pcNotReceiving(since: Date, now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        "PC not receiving since \(clock12(since, now: now, timeZone: timeZone))"
    }

    /// "2:21 AM" in `timeZone` (default: the phone's zone), or "Tue 2:21 AM" when `date` is not on the same day as `now`.
    public static func clock12(_ date: Date, now: Date, timeZone tz: TimeZone = .autoupdatingCurrent) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }
}
