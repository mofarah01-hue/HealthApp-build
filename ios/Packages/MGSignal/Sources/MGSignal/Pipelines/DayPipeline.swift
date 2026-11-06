import Foundation
import MGDomain

// WP-22 DayPipeline — one local day (D13: events belong to the local date of `at`), recomputed hourly and on every log
// save: HRmax members, waking HR, strain / load (ALG-036, CTL/ATL/TSB), logged workouts (strain, calories), calories
// (G-CAL), steps (G-STEPS), VO2max / Fitness Age (G-VO2, research), body arousal (ALG-054, ALG-123:daytime), caffeine now /
// at bedtime and the cut-off group (G-CAFF), vape timing, tonight's sleep need / debt / bedtime (ALG-115), Mo's script
// day members (MS-01 … MS-06), the morning members again (MS-20 reads the day's ATL / CTL), and the suggestions the
// presenters show (detected workouts, nap candidates, movement minutes, caffeine and medication curves, adherence).
// Python mirror (the members the goldens pin): gen_pipelines.py `day_run`; goldens PIPE-DAY.json.
// WRITTEN, NOT COMPILED.

public struct DayInputs: Sendable {
    public var day: LocalDay
    public var now: Date
    public var settings: PipelineSettings
    /// The day's strap rows, R-R and HR from local midnight up to now.
    public var r18: [R18Second]
    public var rr: [RRPoint]
    public var hr: [HRPoint]
    /// HR inside the logged workouts of the 6 days before (Fitness Age activity index).
    public var recentWorkoutHR: [HRPoint]
    public var profile: Profile?
    /// Earlier days and the events of the day itself (`history.events[day]`).
    public var history: MetricHistory
    /// What the store holds for the day already (the night's wake time, RHR, HRV …).
    public var stored: [Metric]
    public var storedSeries: [Series]
    /// Imported Apple Health step totals (pc.history, variant apple_health) of the calibration days: the ALG-040
    /// reference when the phone has no iPhone steps of its own (HealthKit is off in this build). Wave 2, 2026-10-11.
    public var importedSteps: [LocalDay: Double]
    /// Raw motion (R21, wave W8 2026-10-11): the day's seconds (ALG-113 ENMO, ALG-114 asymmetry) and the per-second
    /// accelerometer summaries of the `RawMotion.cosinorWindowDays` days before (CosinorAge, ALG-134).
    public var motion: [MotionSecond]
    public var motionWeek: [MotionAccelSummary]
    /// Imported WHOOP / Apple Health nights (`ImportedHistory.variants`, window night) of the `chronoDays` days up to
    /// the day: sleep onset, wake, total, efficiency, WHOOP's need and debt. The sleep-driven models fall back to them
    /// when the strap has no night of its own (W10, 2026-10-11: Mo's 3.5 h night reached ALG-051 / 052 / 115 as nothing).
    public var importedNights: [LocalDay: [Metric]] = [:]
    /// The newest raw optical records (R20, the last `DayPipeline.pulseSeconds` s up to now) for the pulse-wave spot
    /// (OpticalPulse, T47); empty when the source has no optical stream.
    public var r20: [R20Record] = []

    public init(day: LocalDay, now: Date, settings: PipelineSettings, r18: [R18Second], rr: [RRPoint], hr: [HRPoint],
                recentWorkoutHR: [HRPoint], profile: Profile?, history: MetricHistory, stored: [Metric],
                storedSeries: [Series], importedSteps: [LocalDay: Double] = [:], motion: [MotionSecond] = [],
                motionWeek: [MotionAccelSummary] = []) {
        self.importedSteps = importedSteps
        self.motion = motion
        self.motionWeek = motionWeek
        self.day = day
        self.now = now
        self.settings = settings
        self.r18 = PipelineStreams.dedupe(r18)
        self.rr = PipelineStreams.dedupe(rr)
        self.hr = PipelineStreams.dedupe(hr)
        self.recentWorkoutHR = PipelineStreams.dedupe(recentWorkoutHR)
        self.profile = profile
        self.history = history
        self.stored = stored
        self.storedSeries = storedSeries
    }
}

public struct DayResult: Sendable {
    public var day: LocalDay
    public var metrics: [Metric]
    public var series: [Series]
    /// ALG-041 suggestions (never logged automatically; empty = none found).
    public var detectedWorkouts: Computed<[ALG041.DetectedWorkout]>
    /// ALG-033 nap candidates ("Nap 14:05–14:31?" peek) and the ALG-127 member of G-NAP beside it.
    public var napCandidates: Computed<[ALG033.Candidate]>
    public var napCandidates127: Computed<[ALG127.Candidate]>
    /// ALG-044 minutes by strap activity class.
    public var movement: ALG044.MovementSummary
    /// ALG-060 mg on board every 10 min over the day.
    public var caffeineCurve: Computed<[ALG060.Sample]>
    /// ALG-143 relative level of the lisdexamfetamine preset every 10 min (label PK, never dosing advice).
    public var medicationCurve: Computed<[ALG143.Sample]>
    /// ALG-069 adherence per schedule name (Settings schedules), due slots only.
    public var adherence: [String: Computed<ALG069.Adherence>]
    /// ALG-063 HR / RMSSD before vs after each vape session.
    public var nicotineResponse: Computed<ALG063.Response>
    public var wornMinutes: Int
    public var problems: [String]

    public init(day: LocalDay, metrics: [Metric], series: [Series],
                detectedWorkouts: Computed<[ALG041.DetectedWorkout]>, napCandidates: Computed<[ALG033.Candidate]>,
                napCandidates127: Computed<[ALG127.Candidate]>, movement: ALG044.MovementSummary,
                caffeineCurve: Computed<[ALG060.Sample]>, medicationCurve: Computed<[ALG143.Sample]>,
                adherence: [String: Computed<ALG069.Adherence>], nicotineResponse: Computed<ALG063.Response>,
                wornMinutes: Int, problems: [String]) {
        self.day = day
        self.metrics = metrics
        self.series = series
        self.detectedWorkouts = detectedWorkouts
        self.napCandidates = napCandidates
        self.napCandidates127 = napCandidates127
        self.movement = movement
        self.caffeineCurve = caffeineCurve
        self.medicationCurve = medicationCurve
        self.adherence = adherence
        self.nicotineResponse = nicotineResponse
        self.wornMinutes = wornMinutes
        self.problems = problems
    }
}

public enum DayPipeline {
    static let hkSteps = "HKQuantityTypeIdentifierStepCount"
    static let hkActive = "HKQuantityTypeIdentifierActiveEnergyBurned"
    static let hkVO2 = "HKQuantityTypeIdentifierVO2Max"
    static let hkMass = "HKQuantityTypeIdentifierBodyMass"
    /// Medication names the ALG-143 lisdexamfetamine preset applies to: the generic compound name, plus the product names
    /// the user listed in the local preset file (`PipelineSettings.lisdexAliases`, T9973; no brand name in source).
    static func lisdexNames(_ aliases: [String]) -> [String] { ["lisdexamfetamine"] + aliases }

    /// How far back from now the pulse-wave spot (OpticalPulse) looks for raw optical records.
    static let pulseSeconds: Int64 = 120

    // MARK: entry points (WP-23)

    /// Reads the store, computes, writes. Call hourly, on every log save (`.saveEvent`) and after a history download.
    @discardableResult
    public static func run(day: LocalDay, now: Date, source: any PipelineSource, sink: (any PipelineSink)?,
                           settings: PipelineSettings, core: any SignalCore = Signal.core) async throws -> DayResult {
        let inputs = try await loadInputs(day: day, now: now, source: source, settings: settings)
        let result = compute(inputs, core: core)
        if let sink {
            try await sink.upsertMetrics(result.metrics, day: day)
            try await sink.upsertSeries(result.series, day: day)
        }
        return result
    }

    public static func loadInputs(day: LocalDay, now: Date, source: any PipelineSource,
                                  settings: PipelineSettings) async throws -> DayInputs {
        let clock = PipelineClock(timeZone: settings.timeZone)
        let ds = clock.dayStart(day)
        let de = clock.dayStart(day.adding(days: 1))
        let end = min(Int64(now.timeIntervalSince1970.rounded(.down)), de - 1)
        let history = try await Baselines.load(source: source, before: day, clock: clock)
        var recent: [HRPoint] = []
        for k in 1...6 {
            for e in history.eventsOn(day.adding(days: -k)) where !e.removed {
                guard case .workout(let f) = e.payload else { continue }
                recent += try await source.hrSamples(from: Int64(e.at.timeIntervalSince1970),
                                                     to: Int64(f.end.timeIntervalSince1970), strapId: settings.strapId)
            }
        }
        var imported: [LocalDay: Double] = [:]
        for row in try await source.importedMetrics(named: MetricKey.steps.rawValue,
                                                    from: day.adding(days: -PipelineConstants.chronoDays),
                                                    to: day.adding(days: -1))
        where row.metric.variant == ImportedHistory.appleHealth && ImportedHistory.isImported(row.metric) {
            if let v = row.metric.value, v.isFinite { imported[row.day] = v }
        }
        var inputs = DayInputs(day: day, now: now, settings: settings,
                         r18: try await source.r18Seconds(from: ds, to: end, strapId: settings.strapId),
                         rr: try await source.rrIntervals(from: ds, to: end, strapId: settings.strapId),
                         hr: try await source.hrSamples(from: ds, to: end, strapId: settings.strapId),
                         recentWorkoutHR: recent, profile: try await source.effectiveProfile(), history: history,
                         stored: try await source.metrics(on: day), storedSeries: try await source.series(on: day),
                         importedSteps: imported,
                         motion: try await source.motionSeconds(from: ds, to: end, strapId: settings.strapId),
                         motionWeek: try await source.motionSummaries(
                            from: clock.dayStart(day.adding(days: -RawMotion.cosinorWindowDays)), to: ds - 1,
                            strapId: settings.strapId))
        inputs.importedNights = history.imported
        if let optical = source as? any OpticalSource {
            inputs.r20 = try await optical.r20Records(from: max(ds, end - pulseSeconds), to: end, strapId: settings.strapId)
        }
        return inputs
    }

    /// The imported value of `name` for night `d`: WHOOP's export before Apple Health (`ImportedHistory.variants`).
    static func importedNight(_ nights: [LocalDay: [Metric]], _ d: LocalDay, _ name: String) -> Double? {
        var h = MetricHistory()
        h.imported = nights
        return h.importedValue(name, window: "night", on: d)
    }

    // MARK: helpers

