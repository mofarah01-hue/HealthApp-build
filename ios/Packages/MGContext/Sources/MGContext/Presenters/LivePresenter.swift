import Foundation
import MGDomain

/// The Live tab (UX §6) and Workout mode in place. Strap off / not connected: everything blank with the reason (§13).
public enum LivePresenter {
    /// `UIIntent.openResearch` id of the Raw 4.0 screen (the app opens that screen instead of a research page).
    public static let whoop4RawResearchID = "whoop4raw"
    static let noAwakeSpO2 = "No known command starts an awake reading."

    /// Why nothing streams, in UX §13 words; nil when live data is flowing.
    static func blankReason(_ s: PresenterSnapshot) -> String? {
        // 0.6.0.4 (Mo Oct 26, 1:10 AM: "live tab for hr still asking for the whoop"): with the ring as the active input
        // the strap's link state is irrelevant; the ring measures HR in ~20 s spots that the app repeats while Live is open.
        let si = s.strapSync
        if InputDeviceRule.active(setting: si.inputDevice, strapLinkUp: si.strapLinkUp, ringConnected: si.ringConnected) == .ring {
            guard si.ringConnected else {
                return "Ring not connected yet — wake it (a few seconds on the charger) and keep it near the phone."
            }
            if s.live == nil { return "Ring connected — waiting for its first heart rate (it measures in ~20 s spots)." }
            return nil
        }
        let strap = s.inputs.strap
        switch strap.link {
        case .notPaired: return "No strap paired yet — pair your \(s.pairName) to see live data."
        case .bluetoothOff: return "Bluetooth is off — nothing to show live."
        case .bluetoothNotAllowed: return "iOS hasn't allowed MG to use Bluetooth — nothing to show live. iOS Settings › MG › Bluetooth."
        case .searching, .connecting: return "Looking for your strap — nothing streaming yet."
        case .disconnected:
            return "Strap not connected" + (strap.notConnectedReason.map { " (" + $0 + ")" } ?? "") + " — nothing to show live."
        case .connected: break
        }
        if let off = strap.offWristSince {
            if strap.offWristMayBeStale {
                return "Strap may be off your wrist (off since \(s.hm(off)) when the app last looked) — nothing to show live until beats confirm."
            }
            return "Strap's off your wrist — nothing to show live. Off since \(s.hm(off))."
        }
        if s.live == nil { return "Connected — waiting for the first beats." }
        return nil
    }

