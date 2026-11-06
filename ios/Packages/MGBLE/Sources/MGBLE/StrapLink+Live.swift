import Foundation
import MGDomain
import WhoopProtocol

/// Inbound data: reassembly, routing, live records (ARCHITECTURE §4.4.6).
extension StrapLink {
    public func transport(_ source: StrapTransport, didReceive data: Data, from characteristic: String) {
        lastDataAt = clock.now
        let ch = StrapGATT.normalize(characteristic)
        let bytes = [UInt8](data)
        switch ch {
        case StrapGATT.heartRateMeasurement:
            handleStandardHR(bytes)
        case StrapGATT.batteryLevel:
            if let percent = bytes.first { noteBattery(Double(percent), charging: nil) }
        default:
            guard StrapGATT.notify.contains(ch) else { return }
            // Reassembly, CRC and the R20 / raw-IMU decode run off the main actor (FrameDecodeStage); the decoded frames
            // come back, in order, to `applyDecoded`.
            if !decodeStage.submit(channel: ch, bytes: bytes, at: clock.now) {
                let dropped = decodeStage.droppedCount
                if dropped == 1 || dropped % 100 == 0 {
                    logLine("strap: decode queue full (\(decodeStage.inFlight) in flight), notification dropped — \(dropped) so far")
                }
            }
        }
    }

    /// Starts the single main-actor loop that applies decoded frames in arrival order (called once, from `init`).
    func startDecodeApply() {
        let output = decodeStage.output
        decodeApplyTask = Task { @MainActor [weak self] in
            for await batch in output {
                guard let self else { return }
                self.applyDecoded(batch)
            }
        }
    }

    func applyDecoded(_ batch: DecodedBatch) {
        decodeStage.applied()
        for frame in batch.frames { route(frame) }
    }

    /// Packet type at frame[8] (whoop_protocol.json `PacketType`).
    func route(_ decoded: DecodedFrame) {
        let frame = decoded.bytes
        // T9746 (Mo: archive everything): every frame the strap sends is kept raw and goes to the PC, decoded or not.
        // Type 43 is kept below (after its CRC check, as before); offload traffic (47 / 49 / 50 / 56) while a history run
        // is open is kept with its chunk (RecordMapper.historyChunk), so it is not doubled here.
        guard frame.count > 10 else {
            keepLiveRaw(frame, at: decoded.at)
            return
        }
        let offload = frame[8] == 47 || frame[8] == 49 || frame[8] == 50 || frame[8] == 56
        if frame[8] != 43, !(offload && historyRun != nil) { keepLiveRaw(frame, at: decoded.at) }
        switch frame[8] {
        case 36, 38:   // COMMAND_RESPONSE / PUFFIN_COMMAND_RESPONSE
            guard let response = CommandResponse.parse(frame) else { return }
            if response.command == 145 { noteHello(frame) }
            if !channel.deliver(response), response.command != 145 {
                logLine("strap: unsolicited response to command \(response.command) (\(response.result.label))")
            }
        case 47, 49, 50, 56:   // HISTORICAL_DATA, METADATA, CONSOLE_LOGS, PUFFIN_METADATA — offload traffic
            if let run = historyRun {
                run.inbox.push(frame)
            } else if let inbox = historyProbe?.inbox {   // wave W12b: the read-without-deleting test
                inbox.push(frame)
            } else {
                droppedOffloadFrames += 1
            }
            // noop's only captured raw-IMU buffer is a type-47 v21 record (Whoop5RawImuTests `realFrameBytes`), so
            // that shape is tried too; the freshness gate in `noteMotion` keeps history replays out of the live feed.
            if frame[8] == 47 { noteMotion(decoded.motion) }
        case 48:   // EVENT
            handleEvent(frame)
        case 40:   // REALTIME_DATA (toggle 3)
            handleRealtime(frame)
        case 43:   // REALTIME_RAW_DATA (toggle 63): kept raw for the live stager, and decoded to motion when it is
                   // the 1244-byte raw-IMU buffer
            guard decoded.crcOK == true else {
                noteBadLiveCRC(frame)
                return
            }
            live.rawFrames.append(RawFrame(receivedAt: decoded.at, packetType: 43, bytes: Data(frame)))
            noteMotion(decoded.motion)
            noteLiveOptical(decoded.r20, at: decoded.at)
            noteLiveRawMotion(frame)   // wave W8: R21 (layout 21) → motion_second + the Live trace
            noteLiveEcg(frame)         // wave W8: R17 (layout 17) → the ECG reading
        default:
            break
        }
    }

