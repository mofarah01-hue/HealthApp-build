import Foundation
import MGContext
import MGDomain
import MGSignal

// Wave 4 (#65, 2026-10-11): raw optical at night, on a schedule, under the same switch (off by default until 2026-10-11
// 21:43 PT; on by default since — Mo, CLAUDE.md rule 5). The decision is
// MGContext `RawOpticalNight` (pure); this file feeds it the clock, the planned sleep window, the strap clock offset and
// the burst schedule learned from stored R18, and applies it: 108 ON / OFF through the existing link call (rule 5:
// 108 [01 01] / [01 00] behind the switch — nothing new is sent), live HR (toggle 3) kept on to keep the app awake.
// Every live beat re-checks the decision (in the background a beat is what wakes the app), but the link is only told
// when the decision changes.

extension AppModel {
    /// The planned sleep window around now: tonight's bedtime → the coming morning's latest wake (else bed + 9 h).
    func rawOpticalSleepWindow() -> (start: Date, end: Date)? {
        guard let ctx = lastContext else { return nil }
        let bed = ctx.anchors.bedtime
        return (bed, ComputeWindow.nightEnd(anchors: ctx.anchors, latestWake: settings.latestWake, calendar: calendar))
    }

    /// T124: any of the extra windows (workout, "on for X every X", still wrist) is configured.
    var rawOpticalWindowsOn: Bool {
        settings.rawOpticalInWorkout || settings.spo2Every?.isValid == true || settings.rawOpticalWhenStill
    }

    /// T124: raw optical wanted by a workout, the periodic window or a still wrist (a still window holds 60 s). Only
    /// the existing 108 on / off runs; the schedule decision below is still evaluated, so its state stays current.
    func rawOpticalExtraWindow() -> Bool {
        let now = clock.now
        if let u = rawOpticalStillUntil, now < u { return true }
        let fresh = motionTrace.lastAt.map { now.timeIntervalSince($0) < 5 } ?? false
        let why = RawOpticalWindows.reason(now: now, workout: settings.rawOpticalInWorkout && sessions.workout != nil,
                                           every: settings.spo2Every, stillGate: settings.rawOpticalWhenStill,
                                           motion: fresh ? motionTrace.values : [])
        if why == .still { rawOpticalStillUntil = now.addingTimeInterval(RawOpticalWindows.stillHoldS) }
        return why != nil
    }

    /// Whether raw optical may run now: an extra window (T124), else the nights-only schedule, else "the app is open".
    func rawOpticalAllowedNow() -> Bool {
        let schedule = rawOpticalScheduleAllowedNow()
        // r9q: an automatic workout / burst may run with the app in the background even in the nights-only mode
        return autoStreamsOn || rawOpticalExtraWindow() || schedule
    }

    /// The nights-only schedule's window, else "the app is open".
    private func rawOpticalScheduleAllowedNow() -> Bool {
        if let u = spo2SpotUntil, clock.now < u { return true }      // #77: a spot reading runs for 60 s
        // T9984: a switch that is on runs with the app in the background too, until Mo switches it off.
        guard settings.rawOpticalNightsOnly else {
            rawOpticalDecision = nil
            return StrapStreamPolicy.opticalMayRun(nightsOnly: false, appActive: appActive, scheduleRunNow: nil)
        }
        guard let w = rawOpticalSleepWindow() else {
            rawOpticalDecision = nil
            return StrapStreamPolicy.opticalMayRun(nightsOnly: true, appActive: appActive, scheduleRunNow: nil)
        }
        let d = RawOpticalNight.decide(now: clock.now, strapOffsetS: strapInfo?.clockOffsetSeconds ?? 0,
                                       sleepStart: w.start, sleepEnd: w.end,
                                       schedule: settings.spo2Schedule ?? .researchDefault)
        rawOpticalDecision = d
        // Wave W11 (2026-10-11 21:43, Mo: on by default): live optical while the app is in use, plus the night
        // windows in the background. It used to be the night windows only once this switch was on.
        return appActive || d.runNow
    }

    /// Live HR wanted to keep the app awake for the nights-only schedule.
    var rawOpticalKeepAwake: Bool {
        guard settings.rawOpticalOn, !isSample else { return false }
        // T124: a periodic or still-wrist window needs the app awake in the background too (workouts already run live HR)
        return (settings.rawOpticalNightsOnly && (rawOpticalDecision?.keepAwake ?? false))
            || settings.spo2Every?.isValid == true || settings.rawOpticalWhenStill
    }

