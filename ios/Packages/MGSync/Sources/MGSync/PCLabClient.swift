import Foundation
import MGDomain

// The typed PC Lab API v1 (ARCHITECTURE.md 5.3). Written against app/pclab/mglab/{server,sync_api,auth}.py as read on
// 2026-10-11, not against the document alone: routes, status codes and JSON keys below are what that code does.

// MARK: - Wire models

/// A JSON string that may arrive as a number (`server_sync_api` is "1" today).
struct LooseString: Decodable, Equatable {
    var value: String

    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s; return }
        if let i = try? c.decode(Int.self) { value = String(i); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected a string or a number")
    }
}

/// GET /v1/health -> 200.
struct HealthInfo: Decodable, Equatable {
    var ok: Bool
    var serverVersion: String?
    var contractVersion: String
    var syncAPI: String
    var pcName: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case serverVersion = "server_version"
        case contractVersion = "contract_version"
        case syncAPI = "sync_api"
        case pcName = "pc_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        serverVersion = try c.decodeIfPresent(String.self, forKey: .serverVersion)
        contractVersion = try c.decode(String.self, forKey: .contractVersion)
        syncAPI = try c.decode(LooseString.self, forKey: .syncAPI).value
        pcName = try c.decodeIfPresent(String.self, forKey: .pcName)
    }
}

/// POST /v1/pair -> 200 (`auth.redeem` result + `pc_name`, `server_version`, `contract_version`, `sync_api`).
struct PairResponse: Decodable {
    var deviceId: String
    var deviceKey: String
    var pcName: String?
    var contractVersion: String?
    var syncAPI: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceKey = "device_key"
        case pcName = "pc_name"
        case contractVersion = "contract_version"
        case syncAPI = "sync_api"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        deviceKey = try c.decode(String.self, forKey: .deviceKey)
        pcName = try c.decodeIfPresent(String.self, forKey: .pcName)
        contractVersion = try c.decodeIfPresent(String.self, forKey: .contractVersion)
        syncAPI = try c.decodeIfPresent(LooseString.self, forKey: .syncAPI)?.value
    }
}

struct PairRequest: Encodable {
    var token: String
    var deviceName: String
    var appVersion: String
    var contractVersion: String
    var syncAPI: String

    enum CodingKeys: String, CodingKey {
        case token
        case deviceName = "device_name"
        case appVersion = "app_version"
        case contractVersion = "contract_version"
        case syncAPI = "sync_api"
    }
}

/// PUT /v1/drops/{id}/files/{name} -> 201 (new) or 200 (`duplicate: true`).
struct PutResponse: Decodable {
    var receipt: SyncReceipt
    var duplicate: Bool?
}

/// POST /v1/drops/{id}/commit -> 200, and GET /v1/drops/{id} -> 200 for a committed drop.
struct CommitResponse: Decodable {
    var dropId: String
    var status: String
    var receipts: [SyncReceipt]
    var warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case dropId = "drop_id"
        case status
        case receipts
        case warnings
    }
}

/// One entry of GET /v1/results?since=<seq>.
struct ResultItem: Decodable, Equatable {
    var seq: Int
    var date: String
    var modelId: String
    var modelVersion: String
    var inputsHash: String?
    var name: String
    var bytes: Int
    var sha256: String
    var status: String?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case seq, date, name, bytes, sha256, status, reason
        case modelId = "model_id"
        case modelVersion = "model_version"
        case inputsHash = "inputs_hash"
    }
}

struct ResultsIndex: Decodable {
    var seq: Int
    var items: [ResultItem]
    /// T9809: metric name -> primary source, from the PC's versions/primary.json. nil = an older PC without it.
    var primary: [String: String]?
    var primaryProblem: String?

    enum CodingKeys: String, CodingKey {
        case seq, items, primary
        case primaryProblem = "primary_problem"
    }
}

/// Round 8 (audit top-25 #22): one page of GET /v1/results/bundle (pclab/docs/RESULTS-BUNDLE.md). `items` are the index
/// items with the file content riding along; the content is not decoded here (`ResultsBundlePage.contents` gives each
/// item's labResult JSON as bytes, so one unreadable file cannot make the whole page unreadable).
struct ResultsBundlePage: Decodable {
    var seq: Int
    var items: [ResultItem]
    var complete: Bool
    var nextSince: Int
    var bytes: Int?
    var primary: [String: String]?
    var primaryProblem: String?
    var missingFiles: Int?

    enum CodingKeys: String, CodingKey {
        case seq, items, complete, bytes, primary
        case nextSince = "next_since"
        case primaryProblem = "primary_problem"
        case missingFiles = "missing_files"
    }

    /// Each item's `content` object re-encoded as JSON bytes, in item order; nil where an item has none.
    static func contents(of body: Data) -> [Data?] {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.map { item in
            guard let content = item["content"], JSONSerialization.isValidJSONObject(content) else { return nil }
            return try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        }
    }
}

