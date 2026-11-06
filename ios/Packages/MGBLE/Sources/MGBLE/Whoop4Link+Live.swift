// Ported from ryanbr/noop @ 2a1de76 (main, 2026-10-25): Strand/BLE/BLEManager.swift (custom-notify routing L7400-7470),
// Strand/BLE/FrameRouter.swift (events, `dispatchLiveGestureIfFresh`), WhoopProtocol `parseFrame(…, family: .whoop4)`.
// PolyForm Noncommercial 1.0.0. Required Notice: Copyright 2026 NoopApp.
import Foundation
import MGDomain
import WhoopProtocol

/// Inbound data of the WHOOP 4.0 link: reassembly, routing by packet type (frame[4]), live records, events.
extension Whoop4Link {
    public func transport(_ source: StrapTransport, didReceive data: Data, from characteristic: String) {
        lastDataAt = clock.now
        let ch = StrapGATT.normalize(characteristic)
        let bytes = [UInt8](data)
        switch ch {
        case StrapGATT.heartRateMeasurement:
            handleStandardHR(bytes)
        case StrapGATT.batteryLevel:
            break   // a constant-100 stub on a 4.0 (noop #77): the battery comes from command 26 and BATTERY_LEVEL events
        default:
            guard Whoop4GATT.notify.contains(ch) else { return }
            let reassembler: Reassembler
            if let r = reassemblers[ch] {
                reassembler = r
            } else {
                reassembler = Reassembler(family: .whoop4)
                reassemblers[ch] = reassembler
            }
            let now = clock.now
            for frame in reassembler.feed(bytes) { route(frame, at: now) }
        }
    }

    /// Packet type at frame[4] (whoop_protocol.json `PacketType`). Project rule (archive everything the strap sends, raw): every
    /// frame is kept for `raw_frame`, except offload traffic (47 / 49 / 50) while a history run is open, which is kept with its
    /// chunk, inside the same store call that precedes the ack.
    func route(_ frame: [UInt8], at: Date) {
        guard frame.count > 4 else {
            keepLiveRaw(frame, at: at)
            return
        }
        let type = frame[4]
        let offload = type == 47 || type == 49 || type == 50
        if !(offload && historyRun != nil) { keepLiveRaw(frame, at: at) }
        switch type {
        case 36:   // COMMAND_RESPONSE
            guard let response = Whoop4Frame.response(frame) else { return }
            if !channel.deliver(response) {
                // The link sends 63 [00], 22, 23, 20, SET_CLOCK and the bonding read without waiting for the answer: their replies
                // are expected. They are counted (summary line at the end of a download), not logged one by one. Any other
                // unmatched reply is still logged.
                if Self.fireAndForgetOpcodes.contains(response.command) {
                    ignoredReplyCounts[response.command, default: 0] += 1
                } else {
                    logLine("whoop4: unsolicited response to command \(response.command) (\(response.result.label))")
                }
            }
        case 47, 49, 50:   // HISTORICAL_DATA, METADATA, CONSOLE_LOGS: offload traffic
            if let run = historyRun {
                run.inbox.push(frame)
            } else {
                // No run yet (a reconnect, or the strap resumed an offload by itself): archived raw above; also held so a run that
                // starts next treats the stream as already open (`downloadHistory` replays them, oldest first).
                droppedOffloadFrames += 1
                pendingOffload.append(frame)
                if pendingOffload.count > Self.pendingOffloadCap { pendingOffload.removeFirst(pendingOffload.count - Self.pendingOffloadCap) }
            }
        case 48:
            handleEvent(frame)
        case 40:   // REALTIME_DATA, only after command 3 (nothing here sends it)
            handleRealtime(frame)
        case 43:   // REALTIME_RAW_DATA (WHOOP4-WIRE 6): IMU 1917 and optical 1921 are decoded; the frame is archived raw above either way
            noteLiveRaw(frame, at: at)
        default:
            break   // anything else: archived raw above, not decoded
        }
    }

    func keepLiveRaw(_ frame: [UInt8], at: Date) {
        live.rawFrames.append(RawFrame(receivedAt: at, packetType: frame.count > 4 ? Int(frame[4]) : 0, bytes: Data(frame)))
    }

    /// REALTIME_DATA (type 40): HR at offset 12, R-R count 13, R-R from 14 (inventory §3). Stamped with the phone's clock: a 4.0
    /// whose own clock is wrong would otherwise date live beats wrongly.
    func handleRealtime(_ frame: [UInt8]) {
        let p = parseFrame(frame, family: .whoop4)
        guard p.ok, p.crcOK != false else { return }
        let now = clock.now
        let ts = Int64(now.timeIntervalSince1970)
        let bpm = p.parsed["heart_rate"]?.intValue.flatMap { $0 > 0 ? $0 : nil }
        let rrs = p.parsed["rr_intervals"]?.intArrayValue ?? []
        guard bpm != nil || !rrs.isEmpty else { return }
        if let bpm { live.hr.append(HRPoint(ts: ts, bpm: Double(bpm), source: .live)) }
        for rr in rrs { live.appendRR(ts: ts, rrMs: Double(rr), source: .live) }
        lastType40BeatAt = now
        noteBeat(bpm: bpm, rrMs: rrs.map(Double.init), at: now)
    }

