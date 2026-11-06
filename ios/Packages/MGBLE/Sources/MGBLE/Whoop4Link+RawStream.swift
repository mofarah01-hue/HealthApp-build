import Foundation
import MGDomain
import WhoopProtocol

/// The WHOOP 4.0's raw stream (WHOOP4-WIRE 6): command 63 SEND_R10_R11_REALTIME `[01]` starts the type-43 frames, `[00]` stops them
/// (verified on a 4.0 by noop: ryanbr/noop docs/PROTOCOL_SENSORS.md "Command 63 is the capture-backed output switch"; inventory §5
/// "63 ... verified: starts/stops the raw type-43 stream"). Commands 81/82 did not start it on a 4.0 and are not used. ONE stream
/// carries both the IMU (payload 1917) and the optical waveform (payload 1921), so the app's raw optical and raw motion switches share
/// it: it runs while either wants it. Both switches default OFF (CLAUDE.md rule 5: streams that drain battery default off).
///
/// Sent: `[01]` only when the app asks (a raw switch is on and may run now), after the handshake, never during a history download
/// (it waits for the end); `[00]` when neither wants it, and at most once per 30 s when frames arrive that nothing asked for (noop
/// `stopUnexpectedRealtimeImu`); the handshake already sends `[00]` at every connect. Frames are kept raw by `route` as before.
extension Whoop4Link {
    /// Decoded live IMU seconds (100 Hz x 6 axes, raw counts) and optical frames, for the app's motion path and the Live Waves card.
    public var liveRawMotion: AsyncStream<MotionSecond> { rawMotionHub.stream() }
    public var liveRawOptical: AsyncStream<Whoop4OpticalFrame> { rawOpticalHub.stream() }

    /// Stores the wish without writing (before the link is started): the handshake applies it.
    public func presetRawStream(_ on: Bool) { rawStreamWanted = on }

    /// The app's wish: `on` = a raw switch is on and may run now.
    public func setRawStream(_ on: Bool) async {
        rawStreamWanted = on
        if on { rawStream.stoppedReason = nil }
        await applyRawStream()
    }

    /// One writer at a time; a change that arrives meanwhile is applied right after.
    func applyRawStream() async {
        if rawStreamApplying {
            rawStreamApplyAgain = true
            return
        }
        rawStreamApplying = true
        defer { rawStreamApplying = false }
        repeat {
            rawStreamApplyAgain = false
            await applyRawStreamOnce()
        } while rawStreamApplyAgain
        publishRawStream()
    }

    /// Why 63 [01] may not go out now (nil = it may): a download running or about to start, or the link not ready. In those
    /// cases the wish is kept and applied when the download ends / the link is ready (WHOOP4-WIRE 6; noop: the type-43 flood
    /// causes lulls in the offload, BLEManager L2650).
    var rawStreamBlockReason: String? {
        if historyRun != nil { return "waiting for the history download to end" }
        if historyPending { return "waiting for the history download to run" }
        if state != .ready { return "waiting for the link to be ready" }
        return nil
    }

    private func applyRawStreamOnce() async {
        guard handshakeDone else { return }
        if rawStreamWanted, !rawStreamOn {
            if let why = rawStreamBlockReason {
                rawStream.stoppedReason = why   // re-applied when the download ends
                return
            }
            do {
                // PENDING counts as an answer for 63: the strap may already be streaming, so an OFF is owed (an awaited 3 s used to end in
                // "answered nothing" with nothing owed).
                let r = try await channel.send(.test(opcode: Whoop4Command.sendR10R11Realtime, payload: [0x01]), awaitResponse: true,
                                               pendingCounts: true)
                if let r, r.result == .success {
                    rawStreamOn = true
                    rawStream.stoppedReason = nil
                    logLine("whoop4: raw stream on (63 [01] → \(r.result.label))")
                } else if let r, r.result == .pending {
                    rawStreamOn = true
                    rawStreamNeedsOff = true
                    rawStream.stoppedReason = nil
                    logLine("whoop4: raw stream assumed on (63 [01] → PENDING, no final answer); an OFF is owed")
                } else {
                    if r == nil { rawStreamNeedsOff = true }   // no answer at all: the write may still have taken effect
                    rawStream.stoppedReason = "the strap answered \(r?.result.label ?? "nothing") to 63 [01]"
                    logLine("whoop4: raw stream not started — \(rawStream.stoppedReason ?? "")")
                }
            } catch {
                rawStreamNeedsOff = true     // a write that threw may still have reached the strap: an OFF is owed
                rawStream.stoppedReason = "63 [01] failed — \(describeError(error))"
                logLine("whoop4: raw stream not started — \(rawStream.stoppedReason ?? "")")
            }
        } else if !rawStreamWanted, rawStreamOn || rawStreamNeedsOff {
            do {
                let r = try await channel.send(.test(opcode: Whoop4Command.sendR10R11Realtime, payload: [0x00]), awaitResponse: true)
                logLine("whoop4: raw stream off (63 [00] → \(r?.result.label ?? "no response"))")
                rawStreamOn = false
                rawStreamNeedsOff = false
            } catch {
                rawStreamNeedsOff = true
                logLine("whoop4: 63 [00] failed — \(describeError(error)); sent again at the next connection")
            }
        }
    }

    func publishRawStream() {
        var s = rawStream
        s.wanted = rawStreamWanted
        s.on = rawStreamOn
        if rawStream != s { rawStream = s }
    }

    /// A live packet-43 frame (called from `route`): IMU → `live.motion` (stored as `motion_second`) and the trace stream; optical →
    /// the optical stream. Any other payload length is left to the raw archive. Frames nothing asked for get one OFF per 30 s.
    func noteLiveRaw(_ frame: [UInt8], at: Date) {
        if !rawStreamWanted, !rawStreamOn, handshakeDone {
            if at.timeIntervalSince(rawStreamUnexpectedStopAt ?? .distantPast) >= 30 {
                rawStreamUnexpectedStopAt = at
                rawStreamNeedsOff = true
                logLine("whoop4: raw frames arrived while nothing asked for them — 63 [00] sent")
                Task { @MainActor [weak self] in await self?.applyRawStream() }
            }
        }
        if let second = Whoop4RawDecode.motionSecond(frame, receivedAt: at) {
            live.motion.append(second)
            rawStream.imuFrames += 1
            rawStream.lastImuAt = at
            rawMotionHub.yield(second)
        } else if let optical = Whoop4RawDecode.optical(frame, receivedAt: at) {
            rawStream.opticalFrames += 1
            rawStream.lastOpticalAt = at
            rawOpticalHub.yield(optical)
        }
    }
}
