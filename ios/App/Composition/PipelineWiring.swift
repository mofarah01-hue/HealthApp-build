import Foundation
import MGContext
import MGDomain
import MGSignal
import MGStore

// WP-23a — MGStore behind WP-22's pipeline ports (MGSignal/Pipelines/PipelinePorts.swift, approved by main
// 2026-10-11): every requirement already has exactly the signature of a public MGStore method, so the conformance is
// empty apart from `memberMarks()`, which mirrors MGStore's group marks one-to-one (raw values read / keep / drop).
// The settings the store does not hold arrive as `PipelineSettings`.
//
// Runner (WP-22 README "Entry points for WP-23"): for each requested day, `NightPipeline.run` (wake day D13) then
// `DayPipeline.run` (local day; it also re-runs the morning members — MS-20 reads ATL/CTL). ComputeCoordinator asks for
// it hourly, after a history download, at wake, on every log save and workout edit, and again while a night comes back
// `provisional`. `MatrixPipeline.run` feeds Explore's matrix (AppModel+Snapshot). Wave 2 (2026-10-11): the read-only
// HabitPipeline and ALG-116 social jetlag run here after the day pipeline (today's `DayExtrasInput` in the report);
// GroupPipeline runs in the snapshot for the open group (AppModel+Outputs.swift).
//
// WRITTEN, NOT COMPILED.

/// Wave 4: the night pipeline reads v26 PPG and R20 optical records through MGStore's own reads.
extension MGStore: OpticalSource {}

extension MGStore: PipelineSource, PipelineSink {
    public func memberMarks() async throws -> [MemberMark] {
        try await groupMarks().compactMap { m in
            guard let value = MemberMark.Value(rawValue: m.mark.rawValue) else { return nil }
            return MemberMark(groupId: m.groupId, variant: m.variant, mark: value, at: m.at)
        }
    }

    /// Wave 2: imported history for ALG-040's step calibration (the pipelines otherwise read own rows only).
    public func importedMetrics(named name: String, from: LocalDay,
                                to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        try await metrics(named: name, from: from, to: to, includingImported: true)
            .filter { ImportedHistory.isImported($0.metric) }
    }
}

extension ComputeSettings {
    /// WP-22's settings value: "must be up by" keyed by contract weekday ("HH:MM" local), the need override.
    func pipelineSettings(strapId: StrapID?) -> PipelineSettings {
        var table: [MedSchedule.Weekday: String] = [:]
        for (weekday, t) in latestWake {
            guard let w = Self.contractWeekday(weekday) else { continue }
            table[w] = String(format: "%02d:%02d", t.hour, t.minute)
        }
        return PipelineSettings(timeZone: timeZone, mustBeUpBy: table,
                                needOverrideMin: needOverrideMinutes.map(Double.init), strapId: strapId,
                                medSchedules: medSchedules, strapPrimary: true, hrCleaning: .hampel,
                                lisdexAliases: lisdexAliases)
    }

    /// Calendar weekday (1 = Sunday … 7 = Saturday) → contract weekday.
    static func contractWeekday(_ weekday: Int) -> MedSchedule.Weekday? {
        switch weekday {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        case 7: return .sat
        default: return nil
        }
    }
}

