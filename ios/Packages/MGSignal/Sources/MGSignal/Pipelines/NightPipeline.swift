import Foundation
import MGDomain

// WP-22 NightPipeline — the night that ends on the morning of `day` (D13: it belongs to the wake day).
//   search span 18:00 (day − 1) → 18:00 (day) → ALG-004 A on its R-R → WP-10's SleepNight (ALG-030 rest window →
//   ALG-120 hypnogram; strap flag) → ALG-150 strap-night accounting (longest strap-asleep period, no rest window) → the
//   SLEEP PERIOD = ALG-150 [onset, final wake), else the
//   ALG-030 rest window, else nothing (every nightly value blank "no sleep window: …"; main 2026-10-11: no fallback span)
//   → physiology on the period (HRV family, RHR / dip, breathing, SpO2 byte, skin temp, AF screens)
//   → morning stage (ALG-101, ALG-036 in band, ALG-112) → Mo's script members (MS-07, MS-15,
//   MS-21, MS-18, MS-19, MS-20) → regularity (14 d) and chronotype (28 d) → the live stager's morning check
//   (WP-11: LiveStager replayed over ALG-120's rest window, SleepLiveAgreement in the G-STAGE notes).
// Python mirror: app/pclab/golden/gen_pipelines.py `night_run`, `physiology`, `morning`; goldens PIPE-NIGHT.json.
// WRITTEN, NOT COMPILED.

/// Everything one night run reads (WP-23 builds it with `NightPipeline.loadInputs`; tests build it directly).
public struct NightInputs: Sendable {
    public var day: LocalDay
    public var now: Date
    public var settings: PipelineSettings
    /// R18 seconds of the search span (and later, up to now).
    public var r18: [R18Second]
    /// R-R of the search span (up to now).
    public var rr: [RRPoint]
    /// HR from 12 h before the search span (hr_dip day side) up to now.
    public var hr: [HRPoint]
    public var profile: Profile?
    /// Earlier days (metrics, series, events) and the events of `day` itself (`history.events[day]`).
    public var history: MetricHistory
    /// What the store already holds for `day`; the night's metrics replace rows with the same key.
    public var stored: [Metric]
    /// Wave 4: v26 PPG windows and R20 optical records of the search span (empty when the source has none).
    public var ppg: [PPGBlock]
    public var r20: [R20Record]
    /// T9746: raw skin-temperature night medians of earlier days that have no stored `skin_temp_night_raw` series but do
    /// have stored seconds (rebuilt by `ALG110.nightWhileStrapAsleep`). Empty = the baseline is only what the pipeline
    /// has stored, as the Python mirror computes it.
    public var skinTempBackfill: [LocalDay: Double]

    public init(day: LocalDay, now: Date, settings: PipelineSettings, r18: [R18Second], rr: [RRPoint], hr: [HRPoint],
                profile: Profile?, history: MetricHistory, stored: [Metric], ppg: [PPGBlock] = [],
                r20: [R20Record] = [], skinTempBackfill: [LocalDay: Double] = [:]) {
        self.day = day
        self.now = now
        self.settings = settings
        self.r18 = PipelineStreams.dedupe(r18)
        self.rr = PipelineStreams.dedupe(rr)
        self.hr = PipelineStreams.dedupe(hr)
        self.profile = profile
        self.history = history
        self.stored = stored
        self.ppg = ppg
        self.r20 = r20
        self.skinTempBackfill = skinTempBackfill
    }
}

/// The physiology members on one span.
public struct NightPhysiology: Sendable {
    public var metrics: [Metric]
    public var series: [Series]
    /// Tonight's raw skin-temp median (ALG-110 night), the next nights' baseline input.
    public var tempRawTonight: Double?
    public var hrv: HRVWindowSet
    /// ALG-023 CVHR screen of the span (its episodes become breathing_event events).
    public var cvhr: Computed<ALG023.Screen>

    public init(metrics: [Metric], series: [Series], tempRawTonight: Double?, hrv: HRVWindowSet,
                cvhr: Computed<ALG023.Screen> = .missing("not run")) {
        self.metrics = metrics
        self.series = series
        self.tempRawTonight = tempRawTonight
        self.hrv = hrv
        self.cvhr = cvhr
    }
}

/// One night's result. `metrics` / `series` are what WP-23 stores under `day`.
public struct NightResult: Sendable {
    public var day: LocalDay
    public var metrics: [Metric]
    public var series: [Series]
    public var outcome: SleepNight.Outcome
    /// The span physiology ran on ([onset, final wake) or the rest window), or why there is none.
    public var period: Computed<SleepInterval>
    /// The period ends within 5 min of the last strap record: the night may still be going — run it again later.
    public var provisional: Bool
    /// WP-11 morning check: the live stager replayed vs ALG-120.
    public var liveCheck: Computed<SleepLiveAgreement>
    public var at: Date
    /// Output-rule problems (a metric failing `validate()` or a duplicate store key); empty when all is well.
    public var problems: [String]
    /// ALG-023 breathing_event upserts: tonight's CVHR episodes, and earlier ALG-023 events of the night this run no
    /// longer finds, marked retracted (never deleted).
    public var events: [EventRecord]

    public init(day: LocalDay, metrics: [Metric], series: [Series], outcome: SleepNight.Outcome,
                period: Computed<SleepInterval>, provisional: Bool, liveCheck: Computed<SleepLiveAgreement>, at: Date,
                problems: [String], events: [EventRecord] = []) {
        self.day = day
        self.metrics = metrics
        self.series = series
        self.outcome = outcome
        self.period = period
        self.provisional = provisional
        self.liveCheck = liveCheck
        self.at = at
        self.problems = problems
        self.events = events
    }
}

public enum NightPipeline {

    // MARK: entry points (WP-23)

