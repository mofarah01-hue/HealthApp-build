import Foundation
import MGBLE
import MGContext
import MGDomain
import MGHealth
import MGSignal
import MGStore
import MGSync
import UserNotifications

// WP-23a — the strap side of the model: link state → context, live beats → Live / guided flows, strap events
// (ARCHITECTURE §4.4.6: double-tap 14 → vape hit with a 1.2 s debounce and de-duplication on the event's own
// timestamp, noop FrameRouter L851-859 / AppModel L1795; wrist 9 / 10 → wear state and the wear-location question;
// charging 7 / 8), pairing with the standing clock consent (D6), smart wake (WP-11), Health reads, pull to refresh.
//
// WRITTEN, NOT COMPILED.

extension AppModel {
    // MARK: Wiring

    func wireStrap() {
        wireRing()                        // 0.6.0.3 Ring live: ring beats feed the Live tab when the ring is the active input
        let strap = services.strap
        strap.onChange = { [weak self] state, info in self?.strapChanged(state, info) }
        strap.onBeat = { [weak self] beat in
            self?.liveBeatSource = nil        // 0.6.0.12: the MG link is the source (the Live tab names any other)
            self?.liveBuffer.append(beat)
            self?.wristBeat(beat)             // T110: good beats clear an off flag the strap never took back
            self?.alarmsBeat(beat)            // the Fajr wake's live stager (App/Alarms)
            self?.rawOpticalTick()            // wave 4 (#65): nights-only raw optical windows
            self?.autoRawBeat(beat)           // r9q: workout detector, bursts (automatic raw streams)
            self?.keepUpBeat()                // wave W11: a beat is what wakes the app in the background
            self?.syncCadenceBeat()           // T9988: and the moment to ask whether a sync is due
            self?.liveBeatArrived()           // R-094: show the beat now, not at the next 1-s tick
        }
        strap.onEvent = { [weak self] event in
            guard let self else { return }
            Task { await self.strapEvent(event) }
        }
        strap.onLinkBuilt = { [weak self] link in self?.linkBuilt(link) }
        strap.onRawOptical = { [weak self] status in self?.rawOpticalChanged(status) }
        strap.onHRBroadcast = { [weak self] _ in Task { await self?.refresh() } }
        strap.onHistory = { [weak self] summary in
            guard let self else { return }
            Task { await self.historyFinished(summary) }
        }
        // WHOOP4-LINK (D-WHOOP4-LINK-1): the WHOOP 4.0's beats and events go to the same screens; its link state is Settings' own.
        let whoop4 = services.whoop4
        whoop4.onBeat = { [weak self] beat in
            self?.liveBeatSource = "WHOOP 4.0"
            self?.liveBuffer.append(beat)
            self?.wristBeat(beat)
            self?.alarmsBeat(beat)            // WHOOP4-WIRE 5: the wake alarm's live stager
            self?.keepUpBeat()
            self?.syncCadenceBeat()          // WHOOP4-WIRE: the PC sync trigger the 5/MG's beats also ask for
            self?.liveBeatArrived()
        }
        whoop4.onEvent = { [weak self] event in
            guard let self else { return }
            Task { await self.strapEvent(event) }
        }
        whoop4.onChange = { [weak self] state in self?.strapChanged(state, nil) }   // WHOOP4-WIRE: the 4.0 has no StrapInfo
        // WHOOP4-WIRE: a finished 4.0 download runs the same follow-ups as the 5/MG's.
        whoop4.onHRBroadcast = { [weak self] _ in Task { await self?.refresh() } }
        // WHOOP4-WIRE 6: the 4.0's raw stream (63): IMU seconds join the 100 Hz motion path, the optical wave goes to the Live card.
        whoop4.onRawMotion = { [weak self] m in
            guard let self else { return }
            self.motionTrace.append(m, at: self.clock.now)
            self.feedLiveMotion(m)
        }
        whoop4.onRawOptical = { [weak self] f in self?.feedLivePPGWhoop4(f) }
        whoop4.onRawStatus = { [weak self] st in self?.rawStreamWhoop4Changed(st) }
        whoop4.ledTick = { [weak self] in await self?.whoop4LedTick() }      // 0.6.0.12: overnight LED settings reads (read-only)
        whoop4.onHistory = { [weak self] summary in
            guard let self else { return }
            Task { await self.historyFinished(summary) }
        }
    }

