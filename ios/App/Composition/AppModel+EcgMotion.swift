import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSignal
import UIKit

// Wave W8 (2026-10-11) — the MG ECG reading (APP-033 / APP-039, ALG-014 HR) and raw motion R21 (ALG-113 / ALG-114 /
// CosinorAge input). CLAUDE.md rule 5: ECG start 123, 139, 125, 124 and stop 124, 125, 139; raw motion 81 + 106 [01 01]
// and 82 + 106 [01 00]; each family behind its own switch in Strap & sync — ON by default since 2026-10-11 21:43 PT (Mo;
// it used to say "OFF by default"). MGBLE refuses the ON writes while a switch is off; this file only asks.
//
// ECG + PPG together (Mo's ask): when raw optical (108, live R20) is on during a reading, both streams arrive as packet-43
// frames on the same link; every raw frame is stored with the phone's receive time (`raw_frame.received_at`), which is
// the shared clock, and the `ecg` event names the R20 / R21 spans it overlaps (`ppg_refs`, `imu_ref`).

/// The last 10 s of accelerometer magnitude for the Live trace (raw counts).
struct MotionTraceBuffer: Equatable {
    private(set) var values: [Double] = []
    private(set) var lastAt: Date?
    static let keep = 1000

    /// P9729: the last whole R21 seconds (with their strap times), so ALG-144's MOTION gate works live.
    private(set) var seconds: [MotionSecond] = []
    static let keepSeconds = 16

    mutating func append(_ m: MotionSecond, at: Date) {
        guard let c = m.columns else { return }
        seconds = Array((seconds + [m]).suffix(Self.keepSeconds))
        values += MotionSecond.magnitudes(c)
        if values.count > Self.keep { values.removeFirst(values.count - Self.keep) }
        lastAt = at
    }

    /// At most 250 points, empty when nothing arrived in the last 5 s.
    func recent(now: Date) -> [Double] {
        guard let lastAt, now.timeIntervalSince(lastAt) < 5, !values.isEmpty else { return [] }
        let step = max(1, values.count / 250)
        return stride(from: 0, to: values.count, by: step).map { values[$0] }
    }
}

/// One ECG reading on screen.
struct EcgSession {
    var phase: EcgReadingState.Phase = .ready
    var wrist: EcgWrist = .left
    var seconds = AppModel.ecgSeconds
    var startedAt: Date?
    var endsAt: Date?
    /// P9821: the timed session (5 s lead-in, 60 s kept); set when the strap acknowledged the start. Raw samples live here.
    var recorder: EcgSessionRecorder?
    var packets: [EcgTracePacket] { recorder?.packets ?? [] }
    var samples: [Int16] { recorder?.samples ?? [] }
    /// The newest packet seen, lead-in included (contact and strap status show from the first one).
    var lastPacket: EcgTracePacket?
    var filtered = true
    var expanded = false
    var terminalAt: Date?
    var result: EcgReadingResult?
    var blankReason: String?
    var opticalFramesAtStart = 0
    var motionSecondsAtStart = 0
    var finishing = false
}

extension AppModel {
    /// The timed recording: 60 s (Mo C13, 2026-10-15; it was 45 s) after a 5 s lead-in. The strap's own reading completed at
    /// 38-39 s in noop #891; whether the strap keeps streaming R17 up to 60 s is UNVERIFIED, so the reading no longer ends
    /// early at the strap's terminal frame: it runs to the time and shows what arrived.
    nonisolated static let ecgSeconds = Int(EcgSessionRecorder.recordSeconds)
    nonisolated static let ecgLeadInSeconds = Int(EcgSessionRecorder.leadInSeconds)

    // MARK: Wiring

    func wireEcgMotion(_ link: StrapLink) {
        for t in ecgMotionTasks { t.cancel() }
        ecgMotionTasks = []
        ecgMotionTasks.append(Task { [weak self, weak link] in
            guard let link else { return }
            for await st in link.$ecg.values { self?.ecgStatus = st }
        })
        ecgMotionTasks.append(Task { [weak self, weak link] in
            guard let link else { return }
            for await st in link.$rawMotion.values { self?.rawMotionChanged(st) }
        })
        let packets = link.ecgPackets
        ecgMotionTasks.append(Task { [weak self] in
            for await p in packets { self?.ecgPacket(p) }
        })
        let motion = link.liveRawMotion
        ecgMotionTasks.append(Task { [weak self] in
            for await m in motion {
                guard let self else { return }
                self.motionTrace.append(m, at: self.clock.now)
                self.feedLiveMotion(m)
            }
        })
        services.strap.setEcgSwitch(settings.ecgOn && !isSample)
        applyRawMotion()
    }