    /// Reads the store, computes, writes. Call after a history download is stored, at wake (the context engine's W)
    /// and again when a result came back `provisional`. Idempotent: unchanged metrics are not rewritten (MGStore).
    @discardableResult
    public static func run(day: LocalDay, now: Date, source: any PipelineSource, sink: (any PipelineSink)?,
                           settings: PipelineSettings, core: any SignalCore = Signal.core) async throws -> NightResult {
        let inputs = try await loadInputs(day: day, now: now, source: source, settings: settings)
        let result = compute(inputs, core: core)
        if let sink {
            try await sink.upsertMetrics(result.metrics, day: day)
            try await sink.upsertSeries(result.series, day: day)
            for e in result.events { try await sink.upsertEvent(e) }
        }
        return result
    }

    /// T10009 (2026-10-17): the optical streams are read in slices of this many seconds (30 minutes), not as one whole-night
    /// fetch: each slice's rows are decoded and released before the next is read, so the peak is one slice of raw rows plus the
    /// decoded night, not the whole night's rows twice. The slices are contiguous and do not overlap, so the concatenation is
    /// exactly what one read of the span returns.
    public static let opticalWindowSeconds: Int64 = 30 * 60

    /// `includeR20: false` (a background run): the R20 optical records are not read at all (the PC owns the optical night
    /// features); `NightInputs.r20` stays empty and `removingR20Derived` takes the metrics that would then be wrong out.
    public static func loadInputs(day: LocalDay, now: Date, source: any PipelineSource,
                                  settings: PipelineSettings, includeR20: Bool = true) async throws -> NightInputs {
        let clock = PipelineClock(timeZone: settings.timeZone)
        let span = clock.nightSpan(day)
        let end = min(Int64(now.timeIntervalSince1970.rounded(.down)), span.end + 2 * 3600)
        let r18 = try await source.r18Seconds(from: span.start, to: end, strapId: settings.strapId)
        let rr = try await source.rrIntervals(from: span.start, to: end, strapId: settings.strapId)
        let hr = try await source.hrSamples(from: span.start - PipelineConstants.dipDaySideSeconds, to: end,
                                            strapId: settings.strapId)
        let history = try await Baselines.load(source: source, before: day, clock: clock)
        var ppg: [PPGBlock] = []
        var r20: [R20Record] = []
        if let optical = source as? any OpticalSource {          // wave 4
            var from = span.start
            while from <= end {
                try Task.checkCancellation()                      // a cancelled run stops between slices
                let to = min(from + opticalWindowSeconds - 1, end)
                ppg += try await optical.ppgBlocks(from: from, to: to, strapId: settings.strapId)
                if includeR20 { r20 += try await optical.r20Records(from: from, to: to, strapId: settings.strapId) }
                from = to + 1
                await Task.yield()
            }
        }
        // T9746: nights before this one that the pipeline never stored a skin-temperature median for (the phone only
        // started computing recently) but whose seconds are on the phone: rebuild their median so MS-21's baseline
        // learns from every stored night instead of only the nights the pipeline ran.
        var backfill: [LocalDay: Double] = [:]
        for back in 1...PipelineConstants.readyComponentDays {
            let d = day.adding(days: -back)
            guard history.series0(Baselines.skinTempNightRaw, on: d) == nil else { continue }
            // Round 5: a night with no seconds, or none asleep, is not asked again for an hour (every snapshot re-ran
            // these queries for the same empty days).
            if BackfillMisses.shared.isRecent(d, strapId: settings.strapId, now: now) { continue }
            let sp = clock.nightSpan(d)
            let rows = try await source.r18Seconds(from: sp.start, to: sp.end, strapId: settings.strapId)
            if rows.isEmpty { BackfillMisses.shared.note(d, strapId: settings.strapId, now: now); continue }
            if let n = ALG110.nightWhileStrapAsleep(r18: rows, start: sp.start, end: sp.end).value {
                backfill[d] = n.rawMedian
            } else {
                BackfillMisses.shared.note(d, strapId: settings.strapId, now: now)
            }
        }
        return NightInputs(day: day, now: now, settings: settings, r18: r18, rr: rr, hr: hr,
                           profile: try await source.effectiveProfile(), history: history,
                           stored: try await source.metrics(on: day), ppg: ppg, r20: r20, skinTempBackfill: backfill)
    }

