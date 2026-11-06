import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSignal
import MGStore

// Mo's strap alarms (added 2026-10-11): the Fajr wake, the normal wake's strap layer, custom alarms, timers, and the
// calendar / reminders buzz. Rule 5 (project CLAUDE.md, changed 2026-10-11 12:35 PT with Mo's go-ahead) allows exactly
// the writes used here: SET_ALARM_TIME 66 (slot 1, default pattern), DISABLE_ALARM 69, GET_ALARM_TIME 67 and the buzz 19
// (1–8 pulses) — MGBLE's StrapLink+StrapAlarm, every write logged.
//
// One tick (every 15 s while the app runs, and on every connection, strap event, beat-driven smart moment and edit):
//   1. plan the next 7 days (AlarmPlanner: weekly + overrides, Fajr windows at the saved location, skips);
//   2. keep one iPhone alarm (AlarmKit) per occurrence that has a backstop — scheduled days ahead, so they ring with the
//      app dead (the safe failure); cancelled only when Mo is up (awake evidence, "I'm up") or stops a timer;
//   3. slot 1 of the strap carries the next due occurrence's latest time (StrapSlotPolicy), re-armed on every connection
//      (clock drift, RTC loss) — the strap fires it on its own clock even with the phone off;
//   4. for an occurrence whose window is open: the light-sleep moment (Fajr: our live stager; normal: the smart wake's
//      ring), the buzz schedule (RingPolicy) and the awake check (AwakeEvidence on stored HR + the R18 seconds an
//      offload brings — pulled every 3 min while it rings);
//   5. after a Fajr wake that ended awake: did Mo stay up? (AwakeEvidence.stayedAwake) → the normal wake that day is
//      skipped (switchable) — with too little data it is NOT skipped;
//   6. calendar events / reminders due now → a short buzz (best-effort, read-only EventKit).
// SAMPLE mode: nothing is written to the strap (the app's hard rule); the iPhone alarms still ring.

extension AppModel {
    private var al: AlarmsModel { alarms }

    // MARK: Lifecycle

    func startAlarms() async {
        await alarmsLoad()
        al.ticker?.cancel()
        al.ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.alarmsTick()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        startTimers()
    }

    /// Timers (T153, wired 2026-10-12): gives the timers controller the same strap link + consent the alarm engine uses
    /// (`alarmLink()` / `consentAt`), then starts its tick loop. Until this runs (a Siri intent that launched the app in the
    /// background) only the iPhone alert goes out.
    func startTimers() {
        TimersController.shared.strap = { [weak self] in
            guard let self else { return TimersController.StrapAccess(link: nil, consentAt: Date()) }
            let (link, _) = self.alarmLink()
            return TimersController.StrapAccess(link: link, consentAt: self.consentAt)
        }
        TimersController.shared.start()
    }

    func alarmsLoad() async {
        guard !al.loaded else { return }
        do {
            al.settings = try await services.kv.load(AlarmsSettings.self, key: AlarmsSettings.storeKey) ?? AlarmsSettings()
        } catch {
            if let raw = try? await services.store.value(forKey: AlarmsSettings.storeKey) {
                try? await services.store.setValue(raw, forKey: AlarmsSettings.storeKey + ".unreadable")
            }
            showNotice("The alarm settings couldn't be read; defaults are used (the old ones are kept). \(error)")
        }
        al.runtime = (try? await services.kv.load(AlarmsRuntime.self, key: AlarmsRuntime.storeKey)) ?? AlarmsRuntime()
        al.loaded = true
        al.calendars = al.calendarReader.sources(.event)
        al.reminderLists = al.calendarReader.sources(.reminder)
    }

    func alarmsSaveSettings() async {
        al.settings.consentAt = clock.now
        do { try await services.kv.save(al.settings, key: AlarmsSettings.storeKey) } catch {
            showNotice("The alarm settings weren't saved: \(error)")
        }
    }

    func alarmsSaveRuntime() async {
        try? await services.kv.save(al.runtime, key: AlarmsRuntime.storeKey)
    }

    var alarmsNormalInput: NormalWakeInput {
        NormalWakeInput(on: settings.smartWakeOn, weekly: settings.latestWake, windowMinutes: settings.wakeWindowMinutes)
    }

    /// The link for alarm writes, or why not.
    private func alarmLink() -> ((any AlarmLink)?, String?) {
        if isSample { return (nil, "Sample data is on — nothing is written to the strap.") }
        // WHOOP4-WIRE 5: with "WHOOP 4.0" selected the alarms and buzzes go to the 4.0 link (one slot, Whoop4Link+Alarm)
        let selected: (any AlarmLink)? = StrapDeviceChoice.stored == .whoop4 ? services.whoop4.link : services.strap.link
        guard let link = selected else { return (nil, "the strap link has not started") }
        switch link.state {
        case .ready, .downloadingHistory: return (link, nil)
        default: return (nil, "strap not connected")
        }
    }

    private var consentAt: Date { al.settings.consentAt ?? clock.now }

    /// Wave W12b (#103, AppModel+HandBack): the alarm consent time, and "slot 1 was cleared by the hand-back" — forget the
    /// armed state so the next connection re-arms it.
    var alarmsConsentAt: Date { consentAt }
    func alarmsSlotClearedByHandBack() { al.runtime.slot = StrapSlotState() }

    var alarmsStrapConnected: Bool {
        switch selectedHistoryLink?.state {
        case .ready?, .downloadingHistory?: return true
        default: return false
        }
    }

    // MARK: The tick

    func alarmsTick() async {
        guard al.loaded else { return }
        if al.ticking {
            al.tickAgain = true
            return
        }
        al.ticking = true
        defer { al.ticking = false }
        repeat {
            al.tickAgain = false
            await alarmsTickOnce()
        } while al.tickAgain
    }

