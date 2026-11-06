import Foundation
import MGContext
import MGDomain
import MGSignal
import UIKit

// WP-23a — the running things: Breathe and HRV check (BRIEF WP-29 row: Composition collects live R-R and computes
// ALG-104 / ALG-010 / ALG-121 and the ALG-004 gate; presenters word it), workouts started by hand (UX §6 Workout mode,
// APP-051), the nap timer (UX §4.2), night sounds (WP-26). Nothing here is saved in SAMPLE mode.
//
// WRITTEN, NOT COMPILED.

extension AppModel {
    // MARK: Breathe (APP-024)

    /// `.startBreathe`: close Tonight first if it's open (BRIEF WP-29 row), then the full-screen pacer.
    func startBreathe() {
        breatheSession = BreatheSession()
        if sheet != nil {
            sheet = nil
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))   // a cover can't present while the sheet dismisses
                self?.cover = .breathe
                self?.applyRealtime()
            }
        } else {
            cover = .breathe
            applyRealtime()
        }
    }

    // MARK: HRV check (APP-025)

    /// `.startHRVCheck(minutes:)`: opens the check (ready); from inside it, starts a reading of that length.
    func startHRVCheck(minutes: Int) {
        let m = min(HRVCheckState.minuteRange.upperBound, max(HRVCheckState.minuteRange.lowerBound, minutes))
        if cover != .hrvCheck {
            hrvSession = HRVCheckSession(phase: .ready, minutes: m)
            cover = .hrvCheck
            applyRealtime()
            return
        }
        guard beatsFlowing else {
            hrvSession = HRVCheckSession(phase: .blocked, minutes: m, blockedReason: noBeatsReason)
            return
        }
        let now = clock.now
        hrvSession = HRVCheckSession(phase: .measuring, minutes: m, startedAt: now,
                                     endsAt: now.addingTimeInterval(TimeInterval(m) * 60))
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// UX §13: why nothing can be measured now.
    var noBeatsReason: String {
        if isSample { return "Sample data is on: there are no live beats to measure." }
        if let off = offWristSince {
            return "Strap's off your wrist — nothing to measure. Off since \(MGFormat.time(off, calendar: calendar))."
        }
        if case .ready = strapLinkState { return "No beats arriving from the strap yet. Keep it snug and still." }
        return "Strap not connected."
    }

    // MARK: Inside a flow (`.guided`)

    func guided(_ action: GuidedAction) async {
        switch action {
        case .beginBreathe(let perMinute, let minutes):
            let now = clock.now
            let m = max(1, minutes)
            breatheSession = BreatheSession(phase: .running, perMinute: perMinute, minutes: m, startedAt: now,
                                            endsAt: now.addingTimeInterval(TimeInterval(m) * 60), result: nil)
            UIApplication.shared.isIdleTimerDisabled = true
        case .endNow:
            if breatheSession?.phase == .running { finishBreathe(endedEarly: true) }
            if hrvSession?.phase == .measuring { finishHRVCheck() }
        case .close:
            // From ready or result nothing more happens; while running everything collected is discarded.
            cover = nil
            breatheSession = nil
            hrvSession = nil
            UIApplication.shared.isIdleTimerDisabled = false
            applyRealtime()
        }
    }

    /// Once a second (live ticker): a flow whose time is up finishes by itself.
    func advanceGuidedFlows() {
        let now = clock.now
        if let b = breatheSession, b.phase == .running, let end = b.endsAt, now >= end { finishBreathe(endedEarly: false) }
        if let h = hrvSession, h.phase == .measuring, let end = h.endsAt, now >= end { finishHRVCheck() }
    }

    private func finishBreathe(endedEarly: Bool) {
        guard var b = breatheSession, let start = b.startedAt else { return }
        let rr = liveBuffer.rrSince(start).map(\.rrMs)
        let hr = liveBuffer.hrSince(start)
        b.result = GuidedMath.breathe(rr: rr, hr: hr, startedAt: start, now: clock.now, endedEarly: endedEarly,
                                      strapConnected: beatsFlowing)
        b.phase = .finished
        breatheSession = b
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func finishHRVCheck() {
        guard var h = hrvSession, let start = h.startedAt else { return }
        h.result = GuidedMath.hrvCheck(rr: liveBuffer.rrSince(start).map(\.rrMs), hr: liveBuffer.hrSince(start),
                                       now: clock.now)
        h.phase = .result
        hrvSession = h
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Workouts started by hand (UX §6, APP-051)

    /// `startedAt`: r9q, a "Yes" to "Workout?" starts the session where the heart rate left the floor (never in the future).
    func startWorkout(startedAt: Date? = nil) async {
        guard !isSample else { return showNotice(LogIntents.sampleReason) }
        guard sessions.workout == nil else { tab = .live; return }
        let now = min(startedAt ?? clock.now, clock.now)
        // #41: started at a saved place → its name, and the likely activity where the place has a strong one (Gym,
        // the fields); Mo changes either in Workout detail.
        let here = placeNow
        sessions.workout = LiveSessions.Workout(id: UUID(), start: now,
                                                activityType: here?.askFirst == false ? here?.likelyActivity : nil,
                                                place: here?.name, note: nil, windows: [], setsDone: 0, lastSetAt: nil,
                                                wearLocation: wearLocation)
        liveBuffer.startWorkout(at: now)
        tab = .live
        await saveState()
        applyRealtime(force: true)
    }

    func endWorkout() async {
        guard let w = sessions.workout else { return }
        let saved = await write(EventFactory.manualWorkout(w, end: clock.now), undoable: false)
        guard saved != nil else { return }
        sessions.workout = nil
        liveBuffer.endWorkout()
        await saveState()
        applyRealtime()
    }

    func nextWorkoutWindow() async {
        guard var w = sessions.workout else { return }
        WorkoutEditing.nextWindow(&w, now: clock.now)
        sessions.workout = w
        await saveState()
    }

    /// `.editWorkout(id:edit:)`: a new revision of the stored workout; a running one takes type / place / note only.
    func editWorkout(id: UUID, edit: WorkoutEdit) async {
        guard !isSample else { return showNotice(LogIntents.sampleReason) }
        if var w = sessions.workout, w.id == id {
            switch edit {
            case .setType(let t): w.activityType = t
            case .setPlace(let p): w.place = p
            case .setNote(let n): w.note = n
            case .setWearLocation(let l): w.wearLocation = (l == .unknown) ? nil : l
            case .setTimes, .setWindowKind, .splitWindow, .mergeWithNext:
                return showNotice("Edit the times and windows after the workout ends.")
            case .setRPE, .setWeights:
                return showNotice("Rate the workout and log your weights after it ends.")
            }
            sessions.workout = w
            await saveState()
            return
        }
        guard let event = try? await services.store.event(id: id) else {
            return showNotice("That workout is no longer there.")
        }
        switch WorkoutEditing.apply(edit, to: event) {
        case .success(let revised): await write(revised, undoable: false)
        case .failure(let f): showNotice(f.message)
        }
    }

    // MARK: Nap timer (UX §4.2 "Nap timer running")

    /// Also used by the StartNap App Intent (WP-24). false = not started (SAMPLE mode).
    @discardableResult
    func startNap(minutes: Int, at start: Date) async -> Bool {
        guard !isSample else {
            showNotice(LogIntents.sampleReason)
            return false
        }
        let m = max(1, minutes)
        sessions.nap = LiveSessions.Nap(start: start, plannedMinutes: m)
        await saveState()
        if let why = await services.notifyCenter.napTimerEnds(at: start.addingTimeInterval(TimeInterval(m) * 60),
                                                              minutes: m) {
            showNotice("Nap timer running, but it won't ring: \(why)")
        }
        await refresh()
        return true
    }

    func endNap() async {
        guard let n = sessions.nap else { return }
        let end = max(clock.now, n.start.addingTimeInterval(60))
        sessions.nap = nil
        await services.notifyCenter.cancelNapTimerRing()
        if await write(EventFactory.manualNap(start: n.start, end: end), undoable: false) != nil {
            ledger.napEnds.append(end)   // "30 min after your nap — how now?" (UX §4.2)
        }
        await saveState()
    }

    // MARK: Night sounds (WP-26)

    func setNightSounds(_ on: Bool) async {
        guard !isSample || !on else { return showNotice(LogIntents.sampleReason) }
        let status = await services.nightSounds.setEnabled(on)
        if case .needsMicrophone = status {
            showNotice("Night sounds need the microphone. Turn it on in iOS Settings › MG › Microphone.")
        }
    }

    /// Tonight's listening window: bedtime → L (or B + 9 h); recomputed every refresh.
    func updateNightSoundsPlan(_ s: PresenterSnapshot) async {
        let end = ContextMath.latestWakeInstant(settings.latestWake, after: s.context.anchors.bedtime, calendar: calendar)
        await services.nightSounds.updatePlan(bedtime: s.context.anchors.bedtime, windowEnd: end)
    }
}