    /// R-094 (2026-10-14): a beat rebuilds the Live tab at once, at most every `LivePace.minGap`; the 1-s tick then skips.
    func liveBeatArrived() {
        if let ms = LaunchTimer.reached(.firstLive) {      // R7 / T23: launch timing, the first beat of this run
            ComputeLog.shared.append(.note, "launch: first live data \(ms) ms after launch", at: clock.now)
            ComputeLog.shared.append(.note, "launch timing: \(LaunchTimer.summary())", at: clock.now)
        }
        guard liveOnScreen,
              LivePace.beatShouldRefresh(sinceLast: ProcessInfo.processInfo.systemUptime - liveRefreshedAt) else { return }
        refreshLive()
    }

    /// Starts (or restarts with a new consent) the strap link. Needs the install salt (MGStore keeps it, BRIEF WP-04).
    func startStrapLink() {
        guard let salt = installSalt else { return showNotice("The strap can't start yet: the install salt isn't read.") }
        // WHOOP4-LINK (D-WHOOP4-LINK-1): with "WHOOP 4.0" selected this starts the 4.0 link and NEVER the 5/MG one. The hand-back
        // switch below is the 5/MG strap's mode, so it does not stop the 4.0.
        if StrapDeviceChoice.stored == .whoop4 {
            services.whoop4.hrBroadcastWanted = isSample ? nil : settings.hrBroadcastOn   // WHOOP4-WIRE 4: written at the handshake when on
            applyRawStreamWhoop4()                                                         // WHOOP4-WIRE 6: only when a raw switch is on
            services.whoop4.start(installSalt: salt)
            return
        }
        // Wave W12b (#103): "Hand the strap back to WHOOP" is on — HealthApp does not connect.
        guard !settings.handBackToWhoop else { return }
        services.strap.start(installSalt: salt, clockConsentAt: settings.clockConsentAt)
    }

    /// T9994 (r9d): a wake (background task, background refresh) asks the strap link to reconnect if the strap is wanted and the
    /// link is down. Foreground wakes go through `StrapCoordinator.foregrounded`. The link logs the decision.
    func wakeStrap(_ reason: String) {
        if StrapDeviceChoice.stored == .whoop4 {      // WHOOP4-LINK: only the 4.0 is woken, never the 5/MG link
            guard !isSample, Whoop4Coordinator.wasPaired else { return }
            if services.whoop4.link == nil { startStrapLink() } else { services.whoop4.wake(reason) }
            return
        }
        guard !isSample, StrapCoordinator.wasPaired else { return }
        guard !settings.handBackToWhoop else {
            services.strap.noteExternal("wake (\(reason)): not reconnecting - the strap is handed back to WHOOP")
            return
        }
        if services.strap.link == nil { startStrapLink() } else { services.strap.wake(reason) }
    }

    private func linkBuilt(_ link: StrapLink) {
        // WP-11: the controller holds the link it was built with, so a new link gets a new controller.
        smartWake = SmartWakeController(strap: link, clock: clock,
                                        log: { [weak self] line in
                                            Task { @MainActor in self?.services.strap.noteExternal("smart wake: \(line)") }
                                        })
        lastSmartWakeRequest = nil
        applyRawOptical()
        // T9984: a stream switched on in an earlier run keeps live HR on from the first connection
        if StrapStreamPolicy.keepsRealtimeOn(rawMotionOn: rawMotionWantedNow, rawOpticalOn: rawOpticalWantedNow,
                                             opticalNightsOnly: settings.rawOpticalNightsOnly, sample: isSample) {
            applyRealtime(force: true)
        }
        link.onFiftyHz = { [weak self] ts, n in self?.fiftyHzSeen(strapTs: ts, count: n) }   // r9q (D-TRENDS-1)
        link.hrBroadcastWanted = isSample ? nil : settings.hrBroadcastOn   // T77: written at the handshake when on
        wireEcgMotion(link)   // wave W8: ECG + raw motion status, packets and the trace follow the new link
    }

