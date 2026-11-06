import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSignal
import MGStore

// WP-23a — fills WP-23b's `PresenterSnapshot` (reads through the active data source: the store, or SAMPLE) and turns
// it into every screen state with the presenters. All statistics are computed here with MGSignal (SnapshotMath,
// LiveSignals); presenters only word and format (main, 2026-10-11).
//
// WRITTEN, NOT COMPILED.

extension AppModel {
    // MARK: Snapshot

    /// `light` (R7 / T23, the first pass at launch): leaves out Model status' 60-day read, which only the Model status
    /// page and the one line under Today's verdict use; the full pass that follows fills it.
    func buildSnapshot(now: Date, light: Bool = false) async throws -> PresenterSnapshot {
        let src = source
        let inputs = try await src.contextInputs(now: now)
        var context = ContextEngine.evaluate(inputs)
        // r8g (T10011, audit 0.B-1): until the morning compute writes the ALG-030 wake row the anchor is only the usual
        // wake time, so the ring, hub and rim read yesterday's day (before that time) or an empty today (after it). While
        // the wake is assumed, the last wake the strap's own sleep flag gave (live flag, or a stored strap hypnogram) is
        // used for the context instead. `inputs` stays as stored: compute triggers still key off the stored wake.
        let liveSleep = await liveSleepState(now: now)
        if context.anchors.wakeAssumed {
            let todayDay = LocalDay(date: now, calendar: calendar)
            var hyps: [Series] = []
            for d in [todayDay, todayDay.adding(days: -1)] {
                let stored = try await src.series(for: d)
                hyps += StrapFlagWake.strapHypnograms(stored)
            }
            if let w = StrapFlagWake.pick(anchors: context.anchors, awakeSince: liveSleep.awakeSince, hypnograms: hyps, now: now) {
                var fixed = inputs
                fixed.detectedWake = w
                context = ContextEngine.evaluate(fixed)
            }
        }
        context.moments = visibleMoments(context.moments, now: now)

        let day = LocalDay(date: context.anchors.wake, calendar: calendar)
        let today = LocalDay(date: now, calendar: calendar)
        // Imported history (ImportedHistory) shows on past days only (a past night, Explore); the live day, recovery,
        // strain quartiles, smart wake and workout detail read the app's own values.
        let daySummary = try await src.summary(for: day)?.metrics ?? []
        var metrics = daySummary.filter { !ImportedHistory.isImported($0) }
        // r9t (D-BODY-WALK-1, D-POP-PRIOR): the PC's personal caffeine half-life (ALG-062) is written on the day the PC ran, which may
        // be yesterday's summary; the newest one found drives the curve below, else the population 5 h stays.
        if ALG062.halfLife(from: metrics) == .population,
           let prev = try await src.summary(for: day.adding(days: -1))?.metrics,
           let kept = prev.filter({ !ImportedHistory.isImported($0) && $0.name == MetricKey.caffeineHalfLife.rawValue
               && $0.variant == CaffeineHalfLife.variant }).max(by: { $0.at < $1.at }) {
            metrics.append(kept)
        }
        // Round 2: WHOOP's / Apple's recovery for the wake day, for Today's recovery fallback only (never in `metrics`).
        let importedToday = daySummary.filter { ImportedHistory.isImported($0) && $0.name == MetricKey.readiness.rawValue }
        // Oct 28 2026 (no strap since Oct 18): the wake day's Apple Health rows (pc.history; the Watch's and WHOOP's writes
        // alike, 0.6.0.7) go to the screens only, after every computation below has read `metrics`; `metric()` shows them,
        // labelled by who wrote them, where the app has no value of its own, as on a past night.
        let applesToday = daySummary.filter { ImportedHistory.isAppleHealth($0) && $0.value?.isFinite == true }
        let series = try await src.series(for: day)
        let dayBefore = day.adding(days: -1).start(in: calendar.timeZone)
        let end = now.addingTimeInterval(1)
        let events = try await src.events(from: dayBefore, to: end)
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? dayBefore
        let monthEvents = try await src.events(from: monthStart, to: end)
        let marks = try await src.groupMarks()
        let choices = SnapshotMath.groupChoices(marks)

        // ALG-160 readiness (r9h, D-RECOV-WALK-2): the wake day, OWN nights only (the import rows are filtered out of every
        // column, so WHOOP's or Apple's number never enters our baseline: audit 6.6).
        let span = SnapshotMath.days(endingAt: day, count: ALG160.historyNights)
        func ownColumn(_ key: MetricKey, _ variant: String) async throws -> DailyColumn {
            let all = try await src.metricDays(name: key.rawValue, from: span[0], to: day)
            return SnapshotMath.column(all.filter { !ImportedHistory.isImported($0.metric) }, days: span, variant: variant,
                                       choices: choices)
        }
        let hrvLnColumn = try await ownColumn(.hrvLnRmssd, "ALG-010")
        let recovery = SnapshotMath.recovery(
            hrv: hrvLnColumn, morning: try await ownColumn(.hrvLnRmssd, ALG160.morningVariant),
            morningPpg: try await ownColumn(.hrvLnRmssd, MorningCheck.ppgVariant),
            sleep: try await ownColumn(.sleepPerformance, "ALG-150"), atl: try await ownColumn(.atl, "ALG-036"),
            ctl: try await ownColumn(.ctl, "ALG-036"), stress: try await ownColumn(.stress, "ALG-123:daytime"), day: day,
            now: now)
        let rmssdRows = try await src.metricDays(name: MetricKey.hrvRmssd.rawValue, from: span[0], to: day)
            .filter { !ImportedHistory.isImported($0.metric) }
        let nights = SnapshotMath.column(rmssdRows, days: span, variant: nil, choices: choices).nonNil.suffix(14)
        nightMedianRmssd = nights.isEmpty ? nil : SignalMath.median(Array(nights))

        // Strain quartiles over the 28 days before today (UX §12).
        let strainSpan = SnapshotMath.days(endingAt: today, count: 29)
        let strainRows = try await src.metricDays(name: MetricKey.strain.rawValue, from: strainSpan[0], to: today)
            // D-LOAD-WALK-1 item 1: the quartiles are of the 0-21 number; the TRIMP headline (unit au) is another scale
            .filter { !ImportedHistory.isImported($0.metric) && $0.metric.unit == "score_0_21" }
        let quartiles = SnapshotMath.strainQuartiles(SnapshotMath.column(strainRows, days: strainSpan, variant: nil,
                                                                         choices: choices))

        let curve = SnapshotMath.caffeineCurve(events: events, now: now, bedtime: context.anchors.bedtime,
                                               params: ALG062.halfLife(from: metrics).params)
        // ALG-051 / ALG-052 at `now` (the stored rows are as old as the last day compute): a fresh alertness
        // replaces it, and the dip forecast comes from the same curve.
        let alertness = try await alertnessForecast(src: src, today: today, now: now, events: events,
                                                    bedtime: context.anchors.bedtime)
        let fresh = [ALG051.alertnessMetric(alertness, at: now)]
        metrics.removeAll { m in fresh.contains { $0.name == m.name } }
        metrics += fresh
        let dip = alertness.value.map { f in
            DipForecast(window: ALG052.dip(f, timeZone: calendar.timeZone).map { DialSpan(start: $0.start, end: $0.end) },
                        reactionTests: f.reactionTestsUsed, at: now)
        }
        let explore = try await exploreInput(src: src, today: today, choices: choices)
        let workout = try await workoutDetailInput(src: src, now: now, dayMetrics: metrics)
        let strap = try await strapSyncInfo(src: src, now: now)
        let nightSoundsOn = await services.nightSounds.isEnabled
        let ringer = smartWake?.ringerKind ?? SmartWakeRingers.preferredKind
        let wake = smartWakeSlots(context: context, metrics: metrics, now: now, ringer: ringer)

        if let nd = nightDay, nd != day {
            nightOverride = (nd, try await src.summary(for: nd)?.metrics ?? [], try await src.series(for: nd))
        } else {
            nightOverride = nil
        }

        var snapshot = PresenterSnapshot(
            now: now, calendar: calendar, sample: src.isSample, context: context, inputs: inputs, day: day,
            metrics: metrics + applesToday, series: series, events: events, monthEvents: monthEvents, recovery: recovery,
            strainQuartiles: quartiles, caffeineCurve: curve, caffeineLimitMg: ALG061.defaultLimitMg,
            groupChoices: choices,
            settings: settings.presenterSettings(profile: profile, nightSoundsOn: nightSoundsOn, ringer: ringer),
            strapSync: strap, live: liveInput(), explore: explore, breathe: breatheInput(),
            hrvCheck: hrvCheckInput(), workoutDetail: workout, ui: presenterUI(), dip: dip,
            smartWake: wake.block, smartWakeResult: wake.result, alarmChip: alarmsChip())
        snapshot.importedToday = importedToday
        snapshot.whoop4Selected = StrapDeviceChoice.stored == .whoop4       // 0.6.0.12
        snapshot.hrvLnNights = Array(hrvLnColumn.values.suffix(40))    // 0.6.0.12: the Live explainer cards' 7-night mean and normal band
        snapshot.asleepSince = liveSleep.asleepSince      // round 4, tier S: display state only (read once, above)
        snapshot.awakeSince = liveSleep.awakeSince
        if !light { snapshot.modelOutputs = try await modelOutputs(src: src, today: today, now: now) }
        try await fillOutputs(&snapshot, src: src, today: today, now: now, marks: marks)   // wave 2
        snapshot.liveHRTrace = liveHRTrace()
        snapshot.liveBackfill = liveBackfillPlan()     // wave W11
        snapshot.places = placesSnapshot
        if tab == .explore {      // T116: Explore › Workouts
            snapshot.workoutHistory = try await workoutHistoryInputs(src: src, events: monthEvents, now: now,
                                                                     dayMetrics: metrics)
        }
        if tab == .explore {      // R9m: the alertness self-check reads 14 days of reaction tests; only the Explore screen shows it
            snapshot.alertnessSelfCheck = await alertnessSelfCheck(now: now)
        }
        if settingsOnScreen { snapshot.profileRecords = try await src.profileRecords() }     // tracker #42
        snapshot.todaySoFar = await todaySoFarInput(now: now)   // #75: today's strap data, AppModel+FrontPage
        // P03: the Sundial's detail sheets
        snapshot.dialWeek = try await dialWeek(src: src, today: today, choices: choices)
        snapshot.minuteHR = try await minuteHR(src: src, events: events, now: now)
        snapshot.alertnessCurve = alertness.value?.samples.map { TimedValue(at: $0.at, value: $0.score) } ?? []
        snapshot.dialSeries = try await dialSeriesSources(src: src, today: today, now: now, loaded: series, loadedDay: day)   // r8m T10023
        snapshot.phoneAppleSleep = await readPhoneAppleSleep(now: now)      // Nov 6 2026: Apple Health's night read on the phone
        return snapshot
    }

