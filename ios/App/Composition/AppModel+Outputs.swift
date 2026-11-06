import Foundation
import MGContext
import MGDomain
import MGSignal
import MGStore
import MGSync

// Wave 2 (2026-10-11) — everything already computed made visible and wired: the newest value of every metric from every
// source (own, PC, imported history), every PC model's newest result, today's non-metric pipeline outputs, GroupPipeline
// for the open group, health alerts raised and notified, medication / caffeine-limit / wind-down reminders sent, and the
// "Working on…" state. Statistics come from MGSignal; MGContext's presenters only word them.

// MARK: - Reads (SnapshotReading)

extension StoreDayDataSource {
    func latestMetrics(from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        try await store.latestMetrics(from: from, to: to)
    }

    /// The newest week of results per model is enough for "newest value" and "newest status".
    func labResults(from: LocalDay, excluding: [String]) async throws -> ([LabResult], [String]) {
        try await store.labResults(from: from, excluding: excluding, newestPerModel: 7)
    }
}

extension SampleDayDataSource {
    /// SAMPLE: the sample days' own rows, newest per (name, variant, computed_on) — labelled SAMPLE like the rest.
    func latestMetrics(from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        var seen = Set<String>()
        var out: [(day: LocalDay, metric: Metric)] = []
        var d = to
        while d >= from, from.days(to: d) >= 0, d.days(to: to) < 14 {
            for m in try await summary(for: d)?.metrics ?? [] {
                let k = "\(m.name)|\(m.variant ?? "")|\(m.computedOn.rawValue)"
                if seen.insert(k).inserted { out.append((d, m)) }
            }
            d = d.adding(days: -1)
        }
        return out
    }

    func labResults(from: LocalDay, excluding: [String]) async throws -> ([LabResult], [String]) { ([], []) }
}

// MARK: - Today's non-metric outputs (from the compute run)

enum DayExtrasBuilder {
    /// `r` = today's DayPipeline result. Habits (HabitPipeline, 60 days) and social jetlag (ALG-116, 28 nights) are read
    /// from the store here, once per compute run.
    static func make(_ r: DayResult, ticks: Double?, store: MGStore, settings: ComputeSettings,
                     pipeline ps: PipelineSettings, now: Date) async -> DayExtrasInput {
        var x = DayExtrasInput(at: now)
        let mv = r.movement
        if mv.knownMin > 0 {
            x.movement = .init(stillMin: mv.stillMin, activeMin: mv.activeMin, walkMin: mv.walkMin, runMin: mv.runMin,
                               knownMin: mv.knownMin)
        }
        switch r.medicationCurve {
        case .success(let samples) where !samples.isEmpty:
            let peak = samples.max { $0.level < $1.level }
            let top = peak?.level ?? 0
            let level = samples.last { $0.at <= now }.map { top > 0 ? $0.level / top : 0 }
            x.medication = .init(name: "Medication", levelNow: level, peakAt: peak?.at,
                                 curve: samples.map { TimedValue(at: $0.at, value: $0.level) })
        case .success:
            x.medicationReason = "No curve samples today."
        case .failure(let m):
            x.medicationReason = m.reason
        }
        switch r.nicotineResponse {
        case .success(let resp) where resp.summary.sessions > 0:
            x.nicotine = .init(sessions: resp.summary.sessions, hrDeltaBpm: resp.summary.meanDHr,
                               rmssdDeltaMs: resp.summary.meanDRmssd)
        case .success:
            x.nicotineReason = "No vape session with heart data around it today."
        case .failure(let m):
            x.nicotineReason = m.reason
        }
        x.adherence = r.adherence.sorted { $0.key < $1.key }.map { name, a in
            switch a {
            case .success(let v): return .init(name: name, taken: v.taken, due: v.scheduled)
            case .failure(let m): return .init(name: name, taken: 0, due: 0, reason: m.reason)
            }
        }
        x.stepTicks = ticks
        let clock = PipelineClock(timeZone: settings.timeZone)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = settings.timeZone
        let today = LocalDay(date: now, calendar: cal)
        do {
            let h = try await Baselines.load(source: store, before: today.adding(days: 1), days: 61, clock: clock)
            x.habits = HabitPipeline.effects(history: h, end: today).map { e in
                HabitEffectInput(habit: e.habit, outcome: e.outcome, cohensD: e.group.cohensD.value?.d,
                                 nWith: e.group.cohensD.value?.nWith ?? 0, nWithout: e.group.cohensD.value?.nWithout ?? 0,
                                 reason: e.group.cohensD.missingReason)
            }
            var nights: [ALG116.Night] = []
            for k in 0..<28 {
                let d = today.adding(days: -k)
                if let on = h.value("sleep_onset", variant: "ALG-030", window: "night", on: d),
                   let wk = h.value("wake_time", variant: "ALG-030", window: "night", on: d), wk > on {
                    nights.append(ALG116.Night(onset: on, wake: wk, free: clock.mustBeUp(ps, on: d) == nil))
                }
            }
            switch ALG116.chronotype(nights: nights, utcOffsetSeconds: clock.offsetSeconds(at: now.timeIntervalSince1970)) {
            case .success(let c):
                x.socialJetlagHours = c.socialJetlagHours.value
                x.socialJetlagReason = c.socialJetlagHours.missingReason
            case .failure(let m):
                x.socialJetlagReason = nights.isEmpty ? "Waiting for first night" : m.reason
            }
        } catch {
            x.socialJetlagReason = "Couldn't read the stored nights: \(error)"
        }
        return x
    }
}