    /// ALG-051 `alertness` at `now` for the day: sleeps of the
    /// `historyNights` + 1 days before from the stored rows (own rest window, else imported), confirmed naps, and the
    /// caffeine doses the cut-off uses (yesterday + today); bedtime = the G-CAFF bedtime when known.
    static func alertnessMetrics(day: LocalDay, now: Date, at: Date, stored: MetricHistory, history h: MetricHistory,
                                 doses: [ALG060.Dose], bedtime: Double?, timeZone: TimeZone,
                                 imported: [LocalDay: [Metric]] = [:]) -> [Metric] {
        var byDay: [LocalDay: [Metric]] = [:]
        var events: [EventRecord] = []
        for k in 0...(ALG051.historyNights + 1) {
            let d = day.adding(days: -k)
            // own rows first; ALG051.sleepSpans takes ALG-030, else the imported variants (W10: they now arrive)
            byDay[d] = (k == 0 ? (stored.metrics[d] ?? []) : (h.metrics[d] ?? [])) + (imported[d] ?? [])
            events += h.eventsOn(d)
        }
        let sleeps = ALG051.sleepSpans(metricsByDay: byDay, events: events)
        let fc = ALG051.forecast(sleeps: sleeps, doses: doses, now: now, until: bedtime.map { Date(timeIntervalSince1970: $0) },
                                 timeZone: timeZone)
        return [ALG051.alertnessMetric(fc, at: now)]
    }

    struct Workout {
        var id8: String
        var start: Double
        var end: Double
        /// r9p: the type Mo or the detector gave (slug), the CR-10 rating and the weights, when logged.
        var type: String = "workout"
        var rpe: Double?
        var preKg: Double?
        var postKg: Double?
    }

    static func loggedWorkouts(_ events: [EventRecord]) -> [Workout] {
        events.compactMap { e -> Workout? in
            guard !e.removed, case .workout(let f) = e.payload else { return nil }
            return Workout(id8: PipelineSpecs.id8(e.id), start: e.at.timeIntervalSince1970, end: f.end.timeIntervalSince1970,
                           type: typeSlug(f.activityTypeUser ?? f.activityTypeAuto), rpe: f.sessionRpe,
                           preKg: f.weightPreKg, postKg: f.weightPostKg)
        }.sorted { $0.start < $1.start }
    }

    /// A workout type as a carry-series suffix: lowercase letters and digits, "workout" when untyped.
    static func typeSlug(_ type: String?) -> String {
        let s = String((type ?? "").lowercased().filter { $0.isLetter || $0.isNumber })
        return s.isEmpty ? "workout" : s
    }

    /// Drinks (ml) logged in [from, to]: substance events of kind drink (a drink without a volume is nil, not counted).
    static func drinksMl(_ events: [EventRecord], from: Double = -Double.infinity, to: Double = Double.infinity) -> [Double?] {
        var out: [Double?] = []
        for e in events where !e.removed {
            guard case .substance(let f) = e.payload, f.kind == .drink else { continue }
            let t = e.at.timeIntervalSince1970
            if t >= from && t <= to { out.append(f.volumeMl) }
        }
        return out
    }

    static func confirmedNaps(_ events: [EventRecord]) -> [SleepInterval] {
        events.compactMap { e -> SleepInterval? in
            guard !e.removed, case .nap(let f) = e.payload, f.confirmed == true else { return nil }
            return SleepInterval(start: e.at.timeIntervalSince1970, end: f.end.timeIntervalSince1970)
        }
    }

    /// Rank of an Apple Health source, the PC's `history.source_rank` (bug 19): 0 WHOOP, 1 Apple Watch, 2 other wearable,
    /// 3 iPhone, 4 app / unknown. Names are NFKC + case-folded (Apple writes "<owner>’s Apple\u{00A0}Watch").
    static func sourceRank(_ name: String) -> Int {
        let n = name.precomposedStringWithCompatibilityMapping.lowercased()
        if n.contains("whoop") { return 0 }
        if n.contains("apple watch") { return 1 }
        let wearables = ["watch", "oura", "garmin", "fitbit", "polar", "withings", "ultrahuman", "amazfit", "zepp", "coros",
                         "suunto", "wahoo", "galaxy", "huawei", "xiaomi"]
        if wearables.contains(where: { n.contains($0) }) { return 2 }
        if n.contains("iphone") { return 3 }
        return 4
    }

    /// One source's day total of an Apple Health type and why it won.
    struct HealthPick: Equatable {
        var value: Double
        var source: String
        var rank: Int
        var others: [String]

        /// "WHOOP > Apple Watch > other wearables > iPhone > apps" as the PC states it, with the winner named.
        var note: String {
            var t = "source: \(source) (priority WHOOP > Apple Watch > other wearables > iPhone > apps, as on the PC)"
            if !others.isEmpty { t += "; not used: " + others.joined(separator: ", ") }
            return t
        }
    }

    /// Apple Health hourly sums of one type for the day, ONE source's total (Apple de-duplicates across devices, the hourly
    /// events here do not, so two sources are never summed). Which source: the PC's rule (bug 19, Mo 2026-10-14: the phone
    /// took the largest total, the PC takes WHOOP > Apple Watch > other wearable > iPhone > app, ties by most samples,
    /// then name), so one day has one count on both sides.
    static func healthDayPick(_ events: [EventRecord], type: String, unit: String) -> HealthPick? {
        var total: [String: Double] = [:]
        var count: [String: Int] = [:]
        for e in events where !e.removed {
            guard case .healthkit(let f) = e.payload, f.hkType == type, f.unit == unit, let v = f.value?.number,
                  v.isFinite else { continue }
            let src = healthSourceName(e)
            total[src, default: 0] += v
            count[src, default: 0] += 1
        }
        let order = total.keys.sorted {
            (sourceRank($0), -(count[$0] ?? 0), $0.lowercased()) < (sourceRank($1), -(count[$1] ?? 0), $1.lowercased())
        }
        guard let best = order.first, let v = total[best] else { return nil }
        let label = best.isEmpty ? "unnamed source" : best
        return HealthPick(value: v, source: label, rank: sourceRank(best),
                          others: order.dropFirst().map { $0.isEmpty ? "unnamed source" : $0 })
    }

    /// The raw-motion seconds that count for the wrist-swing walking model: those outside the stretches the strap was worn away
    /// from the wrist (r9o, WearPolicy).
    static func wristMotion(_ motion: [MotionSecond], _ off: [ClosedRange<Double>]) -> [MotionSecond] {
        off.isEmpty ? motion : motion.filter { !WearPolicy.inside(Double($0.ts), off) }
    }

