import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSignal
import MGStore

// r9q (Oct 17 2026; D-LOAD-WALK-2, D-TRENDS-1, D-POP-PRIOR, D-AUTO-WORKOUT-1): the raw streams that switch themselves on.
//
//  1. Workouts: every live beat feeds a 20-minute ring of per-minute heart rates. When the last 3 whole minutes sit at or above
//     the zone-1 floor and the learned score says "ask", raw PPG (R20) and 100 Hz motion (R21) switch on, a notification and an
//     in-app card ask "Workout? Yes / No", and the answer teaches the detector (MGContext `LiveWorkoutDetector`, population
//     values moving toward Mo's own). Yes starts a workout session from where the heart rate left the floor. When the workout
//     ends, or Mo says No, the streams go back to what he SAVED: the saved switches are never changed here, the streams
//     are `saved || auto` (`AutoStreams.effective`).
//  2. Bursts: short raw-PPG bursts at chosen quiet moments (deep sleep, morning rest, still moments), judged by a strict quality
//     gate once they end (`RawBurstGate`); the verdict is kept in `settings.autoRaw.burstLog`.
//  3. 50 Hz: a history chunk holding optical windows the strap flagged 50 Hz is logged with time and count.
//
// Nothing here talks to the strap directly: it changes what `applyRawOptical` / `applyRawMotion` are told is wanted, and those
// go through the existing link calls (which already retry 81, defer the 100 Hz start while a history offload runs and pause raw
// optical for one). On top of that this file never turns anything ON while the link says it is downloading history.
//
// WRITTEN, NOT COMPILED (ios/App cannot be built on the Linux harness).

/// The memory-only part: the heart-rate minutes, the machine and a running burst. The durable part is `settings.autoRaw`.
struct AutoRawRuntime {
    var ring = HRMinuteRing()
    var machine = AutoWorkoutMachine()
    var lastEvalAt: Date?
    var lastBeatAt: Date?
    var burst: BurstRun?
    /// The last planned sleep window seen while `now` was inside it (the anchors move on to tonight after the wake).
    var lastSleepWindow: (start: Date, end: Date)?

    struct BurstRun: Equatable, Sendable {
        var kind: BurstKind
        var start: Date
        var end: Date
    }
}

extension AppModel {
    /// Evaluate at most this often (a beat arrives about every second).
    static let autoRawEvalGapS: TimeInterval = 15

    // MARK: What is wanted

    /// Any automatic reason is on: a workout episode or a burst.
    /// Each reason counts only while its own switch is on (the switches stay; this keeps them honest: with workout automation or bursts
    /// switched off, a stale episode or burst never keeps the raw stream wanted).
    var autoStreamsOn: Bool {
        guard !isSample else { return false }
        let s = settings.autoRaw
        return (s.workoutAutoOn && autoRaw.machine.streamsOn) || (s.burstsOn && autoRaw.burst != nil)
    }
    /// The switch Mo saved, or an automatic reason. Everything that tells the link what is wanted uses these two.
    var rawOpticalWantedNow: Bool { AutoStreams.effective(saved: settings.rawOpticalOn, autoOn: autoStreamsOn) && !isSample }
    var rawMotionWantedNow: Bool { AutoStreams.effective(saved: settings.rawMotionOn, autoOn: autoStreamsOn) && !isSample }

    /// Tells the link the new wanted state (its own rules still decide when 81 / 108 go out).
    func applyAutoStreams() {
        applyRawOptical()
        applyRawMotion()
        applyRealtime(force: true)       // live heart rate keeps the app awake while a stream runs in the background
    }

    private func autoLinkState() -> (connected: Bool, offloading: Bool) {
        // With "WHOOP 4.0" selected the 5/MG link is idle: read the 4.0 link, or a download would never count as "offloading".
        let state: StrapLinkState? = StrapDeviceChoice.stored == .whoop4 ? services.whoop4.state : services.strap.link?.state
        switch state {
        case .ready?: return (true, false)
        case .downloadingHistory?: return (true, true)
        default: return (false, false)
        }
    }

