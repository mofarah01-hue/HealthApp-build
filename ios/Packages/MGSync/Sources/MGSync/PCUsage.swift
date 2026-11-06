import Foundation
import MGDomain

// Settings › Usage, the PC half (tracker #40, Mo 2026-10-11: "storage on my phone and desktop … compute desktop used
// or in use"). GET /v1/usage, written against app/pclab/mglab/usage.py as read on 2026-10-11; the keys below are that
// module's. app/shared/fixtures/pclab/usage.v1.json is the shared example: PCUsageTests decodes it here, and
// pclab/tests/test_usage.py checks every key of it against the live route, so a rename on either side fails a test.

/// GET /v1/usage → 200.
public struct PCUsageReport: Decodable, Equatable, Sendable {
    public struct Area: Decodable, Equatable, Sendable {
        /// raw · streams · days · results · imports · drops · logs · other (every byte in exactly one).
        public var id: String
        public var label: String
        public var bytes: Int64
        public var files: Int
    }

    public struct Disk: Decodable, Equatable, Sendable {
        public var totalBytes: Int64
        public var usedBytes: Int64
        public var freeBytes: Int64

        enum CodingKeys: String, CodingKey {
            case totalBytes = "total_bytes"
            case usedBytes = "used_bytes"
            case freeBytes = "free_bytes"
        }
    }

    public struct Storage: Decodable, Equatable, Sendable {
        /// The data folder's name only (its path never leaves the PC).
        public var dataDir: String?
        /// When the PC last walked the folder (it caches the walk for a minute).
        public var measuredAt: Date?
        public var totalBytes: Int64
        public var totalFiles: Int?
        public var areas: [Area]
        public var disk: Disk?

        enum CodingKeys: String, CodingKey {
            case dataDir = "data_dir"
            case measuredAt = "measured_at"
            case totalBytes = "total_bytes"
            case totalFiles = "total_files"
            case areas, disk
        }
    }

    public struct Process: Decodable, Equatable, Sendable {
        public var pid: Int?
        public var startedAt: Date?
        public var uptimeSeconds: Double
        public var cpuUserSeconds: Double
        public var cpuSystemSeconds: Double
        public var threads: Int?
        public var memoryBytes: Int64?

        enum CodingKeys: String, CodingKey {
            case pid, threads
            case startedAt = "started_at"
            case uptimeSeconds = "uptime_s"
            case cpuUserSeconds = "cpu_user_s"
            case cpuSystemSeconds = "cpu_system_s"
            case memoryBytes = "memory_bytes"
        }
    }

    public struct Job: Decodable, Equatable, Sendable {
        public var date: String?
        /// "<model_id>@<model_version>".
        public var model: String
        public var since: Date?
    }

    public struct Pipeline: Decodable, Equatable, Sendable {
        public var busy: Bool
        public var current: Job?
        public var queuedDates: [String]
        public var models: Int?
        public var loadErrors: [String]
        /// T9827: the PC's own sentence, e.g. "Last PC pass 1:31 PM: 184 ok, 338 skipped, 0 errors, next: ...".
        public var lastPassLine: String?

        enum CodingKeys: String, CodingKey {
            case busy, current, models
            case lastPassLine = "last_pass_line"
            case queuedDates = "queued_dates"
            case loadErrors = "load_errors"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            busy = try c.decode(Bool.self, forKey: .busy)
            current = try c.decodeIfPresent(Job.self, forKey: .current)
            queuedDates = try c.decodeIfPresent([String].self, forKey: .queuedDates) ?? []
            models = try c.decodeIfPresent(Int.self, forKey: .models)
            loadErrors = try c.decodeIfPresent([String].self, forKey: .loadErrors) ?? []
            lastPassLine = try c.decodeIfPresent(String.self, forKey: .lastPassLine)
        }
    }