// MARK: - AppModel

extension AppModel {
    /// "Every measure", a metric's sources and "Computed on PC": newest row of every (name, variant, computed_on) over
    /// 400 days (imports included) + the newest week of every PC model's results. Read at most every 5 min, again when
    /// a compute ran or new PC results arrived, and every 30 s while a metric or group screen is open.
    func outputsInput(src: any SnapshotReading, today: LocalDay, now: Date,
                      period: ExplorePeriod = .days30)
        async throws -> (latest: [String: [DatedMetric]], pc: [LabResult], unreadable: [String]) {
        // T9822: a custom range ending before today reads its own newest rows (through its last day), not today's.
        let through = PCHistoryPlan.periodEnd(period, today: today)
        let readFrom = min(through.adding(days: -400), PCHistoryPlan.periodStart(period, today: today))
        let cursor = src.isSample ? 0 : await services.store.resultsCursor
        let key = "\(src.isSample)|\(today.iso)|\(through.iso)|\(readFrom.iso)|\(cursor)|\(lastComputeAt?.timeIntervalSince1970 ?? 0)"
        let fresh = (detailKey != nil || groupId != nil) ? 30.0 : 300.0
        if let c = outputsCache, c.key == key, now.timeIntervalSince(c.at) < fresh {
            return (c.latest, c.pc, c.unreadable)
        }
        var latest: [String: [DatedMetric]] = [:]
        for row in try await src.latestMetrics(from: period.isCustom ? readFrom : today.adding(days: -400),
                                               to: period.isCustom ? through : today) {
            latest[row.metric.name, default: []].append(DatedMetric(day: row.day, metric: row.metric))
        }
        let (pc, unreadable) = try await src.labResults(from: today.adding(days: -60), excluding: ImportedHistory.modelIds)
        // PC lab metrics are not rows in `metric`: add the newest per (name, variant), a value beating a blank.
        var pcBest: [String: DatedMetric] = [:]
        for r in pc {                                         // newest seq first
            for m in r.metrics where m.computedOn == .pc && !ImportedHistory.isImported(m) {
                let k = "\(m.name)|\(m.variant ?? "")"
                if let held = pcBest[k], held.metric.value != nil || m.value == nil { continue }
                pcBest[k] = DatedMetric(day: r.date, metric: m)
            }
        }
        for (_, dm) in pcBest.sorted(by: { $0.key < $1.key }) { latest[dm.metric.name, default: []].append(dm) }
        outputsCache = (key, now, latest, pc, unreadable)
        return (latest, pc, unreadable)
    }

