import Foundation
import MGDomain
import MGHealth
import MGSync

// T9739 (docs/features/APPLE-HEALTH-AUTO.md): the app side of the automatic Apple Health -> PC read. The logic (types, anchors,
// queue, batching, payload, status line) is MGHealth's HealthAutoSync and is tested there; this file only does the POST and
// the triggers.

/// POST /v1/health-samples with the device key (the same call and answers as `forwardImports`).
/// Nov 5 2026: `transport` is the app's shared `BackgroundUploadTransport` (background URLSession, file-backed) wrapped in the
/// Tailscale-address fallback, so an upload that is under way when the wake ends is finished by iOS; the 20-second wake does
/// not decide whether it arrives. A body whose answer was lost is sent again later (the PC dedups).
struct PCHealthUploader: HealthAutoUploader {
    let transport: any PCLabTransport
    /// Hup2: the background session's transfers under way (`BackgroundUploadTransport.inFlightDescriptions`).
    var inFlight: @Sendable () async -> Set<String> = { [] }

    func upload(_ body: Data) async -> HealthAutoUploadResult { await upload(body, keys: []) }

    func inFlightKeys() async -> Set<String> {
        Set(await inFlight().flatMap { HealthAutoPayload.keys(inTaskDescription: $0) })
    }

    func upload(_ body: Data, keys: [String]) async -> HealthAutoUploadResult {
        guard let creds = try? KeychainCredentialStore().load() else { return .retry("not paired with your PC Lab yet") }
        do {
            let resp = try await transport.send(
                PCRequest(method: "POST", path: "/v1/health-samples",
                          headers: ["Authorization": "Bearer \(creds.deviceKey)", "Content-Type": "application/json"],
                          body: body, timeout: 60,
                          taskDescription: keys.isEmpty ? nil : HealthAutoPayload.taskDescription(keys: keys)), baseURL: creds.baseURL)
            let reason = ((try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any])?["reason"] as? String
            switch resp.status {
            case 200, 201: return .accepted
            case 400, 413: return .rejected(reason ?? "HTTP \(resp.status)")
            default: return .retry("PC answered HTTP \(resp.status)" + (reason.map { ": " + $0 } ?? ""))
            }
        } catch is CancellationError {
            // Hup2: the run's time limit released us; the background transfer goes on and its answer is recorded by
            // `HealthAutoSync.recordAccepted` (via `onLateCompletion`). Waiting, not an error.
            return .pending("sent; waiting for the PC's answer in the background")
        } catch {
            return .retry("PC not reachable (\(error))")
        }
    }
}

extension AppModel {
    /// Every launch / foreground: read what is due (HealthPollSchedule) and send it. `manual` = "Sync now": every safe type,
    /// capped per run, the rest resumes from the anchors next time. Runs inside the HealthAutoSync actor, off the main thread.
    func runHealthAuto(manual: Bool = false) async {
        guard let auto = services.healthAuto, !isSample else { return }
        if await services.health?.authState() == .notRequested { return }   // the permission sheet comes first (askHealthReadIfNeeded)
        _ = await auto.run(trigger: manual ? .manual : .automatic)
        await HealthQueueNote.record(auto, context: manual ? "manual sync" : "run", at: clock.now)      // r9u
        await publishAppleHealth()
    }
}