    private func alarmsTickOnce() async {
        let now = clock.now
        let before = al.runtime
        al.settings.prune(now: now, calendar: calendar)
        al.runtime.prune(now: now)
        await alarmsExpireOneTime(now: now)
        al.plan = AlarmPlanner.plan(settings: al.settings, normal: alarmsNormalInput, now: now, calendar: calendar,
                                    suppressed: al.runtime.suppressed)
        await alarmsBackstops(now: now)
        await alarmsClearOrphanSlot(now: now)
        await alarmsSlot(now: now)
        await alarmsRings(now: now)
        await alarmsSecondWake(now: now)
        await alarmsCalendar(now: now)
        alarmsRealtime(now: now)
        if al.runtime != before { await alarmsSaveRuntime() }
        alarmsPublish()
    }

    // MARK: 1b. One-time alarms that have passed (T152)

    /// A one-time custom alarm whose time and iPhone backstop have passed leaves the list (it used to stay "armed" with a
    /// past time for a day). Runs at the top of every tick, so it also catches alarms that fired while the app was not
    /// running (the tick runs on launch, every 15 s, on connect and after each edit). The strap slot is cleared by
    /// `alarmsClearOrphanSlot`, which retries each tick until the strap is reachable.
    private func alarmsExpireOneTime(now: Date) async {
        let gone = al.settings.expireOneTime(now: now, calendar: calendar, finished: al.finishedIds)
        guard !gone.isEmpty else { return }
        for a in gone {
            // The backstop has rung: forget it WITHOUT cancelling, so a still-ringing one can be stopped on the lock screen.
            for (key, s) in al.runtime.backstops where CustomAlarm.owns(key, id: a.id) {
                if s.at > now { await al.backstops.cancel(s) }
                al.runtime.backstops.removeValue(forKey: key)
            }
            let name = a.label.isEmpty ? "Alarm" : a.label
            al.runtime.note("one-time alarm “\(name)” (\(ClockText.hm(hour: a.minutes / 60, minute: a.minutes % 60))) "
                            + "has passed — removed from the list", at: now)
        }
        // Not alarmsSaveSettings(): that stamps `consentAt` (when Mo last changed something), and Mo changed nothing.
        try? await services.kv.save(al.settings, key: AlarmsSettings.storeKey)
    }

    /// Slot 1 still holds an alarm that is no longer in the list (deleted, or a one-time alarm that passed): clear it with
    /// DISABLE_ALARM (69), over the existing path. `StrapSlotPolicy` keeps a slot whose time has passed (it fired or cleared
    /// itself), so this is the explicit release. Retried each tick while the strap is not connected.
    private func alarmsClearOrphanSlot(now: Date) async {
        guard let occ = al.runtime.slot.occurrenceId, occ.hasPrefix("custom:") else { return }
        let parts = occ.split(separator: ":")
        guard parts.count >= 2, let id = UUID(uuidString: String(parts[1])),
              !al.settings.custom.contains(where: { $0.id == id }) else { return }
        let (link, why) = alarmLink()
        guard let link else {
            let text = "slot 1 not cleared (\(why ?? "?")) — its alarm was removed"
            if al.runtime.lastSlotResult != text { al.runtime.lastSlotResult = text }
            return
        }
        do {
            let r = try await link.disableStrapAlarm(consentAt: consentAt)
            if r.ok { al.runtime.slot = StrapSlotState() }
            al.runtime.lastSlotResult = "\(r.ok ? "cleared" : "NOT cleared") — its alarm was removed — \(r.result)"
            al.runtime.note("strap alarm: \(al.runtime.lastSlotResult!)", at: now)
        } catch {
            al.runtime.lastSlotResult = "slot 1 not cleared: \(StrapCoordinator.words(error))"
        }
    }

    // MARK: 2. iPhone backstops

    private func alarmsBackstops(now: Date) async {
        var wanted: [String: (Date, String)] = [:]
        for o in al.plan.occurrences where !al.runtime.stoppedByMo.contains(o.id) {
            guard let at = o.backstopAt, at > now else { continue }
            let title = o.kind == .fajr ? "Fajr — time to get up" : (o.kind == .timer ? "Timer: \(o.label)" : o.label)
            wanted[o.id] = (at, title)
        }
        for (id, s) in al.runtime.backstops {
            if let w = wanted[id], abs(w.0.timeIntervalSince(s.at)) < 1 { continue }
            if s.at > now { await al.backstops.cancel(s) }
            al.runtime.backstops.removeValue(forKey: id)
        }
        // Wave W11 (2026-10-11): no notice any more — it came up on every launch and for every alarm ("a widget error
        // every time"). A refused AlarmKit alarm is now a notification backstop; the page's iPhone line says which layer
        // is armed and AlarmKit's reason, and the log gets one line each time the reason changes (kept across launches).
        for (id, w) in wanted where al.runtime.backstops[id] == nil {
            if let s = await al.backstops.schedule(occurrenceId: id, at: w.0, title: w.1) {
                al.runtime.backstops[id] = s
            }
        }
        let ak = al.backstops.alarmKitProblem, nf = al.backstops.notificationProblem
        if !wanted.isEmpty, ak != al.runtime.alarmKitProblem || nf != al.runtime.notificationProblem {
            if let ak, ak != al.runtime.alarmKitProblem {
                al.runtime.note("iPhone alarm: AlarmKit refused — \(ak); notification with sound instead", at: now)
            }
            if let nf, nf != al.runtime.notificationProblem { al.runtime.note("iPhone alarm not armed: \(nf)", at: now) }
            al.runtime.alarmKitProblem = ak
            al.runtime.alarmKitProblemAt = ak == nil ? nil : (al.backstops.alarmKitProblemAt ?? now)
            al.runtime.notificationProblem = nf
        }
    }