    /// A type-43 frame whose CRC failed: not decoded and not kept, but counted and logged (first, then every 100th).
    func noteBadLiveCRC(_ frame: [UInt8]) {
        decodeState.crcBadFrames += 1
        let n = decodeState.crcBadFrames
        if n == 1 || n % 100 == 0 {
            logLine("strap: live frame failed its CRC (\(frame.count) bytes) — \(n) so far, not decoded")
        }
    }

    /// A frame as it arrived, kept for `raw_frame` (and so for the PC's raw/frames.* files). Type 0 = too short to
    /// carry a packet type.
    func keepLiveRaw(_ frame: [UInt8], at: Date) {
        live.rawFrames.append(RawFrame(receivedAt: at, packetType: frame.count > 8 ? Int(frame[8]) : 0,
                                       bytes: Data(frame)))
    }

    /// One raw-IMU buffer → one `StrapMotionSecond` on `liveMotion`: the mean of its 100 accelerometer samples.
    /// Decoding is WhoopProtocol's `Whoop5RawImu.decode` (gates on the exact 1244-byte length and both sample counts
    /// = 100, never on the type byte; accel scale 1/4096 g per LSB; strap unix seconds @15). Only an intact frame
    /// whose own timestamp is within `freshEventWindow` of now is emitted — a banked buffer replayed by history is
    /// not live motion. In B1 nothing asks the strap for raw IMU (81 + 106 are policy-gated), so this rarely fires.
    func noteMotion(_ second: StrapMotionSecond?) {
        guard let second else { return }
        guard abs(Double(second.ts) - clock.now.timeIntervalSince1970) <= config.timing.freshEventWindow else { return }
        motionHub.yield(second)
    }

    /// A live R20 record (108 on → REALTIME_RAW_DATA 43, layout 20, 2,140 bytes) → `R20Record` "live" for `ppg_block`.
    /// The raw frame is already kept above. Anything that does not decode (CRC, layout) stays raw only.
    func noteLiveOptical(_ rec: R20Record?, at: Date) {
        guard let rec else { return }
        live.r20.append(rec)
        decodeState.optical.frames += 1
        decodeState.optical.lastFrameAt = at
        // wave 4: a short rolling window for both slots of every block (nothing is sent to the strap)
        var recent = decodeState.optical.recent
        for b in rec.blocks {
            while recent.count <= b.index {
                recent.append(R20Block(index: recent.count, head: [], slotA: [], slotB: []))
            }
            var saved = recent[b.index]
            saved.head = b.head
            saved.slotA = b.slotA.isEmpty ? []
                : Array((saved.slotA + b.slotA).suffix(b.slotA.count * RawOpticalStatus.recentSeconds))
            saved.slotB = b.slotB.isEmpty ? []
                : Array((saved.slotB + b.slotB).suffix(b.slotB.count * RawOpticalStatus.recentSeconds))
            recent[b.index] = saved
        }
        decodeState.optical.recent = recent
        decodeState.optical.recentRecords = Array((decodeState.optical.recentRecords + [rec])
            .suffix(RawOpticalStatus.recordsKept))
        publishOpticalThrottled()
    }

