import Foundation
import MGDomain
import WhoopProtocol

/// What `rawMotion` publishes (wave W8, 2026-10-11 19:50 PT).
public struct RawMotionStatus: Equatable, Sendable {
    /// The app switch "Raw motion (100 Hz)", off by default.
    public var switchOn: Bool = false
    public var foreground: Bool = true
    /// A bounded session runs until this time even with the app in the background (nil = no session).
    public var sessionUntil: Date?
    /// 81 [01] + 106 [01 01] went out on this connection and no OFF since.
    public var on: Bool = false
    /// R21 seconds received since the switch went on, and when the last one arrived.
    public var seconds: Int = 0
    public var lastSecondAt: Date?
    /// Why it is not streaming although wanted (a refusal, a session that ended), or nil.
    public var stoppedReason: String?

    public init() {}
}

/// Raw motion: the strap's 100 Hz six-axis IMU (R21) on demand. CLAUDE.md rule 5 (as changed 2026-10-11 12:35 PT) allows
/// exactly START_RAW_DATA (81) [01] + TOGGLE_IMU_MODE (106) [01 01] to start and STOP_RAW_DATA (82) [01] + 106 [01 00] to
/// stop, with response, behind an off-by-default switch. Sequence: noop docs/RAW_DATA_CAPTURE.md L21-28 (hardware-verified
/// on 5/MG: 106 alone acks without starting the producer) and Strand/BLE/BLEManager.swift L2233-2251.
///
/// It streams while the switch is on AND (the app is in the foreground OR a bounded session runs). A session is the short
/// runner: up to 30 minutes, kept going in the background (iOS keeps a BLE app alive while notifications flow), then OFF.
/// OFF is sent when the switch goes off, the app leaves the foreground with no session, the session ends, or before an
/// intentional disconnect; after a link loss with it on, the next handshake sends OFF unless it is still wanted. R21 that
/// arrives while nothing here asked for it (a crash, a lost stop, another client) is answered with the stop pair, at most
/// once per 30 s (noop BLEManager.swift L2256-2268 `stopUnexpectedRealtimeImu`). Every frame is kept raw anyway (route()).
extension StrapLink {
    /// The longest session the runner accepts.
    public static let rawMotionMaxSessionSeconds: Double = 30 * 60

    /// Every decoded R21 second as it arrives (live only), for the Live tab's trace.
    public var liveRawMotion: AsyncStream<MotionSecond> { rawMotionHub.stream() }

    /// The app switch and the foreground state.
    public func setRawMotion(enabled: Bool, foreground: Bool) async {
        if enabled && !rawMotionSwitchOn {
            rawMotion.seconds = 0
            rawMotion.stoppedReason = nil
        }
        rawMotionSwitchOn = enabled
        rawMotionForeground = foreground
        if !enabled {
            rawMotionSessionTask?.cancel()
            rawMotionSessionTask = nil
            rawMotionSessionUntil = nil
        }
        await applyRawMotion()
    }

    /// The session runner: stream for `seconds` (at most 30 min), in the background too, then stop. Needs the switch on.
    public func startRawMotionSession(seconds: Double) async throws {
        guard rawMotionSwitchOn else {
            throw StrapLinkError.refusedByPolicy(reason: "the raw motion switch is off (Strap & sync › Raw motion)")
        }
        let length = min(max(seconds, 0.1), Self.rawMotionMaxSessionSeconds)
        rawMotionSessionTask?.cancel()
        rawMotionSessionUntil = clock.now.addingTimeInterval(length)
        rawMotion.stoppedReason = nil
        rawMotionSessionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(length * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.rawMotionSessionTask = nil
            self.rawMotionSessionUntil = nil
            self.rawMotion.stoppedReason = "session ended"
            await self.applyRawMotion()
        }
        await applyRawMotion()
    }

    /// Ends a session early (the switch stays as it is).
    public func stopRawMotionSession() async {
        rawMotionSessionTask?.cancel()
        rawMotionSessionTask = nil
        rawMotionSessionUntil = nil
        await applyRawMotion()
    }

    /// One writer at a time; a change that arrives meanwhile is applied right after.
    func applyRawMotion() async {
        if rawMotionApplying {
            rawMotionApplyAgain = true
            return
        }
        rawMotionApplying = true
        defer { rawMotionApplying = false }
        repeat {
            rawMotionApplyAgain = false
            await applyRawMotionOnce()
        } while rawMotionApplyAgain
        publishRawMotion()
    }