/// The error body every non-2xx answer carries: `{error, reason, ...extra}` (sync_api.py `ApiError.body`).
struct APIErrorBody: Decodable {
    var error: String?
    var reason: String?
    var errors: [String]?
    var staged: [String]?
    /// T9988: file name -> sha256 of what the PC already holds of an uncommitted drop (sync_api.py `get_drop`). Nil from
    /// an older PC Lab: then the whole drop is sent again.
    var stagedFiles: [String: String]?
    var missing: [String]?
    var serverContractVersion: String?
    var serverSyncAPI: String?

    enum CodingKeys: String, CodingKey {
        case error, reason, errors, staged, missing
        case stagedFiles = "staged_files"
        case serverContractVersion = "server_contract_version"
        case serverSyncAPI = "server_sync_api"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        errors = try? c.decodeIfPresent([String].self, forKey: .errors)
        staged = try? c.decodeIfPresent([String].self, forKey: .staged)
        stagedFiles = try? c.decodeIfPresent([String: String].self, forKey: .stagedFiles)
        missing = try? c.decodeIfPresent([String].self, forKey: .missing)
        serverContractVersion = try? c.decodeIfPresent(String.self, forKey: .serverContractVersion)
        serverSyncAPI = (try? c.decodeIfPresent(LooseString.self, forKey: .serverSyncAPI))?.value
    }
}

/// An HTTP answer with helpers to read it.
struct APIReply {
    var status: Int
    var body: Data

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            return try MGJSON.decoder().decode(type, from: body)
        } catch {
            throw SyncError.unexpected("The PC Lab sent a reply the app cannot read (HTTP \(status): \(error))")
        }
    }

    var apiError: APIErrorBody? { try? JSONDecoder().decode(APIErrorBody.self, from: body) }
}

// MARK: - Client

struct PCLabClient {
    let transport: any PCLabTransport
    let baseURL: URL
    /// Sent on authenticated routes only; health and pair never carry it (see `call`).
    let deviceKey: String?