    /// Wave W11: the Alarms page's iPhone line (IPhoneAlarmLayer).
    var alarmsIPhoneLine: String {
        let live = al.runtime.backstops.values
        return IPhoneAlarmLayer.line(alarmKitCount: live.filter { $0.kind == .alarmKit }.count,
                                     notificationCount: live.filter { $0.kind == .notification }.count,
                                     alarmKitProblem: al.runtime.alarmKitProblem, problemAt: al.runtime.alarmKitProblemAt,
                                     notificationProblem: al.runtime.notificationProblem, calendar: calendar)
    }

    // MARK: 3. Strap slot 1

    private func alarmsSlot(now: Date) async {
        let action = StrapSlotPolicy.decide(plan: al.plan, finished: al.finishedIds, slot: al.runtime.slot,
                                            connection: al.connection, now: now, enabled: al.settings.strapSlotOn)
        switch action {
        case .keep:
            return
        case .arm(let o):
            let (link, why) = alarmLink()
            guard let link else {
                al.runtime.lastSlotResult = "not armed: \(why ?? "?")"
                return
            }
            if let f = al.lastArmFailure, f.id == o.id, f.connection == al.connection,
               now.timeIntervalSince(f.at) < 300 { return }      // refused a moment ago on this connection
            do {
                let r = try await link.armStrapAlarm(at: o.latest, consentAt: consentAt)
                if r.ok {
                    al.runtime.slot = StrapSlotState(occurrenceId: o.id, armedFor: o.latest, armedAt: now,
                                                     connection: al.connection)
                    al.runtime.slotConfirmedAt = nil
                    al.lastArmFailure = nil
                } else {
                    al.lastArmFailure = (o.id, al.connection, now)
                }
                al.runtime.lastSlotResult = "\(r.ok ? "armed" : "NOT armed") for \(MGFormat.time(o.latest, calendar: calendar))"
                    + " (\(o.label)) — \(r.result)"
                al.runtime.note("strap alarm: \(al.runtime.lastSlotResult!)", at: now)
            } catch {
                al.runtime.lastSlotResult = "not armed: \(StrapCoordinator.words(error))"
                al.lastArmFailure = (o.id, al.connection, now)    // don't retry every 15 s on this connection
                al.runtime.note("strap alarm: \(al.runtime.lastSlotResult!)", at: now)
            }
        case .disable(let reason):
            let (link, why) = alarmLink()
            guard let link else {
                al.runtime.lastSlotResult = "slot 1 not cleared (\(why ?? "?")) — \(reason)"
                return
            }
            do {
                let r = try await link.disableStrapAlarm(consentAt: consentAt)
                if r.ok { al.runtime.slot = StrapSlotState() }
                al.runtime.lastSlotResult = "\(r.ok ? "cleared" : "NOT cleared") — \(reason) — \(r.result)"
                al.runtime.note("strap alarm: \(al.runtime.lastSlotResult!)", at: now)
            } catch {
                al.runtime.lastSlotResult = "slot 1 not cleared: \(StrapCoordinator.words(error))"
            }
        }
    }

    // MARK: 4. Ringing

    private func alarmsRings(now: Date) async {
        for o in al.plan.occurrences where !al.finishedIds.contains(o.id) {
            guard o.windowStart <= now else { continue }
            var st = al.runtime.rings[o.id] ?? RingState(occurrenceId: o.id)
            if o.kind == .fajr, let w = al.watcher, w.occurrenceId == o.id, let at = w.rangAt, st.smartAt == nil {
                st.smartAt = at
                al.runtime.note("Fajr: light-sleep moment in the window (live stager)", at: now)
            }
            if o.isWake {
                await alarmsAwakeCheck(o, &st, now: now)
            }
            let slotHolds = al.runtime.slot.occurrenceId == o.id && al.runtime.slot.armedFor == o.latest
            switch RingPolicy.next(o, st, now: now, slotHoldsThis: slotHolds) {
            case .wait:
                break
            case .buzz(let pulses, let why):
                let (link, problem) = alarmLink()
                if let link, let p = BuzzPulses(pulses) {
                    do {
                        let r = try await link.buzz(p, consentAt: consentAt)
                        if r.ok { st.buzzes.append(now) }
                        al.runtime.note("\(o.label): buzz \(pulses) (\(why)) — \(r.result)", at: now)
                    } catch {
                        al.runtime.note("\(o.label): buzz not sent — \(StrapCoordinator.words(error))", at: now)
                    }
                } else if al.lastBuzzProblem.map({ now.timeIntervalSince($0) > 300 }) ?? true {
                    al.lastBuzzProblem = now
                    al.runtime.note("\(o.label): can't buzz — \(problem ?? "?") (the iPhone alarm still rings)", at: now)
                }
            case .finish(let why):
                await alarmsFinish(o, st, reason: why, now: now)
                continue
            }
            al.runtime.rings[o.id] = st
        }
    }