    private func applyRawMotionOnce() async {
        guard handshakeDone else { return }
        let should = rawMotionSwitchOn && (rawMotionForeground || rawMotionSessionUntil != nil)
        if !should, rawMotionDeferTask != nil {
            rawMotionDeferTask?.cancel()
            rawMotionDeferTask = nil
            if rawMotion.stoppedReason == "waiting for the history download to end" { rawMotion.stoppedReason = nil }
        }
        if should, !rawMotionLiveOn {
            await startRawMotionStream()
        } else if !should, rawMotionLiveOn || rawMotionNeedsOff {
            await stopRawMotionStream()
        }
    }

    /// r9d: R21 seen this recently at start time = the strap is already streaming; nothing is sent.
    public static var rawMotionAlreadyStreamingWindow: Double = 5

    /// Wait before the one retry of 81 (after the stop pair), seconds. T10006 (r8b, 2026-10-17): 1.5 s. A var so tests are fast.
    public static var rawMotionRetryDelay: Double = 1.5
    /// How often a deferred start looks whether the history offload has ended, and how long it keeps looking.
    public static var rawMotionDeferPoll: Double = 2
    public static var rawMotionDeferMaxSeconds: Double = 3600

    private enum RawMotionAttempt {
        case started
        case failed(String)
    }

    /// T10006 (r8b, 2026-10-17; audit §5.1, §5a). 81 [01]; only when the strap says SUCCESS, 106 [01 01] and the on-flag.
    /// A refusal (or no answer) is logged with the full reply body in hex (the 81 reply is 24 bytes — noop issue 423 — and
    /// nobody has decoded the extra four), then 82 [01] + 106 [01 00] go out, 1.5 s pass, and 81 is tried once more; a second
    /// refusal ends with a logged reason. A session left armed by a crash or an earlier launch is the best guess for the
    /// refusal (BLEManager.swift L2255-2268). Never started while a history offload runs: it waits (bounded) for it to end.
    private func startRawMotionStream() async {
        guard rawMotionSwitchOn else { return }     // the switch wall (check_strap_safety.py rule ECG-IMU pins this guard)
        if historyRun != nil || historyProbe != nil {
            deferRawMotionStart()
            return
        }
        rawMotionDeferTask?.cancel()
        rawMotionDeferTask = nil
        // r9d (audit §5.3): read the state before writing. No command reads the IMU producer's state, but its output is the
        // state: R21 seconds that arrived in the last few seconds mean the strap is already streaming (left armed by the
        // last link, or by a start that was answered after the app lost it). 81 would be refused then (r8b, Oct 16-17).
        if let last = rawMotion.lastSecondAt, clock.now.timeIntervalSince(last) <= Self.rawMotionAlreadyStreamingWindow {
            rawMotionLiveOn = true
            rawMotionNeedsOff = false
            rawMotionOnSentAt = clock.now
            rawMotion.stoppedReason = nil
            logLine("raw motion: already streaming (R21 seen \(Int(clock.now.timeIntervalSince(last))) s ago) - 81 / 106 not sent")
            return
        }
        var why = ""
        for attempt in 1...2 {
            switch await attemptRawMotionStart() {
            case .started:
                rawMotion.stoppedReason = nil
                return
            case .failed(let reason):
                why = reason
                logLine("raw motion: start attempt \(attempt) failed — \(reason)")
            }
            if attempt == 2 { break }
            // The producer may still be armed from an earlier session: stop pair, wait, try once more.
            await sendRawMotionStopPair()
            try? await Task.sleep(nanoseconds: UInt64(max(0, Self.rawMotionRetryDelay) * 1_000_000_000))
            let stillWanted = rawMotionSwitchOn && (rawMotionForeground || rawMotionSessionUntil != nil)
            guard handshakeDone, stillWanted, historyRun == nil, historyProbe == nil else {
                logLine("raw motion: retry of 81 [01] dropped — no longer wanted, link gone or a history download started")
                return
            }
        }
        rawMotionLiveOn = false
        rawMotionNeedsOff = false
        rawMotion.stoppedReason = "gave up: the strap refused 81 [01] twice (\(why))"
        logLine("raw motion: gave up — \(why)")
    }