    public static func make(_ s: PresenterSnapshot) -> LiveState {
        let reason = blankReason(s)
        let live = reason == nil ? s.live : nil
        let strapR = Receipt(computedOn: .strap, tier: .strap, at: live?.heartRateAt ?? s.now, method: "live HR")
        let hr: DisplayValue
        if let v = live?.heartRate, v.isFinite {
            hr = s.worded(MGFormat.number(v, decimals: 0), unit: "bpm", receipt: strapR)
        } else {
            hr = .blank(reason: reason ?? "No beat in the last few seconds.", receipt: nil)
        }
        let blankOr: (Metric?) -> DisplayValue = { m in
            if let reason { return .blank(reason: reason, receipt: nil) }
            return s.display(m, missing: "Needs 5 minutes of clean beats.")
        }
        var load = blankOr(live?.autonomicLoad)
        var level: Double?
        if let m = live?.autonomicLoad, let z = m.value, z.isFinite, reason == nil {
            load = s.worded(loadWord(z), receipt: MetricText.receipt(m), style: .estimate(nil))
            level = min(1, max(0, (z + 3) / 6))
        }
        let median: DisplayValue
        if let v = live?.rrMedianMs, v.isFinite {
            median = s.worded(MGFormat.number(v, decimals: 0), unit: "ms",
                              receipt: Receipt(computedOn: .phone, tier: .high, at: s.now, method: "ALG-004 clean R-R"))
        } else {
            median = .blank(reason: reason ?? "Too few clean beats in the last minute.", receipt: nil)
        }
        let streaming = reason == nil
        let chip: StreamChipState
        if let hz = live?.pulseHz, let source = live?.pulseSource {
            // Bug 3: the wave is raw optical (R20), not R26 — say which, with no quality word nobody computed.
            chip = StreamChipState(text: "\(source) · \(MGFormat.number(hz, decimals: 0)) Hz", tone: .good)
        } else if let hz = live?.pulseHz {
            let q = live?.pulseQuality ?? "quality unknown"
            chip = StreamChipState(text: "R26 · \(MGFormat.number(hz, decimals: 0)) Hz · \(q.hasPrefix("quality") ? q : "quality " + q)",
                                   tone: q.contains("poor") ? .warn : .good)
        } else {
            chip = StreamChipState(text: streaming ? "HR only" : "No stream", tone: streaming ? .warn : .neutral)
        }
        let wo = workoutMode(s)
        // #35: the HR line shows while streaming and while connected on the wrist waiting for the first beat (it is
        // already full from the store); strap off or not connected = blank like everything else (UX §13).
        let waiting = s.inputs.strap.link == .connected && s.inputs.strap.offWristSince == nil
        let trace = (streaming || waiting) ? s.liveHRTrace : []
        var state = LiveState(
            sample: s.sample, streamChip: chip, heartRate: hr, beatInterval: live?.beatInterval,
            rmssd: blankOr(live?.rmssd5min), autonomicLoad: load, autonomicLevel: level,
            pulseWave: live?.pulseWave ?? [], pulseQuality: live?.pulseQuality, tachogram: live?.rr ?? [],
            tachogramMedian: median, streams: streams(s, live), actions: actions(s, streaming: streaming, workoutLive: wo != nil),
            broadcast: StrapSyncPresenter.broadcastToggle(s),
            researchLinks: [
                ActionState(id: "inspector", title: "Record inspector", intent: .openResearch("inspector")),
                ActionState(id: "capture", title: "Capture session", intent: .openResearch("capture")),
                ActionState(id: "retention", title: "Raw retention", intent: .openResearch("retention")),
                historyReadTestLink(s),
            ],
            workout: wo, blankReason: reason, hrTrace: trace,
            hrTraceEnd: s.liveBackfill.flatMap { $0.usesStoredTail ? $0.end : nil } ?? s.now)
        state.blankReasonNeedsSettings = s.inputs.strap.link.needsOpenSettings   // T141
        // 0.6.0.12: the two big tiles: solid, grey with the reason, or blank (nothing streams).
        state.rmssdTile = LiveTilePresenter.rmssd(live?.hrv, blankReason: reason, now: s.now)
        let loadTile = LiveTilePresenter.load(live: live?.autonomicLoad, stored: LiveTilePresenter.storedLoad(s),
                                              blankReason: reason, calendar: s.calendar)
        state.loadTile = loadTile.tile
        state.deviceName = s.deviceName
        state.hrSourceNote = live?.hrSource.map { "Heart rate from \($0)" }
        if s.whoop4Selected {
            state.whoop4RawLink = ActionState(id: "whoop4raw", title: "Raw WHOOP 4.0 data", intent: .openResearch(whoop4RawResearchID))
        }
        state.rmssdCard = HRVExplainerPresenter.make(.rmssd, reading: s.live?.hrv, lnNights: s.hrvLnNights)
        state.loadCard = HRVExplainerPresenter.make(.load, reading: s.live?.hrv, lnNights: s.hrvLnNights)
        if loadTile.tile.kind == .solid { state.autonomicLevel = loadTile.level }
        state.hrTraceNote = s.liveBackfill?.hrNote        // wave W11: "last 5 min of stored data, ending 9:12 PM"
        state.tachogramNote = s.liveBackfill?.rrNote
        // T148/T145 root cause: this used `live` (nil whenever the tab has a blank reason: strap may be off the wrist, no beat
        // yet), so records that were arriving drew nothing. The wave depends only on the raw records, not on the heart rate.
        let fullWaves = opticalWaves(s, s.live)                 // wave 4
        state.streamToggles = streamToggles(s)               // T144
        state.streamsMaster = streamsMaster(state.streamToggles)   // T148
        state.opticalNote = opticalNote(s, hasWaves: !fullWaves.isEmpty)   // T143
        let feedIDs = LiveFeedProbe.shared.ids()
        let motion = EcgMotionPresenter.live(s)
        state.waveRows = LiveWaves.rows(s, toggles: state.streamToggles, optical: fullWaves,
                                        motion: motion, opticalNote: state.opticalNote,
                                        feedIDs: feedIDs)   // T146
        // R8j (L1): the Raw PPG row already draws these waves, so the Pulse wave box repeats them only when that row has
        // none (its switch is off) - and it always shows a real R26 wave. T22: the first raw wave that is not ambient,
        // named by its stored LED-drive bytes (which wavelength it is stays unconfirmed, T20).
        let rawRowDraws = state.waveRows.first(where: { $0.id == "ppg" })?.waves.isEmpty == false
        var fromRaw = s.live?.pulseSource != nil
        if state.pulseWave.isEmpty, let w = fullWaves.first(where: { !$0.label.hasSuffix("ambient") }) {
            fromRaw = true
            if !rawRowDraws {
                state.pulseWave = w.samples
                state.pulseQuality = w.label
            }
        }
        if !state.pulseWave.isEmpty, s.live?.pulseSource != nil || s.live?.pulseHz == nil,
           let q = state.pulseQuality, !q.contains("decoded, untested") {
            state.pulseQuality = q + " (decoded, untested)"
        }
        // R8j (L8): the state keeps ids and labels only for waves the smooth view draws from the feed.
        state.opticalWaves = LiveWaves.thin(fullWaves, feedIDs: feedIDs)
        state.pulseNote = pulseNote(s.live)
        state.pulseBlank = pulseBlank(s)
        if let c = s.live?.cleanPulse {        // P9729: the ALG-144 cleaned wave beside the raw one
            state.cleanWave = c.wave
            state.cleanChip = cleanChip(c)
            state.cleanNote = cleanNote(c)
        }
        // R8j (L1): the same raw PPG is not kept (or drawn) a second and third time. The Raw PPG card draws the trace and the
        // cleaned line and carries the pulse-rate lines; the Pulse wave box stays for a real R26 wave and for a raw row that
        // draws nothing.
        state.pulseFromRaw = fromRaw
        if fromRaw, rawRowDraws {
            state.pulseWave = []
            state.cleanWave = []
        }
        state.motion = motion  // wave W8: raw motion R21 trace and sessions
        state.historyReadTest = s.strapSync.historyReadTest   // wave W12b
        state.stressToday = FrontPagePresenter.stressTotal(s)   // T127
        let today = FrontPagePresenter.strapItems(s)             // r9t: average and time worn today beside the live HR
        state.averageToday = today.first { $0.id == "hrAvg" }?.value ?? state.averageToday
        state.wornToday = today.first { $0.id == "worn" }?.value ?? state.wornToday
        return state
    }