    /// GroupPipeline (WP-22) for the open group: its members in rank order with Mo's marks, for each metric name.
    func groupMeasuresInput(metrics: [Metric], marks: [GroupMarkEntry]) -> [GroupMeasureInput] {
        guard let gid = groupId else { return [] }
        let mm = marks.compactMap { m -> MemberMark? in
            guard let v = MemberMark.Value(rawValue: m.mark.rawValue) else { return nil }
            return MemberMark(groupId: m.groupId, variant: m.variant, mark: v, at: m.at)
        }
        return GroupPipeline.views(metrics: metrics, marks: mm).filter { $0.groupId == gid }.map { v in
            GroupMeasureInput(groupId: v.groupId, metric: v.metric,
                              members: v.members.map { .init(variant: $0.variant, rank: $0.rank, hidden: $0.hidden,
                                                             metric: $0.metric) },
                              primaryVariant: v.primaryVariant)
        }
    }

    /// Alerts from the wake day's own metrics and last night's events (MGContext AlertRules); seen = dismissed after
    /// it was raised.
    func alertsNow(metrics: [Metric], events: [EventRecord], day: LocalDay) -> [AlertInfo] {
        guard !isSample else { return [] }
        return AlertRules.alerts(metrics: metrics, events: events, day: day, calendar: calendar,
                                 dismissedAt: sessions.dismissedMoments[MomentKind.alert.rawValue])
    }

    /// Fills the wave-2 slots of a snapshot and re-evaluates the context when the alerts changed.
    func fillOutputs(_ s: inout PresenterSnapshot, src: any SnapshotReading, today: LocalDay, now: Date,
                     marks: [GroupMarkEntry]) async throws {
        let o = try await outputsInput(src: src, today: today, now: now, period: settings.period)
        s.explore.latest = o.latest
        // Tracker #7: a period reaching before the phone's window adds the PC's older part (memory only).
        if tab == .explore || detailKey != nil {
            s.explore.measuresPC = try await measuresPC(src: src, today: today, period: settings.period,
                                                        latest: &s.explore.latest)
        }
        if let gid = groupId {
            s.explore.groupPC = try await groupPCInput(src: src, gid: gid, today: today, period: settings.period)
        }
        s.pcResults = o.pc
        s.primary = isSample ? [:] : await services.sync.primaryMap()      // T9809: the PC's primary-source map
        s.spo2SpotUntil = spo2SpotUntil              // wave 4 (#77)
        s.pcResultsUnreadable = o.unreadable
        s.dayExtras = isSample ? nil : lastDayExtras
        s.groupMeasures = groupMeasuresInput(metrics: s.metrics, marks: marks)
        noteHealthBridgeWork()
        s.working = working
        s.explore.agreement = Self.agreementSentences(o.pc, calendar: calendar)
        if detailKey != nil {
            let days = min(SnapshotMath.periodDays(settings.period, today: today, earliest: today.adding(days: -3650)),
                           3650)
            let from = PCHistoryPlan.periodEnd(settings.period, today: today).adding(days: -(days - 1))
                .start(in: calendar.timeZone)
            // T9822: a custom range that ended before today reads events only through the end of its last day.
            let end = PCHistoryPlan.periodEnd(settings.period, today: today)
            let to = end < today ? end.adding(days: 1).start(in: calendar.timeZone) : now.addingTimeInterval(1)
            s.explore.markers = Self.wearMarkers(try await src.events(from: from, to: to),
                                                 calendar: calendar)
            // W10 #99 (ALG-042): the detail's days by where the strap was worn; the place before the period counts
            if let points = s.explore.detail?.points, !points.isEmpty {
                let wear = try await src.events(from: from.addingTimeInterval(-90 * 86_400), to: to)
                    .filter { $0.type == .wear }
                let places = WearCompare.dayLocations(events: wear, days: points.map(\.day), calendar: calendar)
                s.explore.wearCompare = WearCompare.split(points: points, locations: places)
            }
        }
        let alerts = alertsNow(metrics: s.metrics, events: s.events, day: s.day)
        currentAlerts = alerts
        if alerts != s.inputs.alerts {
            s.inputs.alerts = alerts
            var ctx = ContextEngine.evaluate(s.inputs)
            ctx.moments = visibleMoments(ctx.moments, now: now)
            s.context = ctx
        }
    }