    /// Days whose skin-temperature backfill found nothing, remembered for `ttl` seconds.
    final class BackfillMisses: @unchecked Sendable {
        static let shared = BackfillMisses()
        static let ttl: TimeInterval = 3600
        private let lock = NSLock()
        private var misses: [String: Date] = [:]
        private func key(_ d: LocalDay, _ strapId: StrapID?) -> String { "\(d)|\(String(describing: strapId))" }
        func isRecent(_ d: LocalDay, strapId: StrapID?, now: Date) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let at = misses[key(d, strapId)] else { return false }
            return now.timeIntervalSince(at) < Self.ttl && now >= at
        }
        func note(_ d: LocalDay, strapId: StrapID?, now: Date) {
            lock.lock(); defer { lock.unlock() }
            misses[key(d, strapId)] = now
        }
    }

    // MARK: compute

    public static func compute(_ inp: NightInputs, core: any SignalCore = Signal.core) -> NightResult {
        let clock = PipelineClock(timeZone: inp.settings.timeZone)
        let span = clock.nightSpan(inp.day)
        let s0 = Double(span.start)
        let s1 = Double(span.end)
        let rows = PipelineStreams.r18(inp.r18, s0, s1)
        let pts = PipelineStreams.rr(inp.rr, s0, s1)
        let rrs = pts.map(\.rrMs)
        let corrected = ALG004.correct(rrMs: rrs, times: BeatClock.times(points: pts))
        // Oct 16 2026: the night must wake on `day` (ALG-150 takes the strap flag's longest asleep period ending on this local
        // day; no ALG-030 rest window decides it)
        let wakeDay = (start: Double(clock.dayStart(inp.day)), end: Double(clock.dayStart(inp.day.adding(days: 1))))
        // D-SLEEP-LOW-2: a night that ends within 15 min of the newest strap second is not published (it may still be going,
        // or its history has not arrived); it is blank "night not finished" and computed again when more data lands
        let unfinished: (dataEnd: Int64, now: Int64)? = rows.last.map { (dataEnd: $0.ts, now: Int64(inp.now.timeIntervalSince1970)) }
        let outcome = SleepNight.analyse(seconds: SleepSeconds(r18: rows, hrCleaning: inp.settings.hrCleaning),
                                         beats: SleepBeats(corrected), wakeDay: wakeDay, unfinished: unfinished,
                                         strapMethod: inp.settings.sleepStrapMethod, core: core)
        let notFinished = [outcome.strapAccounting, outcome.fusedAccounting]
            .contains { $0.missingReason?.hasPrefix(ALG150.unfinishedPrefix) ?? false }

        // D-9746-R2a: the strap flag decides asleep / awake and the totals; since Oct 17 2026 (D-SLEEP-WALK-1) the ALG-151 fused
        // stager picks the stage inside strap-asleep epochs (no strap flag: no ALG-151, ALG-120 alone, reason in the stage notes)
        // Oct 16 2026 (Codex review of the ALG-103 removal): the totals come from the strap night only — fused, else the
        // strap flag's own ALG-150. ALG-120's accounting covers just its rest window (the 23-min bug), so it is never the total.
        let usesFused = inp.settings.strapPrimary && outcome.fusedAccounting.value != nil
        let primaryAccounting = usesFused ? outcome.fusedAccounting
            : outcome.strapAccounting.value != nil ? outcome.strapAccounting
            : notFinished ? .missing(outcome.strapAccounting.missingReason ?? ALG150.unfinishedPrefix)
            : .missing("no strap sleep flag for this night (" + (outcome.strapAccounting.missingReason ?? "no strap records") + ")")

        // the sleep period
        var period: Computed<SleepInterval>
        if let acc = primaryAccounting.value {
            period = .success(SleepInterval(start: Double(acc.sleepOnset), end: Double(acc.wakeTime)))
        } else if let w = outcome.window.value {
            period = .success(SleepInterval(start: Double(w.restStart), end: Double(w.restEnd)))
        } else {
            period = .missing("no sleep window: " + (outcome.window.missingReason ?? "no strap records"))
        }
        // T9737 (2026-10-14): a run at 2:40 AM, before Mo was asleep, found the 8:09-9:12 PM stretch as "the longest rest".
        // The span was refused as today's night, but its sleep_total (48 min), onset and wake still went into today's
        // rows and stayed there for hours (a later run that never started could not replace them). A rest that ends
        // on another day is not this day's night: its accounting, stages and strap flag are blank with that reason.
        var wrongDay: Missing?
        if let p = period.value, clock.localDay(p.end) != inp.day {
            let why = "the longest rest in this span ends on \(clock.localDay(p.end)), not \(inp.day)"
            period = .missing(why)
            wrongDay = Missing(why + " (the night has not started or is not in the data yet)")
        }
        let at = Date(timeIntervalSince1970: period.value?.end ?? min(inp.now.timeIntervalSince1970, s1))

        // sleep accounting and the G-STAGE members
        let needLastNight = inp.history.value("sleep_need", variant: "ALG-115", window: "night",
                                              on: inp.day.adding(days: -1)).orMissing("no sleep need for last night yet")
        var shown = outcome
        shown.accounting = primaryAccounting
        if let wrongDay {
            shown.window = .failure(wrongDay)
            shown.stager = .failure(wrongDay)
            shown.accounting = .failure(wrongDay)
            shown.fused = .failure(wrongDay)
            shown.fusedAccounting = .failure(wrongDay)
            shown.strap = .failure(wrongDay)
            shown.strapAccounting = .failure(wrongDay)
        }
        var metrics = ALG150.metrics(shown.accounting, needMin: needLastNight, at: at)
        // Oct 16 2026: the totals are the strap night's, but the ALG-120 member's own stage minutes stay ALG-120's (the strap
        // accounting is sleep / wake only, so reading them from it would blank deep / light / REM). Oct 17 2026: ALG-151 has its
        // own variant, so ALG-120 is always ALG-120's own rest-window accounting (it used to stand in for the hybrid).
        var stageView = shown
        if wrongDay == nil { stageView.accounting = outcome.accounting }
        metrics += SleepStages.alg120Metrics(stageView, at: at)
        metrics += SleepStages.fusedMetrics(shown, at: at)
        if usesFused, wrongDay == nil {
            if let fu = shown.fused.value, !fu.staged {
                let why = "no stages: " + (fu.stageReason ?? "ALG-151 did not stage") + " (asleep / awake time is the strap's)"
                for i in metrics.indices where metrics[i].group == "G-STAGE" && metrics[i].variant == FusedStager.variant {
                    PipelineOutput.addNote(&metrics[i], why)
                }
            }
        } else if inp.settings.strapPrimary, wrongDay == nil {
            let why = "strap sleep / wake flag not available (" + (outcome.fusedAccounting.missingReason
                ?? "no reason recorded") + "), so ALG-120 alone decides asleep / awake"
            for i in metrics.indices where metrics[i].group == "G-STAGE" && metrics[i].variant == "ALG-120"
                && metrics[i].value != nil {
                PipelineOutput.addNote(&metrics[i], why)
            }
        }
        metrics += SleepStages.strapMetrics(shown, at: at)
        metrics += SleepStages.alg031AMetrics(at: at)
        var series: [Series] = []
        // ALG-120 on its own (rest window); the fused night is its own variant (it used to be stored under "ALG-120")
        if let st = shown.stager.value {
            series.append(SleepStages.series(st.hypnogram, variant: "ALG-120", tier: .estimate))
        }
        if let fu = shown.fused.value {
            series.append(SleepStages.series(fu.hypnogram, variant: FusedStager.variant, tier: .estimate))
        }
        if let ep = shown.strap.value {
            // presenters read every hypnogram as W L D R S . (WP-23b): the strap member is its accounting hypnogram;
            // the band's raw codes 0-3 go in their own series
            series.append(SleepStages.series(ep.hypnogram, variant: "strap", tier: .strap))
            series.append(codeSeries("strap_sleep_state", epoch0: ep.epoch0, codes: ep.codes, variant: "strap",
                                     tier: .strap, unit: "code"))
        }

        // T9746: the strap's own gravity-removed motion magnitude (R18 byte 41, g; decoded, untested), one value per
        // second over the night's sleep period, stored so it can be read later (written only when the rows carry it)
        if let p = period.value, wrongDay == nil, let dyn = dynAccelSeries(rows, p.start, p.end) { series.append(dyn) }

        // WP-11 morning check: the live stager replayed over ALG-120's rest window
        var liveCheck: Computed<SleepLiveAgreement>
        if let w = shown.window.value, let st = shown.stager.value {
            let live = LiveStager.stage(seconds: rows.map { SleepLiveSecond($0) }, rr: pts, start: w.restStart,
                                        end: w.restEnd, core: core)
            series.append(codeSeries("hypnogram", epoch0: live.epoch0, codes: live.classes, variant: "live",
                                     tier: .research, unit: "stage"))
            let b = st.hypnogram.codes.map { SleepLiveStage(rawValue: String($0)) ?? .noData }
            liveCheck = SleepLiveAgreement.compare(epoch0A: live.epoch0, live.epochs.map(\.stage),
                                                   epoch0B: st.hypnogram.epoch0, b)
            if let a = liveCheck.value {
                let k = a.kappa.value.map { String(format: "%.2f", $0) } ?? "n/a"
                let pct = Int((a.agreement * 100).rounded())
                let text = "live stager (morning replay, WP-11) agrees on \(pct)% of \(a.n) epochs, kappa \(k)"
                for i in metrics.indices where metrics[i].group == "G-STAGE" && metrics[i].variant == "ALG-120"
                    && metrics[i].value != nil {
                    PipelineOutput.addNote(&metrics[i], text)
                }
            }
        } else {
            liveCheck = .missing(shown.window.missingReason ?? shown.stager.missingReason ?? "no staged night")
        }

        // physiology on the period
        var tempRaw: Double?
        var cvhr: Computed<ALG023.Screen> = .missing("no sleep window")
        var events: [EventRecord] = []
        switch period {
        case .success(let p):
            let phys = physiology(span: p, inputs: inp, at: at, core: core)
            metrics += phys.metrics
            series += phys.series
            tempRaw = phys.tempRawTonight
            cvhr = phys.cvhr
            // r9s (ALG-171): rest-to-walk heart-rate rises of the whole search span (evening, night, morning after waking)
            series += ALG171.series(ALG171.events(rows: inp.r18, hr: inp.hr, from: Int64(span.start), to: Int64(span.end)),
                                    start: Int64(span.start), span: Int64(span.end - span.start))
            // ALG-023: the night's CVHR episodes as breathing_event events (the Night lane, Today's last-night row)
            let around = inp.history.eventsOn(inp.day.adding(days: -1)) + inp.history.eventsOn(inp.day)
            events = ALG023.events(cvhr, spanStart: p.start, spanEnd: p.end, existing: around)
        case .failure(let m):
            metrics += physiologyBlank(m.reason, at: at)
            cvhr = .failure(m)
        }

        // regularity (14 d) and chronotype (28 d)
        metrics += regularity(inp, tonight: period.value, at: at, clock: clock)

        // morning stage, then Mo's script members on the merged day table
        let nightTable = PipelineOutput.merge(inp.stored, metrics)
        let morning = MorningStage.compute(day: inp.day, at: at, today: nightTable, history: inp.history,
                                           tempRawTonight: tempRaw, extras: ALG161.NightExtras(series: series))
        metrics += morning
        let table = PipelineOutput.merge(inp.stored, metrics)
        let sd = ScriptDay(day: inp.day, today: table, history: inp.history, events: inp.history.eventsOn(inp.day),
                           rr: inp.rr, hr: inp.hr, r18: inp.r18, profile: inp.profile, clock: clock)
        let night = ScriptMembers.night(sd, sleepWindow: sd.sleepWindow(), at: at, core: core)
        metrics += night.metrics
        series += night.series
        let sdMorning = ScriptDay(day: inp.day, today: PipelineOutput.merge(table, night.metrics), history: inp.history,
                                  events: inp.history.eventsOn(inp.day), rr: inp.rr, hr: inp.hr, r18: inp.r18,
                                  profile: inp.profile, clock: clock)
        metrics += ScriptMembers.morning(sdMorning, at: at, core: core)

        // wave 1: ALG-023 30-night view, ALG-138, ALG-102 on the complete day table
        let sdInsight = ScriptDay(day: inp.day, today: PipelineOutput.merge(inp.stored, metrics), history: inp.history,
                                  events: inp.history.eventsOn(inp.day), rr: inp.rr, hr: inp.hr, r18: inp.r18,
                                  profile: inp.profile, clock: clock)
        metrics += InsightMembers.night(sdInsight, at: at, tempRawTonight: tempRaw, cvhr: cvhr, core: core)

        var provisional = false
        if let p = period.value, let last = rows.last {
            provisional = p.end >= Double(last.ts) - Double(PipelineConstants.provisionalSeconds)
        }
        if notFinished { provisional = true }       // D-SLEEP-LOW-2: the coordinator runs it again
        let checked = PipelineOutput.checked(metrics)
        return NightResult(day: inp.day, metrics: checked.metrics, series: series, outcome: outcome, period: period,
                           provisional: provisional, liveCheck: liveCheck, at: at, problems: checked.problems,
                           events: events)
    }

    // MARK: physiology

    /// Every nightly physiology member on `span` (R-R / HR with start ≤ ts ≤ end, as the PC; R18 [start, end)),
    /// plus MS-07 / MS-15 / MS-21 with `span` as the sleep window. Public so a span can be checked on its own
    /// (the fixture's 03:00–03:30 excerpt: PIPE-NIGHT "physiology" cases).
    public static func physiologyWithScript(span: SleepInterval, inputs inp: NightInputs, at: Date,
                                            core: any SignalCore = Signal.core) -> NightPhysiology {
        var phys = physiology(span: span, inputs: inp, at: at, core: core)
        let clock = PipelineClock(timeZone: inp.settings.timeZone)
        let table = PipelineOutput.merge(inp.stored, phys.metrics)
        let sd = ScriptDay(day: inp.day, today: table, history: inp.history, events: inp.history.eventsOn(inp.day),
                           rr: inp.rr, hr: inp.hr, r18: inp.r18, profile: inp.profile, clock: clock)
        let ms = ScriptMembers.night(sd, sleepWindow: .success((on: span.start, wake: span.end)), at: at, core: core)
        phys.metrics += ms.metrics
        phys.series += ms.series
        return phys
    }

    /// The physiology members on `span` (no script members).
    public static func physiology(span: SleepInterval, inputs inp: NightInputs, at: Date,
                                  core: any SignalCore = Signal.core) -> NightPhysiology {
        let s = span.start
        let e = span.end
        let pts = PipelineStreams.rr(inp.rr, s, e)
        let set = HRVWindows.analyse(points: pts, core: core)
        var m: [Metric] = []
        m.append(ALG004.metric(set, at: at))
        m += ALG010.metrics(ALG010.nightly(set), at: at)
        m += ALG011.metrics(ALG011.nightly(set), at: at)
        m.append(ALG013.sampEnMetric(ALG013.nightlySampEn(points: pts, core: core), at: at))
        // P200: HR-CLEAN (range, Hampel, quality); resting HR also needs still seconds (activity class 0). When the still gate
        // leaves no 30-min window that is 90 % covered, resting HR falls back to the cleaned, un-gated seconds and says so.
        let hrm = inp.settings.hrCleaning
        let hrRaw = PipelineStreams.hr(inp.hr, s, e)
        let nightRows = PipelineStreams.r18(inp.r18, s, e + 1)
        let hrIn = HRClean.apply(hrRaw, r18: nightRows, method: hrm)
        let hrStill = HRClean.apply(hrRaw, r18: nightRows, method: hrm, requireStill: true)
        var rhrC = ALG012.restingHR(hrStill)
        var rhrNote: String? = hrm == .raw ? nil : "still seconds only"
        if hrm != .raw, rhrC.value == nil { rhrC = ALG012.restingHR(hrIn); rhrNote = "movement gate left too little still heart rate; cleaned seconds, not only still ones" }
        m.append(HRClean.tag(ALG012.rhrSpec, hrm).metric(rhrC, at: at, note: rhrNote))
        m.append(dipMetric(inp, start: s, hrInSpan: hrIn, method: hrm, at: at))
        let rw = ALG020.windows(points: pts, core: core)
        m += ALG020.metrics(ALG020.span(rw), at: at)
        let rows = PipelineStreams.r18(inp.r18, s, e)
        let start = Int64(s.rounded(.up))
        let end = Int64(e.rounded(.up))
        m += ALG021.metrics(ALG021.night(r18: rows, start: start, end: end), at: at)
        // wave 4 (#25): the PC gate's aggregate of the same byte; the schedule is measured over every loaded record
        m += ALG021Windows.metrics(ALG021Windows.night(r18: rows, dutySpan: inp.r18, start: start, end: end), at: at)
        // T9725 (Oct 14, D-069): ALG-144 gated, band-passed PPG pulse HR is the PRIMARY ppg_hr; ALG-108 stays a variant
        // D-HRV-WALK-1 (2026-10-17): with no v26 PPG that night, the same method reads the raw R20 records
        let pulse = inp.ppg.contains { $0.ts >= start && $0.ts < end } || inp.r20.isEmpty
            ? ALG144.night(inp.ppg, start: start, end: end) : ALG144.night(r20: inp.r20, start: start, end: end)
        m += ALG144.metrics(pulse, at: at)
        // signal quality, enhanced readout (base = rr_artefact): share of good 10 s segments of raw green pulse
        m += PPGSignalQuality.metrics(PPGSignalQuality.night(inp.r20, start: start, end: end), at: at)
        // wave 4: heart rate and spot HRV from the strap's v26 PPG bursts (ALG-108, variant)
        m += ALG108.metrics(ALG108.night(inp.ppg, start: start, end: end), at: at)
        // wave 4: breathing rate from the pulse's baseline (RIIV) and amplitude (RIAV) in the same bursts
        m += ALG121PPG.metrics(inp.ppg, start: start, end: end, at: at)
        // wave 4: pulse shape from raw optical block 0 (green), when R20 exists for the night (ALG-015)
        m += ALG015.metrics(ALG015.night(inp.r20, start: start, end: end), at: at)
        // T89: dicrotic notch, reflection index and the share of beats with a notch (same R20 block 0)
        m += PulseNotch.metrics(PulseNotch.night(inp.r20, start: start, end: end), at: at)
        // R9m (D-ALG-TIERS): ENHANCED SpO₂ from raw red / IR when R20 ran in the sleep period; blank with its reason
        // otherwise, and the strap's SpO₂ byte (ALG-021, above) stays the base reading
        let sb = inp.settings.spo2Blocks
        m.append(ALG022Night.metric(ALG022Night.night(inp.r20, red: sb.red, ir: sb.ir, start: start, end: end),
                                    basis: sb.basis, at: at))
        // wave 4: the strap's own optical signal-quality fields over the night (decoded, untested)
        m += R18QualityNight.metrics(R18QualityNight.night(r18: rows, r20: inp.r20, start: start, end: end), at: at)
        let tn = ALG110.night(r18: rows, start: start, end: end)
        let raw = tn.value?.rawMedian
        let nDays = PipelineConstants.readyComponentDays
        var stored = inp.history.denseSeries0(Baselines.skinTempNightRaw, before: inp.day, days: nDays)
        for (i, v) in stored.enumerated() where v == nil {      // index 0 = nDays back … nDays-1 = yesterday
            if let b = inp.skinTempBackfill[inp.day.adding(days: -(nDays - i))] { stored[i] = b }
        }
        let nightRaw = stored + [raw]
        m += ALG110.metrics(ALG110.deviation(nightRaw: nightRaw), at: at)
        let moving = rows.filter { ($0.activityClass ?? 0) >= 1 }.map(\.ts)
        let afScreen = ALG013.screen(points: pts, movingTs: moving, core: core)
        m.append(ALG013.screenMetric(afScreen, at: at))
        let times = BeatClock.times(points: pts)
        let p70 = ALG129.pnn70(rrMs: pts.map(\.rrMs), timesS: times, artefactFraction: set.artefactFraction)
        let cos = ALG129.cosenScreen(ts: pts.map(\.ts), rrMs: pts.map(\.rrMs))
        m += ALG129.metrics(pnn70: p70, cosen: cos, at: at)

        // wave 1 on the span's ALG-004-corrected beats: the CVHR
        // screen (ALG-023)
        let sortedPts = BeatClock.sorted(pts)
        let corr = ALG004.correct(rrMs: sortedPts.map(\.rrMs), times: BeatClock.times(points: sortedPts))
        let cvhr = ALG023.screen(nnMs: corr.rrMs, times: corr.times, artefactFraction: corr.correctedFraction)
        let afFlag = m.contains { $0.name == MetricKey.afScreen.rawValue && $0.variant == "ALG-013"
            && $0.value.map { Int($0.rounded()) == 1 } == true }
        m += ALG023.metrics(cvhr, at: at, rhythmFlag: afFlag)

        var series: [Series] = []
        if let hourly = hourlySeries(rw) { series.append(hourly) }
        if let t = tn.value {
            series.append(PipelineOutput.carry(Baselines.skinTempNightRaw, variant: "ALG-110", start: Int64(s),
                                               stepS: Int64(e - s), value: t.rawMedian, n: t.samples, unit: "count",
                                               tier: .strap))
        }
        // r9h (ALG-161): the first 3 h of sleep, kept so later nights can read them as a baseline (alcohol pattern)
        series += ALG161.first3hSeries(ALG161.first3h(hr: hrRaw, rr: pts, start: s), start: Int64(s), span: Int64(e - s))
        // r9s (ALG-170): the share of assessed still windows flagged irregular (AF burden) and the raw-pulse perfusion index
        if case .success(let af) = ALG170.afShare(afScreen) {
            series.append(PipelineOutput.carry(ALG170.afShareSeries, variant: "ALG-013", start: Int64(s), stepS: Int64(e - s),
                                               value: af.share, n: af.assessed, unit: "ratio", tier: .research))
        }
        series += ALG172.series(ALG172.night(inp.ppg, rows: rows, start: start, end: end), start: Int64(s), span: Int64(e - s))
        if let sp = spo2Series(rows, s, e) { series.append(sp) }
        if let mv = movementSeries(rows, s, e) { series.append(mv) }
        if let c = cvhr.value {
            series.append(PipelineOutput.carry(ALG023.hoursSeries, variant: "ALG-023", start: Int64(s), stepS: Int64(e - s),
                                               value: c.hours, unit: "h", tier: .research))
        }
        return NightPhysiology(metrics: m, series: series, tempRawTonight: raw, hrv: set, cvhr: cvhr)
    }

    /// ALG-012 v2 (2026-10-17, D-HRV-WALK-2): the night HR dip. Sleep side = the sleep period's heart rate in the seconds the
    /// strap does not call awake (every second when the period carries no strap flag at all); day side = awake heart rate
    /// (not strap-asleep) between 10:00 and 20:00 local on the day before the night, else all awake heart rate before the
    /// sleep period. 1-minute medians, ≥ 240 sleep and ≥ 360 day minutes. The note carries the trend against your own last
    /// 14 nights and the word "blunted" below 10 %; there is no risk score. Python mirror: gen_pipelines.py `dip_value`.
    static func dipMetric(_ inp: NightInputs, start s: Double, hrInSpan hrIn: [HRPoint], method: HRClean.Method,
                          at: Date) -> Metric {
        let clock = PipelineClock(timeZone: inp.settings.timeZone)
        var asleep = Set<Int64>()
        var awakeKnown = Set<Int64>()
        for r in inp.r18 {
            guard let st = r.sleepState else { continue }
            if st == 2 { asleep.insert(r.ts) } else if (0...3).contains(st) { awakeKnown.insert(r.ts) }
        }
        let night = awakeKnown.isEmpty && asleep.isEmpty ? hrIn : hrIn.filter { !awakeKnown.contains($0.ts) }
        let before = PipelineStreams.hr(inp.hr, 0, s - 1)
        let beforeRows = PipelineStreams.r18(inp.r18, 0, s)
        let awake = HRClean.apply(before, r18: beforeRows, method: method).filter { !asleep.contains($0.ts) }
        let winStart = clock.dayStart(inp.day.adding(days: -1)) + 10 * 3600
        let spec = HRClean.tag(ALG012.hrDipSpec, method)
        let pick = ALG012.dipDayPick(awakeTs: awake.map(\.ts), awakeBpm: awake.map(\.bpm), winStart: winStart,
                                     winEnd: winStart + 10 * 3600)
        guard let day = pick.value else { return spec.blank(pick.missingReason ?? "no day side", at: at) }
        let dip = ALG012.dip(dayTs: day.ts, dayBpm: day.bpm, nightTs: night.map(\.ts), nightBpm: night.map(\.bpm))
        guard let d = dip.value else { return spec.metric(dip.map(\.dip), at: at) }
        let prior = inp.history.dense("hr_dip", variant: "ALG-012", window: "night", before: inp.day,
                                      days: ALG012.dipTrendNights)
        return spec.metric(.success(d.dip), at: at, note: ALG012.dipNote(d, basis: day.basis,
                                                                          trend: ALG012.dipTrend(prior: prior, today: d.dip)))
    }

    /// Every physiology member blank with the same reason (no sleep window).
    public static func physiologyBlank(_ reason: String, at: Date) -> [Metric] {
        let specs: [MetricSpec] = [
            ALG004.artefactSpec, ALG010.rmssdSpec, ALG010.lnRmssdSpec, ALG010.sdnnSpec, ALG010.pnn50Spec,
            ALG010.sd1Spec, ALG010.sd2Spec, ALG011.lfHfSpec,
            ALG013.sampEnSpec, ALG012.rhrSpec, ALG012.hrDipSpec, ALG020.rsaSpec, ALG020.fusedSpec, ALG021.meanSpec,
            ALG021.minSpec, ALG021Windows.meanSpec, ALG021Windows.minSpec, ALG144.hrSpec, PPGSignalQuality.spec, ALG108.hrSpec, ALG108.hrvSpec, ALG121PPG.spec(.riiv), ALG121PPG.spec(.riav), ALG015.riseSpec, ALG015.widthSpec,
            PulseNotch.notchSpec, PulseNotch.reflectionSpec, PulseNotch.rateSpec,
            R18QualityNight.saturatedSpec, R18QualityNight.psnrSpec, R18QualityNight.logVarSpec, ALG110.spec100, ALG110.spec128, ALG013.screenSpec, ALG129.pnn70Spec, ALG129.cosenSpec,
            ALG022Night.spec,
            ALG023.cvhrSpec, ALG023.odiSpec,
        ]
        return specs.map { $0.blank(reason, at: at) }
    }

    // MARK: series

    /// `resp_rate_hourly` (ALG-121 member): one value per clock hour from the first to the last hour with windows.
    static func hourlySeries(_ windows: [ALG020.Window]) -> Series? {
        var states: [Int64: ALG020.State] = [:]
        for w in windows { states[w.start / PipelineConstants.hourSeconds * PipelineConstants.hourSeconds] = .asleep }
        let hours = ALG020.hourly(windows, stateByHour: states)
        guard let first = hours.map(\.hourStart).min(), let last = hours.map(\.hourStart).max() else { return nil }
        var byHour: [Int64: ALG020.Hour] = [:]
        for h in hours { byHour[h.hourStart] = h }
        var values: [Double?] = []
        var n: [Int] = []
        var quality: [Double?] = []
        var state: [String?] = []
        var hs = first
        while hs <= last {
            let h = byHour[hs]
            let r = h?.rsa.value
            values.append(r?.median)
            n.append(r?.windows ?? 0)
            quality.append(r?.coverage)
            state.append(h?.state.rawValue)
            hs += PipelineConstants.hourSeconds
        }
        return Series(name: "resp_rate_hourly", unit: "br_min", start: Date(timeIntervalSince1970: Double(first)),
                      stepS: Double(PipelineConstants.hourSeconds), values: values, n: n, quality: quality,
                      state: state, group: "G-RESP", variant: "ALG-121", tier: .estimate, computedOn: .phone)
    }

    /// `spo2_strap` (Night lane, raw byte, never %): mean 'reading' byte per 30-s epoch from floor30(start).
    static func spo2Series(_ rows: [R18Second], _ s: Double, _ e: Double) -> Series? {
        let e0 = Int64((s / 30.0).rounded(.down)) * 30
        let n30 = Int(((e - Double(e0)) / 30.0).rounded(.up))
        guard n30 > 0 else { return nil }
        var sums = [Double](repeating: 0, count: n30)
        var cnts = [Int](repeating: 0, count: n30)
        for r in rows where ALG021.mode(r.spo2Byte) == .reading {
            let k = Int((r.ts - e0) / 30)
            if k >= 0 && k < n30, let b = r.spo2Byte {
                sums[k] += Double(b)
                cnts[k] += 1
            }
        }
        guard cnts.contains(where: { $0 > 0 }) else { return nil }
        let values: [Double?] = (0..<n30).map { cnts[$0] > 0 ? sums[$0] / Double(cnts[$0]) : nil }
        return Series(name: "spo2_strap", unit: "count", start: Date(timeIntervalSince1970: Double(e0)), stepS: 30,
                      values: values, group: "G-SPO2", variant: "ALG-021", tier: .strap, computedOn: .phone)
    }

    /// `movement` (Night lane): ALG-030's minute activity (Σ |Δ z-angle| per minute, degrees) over
    /// the period.
    static func movementSeries(_ rows: [R18Second], _ s: Double, _ e: Double) -> Series? {
        let g = SleepMotionGrid.build(SleepSeconds(r18: rows))
        guard !g.act.isEmpty else { return nil }
        let j0 = max(0, Int((Int64(s.rounded(.down)) - g.t0) / 60))
        let j1 = min(g.act.count - 1, Int((Int64(e.rounded(.up)) - 1 - g.t0) / 60))
        guard j1 >= j0 else { return nil }
        return Series(name: "movement", unit: "deg_per_min", start: Date(timeIntervalSince1970: Double(g.t0 + Int64(60 * j0))),
                      stepS: 60, values: Array(g.act[j0...j1]), group: nil, variant: "ALG-030", tier: .estimate,
                      computedOn: .phone)
    }

    /// `dynamic_acceleration` (T9746): R18 byte 41, one value per second from `s` to `e`, nil where a second has none.
    /// nil (no series) when no second in the span carries it, e.g. nights stored before the column existed.
    static func dynAccelSeries(_ rows: [R18Second], _ s: Double, _ e: Double) -> Series? {
        let t0 = Int64(s.rounded(.down))
        let t1 = Int64(e.rounded(.down))
        guard t1 > t0 else { return nil }
        var values = [Double?](repeating: nil, count: Int(t1 - t0))
        var any = false
        for r in rows where r.ts >= t0 && r.ts < t1 {
            if let d = r.dynAccel, d.isFinite {
                values[Int(r.ts - t0)] = d
                any = true
            }
        }
        guard any else { return nil }
        return Series(name: "dynamic_acceleration", unit: "g", start: Date(timeIntervalSince1970: Double(t0)), stepS: 1,
                      values: values, group: nil, variant: "strap", tier: .strap, computedOn: .phone)
    }

    /// A per-epoch code series ("." → null) for hypnograms written as strings.
    static func codeSeries(_ name: String, epoch0: Int64, codes: String, variant: String, tier: Tier,
                           unit: String) -> Series {
        let states: [String?] = codes.map { $0 == "." ? nil : String($0) }
        return Series(name: name, unit: unit, start: Date(timeIntervalSince1970: Double(epoch0)), stepS: 30,
                      values: [Double?](repeating: nil, count: states.count), state: states, group: "G-STAGE",
                      variant: variant, tier: tier, computedOn: .phone)
    }

    // MARK: regularity and chronotype (WRITTEN; no pipeline golden yet — the family goldens cover the maths)

    /// sri / circadian_* over the 14 days before the wake day (minute activity from the `motion_minute` carry series,
    /// sleeps = stored onset … wake of each night plus tonight), chronotype over the last 28 nights.
    static func regularity(_ inp: NightInputs, tonight: SleepInterval?, at: Date, clock: PipelineClock) -> [Metric] {
        let h = inp.history
        let days = PipelineConstants.regularityDays
        let startDay = inp.day.adding(days: -days)
        let start = clock.dayStart(startDay)
        let minutes = days * 1440
        var act = [Double?](repeating: nil, count: minutes)
        for k in 0..<days {
            let d = startDay.adding(days: k)
            guard let s = h.series[d]?.first(where: { $0.name == Baselines.motionMinute }) else { continue }
            let off = Int((Int64(s.start.timeIntervalSince1970) - start) / 60)
            for (i, v) in s.values.enumerated() where off + i >= 0 && off + i < minutes { act[off + i] = v }
        }
        var observed: [SleepInterval] = []
        var runStart: Int?
        for i in 0...minutes {
            let has = i < minutes && act[i] != nil
            if has && runStart == nil { runStart = i }
            if !has, let r = runStart {
                observed.append(SleepInterval(start: Double(start + Int64(r * 60)), end: Double(start + Int64(i * 60))))
                runStart = nil
            }
        }
        var sleeps: [SleepInterval] = []
        for k in 0...days {
            let d = inp.day.adding(days: -k)
            if let on = h.value("sleep_onset", variant: "ALG-030", window: "night", on: d),
               let wk = h.value("wake_time", variant: "ALG-030", window: "night", on: d), wk > on {
                sleeps.append(SleepInterval(start: on, end: wk))
                // T8 (2026-10-12): an imported night has no motion minutes, so its noon-to-noon day counts as observed
                // (as the PC does for ALG-030:import); without it the SRI stayed at "have 0.0" days.
                if h.importedDays("sleep_onset", variant: "ALG-030", window: "night", among: [d]) == 1 {
                    observed.append(SleepInterval(start: Double(clock.dayStart(d.adding(days: -1)) + 43_200),
                                                  end: Double(clock.dayStart(d) + 43_200)))
                }
            }
            for e in h.eventsOn(d) where !e.removed {
                if case .nap(let f) = e.payload, f.confirmed == true {
                    sleeps.append(SleepInterval(start: e.at.timeIntervalSince1970, end: f.end.timeIntervalSince1970))
                }
            }
        }
        if let t = tonight { sleeps.append(t) }
        let states = ALG030.minuteStates(start: start, minutes: minutes, sleeps: sleeps, observed: observed)
        let off = clock.offsetSeconds(at: Double(start))
        var out = ALG030.regularityMetrics(sri: ALG030.sri(states),
                                           rhythm: ALG030.nonparametric(start: start, minuteActivity: act,
                                                                        utcOffsetSeconds: off),
                                           at: at)
        var nights: [ALG116.Night] = []
        for k in (0..<PipelineConstants.chronoDays).reversed() {
            let d = inp.day.adding(days: -k)
            let on: Double?
            let wk: Double?
            if k == 0, let t = tonight {
                on = t.start
                wk = t.end
            } else {
                on = h.value("sleep_onset", variant: "ALG-030", window: "night", on: d)
                wk = h.value("wake_time", variant: "ALG-030", window: "night", on: d)
            }
            if let o = on, let w = wk, w > o {
                nights.append(ALG116.Night(onset: o, wake: w, free: clock.mustBeUp(inp.settings, on: d) == nil))
            }
        }
        out.append(ALG116.metric(ALG116.chronotype(nights: nights, utcOffsetSeconds: off), at: at))
        return out
    }
}