    /// T144 (Mo 2026-10-12): the raw PPG, 100 Hz motion and ECG switches on the Live tab itself, in every state (also
    /// strap away or the switch off — the old motion block only appeared once its switch was on). Same toggles and
    /// intents as Strap & sync, so both places always agree.
    static func streamToggles(_ s: PresenterSnapshot) -> [ToggleState] {
        let link = s.inputs.strap.link
        let sec = EcgMotionPresenter.strapSection(s, link: link)
        return [StrapSyncPresenter.rawOpticalSection(s, link: link).toggle, sec.motion, sec.ecg]
    }

    /// T148: the master button. Only switches that can be changed take part (sample data disables all three). A tap turns
    /// the ones that are off on; with all on, it turns all off. It sends each switch's own intent, nothing new.
    static func streamsMaster(_ toggles: [ToggleState]) -> StreamsMasterState {
        let usable = toggles.filter(\.enabled)
        let on = toggles.filter(\.isOn).count
        let text = "Streams: \(on) of \(toggles.count) on"
        guard !usable.isEmpty else {
            return StreamsMasterState(text: text, title: "Turn all on", enabled: false,
                                      disabledReason: toggles.first?.disabledReason ?? "No streams available.")
        }
        let allOn = usable.allSatisfy(\.isOn)
        return StreamsMasterState(text: text, title: allOn ? "Turn all off" : "Turn all on",
                                  intents: (allOn ? usable : usable.filter { !$0.isOn }).map(\.intent), enabled: true)
    }