    /// R9f (T146): one new R21 second -> the Live tab's motion wave buffer (a `LivePPGFeed`, the same type the raw PPG graph
    /// uses): the accelerometer size of each sample at the second's own rate (100 a second). Only while the Live tab is on screen
    /// and the app is active, as `feedLivePPG` does; display only, nothing is stored or sent.
    func feedLiveMotion(_ m: MotionSecond) {
        guard appActive, liveOnScreen, let c = m.columns else { return }
        let samples = MotionSecond.magnitudes(c).map { Int32(clamping: Int($0.rounded())) }
        guard samples.count >= 10 else { return }
        LiveWaveFeeds.motion.append(id: 0, samples: samples, rateHz: Double(samples.count),
                                    arrivedAt: clock.now.timeIntervalSinceReferenceDate)
    }

    /// The raw-motion switch. CHANGED 2026-10-11 21:43 PT (wave W11, Mo: "Default on … the motion push too"): with the
    /// switch on it streams whenever the strap is connected, app open or not (CosinorAge needs 4+ whole days of minute
    /// ENMO; asymmetry needs the day). It used to stream only while the app was open or a session ran
    /// (`foreground: appActive`). MGBLE's foreground gate stays; the app now always passes "may run".
    func applyRawMotion() {
        if StrapDeviceChoice.stored == .whoop4 { return applyRawStreamWhoop4() }       // WHOOP4-WIRE 6: command 63, shared with raw optical
        services.strap.setRawMotion(enabled: rawMotionWantedNow, foreground: true)     // r9q: saved switch OR automatic reason
    }

    private func rawMotionChanged(_ st: RawMotionStatus) {
        let before = rawMotionStatus
        rawMotionStatus = st
        if let at = st.lastSecondAt, at != before.lastSecondAt { RawNightLog.noteR21(at: clock.now) }   // 0.5.8.1 morning check
        if before.on != st.on || before.switchOn != st.switchOn || before.sessionUntil != st.sessionUntil
            || before.stoppedReason != st.stoppedReason {
            Task { [weak self] in await self?.refresh() }
        }
    }

    func ecgMotionInfo() -> EcgMotionInfo {
        var i = EcgMotionInfo()
        i.ecgWanted = settings.ecgOn
        i.wrist = settings.ecgWrist
        i.ecgPhase = ecgStatus.phase.rawValue
        i.ecgOutcome = ecgStatus.outcome
        i.ecgStopOwed = ecgStatus.stopOwed
        i.motionWanted = settings.rawMotionOn
        i.motionOn = rawMotionStatus.on
        i.motionSeconds = rawMotionStatus.seconds
        i.motionLastAt = rawMotionStatus.lastSecondAt
        i.motionSessionUntil = rawMotionStatus.sessionUntil
        i.motionStopped = rawMotionStatus.stoppedReason
        i.trace = motionTrace.recent(now: clock.now)
        return i
    }

    // MARK: Intents