    /// Awake evidence for a wake occurrence. Before the first vibration only "I'm up" or walking count (a sleep
    /// arousal with a heart-rate rise must not cancel Fajr); after it, heart rate + movement count too — for the
    /// harder-locked Fajr with the stricter `fajrLocked` parameters.
    private func alarmsAwakeCheck(_ o: AlarmOccurrence, _ st: inout RingState, now: Date) async {
        guard st.awakeAt == nil else { return }
        let imUp = al.runtime.imUpAt[o.id]
        if let t = imUp {
            st.awakeAt = t
            st.awakeWhy = "you tapped I'm up"
            return
        }
        if let last = al.lastAwakeCheck[o.id], now.timeIntervalSince(last) < 55 { return }
        al.lastAwakeCheck[o.id] = now
        // Fresh motion only comes with an offload: pull one every 3 min once the alarm has vibrated.
        if st.lastVibration != nil, al.lastHistoryPull.map({ now.timeIntervalSince($0) > 180 }) ?? true,
           case (let link?, nil) = alarmLink() {
            al.lastHistoryPull = now
            Task { _ = try? await link.downloadHistory() }
        }
        let start = Int64(o.windowStart.timeIntervalSince1970)
        let t = Int64(now.timeIntervalSince1970)
        guard let r18 = try? await services.store.r18Seconds(from: start - 25 * 60, to: t + 1),
              let hr = try? await services.store.hrSamples(from: start - 25 * 60, to: t + 1) else { return }
        let minutes = AwakeEvidence.minutes(r18: r18, hr: hr, from: start - 20 * 60, to: t)
        let baseline = AwakeEvidence.baselineHR(minutes, before: start)
        var verdict = AwakeEvidence.evaluate(since: start, now: t, baselineHR: nil, minutes: minutes, imUpAt: nil)
        if !verdict.isAwake, let first = [st.buzzes.first, st.strapFiredAt].compactMap({ $0 }).min() {
            verdict = AwakeEvidence.evaluate(since: Int64(first.timeIntervalSince1970), now: t, baselineHR: baseline,
                                             minutes: minutes, imUpAt: nil,
                                             params: o.locked ? .fajrLocked : .v1)
        }
        switch verdict {
        case .awake(let at, let why):
            st.awakeAt = Date(timeIntervalSince1970: TimeInterval(at))
            st.awakeWhy = why
            if o.kind == .fajr, let b = baseline { al.runtime.fajrSleepingHR[o.day] = b }
        case .notYet(let why):
            al.runtime.awakeNotes[o.id] = "not up yet: \(why)"
        }
    }

    private func alarmsFinish(_ o: AlarmOccurrence, _ st: RingState, reason: String, now: Date) async {
        var st = st
        st.finishedAt = now
        st.finishReason = reason
        al.runtime.rings[o.id] = st
        // A tap / Silence on a WAKE alarm silences it but is not "up" (D-031): its iPhone alarm stays (RingStop.endedByMo).
        let byMo = RingStop.endedByMo(isWake: o.isWake, st)
        let words: String
        if let a = st.awakeAt {
            words = "up at \(MGFormat.time(a, calendar: calendar)) (\(st.awakeWhy ?? "awake"))"
        } else {
            words = reason
        }
        al.runtime.finished[o.id] = words
        al.runtime.finishedAt[o.id] = now
        al.runtime.awakeNotes.removeValue(forKey: o.id)
        if al.runtime.imUpAskedFor == o.id { al.runtime.imUpAskedFor = nil }
        al.runtime.note("\(o.label): \(words)", at: now)
        if byMo {
            al.runtime.stoppedByMo.insert(o.id)
            if let s = al.runtime.backstops[o.id] {
                await al.backstops.cancel(s)
                al.runtime.backstops.removeValue(forKey: o.id)
            }
            if o.kind == .normal { await smartWake?.stop() }     // its iPhone alarm: only on awake evidence
            if o.kind == .fajr, let a = st.awakeAt { al.runtime.fajrAwake[o.day] = a }
        }
        if o.kind == .fajr, al.watcher?.occurrenceId == o.id { al.watcher = nil }
    }

    // MARK: 5. The second wake after Fajr

    private func alarmsSecondWake(now: Date) async {
        guard al.settings.normal.skipIfAwakeAfterFajr else { return }
        for o in al.plan.occurrences where o.kind == .normal && !al.runtime.keptNormal.contains(o.id) {
            guard let awake = al.runtime.fajrAwake[o.day], now < o.latest,
                  now >= o.windowStart.addingTimeInterval(-15 * 60) else { continue }
            let key = "second:" + o.id
            if let last = al.lastAwakeCheck[key], now.timeIntervalSince(last) < 120 { continue }
            al.lastAwakeCheck[key] = now
            // Motion since the Fajr wake reaches the phone with an offload: pull one first (at most every 5 min).
            if al.lastHistoryPull.map({ now.timeIntervalSince($0) > 300 }) ?? true, case (let link?, nil) = alarmLink() {
                al.lastHistoryPull = now
                Task { _ = try? await link.downloadHistory() }     // never blocks the tick; read on the next check
            }
            let from = Int64(awake.timeIntervalSince1970)
            let t = Int64(now.timeIntervalSince1970)
            guard let r18 = try? await services.store.r18Seconds(from: from, to: t + 1),
                  let hr = try? await services.store.hrSamples(from: from, to: t + 1) else { continue }
            let minutes = AwakeEvidence.minutes(r18: r18, hr: hr, from: from, to: t)
            switch AwakeEvidence.stayedAwake(from: from, to: t, sleepingHR: al.runtime.fajrSleepingHR[o.day],
                                             minutes: minutes) {
            case .stayedAwake(let why):
                al.runtime.suppressed[o.id] = "you stayed up after Fajr (\(why))"
                al.runtime.note("Wake \(o.day): skipped — you stayed up after Fajr", at: now)
                showNotice("Normal wake skipped: you stayed up after Fajr.")
                al.plan = AlarmPlanner.plan(settings: al.settings, normal: alarmsNormalInput, now: now,
                                            calendar: calendar, suppressed: al.runtime.suppressed)
                lastSmartWakeRequest = nil             // the smart wake re-plans (and stands down) on the refresh
                Task { [weak self] in await self?.refresh() }
            case .backToSleep(let at):
                al.runtime.keptNormal.insert(o.id)
                al.runtime.note("Wake \(o.day): kept — back to sleep at \(MGFormat.time(Date(timeIntervalSince1970: TimeInterval(at)), calendar: calendar))", at: now)
            case .unknown(let why):
                if now >= o.windowStart {       // decide by the window's start: unknown keeps the alarm (safe side)
                    al.runtime.keptNormal.insert(o.id)
                    al.runtime.note("Wake \(o.day): kept — \(why)", at: now)
                }
            }
        }
    }