    /// T143: one line saying why the raw PPG wave is not on screen. Nil while it shows, or while the switch is off
    /// and nothing stopped it. Raw counts carry no unit (CLAUDE.md rule 4).
    static func opticalNote(_ s: PresenterSnapshot, hasWaves: Bool) -> String? {
        let i = s.strapSync
        if let stopped = i.rawOpticalStopped { return "Raw PPG is off — \(stopped). Tap the switch to start it again." }
        guard i.rawOpticalWanted, !s.sample, !hasWaves else { return nil }
        if s.inputs.strap.link != .connected { return "Raw PPG is on — waiting for the strap." }
        return i.rawOpticalFrames == 0 ? "Raw PPG is on — no records yet."
            : "Raw PPG is on — no records in the last few seconds."
    }

    /// Bug 3 (2026-10-14): why the Pulse wave box is empty, honestly. The strap's ordinary pulse records (R26 / v26) come
    /// only with the history download, never live, so the live wave needs the raw optical switch (108).
    static let r26NotLive = "The strap's ordinary pulse records come only with the history download, not live."

    /// The line under a showing wave: the rate found in it, or why none was.
    static func pulseNote(_ live: LiveInput?) -> String? {
        if let bpm = live?.pulseRateBpm, bpm.isFinite {
            return "Pulse in this wave: \(MGFormat.number(bpm, decimals: 0)) bpm (research, decoded, untested)"
        }
        return live?.pulseNote.map { "No pulse rate: \($0)" }
    }

    static func pulseBlank(_ s: PresenterSnapshot) -> String {
        if s.sample { return "Sample data is on — no strap pulse wave." }
        let i = s.strapSync
        if let stopped = i.rawOpticalStopped {
            return "Raw optical is off — \(stopped). Turn it on in Live (Raw PPG switch, uses strap battery). " + r26NotLive
        }
        guard i.rawOpticalWanted else {
            return "Raw optical is off — turn it on in Live (Raw PPG switch, uses strap battery). " + r26NotLive
        }
        if s.inputs.strap.link != .connected { return "Raw optical is on — waiting for the strap." }
        if let why = s.live?.pulseNote { return "No pulse wave: \(why)." }
        return i.rawOpticalFrames == 0 ? "Raw optical is on — no records yet."
            : "Raw optical is on — no records in the last few seconds."
    }

    /// Wave W12b (#111/#119): "Test: read history without deleting" — runs only with the strap connected, one at a time.
    static func historyReadTestLink(_ s: PresenterSnapshot) -> ActionState {
        let title = "Test: read history without deleting"
        let intent = UIIntent.openResearch("historyReadTest")
        if s.sample { return ActionState(id: "historyReadTest", title: title, intent: intent, enabled: false,
                                         disabledReason: "Sample data is on — the strap is not asked.") }
        if s.strapSync.historyReadTestRunning {
            return ActionState(id: "historyReadTest", title: title, intent: intent, enabled: false,
                               disabledReason: "Running — the normal history download waits until it ends.")
        }
        guard s.inputs.strap.link == .connected else {
            return ActionState(id: "historyReadTest", title: title, intent: intent, enabled: false,
                               disabledReason: "Needs the strap connected.")
        }
        return ActionState(id: "historyReadTest", title: title, intent: intent)
    }

    /// Autonomic load in words from ALG-054's z against your baseline (same ±1 band as UX §12 "in band").
    static func loadWord(_ z: Double) -> String {
        if z >= 1 { return "higher than usual" }
        if z <= -1 { return "lower than usual" }
        return "about usual"
    }