    /// Round 4 tier S (D-9745): the strap's byte-81 sleep state of the last 5 min (stored R18 seconds, so it works with
    /// the app in the background and after a reconnect) through `SleepOnsetDetector`. Motion is not passed (no unit
    /// is pinned for gx / gy / gz), so only strap records with byte 81 can flip it; WHOOP 4.0 never does.
    /// Round 5: two hours back (not 40 min), through `SleepOnsetDetector.liveState`: asleep is latched until the flag
    /// says awake / up for 5 min straight, a gap in the stored seconds (offload lag) changes nothing, and a wake holds
    /// "awake since" for an hour so Today never says "Past your bedtime" in that time.
    func liveSleepState(now: Date) async -> LiveSleepState {
        guard !isSample else { return .unknown }
        let to = Int64(now.timeIntervalSince1970)
        guard let rows = try? await services.store.r18Seconds(from: to - 7200, to: to) else { return .unknown }
        let samples = rows.map { LiveSleepSample(at: Date(timeIntervalSince1970: TimeInterval($0.ts)),
                                                 bandState: $0.sleepState, hr: $0.hr) }
        return SleepOnsetDetector.liveState(samples, now: now)
    }

    /// P03: the last 7 days of the five series behind the Sundial's week charts, one value per day (today last). Recovery
    /// is the ALG-160 readiness score (Orchard MS-19, 1-100); the others follow the same read-method rule as Explore.
    func dialWeek(src: any SnapshotReading, today: LocalDay, choices: [String: GroupChoice]) async throws -> [String: [DayPoint]] {
        let days = SnapshotMath.days(endingAt: today, count: 7)
        let series: [(key: String, metric: MetricKey, variant: String?)] = [
            ("strain", .strain, nil), ("stress", .stress, nil), ("sleep_total", .sleepTotal, nil),
            ("sleep_need", .sleepNeed, nil), ("recovery_score", .readiness, "MS-19")]
        var out: [String: [DayPoint]] = [:]
        for s in series {
            let rows = try await src.metricDays(name: s.metric.rawValue, from: days[0], to: today)
            let column = SnapshotMath.column(rows, days: days, variant: s.variant, choices: choices)
            out[s.key] = zip(column.days, column.values).map { DayPoint(day: $0, value: $1) }
        }
        return out
    }