    /// Every live beat (and every refresh): re-decide; tell the link and the realtime toggles only on a change.
    func rawOpticalTick() {
        guard settings.rawOpticalOn, settings.rawOpticalNightsOnly || rawOpticalWindowsOn, !isSample else { return }
        let before = rawOpticalDecision?.keepAwake
        let allowed = rawOpticalAllowedNow()
        if rawOpticalAllowedLast != allowed {
            rawOpticalAllowedLast = allowed
            applyRawOptical()
        }
        if before != rawOpticalDecision?.keepAwake { applyRealtime(force: true) }
    }

    /// T124: Strap & sync › raw optical windows. Only changes when the existing 108 on / off runs.
    func setRawOpticalWindows(inWorkout: Bool, every: SpO2Every?, whenStill: Bool) async {
        guard !isSample else { return showNotice("Sample data is on — the strap is not asked for raw optical.") }
        if let e = every, !e.isValid { return showNotice("Raw optical windows: the \"on\" time must be shorter than the gap.") }
        settings.rawOpticalInWorkout = inWorkout
        settings.spo2Every = every
        settings.rawOpticalWhenStill = whenStill
        rawOpticalStillUntil = nil
        await saveState()
        applyRawOptical()
        applyRealtime(force: true)
        showNotice("Raw optical windows saved (they use strap battery).")
    }

    func setRawOpticalNightsOnly(_ on: Bool) async {
        guard !isSample else { return showNotice("Sample data is on — the strap is not asked for raw optical.") }
        settings.rawOpticalNightsOnly = on
        await saveState()
        applyRawOptical()
        applyRealtime(force: true)
        // W10 merge (11:20 PM): was "Raw optical: nights only — …" / "while the app is open."; since W11 the night
        // windows come on top of the app-open stream.
        // T10000: since 0.5.8 raw optical runs in the background until switched off, pausing only for history downloads.
        showNotice(on ? "Raw optical: runs in the background until you switch it off (pauses only for history downloads), "
                        + "and at night around the strap's SpO₂ bursts while you sleep (live HR keeps the app awake; "
                        + "uses strap battery)."
                      : "Raw optical: runs in the background until you switch it off (pauses only for history downloads).")
    }

    /// After a history download: learn this strap's SpO₂ burst schedule from the last 36 h of R18 (ALG-021:windows'
    /// duty detection). Kept only when a duty cycle was measured.
    func learnSpO2Schedule() async {
        guard !isSample else { return }
        let to = Int64(clock.now.timeIntervalSince1970)
        guard let rows = try? await services.store.r18Seconds(from: to - 36 * 3600, to: to, strapId: nil) else { return }
        let d = ALG021Windows.duty(ts: rows.map(\.ts), bytes: rows.map(\.spo2Byte))
        guard d.isCycled, let p = d.periodS, let ph = d.phaseS, let w = d.windowLenS else { return }
        let learned = SpO2BurstSchedule(periodS: p, phaseS: ph, windowLenS: w, learnedAt: clock.now)
        if settings.spo2Schedule.map({ ($0.periodS, $0.phaseS, $0.windowLenS) != (p, ph, w) }) ?? true {
            settings.spo2Schedule = learned
            await saveState()
        }
    }

    /// Once per refresh: close the night that ended (live R20 records stored in it), open tonight's, and re-measure the
    /// battery cost at most every 30 min. Nights are logged whether or not optical ran: the cost compares the two.
    func rawOpticalNightHousekeeping() async {
        guard !isSample else { return }
        autoRawHousekeeping()      // r9q: workout detector end rules, bursts, their keep-awake window
        let now = clock.now
        var changed = false
        if var p = settings.rawOpticalPendingNight, now >= p.end {
            p.frames = (try? await services.store.r20RecordCount(from: Int64(p.start.timeIntervalSince1970),
                                                                  to: Int64(p.end.timeIntervalSince1970))) ?? 0
            settings.rawOpticalNights = Array((settings.rawOpticalNights + [p]).suffix(30))
            settings.rawOpticalPendingNight = nil
            changed = true
        }
        if settings.rawOpticalPendingNight == nil, let w = rawOpticalSleepWindow(), now < w.end,
           !settings.rawOpticalNights.contains(where: { abs($0.start.timeIntervalSince(w.start)) < 3600 }) {
            settings.rawOpticalPendingNight = RawOpticalNightLog(start: w.start, end: w.end, frames: 0)
            changed = true
        }
        if changed { await saveState() }
        if rawOpticalCostAt.map({ now.timeIntervalSince($0) >= 1800 }) ?? true, let first = settings.rawOpticalNights.first,
           let last = settings.rawOpticalNights.last {
            rawOpticalCostAt = now
            let readings = (try? await services.store.batteryReadings(from: Int64(first.start.timeIntervalSince1970),
                                                                       to: Int64(last.end.timeIntervalSince1970))) ?? []
            rawOpticalCost = RawOpticalCost.estimate(readings: readings, nights: settings.rawOpticalNights)
        }
        rawOpticalTick()
    }
}