    func ecgMotion(_ action: EcgMotionAction) async {
        switch action {
        case .setEcgSwitch(let on):
            guard !isSample else { return showNotice("Sample data is on — the strap is not asked for ECG.") }
            settings.ecgOn = on
            await saveState()
            services.strap.setEcgSwitch(on)
            showNotice(on ? "ECG on: take a reading from the Live tab. Nothing is sent until you start one." : "ECG off.")
        case .setWrist(let wrist):
            guard wrist == "left" || wrist == "right" else { return }
            settings.ecgWrist = wrist
            await saveState()
        case .setRawMotion(let on):
            guard !isSample else { return showNotice("Sample data is on — the strap is not asked for raw motion.") }
            settings.rawMotionOn = on
            await saveState()
            applyRawMotion()
            applyRealtime()       // T9984: keeps live HR (and the app) running in the background while it is on
            showNotice(on ? "Raw motion on: the strap streams its 100 Hz IMU whenever it is connected (uses strap "
                            + "battery; Settings › Usage shows the cost)." : "Raw motion off.")
        case .rawMotionSession(let minutes):
            if StrapDeviceChoice.stored == .whoop4 {      // WHOOP4-WIRE 6: no timed sessions on the 4.0; it streams while the switch is on
                showNotice(StrapNotices.timedSessionNotOn4)
                break
            }
            if let why = await services.strap.rawMotionSession(seconds: Double(minutes) * 60) {
                showNotice("Raw motion session not started: \(why)")
            } else if minutes > 0 {
                showNotice("Recording raw motion for \(minutes) min — it keeps going with the phone locked.")
            }
        case .beginECG:
            await beginECG()
        case .finishECG:
            await finishECG(reason: "stopped by you")
        case .setEcgFiltered(let on):
            ecgSession?.filtered = on
            presentEcgReading()
        case .setEcgExpanded(let on):
            ecgSession?.expanded = on
            presentEcgReading()
        case .closeECG:
            await closeECG()
        }
        await refresh()
    }

    // MARK: ECG reading

    var ecgBlockedReason: String? {
        if isSample { return "Sample data is on: there is no strap to read." }
        if !settings.ecgOn { return "ECG is off. Turn it on in Strap & sync." }
        switch strapLinkState {
        case .ready: break
        case .downloadingHistory: return "The strap is downloading history — try again when it finishes."
        default: return "Strap not connected."
        }
        if let off = offWristSince {
            return "Strap's off your wrist since \(MGFormat.time(off, calendar: calendar)) — put it on, then try again."
        }
        return nil
    }

    /// `.startECG` (Live tile, the possible-AF moment): opens the guided screen.
    func openECG() {
        var s = EcgSession()
        s.wrist = settings.ecgWrist == "right" ? .right : .left
        if let why = ecgBlockedReason {
            s.phase = .blocked
            s.blankReason = why
        }
        ecgSession = s
        presentEcgReading()
        cover = .ecg
        applyRealtime()
    }

    func beginECG() async {
        guard let current = ecgSession, current.phase != .starting, current.phase != .recording else { return }
        var s = EcgSession()
        s.wrist = settings.ecgWrist == "right" ? .right : .left
        s.filtered = current.filtered
        if let why = ecgBlockedReason {
            s.phase = .blocked
            s.blankReason = why
            ecgSession = s
            return presentEcgReading()
        }
        s.phase = .starting
        s.opticalFramesAtStart = rawOpticalStatus.frames
        s.motionSecondsAtStart = rawMotionStatus.seconds
        ecgSession = s
        presentEcgReading()
        UIApplication.shared.isIdleTimerDisabled = true
        // MGBLE's own limit is a backstop 15 s past the screen's (it stops the strap even if the app is suspended).
        switch await services.strap.startEcgReading(wrist: s.wrist, seconds: Double(Self.ecgLeadInSeconds + s.seconds + 15)) {
        case .success:
            let now = clock.now
            let rec = EcgSessionRecorder(startedAt: now.timeIntervalSince1970)
            ecgSession?.phase = .recording
            ecgSession?.recorder = rec
            ecgSession?.startedAt = Date(timeIntervalSince1970: rec.recordingStart)
            ecgSession?.endsAt = Date(timeIntervalSince1970: rec.recordingEnd)
        case .failure(let why):
            ecgSession?.phase = .blocked
            ecgSession?.blankReason = why.text
            UIApplication.shared.isIdleTimerDisabled = false
        }
        presentEcgReading()
    }

    func ecgPacket(_ p: EcgLivePacket) {
        guard var s = ecgSession, s.phase == .recording || s.phase == .starting, !s.finishing else { return }
        s.lastPacket = p.packet
        s.recorder?.accept(p.packet, samples: p.samples)    // trimmed by sample time: nothing from the lead-in, exactly 60 s
        if p.terminal, s.terminalAt == nil { s.terminalAt = clock.now }
        ecgSession = s
        // Finish on the 60 s of samples, not on the once-a-second refresh (which a suspended app does not get).
        if s.recorder?.isFull == true { Task { [weak self] in await self?.finishECG(reason: "60 s recorded") } }
        presentEcgReading()
    }