    private func autoMotionState(_ now: Date) -> MotionState {
        guard rawMotionStatus.on, let at = motionTrace.lastAt, now.timeIntervalSince(at) < 5 else { return .unknown }
        return RawOpticalWindows.isStill(motionTrace.values) ? .still : .moving
    }

    /// The planned sleep window now: the current one when `now` is inside it (remembered), else the remembered one.
    private func autoSleepWindow(_ now: Date) -> (start: Date, end: Date)? {
        if let w = rawOpticalSleepWindow(), now >= w.start, now <= w.end { autoRaw.lastSleepWindow = w; return w }
        if let last = autoRaw.lastSleepWindow, now <= last.end.addingTimeInterval(RawBursts.morningSpanS) { return last }
        return rawOpticalSleepWindow()
    }

    /// Live heart rate stays on in the windows where a calm moment has to be seen for a burst (deep sleep, morning rest).
    var autoBurstKeepAwake: Bool {
        guard !isSample else { return false }
        let now = clock.now
        let w = autoSleepWindow(now)
        return RawBursts.keepAwake(now: now, sleepStart: w?.start, sleepEnd: w?.end, settings: settings.autoRaw, calendar: calendar)
    }

    /// What Strap & sync shows (MGContext `AutoRawPresenter`).
    func autoRawInfo() -> AutoRawInfo {
        var i = AutoRawInfo()
        i.settings = settings.autoRaw
        i.calendar = calendar
        if autoRaw.machine.streamsOn {
            i.activeReason = settings.autoRaw.switchLog.last(where: { $0.source == "workout" && $0.on })?.reason ?? "a workout"
        } else if let b = autoRaw.burst {
            i.activeReason = "\(b.kind.title) burst until \(MGFormat.time(b.end, calendar: calendar))"
        }
        return i
    }

    // MARK: Beats and the tick

    func autoRawBeat(_ beat: LiveBeat) {
        guard !isSample else { return }
        if let bpm = beat.bpm { autoRaw.ring.add(at: beat.at, bpm: bpm) }
        autoRaw.lastBeatAt = beat.at
        autoRawTick()
    }

    /// Housekeeping, once per refresh: the tick, and the keep-awake window may have opened or closed.
    func autoRawHousekeeping() {
        guard !isSample else { return }
        autoRawTick(force: true)
        applyRealtime()
    }

    func autoRawTick(force: Bool = false) {
        guard !isSample else { return }
        let now = clock.now
        if !force, let l = autoRaw.lastEvalAt, now.timeIntervalSince(l) < Self.autoRawEvalGapS { return }
        autoRaw.lastEvalAt = now
        let link = autoLinkState()
        var s = settings.autoRaw
        var actions: [AutoWorkoutMachine.Action] = []
        if !s.workoutAutoOn {
            actions = autoRaw.machine.stop(now: now, why: "automatic workout streams switched off")
        } else {
            let floor = WorkoutZones.make(profile: effectiveProfile, now: now, calendar: calendar).edges?.floor
            let beatFresh = autoRaw.lastBeatAt.map { now.timeIntervalSince($0) < 90 } ?? false
            let features = (floor != nil && beatFresh)
                ? LiveWorkoutDetector.features(ring: autoRaw.ring, floorBpm: floor ?? 0, motion: autoMotionState(now)) : nil
            let input = AutoWorkoutMachine.Input(
                now: now, dayKey: AutoRawSettings.dayKey(now, calendar: calendar), features: features,
                quietMinutes: floor.map { autoRaw.ring.quietMinutes(below: $0) } ?? 0,
                silentSeconds: autoRaw.lastBeatAt.map { now.timeIntervalSince($0) } ?? 1e9,
                offloading: link.offloading, connected: link.connected, workoutRunning: sessions.workout != nil)
            actions = autoRaw.machine.step(input, settings: &s)
        }
        settings.autoRaw = s
        perform(actions, at: now)
        autoBurstStep(now, link: link)
    }

    // MARK: Carrying out the machine's actions

