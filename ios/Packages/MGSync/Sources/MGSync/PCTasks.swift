import Foundation

// T84: tasks from the Jabarin dashboard and the day's stress total, through the PC Lab (pclab/mglab/jabarin_link.py:
// GET and POST /v1/tasks, POST /v1/stress-day). The bodies are built and read by MGContext `JabarinLink`; this file only
// carries bytes, so MGSync needs no new dependency.

public enum PCTasksResult: Equatable, Sendable {
    /// The PC's answer body (200 or 201).
    case body(Data)
    /// No PC paired on this phone.
    case notPaired
    /// No HTTP answer: Tailscale off, PC asleep or PC Lab not running.
    case unreachable(String)
    /// The PC answered with a refusal; its reason names the cause (Jabarin not running, read only, a bad field).
    case refused(String)
}

public enum PCLabTasks {
    /// GET /v1/tasks.
    public static func fetch(credentials: any CredentialStore,
                             transport: any PCLabTransport = URLSessionPCLabTransport()) async -> PCTasksResult {
        await run(credentials, transport) { try await $0.tasks() }
    }

    /// POST /v1/tasks: one new task (`JabarinLink.newTaskBody`).
    public static func create(_ body: Data, credentials: any CredentialStore,
                              transport: any PCLabTransport = URLSessionPCLabTransport()) async -> PCTasksResult {
        await run(credentials, transport) { try await $0.createTask(body) }
    }

    /// POST /v1/stress-day: the day's stress total (`JabarinLink.stressBody`).
    public static func postStress(_ body: Data, credentials: any CredentialStore,
                                  transport: any PCLabTransport = URLSessionPCLabTransport()) async -> PCTasksResult {
        await run(credentials, transport) { try await $0.postStressDay(body) }
    }

    private static func run(_ credentials: any CredentialStore, _ transport: any PCLabTransport,
                            _ call: (PCLabClient) async throws -> APIReply) async -> PCTasksResult {
        let creds: PCCredentials?
        do { creds = try credentials.load() } catch { return .refused("The PC pairing couldn't be read: \(error)") }
        guard let creds else { return .notPaired }
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)
        do {
            let reply = try await call(client)
            guard (200...201).contains(reply.status) else {
                return .refused(reply.apiError?.reason ?? "HTTP \(reply.status)")
            }
            return .body(reply.body)
        } catch let e as TransportError {
            return .unreachable(e.description)
        } catch {
            return .unreachable("\(error)")
        }
    }
}
