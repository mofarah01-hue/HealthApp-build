import Foundation
import MGDomain

// T9993: the phone asks the PC to run one date's models right away (pclab/mglab/sync_api.py `run_night`, POST and GET
// /v1/run-night). Without it the PC's daily models wait until the uploads of that date have been quiet for about 10 minutes,
// which is longer than the time Mo wants between waking and seeing the PC's numbers.

public enum PCNightRun {
    public enum Result: Equatable, Sendable {
        /// The PC's state for the date: "running", "queued", "waiting" or "idle" (nothing left to run).
        case state(String)
        /// No PC paired on this phone.
        case notPaired
        /// No HTTP answer: Tailscale off, PC asleep or PC Lab not running.
        case unreachable(String)
        /// The date is not stored on the PC (upload first).
        case notStored
        /// The PC refused; its reason names the cause. An older PC Lab without the route answers 404 `not_found`.
        case refused(String)
    }

    /// POST /v1/run-night for `date`.
    public static func request(date: LocalDay, credentials: any CredentialStore,
                               transport: any PCLabTransport = URLSessionPCLabTransport()) async -> Result {
        await run(credentials, transport) { try await $0.runNight(date: date) }
    }

    /// GET /v1/run-night?date=...
    public static func state(date: LocalDay, credentials: any CredentialStore,
                             transport: any PCLabTransport = URLSessionPCLabTransport()) async -> Result {
        await run(credentials, transport) { try await $0.runNightState(date: date) }
    }

    private struct StateBody: Decodable { var state: String }

    private static func run(_ credentials: any CredentialStore, _ transport: any PCLabTransport,
                            _ call: (PCLabClient) async throws -> APIReply) async -> Result {
        let creds: PCCredentials?
        do { creds = try credentials.load() } catch { return .refused("The PC pairing couldn't be read: \(error)") }
        guard let creds else { return .notPaired }
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)
        do {
            let reply = try await call(client)
            if reply.status == 404, reply.apiError?.error == "no_such_date" { return .notStored }
            guard reply.status == 200 else { return .refused(reply.apiError?.reason ?? "HTTP \(reply.status)") }
            guard let body = try? JSONDecoder().decode(StateBody.self, from: reply.body) else {
                return .refused("The PC's answer could not be read")
            }
            return .state(body.state)
        } catch let e as TransportError {
            return .unreachable(e.description)
        } catch {
            return .unreachable("\(error)")
        }
    }
}
