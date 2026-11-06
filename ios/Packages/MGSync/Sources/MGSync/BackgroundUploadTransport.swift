import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// T83: file uploads (PUT with a body) go through an iOS background URLSession, so a transfer that is under way keeps
/// going after the app is suspended. Everything else (health probe, commits' GETs, results) uses `fallback`: a
/// background session cannot run data tasks.
///
/// - Body is written to a temp file first (background sessions upload from files only); the copy is removed when the
///   task ends. A body the PC already received but whose answer arrived after the app was killed is simply sent again
///   at the next sync (the PC's PUT is idempotent by sha256; delivery is still decided by the commit's receipts, 5.5).
/// - Same rules as `URLSessionPCLabTransport`: no cache, no cookies, redirects refused (the device key never follows a
///   redirect), HTTP error statuses are answers.
/// - Not covered by tests (device check): a real `.background(withIdentifier:)` session, an upload that finishes while
///   the app is suspended, and `handleEventsForBackgroundURLSession` (see `eventsCompletion`).
public final class BackgroundUploadTransport: PCLabTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: UploadDelegate
    private let fallback: any PCLabTransport
    private let tempDirectory: URL
    private let backgroundPostPaths: Set<String>

    /// `configuration` is `.background(withIdentifier:)` in the app; tests pass an ephemeral one with a stub server.
    /// `backgroundPostPaths` (Nov 5 2026): POSTs with a body to these paths (the Apple Health upload, `/v1/health-samples`)
    /// also go through the background session, so they finish after the 20-second wake ends. For these, cancelling the caller
    /// (the run's time limit) releases the caller but leaves the transfer running; the PC dedups a body that is sent again.
    public init(configuration: URLSessionConfiguration, fallback: any PCLabTransport,
                tempDirectory: URL = FileManager.default.temporaryDirectory, backgroundPostPaths: Set<String> = []) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 15 * 60
        let d = UploadDelegate()
        delegate = d
        session = URLSession(configuration: configuration, delegate: d, delegateQueue: nil)
        self.fallback = fallback
        self.tempDirectory = tempDirectory
        self.backgroundPostPaths = backgroundPostPaths
        Self.sweepStaleCopies(in: tempDirectory)
    }

    /// A transfer that ends after the app was relaunched has no caller left to remove its staged copy; copies older than a
    /// day are removed here (a recent one may still be uploading).
    static func sweepStaleCopies(in dir: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("mgupload-") {
            let url = dir.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if let modified, now.timeIntervalSince(modified) > 86_400 { try? fm.removeItem(at: url) }
        }
    }

    #if !canImport(FoundationNetworking)
    /// The app's configuration: one named background session, woken for its own events (Apple platforms only).
    public static func appConfiguration(identifier: String) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.background(withIdentifier: identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        return c
    }
    #endif

    /// The system's completion handler from `handleEventsForBackgroundURLSession`; called once iOS has delivered every
    /// queued event (on the main queue).
    public var eventsCompletion: (@Sendable () -> Void)? {
        get { delegate.eventsCompletion }
        set { delegate.eventsCompletion = newValue }
    }

    /// Hup2 (Nov 6 2026): called when a transfer ends with an HTTP answer and nobody was waiting for it (the caller was
    /// released at the run's time limit, or the app was relaunched since): `(task description, HTTP status)`. A call made
    /// before this is set is held and delivered when it is set, so an answer that arrives at launch is not lost.
    public var onLateCompletion: (@Sendable (String, Int) -> Void)? {
        get { delegate.onLateCompletion }
        set { delegate.setLateCompletion(newValue) }
    }

    /// Task descriptions of the transfers still running (also those of an earlier launch: the session keeps them). Used to
    /// not stage a second POST of a body that is already on its way.
    public func inFlightDescriptions() async -> Set<String> {
        await withCheckedContinuation { (cont: CheckedContinuation<Set<String>, Never>) in
            session.getAllTasks { tasks in
                cont.resume(returning: Set(tasks.compactMap { t in
                    (t.state == .running || t.state == .suspended) ? t.taskDescription : nil
                }))
            }
        }
    }

    public func send(_ request: PCRequest, baseURL: URL) async throws -> PCResponse {
        let detach = request.method == "POST" && backgroundPostPaths.contains(request.path)
        guard let body = request.body, request.method == "PUT" || detach else {
            return try await fallback.send(request, baseURL: baseURL)
        }
        let req = try request.urlRequest(baseURL: baseURL)
        let file = tempDirectory.appendingPathComponent("mgupload-\(UUID().uuidString)")
        do { try body.write(to: file) } catch { throw TransportError.unreachable("could not stage the upload: \(error)") }

        let delegate = self.delegate
        // A PUT is cancelled with its caller; a listed POST is only detached (the caller is released, the transfer goes on).
        let handle = TaskHandle { task in
            if detach { delegate.detach(task.taskIdentifier) } else { task.cancel() }
        }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PCResponse, Error>) in
                    let task = session.uploadTask(with: req, fromFile: file)
                    task.taskDescription = request.taskDescription
                    delegate.register(task.taskIdentifier, file: file, continuation: cont)
                    handle.set(task)
                    task.resume()
                }
            } onCancel: {
                handle.cancel()
            }
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw TransportError.from(error)
        }
    }
}