    static func segment(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// `authenticated: false` for health and pair: the key must not go to whatever answers a reachability probe
    /// (2026-10-11, first CI run: SyncEngineTests L87 caught health carrying `Authorization` — the old code sent
    /// the key on every call whenever the client had one).
    private func call(_ request: PCRequest, authenticated: Bool = true) async throws -> APIReply {
        var req = request
        if authenticated, let key = deviceKey { req.headers["Authorization"] = "Bearer \(key)" }
        let response = try await transport.send(req, baseURL: baseURL)
        return APIReply(status: response.status, body: response.body)
    }

    /// Reachability probe: 3 s (ARCHITECTURE.md 5.3).
    func health() async throws -> APIReply {
        try await call(PCRequest(method: "GET", path: "/v1/health", timeout: 3), authenticated: false)
    }

    func pair(token: String, deviceName: String, appVersion: String) async throws -> APIReply {
        let body = try MGJSON.encoder().encode(PairRequest(token: token, deviceName: deviceName, appVersion: appVersion,
                                                           contractVersion: ContractInfo.version,
                                                           syncAPI: ContractInfo.syncAPI))
        return try await call(PCRequest(method: "POST", path: "/v1/pair",
                                        headers: ["Content-Type": "application/json"], body: body, timeout: 15),
                              authenticated: false)
    }

    func putFile(dropId: String, file: OutboxFile) async throws -> APIReply {
        try await call(PCRequest(
            method: "PUT",
            path: "/v1/drops/\(PCLabClient.segment(dropId))/files/\(PCLabClient.segment(file.name))",
            headers: ["X-MG-SHA256": file.sha256, "Content-Type": "application/octet-stream"],
            body: file.blob, timeout: 120))
    }

    /// PUT /v1/watch-files/<name> (0.6.0.10, watch/INTEGRATION.md): one .mgw recording the Watch sent the phone.
    /// PC Lab answers 201 stored, 200 duplicate, 422 broken file.
    func putWatchFile(name: String, data: Data, sha256: String) async throws -> APIReply {
        try await call(PCRequest(method: "PUT", path: "/v1/watch-files/\(PCLabClient.segment(name))",
                                 headers: ["X-MG-SHA256": sha256, "Content-Type": "application/octet-stream"],
                                 body: data, timeout: 120))
    }

    func commit(dropId: String, manifest: Data) async throws -> APIReply {
        try await call(PCRequest(method: "POST", path: "/v1/drops/\(PCLabClient.segment(dropId))/commit",
                                 headers: ["Content-Type": "application/json"], body: manifest, timeout: 60))
    }

    func drop(dropId: String) async throws -> APIReply {
        try await call(PCRequest(method: "GET", path: "/v1/drops/\(PCLabClient.segment(dropId))", timeout: 15))
    }

    func results(since: Int) async throws -> APIReply {
        try await call(PCRequest(method: "GET", path: "/v1/results",
                                 query: [URLQueryItem(name: "since", value: String(since))], timeout: 30))
    }

    /// GET /v1/results/bundle (round 8): the changed results with their files, `maxBytes` of content per page. A PC Lab
    /// without the route answers 404; the engine then falls back to `results` + `result` (one GET per file).
    func resultsBundle(since: Int, maxBytes: Int) async throws -> APIReply {
        try await call(PCRequest(method: "GET", path: "/v1/results/bundle",
                                 query: [URLQueryItem(name: "since", value: String(since)),
                                         URLQueryItem(name: "max_bytes", value: String(maxBytes))], timeout: 60))
    }

    /// PUT /v1/profile (wave 2, 2026-10-11): the contract `profile` as JSON.
    func putProfile(_ body: Data) async throws -> APIReply {
        try await call(PCRequest(method: "PUT", path: "/v1/profile", headers: ["Content-Type": "application/json"],
                                 body: body, timeout: 30))
    }

    /// GET /v1/profile (tracker #90, 2026-10-11; PCProfile.swift): the PC's merged profile with a source per field.
    func profile() async throws -> APIReply {
        try await call(PCRequest(method: "GET", path: "/v1/profile", timeout: 15))
    }

    func result(date: String, name: String) async throws -> APIReply {
        try await call(PCRequest(method: "GET",
                                 path: "/v1/results/\(PCLabClient.segment(date))/\(PCLabClient.segment(name))",
                                 timeout: 30))
    }

    /// T9819 (PCUsage.swift, PCLabAppStatus): the app's status blob for the PC's debug ping.
    func postAppStatus(_ body: Data) async throws -> APIReply {
        try await call(PCRequest(method: "POST", path: "/v1/app-status", headers: ["Content-Type": "application/json"],
                                 body: body, timeout: 10))
    }

    /// T10012 (PCDebug.swift): the remote debug channel. A long poll for commands the PC queued, and the answer to one.
    /// The request timeout is the wait plus a margin, so the PC's own hold-up is never cut short by the phone.
    func debugCommands(wait: Int) async throws -> APIReply {
        try await call(PCRequest(method: "GET", path: "/v1/debug/commands",
                                 query: [URLQueryItem(name: "wait", value: String(max(0, min(wait, 55))))],
                                 timeout: TimeInterval(max(0, min(wait, 55)) + 15)))
    }

    func postDebugResult(_ body: Data) async throws -> APIReply {
        try await call(PCRequest(method: "POST", path: "/v1/debug/results", headers: ["Content-Type": "application/json"],
                                 body: body, timeout: 60))
    }

    /// Settings › Usage (tracker #40; PCUsage.swift).
    func usage() async throws -> APIReply {
        try await call(PCRequest(method: "GET", path: "/v1/usage", timeout: 10))
    }

    /// T84 (PCTasks.swift): the open Jabarin tasks, a new task, and the day's stress total (an estimate).
    func tasks() async throws -> APIReply {
        try await call(PCRequest(method: "GET", path: "/v1/tasks", timeout: 15))
    }

    func createTask(_ body: Data) async throws -> APIReply {
        try await call(PCRequest(method: "POST", path: "/v1/tasks", headers: ["Content-Type": "application/json"],
                                 body: body, timeout: 15))
    }

    func postStressDay(_ body: Data) async throws -> APIReply {
        try await call(PCRequest(method: "POST", path: "/v1/stress-day", headers: ["Content-Type": "application/json"],
                                 body: body, timeout: 15))
    }

    /// T9993 (PCNightRun.swift): ask the PC to run a date's models now / where that date stands.
    func runNight(date: LocalDay) async throws -> APIReply {
        let body = Data("{\"date\":\"\(date.iso)\"}".utf8)
        return try await call(PCRequest(method: "POST", path: "/v1/run-night", headers: ["Content-Type": "application/json"],
                                        body: body, timeout: 15))
    }

    func runNightState(date: LocalDay) async throws -> APIReply {
        try await call(PCRequest(method: "GET", path: "/v1/run-night",
                                 query: [URLQueryItem(name: "date", value: date.iso)], timeout: 10))
    }

    /// GET /v1/history (tracker #7, 2026-10-11; PCHistory.swift): imported history for a range the phone does not keep.
    func history(from: LocalDay, to: LocalDay, names: [String]?, latest: Bool) async throws -> APIReply {
        var query = [URLQueryItem(name: "from", value: from.iso), URLQueryItem(name: "to", value: to.iso)]
        if let names, !names.isEmpty { query.append(URLQueryItem(name: "names", value: names.joined(separator: ","))) }
        if latest { query.append(URLQueryItem(name: "latest", value: "1")) }
        return try await call(PCRequest(method: "GET", path: "/v1/history", query: query, timeout: 60))
    }
}