    /// Once a second (refreshLive): time up, or 3 s after the strap's terminal frame.
    func advanceEcg() {
        guard let s = ecgSession, s.phase == .recording, !s.finishing else { return }
        let now = clock.now
        if let end = s.recorder?.finishDeadline, now.timeIntervalSince1970 >= end {
            Task { [weak self] in await self?.finishECG(reason: "time up") }
        } else {
            presentEcgReading()    // the lead-in countdown and the live heart rate move once a second
        }
    }

    func finishECG(reason: String) async {
        guard var s = ecgSession, s.phase == .recording || s.phase == .starting, !s.finishing else { return }
        s.finishing = true
        ecgSession = s
        await services.strap.stopEcgReading(reason: reason)
        UIApplication.shared.isIdleTimerDisabled = false
        let result = await saveECG(s, end: clock.now)
        ecgSession?.phase = .result
        ecgSession?.result = result
        // R9f (T146): the Live tab's ECG row draws this reading (display filter when it exists, else the raw counts).
        let shown = result.filteredTrace.isEmpty ? result.trace : result.filteredTrace
        if !shown.isEmpty {
            LiveECGMemory.shared.set(at: clock.now, seconds: s.seconds, samples: shown, filtered: !result.filteredTrace.isEmpty)
        }
        ecgSession?.finishing = false
        presentEcgReading()
    }

    func closeECG() async {
        if let s = ecgSession, s.phase == .recording || s.phase == .starting {
            await finishECG(reason: "closed")
        }
        cover = nil
        ecgSession = nil
        presentEcgReading()
        UIApplication.shared.isIdleTimerDisabled = false
        applyRealtime()
    }

    /// D-HRV-WALK-1 (r9l, 2026-10-17): a finished 60 s ECG that started before noon is also the morning check - RMSSD and
    /// lnRMSSD from its refined R-peaks, stored as hrv_rmssd / hrv_ln_rmssd variant ALG-010:spot60, window morning, the
    /// enhanced input of the readiness score (ALG-160). A reading that fails its rules is not stored (it must not replace
    /// a good one from earlier the same morning); the line returned says why. nil when sample data is on.
    private func recordMorningCheck(_ s: EcgSession, start: Date, end: Date) async -> String? {
        guard !isSample else { return nil }
        guard MorningCheck.isMorning(start, calendar: calendar) else {
            return "Not stored as a morning check: it started after \(MorningCheck.latestMorningHour):00"
        }
        let reading = MorningCheck.ecg(samples: s.samples, packets: s.packets)
        guard let r = reading.value else {
            return "Morning check not stored: \(reading.missingReason ?? "no reading")"
        }
        // D-BODY-WALK-1: pin to the Apple ECG of the same morning (hr_avg, variant apple_health:ecg, window ecg:<HHMM>) when one exists
        let day = LocalDay(date: start, calendar: calendar)
        let apple = ((try? await services.store.metrics(on: day, includingImported: true)) ?? [])
            .filter { $0.name == MetricKey.hrAvg.rawValue && ($0.window ?? "").hasPrefix("ecg") && $0.value != nil }
        let appleBpm = apple.first?.value
        let strapBpm = 60_000.0 / r.meanRR
        let pinNote = MorningCheck.pinNote(appleBpm.map { MorningCheck.pin(strapBpm: strapBpm, appleBpm: $0) },
                                           strapBpm: strapBpm, appleBpm: appleBpm, on: day.iso)
        do {
            _ = try await services.store.upsertMetrics(MorningCheck.metrics(reading, fromEcg: true, at: end, pinNote: pinNote),
                                                       day: day)
        } catch {
            return "Morning check not saved: \(error)"
        }
        return "Morning check stored (decoded, untested): RMSSD \(Int(r.rmssd.rounded())) ms from \(r.beats) beats; "
            + "it feeds the readiness HRV part"
    }