    /// The UI hears about live optical at most once per `opticalPublishInterval` (one `rawOptical` assignment): the first
    /// frame after a quiet spell at once, the rest folded into one trailing publish so the last state always arrives.
    func publishOpticalThrottled() {
        let interval = LiveDecodeState.opticalPublishInterval
        let now = clock.now
        let sinceLast = decodeState.opticalPublishedAt.map { now.timeIntervalSince($0) } ?? interval
        if sinceLast >= interval {
            decodeState.opticalPublishedAt = now
            publishRawOptical()
        } else if decodeState.opticalTrailing == nil {
            let wait = max(0.01, interval - sinceLast)
            decodeState.opticalTrailing = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self else { return }
                self.decodeState.opticalTrailing = nil
                self.decodeState.opticalPublishedAt = self.clock.now
                self.publishRawOptical()
            }
        }
    }

    // MARK: - Raw optical switch (2026-10-11, strap-raw-optical phase C)

    /// The app switch "Raw optical (uses strap battery)" and whether the app is in the foreground. Raw optical runs
    /// only while BOTH are true and the strap is connected: TOGGLE_OPTICAL_MODE (108) [01 01] when that starts,
    /// [01 00] when the switch goes off, the app goes to the background, or before an intentional disconnect.
    /// ENABLE_OPTICAL_DATA (107, banking R20 into history) is turned on only by its own opt-in switch (T9992, below, default
    /// off): a 2,140-byte record a second would fill the strap's history and lengthen every offload (noop #1992).
    public func setRawOptical(enabled: Bool, foreground: Bool) async {
        if enabled && !wantRawOptical {
            rawOpticalTrip = nil
            decodeState.optical.frames = 0
            decodeState.optical.recentRecords = []
            rawOptical.stoppedReason = nil
        }
        wantRawOptical = enabled
        appForeground = foreground
        await applyRawOptical()
    }

    /// Sends 108 OFF first when raw optical is on, then disconnects (an unexpected link loss cannot send it; the next
    /// handshake does — `rawOpticalNeedsOff`).
    public func disconnectStoppingRawOptical() async {
        wantRawOptical = false
        await applyRawOptical()
        setOpticalReason("stopped: the strap was disconnected from the app (hand-back or disconnect)")
        publishRawOptical()
        // Wave W8: raw motion and an ECG reading are stopped the same way before the link goes.
        rawMotionSwitchOn = false
        rawMotionSessionUntil = nil
        await applyRawMotion()
        if ecgReading != nil || ecgNeedsStop { _ = await stopEcgReading() }
        disconnect()
    }

    /// A previous link object may have left raw optical on (the app rebuilt the link): the next handshake sends OFF
    /// unless the switch wants it on.
    public func noteRawOpticalMayBeOn() {
        rawOpticalNeedsOff = true
    }

    /// One writer at a time; a change that arrives meanwhile is applied right after.
    func applyRawOptical() async {
        if rawOpticalApplying {
            rawOpticalApplyAgain = true
            return
        }
        rawOpticalApplying = true
        defer { rawOpticalApplying = false }
        repeat {
            rawOpticalApplyAgain = false
            await applyRawOpticalOnce()
            await applyRawBankingOnce()
        } while rawOpticalApplyAgain
        publishRawOptical()
    }

    private func applyRawOpticalOnce() async {
        guard handshakeDone else { return }
        let should = wantRawOptical && appForeground && rawOpticalTrip == nil
        // T9996 (r9d): off for a reason is never silent. "Not allowed now" (app in the background outside the allowed
        // windows, nights-only schedule) used to switch it off with no word on the switch.
        if wantRawOptical, rawOpticalTrip == nil, !appForeground {
            setOpticalReason(Self.opticalPausedReason)
        } else if rawOptical.stoppedReason == Self.opticalPausedReason {
            rawOptical.stoppedReason = nil
        }
        if should, !rawOpticalLiveOn {
            do {
                let r = try await channel.send(.sanctioned(.toggleOpticalMode(on: true)), awaitResponse: true)
                rawOpticalLiveOn = true          // written: from now on an OFF is owed, whatever the answer
                rawOpticalNeedsOff = false
                rawOpticalOnSentAt = clock.now
                logLine("raw optical: 108 [01 01] → \(r?.result.label ?? "no response")")
                if rawOptical.stoppedReason?.hasPrefix("link lost") == true { rawOptical.stoppedReason = nil }
                if let r, r.result != .success {
                    setOpticalReason("the strap answered \(r.result.label) to raw optical on")
                }
            } catch {
                logLine("raw optical: 108 [01 01] failed — \(describeError(error))")
                setOpticalReason("could not send raw optical on: \(describeError(error))")
            }
        } else if !should, rawOpticalLiveOn || rawOpticalNeedsOff {
            do {
                let r = try await channel.send(.sanctioned(.toggleOpticalMode(on: false)), awaitResponse: true)
                rawOpticalLiveOn = false
                rawOpticalNeedsOff = false
                logLine("raw optical: 108 [01 00] → \(r?.result.label ?? "no response")")
            } catch {
                logLine("raw optical: 108 [01 00] failed — \(describeError(error)); sent again at the next connection")
                rawOpticalNeedsOff = true
                rawOpticalLiveOn = false
            }
        }
    }

    // MARK: - Keep raw on the strap (T9992, default off)

    /// The app switch "Keep raw on the strap if the app is closed (fills strap memory, longer downloads)". With it ON and raw
    /// optical wanted, 107 [01 01] is sent (and sent again after every reconnect, the banking may be session-scoped); with
    /// either off, 107 [01 00]. Nothing is read back from the strap: the log lines are the evidence.
    public func setRawBanking(_ enabled: Bool) async {
        wantRawBanking = enabled
        await applyRawOptical()
    }

    private func applyRawBankingOnce() async {
        guard handshakeDone else { return }
        let should = wantRawBanking && wantRawOptical
        if should, !rawBankingOn {
            do {
                let r = try await channel.send(.sanctioned(.enableOpticalData(on: true)), awaitResponse: true)
                rawBankingOn = true              // written: from now on an OFF is owed, whatever the answer
                rawBankingNeedsOff = false
                logLine("raw banking: 107 [01 01] → \(r?.result.label ?? "no response")")
            } catch {
                logLine("raw banking: 107 [01 01] failed — \(describeError(error))")
            }
        } else if !should, rawBankingOn || rawBankingNeedsOff {
            do {
                let r = try await channel.send(.sanctioned(.enableOpticalData(on: false)), awaitResponse: true)
                rawBankingOn = false
                rawBankingNeedsOff = false
                logLine("raw banking: 107 [01 00] → \(r?.result.label ?? "no response")")
            } catch {
                logLine("raw banking: 107 [01 00] failed — \(describeError(error)); sent again at the next connection")
                rawBankingNeedsOff = true
                rawBankingOn = false
            }
        }
    }

    /// The offload watchdog tripped (HistoryRun): raw optical off now and until the switch is turned on again.
    func rawOpticalWatchdogTripped(_ reason: String) async {
        rawOpticalTrip = reason
        rawOptical.stoppedReason = "stopped by the watchdog: \(reason)"
        logLine("raw optical: stopped — \(reason)")
        await applyRawOptical()
    }

    static let opticalPausedReason = "paused: not allowed right now (app in the background outside the allowed times - "
        + "Strap & sync › Raw optical); it starts again by itself"

    /// Sets a stopped reason the link itself found, with the moment it was set.
    func setOpticalReason(_ text: String) {
        if rawOptical.stoppedReason != text { logLine("raw optical: not streaming - \(text)") }
        rawOptical.stoppedReason = text
        rawOpticalReasonAt = clock.now
    }

    func setMotionReason(_ text: String) {
        if rawMotion.stoppedReason != text { logLine("raw motion: not streaming - \(text)") }
        rawMotion.stoppedReason = text
        rawMotionReasonAt = clock.now
    }

    /// T9996 (r9d): the switch is on and the start went out, but the strap sends nothing for `streamStallSeconds` (and no
    /// history download runs, the strap may pause streams during one): say so on the switch and ask again, at most once per
    /// `streamRearmGap`. Runs on the maintenance loop (already running while connected), no timer of its own.
    func checkRawStreamStalls() {
        guard handshakeDone, historyRun == nil, historyProbe == nil else { return }
        let now = clock.now
        let limit = config.timing.streamStallSeconds
        let gap = config.timing.streamRearmGap
        if rawOpticalLiveOn {
            let since = [decodeState.optical.lastFrameAt, rawOpticalOnSentAt, streamsQuietSince].compactMap { $0 }.max() ?? now
            let quiet = now.timeIntervalSince(since)
            if quiet > limit {
                setOpticalReason("the strap stopped sending raw optical (nothing for \(Int(limit)) s or more)")
                if now.timeIntervalSince(rawOpticalRearmAt ?? .distantPast) >= gap {
                    rawOpticalRearmAt = now
                    logLine("raw optical: asking the strap to start again")
                    rawOpticalLiveOn = false
                    rawOpticalNeedsOff = false
                    Task { @MainActor [weak self] in await self?.applyRawOptical() }
                }
                publishRawOptical()
            }
        }
        if rawMotionLiveOn {
            let since = [rawMotion.lastSecondAt, rawMotionOnSentAt, streamsQuietSince].compactMap { $0 }.max() ?? now
            let quiet = now.timeIntervalSince(since)
            if quiet > limit {
                setMotionReason("the strap stopped sending raw motion (nothing for \(Int(limit)) s or more)")
                if now.timeIntervalSince(rawMotionRearmAt ?? .distantPast) >= gap {
                    rawMotionRearmAt = now
                    logLine("raw motion: asking the strap to start again")
                    rawMotionLiveOn = false
                    // 81 is refused while the producer is still armed: the start path then sends the stop pair and retries once
                    Task { @MainActor [weak self] in await self?.applyRawMotion() }
                }
                publishRawMotion()
            }
        }
    }

    func publishRawOptical() {
        var s = rawOptical
        let liveOptical = decodeState.optical
        s.frames = liveOptical.frames
        s.lastFrameAt = liveOptical.lastFrameAt
        s.recent = liveOptical.recent
        s.recentRecords = liveOptical.recentRecords
        s.wanted = wantRawOptical
        s.on = rawOpticalLiveOn
        if wantRawOptical, rawOpticalTrip == nil, s.stoppedReason?.hasPrefix("stopped by the watchdog") == true {
            s.stoppedReason = nil
        }
        // T9996 (r9d): a reason set by the link itself goes away once raw optical data arrives after it.
        if s.stoppedReason != nil, s.stoppedReason == rawOptical.stoppedReason, let at = rawOpticalReasonAt,
           let frame = liveOptical.lastFrameAt, frame > at {
            s.stoppedReason = nil
            rawOptical.stoppedReason = nil
            rawOpticalReasonAt = nil
        }
        if rawOptical != s {
            rawOptical = s
            decodeState.opticalPublishes += 1
        }
    }

    /// The GET_HELLO reply carries the firmware version at reply payload byte 93 (noop Interpreter L943-965,
    /// `fw_version`, guarded to generation 50 — fails closed on other firmware).
    func noteHello(_ frame: [UInt8]) {
        let p = parseFrame(frame, family: .whoop5)
        if let fw = p.parsed["fw_version"]?.stringValue { info?.firmware = fw }
    }

    /// REALTIME_DATA: HR and R-R. 5/MG realtime timestamps are the strap RTC's real unix seconds, so the identity
    /// clock reference is the correct decode (noop BLEManager `configureCollectorFamily`; BackfillContinuation
    /// `derivesClockCorrelation`, L380-400).
    func handleRealtime(_ frame: [UInt8]) {
        let p = parseFrame(frame, family: .whoop5)
        guard p.ok else { return }
        let now = Int(clock.now.timeIntervalSince1970)
        let s = extractStreams([p], deviceClockRef: now, wallClockRef: now, family: .whoop5)
        for h in s.hr where h.bpm > 0 {
            live.hr.append(HRPoint(ts: Int64(h.ts), bpm: Double(h.bpm), source: .live))
        }
        for beat in s.rr {
            live.appendRR(ts: Int64(beat.ts), rrMs: Double(beat.rrMs), source: .live)
        }
        guard !s.hr.isEmpty || !s.rr.isEmpty else { return }
        lastFd4bBeatAt = clock.now
        let ts = s.hr.first?.ts ?? s.rr.first?.ts ?? now
        let bpm: Double? = s.hr.first.flatMap { $0.bpm > 0 ? Double($0.bpm) : nil }
        beatHub.yield(LiveBeat(at: Date(timeIntervalSince1970: TimeInterval(ts)), bpm: bpm,
                               rrMs: s.rr.map { Double($0.rrMs) }))
    }

    /// Standard 0x2A37 (works without the bond; source `std_2a37`).
    func handleStandardHR(_ bytes: [UInt8]) {
        guard let m = HeartRateMeasurement.parse(bytes) else { return }
        let now = clock.now
        let ts = Int64(now.timeIntervalSince1970)
        if let bpm = m.bpm { live.hr.append(HRPoint(ts: ts, bpm: Double(bpm), source: .std2A37)) }
        for rr in m.rrMs { live.appendRR(ts: ts, rrMs: rr, source: .std2A37) }
        // The fd4b stream feeds the UI when both run; 2A37 fills in when it is off.
        if let last = lastFd4bBeatAt, now.timeIntervalSince(last) < 1.5 { return }
        guard m.bpm != nil || !m.rrMs.isEmpty else { return }
        beatHub.yield(LiveBeat(at: now, bpm: m.bpm.map { Double($0) }, rrMs: m.rrMs))
    }

    /// EVENT (type 48). During an offload every EVENT also goes to the chunk (noop `isOffloadFrame`). Only an event
    /// whose own timestamp is within its freshness window of now is acted on — a replayed double-tap must not log a
    /// vape hit (noop FrameRouter `dispatchLiveGestureIfFresh`, L851-859). T110: WRIST_ON (9) / WRIST_OFF (10) use the
    /// wider `wearEventWindow` — a slow reconnect replays the wrist change late, and dropping it left the app's
    /// off-wrist flag stuck; every other event keeps the 30 s `freshEventWindow` gate.
    func handleEvent(_ frame: [UInt8]) {
        if let run = historyRun { run.inbox.push(frame) } else { historyProbe?.inbox?.push(frame) }
        let p = parseFrame(frame, family: .whoop5)
        guard p.ok, p.crcOK != false, let event = RecordMapper.strapEvent(frame: frame, parsed: p) else { return }
        // 9 WRIST_ON / 10 WRIST_OFF (AppModel+Strap `strapEvent` switches on the same numbers): the wider
        // wear window, never narrower than the general one; every other event keeps `freshEventWindow`.
        let isWearEvent = event.number == 9 || event.number == 10
        let window = isWearEvent ? max(config.timing.freshEventWindow, config.timing.wearEventWindow)
                                 : config.timing.freshEventWindow
        let fresh = abs(Double(event.ts) - clock.now.timeIntervalSince1970) <= window
        if historyRun != nil || historyProbe != nil, !fresh { return }   // a replayed record: it belongs to its chunk
        live.events.append(event)
        guard fresh else { return }
        eventHub.yield(event)
        switch event.number {
        case 13:   // RTC_LOST → redo the clock (ARCHITECTURE §4.4.2)
            if handshakeDone { Task { @MainActor [weak self] in await self?.runClockSync() } }
        case 3:    // BATTERY_LEVEL: deci-percent in the event (noop Interpreter `decodeWhoop5Event`)
            if let percent = p.parsed["battery_pct"]?.doubleValue {
                noteBattery(percent, charging: p.parsed["battery_charging"]?.intValue.map { $0 != 0 }, ts: event.ts)
            }
        default:
            break
        }
    }

    func noteBattery(_ percent: Double, charging: Bool?, ts: Int64? = nil) {
        info?.batteryPercent = percent
        live.battery.append(BatteryReading(ts: ts ?? Int64(clock.now.timeIntervalSince1970), percent: percent,
                                           charging: charging))
    }

    func flushLive() async {
        guard let sid = strapId, let batch = live.take(strapId: sid) else { return }
        do { try await liveSink.append(batch) } catch {
            logLine("live: append failed — \(describeError(error))")
        }
    }

    func flushLiveSoon() {
        Task { @MainActor [weak self] in await self?.flushLive() }
    }
}