/// The process's own clock for `WorkBudget` (T140): CPU time from getrusage, wall time from the system uptime.
extension WorkBudget.Clock {
    static let process = WorkBudget.Clock(
        cpu: { ProcessUsage.cpuSeconds() }, wall: { ProcessInfo.processInfo.systemUptime },
        sleep: { _ = try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
}

/// Rejects every mutation from a run after its generation has been invalidated.
private struct LeasedPipelineSink: PipelineSink {
    let store: MGStore
    let lease: ComputeWriteLease

    func upsertMetrics(_ metrics: [Metric], day: LocalDay) async throws -> Int {
        try Task.checkCancellation()
        try await lease.check()
        return try await store.upsertMetrics(metrics, day: day)
    }

    func upsertSeries(_ series: [Series], day: LocalDay) async throws -> Int {
        try Task.checkCancellation()
        try await lease.check()
        return try await store.upsertSeries(series, day: day)
    }

    func upsertEvent(_ event: EventRecord) async throws -> EventRecord {
        try Task.checkCancellation()
        try await lease.check()
        return try await store.upsertEvent(event)
    }
}

extension ComputeReason {
    /// Something the user is waiting on (foreground, manual, settings) may use more of the core than background work.
    /// R8o (audit §2.7): the launch compute is NOT waited on (Today is drawn from stored values first), so it gets the
    /// normal governor like background work and no longer runs flat out while the first screens are still drawing.
    var userWaiting: Bool { [.foreground, .manual, .settingsChanged].contains(self) }
}

/// The WP-22 pipelines over MGStore. Errors and output-rule problems go into the report line (never swallowed).
struct StorePipelineRunner: ComputeRunning {
    let store: MGStore
    let clock: any MGDomain.Clock

    func run(days: [LocalDay], settings: ComputeSettings, reason: ComputeReason,
             writeLease: ComputeWriteLease) async -> ComputeReport {
        let strapId = (try? await store.primaryStrapId()) ?? nil
        let sink = LeasedPipelineSink(store: store, lease: writeLease)
        var ps = settings.pipelineSettings(strapId: strapId)
        let now = clock.now
        // T32: the daytime stress scores the clock window (9 AM - 5 PM). No stored setting, location permission or Places
        // snapshot is fed yet, so the geofence modes fall back to the clock hours exactly as `DaytimeWindow` does.
        var windowCal = Calendar(identifier: .gregorian)
        windowCal.timeZone = settings.timeZone
        ps.daytimeSpans = days.flatMap {
            DaytimeWindow().resolve(day: $0.start(in: settings.timeZone), calendar: windowCal, places: PlacesSnapshot(),
                                    locationAllowed: false, now: now).spans
        }
        var computed = 0
        var notes: [String] = []
        var provisional: [LocalDay] = []
        var failed: Set<LocalDay> = []
        var workouts: [DateInterval] = []
        var naps: [DateInterval] = []
        var extras: DayExtrasInput?
        var dayCal = Calendar(identifier: .gregorian)
        dayCal.timeZone = settings.timeZone
        let today = LocalDay(date: now, calendar: dayCal)
        if settings.lightBackground, let newest = days.max() {
            return await runLight(day: newest, requested: days, ps: ps, sink: sink, now: now, reason: reason,
                                  writeLease: writeLease)
        }
        var budget = WorkBudget.forRun(userWaiting: reason.userWaiting, backgroundOnBattery: settings.backgroundOnBattery,
                                       clock: .process)
        var deferred: [LocalDay] = []
        let fileLog = ComputeLog.shared
        let wallClock = self.clock
        func logDay(_ text: String) { fileLog.append(.dayStart, text, at: wallClock.now) }          // T9737: persistent trace
        func logDone(_ text: String) { fileLog.append(.dayEnd, text, at: wallClock.now) }
        for (dayIndex, day) in days.enumerated() {
            // T140: in the background on battery a run stops taking days once it has used its CPU limit (never before
            // its first day); the rest come back in `deferredDays` and are marked due again.
            if day != days.first, !budget.hasRoom { deferred.append(day); continue }
            // T9728: cancellation is cooperative, so also honor the invalidated write generation at every stage edge.
            let nightMayStart = await writeLease.permitsWork()
            if Task.isCancelled || !nightMayStart {
                deferred.append(contentsOf: days[dayIndex...])
                break
            }
            do {
                logDay("\(day.iso) night")
                let r = try await NightPipeline.run(day: day, now: now, source: store, sink: sink, settings: ps)
                logDone("\(day.iso) night: \(r.metrics.count) metric(s)" + (r.period.value == nil
                        ? "; no night period (\(r.period.missingReason ?? "no reason"))" : ""))
                computed += r.metrics.count
                if !r.problems.isEmpty { notes.append("\(day.iso) night: \(r.problems.joined(separator: "; "))") }
                if r.provisional { provisional.append(day) }
            } catch is CancellationError {
                deferred.append(contentsOf: days[dayIndex...])
                break
            } catch {
                logDone("\(day.iso) night failed: \(error)")
                notes.append("\(day.iso) night failed: \(error)")
                failed.insert(day)
            }
            let nightMayFinish = await writeLease.permitsWork()
            if Task.isCancelled || !nightMayFinish {
                deferred.append(contentsOf: days[dayIndex...])
                break
            }
            await budget.rest()
            let dayMayStart = await writeLease.permitsWork()
            if Task.isCancelled || !dayMayStart {
                deferred.append(contentsOf: days[dayIndex...])
                break
            }
            do {
                logDay("\(day.iso) day")
                let r = try await DayPipeline.run(day: day, now: now, source: store, sink: sink, settings: ps)
                logDone("\(day.iso) day: \(r.metrics.count) metric(s)")
                let dayMayFinish = await writeLease.permitsWork()
                if Task.isCancelled || !dayMayFinish {
                    deferred.append(contentsOf: days[dayIndex...])
                    break
                }
                computed += r.metrics.count
                if !r.problems.isEmpty { notes.append("\(day.iso) day: \(r.problems.joined(separator: "; "))") }
                for w in r.detectedWorkouts.value ?? [] where w.endTs > w.startTs {
                    workouts.append(DateInterval(start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                                                 end: Date(timeIntervalSince1970: TimeInterval(w.endTs))))
                }
                for c in r.napCandidates.value ?? [] where c.nap && c.end > c.start {
                    naps.append(DateInterval(start: Date(timeIntervalSince1970: c.start),
                                             end: Date(timeIntervalSince1970: c.end)))
                }
                // Wave 2: raw strap ticks while steps are uncalibrated (ALG-040:ticks), stored so every screen sees them
                let ticks = ALG040.uncalibratedTicks(metrics: r.metrics, series: r.series, at: now)
                if let ticks {
                    computed += try await sink.upsertMetrics([ticks], day: day)
                } else if try await store.metrics(on: day).contains(where: {
                    $0.variant == ALG040.ticksSpec.variant && $0.value != nil }) {
                    computed += try await sink.upsertMetrics([ALG040.ticksSpec.blank(
                        "calibrated now: the strap member (ALG-040) has the steps", at: now)], day: day)
                }
                if day == today {
                    extras = await DayExtrasBuilder.make(r, ticks: ticks?.value, store: store, settings: settings,
                                                         pipeline: ps, now: now)
                }
            } catch is CancellationError {
                deferred.append(contentsOf: days[dayIndex...])
                break
            } catch {
                logDone("\(day.iso) day failed: \(error)")
                notes.append("\(day.iso) day failed: \(error)")
                failed.insert(day)
            }
            let dayWritesFinished = await writeLease.permitsWork()
            if Task.isCancelled || !dayWritesFinished {
                deferred.append(contentsOf: days[dayIndex...])
                break
            }
            await budget.rest()
        }
        var head = "compute (\(reason.rawValue)): night + day pipelines over \(days.count) day(s), \(computed) metric(s)"
        if !deferred.isEmpty { head += "; \(deferred.count) day(s) left for later (background CPU limit)" }
        if !provisional.isEmpty { head += "; provisional night \(provisional.map(\.iso).joined(separator: ", "))" }
        return ComputeReport(ran: true, days: days, metricsWritten: computed,
                             line: notes.isEmpty ? head : head + " — " + notes.joined(separator: " | "),
                             provisionalDays: provisional, failedDays: failed.sorted(), deferredDays: deferred, suggestedWorkouts: workouts, suggestedNaps: naps,
                             dayExtras: extras)
    }

    /// T9995 (2026-10-17): the light background run. iOS stopped the app for 90 s of CPU in 92 s (limit: 50 % over 180 s),
    /// so a run in the background does only the night pipeline of the newest day, in three slices (read, compute, write)
    /// with a rest after each (`WorkBudget.lightGovernor`), and stops if the CPU limit is used up. The day pipeline, the
    /// day's extras and every older day wait for the foreground or the BGProcessing task: `nightOnlyDays` tells the
    /// coordinator to add the day pipeline at the next full run. Nothing is hidden: the report line says what was left.
    private func runLight(day: LocalDay, requested: [LocalDay], ps: PipelineSettings, sink: LeasedPipelineSink, now: Date,
                          reason: ComputeReason, writeLease: ComputeWriteLease) async -> ComputeReport {
        var budget = WorkBudget.forRun(userWaiting: false, backgroundOnBattery: false, lightBackground: true, clock: .process)
        let fileLog = ComputeLog.shared
        let left = requested.filter { $0 != day }
        func report(_ line: String, computed: Int = 0, failed: Bool = false, provisional: Bool = false,
                    deferred: [LocalDay] = [], nightDone: Bool = false) -> ComputeReport {
            ComputeReport(ran: true, days: [day], metricsWritten: computed, line: line,
                          provisionalDays: provisional ? [day] : [], failedDays: failed ? [day] : [],
                          deferredDays: deferred + left, nightOnlyDays: nightDone ? [day] : [])
        }
        fileLog.append(.dayStart, "\(day.iso) night (light background run)", at: clock.now)
        do {
            guard await writeLease.permitsWork() else { return report("compute (\(reason.rawValue)): stopped before reading", deferred: [day]) }
            // T10009: no R20 in a background run (the PC owns the optical night features); the PPG blocks are read in slices.
            let inputs = try await NightPipeline.loadInputs(day: day, now: now, source: store, settings: ps, includeR20: false)
            await budget.rest()
            guard await writeLease.permitsWork(), !Task.isCancelled else {
                return report("compute (\(reason.rawValue)): stopped after reading", deferred: [day])
            }
            guard budget.hasRoom else {
                return report("compute (\(reason.rawValue)): background CPU limit used up while reading; night of \(day.iso) left for later",
                              deferred: [day])
            }
            let r = NightPipeline.compute(inputs)
            await budget.rest()
            try Task.checkCancellation()
            // The members that need R20 are left as the last foreground run wrote them (they would compute from nothing here).
            let lightMetrics = NightPipeline.removingR20Derived(from: r.metrics)
            _ = try await sink.upsertMetrics(lightMetrics, day: day)
            _ = try await sink.upsertSeries(r.series, day: day)
            for e in r.events { _ = try await sink.upsertEvent(e) }
            await budget.rest()
            fileLog.append(.dayEnd, "\(day.iso) night: \(lightMetrics.count) metric(s) (light background run, no R20)", at: clock.now)
            var line = "compute (\(reason.rawValue)): light background run, night pipeline only for \(day.iso), \(lightMetrics.count) metric(s), R20 not read"
            line += "; day pipeline" + (left.isEmpty ? "" : " and \(left.count) older day(s)") + " left for the foreground"
            if !r.problems.isEmpty { line += " — " + r.problems.joined(separator: "; ") }
            return report(line, computed: lightMetrics.count, provisional: r.provisional, nightDone: true)
        } catch is CancellationError {
            return report("compute (\(reason.rawValue)): light background run cancelled", deferred: [day])
        } catch {
            fileLog.append(.dayEnd, "\(day.iso) night failed: \(error)", at: clock.now)
            return report("compute (\(reason.rawValue)): \(day.iso) night failed: \(error)", failed: true)
        }
    }
}