    /// T20: both physical reading slots in every live raw-optical block. The stored drive bytes label each trace;
    /// all-zero drives identify the ambient measurement without assigning unverified wavelengths.
    static func opticalWaves(_ s: PresenterSnapshot, _ live: LiveInput?) -> [OpticalWave] {
        // WHOOP4-WIRE 6: the 4.0 sends ONE optical waveform (type 43, 1921); no block map, no LED identity.
        if let w4 = live?.opticalWhoop4, !w4.isEmpty {
            let samples = LiveWaves.detrended(w4)
            guard samples.count >= 2 else { return [] }
            return [OpticalWave(id: LiveWaves.whoop4OpticalID, label: LiveWaves.whoop4OpticalLabel, samples: samples)]
        }
        guard let rec = live?.opticalRecent, !rec.isEmpty else { return [] }
        var out: [OpticalWave] = []
        for block in rec.sorted(by: { $0.index < $1.index }) where block.head.count >= 7 {
            let drive = [block.head[2], block.head[3], block.head[5], block.head[6]]
            let bytes = drive.map { String(format: "%02X", $0) }
            let ambient = drive.allSatisfy { $0 == 0 } ? " · ambient" : ""
            for (slot, raw) in [block.slotA, block.slotB].enumerated() {
                let samples = LiveWaves.detrended(raw)      // T22: clipped samples dropped, drift removed
                guard samples.count >= 2 else { continue }
                let label = "Block \(block.index) · slot \(slot == 0 ? "A" : "B") · LED drive bytes "
                    + "A \(bytes[0]) \(bytes[1]), B \(bytes[2]) \(bytes[3])\(ambient)"
                out.append(OpticalWave(id: block.index * 2 + slot, label: label, samples: samples))
            }
        }
        return out
    }

    static func streams(_ s: PresenterSnapshot, _ live: LiveInput?) -> [StreamLine] {
        var out: [StreamLine] = []
        // Bug 3 (2026-10-14): R26 never arrives live, so "not flowing" / "flag not read" read as a fault; say why instead.
        if let hz = live?.pulseHz, live?.pulseSource == nil {
            out.append(StreamLine(id: "r26", text: "R26 pulse, \(MGFormat.number(hz, decimals: 0)) Hz, flowing", tone: .good))
        } else {
            out.append(StreamLine(id: "r26", text: "R26 pulse not sent live", tone: .neutral,
                                  note: "its records come with the history download"))
        }
        switch live?.fiftyHzFlag {
        case .some(true): out.append(StreamLine(id: "50hz", text: "50 Hz mode flag on", tone: .good))
        case .some(false): out.append(StreamLine(id: "50hz", text: "50 Hz mode flag off", tone: .neutral))
        case .none: out.append(StreamLine(id: "50hz", text: "50 Hz mode flag not sent live", tone: .neutral,
                                          note: "it rides on the history pulse records"))
        }
        // 2026-10-11: R20 comes from the raw optical switch (108), not from a flag unlock.
        if s.strapSync.rawOpticalOn {
            out.append(StreamLine(id: "r20", text: "R20 raw optical on · \(s.strapSync.rawOpticalFrames) records",
                                  tone: .good, note: "5 blocks · 25 Hz · raw counts"))
        } else {
            out.append(StreamLine(id: "r20", text: "R20 raw optical off", tone: .neutral,
                                  note: "Strap & sync › Raw optical"))
        }
        return out
    }

    static func actions(_ s: PresenterSnapshot, streaming: Bool, workoutLive: Bool) -> [ActionState] {
        let needStrap = "Needs the strap on your wrist and connected."
        return [
            ActionState(id: "breathe", title: "Breathe", intent: .startBreathe),
            ActionState(id: "hrv", title: "HRV check", intent: .startHRVCheck(minutes: 3), enabled: streaming,
                        disabledReason: streaming ? nil : needStrap),
            // Wave W8 (2026-10-11): was always disabled ("policy-gated"); rule 5 now allows the reading behind its switch.
            EcgMotionPresenter.ecgAction(s, streaming: streaming),
            workoutLive
                ? ActionState(id: "workout", title: "End workout", intent: .endWorkout)
                : ActionState(id: "workout", title: "Workout", intent: .startWorkout),
            // Wave 4 (#62 closed by research): no command takes a reading, so this opens the SpO₂ screen, which says
            // so in one sentence (SpO2Gate.noOnDemand) — it used to be a disabled "SpO₂ now" button.
            ActionState(id: "spo2", title: "SpO₂ overnight",
                        intent: .openMetric(key: MetricKey.spo2StrapMean.rawValue, variant: nil)),
        ]
    }