    // MARK: Raw optical (2026-10-11): live R20 (108) while the switch is on and the app is open

    /// Hands the switch and "may run now" to the link; it sends 108 ON / OFF as they change. "May run now" is the app
    /// being open, or (wave 4, #65, nights only) the schedule's window around a strap SpO₂ burst — the link's
    /// `foreground` parameter carries that permission (MGBLE itself is unchanged).
    func applyRawOptical() {
        // r9q: the saved switch OR an automatic reason (workout episode, burst): AppModel+AutoWorkout
        ActivityLog.setOn(.rawOptical, rawOpticalWantedNow, now: clock.now, calendar: calendar)    // B-6
        if StrapDeviceChoice.stored == .whoop4 { return applyRawStreamWhoop4() }    // WHOOP4-WIRE 6: command 63 instead of 108 / 107
        services.strap.setRawOptical(enabled: rawOpticalWantedNow, foreground: rawOpticalAllowedNow())
        services.strap.setRawBanking(settings.keepRawOnStrap && !isSample)      // T9992: also banked on the strap, opt-in
    }

    func setRawOptical(_ on: Bool) async {
        guard !isSample else { return showNotice("Sample data is on — the strap is not asked for raw optical.") }
        settings.rawOpticalOn = on
        await saveState()
        applyRawOptical()
        applyRealtime()           // T9984: a stream that is on keeps live HR (and the app) running in the background
        if StrapDeviceChoice.stored == .whoop4 {
            return showNotice(on ? "Raw optical on: the WHOOP 4.0 streams its raw optical and motion frames (command 63) until you "
                                   + "switch it off (uses strap battery)." : "Raw optical off.")
        }
        showNotice(on ? "Raw optical on: the strap streams R20 until you switch it off, with the app in the background too "
                        + "(uses strap battery)." : "Raw optical off.")
    }

    /// T9992: the opt-in "keep raw on the strap if the app is closed" switch (saved; the link sends 107 while raw optical is on).
    func setKeepRawOnStrap(_ on: Bool) async {
        guard !isSample else { return showNotice("Sample data is on — the strap is not asked to keep raw data.") }
        settings.keepRawOnStrap = on
        await saveState()
        applyRawOptical()
        showNotice(on ? "Raw data is also kept on the strap while raw optical is on: it fills the strap's memory and every "
                        + "history download takes longer. Turn it off when you don't need it."
                      : "The strap no longer keeps raw data for the app.")
    }

    /// T77: the Settings switch for the heart-rate broadcast (14 + 119, read back with 121; MGBLE `setHRBroadcast`).
    func setHRBroadcast(_ on: Bool) async {
        guard !isSample else { return showNotice("Sample data is on — the strap is not asked to broadcast.") }
        settings.hrBroadcastOn = on
        await saveState()
        if StrapDeviceChoice.stored == .whoop4 {      // WHOOP4-WIRE 4: command 14 only; the 4.0 has no 119 / 121 pair
            await services.whoop4.setHRBroadcast(on)
        } else {
            await services.strap.setHRBroadcast(on)
        }
        showNotice(on ? "Heart-rate broadcast on: sent to the strap now, or when it next connects (uses a little strap battery)."
                      : "Heart-rate broadcast off: sent to the strap now, or when it next connects.")
    }