    /// Standard 0x2A37 (works without the bond; source `std_2a37`). The type-40 stream feeds the UI when both run.
    func handleStandardHR(_ bytes: [UInt8]) {
        guard let m = HeartRateMeasurement.parse(bytes) else { return }
        let now = clock.now
        let ts = Int64(now.timeIntervalSince1970)
        if let bpm = m.bpm { live.hr.append(HRPoint(ts: ts, bpm: Double(bpm), source: .std2A37)) }
        for rr in m.rrMs { live.appendRR(ts: ts, rrMs: rr, source: .std2A37) }
        if let last = lastType40BeatAt, now.timeIntervalSince(last) < 1.5 { return }
        guard m.bpm != nil || !m.rrMs.isEmpty else { return }
        noteBeat(bpm: m.bpm, rrMs: m.rrMs, at: now)
    }

    private func noteBeat(bpm: Int?, rrMs: [Double], at: Date) {
        if let bpm {
            status.liveBPM = bpm
            status.liveAt = at
        }
        beatHub.yield(LiveBeat(at: at, bpm: bpm.map(Double.init), rrMs: rrMs))
    }

    /// EVENT (type 48). During an offload every EVENT also goes to the chunk. Only an event whose own timestamp is within its
    /// freshness window of now is acted on (a replayed wrist-off must not flip the state); wrist events use the wider window.
    func handleEvent(_ frame: [UInt8]) {
        if let run = historyRun { run.inbox.push(frame) }
        let p = parseFrame(frame, family: .whoop4)
        guard p.ok, p.crcOK != false, let event = Whoop4RecordMapper.strapEvent(frame: frame, parsed: p) else { return }
        let isWearEvent = event.number == 9 || event.number == 10
        let window = isWearEvent ? max(config.timing.freshEventWindow, config.timing.wearEventWindow)
                                 : config.timing.freshEventWindow
        let fresh = abs(Double(event.ts) - clock.now.timeIntervalSince1970) <= window
        if historyRun != nil, !fresh { return }   // a replayed record: it belongs to its chunk
        live.events.append(event)
        guard fresh else { return }
        eventHub.yield(event)
        // 0.6.0.11: every live event goes to the log (the 4.0 buzzed nonstop on Mo's first connect with nothing logged). Alarm
        // and haptic events are named (WHOOP4-WIRE: and 14 double tap, inventory §6): 56 alarm set, 57 alarm fired, 59 alarm disabled, 60 haptics fired, 100 haptics ended
        // (noop PROTOCOL.md event table).
        let names: [Int: String] = [14: "DOUBLE_TAP", 56: "STRAP_DRIVEN_ALARM_SET", 57: "STRAP_DRIVEN_ALARM_EXECUTED",
                                    59: "STRAP_DRIVEN_ALARM_DISABLED", 60: "HAPTICS_FIRED", 100: "HAPTICS_TERMINATED"]
        logLine("whoop4: event \(event.number)" + (names[Int(event.number)].map { " " + $0 } ?? ""))
        switch event.number {
        case 3:    // BATTERY_LEVEL: soc at frame 17, mV at 21, charging bit at 26 (noop PostHooks "event")
            if let percent = p.parsed["battery_pct"]?.doubleValue {
                noteBattery(percent, charging: p.parsed["battery_charging"]?.intValue.map { $0 != 0 }, ts: event.ts)
            }
        case 24: status.hrBroadcast = "on"    // BLE HR profile enabled (inventory §6; the read-back of command 14)
        case 25: status.hrBroadcast = "off"   // BLE HR profile disabled
        case 7: status.charging = true
        case 8: status.charging = false
        case 9: status.worn = true
        case 10: status.worn = false
        case 13:   // RTC_LOST → redo the clock (never mid-offload)
            if handshakeDone, historyRun == nil { Task { @MainActor [weak self] in await self?.runClockSync() } }
        default: break
        }
    }

    func noteBattery(_ percent: Double, charging: Bool?, ts: Int64? = nil) {
        status.batteryPercent = percent
        if let charging { status.charging = charging }
        live.battery.append(BatteryReading(ts: ts ?? Int64(clock.now.timeIntervalSince1970), percent: percent, charging: charging))
    }

    func flushLive() async {
        guard let sid = strapId, let batch = live.take(strapId: sid) else { return }
        do { try await liveSink.append(batch) } catch {
            live.putBack(batch)   // tried again at the next flush; nothing the strap sent is dropped because the store was busy
            logLine("whoop4: live append failed — \(describeError(error)); the batch is kept for the next flush")
        }
    }

    func flushLiveSoon() {
        Task { @MainActor [weak self] in await self?.flushLive() }
    }
}
