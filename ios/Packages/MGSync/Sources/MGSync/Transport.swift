import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request to the PC Lab (ARCHITECTURE.md 5.3). `path` is already percent-encoded and starts with `/v1/`.
public struct PCRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    /// Hup2 (Nov 6 2026): put on a background upload task (`URLSessionTask.taskDescription`) so the caller of a POST can be
    /// identified after the caller is gone: by the late-completion callback and the in-flight list of `BackgroundUploadTransport`.
    public var taskDescription: String?

    public init(method: String, path: String, query: [URLQueryItem] = [], headers: [String: String] = [:],
                body: Data? = nil, timeout: TimeInterval = 30, taskDescription: String? = nil) {
        self.taskDescription = taskDescription
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct PCResponse: Sendable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The request never produced an HTTP answer. (An HTTP error status is a `PCResponse`, not an error.)
public enum TransportError: Error, Equatable, CustomStringConvertible {
    case timeout
    /// DNS failure, connection refused or lost, no route (Tailscale off), TLS failure.
    case unreachable(String)
    /// The host NAME did not resolve (NSURLErrorCannotFindHost -1003 / DNSLookupFailed -1006): with a MagicDNS name this
    /// usually means the Tailscale tunnel is not up yet. `AddressFallbackTransport` retries against the PC's 100.x address.
    case dnsFailure(String)

    public var description: String {
        switch self {
        case .timeout: return "timed out"
        case .unreachable(let s), .dnsFailure(let s): return s
        }
    }
}

/// The only thing the sync engine needs from the network. `URLSessionPCLabTransport` is the real one; tests replay the
/// PC's documented responses with a stub (Tests/MGSyncTests/FakePCLab.swift). The transport adds no credentials: the
/// engine puts `Authorization: Bearer <device key>` in `headers`.
public protocol PCLabTransport: Sendable {
    func send(_ request: PCRequest, baseURL: URL) async throws -> PCResponse
}

/// URLSession over the Tailscale tunnel.
/// - Ephemeral configuration: no cookies, no cache, no credential storage on disk.
/// - Redirects are refused (the 3xx comes back as the answer): a redirect must never carry the device key to another
///   host.
/// - Route B is plain `http://<pc>:18787`; that needs `NSAllowsLocalNetworking` in Info.plist (WP-03) and nothing here.
public final class URLSessionPCLabTransport: PCLabTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate = RefuseRedirects()

    public init(configuration: URLSessionConfiguration? = nil) {
        let c = configuration ?? URLSessionConfiguration.ephemeral
        #if !canImport(FoundationNetworking)
        c.waitsForConnectivity = false      // (not settable in swift-corelibs-foundation: the Linux test build)
        #endif
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForResource = 15 * 60
        session = URLSession(configuration: c)
    }

    public func send(_ request: PCRequest, baseURL: URL) async throws -> PCResponse {
        let req = try request.urlRequest(baseURL: baseURL)

        do {
            let result: (Data, URLResponse)
            if let body = request.body {
                result = try await session.upload(for: req, from: body, delegate: delegate)
            } else {
                result = try await session.data(for: req, delegate: delegate)
            }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse else {
                throw TransportError.unreachable("the answer was not HTTP")
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
            }
            return PCResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw TransportError.from(error)
        }
    }
}

extension PCRequest {
    /// The URLRequest for this request against `baseURL` (shared by the foreground and the background transports).
    func urlRequest(baseURL: URL) throws -> URLRequest {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        guard var comps = URLComponents(string: text + path) else {
            throw TransportError.unreachable("bad URL \(text)\(path)")
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw TransportError.unreachable("bad URL \(text)\(path)") }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }
}

extension TransportError {
    static func from(_ error: URLError) -> TransportError {
        switch error.code {
        case .timedOut:
            return .timeout
        case .cannotFindHost, .dnsLookupFailed:
            return .dnsFailure(error.localizedDescription)
        default:
            return .unreachable(error.localizedDescription)
        }
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