    /// The offload watchdog paused raw optical for a history download. T9996 (Oct 16 2026, Mo: "off ~10 min after I switched
    /// it on"): the switch used to be SAVED as off here, so it never came back; now it stays on, the link resumes raw optical
    /// when the download ends (0.5.8.1), and the pause is only a notice. Live HR is re-applied so the app stays awake.
    private func rawOpticalChanged(_ status: RawOpticalStatus) {
        let before = rawOpticalStatus
        rawOpticalStatus = status
        if let at = status.lastFrameAt, at != before.lastFrameAt { RawNightLog.noteR20(at: clock.now) }   // 0.5.8.1 morning check
        // T10005: the Live PPG graph's buffer takes each new record's samples (cheap); a new switch-on starts it empty.
        if status.frames == 0, before.frames != 0 { LivePPGFeed.shared.reset(); lastFedR20Index = -1 }
        if let at = status.lastFrameAt, at != before.lastFrameAt {
            // A restarted strap counter (index below the last fed) starts the run again from the newest record.
            if let newest = status.recentRecords.last?.recordIndex, newest < lastFedR20Index { lastFedR20Index = newest - 1 }
            for rec in status.recentRecords where rec.recordIndex > lastFedR20Index {
                feedLivePPG(rec)
                lastFedR20Index = rec.recordIndex
            }
        }
        if let why = status.stoppedReason, why != before.stoppedReason, settings.rawOpticalOn,
           why.hasPrefix("stopped by the watchdog") {
            showNotice("Raw optical paused for a history download — it comes back on by itself (\(why))")
            applyRealtime()
        }
        // Frame counts change every second; the screens are rebuilt only when the state itself changes.
        if before.on != status.on || before.wanted != status.wanted || before.stoppedReason != status.stoppedReason {
            Task { [weak self] in await self?.refresh() }
        }
    }

    /// T10005: one new live R20 record -> the smooth Live PPG buffer (MGSignal `LivePPGFeed`), every block and slot as the graph
    /// picker can show them, and - only while the Live tab is on screen - one background run of the cleaned trace (the band-pass
    /// runs on a utility queue inside the feed, never here). Rate = samples a second in the record (25 or 50), as the pulse path
    /// reads it. Display only; nothing is stored or sent.
    func feedLivePPG(_ rec: R20Record) {
        // Audit 7.2 (2026-10-17): the graph's buffer is display only; with the app in the background or another tab open it
        // was still being filled (and its own copies made) all night. A shown Live tab starts it empty and it fills in seconds.
        guard appActive, liveOnScreen else { return }
        let at = clock.now.timeIntervalSinceReferenceDate
        var heads: [Int: [UInt8]] = [:]
        var slotA: [Int: [Int32]] = [:]
        for b in rec.blocks {
            heads[b.index] = b.head
            slotA[b.index] = b.slotA
            for (slot, samples) in [b.slotA, b.slotB].enumerated() where samples.count >= 10 {
                LivePPGFeed.shared.append(id: b.index * 2 + slot, samples: samples, rateHz: Double(samples.count), arrivedAt: at)
            }
        }
        guard liveOnScreen, let block = LivePPGFeed.cleanBlock(heads: heads, slotA: slotA) else { return }
        LivePPGFeed.shared.requestClean(id: block * 2)
    }

    // MARK: Link state

    private func strapChanged(_ state: StrapLinkState, _ info: StrapInfo?) {
        let previousState = strapLinkState
        let wasDownloading = lastStrapDownloading
        strapLinkState = state
        strapInfo = info
        applyHRRead()       // 0.6.0.12: a 4.0 / MG link coming up or going down holds or releases the 5.0 broadcast reader
        switch state {      // 0.5.8.1: the morning check's down / up times
        case .ready, .downloadingHistory: RawNightLog.noteLink(up: true, at: clock.now)
        case .disconnected, .bluetoothOff, .unauthorized: RawNightLog.noteLink(up: false, at: clock.now)
        default: break
        }
        let downloading = StrapCoordinator.history(state) != nil
        lastStrapDownloading = downloading
        if wasDownloading && !downloading {
            // History stored (ack only after the durable write, MGBLE): a BLE-wake sync (§5.7). Compute is requested from
            // `historyFinished`, which knows whether the download stored anything new (T134).
            Task { [weak self] in
                guard let self else { return }
                await self.learnSpO2Schedule()          // wave 4 (#65): the strap's own SpO₂ burst schedule
                if !self.isSample { await self.services.syncCoordinator.strapWoke() }
                await self.drainIntents()
                _ = await self.services.nightSounds.evaluate()      // WP-26: re-check on every BLE wake
            }
        }
        var wasReady = false
        if case .ready = previousState { wasReady = true }
        if case .ready = state, !wasReady {
            // A fresh handshake: StrapLink re-applies the last wanted toggles itself (step 7); smart wake re-plans
            // (WP-11: refresh on BLE restore / wake); strap alarm slot 1 is re-armed on every connection (App/Alarms).
            lastSmartWakeRequest = nil
            alarmsConnected()
            if StrapDeviceChoice.stored == .whoop4 { applyRawStreamWhoop4() }    // an automatic raw wish held back until the link was ready
        }
        // T23: a chunk of a running download only moves the progress figure. It updates the "Working on" lines at once
        // and rebuilds every screen at most once per `progressRefreshGate` interval; the start and end of a download
        // (and every other state change) still rebuild right away.
        if wasDownloading && downloading {
            publishWorking()
            if progressRefreshGate.allow(at: clock.now) { Task { await refresh() } }
        } else {
            Task { await refresh() }
        }
    }