    private func attemptRawMotionStart() async -> RawMotionAttempt {
        do {
            let start = try await channel.send(.sanctioned(.startRawMotion), awaitResponse: true)
            guard let start else { return .failed("no answer to 81 [01]") }
            logLine("raw motion: 81 [01] → \(start.result.label), reply \(start.frame.count) bytes, body "
                    + (start.body.isEmpty ? "(empty)" : start.body.hexLower))
            guard start.result == .success else { return .failed("the strap answered \(start.result.label) to 81 [01]") }
            rawMotionLiveOn = true       // only now: the strap said yes
            rawMotionNeedsOff = false
            rawMotionOnSentAt = clock.now
            let imu = try await channel.send(.sanctioned(.imuMode(on: true)), awaitResponse: true)
            logLine("raw motion: 106 [01 01] → \(imu?.result.label ?? "no response")")
            if let r = imu, r.result != .success {
                rawMotion.stoppedReason = "the strap answered \(r.result.label) to 106 [01 01]"
            }
            return .started
        } catch {
            // A write that threw may still have reached the strap: an OFF is owed.
            rawMotionNeedsOff = true
            return .failed("write failed — \(describeError(error))")
        }
    }

    /// Looks every `rawMotionDeferPoll` s (at most `rawMotionDeferMaxSeconds`) whether the offload is over, then applies.
    private func deferRawMotionStart() {
        rawMotion.stoppedReason = "waiting for the history download to end"
        guard rawMotionDeferTask == nil else { return }
        logLine("raw motion: start deferred — a history download is running")
        let poll = max(0.01, Self.rawMotionDeferPoll)
        let limit = Self.rawMotionDeferMaxSeconds
        rawMotionDeferTask = Task { @MainActor [weak self] in
            var waited = 0.0
            while waited < limit {
                try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                waited += poll
                guard let self, !Task.isCancelled else { return }
                if self.historyRun == nil && self.historyProbe == nil {
                    self.rawMotionDeferTask = nil
                    self.logLine("raw motion: the history download ended — starting")
                    await self.applyRawMotion()
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.rawMotionDeferTask = nil
            self.rawMotion.stoppedReason = "gave up waiting for the history download to end"
            self.logLine("raw motion: gave up waiting for the history download (\(Int(limit / 60)) min)")
            self.publishRawMotion()
        }
    }

    /// 82 [01], then 106 [01 00]. If either write fails, the OFF stays owed (sent again at the next connection).
    private func stopRawMotionStream() async {
        rawMotionDeferTask?.cancel()
        rawMotionDeferTask = nil
        let sent = await sendRawMotionStopPair()
        rawMotionLiveOn = false
        rawMotionNeedsOff = !sent
        rawMotionUnexpectedStopAt = clock.now
    }

    /// 82 [01] then 106 [01 00], each with response; false if a write threw.
    @discardableResult
    private func sendRawMotionStopPair() async -> Bool {
        var sent = true
        for command in [SanctionedCommand.stopRawMotion, .imuMode(on: false)] {
            do {
                let r = try await channel.send(.sanctioned(command), awaitResponse: true)
                logLine("raw motion: \(command.opcode) [\(command.payload.hexLower)] → \(r?.result.label ?? "no response")")
            } catch {
                sent = false
                logLine("raw motion: \(command.opcode) failed — \(describeError(error)); sent again at the next connection")
            }
        }
        return sent
    }

    /// A live packet-43 frame: R21 → `live.motion` (stored as `motion_second`) and the trace stream.
    func noteLiveRawMotion(_ frame: [UInt8]) {
        guard RawMotionDecode.looksLikeR21(frame), let second = RawMotionDecode.motionSecond(frame, source: "live")
        else { return }
        let wanted = rawMotionSwitchOn && (rawMotionForeground || rawMotionSessionUntil != nil)
        if !rawMotionLiveOn && !wanted && handshakeDone {
            let last = rawMotionUnexpectedStopAt ?? .distantPast
            if clock.now.timeIntervalSince(last) >= 30 {
                rawMotionUnexpectedStopAt = clock.now
                rawMotionNeedsOff = true
                logLine("raw motion: R21 arrived while nothing asked for it — stop sent")
                Task { @MainActor [weak self] in await self?.applyRawMotion() }
            }
        }
        live.motion.append(second)
        rawMotion.seconds += 1
        rawMotion.lastSecondAt = clock.now
        rawMotionHub.yield(second)
    }

    func publishRawMotion() {
        var s = rawMotion
        s.switchOn = rawMotionSwitchOn
        s.foreground = rawMotionForeground
        s.sessionUntil = rawMotionSessionUntil
        s.on = rawMotionLiveOn
        // T9996 (r9d): a reason set by the link itself goes away once motion data arrives after it.
        if s.stoppedReason != nil, s.stoppedReason == rawMotion.stoppedReason, let at = rawMotionReasonAt,
           let second = rawMotion.lastSecondAt, second > at {
            s.stoppedReason = nil
            rawMotion.stoppedReason = nil
            rawMotionReasonAt = nil
        }
        if rawMotion != s { rawMotion = s }
    }
}