    /// "app · device" of a Health event's origin ("" when it has neither): the key `healthDayPick` groups by.
    static func healthSourceName(_ e: EventRecord) -> String {
        [e.origin?.app, e.origin?.device].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One source's samples of an Apple Health quantity as (start, end, value), for the hourly steps merge. `source` is the
    /// label `HealthPick.source` carries ("unnamed source" for an event with no origin).
    static func healthSamples(_ events: [EventRecord], type: String, unit: String,
                              source: String) -> [(start: Double, end: Double, steps: Double)] {
        var out: [(start: Double, end: Double, steps: Double)] = []
        for e in events where !e.removed {
            guard case .healthkit(let f) = e.payload, f.hkType == type, f.unit == unit, let v = f.value?.number, v.isFinite else { continue }
            let name = healthSourceName(e)
            guard (name.isEmpty ? "unnamed source" : name) == source else { continue }
            let a = e.at.timeIntervalSince1970
            out.append((a, max(f.end?.timeIntervalSince1970 ?? a, a), v))
        }
        return out
    }

    static func healthDayTotal(_ events: [EventRecord], type: String, unit: String) -> Double? {
        healthDayPick(events, type: type, unit: unit)?.value
    }

    /// The VO2max the with-VO2max calories row uses, and where it came from (bug 7). Order: a sample of the day, the newest
    /// Apple / WHOOP value of the history window (own "apple" row, else an import), else the Uth HR-ratio estimate.
    struct VO2Pick: Equatable {
        var value: Double
        var label: String
    }

    static func vo2maxForCalories(day: LocalDay, history h: MetricHistory, dayEvents: [EventRecord], hrmax: Double?,
                                  rhr: Double?) -> VO2Pick? {
        func ok(_ v: Double?) -> Double? { v.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        if let v = ok(healthLatest(dayEvents, type: hkVO2, unit: "mL/(kg*min)")) {
            return VO2Pick(value: v, label: "\(String(format: "%.1f", v)) ml/kg/min, Apple Health sample of this day")
        }
        for k in 0..<PipelineConstants.historyDays {
            let d = day.adding(days: -k)
            if let v = ok(h.value("vo2max", variant: "apple", window: "day", on: d)) {
                return VO2Pick(value: v, label: "\(String(format: "%.1f", v)) ml/kg/min, newest Apple Health / WHOOP value "
                               + "(\(k) day(s) back)")
            }
        }
        if let u = ALG036.uthVO2max(hrmax: hrmax, rhr: rhr).value {
            return VO2Pick(value: u, label: "\(String(format: "%.1f", u)) ml/kg/min, estimate from HRmax / HRrest "
                           + "(Uth 2004); no measured or imported VO2max")
        }
        return nil
    }

    /// The day's ALG-036 strain row (bug 11): our own number, except a computed 0 on a day WHOOP's export holds a strain for,
    /// which is blank with the reason (the WHOOP value stays as its own member).
    static func dayStrainMetric(_ dstr: Computed<ALG036.DayStrain>, whoopStrain: Double?, at: Date,
                                 hrm: HRClean.Method = .raw) -> Metric {
        let spec = HRClean.tag(ALG036.strainSpec, hrm)
        if let ws = whoopStrain, ws.isFinite, ws > 0, let own = dstr.value?.strain, own <= 0 {
            return spec.blank("our load model gave 0, but WHOOP logged strain \(String(format: "%.1f", ws)) for this day; "
                + "a 0 is not shown on a day WHOOP recorded strain (WHOOP's value is the whoop_export member)", at: at)
        }
        // T9987: the published part first, in its own units; the 0-21 number is our mapping of it.
        let note = dstr.value.map { "Training load \(Int($0.netTrimp.rounded())) TRIMP (Banister, Morton 1990; net above your quiet level, "
            + "arbitrary units, from strap heart rate). The 0-21 number is a WHOOP-style scale (our mapping, not validated)." }
        return spec.metric(dstr.map(\.strain), at: at, note: note)
    }

    /// A count that was logged: a number above 0 is stored; 0 is not a real zero when nothing was logged (bug 20), so it
    /// becomes a blank carrying `none`; nil carries `otherwise`.
    static func loggedCount(_ n: Int?, none: String, otherwise: String) -> Computed<Double> {
        guard let n else { return .missing(otherwise) }
        return n > 0 ? .success(Double(n)) : .missing(none)
    }

    static func healthLatest(_ events: [EventRecord], type: String, unit: String) -> Double? {
        var best: (Date, Double)?
        for e in events where !e.removed {
            guard case .healthkit(let f) = e.payload, f.hkType == type, f.unit == unit, let v = f.value?.number,
                  v.isFinite else { continue }
            if best == nil || e.at >= best!.0 { best = (e.at, v) }
        }
        return best?.1
    }

    static func ints(_ ts: [Int64]) -> [Int] { ts.map { Int($0) } }

    // MARK: breathing while awake (W10 #95)

    /// ALG-121 (RSA from R-R, the night's method) on the waking day, every clock hour (W10 #95, 2026-10-11; Mo 10-10:
    /// "need to save rr hourly … and during workouts having that as well if we can get it cleanly"). Quality gates:
    /// only beats from still seconds (strap activity class 0) outside workouts and detected exercise feed the 64-s
    /// windows (RSA is a resting measure), the windows' own coverage and artefact rules apply, and an hour needs 30
    /// usable windows (ALG-020 hourly). Workout hours stay blank with the reason: one estimator only, and ALG-020's
    /// workout mode needs two that agree. Series `resp_rate_hourly_awake` (state per hour); day value = the median of
    /// the usable windows, window "day".
    public static let awakeRespSeries = "resp_rate_hourly_awake"

    static func awakeBreathing(rr: [RRPoint], r18: [R18Second], from: Double, to: Double, exercise: [(Double, Double)],
                               core: any SignalCore) -> (day: Metric, series: Series?) {
        var spec = ALG020.rsaSpec
        spec.window = "day"
        let at = Date(timeIntervalSince1970: to)
        guard to - from >= 3600 else {
            return (spec.blank("less than an hour awake so far today", at: at), nil)
        }
        let moving = Set(r18.filter { ($0.activityClass ?? 0) >= 1 }.map(\.ts))
        let known = Set(r18.filter { $0.activityClass != nil }.map(\.ts))
        func inExercise(_ t: Double) -> Bool { exercise.contains { t >= $0.0 && t < $0.1 } }
        let still = rr.filter { p in
            !inExercise(Double(p.ts)) && known.contains(p.ts) && !moving.contains(p.ts)
        }
        let windows = ALG020.windows(points: still, core: core)
        let hourS = PipelineConstants.hourSeconds
        var states: [Int64: ALG020.State] = [:]
        for w in windows { states[w.start / hourS * hourS] = .awakeStill }
        let hours = ALG020.hourly(windows, stateByHour: states)
        var byHour: [Int64: ALG020.Hour] = [:]
        for h in hours { byHour[h.hourStart] = h }
        let h0 = Int64(from.rounded(.down)) / hourS * hourS
        let h1 = Int64(to.rounded(.down)) / hourS * hourS
        var values: [Double?] = []
        var n: [Int] = []
        var quality: [Double?] = []
        var state: [String?] = []
        var hs = h0
        while hs <= h1 {
            let workout = exercise.contains { $0.0 < Double(hs + hourS) && $0.1 > Double(hs) }
            if workout {
                values.append(nil); n.append(0); quality.append(nil); state.append(ALG020.State.workout.rawValue)
            } else if let h = byHour[hs], let r = h.rsa.value {
                values.append(r.median); n.append(r.windows); quality.append(r.coverage)
                state.append(ALG020.State.awakeStill.rawValue)
            } else {
                let secs = r18.filter { $0.ts >= hs && $0.ts < hs + hourS }
                let movingShare = secs.isEmpty ? 0 : Double(secs.filter { ($0.activityClass ?? 0) >= 1 }.count)
                    / Double(secs.count)
                values.append(nil); n.append(byHour[hs].map { _ in 0 } ?? 0); quality.append(nil)
                state.append(secs.isEmpty ? ALG020.State.unknown.rawValue
                             : (movingShare > 0.5 ? ALG020.State.awakeActive.rawValue : ALG020.State.awakeStill.rawValue))
            }
            hs += hourS
        }
        let series: Series? = values.isEmpty ? nil
            : Series(name: awakeRespSeries, unit: "br_min", start: Date(timeIntervalSince1970: Double(h0)),
                     stepS: Double(hourS), values: values, n: n, quality: quality, state: state, group: "G-RESP",
                     variant: "ALG-121", tier: .estimate, computedOn: .phone)
        let span = ALG020.span(windows)
        guard let s = span.rsa.value else {
            let why = span.rsa.missingReason ?? "no usable window"
            return (spec.blank("awake: \(why) (only still minutes outside workouts count)", at: at), series)
        }
        let usableHours = values.compactMap { $0 }.count
        return (spec.metric(.success(s.median), at: at, coverage: s.coverage,
                            note: "awake, still minutes outside workouts: \(s.windows) windows, \(usableHours) hour(s) "
                                + "with a value; workouts left out (RSA alone is not reliable during exercise)"), series)
    }

    /// "9 h 57 min" / "47 min" for notes (a duration, never a clock time).
    static func hm(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    // MARK: compute

    public static func compute(_ inp: DayInputs, core: any SignalCore = Signal.core) -> DayResult {
        let clock = PipelineClock(timeZone: inp.settings.timeZone)
        let day = inp.day
        let h = inp.history
        let ds = Double(clock.dayStart(day))
        let de = Double(clock.dayStart(day.adding(days: 1)))
        let now = inp.now.timeIntervalSince1970
        let end = min(now, de)
        let at = Date(timeIntervalSince1970: end)
        var t = MetricHistory(metrics: [day: inp.stored])
        t.imported = h.imported                       // W10: last night may exist only as an import
        let wake = t.value("wake_time", variant: "ALG-030", window: "night", on: day)
        let w0 = wake ?? ds
        let dayEvents = h.eventsOn(day).filter { $0.at.timeIntervalSince1970 >= ds && $0.at.timeIntervalSince1970 < de }
        let naps = confirmedNaps(dayEvents)
        let wos = loggedWorkouts(dayEvents)
        func waking(_ ts: Double) -> Bool {
            ts >= w0 && ts < end && !naps.contains { ts >= $0.start && ts < $0.end }
        }
        let prof = inp.profile
        let sex = prof?.sex
        let age: Computed<Double>
        if let b = prof?.birthDate {
            age = DayCalendar.ageYears(birth: b, on: day)
        } else {
            age = .missing("profile has no birth date (not in your Me profile and not on your PC)")
        }
        var ageWhole: Double?
        if let b = prof?.birthDate {
            ageWhole = Double(day.year - b.year - ((day.month, day.day) < (b.month, b.day) ? 1 : 0))
        }
        let weight = prof?.weightKg ?? healthLatest(dayEvents, type: hkMass, unit: "kg")
        let height = prof?.heightCm
        var out: [Metric] = []
        var series: [Series] = []

        // ---- heart-rate anchors and G-HRMAX
        let rhr7 = ALG036.rhr7dMedian(nights: h.dense("rhr", variant: "ALG-012", window: "night", before: day, days: 6)
                                      + [t.value("rhr", variant: "ALG-012", window: "night", on: day)])
        // P200: every HR reader below (resting-HR anchors, strain, calories, workouts) reads the HR-CLEAN output; `.raw` = the previous method
        let hrm = inp.settings.hrCleaning
        let hrClean = HRClean.apply(inp.hr, r18: inp.r18, method: hrm)
        let dayHR = hrClean.filter { Double($0.ts) >= ds && Double($0.ts) < end }
        // ALG-106 fix (WP-15, 2026-10-11): a workout's held max counts only when the window clears the ALG-041 vigorous
        // floor and the max is ≥ 0.9 × Tanaka — judged with the 7-day resting-HR median and the profile age
        var observed: ALG106.HeldMax? = wos.isEmpty ? nil : ALG106.observedMax(
            ts: ints(dayHR.map(\.ts)), bpm: dayHR.map(\.bpm),
            windows: wos.map { DayWindow(start: Int($0.start), end: Int($0.end)) }, rhr: rhr7.value,
            age: age.value).value
        var bestHist: Double?
        for k in 1...PipelineConstants.historyDays {
            if let v = h.value("hrmax", variant: "ALG-106:measured", window: "profile", on: day.adding(days: -k)),
               bestHist == nil || v > bestHist! { bestHist = v }
        }
        if let b = bestHist, observed == nil || b > observed!.bpm {
            observed = ALG106.HeldMax(bpm: b, ts: 0, heldS: ALG106.holdSeconds)
        }
        let hv = ALG106.variants(age: age.value, profileMeasured: prof?.hrMaxMeasured, observed: observed)
        out.append(ALG106.measuredSpec.metric(hv.measured, at: at, note: hv.measuredSource.map { "source: \($0)" }))
        // P9745: no age because the profile has no birth date says so (the formula's own "needs an age between 0 and 120" hid it)
        var tanakaV = hv.tanaka
        if case .failure(let m) = age, prof?.birthDate == nil { tanakaV = .missing(m.reason) }
        out.append(ALG106.tanakaSpec.metric(tanakaV, at: at))
        out.append(PipelineSpecs.hrmaxScript.metric(ageWhole.map { 208.0 - 0.8 * $0 }
                                                        .orMissing("needs profile.birth_date"), at: at))
        let rhrV = rhr7.value
        let hrmaxV = hv.primaryBpm

        // ---- waking HR, strain, load
        let wh = hrClean.filter { waking(Double($0.ts)) }
        out.append(HRClean.tag(ALG012.hrAvgSpec, hrm).metric(ALG012.average(wh), at: at))
        let mins = ALG036.perMinuteHR(ts: ints(wh.map(\.ts)), bpm: wh.map(\.bpm))
        let detected: Computed<[ALG041.DetectedWorkout]> = {
            let gravity = inp.r18.filter { $0.gx != nil && $0.gy != nil && $0.gz != nil }
            let motion = ALG044.motionPoints(ts: ints(gravity.map(\.ts)), gx: gravity.map { $0.gx! },
                                             gy: gravity.map { $0.gy! }, gz: gravity.map { $0.gz! })
            let classes = inp.r18.compactMap { r in r.activityClass.map { ALG041.ActivityClassSample(ts: Int(r.ts),
                                                                                                  activityClass: $0) } }
            return ALG041.detect(hrTs: ints(wh.map(\.ts)), hrBpm: wh.map(\.bpm), rhr: rhrV, hrmax: hrmaxV, motion: motion,
                                 classes: classes, savedSpans: wos.map { DayWindow(start: Int($0.start), end: Int($0.end)) })
        }()
        // Oct 17 2026 (Mo, D-RECOV-WALK-2): the day-level "wind-down to resting" readout (ours, T34) is removed. HR recovery
        // is per workout only (below), with a per-type personal baseline in the workout summary.
        let qd = ALG036.dailyQuietHRR(hrMinutes: mins.hr, rhr: rhrV, hrmax: hrmaxV)
        let qh = h.denseSeries0(Baselines.quietHRRDay, before: day, days: ALG036.quietWindowDays)
        let dstr = ALG036.dayStrain(hrMinutes: mins.hr, rhr: rhrV, hrmax: hrmaxV, sex: sex, quietHistory: qh)
        // r9n (D-LOAD-WALK-1 item 1): the fitted "WHOOP-style strain (estimate)" is written FIRST among the day strains, so a read
        // that takes the first valued member of `strain` gets the 0-21 number the front page shows.
        // T19: all-day strain fitted to the exported WHOOP days; needs no sex, no quiet history and no workout
        let strainFit = ALG036.dayStrainFit(hrMinutes: ALG036.perMinuteHR(ts: ints(dayHR.map(\.ts)), bpm: dayHR.map(\.bpm)).hr,
                                            rhr: rhrV, hrmax: hrmaxV)
        out.append(HRClean.tag(ALG036.strainFitSpec, hrm).metric(strainFit.map(\.strain), at: at,
                                               note: "estimate - not WHOOP's number: fitted to your exported WHOOP days"))
        // Bug 11 (Mo 2026-10-14: "WHOOP strain was never 0, even on non-workout days"): when WHOOP's export holds a strain for
        // this day, our own 0 is not shown as strain (a 0 here means "net load above the quiet level was 0", not "no
        // strain"). The row goes blank with a reason; WHOOP's own number stays beside it as the whoop_export member.
        out.append(Self.dayStrainMetric(dstr, whoopStrain: h.importedValue("strain", variant: "ALG-036", window: "day", on: day),
                                        at: at, hrm: hrm))
        // D-LOAD-WALK-1 item 1: the strain HEADLINE is the day's plain Banister TRIMP over the waking minutes, in its own units
        // (the 0-21 number above is the "WHOOP-style strain (estimate)"); needs no quiet-level history.
        let dtrimp = ALG036.dayTrimp(hrMinutes: mins.hr, rhr: rhrV, hrmax: hrmaxV, sex: sex)
        out.append(HRClean.tag(ALG036.trimpSpec, hrm).metric(dtrimp.map(\.trimp), at: at,
                                                             note: "TRIMP: Banister training-impulse units (Morton 1990), the day's waking minutes; not a 0-21 scale"))
        // ALG-048 v2 (D-LOAD-WALK-1 item 4): the person's own FLEX HR (Spurr 1988) from the strap's still / walk / run minutes
        let r18w = inp.r18.filter { $0.activityClass != nil && waking(Double($0.ts)) }
        let flexToday = ALG048.flexDay(minuteTs: mins.minuteTs, minuteHR: mins.hr, classTs: ints(r18w.map(\.ts)),
                                       classes: r18w.map { $0.activityClass ?? 0 })
        let flex = ALG048.flexHR(
            restHighs: h.denseSeries0(Baselines.flexRestHighDay, before: day, days: ALG036.quietWindowDays) + [flexToday.restHigh],
            exerciseLows: h.denseSeries0(Baselines.flexExerciseLowDay, before: day, days: ALG036.quietWindowDays) + [flexToday.exerciseLow])
        // D-POP-PRIOR: starts at the population point (resting HR + 40 % of reserve) and moves toward the person's own FLEX HR
        // as days grow, n / (n + 7). The note says which: 'population' (no own days) or 'yours (N days)'.
        let flexPrior: Double? = (rhrV != nil && hrmaxV != nil) ? rhrV! + ALG048.flexHRR * (hrmaxV! - rhrV!) : nil
        let flexDays = flex.value.map { min($0.restDays, $0.exerciseDays) } ?? 0
        let flexBpm: Double? = flexPrior.flatMap { ALG048.shrinkFlex(own: flex.value?.flexBpm, days: flexDays, prior: $0).value }
            ?? flex.value?.flexBpm
        var flexWhy = "not enough days yet"
        if case .failure(let m) = flex { flexWhy = m.reason }
        let flexNote: String = flex.value.map {
            "HR-flex (Spurr 1988): flex HR \(Int((flexBpm ?? $0.flexBpm).rounded())) bpm, yours (\(flexDays) days): your own "
                + "\(Int($0.flexBpm.rounded())) bpm = mean of your highest resting HR "
                + "\(Int($0.restHigh.rounded())) and lowest walking HR \(Int($0.exerciseLow.rounded())) "
                + "(medians over \($0.restDays) / \($0.exerciseDays) days), blended with the population point "
                + "\(Int((flexPrior ?? $0.flexBpm).rounded())) bpm at weight 7 / (\(flexDays) + 7); below it resting energy, above it Keytel"
        } ?? ("flex HR from the population point (resting HR + 40 % of reserve) while your own is learned, "
              + "yours (0 days): " + flexWhy)
        if let r = flexToday.restHigh {
            series.append(PipelineOutput.carry(Baselines.flexRestHighDay, variant: "ALG-048", start: Int64(ds), stepS: 86_400,
                                               value: r, unit: "bpm", tier: .estimate))
        }
        if let e = flexToday.exerciseLow {
            series.append(PipelineOutput.carry(Baselines.flexExerciseLowDay, variant: "ALG-048", start: Int64(ds), stepS: 86_400,
                                               value: e, unit: "bpm", tier: .estimate))
        }
        // ALG-135 v2 (r9p, D-LOAD-WALK-2): the EFSA reference, the drinks Mo logged today, and his sweat rate
        out.append(ALG135.metric(ALG135.goal(sex: sex), at: at))
        let drinksToday = Self.drinksMl(dayEvents, from: ds, to: de)
        out.append(drinksToday.isEmpty ? ALG135.intakeSpec.blank("no drinks logged today: log them in Log > Water", at: at)
                   : ALG135.intakeMetric(ALG135.status(drinksMl: drinksToday, sex: sex), at: at))
        // r9p (ALG-036:week): this week vs your 4-week average of plain TRIMP; a day without enough strap data is nil, not 0
        let trimpToday: Double? = mins.hr.count >= ALG036.dayStrainMinMinutes
            ? ALG036.trimp(hrMinutes: mins.hr, rhr: rhrV, hrmax: hrmaxV, sex: sex).value : nil
        let weekLoad = ALG036.weekVsAverage(dailyTrimp: h.denseSeries0(Baselines.trimpDay, before: day,
                                                                      days: ALG036.weekBaseDays - 1) + [trimpToday])
        let weekNote = weekLoad.value.map {
            "\($0.observedWeek) of 7 days this week, \($0.observed4wk) of 28 days in the average (yours, \($0.observed4wk) days); "
                + "a day without strap data is skipped, never a zero"
        }
        out.append(ALG036.weekSpec.metric(weekLoad.map(\.thisWeek), at: at, note: weekNote))
        out.append(ALG036.week4Spec.metric(weekLoad.map(\.avgWeek), at: at, note: weekNote))
        if let t = trimpToday {
            series.append(PipelineOutput.carry(Baselines.trimpDay, variant: "ALG-036", start: Int64(ds), stepS: 86_400,
                                               value: t, unit: "au", tier: .estimate))
        }
        var rated = 0.0
        var ratedN = 0
        for k in 0..<ALG036.weekDays {
            for e in (k == 0 ? dayEvents : h.eventsOn(day.adding(days: -k))) where !e.removed {
                guard case .workout(let f) = e.payload, let r = f.sessionRpe,
                      let l = ALG036.srpeLoad(rpe: r, minutes: f.end.timeIntervalSince(e.at) / 60.0).value else { continue }
                rated += l
                ratedN += 1
            }
        }
        out.append(ALG036.srpeWeekSpec.metric(ratedN == 0 ? .missing("no session rated this week: rate a workout after it ends")
                                              : .success(rated), at: at,
                                              note: ratedN == 0 ? nil : "\(ratedN) rated session\(ratedN == 1 ? "" : "s") in the last 7 days"))
        let net = dstr.value?.netTrimp
        let load = ALG036.ctlAtlTsb(dailyLoad: h.denseSeries0(Baselines.netTrimpDay, before: day,
                                                             days: PipelineConstants.historyDays - 1) + [net])
        out.append(ALG036.ctlSpec.metric(load.map(\.ctl), at: at, coverage: load.value?.coverage42d))
        out.append(ALG036.atlSpec.metric(load.map(\.atl), at: at, coverage: load.value?.coverage42d))
        out.append(ALG036.tsbSpec.metric(load.map(\.tsb), at: at, coverage: load.value?.coverage42d))
        out.append(ALG036.acwrSpec.metric(load.flatMap { $0.acwr.orMissing("CTL is 0: no ratio") }, at: at))
        if let q = qd.value {
            series.append(PipelineOutput.carry(Baselines.quietHRRDay, variant: "ALG-036", start: Int64(ds), stepS: 86_400,
                                               value: q, unit: "fraction", tier: .estimate))
        }
        if let n = net {
            series.append(PipelineOutput.carry(Baselines.netTrimpDay, variant: "ALG-036", start: Int64(ds), stepS: 86_400,
                                               value: n, unit: "au", tier: .estimate))
        }

        // D-LOAD-WALK-2: resting energy from the scan's fat-free mass (Cunningham 1980), flagged 'from scan'; Mifflin otherwise.
        let cunningham = ALG048.cunninghamBMR(ffmKg: prof?.fatFreeMassKg)
        let bmrScan: Double? = cunningham.value
        let restNote = bmrScan != nil
            ? String(format: "resting energy: Cunningham 1980 (500 + 22 x fat-free mass %.1f kg) from scan, adjusted to your current weight",
                     prof?.fatFreeMassKg ?? 0)
            : "resting energy: Mifflin-St Jeor (no body-composition scan on the PC)"
        // Active-calories range (D-LOAD-WALK-2): HIGH = heart rate alone (above the flex HR); LOW = only minutes in which the
        // strap's motion also says "moving" (30 s or more of the minute at activity class >= 1). Heart rate alone over-bills
        // stress, caffeine and heat; motion alone misses cycling and lifting; the range is the honest answer between them.
        var movingSecondsPerMinute: [Int: Int] = [:]
        for r in inp.r18 where (r.activityClass ?? 0) >= 1 { movingSecondsPerMinute[Int(r.ts) / 60, default: 0] += 1 }
        let movingMinutes = Set(movingSecondsPerMinute.filter { $0.value >= 30 }.keys)
        let haveMotion = inp.r18.contains { $0.activityClass != nil }

        // ---- logged workouts
        let q = ALG036.personalQuietHRR(dailyLevels: qh).value?.q
        let ageV = age.value
        var sessionTrimp: [String: Double] = [:]
        var sweatMlToday = 0.0
        var sweatMinToday = 0.0
        for w in wos {
            let hrIn = PipelineStreams.hr(hrClean, w.start, w.end)
            let wm = ALG036.perMinuteHR(ts: ints(hrIn.map(\.ts)), bpm: hrIn.map(\.bpm))
            let ws = ALG036.workoutStrain(hrMinutes: wm.hr, rhr: rhrV, hrmax: hrmaxV, sex: sex, q: q)
            out.append(PipelineSpecs.forWorkout(HRClean.tag(ALG036.workoutStrainSpec, hrm), id8: w.id8).metric(ws.map(\.strain), at: at))
            let cal = ALG048.activeCalories(hrTs: ints(hrIn.map(\.ts)), hrBpm: hrIn.map(\.bpm), rhr: rhrV, hrmax: hrmaxV,
                                            weightKg: weight, heightCm: height, age: ageV, sex: sex,
                                            windowMinutes: (w.end - w.start) / 60.0, flexBpm: flexBpm,
                                            bmrKcalDay: bmrScan)
            out.append(PipelineSpecs.forWorkout(HRClean.tag(ALG048.keytelSpec, hrm), id8: w.id8).metric(cal.map(\.activeKcal), at: at,
                                                                                                          note: flexNote))
            // r9p: load score against your earlier sessions of this type (replaces Training Effect), session-RPE load, sweat loss
            let sTrimp = wm.hr.isEmpty ? Computed<Double>.missing("no heart rate in this workout")
                : ALG036.trimp(hrMinutes: wm.hr, rhr: rhrV, hrmax: hrmaxV, sex: sex)
            let earlier = h.denseSeries0(Baselines.sessionTrimpPrefix + w.type, before: day, days: PipelineConstants.historyDays)
            let score = sTrimp.value == nil ? Computed<ALG036.SessionScore>.missing(sTrimp.missingReason ?? "no TRIMP")
                : ALG036.sessionLoadScore(trimp: sTrimp.value, history: earlier)
            out.append(PipelineSpecs.forWorkout(ALG036.loadScoreSpec, id8: w.id8).metric(
                score.map(\.percentile), at: at,
                note: score.value.map {
                    "of \($0.n) earlier \(w.type) days of yours" + ($0.z.map { String(format: "; z %.2f of ln TRIMP", $0) } ?? "")
                        + "; within you only, not a population rank"
                }))
            let mins0 = (w.end - w.start) / 60.0
            out.append(PipelineSpecs.forWorkout(ALG036.srpeSpec, id8: w.id8).metric(
                w.rpe == nil ? .missing("not rated yet: the app asks after the workout")
                    : ALG036.srpeLoad(rpe: w.rpe, minutes: mins0), at: at,
                note: w.rpe.map { "CR-10 rating \(String(format: "%.1f", $0)) x \(Int(mins0.rounded())) min" }))
            let drunk = Self.drinksMl(dayEvents, from: w.start, to: w.end).compactMap { $0 }.reduce(0, +)
            let sweat = ALG135.sweatLoss(preKg: w.preKg, postKg: w.postKg, drinkMl: drunk)
            if w.preKg == nil && w.postKg == nil {
                out.append(PipelineSpecs.forWorkout(ALG135.sweatSpec, id8: w.id8).blank(
                    "log your weight before and after to get a sweat-loss estimate", at: at))
            } else {
                out.append(PipelineSpecs.forWorkout(ALG135.sweatSpec, id8: w.id8).metric(
                    sweat.map(\.sweatMl), at: at,
                    note: sweat.value.map { _ in "weights before and after + \(Int(drunk.rounded())) ml logged during; estimate" }))
            }
            if let t = sTrimp.value { sessionTrimp[w.type, default: 0] += t }
            if let s = sweat.value { sweatMlToday += s.sweatMl; sweatMinToday += mins0 }
            // ALG-012 HR recovery after the logged end (wave 1): HRR at 60 s and the tail's tau
            let tail = PipelineStreams.hr(inp.hr, w.end - Double(ALG012Recovery.eligibilityLookbackS) - 1,
                                          w.end + Double(ALG012Recovery.tauWindowS) + 60)
            let hrr = ALG012Recovery.recovery(tail, endTs: Int64(w.end.rounded(.down)), hrmax: hrmaxV)
            out.append(PipelineSpecs.forWorkout(ALG012Recovery.hrr60Spec, id8: w.id8).metric(
                hrr.map(\.hrr60), at: at, note: hrr.value.map { "peak \(Int($0.peak.rounded())) bpm" }))
            out.append(PipelineSpecs.forWorkout(ALG012Recovery.hrr120Spec, id8: w.id8).metric(
                hrr.flatMap { $0.hrr120 }, at: at, note: hrr.value.map { "peak \(Int($0.peak.rounded())) bpm" }))
            out.append(PipelineSpecs.forWorkout(ALG012Recovery.tauSpec, id8: w.id8).metric(
                hrr.flatMap { $0.tau.map(\.tau) }, at: at,
                note: hrr.value?.tau.value.map {
                    "research estimate: wrist 1 Hz HR over a 180 s tail (Imai 1994 used beat-by-beat ECG over 30 s); "
                        + "started from \(Int($0.startHR.rounded())) bpm; compare only within the same workout type"
                }))
        }

        // r9p carries: one TRIMP per session type and day, and the day's sweat ml / minutes for the sweat rate
        for (type, v) in sessionTrimp.sorted(by: { $0.key < $1.key }) {
            series.append(PipelineOutput.carry(Baselines.sessionTrimpPrefix + type, variant: "ALG-036", start: Int64(ds),
                                               stepS: 86_400, value: v, unit: "au", tier: .estimate))
        }
        if sweatMinToday > 0 {
            series.append(PipelineOutput.carry(Baselines.sweatMlDay, variant: "ALG-135", start: Int64(ds), stepS: 86_400,
                                               value: sweatMlToday, unit: "ml", tier: .estimate))
            series.append(PipelineOutput.carry(Baselines.sweatMinDay, variant: "ALG-135", start: Int64(ds), stepS: 86_400,
                                               value: sweatMinToday, unit: "min", tier: .estimate))
        }
        // ALG-135 sweat rate, D-POP-PRIOR: the population value alone until sessions with both weights are logged
        let sweatMlHist = h.denseSeries0(Baselines.sweatMlDay, before: day, days: PipelineConstants.historyDays)
        let sweatMinHist = h.denseSeries0(Baselines.sweatMinDay, before: day, days: PipelineConstants.historyDays)
        var sweatDays: [(sweatMl: Double, minutes: Double)] = []
        for (ml, mn) in zip(sweatMlHist, sweatMinHist) {
            if let ml, let mn { sweatDays.append((sweatMl: ml, minutes: mn)) }
        }
        if sweatMinToday > 0 { sweatDays.append((sweatMl: sweatMlToday, minutes: sweatMinToday)) }
        out.append(ALG135.sweatRateMetric(ALG135.sweatRate(sessions: sweatDays), at: at))

        // ---- calories (G-CAL)
        let cal = ALG048.activeCalories(hrTs: ints(dayHR.map(\.ts)), hrBpm: dayHR.map(\.bpm), rhr: rhrV, hrmax: hrmaxV,
                                        weightKg: weight, heightCm: height, age: ageV, sex: sex, windowMinutes: 1440, flexBpm: flexBpm,
                                        bmrKcalDay: bmrScan)
        out.append(HRClean.tag(ALG048.keytelSpec, hrm).metric(cal.map(\.activeKcal), at: at,
                                                              note: flexNote + "; " + restNote + "; high end of the range (heart rate alone)"))
        let calLow = ALG048.activeCalories(hrTs: ints(dayHR.map(\.ts)), hrBpm: dayHR.map(\.bpm), rhr: rhrV, hrmax: hrmaxV,
                                           weightKg: weight, heightCm: height, age: ageV, sex: sex, windowMinutes: 1440,
                                           flexBpm: flexBpm, movingMinutes: movingMinutes, bmrKcalDay: bmrScan)
        out.append(HRClean.tag(ALG048.keytelMotionSpec, hrm).metric(
            haveMotion ? calLow.map(\.activeKcal) : .missing("no strap motion for this day"), at: at,
            note: "low end of the range: only minutes where heart rate and the strap's motion agree; " + flexNote + "; " + restNote))
        // Bug 7 (Mo 2026-10-14: "no metric waits on one optional input"): the with-VO2max Keytel equation takes WHOOP's /
        // Apple's VO2max when one is imported or measured (newest in the history window), else the HR-ratio estimate
        // (Uth 2004: 15.3 x HRmax / HRrest, an estimate). It used to be a hard-coded blank waiting for a waist circumference.
        let vo2ForCalories = Self.vo2maxForCalories(day: day, history: h, dayEvents: dayEvents, hrmax: hrmaxV, rhr: rhrV)
        let uth = ALG036.uthVO2max(hrmax: hrmaxV, rhr: rhrV)
        out.append(ALG036.vo2maxUthSpec.metric(uth, at: at, note: "estimate: 15.3 x HRmax / HRrest (Uth 2004)"))
        let calVO2 = ALG048.activeCalories(hrTs: ints(dayHR.map(\.ts)), hrBpm: dayHR.map(\.bpm), rhr: rhrV, hrmax: hrmaxV,
                                           weightKg: weight, heightCm: height, age: ageV, sex: sex,
                                           vo2max: vo2ForCalories?.value, windowMinutes: 1440, flexBpm: flexBpm,
                                           bmrKcalDay: bmrScan)
        out.append(HRClean.tag(ALG048.keytelVO2Spec, hrm).metric(vo2ForCalories == nil
            ? .missing("no VO2max: none imported or measured, and the HR-ratio estimate needs resting HR and max HR")
            : calVO2.map(\.activeKcal), at: at, note: vo2ForCalories.map { "VO2max used: " + $0.label + "; " + flexNote }))
        let appleCal = Self.healthDayPick(dayEvents, type: hkActive, unit: "kcal")
        out.append(PipelineSpecs.caloriesApple.metric(appleCal.map { Computed.success($0.value) }
            ?? .missing("no Apple Health active energy for this day"), at: at, note: appleCal?.note))
        out.append(ALG048.mifflinSpec.metric(ALG048.mifflinBMR(weightKg: weight, heightCm: height, age: ageV, sex: sex),
                                             at: at))
        if bmrScan != nil {
            out.append(ALG048.cunninghamSpec.metric(cunningham, at: at,
                                                    note: "from scan: " + restNote.replacingOccurrences(of: "resting energy: ", with: "")))
        }

        // ---- steps (G-STEPS): strap ticks need a calibration against iPhone steps (ALG-040, 7 days)
        // Bug 19: one source's total by the PC's rule (WHOOP > Apple Watch > other wearable > iPhone > app); a Watch count is
        // written under the Watch member (variant apple_watch), anything else under "apple" (labelled iPhone in the groups).
        let stepPick = healthDayPick(dayEvents, type: hkSteps, unit: "count")
        let appleSteps = stepPick?.value
        let stepNote = stepPick?.note
        let watchWon = stepPick.map { $0.rank == 1 } ?? false
        out.append(PipelineSpecs.stepsApple.metric(
            (watchWon ? nil : appleSteps).orMissing(watchWon ? "this day's count came from the Apple Watch (see the Apple Watch member)"
                                                    : "no Apple Health step count for this day"),
            at: at, note: watchWon ? nil : stepNote))
        out.append(PipelineSpecs.stepsAppleWatch.metric(
            (watchWon ? appleSteps : nil).orMissing("this day's count did not come from the Apple Watch"),
            at: at, note: watchWon ? stepNote : nil))
        // r9o (D-LOAD-WALK-1 item 12): strap steps are off while the strap is worn away from the wrist (WearPolicy): the day's
        // ticks, the calibration days and the wrist-walking model all leave those stretches out. The phone's steps are untouched.
        let allEvents = h.events.values.flatMap { $0 }
        let offSpans = WearPolicy.stepsOffSpans(events: allEvents, from: ds, to: end)
        let samples = inp.r18.filter { Double($0.ts) >= ds && Double($0.ts) < end }.compactMap { r -> ALG040.StepSample? in
            r.steps.map { ALG040.StepSample(ts: Int(r.ts), counter: $0, activityClass: r.activityClass) }
        }
        let stepOff: (Int) -> Bool = { WearPolicy.inside(Double($0), offSpans) }
        let ticks = ALG040.ticks(samples, excluding: offSpans.isEmpty ? nil : stepOff)
        if let tk = ticks.value {
            series.append(PipelineOutput.carry(Baselines.stepTicksDay, variant: "strap", start: Int64(ds), stepS: 86_400,
                                               value: Double(tk.ticks), unit: "ticks", tier: .strap))
        }
        // Reference per day: the phone's own iPhone steps, else the imported Apple Health total (wave 2, 2026-10-11:
        // HealthKit is off in this build, so imported steps are the only reference most days have).
        var calib: [ALG040.TicksDay] = []
        var fromImport = 0
        for k in 1...PipelineConstants.chronoDays {
            let d = day.adding(days: -k)
            guard let tk = h.series0(Baselines.stepTicksDay, on: d) else { continue }
            // a day with any stretch away from the wrist is not a wrist-calibration day (its ticks are for another place)
            if !WearPolicy.stepsOffSpans(events: allEvents, from: Double(clock.dayStart(d)),
                                         to: Double(clock.dayStart(d.adding(days: 1)))).isEmpty { continue }
            if let ref = h.value("steps", variant: "apple", on: d) ?? h.value("steps", variant: "apple_watch", on: d) {
                calib.append(ALG040.TicksDay(ticks: tk, referenceSteps: ref))
            } else if let ref = inp.importedSteps[d] {
                calib.append(ALG040.TicksDay(ticks: tk, referenceSteps: ref))
                fromImport += 1
            }
        }
        let fit = ALG040.fitTicksPerStep(days: calib)
        let calNote = fit.value.map { f in
            "calibrated on \(f.days) day(s); reference = iPhone steps, else imported Apple Health steps "
                + "(\(fromImport) of the \(calib.count) candidate days were imported)"
        }
        out.append(ALG040.spec.metric(fit.flatMap { f in
            ALG040.steps(fromTicks: ticks.value.map { Double($0.ticks) }, ticksPerStep: f.ticksPerStep).map { Double($0) }
        }, at: at, note: calNote))

        // ---- merged steps (G-STEPS "merged"): the phone per minute window; the 100 Hz wrist model (enhanced tier) or the
        // calibrated step counter (base tier) fills the minutes the phone missed (StepsMerge, D-LOAD-WALK-2)
        var strapMinutes: [Int: StepsMerge.StrapMinute] = [:]
        let covered = WristWalking.coveredMinutes(inp.motion, origin: ds)
        for (m, v) in WristWalking.stepsByMinute(inp.motion, origin: ds) where covered.contains(m) {
            strapMinutes[m] = StepsMerge.StrapMinute(steps: v, kind: .wrist100Hz)
        }
        if let f = fit.value, f.ticksPerStep >= 0.5 {
            for (m, t) in ALG040.ticksByBucket(samples, origin: Int(ds), bucketS: 60) where !covered.contains(m) {
                strapMinutes[m] = StepsMerge.StrapMinute(steps: Double(t) / f.ticksPerStep, kind: .counter)
            }
        }
        let phoneSamples = (stepPick.map { healthSamples(dayEvents, type: hkSteps, unit: "count", source: $0.source) } ?? [])
            .map { StepsMerge.Sample(start: $0.start, end: $0.end, steps: $0.steps) }
        let merged = StepsMerge.merge(phone: phoneSamples, phoneSource: stepPick?.source, strap: strapMinutes,
                                      strapOff: StepsMerge.minutes(overlapping: offSpans, origin: ds), origin: ds,
                                      calibrationDays: fit.value?.days)
        out.append(PipelineSpecs.stepsMerged.metric(merged.map { $0.total.rounded() }, at: at, note: merged.value.map(StepsMerge.note)))

        // ---- VO2max and Fitness Age (G-VO2, research: the activity index scale is unconfirmed)
        var activeDays = Set<LocalDay>()
        var activeMin = 0.0
        for k in 0...6 {
            let d = day.adding(days: -k)
            for w in loggedWorkouts(k == 0 ? dayEvents : h.eventsOn(d)) {
                activeDays.insert(d)
                activeMin += (w.end - w.start) / 60.0
            }
        }
        let woHR = inp.recentWorkoutHR + wos.flatMap { w in PipelineStreams.hr(inp.hr, w.start, w.end) }
        var highShare: Double?
        if let mx = hrmaxV, !woHR.isEmpty {
            highShare = Double(woHR.filter { $0.bpm >= ALG106.zoneFractions[3] * mx }.count) / Double(woHR.count)
        } else if activeDays.isEmpty {
            highShare = 0
        }
        let pa = ALG036.paIndexV0(activeDays: Double(activeDays.count),
                                  avgActiveMin: activeDays.isEmpty ? 0 : activeMin / Double(activeDays.count),
                                  highIntensityFraction: highShare)
        // Waist: the newest body-composition entry with one (Log › More › Scan; tracker #42, 2026-10-11) among the
        // events the pipeline holds (the history window). It used to be `waistCm: nil` (always blank).
        let waist = BodyComposition.latestWaist(in: h.events.values.flatMap { $0 }, upTo: Date(timeIntervalSince1970: end))
        let nesV = ALG036.nesVO2max(age: ageV, sex: sex, rhr: rhrV, paIndex: pa.value, waistCm: waist)
        out.append(ALG036.vo2maxSpec.metric(nesV.map(\.vo2max), at: at))
        out.append(PipelineSpecs.vo2Apple.metric(healthLatest(dayEvents, type: hkVO2, unit: "mL/(kg*min)")
            .orMissing("no Apple Health VO2max sample for this day"), at: at))
        // ALG-133 v2 (D-LOAD-WALK-1 item 8): Nes's Fitness Age = the age at which a typical healthy person of your sex has your
        // VO2max. The VO2max is the Nes non-exercise estimate when it can be computed (needs a waist), else the HR-ratio estimate
        // (Uth 2004); the note says which.
        let faSource: (vo2: Double, label: String)? = nesV.value.map { ($0.vo2max, "Nes 2011 non-exercise estimate") }
            ?? uth.value.map { ($0, "HR-ratio estimate (Uth 2004)") }
        let fa = ALG133.fitnessAge(vo2max: faSource?.vo2, sex: sex, age: ageV)
        out.append(ALG133.spec.metric(faSource == nil ? .missing("needs a VO2max: the Nes estimate needs a waist and the HR-ratio "
                                                                  + "estimate needs resting HR and max HR") : fa.map(\.fitnessAge),
                                      at: at, note: faSource.map { src in
            "estimate (Nes's definition: the age at which a typical healthy person of your sex has your VO2max, HUNT3 reference); "
                + String(format: "VO2max %.1f from the ", src.vo2) + src.label
                + (fa.value?.clamped == true ? "; clamped to 20-90" : "")
        }))

        // ---- vape timing (ALG-068 / ALG-069)
        let vt = ALG068.compute(wake: wake.map { Date(timeIntervalSince1970: $0) },
                                hits: BehaviourEvents.vapeHits(from: dayEvents),
                                dayStart: Date(timeIntervalSince1970: ds), dayEnd: Date(timeIntervalSince1970: de),
                                now: inp.now)
        out.append(ALG068.firstAfterWakeSpec.metric(
            vt.firstAfterWakeMin.orMissing(vt.reasons["first_after_wake_min"] ?? "no first hit"), at: at))
        // Bug 20 (Mo 2026-10-14, e-13 b): a day with nothing logged is not stored as 0 (the dashes and 0s mixed in one metric);
        // zero hits is blank with its reason. A count above 0 is stored as before.
        out.append(ALG069.vapeHitsSpec.metric(
            Self.loggedCount(vt.hitsDay, none: "no hit logged this day (stored blank, not 0: nothing logged is not the same as none)",
                             otherwise: vt.reasons["hits_day"] ?? "no day window"), at: at))

        // ---- tonight's need, debt, bedtime (ALG-115 v2, 2026-10-17). Strap nights only: a night that came from WHOOP's /
        // Apple's export is left out (D-SLEEP-WALK-1: no WHOOP cloud dependency), and WHOOP's own need / debt no longer
        // stand in. Need = mean TST of free nights, debt = net deficit over 14 nights; each is 'learning' on its own.
        func nightVal(_ d: LocalDay, _ name: String, _ variant: String) -> Double? {
            d == day ? t.value(name, variant: variant, window: "night", on: d)
                : h.value(name, variant: variant, window: "night", on: d)
        }
        func isImported(_ d: LocalDay, _ name: String, _ variant: String) -> Bool {
            let src = d == day ? t : h
            return src.importedDays(name, variant: variant, window: "night", among: [d]) == 1
        }
        /// A strap night's value (nil for an imported night).
        func strapNight(_ d: LocalDay, _ name: String, _ variant: String) -> Double? {
            isImported(d, name, variant) ? nil : nightVal(d, name, variant)
        }
        var free: [Double] = []
        for k in (0..<PipelineConstants.chronoDays).reversed() {
            let d = day.adding(days: -k)
            if let tst = strapNight(d, "sleep_total", "ALG-150"), clock.mustBeUp(inp.settings, on: d) == nil {
                free.append(tst)
            }
        }
        let needNotes: [String] = []
        let base = ALG115.baselineNeed(freeTstMin: free, settingMin: inp.settings.needOverrideMin)
        var slept: [Double?] = []
        for k in (0...13).reversed() {
            let d = day.adding(days: -k)
            let evs = d == day ? dayEvents : h.eventsOn(d)
            let napMin = confirmedNaps(evs).reduce(0.0) { $0 + ($1.end - $1.start) / 60.0 }
            slept.append(strapNight(d, "sleep_total", "ALG-150").map { $0 + napMin })
        }
        let napToday = naps.reduce(0.0) { $0 + ($1.end - $1.start) / 60.0 }
        let debt: Computed<ALG115.Debt> = base.flatMap { ALG115.debt(sleptMin: slept, needMin: $0.minutes) }
        let need: Computed<ALG115.NeedTonight> = base.map { ALG115.needTonight(baseMin: $0.minutes, napMin: napToday) }
        var planNotes: [String] = []
        let plan: Computed<ALG115.Plan> = need.flatMap { nd in
            var anchor: Computed<Double>
            var isMust = false
            if let m = clock.mustBeUp(inp.settings, on: day.adding(days: 1)) {
                anchor = .success(Double(m))
                isMust = true
            } else {
                let wakes = (0...13).reversed().compactMap { nightVal(day.adding(days: -$0), "wake_time", "ALG-030") }
                // T5: your last real wake (today's, else yesterday's; own or imported) before the 14-night median
                if let last = nightVal(day, "wake_time", "ALG-030") ?? nightVal(day.adding(days: -1), "wake_time", "ALG-030") {
                    anchor = ALG115.typicalWakeAnchor(recentWakes: [last, last, last],
                                                      utcOffsetSeconds: clock.offsetSeconds(at: now), after: now)
                    planNotes.append("wake anchor = your last wake (no 'must be up by' for tomorrow)")
                } else {
                    anchor = ALG115.typicalWakeAnchor(recentWakes: wakes, utcOffsetSeconds: clock.offsetSeconds(at: now),
                                                      after: now)
                    if anchor.value == nil, let last = wakes.last {
                        // fewer than 3 wakes: last night's wake time of day, next occurrence (said in the note)
                        anchor = ALG115.typicalWakeAnchor(recentWakes: [last, last, last],
                                                          utcOffsetSeconds: clock.offsetSeconds(at: now), after: now)
                        planNotes.append("wake anchor = last night's wake (fewer than 3 nights)")
                    }
                }
            }
            return anchor.flatMap { a in
                var effs = (0...13).reversed().compactMap { nightVal(day.adding(days: -$0), "sleep_efficiency", "ALG-150") }
                if effs.count < ALG115.planMinNights, !effs.isEmpty {
                    let e = SignalMath.median(effs)
                    effs = [e, e, e]
                    planNotes.append("efficiency \(Int((e * 100).rounded())) % from fewer than 3 nights")
                }
                let lats = (0...13).reversed().compactMap { nightVal(day.adding(days: -$0), "sleep_latency", "ALG-150") }
                return ALG115.planTonight(needMin: nd.needMin, wakeAnchor: a, anchorIsMustBeUp: isMust,
                                          efficiencies: effs, latenciesMin: lats)
            }.flatMap { p in
                // T9710/T9728: reject a stray daytime "tonight", but preserve real day sleep and a transition to a
                // newly scheduled day sleep. Each instant needs its own UTC offset across DST or a time-zone change.
                let onsets = (0...13).reversed().compactMap { nightVal(day.adding(days: -$0), "sleep_onset", "ALG-030") }
                func localSeconds(_ instant: Double) -> Double {
                    let local = Int64(instant.rounded(.down)) + Int64(clock.offsetSeconds(at: instant))
                    return Double(SleepMath.floorMod(local, 86_400))
                }
                guard ALG115.inSleepWindow(bedtimeLocalSeconds: localSeconds(p.bedtime),
                                           recentOnsetLocalSeconds: onsets.map(localSeconds),
                                           hasExplicitWakeSchedule: p.anchor == .mustBeUpBy) else {
                    return .missing("bedtime \(InsightMembers.hm(Int64(p.bedtime.rounded(.down)), clock: clock)) is outside tonight's sleep window "
                        + "(more than 6 h from your usual sleep onset); not used")
                }
                return .success(p)
            }
        }
        var m115 = ALG115.metrics(need: need, debt: debt, plan: plan, at: at)
        if let nd = need.value {
            var parts = ["need \(Self.hm(nd.needMin)) = usual \(Self.hm(nd.baselineMin))"
                         + (base.value?.freeNights.map { " (mean of \($0) free nights)" } ?? " (your setting)")]
            if nd.napCreditMin <= -1 { parts[0] += " − nap \(Self.hm(-nd.napCreditMin))" }
            if let p = plan.value { parts.append("\(Int((p.efficiencyUsed * 100).rounded())) % of time in bed asleep") }
            let note = (parts + needNotes + planNotes).joined(separator: "; ")
            for i in m115.indices where m115[i].value != nil { m115[i].note = note }
        }
        out += m115

        // ---- caffeine (ALG-060, G-CAFF)
        let prevEvents = h.eventsOn(day.adding(days: -1))
        let doses = BehaviourEvents.caffeineDoses(from: prevEvents + dayEvents)
        // r9t (D-POP-PRIOR): your half-life from the PC fit (ALG-062) when one is stored for today or yesterday, else the population 5 h.
        let caffParams = ALG062.halfLife(from: inp.stored + (h.metrics[day.adding(days: -1)] ?? [])).params
        out.append(ALG060.nowSpec.metric(ALG060.state(at: inp.now, doses: doses, params: caffParams).map(\.totalMg), at: inp.now))
        var bed: Computed<Double>
        if let p = plan.value {
            bed = .success(p.bedtime)
        } else {
            var tods: [Double] = []
            for k in (0...13).reversed() {
                if let on = nightVal(day.adding(days: -k), "sleep_onset", "ALG-030") {
                    let x = Int64(on.rounded(.down)) + Int64(clock.offsetSeconds(at: on))
                    let tod = Double(((x % 86_400) + 86_400) % 86_400)
                    tods.append(tod < 12 * 3600 ? tod + 86_400 : tod)
                }
            }
            bed = tods.count >= 3 ? .success(ds + SignalMath.median(tods))
                : .missing("no bedtime yet: needs a recommended bedtime (ALG-115) or 3 nights of sleep onset")
        }
        out.append(ALG060.bedtimeSpec.metric(bed.flatMap { b in
            ALG060.state(at: Date(timeIntervalSince1970: b), doses: doses, params: caffParams).map(\.totalMg)
        }, at: at))
        var mgs: [Double] = []
        for k in (1...13).reversed() {
            mgs += BehaviourEvents.caffeineDoses(from: h.eventsOn(day.adding(days: -k))).compactMap(\.mg).filter(\.isFinite)
        }
        mgs += BehaviourEvents.caffeineDoses(from: dayEvents).compactMap(\.mg).filter(\.isFinite)
        let nextMg = mgs.isEmpty ? nil : SignalMath.median(mgs)
        let cutoffSpecs: [String: MetricSpec] = [ALG126.variantProbabilistic: ALG061.cutoffSpec,
                                                 ALG126.variant33mg: ALG126.spec33mg,
                                                 ALG126.variantDrake: ALG126.specDrake]
        switch bed {
        case .failure(let m):
            for v in [ALG126.variantProbabilistic, ALG126.variant33mg, ALG126.variantDrake] {
                out.append(cutoffSpecs[v]!.blank(m.reason, at: at))
            }
        case .success(let b):
            let g = ALG126.group(doses: doses, now: inp.now, bedtime: Date(timeIntervalSince1970: b), nextMg: nextMg,
                                 params: caffParams)
            for member in g.members {
                let value: Computed<Double> = member.result.flatMap { c in
                    if c.outcome == .alreadyOver {
                        return .missing("already over the limit at bedtime: no more caffeine today")
                    }
                    return c.cutoffMinute.map { $0.timeIntervalSince1970 }.orMissing("no cut-off time")
                }
                if let spec = cutoffSpecs[member.variant] { out.append(spec.metric(value, at: at, note: member.label)) }
            }
        }

        // ---- alertness (ALG-051, UMP + caffeine), population parameters
        // `at` (= now, or the day's end when a past day is recomputed): the curve belongs to this day, not to today.
        out += alertnessMetrics(day: day, now: at, at: at, stored: t, history: h, doses: doses,
                                bedtime: bed.value, timeZone: inp.settings.timeZone, imported: inp.importedNights)

        // ---- reaction test (ALG-050): the day's latest PVT-B, as scored when it was taken (2026-10-11)
        let tests = dayEvents.compactMap { e -> (Date, ReactionTestFields)? in
            guard !e.removed, case .reactionTest(let f) = e.payload else { return nil }
            return (e.at, f)
        }
        if let (tAt, f) = tests.max(by: { $0.0 < $1.0 }) {
            out.append(ALG050.meanRtSpec.metric(.success(f.meanRtMs), at: tAt))
            if let l = f.lapses { out.append(ALG050.lapsesSpec.metric(.success(Double(l)), at: tAt)) }
        }

        // ---- daytime HRV and body arousal over still waking spans (ALG-010, ALG-054, ALG-123:daytime)
        let wrr = inp.rr.filter { waking(Double($0.ts)) }
        let stillRR = ALG054.stillPoints(wrr, activity: inp.r18)
        let wset = HRVWindows.analyse(points: stillRR, core: core)
        out += ALG010.daytimeMetrics(ALG010.nightly(wset), at: at)
        var exercise: [(Double, Double)] = wos.map { ($0.start, $0.end) }
        exercise += (detected.value ?? []).map { (Double($0.startTs), Double($0.endTs)) }
        let isExercise: (Int64) -> Bool = { start in
            let s = Double(start)
            return exercise.contains { s < $0.1 && s + HRVWindows.windowSeconds > $0.0 }
        }
        let todaySamples = ALG054.samples(wset, hourOf: { clock.hourOfDay($0) }, exercise: isExercise)
        let days54 = (1...PipelineConstants.stressDailyDays).map { day.adding(days: -$0) }
        let hist54 = ALG054.history(series: h.series, days: days54, hourOf: { clock.hourOfDay($0) })
        let own54 = ALG054.historyDays(series: h.series, days: days54)
        // D-POP-PRIOR (R9m): the baseline starts at the population value and moves to yours; the note says which.
        out.append(ALG054.spec.metric(ALG054.day(todaySamples, baseline: ALG054.baseline(history: hist54, days: own54)), at: at,
                                      note: "baseline: \(ALG054.basisLabel(days: own54) ?? "yours")"))
        // T31: daytime body arousal 0–3 against the last 14 days; windows in a workout or while the strap is flagged off the
        // wrist are not scored (T110)
        let days14 = (1...ALG123Daytime.baselineDays).map { day.adding(days: -$0) }
        let hist14 = ALG054.history(series: h.series, days: days14, hourOf: { clock.hourOfDay($0) })
        let own14 = ALG054.historyDays(series: h.series, days: days14)
        let dayStress = ALG123Daytime.day(wset, hourOf: { clock.hourOfDay($0) }, exercise: isExercise,
                                          baseline: ALG054.baseline(history: hist14, days: own14),
                                          offWrist: ALG123Daytime.offWristSpans(prevEvents + dayEvents, until: Int64(end)),
                                          inDaytime: { start in
                                              inp.settings.daytimeSpans.map { spans in
                                                  spans.contains { $0.start.timeIntervalSince1970 <= Double(start)
                                                      && Double(start) < $0.end.timeIntervalSince1970 }
                                              } ?? true
                                          })
        out.append(ALG123Daytime.spec.metric(dayStress.map(\.score), at: at, note: dayStress.value.map { d in
            "\(ALG123Daytime.band(d.score)); highest around \(InsightMembers.hm(d.peak.start, clock: clock)) ("
                + "\(d.windows.count) still 5-min windows" + (d.skippedOffWrist > 0 ? ", \(d.skippedOffWrist) skipped: strap flagged off wrist" : "")
                + "); baseline: \(ALG054.basisLabel(days: own14) ?? "yours"); physiological arousal estimate, not mood and not WHOOP's number"
        }))
        let awakeResp = awakeBreathing(rr: wrr, r18: inp.r18, from: w0, to: end, exercise: exercise, core: core)
        out.append(awakeResp.day)
        if let sr = awakeResp.series { series.append(sr) }
        // ALG-105 (wave 1): whoop-rs arousal-rise ("stress onset") replayed over today's waking R-R, workouts and naps cut out
        let onsetSpans = InsightMembers.wakingSpans(from: w0, to: end,
                                                    excluding: exercise + naps.map { ($0.start, $0.end) })
        let movingTs = inp.r18.filter { ($0.activityClass ?? 0) >= 1 }.map(\.ts)
        let onset = ALG105.replay(rrTs: inp.rr.map(\.ts), rrMs: inp.rr.map(\.rrMs), hrTs: inp.hr.map(\.ts),
                                  hrBpm: inp.hr.map(\.bpm), movingTs: movingTs, spans: onsetSpans)
        out.append(ALG105.spec.metric(Self.loggedCount(onset.value?.onsets.count, none: "no fresh HRV dip outside exercise over "
            + "\(onset.value?.evaluations ?? 0) checks (stored blank, not 0: none found is not the same as a measured 0)",
            otherwise: onset.missingReason ?? "no stress-onset replay"), at: at, note: onset.value.flatMap { o in
            o.onsets.isEmpty ? nil : "at " + o.onsets.map { InsightMembers.hm($0, clock: clock) }.joined(separator: ", ")
                    + "; the live nudge is not wired yet"
        }))
        var hr5 = [Double?](repeating: nil, count: 288)
        var ln5 = [Double?](repeating: nil, count: 288)
        for w in wset.cleanWindows where !isExercise(w.start) {
            guard let tm = w.time else { continue }
            let i = Int((Double(w.start) - ds) / 300)
            if i >= 0 && i < 288 {
                hr5[i] = 60_000.0 / tm.meanRR
                ln5[i] = tm.lnRmssd
            }
        }
        if hr5.contains(where: { $0 != nil }) {
            series.append(Series(name: Baselines.hr5min, unit: "bpm", start: Date(timeIntervalSince1970: ds), stepS: 300,
                                 values: hr5, variant: "ALG-054", tier: .estimate, computedOn: .phone))
            series.append(Series(name: Baselines.lnRmssd5min, unit: "ln_ms", start: Date(timeIntervalSince1970: ds),
                                 stepS: 300, values: ln5, variant: "ALG-054", tier: .estimate, computedOn: .phone))
        }

        // ---- minute activity of the day (ALG-030 regularity input), movement, naps
        let dayRows = inp.r18.filter { Double($0.ts) >= ds && Double($0.ts) < end }
        let grid = SleepMotionGrid.build(SleepSeconds(r18: dayRows, hrCleaning: hrm))
        if !grid.act.isEmpty {
            var act = [Double?](repeating: nil, count: 1440)
            let off = Int((Double(grid.t0) - ds) / 60)
            for (j, v) in grid.act.enumerated() where off + j >= 0 && off + j < 1440 { act[off + j] = v }
            if act.contains(where: { $0 != nil }) {
                series.append(Series(name: Baselines.motionMinute, unit: "deg_per_min",
                                     start: Date(timeIntervalSince1970: ds), stepS: 60, values: act, variant: "ALG-030",
                                     tier: .estimate, computedOn: .phone))
            }
        }
        let classed = dayRows.filter { $0.activityClass != nil }
        let movement = ALG044.movementSummary(ts: ints(classed.map(\.ts)), activityClass: classed.map { $0.activityClass! })
        var mainSleep: [SleepInterval] = []
        if let on = t.value("sleep_onset", variant: "ALG-030", window: "night", on: day), let w = wake {
            mainSleep.append(SleepInterval(start: on, end: w))
        }
        let nap033 = ALG033.candidates(grid: grid, exclude: mainSleep)
        let seated = ALG127.seatedBaseline(grid: grid, seconds: SleepSeconds(r18: dayRows), exclude: mainSleep)
        let nap127 = ALG127.candidates(grid: grid, seatedBpm: seated.map(\.bpm), exclude: mainSleep)

        // ---- curves, adherence, nicotine response
        let caffeineCurve = ALG060.curve(from: Date(timeIntervalSince1970: ds), to: Date(timeIntervalSince1970: de),
                                         step: 600, doses: doses, params: caffParams)
        var medCurve: Computed<[ALG143.Sample]> = .missing("no lisdexamfetamine dose logged")
        for name in lisdexNames(inp.settings.lisdexAliases) {
            let doses143 = BehaviourEvents.medicationDoses(from: prevEvents + dayEvents, named: name)
            if !doses143.isEmpty {
                medCurve = ALG143.curve(from: Date(timeIntervalSince1970: ds), to: Date(timeIntervalSince1970: de),
                                        step: 600, doses: doses143, pk: ALG143.lisdexamfetamineDAmphetamine)
                break
            }
        }
        var adherence: [String: Computed<ALG069.Adherence>] = [:]
        let weekday = PipelineClock.weekday(day)
        for sch in inp.settings.medSchedules {
            if let days = sch.days, !days.contains(weekday) { continue }
            let due: [Date] = (sch.times ?? []).compactMap { hm in
                let p = hm.split(separator: ":")
                guard p.count == 2, let hh = Double(p[0]), let mm = Double(p[1]) else { return nil }
                let ts = ds + hh * 3600 + mm * 60
                return ts <= now ? Date(timeIntervalSince1970: ts) : nil
            }
            adherence[sch.name] = ALG069.adherence(scheduled: due,
                                                   taken: BehaviourEvents.medicationTimes(from: dayEvents, named: sch.name))
        }
        let hits = BehaviourEvents.vapeHits(from: dayEvents).map(\.at)
        let nicotine = ALG063.response(hits: hits, hrTs: inp.hr.map(\.ts), hrBpm: inp.hr.map(\.bpm),
                                       rrTs: inp.rr.map(\.ts), rrMs: inp.rr.map(\.rrMs))

        // ---- wave 1: key points (ALG-132), Body Age (ALG-134), activity cost (ALG-136)
        // ---- wave W8: raw motion — ALG-113 ENMO and ALG-114 gait asymmetry for the day, CosinorAge's cosinor inputs
        out += RawMotion.dayMetrics(inp.motion, at: at)
        out += WristWalking.dayMetrics(wristMotion(inp.motion, offSpans), at: at)
        // T47: pulse-wave HR and breathing from the newest raw optical records, on ALG-015's block (the choice is the
        // default one, not established for every firmware); no optical records = no row.
        if !inp.r20.isEmpty {
            let spot = OpticalPulse.spot(records: inp.r20)
            out.append(OpticalPulse.hrMetric(spot, block: ALG015.block, at: at))
            out.append(OpticalPulse.breathingMetric(spot, block: ALG015.block, at: at))
        }
        let cosinorDays = (0...RawMotion.cosinorWindowDays).reversed().map { clock.dayStart(day.adding(days: -$0)) }
        let cosinor = RawMotion.cosinorFromSummaries(inp.motionWeek, dayStarts: Array(cosinorDays.dropLast()))
        out += InsightMembers.day(day: day, at: at, table: PipelineOutput.merge(inp.stored, out), history: h,
                                  dayEvents: dayEvents, profile: prof, age: age.value, rhr7: rhrV, paIndex: pa.value,
                                  cosinor: cosinor)

        // ---- Mo's script day members, then the morning members again (MS-20 reads the day's ATL / CTL)
        let wornMinutes = ALG036.perMinuteHR(ts: ints(dayHR.map(\.ts)), bpm: dayHR.map(\.bpm)).minuteTs.count
        let table = PipelineOutput.merge(inp.stored, out)
        let sd = ScriptDay(day: day, today: table, history: h, events: dayEvents, rr: inp.rr, hr: inp.hr, r18: inp.r18,
                           profile: prof, clock: clock)
        out += ScriptMembers.day(sd, at: at, wornMinutes: wornMinutes)
        if let wk = wake {
            let wakeAt = Date(timeIntervalSince1970: wk)
            let tempRaw = inp.storedSeries.first { $0.name == Baselines.skinTempNightRaw }?.values.first ?? nil
            let morning = MorningStage.compute(day: day, at: wakeAt, today: PipelineOutput.merge(inp.stored, out),
                                               history: h, tempRawTonight: tempRaw,
                                               extras: ALG161.NightExtras(series: inp.storedSeries))
            out += morning
            let sdm = ScriptDay(day: day, today: PipelineOutput.merge(inp.stored, out), history: h, events: dayEvents,
                                rr: inp.rr, hr: inp.hr, r18: inp.r18, profile: prof, clock: clock)
            out += ScriptMembers.morning(sdm, at: wakeAt, core: core)
        }

        let checked = PipelineOutput.checked(out)
        return DayResult(day: day, metrics: checked.metrics, series: series, detectedWorkouts: detected,
                         napCandidates: nap033, napCandidates127: nap127, movement: movement,
                         caffeineCurve: caffeineCurve, medicationCurve: medCurve, adherence: adherence,
                         nicotineResponse: nicotine, wornMinutes: wornMinutes, problems: checked.problems)
    }
}

// MARK: - G-HABIT (on demand for Explore)

/// One habit's effect on one outcome: every G-HABIT member side by side (ALG-067 Cohen's d first, ALG-125 the rest).
public struct HabitEffect: Sendable, Equatable {
    /// "caffeine", "alcohol", "vape", or "medication:<name>".
    public var habit: String
    /// The outcome metric read the NEXT night: "hrv_rmssd", "sleep_performance", "rhr".
    public var outcome: String
    public var group: ALG125.Group

    public init(habit: String, outcome: String, group: ALG125.Group) {
        self.habit = habit
        self.outcome = outcome
        self.group = group
    }
}

public enum HabitPipeline {
    static let outcomes: [(name: String, variant: String)] = [("hrv_rmssd", "ALG-010"), ("sleep_performance", "ALG-150"),
                                                              ("rhr", "ALG-012")]

    /// Days (last `days` up to `end`) with the habit vs logged days without it (ALG-067: unlogged days are NOT
    /// controls), outcome = the next night's value (stored on the next day, D13). Explore calls this on demand.
    public static func effects(history h: MetricHistory, end: LocalDay, days: Int = 60) -> [HabitEffect] {
        var habitsByDay: [LocalDay: Set<String>] = [:]
        var logged = Set<LocalDay>()
        for k in 0..<days {
            let d = end.adding(days: -k)
            let evs = h.eventsOn(d).filter { !$0.removed }
            if !evs.isEmpty { logged.insert(d) }
            for e in evs {
                switch e.payload {
                case .substance(let f) where f.kind == .caffeine || f.kind == .alcohol
                    || f.kind == .vapeTick || f.kind == .vape:
                    habitsByDay[d, default: []].insert(f.kind == .vapeTick ? "vape" : f.kind.rawValue)
                case .medication(let f) where f.status != .skipped:
                    if let n = f.name, !n.isEmpty { habitsByDay[d, default: []].insert("medication:\(n)") }
                default:
                    break
                }
            }
        }
        let habits = Set(habitsByDay.values.flatMap { $0 }).sorted()
        var out: [HabitEffect] = []
        for habit in habits {
            let withDays = Set(habitsByDay.filter { $0.value.contains(habit) }.keys.map(\.iso))
            let control = Set(logged.filter { !(habitsByDay[$0]?.contains(habit) ?? false) }.map(\.iso))
            for o in outcomes {
                var outcomeByDay: [String: Double] = [:]
                for d in logged {
                    if let v = h.value(o.name, variant: o.variant, window: "night", on: d.adding(days: 1)) {
                        outcomeByDay[d.iso] = v
                    }
                }
                let split = ALG067.splitDays(withDays: withDays, controlDays: control, outcomeByDay: outcomeByDay)
                out.append(HabitEffect(habit: habit, outcome: o.name, group: ALG125.group(with: split.with,
                                                                                          without: split.without)))
            }
        }
        return out
    }
}