/// Live records waiting for the next `LiveSink.append` (every `liveFlushInterval`).
struct LiveBuffer {
    var hr: [HRPoint] = []
    var rr: [RRPoint] = []
    var events: [StrapEvent] = []
    var battery: [BatteryReading] = []
    var rawFrames: [RawFrame] = []
    var r20: [R20Record] = []
    var motion: [MotionSecond] = []
    private var ords = RROrdinals()

    mutating func appendRR(ts: Int64, rrMs: Double, source: StreamSource) {
        rr.append(RRPoint(ts: ts, ord: ords.next(for: ts), rrMs: rrMs, source: source))
    }

    mutating func take(strapId: StrapID) -> StrapRecordBatch? {
        guard !(hr.isEmpty && rr.isEmpty && events.isEmpty && battery.isEmpty && rawFrames.isEmpty && r20.isEmpty
                && motion.isEmpty)
        else { return nil }
        let batch = StrapRecordBatch(strapId: strapId, hr: hr, rr: rr, seconds: [], ppg: [], events: events,
                                     battery: battery, rawFrames: rawFrames, r20: r20, motion: motion)
        motion = []
        hr = []
        rr = []
        events = []
        battery = []
        rawFrames = []
        r20 = []
        return batch
    }

    /// WHOOP 4.0: a batch whose `LiveSink.append` threw goes back in front of what arrived meanwhile, so it is tried again at
    /// the next flush instead of being lost. Raw frames and motion are capped (the oldest are dropped) so a sink that keeps
    /// failing cannot grow the buffer without end.
    mutating func putBack(_ batch: StrapRecordBatch, cap: Int = 100_000) {
        hr = batch.hr + hr
        rr = batch.rr + rr
        events = batch.events + events
        battery = batch.battery + battery
        r20 = batch.r20 + r20
        motion = Array((batch.motion + motion).suffix(cap))
        rawFrames = Array((batch.rawFrames + rawFrames).suffix(cap))
    }
}