    /// ALG-079 from the PC (pc.group-agreement over the last 90 days, pc.whoop-agreement over the backlog): one sentence
    /// per compared group, newest result of each model. The metric's `group` is the group compared (registry note).
    static func agreementSentences(_ pc: [LabResult], calendar: Calendar) -> [String: String] {
        var newest: [String: LabResult] = [:]
        for r in pc where ["pc.group-agreement", "pc.whoop-agreement"].contains(r.modelId) && newest[r.modelId] == nil {
            newest[r.modelId] = r
        }
        var parts: [String: [String]] = [:]
        for r in newest.values.sorted(by: { $0.modelId < $1.modelId }) {
            let rho = r.metrics.filter { $0.name == MetricKey.agreementSpearman.rawValue }
            let bias = r.metrics.filter { $0.name == MetricKey.agreementBias.rawValue }
            for m in rho {
                guard let gid = m.group else { continue }
                let b = bias.first { $0.group == gid && $0.source == m.source }
                var line = m.source
                if let v = m.value {
                    line += ": ρ \(MGFormat.number(v, decimals: 2))"
                    if let bv = b?.value { line += ", bias \(MGFormat.number(bv, decimals: 1)) \(b?.unit ?? "")" }
                } else {
                    line += ": " + (m.note ?? r.reason ?? "not computed")
                }
                line += " (\(m.window ?? "90d"), computed on PC \(r.date.iso))"
                parts[gid, default: []].append(line)
            }
        }
        return parts.mapValues { $0.joined(separator: "; ") }
    }

    /// APP-101 device-change markers on the detail graph: each change of wear location the log recorded.
    static func wearMarkers(_ events: [EventRecord], calendar: Calendar) -> [GraphMarker] {
        var out: [GraphMarker] = []
        var last: WearLocation?
        for e in events.sorted(by: { $0.at < $1.at }) where e.type == .wear && !e.removed {
            guard let loc = e.wearLocation else { continue }
            if let last, last != loc {
                out.append(GraphMarker(kind: .wearLocation, day: LocalDay(date: e.at, calendar: calendar),
                                       label: "worn on " + loc.rawValue.replacingOccurrences(of: "_", with: " ")))
            }
            last = loc
        }
        return out
    }

    // MARK: Notifications (alerts, medication, caffeine limit, wind-down)

