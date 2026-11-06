import Foundation
import MGDomain

// T10012: the phone's half of the remote debug channel (pclab/mglab/debug.py). GET /v1/debug/commands is a long poll: the PC
// answers at once when a command is queued, else after `wait` seconds with an empty list. The body is decoded by MGContext
// `RemoteDebug.decodeCommands` (this package does not depend on MGContext); the answers go back with `postResult`.
// Written against debug.py as read on 2026-10-17; pclab/tests/test_debug.py covers the PC side of each route.

public enum PCLabDebug {
    public enum PollReply: Equatable, Sendable {
        /// HTTP 200: the answer body (`{"commands": [...]}`).
        case body(Data)
        /// No PC paired on this phone.
        case notPaired
        /// No HTTP answer or a server error: Tailscale off, PC asleep, PC Lab not running. Worth retrying soon.
        case unreachable(String)
        /// The PC answered but cannot serve this (an older PC Lab without the route: 404; a revoked key: 401). Retry rarely.
        case unavailable(String)
    }

    /// One long poll (the request waits up to `wait` seconds + 15 s margin). Never throws.
    public static func poll(wait: Int, credentials: any CredentialStore,
                            transport: any PCLabTransport = URLSessionPCLabTransport()) async -> PollReply {
        let creds: PCCredentials?
        do { creds = try credentials.load() } catch { return .unavailable("The PC pairing couldn't be read: \(error)") }
        guard let creds else { return .notPaired }
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)
        do {
            let reply = try await client.debugCommands(wait: wait)
            switch reply.status {
            case 200: return .body(reply.body)
            case 401, 403, 404: return .unavailable(reply.apiError?.reason ?? "HTTP \(reply.status)")
            default: return .unreachable(reply.apiError?.reason ?? "HTTP \(reply.status)")
            }
        } catch let e as TransportError {
            return .unreachable(e.description)
        } catch is CancellationError {
            return .unreachable("cancelled")
        } catch {
            return .unreachable("\(error)")
        }
    }

    /// POST one answer. true = the PC has it, or no longer knows the command (404: expired or answered already; 409/400
    /// would not change by sending again), so the caller can forget it; false = try again later.
    public static func postResult(_ body: Data, credentials: any CredentialStore,
                                  transport: any PCLabTransport = URLSessionPCLabTransport()) async -> Bool {
        guard let creds = try? credentials.load() else { return false }
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)
        guard let reply = try? await client.postDebugResult(body) else { return false }
        return (200..<300).contains(reply.status) || [400, 404, 409, 413].contains(reply.status)
    }
}