    // MARK: 6. Calendar and Reminders buzz (best-effort)

    private func alarmsCalendar(now: Date) async {
        let c = al.settings.calendar
        guard c.eventsOn || c.remindersOn else { return }
        if let last = al.lastCalendarCheck, now.timeIntervalSince(last) < 30 { return }
        al.lastCalendarCheck = now
        let items = await al.calendarReader.items(from: now.addingTimeInterval(-180), to: now.addingTimeInterval(3600),
                                                  settings: c)
        let due = CalendarBuzzPlanner.due(items, settings: c, now: now, buzzed: Set(al.runtime.calendarBuzzed.keys))
        guard !due.isEmpty else { return }
        let (link, why) = alarmLink()
        for item in due {
            al.runtime.calendarBuzzed[item.key] = now
            guard let link, let p = BuzzPulses(c.pulses) else {
                al.runtime.note("\(item.source == .event ? "Calendar" : "Reminder"): “\(item.title)” — not buzzed (\(why ?? "?"))", at: now)
                continue
            }
            let r = try? await link.buzz(p, consentAt: consentAt)
            al.runtime.note("\(item.source == .event ? "Calendar" : "Reminder"): “\(item.title)” — buzz \(c.pulses) "
                            + (r?.result ?? "not sent"), at: now)
        }
    }

    // MARK: 7. Notification buzz by app and person (T53)

    /// A notification from our app (`mg.<kind>`) or Personal OS (`personal-os`, via `mgapp://buzz`): buzz the strap if Mo's
    /// rules say so. The decision is MGContext's NotificationBuzzPlanner; only the app id and name are used, never the text.
    func buzzForNotification(source: String, person: String?) async {
        let now = clock.now
        let ctx = await services.notifyCenter.context
        let quiet = (ctx.quiet ?? .beforeFirstAnchors).isQuiet(at: now, wokeAt: ctx.wokeAt, calendar: calendar)
        guard let n = NotificationBuzzPlanner.pulses(source: source, person: person, settings: al.settings.notifications,
                                                     now: now, inQuiet: quiet, lastBuzz: al.notificationBuzzed) else { return }
        al.notificationBuzzed[NotificationBuzzPlanner.key(source: source, person: person)] = now
        let (link, why) = alarmLink()
        guard let link, let p = BuzzPulses(n) else {
            al.runtime.note("Notification: \(source) — not buzzed (\(why ?? "?"))", at: now)
            return
        }
        let r = try? await link.buzz(p, consentAt: consentAt)
        al.runtime.note("Notification: \(source) — buzz \(n) " + (r?.result ?? "not sent"), at: now)
    }

    // MARK: Realtime HR while a wake window is near (keeps the app alive; feeds the Fajr stager)

    private func alarmsRealtime(now: Date) {
        let bed = lastContext?.anchors.bedtime
        let wake = al.plan.occurrences.first { o in
            o.isWake && o.strapBuzz && !al.finishedIds.contains(o.id)
        }
        var want = false
        if let o = wake {
            let from = max(o.windowStart.addingTimeInterval(-9 * 3600),
                           (bed ?? o.windowStart).addingTimeInterval(-30 * 60))
            want = !isSample && now >= min(from, o.windowStart.addingTimeInterval(-60 * 60))
            if o.kind == .fajr, want, al.watcher?.occurrenceId != o.id, now < o.latest {
                al.watcher = FajrWatcher(occurrence: o, startedAt: now, strapOffset: strapInfo?.clockOffsetSeconds ?? 0)
            }
        }
        if let w = al.watcher {
            let strapNow = Int64((now.timeIntervalSince1970 + (strapInfo?.clockOffsetSeconds ?? 0)).rounded(.down))
            if w.tick(strapNow: strapNow, now: now) { al.tickAgain = true }
        }
        if want != al.wantsRealtime {
            al.wantsRealtime = want
            applyRealtime(force: true)
        }
    }

    /// Every live beat (StrapCoordinator.onBeat) also feeds the Fajr stager while it runs.
    func alarmsBeat(_ b: LiveBeat) {
        al.watcher?.take(b)
    }

    // MARK: Strap events (56–60, 100, 14)

    /// A fresh strap event. Returns true when a double-tap belonged to a ringing alarm (then it is NOT a vape hit).
    func alarmsStrapEvent(_ e: StrapEvent) async -> Bool {
        // D-031: a double tap (14), or a buzz that ended because of one (100, cause byte 2), stops a double-tap TIMER too.
        // `RingStop.decision` is the tested rule. A tap that stopped a ringing timer is not a vape hit either.
        let isTap = RingStop.decision(event: e) == .silence
        let timerStopped = isTap ? TimersController.shared.silence() : false
        // Bug 2: the strap's own alarm in a timer slot (2-6) fired: events 56-60 only ever named slot 1 before.
        if (56...60).contains(e.number) || e.number == 100 {
            TimersController.shared.logStrapEvent(number: e.number, at: Date(timeIntervalSince1970: TimeInterval(e.ts)))
        }
        if e.number == 57 || e.number == 60 {
            TimersController.shared.strapAlarmFired(at: Date(timeIntervalSince1970: TimeInterval(e.ts)))
        }
        // The strap woke the app (or the app is open): a timer that failed to arm gets another try now.
        Task { await TimersController.shared.retryStrapArms() }
        guard al.loaded else { return timerStopped && e.number == 14 }
        let at = Date(timeIntervalSince1970: TimeInterval(e.ts))
        var consumed = timerStopped && e.number == 14
        switch e.number {
        case 56:
            if let a = al.runtime.slot.armedAt, abs(at.timeIntervalSince(a)) < 180 { al.runtime.slotConfirmedAt = at }
            let when = al.runtime.slot.armedFor.map { " for \(MGFormat.time($0, calendar: calendar))" } ?? ""
            al.runtime.note("strap confirmed the alarm is set\(when) (event 56)", at: at)
        case 57, 60:
            if let o = slotOccurrence(near: at) {
                var st = al.runtime.rings[o.id] ?? RingState(occurrenceId: o.id)
                if st.strapFiredAt == nil { st.strapFiredAt = at }
                al.runtime.rings[o.id] = st
            }
            al.runtime.note(e.number == 57 ? "the strap's own alarm fired (event 57)" : "strap haptics fired (event 60)", at: at)
        case 58:
            al.runtime.note("app-driven alarm ran (event 58)", at: at)
        case 59:
            if let a = al.runtime.slot.armedFor, a <= at.addingTimeInterval(120) { al.runtime.slot = StrapSlotState() }
            al.runtime.note("the strap cleared its alarm (event 59)", at: at)
        case 100:
            al.runtime.note("strap haptics ended" + Self.hapticsEndWords(e.payloadHex), at: at)
            // Cause byte 2 = the buzz ended because of a double tap: silence like event 14 (the tap may arrive as only
            // this event). Never swallows a vape-hit double tap: the return value is ignored for event 100.
            if isTap { _ = await silenceRinging(at: at, viaDoubleTap: false) }
        case 14:
            if await silenceRinging(at: at, viaDoubleTap: true) { consumed = true }
        default:
            return false
        }
        await alarmsSaveRuntime()
        Task { [weak self] in await self?.alarmsTick() }
        return consumed
    }