    /// ALG-014 HR from the R-peaks (research), the strap's own screen and status bytes kept raw, the samples and the
    /// `ecg` event saved. Raw frames are already in `raw_frame` (pinned around the event, sent to the PC raw).
    private func saveECG(_ s: EcgSession, end: Date) async -> EcgReadingResult {
        let terminal = s.packets.last { $0.classifierState == 2 || $0.progress == 100 } ?? s.packets.last
        var together: [String] = []
        let optical = rawOpticalStatus.frames - s.opticalFramesAtStart
        if optical > 0 { together.append("Recorded with raw optical: \(optical) R20 record(s), same phone clock") }
        let motion = rawMotionStatus.seconds - s.motionSecondsAtStart
        if motion > 0 { together.append("Recorded with raw motion: \(motion) s of R21, same phone clock") }
        guard let start = s.startedAt, let last = terminal else {
            return EcgReadingResult(
                heartRate: nil, heartRateReason: "no ECG records arrived",
                heartRateNote: "The strap acknowledged the start but sent no waveform. Check that the finger rests on the "
                    + "sensor; if it repeats, the strap may not stream ECG on this firmware.",
                strapScreen: "No strap screen: no records.", strapHeartRate: nil, saved: "Nothing saved: no records.",
                together: together, trace: [])
        }
        let hr = ALG014.heartRate(samples: s.samples, packets: s.packets)
        let screen = ALG014.strapScreenWords(code: last.resultCode, state: last.classifierState)
        let strapHR = last.averageHR > 0 ? "The strap's own average: \(last.averageHR) bpm" : nil
        let id = UUID()
        var ours: [String: JSONValue] = [
            "tier": .string("research"), "method": .string("ALG-014@1 pan-tompkins"),
            "packets": .number(Double(s.packets.count)), "samples": .number(Double(s.samples.count)),
            "wrist": .string(s.wrist == .right ? "right" : "left"),
            "session": .string("live-ecg@1"), "lead_in_s": .number(EcgSessionRecorder.leadInSeconds),
            "record_s": .number(EcgSessionRecorder.recordSeconds),
        ]
        switch hr {
        case .success(let r):
            ours["hr_bpm"] = .number(r.bpm)
            ours["beats"] = .number(Double(r.beats))
            ours["rate_hz_measured"] = .number(r.rateHz)
            ours["seconds_analysed"] = .number(r.seconds)
        case .failure(let m):
            ours["hr_reason"] = .string(m.reason)
        }
        let strapStatus: [String: JSONValue] = [
            "result_code": .number(Double(last.resultCode)), "classifier_state": .number(Double(last.classifierState)),
            "progress": .number(Double(last.progress)), "quality": .number(Double(last.quality)),
            "flags": .number(Double(last.flags)), "unreadable": .number(Double(last.unreadable)),
            "average_hr": .number(Double(last.averageHR)), "live_hr": .number(Double(last.liveHR)),
            "screen_words": .string(screen),
        ]
        let t0 = Int(start.timeIntervalSince1970), t1 = Int(end.timeIntervalSince1970)
        let fields = ECGFields(end: end, rateHz: hr.value?.rateHz, samplesRef: EcgTrace.ref(id),
                               ppgRefs: optical > 0 ? ["ppg_block:r20:\(t0)-\(t1)"] : nil,
                               imuRef: motion > 0 ? "motion_second:\(t0)-\(t1)" : nil,
                               strapStatus: strapStatus, ours: ours, wristOnly: true)
        let event = EventRecord(id: id, type: .ecg, at: start, loggedAt: end, source: .strap, payload: .ecg(fields))
        var saved: String
        do {
            let savedTrace = EcgTrace(eventId: id, strapId: strapInfo?.strapId, samples: s.samples, packets: s.packets)
            try await services.store.saveEcgTrace(savedTrace, startedAt: start)
            // T9821: the decoded session goes to the PC as its own drop with the next sync (failure leaves it on the phone only)
            if !isSample { try? await services.sync.enqueueEcg(savedTrace, startedAt: start) }
            if await write(event, undoable: false) != nil {
                saved = "Saved \(MGFormat.time(end, calendar: calendar)) · samples on the phone; the raw frames go to the "
                    + "PC with the next sync"
            } else {
                saved = "Samples stored; the reading's event was not saved (see the notice)."
            }
        } catch {
            saved = "Not saved: \(error)"
        }
        if let line = await recordMorningCheck(s, start: start, end: end) { together.append(line) }
        let step = max(1, s.samples.count / 600)
        let trace = stride(from: 0, to: s.samples.count, by: step).map { Double(s.samples[$0]) }
        // T9821: heart rate, R-R spread, quality, contact and rhythm class in words (MGSignal EcgBreakdown, ALG-014 part)
        let breakdown = EcgBreakdown.rows(samples: s.samples, packets: s.packets, result: hr)
            .map { EcgBreakdownRow(label: $0.label, value: $0.value, note: $0.note) }
        var filteredTrace: [Double] = []
        if let fs = ALG014.rate(s.packets).value {
            let f = EcgFilter.display(s.samples.map(Double.init), fs: fs)
            filteredTrace = stride(from: 0, to: f.count, by: step).map { f[$0] }
        }
        switch hr {
        case .success(let r):
            var out = EcgReadingResult(
                heartRate: "\(Int(r.bpm.rounded())) bpm", heartRateReason: nil,
                heartRateNote: "Research tier · our R-peaks (Pan-Tompkins) · \(r.beats) beats in "
                    + "\(Int(r.seconds.rounded())) s · rate \(Int(r.rateHz.rounded())) Hz measured from arrival times",
                strapScreen: screen, strapHeartRate: strapHR, saved: saved, together: together, trace: trace)
            out.filteredTrace = filteredTrace
            out.breakdown = breakdown
            return out
        case .failure(let m):
            var out = EcgReadingResult(heartRate: nil, heartRateReason: m.reason,
                                    heartRateNote: "Research tier · our R-peaks (Pan-Tompkins)", strapScreen: screen,
                                    strapHeartRate: strapHR, saved: saved, together: together, trace: trace)
            out.filteredTrace = filteredTrace
            out.breakdown = breakdown
            return out
        }
    }

