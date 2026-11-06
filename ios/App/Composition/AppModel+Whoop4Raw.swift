import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSignal

// WHOOP4-WIRE 6 (2026-11-05; Mo: "when I select 4.0 it does all of that"): the raw optical and raw motion switches on the WHOOP 4.0.
// Both switches drive ONE stream there (command 63 `[01]` / `[00]`, Whoop4Link+RawStream); the stream carries the IMU (type 43,
// payload 1917, into the existing 100 Hz motion path) and one optical waveform (payload 1921, into the Live "Waves" card as raw
// counts, decoded, untested, LED unknown). Both switches default OFF (CLAUDE.md rule 5: streams that drain battery default off); this
// file only forwards what the switches say. WRITTEN, NOT COMPILED here (the app target is built with xtool).
extension AppModel {
    /// The stream runs while raw motion is on, or raw optical is on and allowed now (the same two rules the 5/MG links use).
    func applyRawStreamWhoop4() {
        let motion = rawMotionWantedNow
        let optical = rawOpticalWantedNow && rawOpticalAllowedNow()
        var wanted = motion || optical
        // Only an automatic reason (workout episode / burst) wants it: not while the link is busy (downloading) or not ready. The
        // link itself also holds 63 [01] until its download ends; this keeps the wish honest. `strapChanged` re-applies on ready.
        if wanted, !(settings.rawMotionOn || settings.rawOpticalOn), services.whoop4.state != .ready { wanted = false }
        services.whoop4.setRawStream(wanted)
    }

    /// One live optical frame -> the Live PPG feed (id `LiveWaves.whoop4OpticalID`). Only while the Live tab is on screen (display
    /// only, as `feedLivePPG`). The sample rate is not documented (noop: "up to 419 samples", about 2 frames a second): it is
    /// estimated from the gap between frames, clamped to 0.25-2 s, so the trace's time axis is approximate.
    func feedLivePPGWhoop4(_ f: Whoop4OpticalFrame) {
        let now = clock.now
        defer { lastWhoop4OpticalAt = now }
        guard appActive, liveOnScreen, f.samples.count >= 10 else { return }
        let gap = min(2, max(0.25, lastWhoop4OpticalAt.map { now.timeIntervalSince($0) } ?? 0.5))
        LivePPGFeed.shared.append(id: LiveWaves.whoop4OpticalID, samples: f.samples, rateHz: Double(f.samples.count) / gap,
                                  arrivedAt: now.timeIntervalSinceReferenceDate)
    }

    /// The stream's state into the two statuses the screens already read (`rawOpticalStatus`, `rawMotionStatus`).
    func rawStreamWhoop4Changed(_ st: Whoop4RawStatus) {
        guard StrapDeviceChoice.stored == .whoop4 else { return }
        let beforeOptical = rawOpticalStatus
        let beforeMotion = rawMotionStatus
        var o = rawOpticalStatus
        o.wanted = settings.rawOpticalOn
        o.on = st.on
        o.frames = st.opticalFrames
        o.lastFrameAt = st.lastOpticalAt
        o.stoppedReason = st.stoppedReason
        rawOpticalStatus = o
        var m = rawMotionStatus
        m.switchOn = settings.rawMotionOn
        m.on = st.on
        m.seconds = st.imuFrames
        m.lastSecondAt = st.lastImuAt
        m.stoppedReason = st.stoppedReason
        rawMotionStatus = m
        if let at = st.lastImuAt, at != beforeMotion.lastSecondAt { RawNightLog.noteR21(at: clock.now) }   // IMU seconds, as R21
        // Frame counts change every second; the screens are rebuilt only when the state itself changes (as the 5/MG's do).
        if beforeOptical.on != o.on || beforeOptical.wanted != o.wanted || beforeOptical.stoppedReason != o.stoppedReason
            || beforeMotion.switchOn != m.switchOn {
            Task { [weak self] in await self?.refresh() }
        }
    }
}