    /// Silences what is ringing, for a strap tap (`viaDoubleTap` true: event 14; false: event 100 cause 2) and for the
    /// phone's Silence button: a timer / plain alarm is stopped (its iPhone alarm cancelled); a WAKE alarm is silenced
    /// too (D-031) but NOT marked awake and keeps its iPhone alarm. Returns true when something rang (then a double tap
    /// is not a vape hit).
    private func silenceRinging(at: Date, viaDoubleTap: Bool) async -> Bool {
        let hm = MGFormat.time(at, calendar: calendar)
        if let o = ringingOccurrence(at: at) {
            var st = al.runtime.rings[o.id] ?? RingState(occurrenceId: o.id)
            let first = st.acknowledgedAt == nil           // event 14 and event 100 can both arrive for one tap
            RingStop.silence(&st, at: at, viaDoubleTap: viaDoubleTap && first)
            al.runtime.rings[o.id] = st
            if first {
                al.runtime.note(o.isWake ? "\(o.label): silenced at \(hm) — not counted as awake"
                                         : "\(o.label): stopped at \(hm)", at: at)
            }
            return true
        }
        if let o = recentNonWake(at: at) {
            await acknowledgeFinished(o, at: at)
            return true
        }
        return false
    }

    /// The ONE "stop the buzzing" entry point (T159/D-031): the phone's Silence button calls this. Ends every timer's
    /// re-buzz loop and marks the ringing occurrence silenced (a wake alarm: not awake) before asking the strap once to
    /// stop its current haptics. Returns true when something was ringing in the app.
    @discardableResult
    func silence() async -> Bool {
        let timers = TimersController.shared.silence()
        var alarm = false
        let now = clock.now
        if al.loaded {
            alarm = await silenceRinging(at: now, viaDoubleTap: false)
            await alarmsSaveRuntime()
            // Reconcile any other due occurrence before STOP_HAPTICS, so this command is never immediately followed by
            // a buzz from the alarm tick.
            if al.ticking {
                al.tickAgain = true
                while al.ticking { try? await Task.sleep(for: .milliseconds(10)) }
            }
            await alarmsTick()
        }
        let (link, why) = alarmLink()
        if let link {
            do {
                let report = try await link.silenceHaptics(consentAt: consentAt)
                let words = report.ok ? "Strap silence: success."
                    : "Strap silence: no answer, strap may still be buzzing. \(report.result)"
                al.runtime.note(words, at: now)
                showNotice(words)
            } catch {
                let words = "Strap silence: no answer, strap may still be buzzing. \(StrapCoordinator.words(error))"
                al.runtime.note(words, at: now)
                showNotice(words)
            }
        } else {
            let words = "Strap silence: no answer, strap may still be buzzing. \(why ?? "strap not connected")"
            al.runtime.note(words, at: now)
            showNotice(words)
        }
        await alarmsSaveRuntime()
        return timers || alarm
    }

    /// Event 100's detail byte, as today's research reads it (payload byte 1: 0 time ran out, 1 error, 2 double-tap).
    /// DECODED, untested. Event 100 with cause 2 now also silences (`RingStop.decision`); the offset lives in
    /// `RingStop.hapticsEndCause`.
    static func hapticsEndWords(_ payloadHex: String) -> String {
        guard let cause = RingStop.hapticsEndCause(payloadHex: payloadHex) else {
            return " (event 100, raw \(payloadHex))"
        }
        let words = [0: "time ran out", 1: "error", 2: "you double-tapped"][Int(cause)] ?? "code \(cause)"
        return " (event 100: \(words) — decoded, untested; raw \(payloadHex))"
    }

    private func slotOccurrence(near at: Date) -> AlarmOccurrence? {
        guard let id = al.runtime.slot.occurrenceId, let armed = al.runtime.slot.armedFor,
              abs(at.timeIntervalSince(armed)) < 180 else { return nil }
        return al.plan.occurrences.first { $0.id == id }
    }

    /// An occurrence that vibrated or whose window is open, not finished.
    private func ringingOccurrence(at: Date) -> AlarmOccurrence? {
        al.plan.occurrences.first { o in
            guard !al.finishedIds.contains(o.id), o.windowStart <= at else { return false }
            let st = al.runtime.rings[o.id]
            return st?.lastVibration != nil || (o.isWake && at >= o.latest)
        }
    }