    public struct Plugins: Decodable, Equatable, Sendable {
        /// The plugin watcher runs only under `python -m mglab serve`.
        public var watching: Bool
        public var intervalSeconds: Double?
        public var lastCheck: Date?
        public var running: [String]

        enum CodingKeys: String, CodingKey {
            case watching, running
            case intervalSeconds = "interval_s"
            case lastCheck = "last_check"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            watching = try c.decode(Bool.self, forKey: .watching)
            intervalSeconds = try c.decodeIfPresent(Double.self, forKey: .intervalSeconds)
            lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
            running = try c.decodeIfPresent([String].self, forKey: .running) ?? []
        }
    }

    public struct Running: Decodable, Equatable, Sendable {
        public var pipeline: Pipeline?
        public var plugins: Plugins?
    }

    /// When the PC answered.
    public var at: Date
    public var pcName: String?
    public var serverVersion: String?
    public var storage: Storage
    public var process: Process
    public var running: Running

    enum CodingKeys: String, CodingKey {
        case at, storage, process, running
        case pcName = "pc_name"
        case serverVersion = "server_version"
    }
}

public enum PCUsageResult: Equatable, Sendable {
    case report(PCUsageReport)
    /// No PC paired on this phone.
    case notPaired
    /// No HTTP answer: Tailscale off, PC asleep or PC Lab not running.
    case unreachable(String)
    /// An HTTP answer that is not a usage report, with the PC's reason.
    case refused(String)
}

public enum PCLabUsage {
    /// One GET /v1/usage with the paired device key (10 s). Never throws: every way it can fail is a case.
    public static func fetch(credentials: any CredentialStore,
                             transport: any PCLabTransport = URLSessionPCLabTransport()) async -> PCUsageResult {
        let creds: PCCredentials?
        do { creds = try credentials.load() } catch { return .refused("The PC pairing couldn't be read: \(error)") }
        guard let creds else { return .notPaired }
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)
        do {
            let reply = try await client.usage()
            return decode(status: reply.status, body: reply.body)
        } catch let e as TransportError {
            return .unreachable(e.description)
        } catch {
            return .unreachable("\(error)")
        }
    }

    static func decode(status: Int, body: Data) -> PCUsageResult {
        guard status == 200 else {
            let reason = APIReply(status: status, body: body).apiError?.reason
            if status == 404 { return .refused(reason.map { "This PC Lab has no usage page yet (\($0)) — restart it with the new code." }
                                                ?? "This PC Lab has no usage page yet — restart it with the new code.") }
            return .refused(reason ?? "HTTP \(status)")
        }
        do {
            return .report(try MGJSON.decoder().decode(PCUsageReport.self, from: body))
        } catch {
            return .refused("The PC's usage answer couldn't be read: \(error)")
        }
    }
}

/// T9819: the phone's debug ping. POST /v1/app-status with the small status blob (pclab/mglab/app_status.py stores it
/// and shows "no ping since <time>" when the phone stops). The blob is encoded by the caller (MGContext
/// `AppLifecycle.StatusBlob`). Never throws; true only when the PC answered 200.
public enum PCLabAppStatus {
    public static func post(_ body: Data, credentials: any CredentialStore,
                            transport: any PCLabTransport = URLSessionPCLabTransport()) async -> Bool {
        await postWithReply(body, credentials: credentials, transport: transport).ok
    }

    /// T10012: the same post, also handing back the PC's answer body (it may carry `pending_commands`: debug commands
    /// waiting for this phone; MGContext `RemoteDebug.pendingCommands(inStatusReply:)` reads it).
    public static func postWithReply(_ body: Data, credentials: any CredentialStore,
                                     transport: any PCLabTransport = URLSessionPCLabTransport()) async -> (ok: Bool, reply: Data) {
        guard let creds = try? credentials.load() else { return (false, Data()) }
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)
        guard let reply = try? await client.postAppStatus(body) else { return (false, Data()) }
        return (reply.status == 200, reply.body)
    }
}