    /// T110: a live beat reaches the off-wrist tracker; when five good ones clear the flag, the screens refresh.
    func wristBeat(_ beat: LiveBeat) {
        guard wrist.offSince != nil else { return }
        wrist.beat(at: beat.at, bpm: beat.bpm, rrMs: beat.rrMs)
        if wrist.offSince == nil { Task { await refresh() } }
    }

    // MARK: Strap events (ARCHITECTURE §4.4.6)

    func strapEvent(_ e: StrapEvent) async {
        let at = Date(timeIntervalSince1970: TimeInterval(e.ts))
        switch e.number {
        case 14:    // DOUBLE_TAP
            if let last = lastDoubleTap, last.ts == e.ts || clock.now.timeIntervalSince(last.at) < 1.2 { return }
            lastDoubleTap = (e.ts, clock.now)
            // While a strap alarm rings, the double-tap is the alarm's (it stops a timer; never counts as awake for a
            // wake alarm) — never a vape hit (2026-10-11).
            if await alarmsStrapEvent(e) { break }
            await doubleTap(at: at)
        case 56, 57, 58, 59, 60, 100:   // strap alarm set / fired / app-run / cleared, haptics fired / ended
            _ = await alarmsStrapEvent(e)
        case 9:     // WRIST_ON
            wrist.wristOn(at: at)
            ledger.wearBefore = wearLocation
            ledger.wristOnAt = at
            await services.notifyCenter.cancelStrapOffReminder()
            if !isSample {
                await write(EventFactory.wear(.on, at: at, location: nil, detectedBy: .strapEvent), undoable: false)
            }
            await saveState()
        case 10:    // WRIST_OFF
            wrist.wristOff(at: at)
            if !isSample {
                await write(EventFactory.wear(.off, at: at, location: wearLocation, detectedBy: .strapEvent),
                            undoable: false)
            }
        case 7:     // charging on
            charging = true
        case 8:     // charging off
            charging = false
        default:
            break
        }
        await refresh()
    }

    /// APP-007: a double-tap logs a vape hit — or, while a workout runs, marks a set done (UX §6 "double-tap the strap
    /// = set done"). No return buzz: haptics are policy-gated (D5). Settings › Quick-log surfaces can switch it off.
    private func doubleTap(at: Date) async {
        if var w = sessions.workout {
            w.setsDone += 1
            w.lastSetAt = at
            WorkoutEditing.nextWindow(&w, now: at)
            sessions.workout = w
            await saveState()
            return
        }
        guard settings.surfaceOn("doubleTap") else { return }
        guard !isSample else { return showNotice("Strap double-tap ignored: sample data is on.") }
        if await write(EventFactory.vapeHit(at: at, trigger: .doubleTap, wake: lastInputs?.detectedWake)) != nil {
            tapHaptic()
        }
    }

    // MARK: Pairing (UX §14, ARCHITECTURE §9.4 first-run checklist)