    /// P03: today's heart rate as one mean per minute, from 30 min before the first vape hit or medication dose to now
    /// (what their heart-rate effects need); empty when there is neither. The snapshot is rebuilt far more often than a
    /// minute passes, so the read is kept for the minute.
    func minuteHR(src: any SnapshotReading, events: [EventRecord], now: Date) async throws -> [HRPoint] {
        let midnight = calendar.startOfDay(for: now)
        let first = events.filter { e in
            guard e.at >= midnight, !e.removed else { return false }
            switch e.payload {
            case .medication: return true
            case .substance(let f): return f.kind == .vape || f.kind == .vapeTick
            default: return false
            }
        }.map(\.at).min()
        guard let first else { return [] }
        let from = max(midnight, first.addingTimeInterval(-1800))
        let key = "\(Int(from.timeIntervalSince1970))|\(Int(now.timeIntervalSince1970 / 60))|\(src.isSample)"
        if let c = MinuteHRCache.entry, c.key == key { return c.points }
        var buckets: [Int64: (sum: Double, n: Int, source: StreamSource)] = [:]
        for p in try await src.hrSamples(from: from, to: now) where p.bpm.isFinite && p.bpm > 0 {
            let b = buckets[p.ts / 60] ?? (0, 0, p.source)
            buckets[p.ts / 60] = (b.sum + p.bpm, b.n + 1, b.source)
        }
        let points = buckets.keys.sorted().map { m in
            HRPoint(ts: m * 60, bpm: buckets[m]!.sum / Double(buckets[m]!.n), source: buckets[m]!.source)
        }
        MinuteHRCache.entry = (key, points)
        return points
    }

    /// Round 8 (T10023): the stored 5-minute series the Sundial's time scrub reads, from the two calendar days its 24 h
    /// window can cover (today and the day before). `loaded` is the wake day's series already read above. Kept for the
    /// minute: the snapshot is rebuilt far more often than that.
    func dialSeriesSources(src: any SnapshotReading, today: LocalDay, now: Date, loaded: [Series],
                           loadedDay: LocalDay) async throws -> [Series] {
        let key = "\(today.iso)|\(Int(now.timeIntervalSince1970 / 60))|\(src.isSample)"
        if let c = DialSeriesCache.entry, c.key == key { return c.series }
        var out: [Series] = []
        for d in [today.adding(days: -1), today] {
            var all = loaded
            if d != loadedDay { all = try await src.series(for: d) }
            out += all.filter { DialSeries.wantedNames.contains($0.name) }
        }
        DialSeriesCache.entry = (key, out)
        return out
    }

    static let knownMetricNames: Set<String> = Set(MetricKey.allCases.map(\.rawValue))

    /// The Model status page is on a stack: fill in when each model last had a value.
    var agesOnScreen: Bool { paths.values.contains { $0.contains(.ages) } }

    var modelStatusOnScreen: Bool {
        paths.values.contains { $0.contains(.modelStatus) }
    }

    /// Settings or Preferences is on a stack (Preferences' Profile lists read the record and scan events; tracker #42).
    /// Both draw the one `SettingsState`, so both ask for the "settings" build.
    var settingsOnScreen: Bool {
        paths.values.contains { $0.contains(.settings) || $0.contains(.preferences) }
    }

    /// "metric|variant" → the newest valued row of the last 60 days, imports included (Model status: "has output ·
    /// from past data · WHOOP export · Fri 9 Oct"). Read at most every 15 min, and fresh whenever the page is open.
    func modelOutputs(src: any SnapshotReading, today: LocalDay, now: Date) async throws -> [String: ModelOutput] {
        if let c = modelOutputsCache, c.sample == src.isSample, now.timeIntervalSince(c.at) < 15 * 60,
           !modelStatusOnScreen || now.timeIntervalSince(c.at) < 60 {
            return c.outputs
        }
        var out: [String: ModelOutput] = [:]
        // R7 / T23: one read for every name (was one per metric key: 300+ reads on every launch and every 15 min).
        let known = Self.knownMetricNames
        for row in try await src.metricsAllNames(from: today.adding(days: -60), to: today)
        where known.contains(row.metric.name) && (row.metric.value?.isFinite ?? false) {
            let k = "\(row.metric.name)|\(row.metric.variant ?? "")"
            if out[k].map({ row.metric.at > $0.at }) ?? true {
                out[k] = ModelOutput(value: row.metric.value!, unit: row.metric.unit, at: row.metric.at,
                                     computedOnPC: row.metric.computedOn == .pc,
                                     importLabel: ImportedHistory.sourceLabel(row.metric))
            }
        }
        modelOutputsCache = (now, src.isSample, out)
        return out
    }