    /// Posts each new unseen alert once and the reminders ReminderPlan wants, through NotifyCenter (quiet hours, the
    /// daily cap and the strap's asleep spans apply there). A reminder whose time moved replaces the old one; one no
    /// longer wanted (dose logged, toggle off, schedule removed) is withdrawn while still in the future.
    func postAlertsAndReminders(_ s: PresenterSnapshot) async {
        guard !isSample else { return }
        let center = services.notifyCenter
        var changed = false
        for a in s.inputs.alerts where !a.seen {
            let key = "alert|" + a.id
            guard sessions.notified[key] == nil else { continue }
            let id = "mg.alert.\(a.id)"
            _ = await center.offer(NotifyContent.alert(a), id: id)
            sessions.notified[key] = "\(id)@\(Int(s.now.timeIntervalSince1970))"
            changed = true
        }
        let plan = ReminderPlan.plan(now: s.now, calendar: calendar, schedules: settings.schedules, events: s.events,
                                     windDownOn: settings.windDownOn, bedtime: s.context.anchors.bedtime,
                                     caffeineCutoff: caffeineCutoff(s), limitMg: s.caffeineLimitMg,
                                     stressSummaryOn: settings.stressSummaryOn, stressToday: stressToday(s))
        for r in plan {
            let value = "\(r.id)@\(Int(r.at.timeIntervalSince1970))"
            if sessions.notified[r.slot] == value { continue }
            if let old = sessions.notified[r.slot], let oldID = old.split(separator: "@").first { await center.withdraw(id: String(oldID)) }
            // T57: a refused offer (quiet hours on a stale window, asleep span) is not marked done, so the next refresh retries it.
            let decision = await center.offer(NotifyContent.reminder(r), id: r.id, wanted: r.at, expiresAt: r.expiresAt)
            guard decision.whyNot == nil else { continue }
            sessions.notified[r.slot] = value
            changed = true
        }
        let wanted = Set(plan.map(\.slot))
        for (slot, value) in sessions.notified where !slot.hasPrefix("alert|") && !wanted.contains(slot) {
            let parts = value.split(separator: "@")
            if parts.count == 2, let at = Double(parts[1]), at > s.now.timeIntervalSince1970 {
                await center.withdraw(id: String(parts[0]))
            }
            sessions.notified.removeValue(forKey: slot)
            changed = true
        }
        if sessions.notified.count > 200 {      // alerts: keep the newest 200 keys (ids carry the night)
            for k in sessions.notified.keys.sorted().prefix(sessions.notified.count - 200) { sessions.notified.removeValue(forKey: k) }
        }
        if changed { await saveState() }
    }

    /// Today's caffeine cut-off from the G-CAFF member Mo reads (default ALG-061), else any member with a value.
    /// T31: today's daytime stress row (ALG-123:daytime) for the 5:00 PM summary; nil when it has no value.
    func stressToday(_ s: PresenterSnapshot) -> Metric? {
        s.metrics.first { $0.name == MetricKey.stress.rawValue && $0.variant == "ALG-123:daytime" && $0.value != nil }
    }

    func caffeineCutoff(_ s: PresenterSnapshot) -> Date? {
        let rows = s.metrics.filter { $0.name == MetricKey.caffeineCutoff.rawValue && $0.value != nil }
        let read = s.groupChoices["G-CAFF"]?.readVariant ?? "ALG-061"
        guard let v = (rows.first { $0.variant == read } ?? rows.first)?.value else { return nil }
        return Date(timeIntervalSince1970: v)
    }

    // MARK: Working on…

    /// A sync step reported by MGSync (nil = the sync ended).
    func syncProgress(_ p: SyncProgress?) {
        working.sync = p.map { WorkingInput.Sync(phase: WorkingInput.Sync.Phase(rawValue: $0.phase.rawValue) ?? .uploading,
                                                 done: $0.done, total: $0.total) }
        publishWorking()
    }

    /// A compute run started (`days` > 0) or ended (nil).
    func computeProgress(_ reason: String?, days: Int) {
        working.compute = reason.map { WorkingInput.Compute(reason: $0, days: days, since: clock.now) }
        publishWorking()
    }

    /// The Apple Health bridge: a Shortcut run waiting for its callback, or samples on their way to the PC.
    func noteHealthBridgeWork() {
        let b = healthBridge
        if let p = b.doc.pending {
            working.healthImport = "Apple Health Shortcut “\(p.shortcut)” running since "
                + MGFormat.time(p.startedAt, calendar: calendar)
        } else {
            working.healthImport = b.forwarding ? "Sending Apple Health samples to the PC" : nil
        }
    }

    /// Rebuilds the "Working on…" line from the last snapshot (history download comes from the context inputs).
    func publishWorking() {
        noteHealthBridgeWork()
        guard var s = lastSnapshot else { return }
        s.working = working
        s.inputs.history = StrapCoordinator.history(strapLinkState)
        setIfChanged(\.workingState, WorkingPresenter.make(s))
        setIfChanged(\.workingDetail, WorkingDetailPresenter.make(s))
        setIfChanged(\.workingBadge, WorkingBadgePresenter.make(s))   // T108: shown on Today even with the bars hidden
    }
}