    /// `.pairStrap`: the first time, the standing clock consent sheet (D6); then the link starts (bond, clock,
    /// history). Creating the central here is what shows iOS's Bluetooth permission prompt — never on first open.
    func pairStrap() {
        if StrapDeviceChoice.stored == .whoop4 { return pairWhoop4() }   // WHOOP4-LINK: the Pair button pairs the selected strap
        if settings.handBackToWhoop {   // wave W12b (#103)
            return showNotice("The strap is handed back to WHOOP — switch that off in Strap & sync to connect again.")
        }
        if settings.clockConsentAsked {
            startStrapLink()
            showNotice("Looking for your strap. Keep it close, and close the WHOOP app.")
        } else {
            sheet = .strapConsent
        }
    }

    /// The consent sheet's answer: a yes is stored with its time (`clockConsentAt`), a no means the clock is only read.
    func clockConsentDecided(_ allow: Bool) async {
        settings.clockConsentAsked = true
        settings.clockConsentAt = allow ? clock.now : nil
        sheet = nil
        await saveState()
        startStrapLink()
        // Notifications are asked for here, a moment that explains itself (WP-24 NotifySystem note).
        _ = await NotifySystem.requestAuthorization()
        await refresh()
    }

    func changeWearLocation(_ place: WearLocation) async {
        // R-100: the "Where's the strap now?" notification opens Strap & sync; a pick there while that question is open
        // is its answer (one wear event at the wrist-on time, question closed, notification withdrawn), not a second event.
        if !isSample, activeQuestion(.wearLocation) != nil {
            await answerPeek(.wearLocation, answer: place.rawValue)
            return
        }
        if await write(EventFactory.wear(.on, at: clock.now, location: place, detectedBy: .manual,
                                         answeredAt: clock.now), undoable: false) != nil {
            wearLocation = place
        }
    }

    func remindStrapOff(minutes: Int) async {
        let at = clock.now.addingTimeInterval(TimeInterval(minutes) * 60)
        if let why = await services.notifyCenter.remindStrapOff(at: at, offSince: offWristSince) {
            showNotice(why)
        } else {
            showNotice("I'll remind you at \(MGFormat.time(at, calendar: calendar)).")
        }
    }

    /// Pull down on Today (UX §10): reconnect the strap and try a sync; the status chip shows the result.
    func pullToRefresh() async {
        if StrapCoordinator.wasPaired || Whoop4Coordinator.wasPaired { startStrapLink() }
        await drainIntents()
        if isSample { return }
        let outcome = await services.syncCoordinator.syncUntilDrained()      // T9988: until the queue is empty
        syncStatus = await services.sync.refreshStatus()
        switch outcome.result {
        case .synced, .nothingToSend, .notSetUp:
            if let held = outcome.rawHeld { showNotice(held) }          // #74: Low Data Mode holds raw frames
        case .partial, .offline, .error, .skipped:
            if let detail = outcome.detail { showNotice(detail) }
        }
    }

    /// Strap & sync > sync panel (P9734): "Sync now" (a manual sync) and "Reset" (clears the re-pair latch and the retry
    /// ladder, then tries once; never deletes queued data).
    func syncPCNow(reset: Bool) async {
        guard !isSample else { return showNotice("Sample data is on — sync is off.") }
        showNotice(reset ? "Resetting sync… (nothing queued is deleted)" : "Syncing with the PC…")
        let outcome: SyncOutcome
        if reset {      // T9991 (c): inside a background task like every other drain, so leaving the app does not freeze it
            let engine = services.sync
            outcome = await SyncGrace.run("mg.sync.reset") { await engine.resetSync(budget: Duration.seconds(900)) }
        } else {
            outcome = await services.syncCoordinator.syncUntilDrained()
        }
        syncStatus = await services.sync.refreshStatus()
        if !reset { Task { [weak self] in await self?.runHealthAuto(manual: true) } }     // V3: Apple Health, capped, resumes next time
        switch outcome.result {
        case .synced, .nothingToSend: showNotice("Synced with the PC.")
        default: showNotice(outcome.detail ?? "Sync did not finish: \(outcome.result.rawValue).")
        }
    }

    // MARK: Strap settings (117/118/128 reads; added 2026-10-11)