    /// R9m (D-HRV-WALK-2): where the two-week check of the alertness model against Mo's reaction tests stands. nil in
    /// SAMPLE mode or when the store read fails (the screen then says nothing is stored).
    func alertnessSelfCheck(now: Date) async -> AlertnessSelfCheck? {
        guard !isSample else { return nil }
        let from = now.addingTimeInterval(-Double(AlertnessCheck.windowDays) * 86400)
        guard let tests = try? await services.store.events(from: from, to: now, types: [.reactionTest]) else { return nil }
        let tz = calendar.timeZone
        let progress = AlertnessCheck.progress(events: tests, now: now, timeZone: tz)
        switch AlertnessCheck.agreement(events: tests, now: now, timeZone: tz) {
        case .success(let a):
            return AlertnessSelfCheck(checks: a.n, days: a.days, rho: a.rho, low: a.low, high: a.high, tracks: a.tracks)
        case .failure:
            return AlertnessSelfCheck(checks: progress.checks, days: progress.days)
        }
    }

    /// ALG-051 inputs from the store: the sleep windows of the last `historyNights` + 1 days (own rest window, else an
    /// import), and from `events` (yesterday and today) the confirmed naps and caffeine doses. Bedtime bounds the curve.
    func alertnessForecast(src: any SnapshotReading, today: LocalDay, now: Date, events: [EventRecord],
                           bedtime: Date) async throws -> Computed<ALG051.Forecast> {
        let from = today.adding(days: -(ALG051.historyNights + 1))
        var byDay: [LocalDay: [Metric]] = [:]
        for key in [MetricKey.sleepOnset, MetricKey.wakeTime] {
            for row in try await src.metricDays(name: key.rawValue, from: from, to: today) {
                byDay[row.day, default: []].append(row.metric)
            }
        }
        // Confirmed naps of yesterday and today (`events`): older naps barely move today's curve, and every refresh
        // would otherwise read 16 days of events.
        return ALG051.forecast(sleeps: ALG051.sleepSpans(metricsByDay: byDay, events: events),
                               doses: BehaviourEvents.caffeineDoses(from: events), now: now,
                               until: bedtime > now ? bedtime : nil, timeZone: calendar.timeZone)
    }

    /// Moments Mo dismissed ("Later") stay hidden for 3 h (UX §4.2); unseen alerts always show.
    func visibleMoments(_ moments: [Moment], now: Date) -> [Moment] {
        moments.filter { m in
            guard m.kind != .alert, let at = sessions.dismissedMoments[m.kind.rawValue] else { return true }
            return now.timeIntervalSince(at) > 3 * 3600
        }
    }

    func presenterUI() -> PresenterUI {
        PresenterUI(openRows: openRows, expandedGroups: expandedGroups, showDroppedGroups: showDroppedGroups,
                    checkinStep: ledger.checkinDone ? 1 : max(1, min(2, ledger.checkinStep)),
                    napPeekStep: napPeekStep, workoutPeekStep: workoutPeekStep, settling: settling)
    }

    // MARK: Presenting

    /// R7 / T23: the presenters are pure functions of the snapshot, so they run off the main actor; only the choice of
    /// which optional screens are open (read here) and the assignment of the results (`applyScreens`) run on it.
    /// `light` = the first pass at launch: Today only (the other tabs are built by the full pass that follows).
    /// Returns the seconds the main actor was busy with it (for the stall watch's "slowest full rebuild").
    @discardableResult
    func present(_ s: PresenterSnapshot, light: Bool = false) async -> TimeInterval {
        let planBegan = ProcessInfo.processInfo.systemUptime
        // R8e (§0.C-2): hidden screens are built when open, or once (the first full pass) so a tab never opens empty.
        let open = openGatedScreens()
        let everything = !gatedBuiltOnce
        var plan = ScreenPlan(detail: detailKey != nil, group: groupId != nil, compare: compareFirst != nil,
                              workout: workoutRequested, modelStatus: modelStatusOnScreen, ages: agesOnScreen,
                              nightDay: nightOverride?.day, nightMetrics: nightOverride?.metrics ?? [],
                              nightSeries: nightOverride?.series ?? [], light: light)
        plan.log = everything || open.contains("log")
        plan.explore = everything || open.contains("explore")
        plan.matrix = everything || open.contains("matrix")
        plan.settings = everything || open.contains("settings")
        plan.strapSync = everything || open.contains("strapSync") || settingsOnScreen      // Settings draws it as its Device section
        var busy = ProcessInfo.processInfo.systemUptime - planBegan
        let finalPlan = plan
        let built = await Task.detached(priority: .userInitiated) { ScreenBuilder.build(s, plan: finalPlan) }.value
        let applyBegan = ProcessInfo.processInfo.systemUptime
        applyScreens(built, light: light)
        // The Live part is rebuilt from the newest snapshot: a once-a-second tick may have moved it while this ran.
        presentLive(lastSnapshot ?? s)
        busy += ProcessInfo.processInfo.systemUptime - applyBegan
        return busy
    }

    private func applyScreens(_ b: PresentedScreens, light: Bool) {
        setIfChanged(\.today, b.today)
        if b.today.theme != theme {
            theme = b.today.theme
            Task { [weak self] in await self?.publishWidgetSnapshot() }   // widgets follow the theme (WP-27)
        }
        setIfChanged(\.quietHaptics, b.quiet)
        if let r = b.rest {
            setIfChanged(\.tonight, r.tonight)
            setIfChanged(\.night, r.night)
            if let v = r.log { setIfChanged(\.log, v); gatedBuiltGen["log"] = snapshotGen }
            // Explore, Matrix and Settings read extra inputs only while open (workout history, profile records): a build while
            // closed is a placeholder, so it is not marked fresh and the full pass runs when the screen opens.
            if let v = r.explore {
                setIfChanged(\.explore, v)
                if tab == .explore || matrixOnScreen { gatedBuiltGen["explore"] = snapshotGen }
            }
            setIfChanged(\.metricDetail, r.metricDetail)
            setIfChanged(\.group, r.group)
            setIfChanged(\.compare, r.compare)
            if let v = r.matrix { setIfChanged(\.matrix, v); if matrixOnScreen { gatedBuiltGen["matrix"] = snapshotGen } }
            if let v = r.settings { setIfChanged(\.settingsState, v); if settingsOnScreen { gatedBuiltGen["settings"] = snapshotGen } }
            if let v = r.strapSync { setIfChanged(\.strapSync, v); gatedBuiltGen["strapSync"] = snapshotGen }
            gatedBuiltOnce = true
            setIfChanged(\.workoutDetail, r.workoutDetail)
            setIfChanged(\.modelStatus, r.modelStatus)
            setIfChanged(\.ages, r.ages)
            if frontPageOnScreen { frontPagePublish() }
        }
    }