    /// A timer / plain alarm that buzzed in the last 3 min and whose iPhone backstop may still be pending.
    private func recentNonWake(at: Date) -> AlarmOccurrence? {
        al.plan.occurrences.first { o in
            !o.isWake && !al.runtime.stoppedByMo.contains(o.id) && al.finishedIds.contains(o.id)
                && (al.runtime.finishedAt[o.id].map { at.timeIntervalSince($0) < 180 } ?? false)
        }
    }

    private func acknowledgeFinished(_ o: AlarmOccurrence, at: Date) async {
        al.runtime.stoppedByMo.insert(o.id)
        if let s = al.runtime.backstops[o.id] {
            await al.backstops.cancel(s)
            al.runtime.backstops.removeValue(forKey: o.id)
        }
        al.runtime.note("\(o.label): stopped — iPhone alarm cancelled", at: at)
    }

    /// A new handshake: slot 1 is re-armed on it.
    func alarmsConnected() {
        al.connection += 1
        Task { await TimersController.shared.tick() }      // a timer waiting for the strap (or a ring) resumes
        Task { [weak self] in await self?.alarmsTick() }
    }

    /// The smart wake (normal wake's iPhone ring) rang at a light-sleep moment: the strap buzzes then too.
    func alarmsSmartWakeRang(at: Date) {
        guard let o = al.plan.occurrences.first(where: { $0.kind == .normal && $0.windowStart <= at && at <= $0.latest })
        else { return }
        var st = al.runtime.rings[o.id] ?? RingState(occurrenceId: o.id)
        guard st.smartAt == nil else { return }
        st.smartAt = at
        al.runtime.rings[o.id] = st
        Task { [weak self] in await self?.alarmsTick() }
    }

    /// The normal wake the smart wake should hold: the next one still ahead and not done (override-aware) — this
    /// morning's even when Today's anchors have already moved to tonight (a wake detected at Fajr would otherwise make
    /// the smart wake re-plan for tomorrow and drop this morning's iPhone alarm). When none is ahead, the weekly time's
    /// morning may be skipped (a change set to off, "you stayed up after Fajr"): then nil and why.
    func alarmsNormalTarget(after bed: Date, fallback: Date?) -> (Date?, String?) {
        guard al.loaded else { return (fallback, nil) }
        let now = clock.now
        if let o = al.plan.occurrences.first(where: { $0.kind == .normal && $0.latest > now
            && !al.finishedIds.contains($0.id) && $0.latest <= now.addingTimeInterval(30 * 3600) }) {
            return (o.latest, nil)
        }
        let days = [fallback, bed.addingTimeInterval(8 * 3600)].compactMap { $0 }
            .map { "normal:" + LocalDay(date: $0, calendar: calendar).iso }
        for k in days { if let why = al.plan.skipped[k] { return (nil, why) } }
        return (fallback, nil)       // nothing planned and nothing skipped: leave the smart wake as it was
    }

    /// Today's chip.
    func alarmsChip() -> String? {
        guard al.loaded else { return nil }
        return AlarmsPresenter.chip(plan: al.plan, finished: al.finishedIds, now: clock.now, calendar: calendar)
    }

    // MARK: Intents

    func alarmsAction(_ action: AlarmsAction) async {
        await alarmsLoad()
        let now = clock.now
        switch action {
        case .open:
            if paths[tab]?.last != .alarms { push(.alarms) }
            al.calendars = al.calendarReader.sources(.event)
            al.reminderLists = al.calendarReader.sources(.reminder)
        case .edit(let edit):
            edit.apply(to: &al.settings)
            await alarmsSaveSettings()
        case .useMyLocation:
            al.locationNote = "reading the location…"
            alarmsPublish()
            switch await al.location.readOnce() {
            case .success(let loc):
                al.settings.location = loc
                al.locationNote = nil
                await alarmsSaveSettings()
            case .failure(let f):
                al.locationNote = f.words
            }
        case .matchPillars(let minutes):
            guard let loc = al.settings.location else {
                showNotice("Tap “Use my location” first: the match needs where you are.")
                break
            }
            al.match = PrayerTimesCalculator.matchMethod(typedFajrMinutes: minutes, localDay: now, calendar: calendar,
                                                         coordinates: loc.coordinates)
        case .useMethod(let m):
            al.settings.fajr.method = m
            al.match = nil
            await alarmsSaveSettings()
        case .imUp(let confirmed):
            await alarmsImUp(confirmed: confirmed, now: now)
        case .stop:
            if let o = ringingOccurrence(at: now) {
                var st = al.runtime.rings[o.id] ?? RingState(occurrenceId: o.id)
                st.acknowledgedAt = now
                al.runtime.rings[o.id] = st
            } else if let o = recentNonWake(at: now) {
                await acknowledgeFinished(o, at: now)
            } else {
                showNotice("Nothing is buzzing to silence.")
            }
        case .silence:
            await silence()
            return
        case .testBuzz(let pulses):
            let (_, words) = await sendTestBuzz(pulses: pulses, at: now)
            showNotice("Test buzz: \(words)")
        case .testAlarm:
            await runAlarmTest(at: now)
        case .readStrapAlarm:
            let (link, why) = alarmLink()
            guard let link else {
                showNotice("Not read: \(why ?? "?")")
                break
            }
            do {
                let rec = try await link.readStrapAlarm()
                let words = rec?.words ?? "no decodable reply"
                al.runtime.note("slot 1 reads: \(words)", at: now)
                showNotice("Strap alarm slot 1: \(words)")
            } catch {
                showNotice("Not read: \(StrapCoordinator.words(error))")
            }
        // startTimer / cancelTimer retired (T153, 2026-10-12): timers are TimersController (App/Timers). Old saved
        // `AlarmTimer`s still decode and still plan their one buzz.
        case .saveCustom(let a):
            if let i = al.settings.custom.firstIndex(where: { $0.id == a.id }) {
                al.settings.custom[i] = a
            } else {
                al.settings.custom.append(a)
            }
            await alarmsSaveSettings()
        case .deleteCustom(let id):
            // T152: cancel EVERY iPhone backstop of this alarm whatever its time. The tick only cancels a backstop that is
            // still in the future, so one that had already passed was forgotten un-cancelled and could not be removed.
            for (key, s) in al.runtime.backstops where CustomAlarm.owns(key, id: id) {
                await al.backstops.cancel(s)
                al.runtime.backstops.removeValue(forKey: key)
            }
            al.settings.custom.removeAll { $0.id == id }
            al.settings.overrides.removeAll { $0.target == .custom(id) }
            await alarmsSaveSettings()
        case .addOverride(let target, let tomorrow, let days, let act):
            let first = LocalDay(date: now, calendar: calendar).adding(days: tomorrow ? 1 : 0)
            let span = AlarmOverride.allowedSpans.contains(days) ? days : 1
            al.settings.overrides.append(AlarmOverride(target: target, firstDay: first.iso, days: span, action: act,
                                                       createdAt: now))
            await alarmsSaveSettings()
        case .deleteOverride(let id):
            al.settings.overrides.removeAll { $0.id == id }
            await alarmsSaveSettings()
        case .requestCalendarAccess:
            if await al.calendarReader.requestEvents() { al.calendars = al.calendarReader.sources(.event) }
        case .requestRemindersAccess:
            if await al.calendarReader.requestReminders() { al.reminderLists = al.calendarReader.sources(.reminder) }
        case .pickCalendar(let id, let on):
            al.settings.calendar.calendarIds.removeAll { $0 == id }
            if on { al.settings.calendar.calendarIds.append(id) }
            await alarmsSaveSettings()
        case .pickReminderList(let id, let on):
            al.settings.calendar.reminderListIds.removeAll { $0 == id }
            if on { al.settings.calendar.reminderListIds.append(id) }
            await alarmsSaveSettings()
        }
        lastSmartWakeRequest = nil          // an edit may move the normal wake: the smart wake re-plans
        await alarmsTick()
    }