    /// Reads every strap feature flag and its value; MGBLE stores the snapshot before this returns. Writes nothing.
    func readStrapSettings() async {
        guard !isSample else { return showNotice("Sample data is on — the strap is not read.") }
        showNotice("Reading strap settings… (reads only, nothing is written)")
        switch await services.strap.readFlagSnapshot() {
        case .success(let snap):
            flagSnapshot = snap
            let ok = snap.readings.filter { $0.status == "ok" }.count
            showNotice("Strap settings read: \(snap.readings.count) keys, \(ok) with a value.")
        case .failure(let why):
            showNotice("Strap settings not read: \(why.text)")
        }
    }

    /// R22 research stream (2026-10-11): MGBLE reads and stores every setting, stops unless an R22 version flag
    /// already reads '1', then asks the confirm sheet before the one write. The outcome is shown as a notice; the
    /// write log (refreshed after every intent) holds prior / payload / read-back.
    func runR22(restore: Bool) async {
        guard !isSample else { return showNotice("Sample data is on — nothing is written to the strap.") }
        let result = restore ? await services.strap.restoreR22() : await services.strap.enableR22()
        if let snap = services.strap.lastFlagSnapshot { flagSnapshot = snap }
        switch result {
        case .success(let report):
            let lines = report.items.map { "\($0.name): '\($0.priorValue ?? "—")' → read back '\($0.readback ?? "—")' · \($0.result)" }
            showNotice((lines + [report.note].compactMap { $0 }).joined(separator: " · "))
            // Mo 2026-10-11 "Single write, then see": after an enable that read back '1', watch the next offloads for
            // R22 records; a restore that read back ends the watch.
            if report.items.contains(where: { $0.result == "ok" }) {
                if restore {
                    settings.r22Watch = nil
                } else {
                    settings.r22Watch = R22Watch(writtenAt: clock.now,
                                                 hintFlag: flagSnapshot.flatMap { StrapLink.r22VersionHint($0) })
                }
                await saveState()
            }
        case .failure(let why):
            showNotice("R22: \(why.text)")
        }
    }

    /// A history download finished: the R22 watch counts its R22 records and whether it carried post-write data.
    func historyFinished(_ summary: HistorySummary) async {
        keepUpHistoryFinished()     // wave W11: any finished download counts as the last pull
        // T134: compute only the days the new records fall in; a download that stored nothing new schedules nothing.
        await services.compute.noteHistory(recordsInserted: summary.recordsInserted, firstTs: summary.firstTs,
                                           lastTs: summary.lastTs, endedAt: summary.endedAt)
        if summary.recordsInserted >= AppModel.bigHistoryWrite {      // audit 3.1: fold the log back after a big write
            await services.store.checkpointTruncate()
        }
        if summary.recordsInserted > 0 {
            // T10007: the download that brings in the first awake seconds after a night is a trigger of its own, so the chain
            // does not depend on the app being awake at the minute the flag changed.
            Task { [weak self] in await self?.wakeChainCheck(trigger: "history download") }
        }
        guard var watch = settings.r22Watch else { return }
        let before = watch
        watch.noteDownload(lastTs: summary.lastTs, r22Records: summary.r22Records, at: clock.now)
        guard watch != before else { return }
        settings.r22Watch = watch
        await saveState()
        await refresh()
    }

    // MARK: Realtime toggles (D5: 3 and 63 are the two sanctioned toggles)

    /// Live HR is wanted while the Live tab, a guided flow or a workout is on. Smart wake turns the toggles on for its
    /// window itself (D8) and off after the wake (WP-11 `realtimeOffAfterWake`): never switched off here while it
    /// watches.
    func applyRealtime(force: Bool = false) {
        guard !isSample else { return }
        // App/Alarms asks for live HR from bedtime through a wake window (feeds the Fajr stager, keeps the app alive).
        let want = tab == .live || cover != nil || sessions.workout != nil || alarms.wantsRealtime
            || rawOpticalKeepAwake            // wave 4 (#65): live HR keeps the app awake for the night schedule
            || keepUp.keepAwake               // wave W11: … and for the 15-min history pulls in the background
            || StrapStreamPolicy.keepsRealtimeOn(rawMotionOn: rawMotionWantedNow, rawOpticalOn: rawOpticalWantedNow,
                                                 opticalNightsOnly: settings.rawOpticalNightsOnly, sample: isSample)   // T9984
            || autoBurstKeepAwake             // r9q: deep-sleep / morning windows: a calm moment has to be seen
        let watching: Bool
        if case .watching? = smartWake?.status { watching = true } else { watching = false }
        guard force || want != realtimeOn else { return }
        if !want && watching { return }
        realtimeOn = want
        ActivityLog.setOn(.bleStream, want, now: clock.now, calendar: calendar)    // B-6
        services.strap.setRealtime(hr: want, motion: false)
        if want { seedLive() }   // #35: the Live charts open full from the store, then scroll on live beats
    }