    func presentLive(_ s: PresenterSnapshot) {
        setIfChanged(\.live, LivePresenter.make(s))
        setIfChanged(\.breathe, breatheSession == nil ? nil : BreathePresenter.make(s))
        setIfChanged(\.hrvCheck, hrvSession == nil ? nil : HRVCheckPresenter.make(s))
    }

    /// Publishes only real changes (SwiftUI redraws on every assignment).
    func setIfChanged<T: Equatable>(_ path: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    // MARK: Live and guided inputs

    var beatsFlowing: Bool {
        guard let last = liveBuffer.lastBeatAt else { return false }
        return clock.now.timeIntervalSince(last) < LiveBeatBuffer.staleAfter
    }

    func liveInput() -> LiveInput? {
        guard !isSample else { return nil }
        let w = sessions.workout.map { liveBuffer.workoutInput($0, profile: effectiveProfile, now: clock.now, calendar: calendar) }
        var li = liveBuffer.liveInput(now: clock.now, workout: w)
        li?.hrSource = liveBeatSource
        let latestWindow = li?.hrv?.latest                                                        // copied first: exclusive access to li
        li?.autonomicLoad = liveAutonomicLoad(workout: w != nil, window: latestWindow)          // W10 #94; 0.6.0.12: same window rules as the RMSSD tile
        // wave 4: live raw optical (108 on) for the Live tab's waveforms, while frames are fresh
        // T145/T148 fix: build the input even when no heartbeat arrived for 15 s (liveInput() is nil then), or the wave is lost.
        if let at = rawOpticalStatus.lastFrameAt, clock.now.timeIntervalSince(at) < 5 {
            if li == nil { li = LiveInput() }
            li?.opticalRecent = rawOpticalStatus.recent
            if StrapDeviceChoice.stored == .whoop4 { li?.opticalWhoop4 = services.whoop4.recentOptical }   // WHOOP4-WIRE 6
            // Bug 3 (2026-10-14): the pulse wave was hard-wired empty (LiveSignals). R26 never arrives live, so the wave
            // is the live raw optical block the presenter already chose (first lit, non-ambient), with its sample rate and
            // the pulse rate found in it, or the real reason none was (saturated / run too short / no pulse).
            // T10005 (phone heat): the pulse rate is an autocorrelation over 8 s of samples; it changes only when a new record
            // arrives (once a second), not at every 0.5-s Live rebuild, so it is worked out once per record.
            let p = livePulseOnce(rawOpticalStatus.recentRecords)
            if let block = p.block, !p.wave.isEmpty {
                li?.pulseWave = p.wave
                li?.pulseHz = p.rateHz
                li?.pulseSource = "R20 raw optical block \(block)"
                li?.pulseQuality = "raw counts, block \(block)"
            }
            li?.pulseRateBpm = p.hrBpm
            li?.pulseNote = p.hrBpm == nil ? p.reason : nil
            // P9729: the ALG-144 cleaned wave beside it (a background run at most once per new strap second)
            li?.cleanPulse = liveCleanPulse(records: rawOpticalStatus.recentRecords)
        }
        return li
    }

    /// T10005: `OpticalPulse.live` for the newest record, reused until a newer record arrives.
    func livePulseOnce(_ records: [R20Record]) -> OpticalPulse.Live {
        let key = LivePulseMemoKey(newestTs: records.last?.ts, count: records.count)
        if let memo = livePulseMemo, memo.key == key { return memo.value }
        let value = OpticalPulse.live(records: records)
        livePulseMemo = (key, value)
        return value
    }

    func breatheInput() -> BreatheInput? {
        guard let b = breatheSession else { return nil }
        var collected: Int?
        if b.phase == .running, let start = b.startedAt, beatsFlowing {
            collected = liveBuffer.rrSince(start).count
        }
        let note: String? = (b.phase == .running && !beatsFlowing)
            ? (isSample ? "Sample data is on — the pacer runs, no coherence."
                        : "Strap not connected — the pacer runs, no coherence.")
            : nil
        return BreatheInput(phase: b.phase, breathsPerMinute: b.perMinute, minutes: b.minutes, startedAt: b.startedAt,
                            endsAt: b.endsAt, beatsCollected: collected, strapNote: note, result: b.result)
    }

    func hrvCheckInput() -> HRVCheckInput? {
        guard let h = hrvSession else { return nil }
        var beats: Int?
        var flagged: Int?
        var seconds = 0.0
        var passing: Bool?
        if h.phase == .measuring, let start = h.startedAt {
            let g = GuidedMath.gate(rr: liveBuffer.rrSince(start).map(\.rrMs))
            beats = g.beats
            flagged = g.flagged
            seconds = g.seconds
            passing = g.passing
        }
        return HRVCheckInput(phase: h.phase, minutes: h.minutes, startedAt: h.startedAt, endsAt: h.endsAt, beats: beats,
                             flagged: flagged, secondsOfBeats: seconds, gatePassing: passing,
                             blockedReason: h.blockedReason, result: h.result, nightMedianRmssd: nightMedianRmssd)
    }

    // MARK: Explore (ALG-075, ALG-079)

    func exploreInput(src: any SnapshotReading, today: LocalDay,
                      choices: [String: GroupChoice]) async throws -> ExploreInput {
        let period = settings.period
        let periodEnd = PCHistoryPlan.periodEnd(period, today: today)      // T9822: a custom range may end before today
        // Matrix and Compare read the phone's rows only: a period longer than what the phone holds covers its span.
        let phoneOldest = try await src.oldestDay(name: nil)
        let n = PCHistoryPlan.shownDays(period: period, today: today, phoneOldest: phoneOldest,
                                        pcShown: phoneOldest.map { $0 <= PCHistoryPlan.periodStart(period, today: today) }
                                            ?? false, earliest: phoneOldest)
        func rows(_ key: String, days: Int) async throws -> [(day: LocalDay, metric: Metric)] {
            try await src.metricDays(name: key, from: periodEnd.adding(days: -(days - 1)), to: periodEnd)
        }
        // Tracker #7: the PC's answers live only while an Explore screen is open.
        if !exploreOnScreen { pcHistoryCenter.clear() }
        var shelf: [MetricAnalysis] = []
        for key in settings.pinnedMetrics {     // the shelf never asks the PC (one request per pinned metric is too many)
            shelf.append(try await exploreAnalysis(src: src, key: key, variant: nil, today: today, period: period,
                                                   choices: choices, askPC: false))
        }
        // T96: Today's picked metrics — the last 30 days each, phone rows only like the shelf.
        var todayPicks: [MetricAnalysis] = []
        for pick in settings.frontPage.picks {
            todayPicks.append(try await exploreAnalysis(src: src, key: pick.key, variant: nil, today: today,
                                                        period: .days30, choices: choices, askPC: false))
        }
        // Sleep expanded (Mo, Nov 5 2026): 90 nights of the sleep card's keys for its baselines and 7 / 30 / 90 trends.
        var sleepTrends: [MetricAnalysis] = []
        for key in SleepBreakdownPresenter.trendKeys {
            sleepTrends.append(try await exploreAnalysis(src: src, key: key.rawValue, variant: nil, today: today,
                                                         period: .days90, choices: choices, askPC: false))
        }
        var detail: MetricAnalysis?
        if let key = detailKey {
            detail = try await exploreAnalysis(src: src, key: key, variant: detailVariant, today: today,
                                               period: period, choices: choices, askPC: true)
        }

        let periodDays = SnapshotMath.days(endingAt: periodEnd, count: n)
        func column(_ key: String) async throws -> DailyColumn {
            SnapshotMath.column(try await rows(key, days: n), days: periodDays, variant: nil, choices: choices)
        }
        let keys = Array(settings.matrixKeys.prefix(MatrixState.maxMetrics))
        var cells: [[CorrelationInput]] = []
        if !keys.isEmpty, matrixOnScreen {
            let cacheKey = "\(keys.joined(separator: ","))|\(n)|\(periodEnd.iso)|\(src.isSample)"
            if let cached = matrixCache, cached.key == cacheKey {
                cells = cached.cells
            } else {
                if src.isSample {
                    var cols: [String: [Double?]] = [:]
                    for k in keys { cols[k] = try await column(k).values }
                    cells = SnapshotMath.matrix(keys: keys, columns: cols)
                } else {
                    // WP-22 MatrixPipeline: the PC's column rule (first stored row per day) and one BH family.
                    let m = try await MatrixPipeline.run(source: services.store,
                                                         keys: keys.map { MatrixKey(name: $0, variant: nil, window: nil) },
                                                         end: periodEnd, days: n)
                    cells = SnapshotMath.correlationInputs(m)
                }
                matrixCache = (cacheKey, cells)
            }
        }
        var compare: CompareInput?
        if let first = compareFirst {
            let x = try await column(first)
            let y = try await compareSecond.asyncMap { try await column($0) }
            compare = SnapshotMath.compare(first: first, second: compareSecond, lag: compareLag, x: x, y: y)
        }
        var input = ExploreInput(period: period, query: exploreQuery, viewMode: metricView, shelf: shelf,
                                 detail: detail, markers: [], groupId: groupId, agreement: [:], matrixKeys: keys,
                                 matrixCells: cells, compare: compare)
        input.todayPicks = todayPicks
        input.sleepTrends = sleepTrends
        return input
    }

    /// The Matrix screen is in a stack (WP-22: run MatrixPipeline when it opens or its choices / period change).
    var matrixOnScreen: Bool {
        paths.values.contains { $0.contains(.matrix) }
    }

    // MARK: Workout detail (WP-29)

    func workoutDetailInput(src: any SnapshotReading, now: Date, dayMetrics: [Metric]) async throws -> WorkoutDetailInput? {
        // T116: a running workout always loads, so the Live summary card has its numbers.
        guard workoutRequested || sessions.workout != nil else { return nil }
        let rhr = dayMetrics.first { $0.name == MetricKey.rhr.rawValue && $0.value != nil }?.value
        if let w = sessions.workout, workoutId == nil || workoutId == w.id {
            let event = EventFactory.manualWorkout(w, end: now)
            let hr = try await src.hrSamples(from: w.start, to: now)
            return SnapshotMath.workoutDetail(event: event, isLive: true, hr: hr, profile: effectiveProfile, rhr: rhr,
                                              dayMetrics: dayMetrics, setsDone: w.setsDone, lastSetAt: w.lastSetAt,
                                              now: now, calendar: calendar)
        }
        guard let event = try await src.workout(id: workoutId, now: now), case .workout(let f) = event.payload else {
            return nil
        }
        let hr = try await src.hrSamples(from: event.at, to: f.end)
        let wday = LocalDay(date: event.at, calendar: calendar)
        let metrics = try await src.summary(for: wday)?.metrics.filter { !ImportedHistory.isImported($0) } ?? dayMetrics
        let starts = await sleepStarts(src: src, from: wday)
        return SnapshotMath.workoutDetail(event: event, isLive: false, hr: hr, profile: effectiveProfile, rhr: rhr,
                                          dayMetrics: metrics, setsDone: 0, lastSetAt: nil, now: now,
                                          calendar: calendar, sleepStarts: starts)
    }

    /// Sleep starts (the `sleep_onset` rows our own night analysis wrote; the strap's asleep flag decides them) on the
    /// workout's day and the next. Feeds the "went to sleep N min after" note on HR recovery (D-RECOV-WALK-2).
    func sleepStarts(src: any SnapshotReading, from day: LocalDay) async -> [Double] {
        let rows = (try? await src.metricDays(name: MetricKey.sleepOnset.rawValue, from: day, to: day.adding(days: 1))) ?? []
        return rows.filter { !ImportedHistory.isImported($0.metric) }.compactMap { $0.metric.value }.filter { $0.isFinite }
    }

    /// T116: the recent finished workouts of this month for Explore › Workouts, same numbers as the detail page.
    func workoutHistoryInputs(src: any SnapshotReading, events: [EventRecord], now: Date,
                              dayMetrics: [Metric]) async throws -> [WorkoutDetailInput] {
        let rhr = dayMetrics.first { $0.name == MetricKey.rhr.rawValue && $0.value != nil }?.value
        var out: [WorkoutDetailInput] = []
        for event in events.filter({ $0.type == .workout && !$0.removed }).sorted(by: { $0.at > $1.at })
            .prefix(WorkoutSummaryPresenter.baselineLimit) {
            guard case .workout(let f) = event.payload else { continue }
            let hr = try await src.hrSamples(from: event.at, to: f.end)
            let day = LocalDay(date: event.at, calendar: calendar)
            let metrics = try await src.summary(for: day)?.metrics.filter { !ImportedHistory.isImported($0) } ?? dayMetrics
            let starts = await sleepStarts(src: src, from: day)
            if let d = SnapshotMath.workoutDetail(event: event, isLive: false, hr: hr, profile: effectiveProfile, rhr: rhr,
                                                  dayMetrics: metrics, setsDone: 0, lastSetAt: nil, now: now,
                                                  calendar: calendar, sleepStarts: starts) { out.append(d) }
        }
        return out
    }

    // MARK: Strap & sync sheet

    func strapSyncInfo(src: any SnapshotReading, now: Date) async throws -> StrapSyncInfo {
        let all = try await src.strapWrites(limit: 50)
        let writes = all.filter { calendar.isDate($0.confirmedAt, inSameDayAs: now) }.map { StrapWriteWords.short($0) }
        // 120 SET_FF_VALUE is only ever the enable_r22_packets write (MGBLE SanctionedCommand.setR22Packets).
        let r22 = all.filter { $0.command == 120 && $0.readback != nil }.max { $0.confirmedAt < $1.confirmedAt }
            .map { StrapFlagWrite(readback: $0.readback!, at: $0.confirmedAt) }
        let cleanup: PhoneRetentionReport? = isSample ? nil : try? await services.store.lastPhoneRetention()
        var info = StrapSyncInfo(bonded: isSample ? true : strapInfo?.bonded, firmware: strapInfo?.firmware,
                             lastAckAt: try await src.lastAck(), writesToday: writes,
                             unsyncedBytes: try await src.pendingOutboxBytes(),
                             healthAvailable: healthState?.isUsable ?? false,
                             healthGranted: healthState == .requested ? ["read access asked (iOS doesn't say which)"] : [],
                             healthLastRead: healthLastRead, flagSnapshot: flagSnapshot,
                             rawOpticalWanted: settings.rawOpticalOn, rawOpticalOn: rawOpticalStatus.on,
                             rawOpticalFrames: rawOpticalStatus.frames,
                             rawOpticalLastFrameAt: rawOpticalStatus.lastFrameAt,
                             rawOpticalStopped: rawOpticalStatus.stoppedReason, r22Watch: settings.r22Watch,
                             lastCleanup: cleanup, r22LastWrite: r22)
        info.rawOpticalInWorkout = settings.rawOpticalInWorkout                 // T124
        info.rawOpticalEvery = settings.spo2Every
        info.rawOpticalWhenStill = settings.rawOpticalWhenStill
        info.rawOpticalNightsOnly = settings.rawOpticalNightsOnly          // wave 4 (#65)
        info.rawOpticalSchedule = settings.spo2Schedule
        info.rawOpticalDecision = rawOpticalDecision
        info.rawOpticalCost = rawOpticalCost
        info.ecgMotion = ecgMotionInfo()   // wave W8
        info.historyReadTest = historyReadTestLines            // wave W12b
        info.historyReadTestRunning = historyReadTestRunning
        info.handBackOn = settings.handBackToWhoop                      // wave W12b (#103)
        applyRingInfo(&info)                                            // 0.6.0.3 Ring live
        info.hrBroadcastOn = settings.hrBroadcastOn                     // T77
        info.hrRead = hrReadInfo()                                      // 0.6.0.12
        info.autoRaw = autoRawInfo()                                    // r9q
        info.hrBroadcastReading = StrapDeviceChoice.stored == .whoop4 ? services.whoop4.status.hrBroadcast   // WHOOP4-WIRE 4
                                                                       : services.strap.link?.hrBroadcastReading
        if !isSample {                                                  // P9734: phone-to-PC sync panel
            let p = await services.sync.panel()
            info.pcSync = PCSyncPanelInfo(
                state: p.state, lastSuccess: p.lastSuccess, lastAcceptedAt: p.lastAcceptedAt, queueDrops: p.queueDrops,
                queueBytes: p.queueBytes, bytesDelivered: p.bytesDelivered, lastError: p.lastError,
                lastErrorAt: p.lastErrorAt, nextRetryAt: p.nextRetryAt, consecutiveFailures: p.consecutiveFailures,
                authFailures: p.authFailures, authFailuresToRepair: p.authFailuresToRepair, needsRepair: p.needsRepair,
                banner: p.banner, lastStop: p.lastStop, lastStopAt: p.lastStopAt)
        }
        info.handBackLines = settings.handBackLines
        if !isSample, let auto = services.healthAuto {                  // Nov 6 2026: the card says how many batches wait
            info.healthQueuedBatches = await auto.status().queuedBatches
        }
        return info
    }

    // MARK: Smart wake (WP-11)

    func smartWakeSlots(context: DayContext, metrics: [Metric], now: Date,
                        ringer: SmartWakeBlockState.Ringer) -> (block: SmartWakeBlockState, result: SmartWakeSummaryInput?) {
        let bed = context.anchors.bedtime
        let latest = ContextMath.latestWakeInstant(settings.latestWake, after: bed, calendar: calendar)
        let need = metrics.first { $0.name == MetricKey.sleepNeed.rawValue && $0.value != nil }?.value
        var plan: Computed<SmartWakePlan>
        if isSample {
            plan = .missing("Sample data is on, so no alarm is set")
        } else {
            switch smartWake?.status {
            case .armed(let p, _)?, .watching(let p)?:
                plan = .success(p)
            case .off(let reason)?:
                plan = .missing(reason)
            default:
                plan = ALG035.plan(enabled: settings.smartWakeOn, mustBeUpBy: latest.map(AppModel.unix),
                                   windowMinutes: settings.wakeWindowMinutes, armedAt: AppModel.unix(now),
                                   bedtime: AppModel.unix(bed), asleepAround: nil, needMinutes: need,
                                   options: smartWakeOptions(forWakeAt: latest))
                if case .success = plan, smartWake == nil {
                    plan = .missing("Pair your strap first: smart wake watches it overnight")
                }
            }
        }
        let block = SmartWakeBlockFactory.make(isOn: settings.smartWakeOn, windowMinutes: settings.wakeWindowMinutes,
                                               plan: plan, ringer: ringer, motionLive: false, calendar: calendar)
        var result: SmartWakeSummaryInput?
        if !isSample, let r = smartWake?.lastResult, now.timeIntervalSince(r.recordedAt) < 18 * 3600 {
            let w = r.words(timeZone: calendar.timeZone)
            let at = Date(timeIntervalSince1970: TimeInterval(r.outcome.at ?? r.plan.windowEnd))
            if let title = w.title {
                let detail = [w.detail, w.note, w.battery].compactMap { $0 }.joined(separator: " · ")
                result = SmartWakeSummaryInput(title: title, detail: detail.isEmpty ? nil : detail,
                                               receiptMethod: r.method, at: at)
            }
        }
        return (block, result)
    }

    static func unix(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970.rounded(.down)) }
}