    private func perform(_ actions: [AutoWorkoutMachine.Action], at now: Date) {
        guard !actions.isEmpty else { return }
        for a in actions {
            switch a {
            case .streamsOn(let why):
                logAutoSwitch(on: true, source: "workout", reason: why, at: now)
                applyAutoStreams()
            case .streamsOff(let why):
                logAutoSwitch(on: false, source: "workout", reason: why, at: now)
                applyAutoStreams()
            case .ask(_, let onset):
                autoWorkoutPrompt = AutoRawPresenter.prompt(onset: onset, now: now, calendar: calendar)
                if !appActive {
                    Task { [weak self] in await self?.services.notifyCenter.workoutLikely(onset: onset) }
                }
            case .withdrawAsk:
                autoWorkoutPrompt = nil
                Task { [weak self] in await self?.services.notifyCenter.withdrawWorkoutLikely() }
            case .startWorkout(let onset):
                Task { [weak self] in await self?.startWorkout(startedAt: onset) }
            case .label(let l):
                ComputeLog.shared.append(.note, "auto workout: answer \(l.workout ? "yes" : "no") (asked \(MGFormat.time(l.askedAt, calendar: calendar))); "
                                         + "detector now \(settings.autoRaw.params.provenance)", at: now)
            }
        }
        Task { [weak self] in await self?.saveState() }
    }

    private func logAutoSwitch(on: Bool, source: String, reason: String, at now: Date) {
        settings.autoRaw.log(AutoSwitchEntry(at: now, on: on, source: source, reason: reason))
        let line = "auto raw streams \(on ? "ON" : "OFF") (\(source)): \(reason)"
        ComputeLog.shared.append(.note, line, at: now)
        services.strap.noteExternal(line)
    }

    /// Mo's answer to "Workout?" from the card or the notification button.
    func answerAutoWorkout(_ yes: Bool) async {
        let now = clock.now
        var s = settings.autoRaw
        let actions = autoRaw.machine.answer(workout: yes, now: now, settings: &s)
        settings.autoRaw = s
        autoWorkoutPrompt = nil
        guard !actions.isEmpty else {
            await services.notifyCenter.withdrawWorkoutLikely()
            return showNotice("That question has expired.")
        }
        perform(actions, at: now)
        showNotice(yes ? "Workout started. Raw streams stay on until it ends."
                       : "Noted: not a workout. Raw streams are back to your setting.")
        await refresh()
    }

    // MARK: Settings intents

    func autoRawAction(_ action: AutoRawAction) async {
        switch action {
        case .answerWorkout(let yes):
            await answerAutoWorkout(yes)
            return
        case .setWorkoutAuto(let on):
            guard !isSample else { return showNotice("Sample data is on.") }
            settings.autoRaw.workoutAutoOn = on
            if !on { autoRawTick(force: true) }       // ends a running episode
            showNotice(on ? "Raw streams switch on by themselves when a workout looks likely, and MG asks."
                          : "Raw streams no longer switch on by themselves for workouts.")
        case .setBursts(let on):
            guard !isSample else { return showNotice("Sample data is on.") }
            settings.autoRaw.burstsOn = on
            if !on, let b = autoRaw.burst { finishBurst(b, now: clock.now, early: true) }
            showNotice(on ? "Raw bursts at quiet moments are on (uses a little strap battery)." : "Raw bursts are off.")
        case .setBurstKind(let raw, let on):
            var kinds = settings.autoRaw.burstKinds.filter { $0 != raw }
            if on, BurstKind(rawValue: raw) != nil { kinds.append(raw) }
            settings.autoRaw.burstKinds = BurstKind.allCases.map { $0.rawValue }.filter { kinds.contains($0) }
        case .setBurstSeconds(let secs):
            settings.autoRaw.burstSeconds = min(max(secs, RawBursts.lengthRange.lowerBound), RawBursts.lengthRange.upperBound)
        }
        await saveState()
        await refresh()
    }

    // MARK: Bursts