    /// Zone 1…5 from the upper edges of zones 1–4 (ALG-106 `zoneEdges` shape); nil without HR or edges.
    static func zone(of hr: Double?, edges: [Double]?) -> Int? {
        guard let hr, hr.isFinite, let e = edges, e.count == 4 else { return nil }
        for (i, edge) in e.enumerated() where hr <= edge { return i + 1 }
        return 5
    }

    /// "13:10" (min:s) under an hour, "1:02:05" over.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func workoutTitle(type: String?, place: String?) -> String {
        let parts = [place, type].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Workout" }
        let joined = parts.joined(separator: ", ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Workout mode (UX §6), only while a workout runs.
    public static func workoutMode(_ s: PresenterSnapshot) -> WorkoutModeState? {
        guard let session = s.live?.workout?.session ?? s.inputs.workout, session.isLive else { return nil }
        let w = s.live?.workout
        let hrV = s.live?.heartRate
        let hr: DisplayValue = hrV.map {
            s.worded(MGFormat.number($0, decimals: 0), unit: "bpm",
                     receipt: Receipt(computedOn: .strap, tier: .strap, at: s.live?.heartRateAt ?? s.now))
        } ?? .blank(reason: blankReason(s) ?? "No heart rate right now.", receipt: nil)
        let stats = s.workoutDetail?.event.id == session.id ? s.workoutDetail?.windowStats : nil
        let windows: [WorkoutWindowRow] = (w?.windows ?? []).map { win in
            let id = WorkoutDetailWindow.makeID(kind: win.kind, start: win.start)
            let avg = stats?[id]?.avgHR
            return WorkoutWindowRow(kind: win.kind?.rawValue ?? "window",
                                    label: win.label ?? win.kind.map(WorkoutDetailWindow.title(for:)) ?? "Window",
                                    start: win.start, end: win.end > win.start ? win.end : nil,
                                    avgHR: avg.map { s.worded(MGFormat.number($0, decimals: 0), unit: "bpm",
                                                              receipt: Receipt(computedOn: .phone, tier: .high, at: s.now)) }
                                        ?? .blank(reason: "Average shows when the window closes.", receipt: nil))
        }
        let strainMetric = s.metric(MetricKey.strain.rawValue, window: "workout", in: w?.strain ?? [])
        var hint = "Double-tap the strap = set done"
        if let w, w.setsDone > 0 {
            hint += " · \(w.setsDone) set\(w.setsDone == 1 ? "" : "s") so far"
            if let last = w.lastSetAt { hint += " · last \(s.hm(last))" }
        }
        var mode = WorkoutModeState(
            sample: s.sample, title: workoutTitle(type: session.activityType, place: session.place), start: session.start,
            elapsed: elapsed(s.now.timeIntervalSince(session.start)), heartRate: hr,
            zone: zone(of: hrV, edges: w?.zoneEdgesBpm), zoneMinutes: w?.zoneMinutes ?? [], hrTrace: w?.hrTrace ?? [],
            windows: windows,
            breathing: s.display(w?.breathing, missing: "Shown only where two breathing estimators agree (APP-031)."),
            strain: s.display(strainMetric, missing: "Strain appears after the first minutes of HR."),
            strainGroup: s.methodsStrip("G-LOAD", window: "workout", source: w?.strain ?? []),
            doubleTapHint: hint,
            actions: [ActionState(id: "next", title: "Next window", intent: .nextWorkoutWindow),
                      ActionState(id: "end", title: "End workout", intent: .endWorkout)],
            zoneEdgesBpm: w?.zoneEdgesBpm, zoneBasis: w?.zoneBasis)
        // T116: the summary card once this workout's detail is loaded.
        if let d = s.workoutDetail, d.event.id == session.id {
            mode.summary = WorkoutSummaryPresenter.make(s, d, openPrefix: "workout-live")
        }
        return mode
    }
}