/// The last `minuteHR` read and the minute it is for.
@MainActor
private enum MinuteHRCache {
    static var entry: (key: String, points: [HRPoint])?
}

/// The last `dialSeriesSources` read and the minute it is for.
@MainActor
private enum DialSeriesCache {
    static var entry: (key: String, series: [Series])?
}

/// How the strap sheet names today's writes ("clock set ×1 today").
enum StrapWriteWords {
    static func short(_ e: StrapWriteEntry) -> String {
        switch e.command {
        case 146, 10: return e.restored == true ? "clock restored" : "clock set"
        case 120: return e.restored == true ? "R22 flag restored" : "R22 flag"
        default: return e.name.isEmpty ? "write \(e.command)" : e.name.lowercased().replacingOccurrences(of: "_", with: " ")
        }
    }
}

extension Optional {
    /// `map` with an async throwing transform.
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

// MARK: Live autonomic load (W10, tracker #94)

extension AppModel {
    /// ALG-054 on the last 5 min of live beats against the same hour's baseline; the baseline (the 30 days before
    /// today's 5-min HR / lnRMSSD series) is read once a day in the background, the tile says so meanwhile.
    func liveAutonomicLoad(workout: Bool, window: LiveHRVWindow?) -> Metric {
        let now = clock.now
        var spec = ALG054.spec
        spec.window = "live_5min"
        let today = LocalDay(date: now, calendar: calendar)
        guard let b = autonomicBaseline, b.day == today else {
            loadAutonomicBaseline(today)
            return spec.blank("reading your hour-by-hour baseline from the stored days…", at: now)
        }
        if workout { return spec.blank("exercise response, not stress (a workout is running)", at: now) }
        // 0.6.0.12 (Mo Nov 5): the load needs the same judged 5-minute window as the RMSSD tile (>= 20 clean successive intervals,
        // >= 80 % covered, no pair across a gap): it used to take any 3 beats. Otherwise the tile is grey and says why.
        guard let w = window, w.ideal, let rmssd = w.rmssd, rmssd > 0, let meanRR = w.meanRR, meanRR > 0 else {
            return spec.blank("no clean 5-minute window yet: " + (window?.why?.text ?? "no beats"), at: now)
        }
        // D-POP-PRIOR (R9m): with no stored days the baseline is the population value, so the tile is not blank (the note says so).
        let sample = ALG054.Sample(hour: calendar.component(.hour, from: now), hr: 60_000.0 / meanRR, lnRmssd: Foundation.log(rmssd))
        let load = ALG054.load(sample, baseline: b.baseline)
        return spec.metric(load.map(\.load), at: now, note: "baseline: \(ALG054.basisLabel(days: b.baseline.days) ?? "yours")")
    }

    func loadAutonomicBaseline(_ today: LocalDay) {
        guard !autonomicBaselineLoading, !isSample else { return }
        autonomicBaselineLoading = true
        let store = services.store
        let tz = calendar.timeZone
        Task { [weak self] in
            var series: [LocalDay: [Series]] = [:]
            let days = (1...PipelineConstants.stressDailyDays).map { today.adding(days: -$0) }
            for d in days {
                if let s = try? await store.series(on: d), !s.isEmpty { series[d] = s }
            }
            let clock = PipelineClock(timeZone: tz)
            let samples = ALG054.history(series: series, days: days, hourOf: { clock.hourOfDay($0) })
            await MainActor.run {
                self?.autonomicBaseline = (today, ALG054.baseline(history: samples, days: ALG054.historyDays(series: series, days: days)),
                                           samples.count)
                self?.autonomicBaselineLoading = false
            }
        }
    }
}

/// T10005: what identifies "the same newest raw-optical records" for `livePulseOnce`.
struct LivePulseMemoKey: Equatable {
    var newestTs: Int64?
    var count: Int
}