private final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    private let onCancel: (URLSessionTask) -> Void

    init(onCancel: @escaping (URLSessionTask) -> Void) { self.onCancel = onCancel }

    func set(_ t: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        task = t
        if cancelled { onCancel(t) }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let task { onCancel(task) }
    }
}

private final class UploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var file: URL
        /// nil once the caller was released (`detach`): the transfer goes on, nobody waits for its answer.
        var continuation: CheckedContinuation<PCResponse, Error>?
        var body = Data()
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    var eventsCompletion: (@Sendable () -> Void)?
    private var lateHandler: (@Sendable (String, Int) -> Void)?
    private var lateHeld: [(String, Int)] = []

    var onLateCompletion: (@Sendable (String, Int) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return lateHandler
    }

    func setLateCompletion(_ handler: (@Sendable (String, Int) -> Void)?) {
        lock.lock()
        lateHandler = handler
        let held = handler == nil ? [] : lateHeld
        if handler != nil { lateHeld = [] }
        lock.unlock()
        for (d, s) in held { handler?(d, s) }
    }

    private func reportLate(_ task: URLSessionTask, error: Error?) {
        guard error == nil, let http = task.response as? HTTPURLResponse,
              let description = task.taskDescription, !description.isEmpty else { return }
        lock.lock()
        let handler = lateHandler
        if handler == nil { lateHeld.append((description, http.statusCode)) }
        lock.unlock()
        handler?(description, http.statusCode)
    }

    func register(_ id: Int, file: URL, continuation: CheckedContinuation<PCResponse, Error>) {
        lock.lock(); defer { lock.unlock() }
        pending[id] = Pending(file: file, continuation: continuation)
    }

    /// Releases the caller of task `id` with CancellationError and leaves the transfer running; the staged copy is still
    /// removed when the task ends.
    func detach(_ id: Int) {
        lock.lock()
        let cont = pending[id]?.continuation
        pending[id]?.continuation = nil
        lock.unlock()
        cont?.resume(throwing: CancellationError())
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending[dataTask.taskIdentifier]?.body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let entry else {      // finished after a relaunch: no caller is waiting; report the answer by its description
            reportLate(task, error: error)
            return
        }
        try? FileManager.default.removeItem(at: entry.file)
        guard let continuation = entry.continuation else {      // detached: the caller was released already
            reportLate(task, error: error)
            return
        }
        if let error {
            continuation.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse {
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
            }
            continuation.resume(returning: PCResponse(status: http.statusCode, headers: headers, body: entry.body))
        } else {
            continuation.resume(throwing: TransportError.unreachable("the answer was not HTTP"))
        }
    }

    #if !canImport(FoundationNetworking)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in self?.eventsCompletion?() }
    }
    #endif
}