    func presentEcgReading() {
        guard let s = ecgSession else { return setIfChanged(\.ecgReading, nil) }
        let wrist = s.wrist == .right ? "right" : "left"
        let other = wrist == "right" ? "left" : "right"
        let status = s.lastPacket.map {
            "Contact: \($0.presence ? "yes" : "not yet") · quality code \($0.quality) · strap progress \($0.progress) %"
        }
        let now = clock.now.timeIntervalSince1970
        var state = EcgReadingState(
            sample: isSample, phase: s.phase, wrist: wrist,
            steps: ["The strap is on your \(wrist) wrist (Strap & sync changes it).",
                    "Rest a fingertip of your \(other) hand lightly on the strap's sensor. Arm relaxed, no squeezing.",
                    "A 5 s countdown comes first, then \(s.seconds) s are recorded. It stops by itself."],
            seconds: s.seconds, startedAt: s.startedAt, endsAt: s.endsAt,
            trace: s.samples.suffix(400).map(Double.init), statusLine: status, packets: s.packets.count,
            result: s.result, blankReason: s.blankReason)
        state.filtered = s.filtered
        state.expanded = s.expanded
        if let rec = s.recorder, s.phase == .recording {
            let leadIn = rec.phase(at: now) == .leadIn
            state.leadInSecondsLeft = leadIn ? rec.secondsLeft(at: now) : nil
            state.contactLine = s.lastPacket.map { "Contact: \($0.presence ? "yes" : "not yet")" }
            let shown = rec.trace(seconds: s.expanded ? EcgSessionRecorder.recordSeconds : 8, filtered: s.filtered)
            let step = max(1, shown.count / 600)
            state.trace = stride(from: 0, to: shown.count, by: step).map { shown[$0] }
            if !leadIn {
                switch rec.liveHeartRate() {
                case .success(let bpm): state.liveHeartRate = "\(bpm) bpm"
                case .failure(let m): state.liveHeartRateReason = m.reason
                }
            }
            state.traceLabel = s.filtered
                ? "Filtered: 0.5-40 Hz band-pass + powerline notch, zero-phase · display only, the saved samples are raw"
                : "Unfiltered counts · decoded, untested · no voltage scale"
        }
        setIfChanged(\.ecgReading, state)
    }
}