    private func runAlarmTest(at now: Date) async {
        let alertProblem = await al.backstops.scheduleTestAlert()
        let alertWords = alertProblem.map { "phone alert not scheduled — \($0)" } ?? "phone alert scheduled"
        let (buzzOK, buzzWords) = await sendTestBuzz(pulses: 4, at: now)
        let result = "\(buzzWords), \(alertWords)"
        let ok = buzzOK && alertProblem == nil
        al.runtime.note("alarm test — \(result)", at: now)
        await alarmsSaveRuntime()
        showNotice("Alarm test: \(result)")
        await appendTestRun(kind: .alarm, at: now, result: result, ok: ok)
    }

    /// The one-shot path used by both the Alarms-page buzz check and Settings' complete alarm test.
    private func sendTestBuzz(pulses count: Int, at now: Date) async -> (ok: Bool, words: String) {
        let (link, why) = alarmLink()
        if let link, let pulses = BuzzPulses(count) {
            do {
                let report = try await link.buzz(pulses, consentAt: consentAt)
                al.runtime.note("test buzz \(count) — \(report.result)", at: now)
                if report.result == "ok" {
                    return (true, "strap buzzed")
                } else if report.ok {
                    return (true, "strap buzz sent — \(report.result)")
                } else {
                    return (false, "strap buzz failed — \(report.result)")
                }
            } catch {
                return (false, "strap buzz failed — \(StrapCoordinator.words(error))")
            }
        }
        return (false, "strap not buzzed — \(why ?? "1–8 pulses only")")
    }

    /// "I'm up": ends the ringing wake alarm — or, within an hour before it, the next one. The Fajr wake asks twice.
    private func alarmsImUp(confirmed: Bool, now: Date) async {
        let target = al.plan.occurrences.first { o in
            o.isWake && !al.finishedIds.contains(o.id) && o.windowStart.addingTimeInterval(-3600) <= now
        }
        guard let o = target else {
            showNotice("No wake alarm is ringing or due within the hour.")
            return
        }
        if o.locked && !confirmed {
            al.runtime.imUpAskedFor = o.id
            return
        }
        al.runtime.imUpAt[o.id] = now
        al.runtime.imUpAskedFor = nil
        al.runtime.note("\(o.label): you tapped I'm up", at: now)
        if now < o.windowStart {
            // Before the window: there is nothing to check, it simply ends.
            var st = al.runtime.rings[o.id] ?? RingState(occurrenceId: o.id)
            st.awakeAt = now
            st.awakeWhy = "you tapped I'm up"
            await alarmsFinish(o, st, reason: "awake", now: now)
        }
    }

    // MARK: Page

    func alarmsPublish() {
        let input = AlarmsInput(
            now: clock.now, calendar: calendar, sample: isSample, settings: al.settings, normal: alarmsNormalInput,
            plan: al.plan, finished: al.runtime.finished, slot: al.runtime.slot,
            slotConfirmedAt: al.runtime.slotConfirmedAt, lastSlotResult: al.runtime.lastSlotResult,
            rings: al.runtime.rings, awakeNotes: al.runtime.awakeNotes, imUpAskedFor: al.runtime.imUpAskedFor,
            connected: alarmsStrapConnected,
            log: al.runtime.log.map { AlarmLogLine(id: $0.id, at: $0.at, text: $0.text) },
            locationNote: al.locationNote, match: al.match,
            calendarAccess: al.calendarReader.access(.event), remindersAccess: al.calendarReader.access(.reminder),
            calendars: al.calendars, reminderLists: al.reminderLists)
        var input2 = input
        input2.iphoneLine = alarmsIPhoneLine     // wave W11
        let s = AlarmsPresenter.make(input2)
        if al.state != s { al.state = s }
    }
}
