import Foundation
import MGBLE
import MGDomain

// Wave W8 (2026-10-11): the ECG reading and raw motion R21 through the one strap link. CLAUDE.md rule 5: each behind its
// own off-by-default switch; MGBLE refuses the ON writes while a switch is off and keeps every stop available.

extension StrapCoordinator {
    func setEcgSwitch(_ on: Bool) {
        guard let link else { return }
        Task { @MainActor in await link.setEcgSwitch(on) }
    }

    func startEcgReading(wrist: EcgWrist, seconds: Double) async -> Result<EcgStartReport, StrapActionError> {
        guard let link else { return .failure(StrapActionError("the strap link is not started")) }
        do { return .success(try await link.startEcgReading(wrist: wrist, maxSeconds: seconds)) } catch {
            noteExternal("ECG: \(error)")
            return .failure(StrapActionError(Self.words(error)))
        }
    }

    @discardableResult
    func stopEcgReading(reason: String) async -> Bool {
        guard let link else { return false }
        // MGBLE's own time limit may have stopped it already: no second stop unless one is still owed.
        guard link.ecg.phase != .idle || link.ecg.stopOwed else { return true }
        return await link.stopEcgReading(reason: reason)
    }

    func setRawMotion(enabled: Bool, foreground: Bool) {
        guard let link else { return }
        Task { @MainActor in await link.setRawMotion(enabled: enabled, foreground: foreground) }
    }

    /// nil when the session started (or will at the next connection); else why not.
    func rawMotionSession(seconds: Double) async -> String? {
        guard let link else { return "the strap link is not started" }
        if seconds <= 0 {
            await link.stopRawMotionSession()
            return nil
        }
        do {
            try await link.startRawMotionSession(seconds: seconds)
            return nil
        } catch {
            return Self.words(error)
        }
    }
}