    private func autoBurstStep(_ now: Date, link: (connected: Bool, offloading: Bool)) {
        if let b = autoRaw.burst {
            let s = settings.autoRaw
            if now >= b.end { finishBurst(b, now: now, early: false) }
            else if !s.burstsOn || autoRaw.machine.streamsOn || sessions.workout != nil { finishBurst(b, now: now, early: true) }
            return
        }
        let s = settings.autoRaw
        guard s.burstsOn, link.connected, !link.offloading, sessions.workout == nil, !autoRaw.machine.streamsOn else { return }
        let w = autoSleepWindow(now)
        let fresh = autoRaw.lastBeatAt.map { now.timeIntervalSince($0) < 90 } ?? false
        let calm = fresh ? autoRaw.ring.calmMinutes(spreadBpm: RawBursts.calmSpreadBpm) : 0
        let ctx = BurstContext(now: now, sleepStart: w?.start, sleepEnd: w?.end, calmMinutes: calm,
                               motion: autoMotionState(now), workoutBusy: false)
        guard let kind = RawBursts.pick(ctx, settings: s, calendar: calendar) else { return }
        RawBursts.markStarted(kind, at: now, settings: &settings.autoRaw, dayKey: AutoRawSettings.dayKey(now, calendar: calendar))
        let len = TimeInterval(min(max(s.burstSeconds, RawBursts.lengthRange.lowerBound), RawBursts.lengthRange.upperBound))
        autoRaw.burst = AutoRawRuntime.BurstRun(kind: kind, start: now, end: now.addingTimeInterval(len))
        logAutoSwitch(on: true, source: "burst", reason: "\(kind.title): heart rate calm for \(calm) min", at: now)
        applyAutoStreams()
        Task { [weak self] in await self?.saveState() }
    }

    private func finishBurst(_ b: AutoRawRuntime.BurstRun, now: Date, early: Bool) {
        autoRaw.burst = nil
        logAutoSwitch(on: false, source: "burst", reason: early ? "stopped early" : "finished (\(b.kind.title))", at: now)
        applyAutoStreams()
        Task { [weak self] in await self?.judgeBurst(b, endedAt: now) }
    }

    /// Reads what arrived, runs ALG-144 off the main thread, applies the strict gate, keeps the verdict.
    private func judgeBurst(_ b: AutoRawRuntime.BurstRun, endedAt: Date) async {
        let from = Int64(b.start.timeIntervalSince1970) - 30
        let to = Int64(endedAt.timeIntervalSince1970) + 30
        let records = (try? await services.store.r20Records(from: from, to: to)) ?? []
        let motion = (try? await services.store.motionSeconds(from: from, to: to)) ?? []
        let entry: BurstLogEntry = await Task.detached(priority: .utility) {
            let out = ALG144.analyse(r20: records, motion: motion)
            let q = out.windows.map { BurstWindowQuality(state: $0.state.rawValue, gates: $0.gates.map { $0.rawValue }) }
            let bpms = out.hrEstimated.map { $0.bpm }
            let mean: Double? = bpms.isEmpty ? nil : bpms.reduce(0, +) / Double(bpms.count)
            return RawBurstGate.judge(start: b.start, kind: b.kind.rawValue, windows: q, recordSeconds: records.count, meanBpm: mean)
        }.value
        RawBursts.record(entry, settings: &settings.autoRaw)
        ComputeLog.shared.append(.note, "raw burst \(b.kind.title) \(MGFormat.time(b.start, calendar: calendar)): "
                                 + "\(entry.usable ? "usable" : "not used") - \(entry.reason)", at: clock.now)
        await saveState()
        await refresh()
    }

    // MARK: 50 Hz

    /// A history chunk held optical windows the strap flagged 50 Hz (MGBLE `onFiftyHz`, strap-clock second of the first one).
    func fiftyHzSeen(strapTs: Int64, count: Int) {
        guard count > 0, !isSample else { return }
        let e = FiftyHzEvent(at: Date(timeIntervalSince1970: TimeInterval(strapTs)), count: count)
        let before = settings.autoRaw.fiftyHzLog.count
        FiftyHzEvent.record(e, settings: &settings.autoRaw)
        guard settings.autoRaw.fiftyHzLog.count != before else { return }
        let line = e.line + " (history download), seen \(MGFormat.time(clock.now, calendar: calendar))"
        ComputeLog.shared.append(.note, line, at: clock.now)
        services.strap.noteExternal(line)
        Task { [weak self] in await self?.saveState() }
    }
}