    // MARK: Smart wake (WP-11)

    /// Plans / arms tonight. Idempotent in the controller; called after every refresh with the current inputs.
    func updateSmartWake(_ s: PresenterSnapshot) async {
        guard let sw = smartWake else { return }
        let bed = s.context.anchors.bedtime
        let need = s.metrics.first { $0.name == MetricKey.sleepNeed.rawValue && $0.value != nil }?.value
        // The normal wake's time for that morning comes from the alarm plan (weekly times + one-/two-day / week-long
        // changes; App/Alarms 2026-10-11); a skipped day ("you stayed up after Fajr", a change set to off) stands down.
        let weekly = ContextMath.latestWakeInstant(settings.latestWake, after: bed, calendar: calendar)
        let (mustBeUpBy, skipped) = alarmsNormalTarget(after: bed, fallback: weekly)
        let request = SmartWakeRequest(
            enabled: settings.smartWakeOn && !isSample && skipped == nil,
            mustBeUpBy: mustBeUpBy,
            windowMinutes: settings.wakeWindowMinutes, bedtime: bed, asleepAround: nil, needMinutes: need,
            options: smartWakeOptions(forWakeAt: mustBeUpBy))
        let watchingBefore = smartWakeWatching
        if request != lastSmartWakeRequest || s.context.phase != lastSmartWakePhase {
            lastSmartWakeRequest = request
            lastSmartWakePhase = s.context.phase
            if request.enabled {
                await sw.refresh(request)
            } else {
                await sw.disarm(reason: isSample ? "Sample data is on"
                                : skipped.map { "Normal wake skipped: \($0)" } ?? "Smart wake is off")
            }
        }
        // The smart wake rang at a light-sleep moment: the strap buzzes with it (App/Alarms).
        if case .ringing(let at, true)? = smartWake?.status { alarmsSmartWakeRang(at: at) }
        if case .watching? = smartWake?.status { smartWakeWatching = true } else { smartWakeWatching = false }
        // WP-11 switches the realtime toggles off after the wake (`realtimeOffAfterWake`): if the Live tab, a flow or
        // a workout still wants them, turn them back on — once, at that transition (no repeated strap writes).
        if watchingBefore && !smartWakeWatching && realtimeOn { applyRealtime(force: true) }
    }

    // MARK: Apple Health (WP-14)

    /// The read permission sheet appears when Mo first opens Strap & sync — not on first launch (UX rule 2).
    func askHealthReadIfNeeded() async {
        guard let health = services.health else { return }
        let state = await health.authState()
        healthState = state
        guard state == .notRequested else { return }
        do {
            try await health.requestAccess()
            healthState = await health.authState()
            await readHealthIfAllowed()
        } catch {
            showNotice("Apple Health: \(error)")
        }
    }

    func readHealthIfAllowed() async {
        guard let health = services.health, !isSample else { return }
        let state = await health.authState()
        healthState = state
        guard state == .requested else { return }
        let report = await health.sync()
        healthLastRead = clock.now
        if let message = report.message { showNotice(message) }
        if !report.errors.isEmpty { services.strap.noteExternal("health: \(report.errors.joined(separator: "; "))") }
        if report.ingested > 0 { await services.compute.request(.manual) }
        await runHealthAuto()          // T9739: every type, new samples only, to the PC
        _ = await services.mirror?.run()
    }
}
