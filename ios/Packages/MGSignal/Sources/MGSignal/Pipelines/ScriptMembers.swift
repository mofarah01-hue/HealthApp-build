import Foundation
import MGDomain

// WP-22 — Mo's script members on the phone (ARCHITECTURE 8.1 / 8.2). The Swift ports (Script/, WP-17) only compute;
// this file builds their inputs EXACTLY as the PC builds them for the fixed script (app/pclab/mglab/ms_inputs.py,
// builders build_ms01 … build_ms22, and ms_runner.py `_day_aggregate`), so the PC's receipt check ("disagreements")
// compares like with like. Every "ours v0" adapter choice lives in ms_inputs.py and is copied here, not re-decided.
// One departure, decided by main (2026-10-11): a WORN day without a workout writes a real MS-01 / MS-02 day load of 0
// (MS-03 needs 28 daily values and never invents one); an unworn day writes a blank.
// MS-30 / MS-31 are not called: they need PPG pulse-shape features that do not exist yet (Script README).
// Goldens: app/shared/golden/pipelines/PIPE-*.json, MS members produced by the PC runner itself.
// WRITTEN, NOT COMPILED.

/// The day as the script adapters see it (ms_inputs.DayData): the day's table (summary order), earlier days, the
/// streams of the run, the day's events and the profile.
public struct ScriptDay: Sendable {
    public var day: LocalDay
    public var today: [Metric]
    public var history: MetricHistory
    /// Events of `day` (the PC's events.jsonl of the date). Earlier days' events come from `history.events`.
    public var events: [EventRecord]
    public var rr: [RRPoint]
    public var hr: [HRPoint]
    public var r18: [R18Second]
    public var profile: Profile?
    public var clock: PipelineClock

    public init(day: LocalDay, today: [Metric], history: MetricHistory, events: [EventRecord], rr: [RRPoint],
                hr: [HRPoint], r18: [R18Second], profile: Profile?, clock: PipelineClock) {
        self.day = day
        self.today = today
        self.history = history
        self.events = events
        self.rr = BeatClock.sorted(rr)
        self.hr = hr.sorted { $0.ts < $1.ts }
        self.r18 = r18.sorted { $0.ts < $1.ts }
        self.profile = profile
        self.clock = clock
    }

    // MARK: summary values (DayData.metric / history_values / baseline)

    public func metric(_ name: String, variant: String? = nil, window: String? = nil,
                       on date: LocalDay? = nil) -> Computed<Double> {
        let d = date ?? day
        let rows: [Metric]
        if d == day {
            rows = today
        } else {
            // W10 (2026-10-11): an earlier day the app has no value for may have WHOOP's / Apple's imported one; the
            // script's baselines count it (MetricHistory.importedValue: same name, unit and window only).
            let own = history.metrics[d]?.first { $0.name == name && (variant == nil || $0.variant == variant)
                && (window == nil || $0.window == window) }
            if own?.value?.isFinite != true,
               let v = history.importedValue(name, variant: variant, window: window, on: d) { return .success(v) }
            guard let r = history.metrics[d] else { return .missing("no stored summary for \(d)") }
            rows = r
        }
        let label = name + (variant.map { " (\($0))" } ?? "")
        var cands = rows.filter { $0.name == name && (variant == nil || $0.variant == variant) }
        if cands.isEmpty { return .missing("\(label) is not in the \(d) summary") }
        if let window {
            let good = cands.filter { $0.window == window }
            if good.isEmpty {
                return .missing("\(label) is a '\(cands[0].window ?? "")' value in the \(d) summary, not '\(window)'")
            }
            cands = good
        }
        let m = cands[0]
        if let v = m.value, v.isFinite { return .success(v) }
        let why = (m.note ?? "").trimmingCharacters(in: .whitespaces)
        return .missing("\(label) is blank in the \(d) summary" + (why.isEmpty ? "" : " (\(String(why.prefix(90))))"))
    }

    /// Values of the `days` days ending `startOffset` days before `day`, oldest first.
    func historyValues(_ name: String, _ variant: String?, _ window: String?, days: Int, startOffset: Int) -> [Double?] {
        guard days > 0 else { return [] }
        return (0..<days).reversed().map { j in
            metric(name, variant: variant, window: window, on: day.adding(days: -(startOffset + j))).value
        }
    }

    /// ms_inputs.min_days: ceil(0.7 × window) → 7:5, 14:10, 28:20, 90:63.
    static func minDays(_ window: Int) -> Int { Int((0.7 * Double(window) - 1e-9).rounded(.up)) }

    func baseline(_ label: String, _ name: String, _ variant: String?, _ window: String?, days: Int,
                  includeToday: Bool = false) -> Computed<[Double]> {
        let good = historyValues(name, variant, window, days: days, startOffset: includeToday ? 0 : 1).compactMap { $0 }
        let need = ScriptDay.minDays(days)
        if good.count < need { return .missing("\(label) needs \(need) of the last \(days) days (have \(good.count))") }
        return .success(good)
    }

    // MARK: streams

    /// HR values with a ≤ ts ≤ b (every stored sample, as the PC's hr stream: off-wrist 0s included).
    func hrBetween(_ a: Double, _ b: Double) -> [Double] {
        hr.filter { Double($0.ts) >= a && Double($0.ts) <= b }.map(\.bpm)
    }

    func sleepWindow() -> Computed<(on: Double, wake: Double)> {
        let on = metric("sleep_onset", window: "night")
        let wk = metric("wake_time", window: "night")
        var bad: [String] = []
        if let r = on.missingReason { bad.append("sleep_onset: \(r)") }
        if let r = wk.missingReason { bad.append("wake_time: \(r)") }
        guard bad.isEmpty, let o = on.value, let w = wk.value else {
            return .missing("sleep window unknown (" + bad.joined(separator: "; ") + ")")
        }
        guard w > o else { return .missing("sleep window unknown (wake_time is not after sleep_onset)") }
        return .success((on: o, wake: w))
    }

    struct NightRR {
        var rr: [Double]
        var times: [Double]
        var spanS: Double
        var coverage: Double
        var correctedFraction: Double
        var runs: Int
        /// P9744: every run (not only the longest), for MS-21, which stages an epoch wherever 30 beats in the last 5 min
        /// exist. Mo's Oct 12 night: R-R in 95 % of its epochs but a 70-min longest run of 431.
        var allRR: [Double] = []
        var allTimes: [Double] = []
        var coveredS: Double = 0
        var coveredCoverage: Double = 0
    }

    /// ms_inputs._night_rr: R-R in [on, wake] after ALG-004 A, the longest contiguous run (a run ends where the beat
    /// clock re-anchored: t[i] − t[i−1] − rr[i] / 1000 > 2 s).
    func nightRR(_ sw: (on: Double, wake: Double)) -> Computed<NightRR> {
        guard !rr.isEmpty else { return .missing("no rr stream for this date") }
        let pts = PipelineStreams.rr(rr, sw.on, sw.wake)
        guard pts.count >= 3 else { return .missing("the rr stream has no beats inside the sleep window") }
        let rrs = pts.map(\.rrMs)
        let art = ALG004.correct(rrMs: rrs, times: BeatClock.times(ts: pts.map(\.ts), rrMs: rrs))
        let t = art.times
        let r = art.rrMs
        guard !t.isEmpty else { return .missing("no valid R-R inside the sleep window") }
        var runs: [(Int, Int)] = []
        var start = 0
        for i in 1..<max(1, t.count) where t[i] - t[i - 1] - r[i] / 1000.0 > 2.0 {
            runs.append((start, i))
            start = i
        }
        runs.append((start, t.count))
        var best = runs[0]
        for run in runs.dropFirst() where t[run.1 - 1] - t[run.0] > t[best.1 - 1] - t[best.0] { best = run }
        let span = t[best.1 - 1] - t[best.0] + r[best.0] / 1000.0
        let covered = runs.reduce(0.0) { $0 + t[$1.1 - 1] - t[$1.0] + r[$1.0] / 1000.0 }
        return .success(NightRR(rr: Array(r[best.0..<best.1]), times: Array(t[best.0..<best.1]), spanS: span,
                                coverage: min(1.0, span / (sw.wake - sw.on)),
                                correctedFraction: art.correctedFraction, runs: runs.count,
                                allRR: r, allTimes: t, coveredS: covered,
                                coveredCoverage: min(1.0, covered / (sw.wake - sw.on))))
    }

    struct NightHRV {
        var rmssd: Double
        var lnRmssd: Double
        var windowsClean: Int
        var coverage: Double
        var lf: Double?
        var hf: Double?
        var freqProblem: String?
    }

    /// ms_inputs._night_hrv: WP-08's nightly ALG-010 / ALG-011 on the sleep window's R-R.
    func nightHRV(_ sw: (on: Double, wake: Double), core: any SignalCore) -> Computed<NightHRV> {
        let pts = PipelineStreams.rr(rr, sw.on, sw.wake)
        guard pts.count >= 3 else { return .missing("no rr stream beats inside the sleep window") }
        let ws = HRVWindows.analyse(points: pts, core: core)
        let tm = ALG010.nightly(ws)
        guard let n = tm.value else { return .missing("nightly RMSSD from the rr stream: " + (tm.missingReason ?? "")) }
        let fr = ALG011.nightly(ws)
        let cov = Double(n.windowsClean) * HRVWindows.windowSeconds / (sw.wake - sw.on)
        return .success(NightHRV(rmssd: n.rmssd, lnRmssd: n.lnRmssd, windowsClean: n.windowsClean,
                                 coverage: min(1.0, cov), lf: fr.value?.lf, hf: fr.value?.hf,
                                 freqProblem: fr.missingReason))
    }

    /// ms_inputs.window_label: "night" when the data covers ≥ 70 % of the sleep window, else the minutes it covers
    /// (Python round = half to even).
    static func windowLabel(_ coverage: Double?, _ spanS: Double) -> String {
        if let coverage, coverage >= 0.7 { return "night" }
        return "\(Int((spanS / 60.0).rounded(.toNearestOrEven)))min"
    }

    /// ms_inputs.night_value: the day's nightly value, else recomputed from the stream.
    func nightValue(_ lnForm: Bool, _ sw: Computed<(on: Double, wake: Double)>, core: any SignalCore) -> Computed<Double> {
        let name = lnForm ? "hrv_ln_rmssd" : "hrv_rmssd"
        let v = metric(name, window: "night")
        if v.value != nil { return v }
        guard let w = sw.value else { return .missing("\(v.missingReason ?? ""); and \(sw.missingReason ?? "")") }
        let hv = nightHRV(w, core: core)
        guard let h = hv.value else { return .missing("\(v.missingReason ?? ""); and \(hv.missingReason ?? "")") }
        return .success(lnForm ? h.lnRmssd : h.rmssd)
    }

    // MARK: profile

    /// Whole years on the day (ms_inputs.age).
    func age() -> Computed<Double> {
        guard let b = profile?.birthDate else {
            return .missing("profile.birth_date is not set (no profile, or the field is empty)")
        }
        let years = day.year - b.year - ((day.month, day.day) < (b.month, b.day) ? 1 : 0)
        return .success(Double(years))
    }

    func sexIsMale() -> Computed<Bool> {
        switch profile?.sex {
        case .male: return .success(true)
        case .female: return .success(false)
        case .other: return .missing("profile.sex is 'other': the Banister coefficients exist for male and female only")
        case nil: return .missing("profile.sex is not set (no profile, or the field is empty)")
        }
    }

    func weightKg() -> Computed<Double> {
        if let w = profile?.weightKg { return .success(w) }
        var best: (Date, Double)?
        for e in events where !e.removed {
            guard case .healthkit(let f) = e.payload, f.hkType.contains("BodyMass"), f.unit == "kg",
                  let v = f.value?.number, v.isFinite else { continue }
            if best == nil || e.at >= best!.0 { best = (e.at, v) }
        }
        if let b = best { return .success(b.1) }
        return .missing("profile.weight_kg is not set; no Health body-mass sample in the day's events either")
    }

    /// Measured HRmax (the day's table, then the profile) else the table's Tanaka, else Tanaka from the whole-year age.
    func hrmax() -> Computed<Double> {
        if let v = metric("hrmax", variant: "ALG-106:measured").value { return .success(v) }
        if let p = profile?.hrMaxMeasured { return .success(p) }
        if let v = metric("hrmax", variant: "ALG-106:tanaka").value { return .success(v) }
        let a = age()
        guard let years = a.value else { return .missing("no measured HRmax and no age for Tanaka (\(a.missingReason ?? ""))") }
        return .success(208.0 - 0.7 * years)
    }

    // MARK: events

    struct Workout {
        var event: EventRecord
        var end: Date
        var fields: WorkoutFields
    }

    func workouts() -> [Workout] {
        events.compactMap { e -> Workout? in
            guard !e.removed, case .workout(let f) = e.payload else { return nil }
            return Workout(event: e, end: f.end, fields: f)
        }.sorted { $0.event.at < $1.event.at }
    }

    struct WorkoutHR {
        var bpm: [Double]
        var stepS: Double
        var coverage: Double
    }

    /// ms_inputs.workout_hr: the hr stream if it covers ≥ 80 % of the window, else the event's own workout_hr series.
    func workoutHR(_ w: Workout) -> Computed<WorkoutHR> {
        let t0 = w.event.at.timeIntervalSince1970
        let t1 = w.end.timeIntervalSince1970
        let dur = t1 - t0
        guard dur > 0 else { return .missing("the workout's end is not after its start") }
        var options: [WorkoutHR] = []
        let vals = hrBetween(t0, t1)
        if !vals.isEmpty { options.append(WorkoutHR(bpm: vals, stepS: 1.0, coverage: min(1.0, Double(vals.count) / dur))) }
        for s in w.fields.series ?? [] where s.name == "workout_hr" && !s.values.isEmpty && s.stepS.isFinite {
            let s0 = s.start.timeIntervalSince1970
            let v = s.values.compactMap { $0 }.filter(\.isFinite)
            let span = Double(s.values.count) * s.stepS
            let overlap = max(0.0, min(t1, s0 + span) - max(t0, s0))
            options.append(WorkoutHR(bpm: v, stepS: s.stepS,
                                     coverage: min(1.0, overlap * Double(v.count) / Double(max(1, s.values.count)) / dur)))
        }
        guard var best = options.first else {
            return .missing("no HR stream rows and no workout_hr series inside the workout")
        }
        for o in options.dropFirst() where o.coverage > best.coverage { best = o }
        if best.coverage < 0.8 {
            return .missing("HR covers \(Int((best.coverage * dur / 60).rounded())) of \(Int((dur / 60).rounded())) min "
                            + "of the workout (needs 80%; ours v0)")
        }
        return .success(best)
    }

    /// ms_inputs.events_between: non-removed events of `type` with t0 ≤ at < t1 from this day and the day before.
    func eventsBetween(_ t0: Double, _ t1: Double, type: EventType) -> Computed<[EventRecord]> {
        var found: [EventRecord] = []
        for off in 0...1 {
            let d = day.adding(days: -off)
            let ds = Double(clock.dayStart(d))
            if ds + 86_400 <= t0 || ds >= t1 { continue }
            let evs: [EventRecord]
            if off == 0 {
                evs = events
            } else {
                guard let h = history.events[d] else { return .missing("the events of \(d) are not loaded") }
                evs = h
            }
            found += evs.filter { e in
                let t = e.at.timeIntervalSince1970
                return e.type == type && !e.removed && t >= t0 && t < t1
            }
        }
        return .success(found)
    }
}

/// The phone-tier script members (MS-01 … 07, 15, 18 … 22).
public enum ScriptMembers {
    static let v0 = "ours v0"

    /// One script call's arguments: values, or named missing inputs (ms_inputs.Args).
    struct Args {
        var missing: [String] = []
        var notes: [String] = []

        mutating func miss(_ name: String, _ reason: String) { missing.append("\(name): \(reason)") }

        mutating func need<T>(_ name: String, _ c: Computed<T>) -> T? {
            switch c {
            case .success(let v): return v
            case .failure(let m):
                missing.append("\(name): \(m.reason)")
                return nil
            }
        }

        var reason: String { "missing: " + missing.joined(separator: "; ") }
    }

    static func spec(_ id: String, _ output: String, _ window: String, source: String = "streams") -> MetricSpec {
        // Every phone-tier output is a registry name (MSCatalogue); the force-unwrap would only fail on a catalogue
        // typo, which MSGoldenTests and PipelineRuleTests would catch first.
        MSCatalogue.spec(id, output: output, window: window, tier: .estimate, source: source)!
    }

    static func emit(_ id: String, _ output: String, _ window: String, _ value: Computed<Double>, at: Date,
                     args: Args, coverage: Double? = nil, note: String? = nil) -> Metric {
        let s = spec(id, output, window)
        if !args.missing.isEmpty { return s.blank(args.reason, at: at) }
        let notes = (args.notes + [note].compactMap { $0 }).filter { !$0.isEmpty }
        return s.metric(value, at: at, coverage: coverage, note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    // MARK: night (MS-07, MS-15, MS-21)

    /// MS-07, MS-15 and MS-21 for the sleep window `sw` (the day table's onset / wake, or an explicit span).
    public static func night(_ d: ScriptDay, sleepWindow sw: Computed<(on: Double, wake: Double)>, at: Date,
                             core: any SignalCore = Signal.core) -> (metrics: [Metric], series: [Series]) {
        var out: [Metric] = []
        out.append(ms07(d, sw, at: at))
        out.append(ms15(d, sw, at: at, core: core))
        let ms21 = ms21Night(d, sw, at: at)
        out += ms21.metrics
        return (out, ms21.series)
    }

    static func ms07(_ d: ScriptDay, _ sw: Computed<(on: Double, wake: Double)>, at: Date) -> Metric {
        var a = Args()
        guard let w = sw.value else {
            a.miss("ibi_ms", sw.missingReason ?? "")
            return emit("MS-07", "resp_rate", "night", .missing(""), at: at, args: a)
        }
        let nr = d.nightRR(w)
        guard let n = nr.value else {
            a.miss("ibi_ms", nr.missingReason ?? "")
            return emit("MS-07", "resp_rate", "night", .missing(""), at: at, args: a)
        }
        let window = ScriptDay.windowLabel(n.coverage, n.spanS)
        if n.spanS < 120.0 {
            a.miss("ibi_ms", "the longest contiguous R-R run is \(Int(n.spanS.rounded())) s (needs 120 s; \(v0))")
            return emit("MS-07", "resp_rate", window, .missing(""), at: at, args: a)
        }
        let pct = String(format: "%.1f", n.correctedFraction * 100)
        a.notes.append("R-R after ALG-004 A (\(pct)% corrected), longest contiguous run "
                       + "\(Int((n.spanS / 60).rounded())) min of \(n.runs) run(s) in the sleep window")
        return emit("MS-07", "resp_rate", window, MS07.respRateKratky(ibiMs: n.rr), at: at, args: a,
                    coverage: n.coverage)
    }

    static func ms15(_ d: ScriptDay, _ sw: Computed<(on: Double, wake: Double)>, at: Date,
                     core: any SignalCore) -> Metric {
        var a = Args()
        let rmssd = a.need("rmssd", d.nightValue(false, sw, core: core))
        var lf: Double?
        var hf: Double?
        var window = "night"
        var cov: Double?
        if let w = sw.value {
            let hv = d.nightHRV(w, core: core)
            if let h = hv.value {
                if let l = h.lf, let hh = h.hf {
                    lf = l
                    hf = hh
                } else {
                    a.miss("lf_mw2", h.freqProblem ?? "no LF / HF")
                    a.miss("hf_mw2", h.freqProblem ?? "no LF / HF")
                }
                cov = h.coverage
                window = ScriptDay.windowLabel(h.coverage, Double(h.windowsClean) * HRVWindows.windowSeconds)
            } else {
                a.miss("lf_mw2", hv.missingReason ?? "")
                a.miss("hf_mw2", hv.missingReason ?? "")
            }
        } else {
            a.miss("lf_mw2", sw.missingReason ?? "")
            a.miss("hf_mw2", sw.missingReason ?? "")
        }
        let base = d.baseline("the 28-day night RMSSD baseline", "hrv_rmssd", nil, "night", days: 28)
        var mu: Double?
        var sd: Double?
        if let b = base.value {
            mu = SignalMath.mean(b)
            sd = b.count > 1 ? SignalMath.sampleSD(b) : 0.0
            a.notes.append("baseline = mean and SD (ddof 1) of \(b.count) of the last 28 night RMSSD values (\(v0))")
        } else {
            a.miss("rmssd_b", base.missingReason ?? "")
            a.miss("rmssd_sd", base.missingReason ?? "")
        }
        guard a.missing.isEmpty, let r = rmssd, let l = lf, let h = hf, let m = mu, let s = sd else {
            return emit("MS-15", "stress", window, .missing(""), at: at, args: a, coverage: cov)
        }
        return emit("MS-15", "stress", window, MS15.hrvStressEsc(rmssd: r, lfMw2: l, hfMw2: h, rmssdB: m, rmssdSD: s),
                    at: at, args: a, coverage: cov)
    }

    static let ms21Outputs = ["sleep_deep", "sleep_light", "sleep_rem", "sleep_wake"]

    static func ms21Blank(_ a: Args, at: Date) -> (metrics: [Metric], series: [Series]) {
        (ms21Outputs.map { emit("MS-21", $0, "night", .missing(""), at: at, args: a) }, [])
    }

    /// ms_inputs.build_ms21: per 30-s epoch over the sleep window — mean HR, RMSSD and MS-07 of the trailing 5-min
    /// R-R, motion = summed |Δ gravity| per epoch / the night's 95th percentile, temp_dev = ALG-110 /100 (no ambient
    /// correction, noted). Nightly values = minutes per stage over the staged epochs.
    static func ms21Night(_ d: ScriptDay, _ sw: Computed<(on: Double, wake: Double)>,
                          at: Date) -> (metrics: [Metric], series: [Series]) {
        var a = Args()
        guard let w = sw.value else {
            a.miss("epochs", sw.missingReason ?? "")
            return ms21Blank(a, at: at)
        }
        let t0 = w.on
        let t1 = w.wake
        let nEp = Int(((t1 - t0) / 30.0).rounded(.down))
        let temp = d.metric("skin_temp_dev", variant: "ALG-110:100", window: "night")
        if let r = temp.missingReason { a.miss("temp_dev_ambient_corrected", r) }
        let nr = d.nightRR(w)
        if let r = nr.missingReason {
            a.miss("rmssd / resp", r)
        } else if let n = nr.value, n.coveredCoverage < 0.7 {
            a.miss("rmssd / resp", "R-R covers \(Int((n.coveredS / 60).rounded())) of \(Int(((t1 - t0) / 60).rounded())) "
                   + "min of the sleep window (needs 70%; \(v0))")
        }
        let hrCov = d.hr.isEmpty ? 0.0 : Double(d.hr.count) / (t1 - t0)
        if hrCov < 0.7 {
            a.miss("hr", "the hr stream covers \(Int((hrCov * 100).rounded()))% of the sleep window (needs 70%; \(v0))")
        }
        let inWin = d.r18.filter { Double($0.ts) >= t0 && Double($0.ts) < t1 }
        let gOK = inWin.filter { $0.gx != nil && $0.gy != nil && $0.gz != nil }.count
        let gCov = gOK > 0 ? Double(gOK) / (t1 - t0) : 0.0
        if gCov < 0.7 {
            a.miss("motion", "the r18 acceleration covers \(Int((gCov * 100).rounded()))% of the sleep window (needs 70%; "
                   + "\(v0))")
        }
        guard a.missing.isEmpty, let n = nr.value, let tempDev = temp.value else { return ms21Blank(a, at: at) }

        // gravity change per epoch (rows with ts in [s, e); a row without gravity breaks the chain)
        var counts: [Double?] = []
        counts.reserveCapacity(nEp)
        var i = 0
        let rows = d.r18
        for k in 0..<nEp {
            let s = t0 + Double(k) * 30.0
            let e = s + 30.0
            while i < rows.count && Double(rows[i].ts) < s { i += 1 }
            var j = i
            var c = 0.0
            var prev: (Double, Double, Double)?
            while j < rows.count && Double(rows[j].ts) < e {
                if let x = rows[j].gx, let y = rows[j].gy, let z = rows[j].gz {
                    if let p = prev {
                        let dx = x - p.0
                        let dy = y - p.1
                        let dz = z - p.2
                        c += (dx * dx + dy * dy + dz * dz).squareRoot()
                    }
                    prev = (x, y, z)
                } else {
                    prev = nil
                }
                j += 1
            }
            counts.append(j - i >= 15 ? c : nil)
        }
        let known = counts.compactMap { $0 }
        let p95 = known.isEmpty ? 0.0 : SignalMath.quantile(known, 0.95)

        var stages: [MS21Stage?] = []
        stages.reserveCapacity(nEp)
        var skipped = 0
        var tallies: [MS21Stage: Int] = [.wake: 0, .light: 0, .rem: 0, .deep: 0]
        let rt = n.allTimes                                  // P9744: all runs, not the longest one
        let rrv = n.allRR
        for k in 0..<nEp {
            let s = t0 + Double(k) * 30.0
            let e = s + 30.0
            let hrs = d.hrBetween(s, e - 1e-9)
            // beats with end time in (e − 300, e] (bisect_right on both ends)
            let j0 = rt.firstIndex { $0 > e - 300.0 } ?? rt.count
            let j1 = rt.firstIndex { $0 > e } ?? rt.count
            let win = j1 > j0 ? Array(rrv[j0..<j1]) : []
            guard hrs.count >= 15, win.count >= 30, let ck = counts[k] else {
                skipped += 1
                stages.append(nil)
                continue
            }
            guard let ht = ALG010.time(rrMs: win).value, let rs = MS07.respRateKratky(ibiMs: win).value else {
                skipped += 1
                stages.append(nil)
                continue
            }
            let motion: Double
            if p95 <= 0 && ck > 0 {
                motion = 1.0
            } else if p95 <= 0 {
                motion = 0.0
            } else {
                motion = min(1.0, ck / p95)
            }
            let st = MS21.sleepStagePPG(hr: SignalMath.mean(hrs), rmssd: ht.rmssd, resp: rs, motion: motion,
                                        tempDevAmbientCorrected: tempDev)
            switch st {
            case .failure(let m):
                // the PC stops at the first failing epoch: the whole call is blank with that reason
                var b = Args()
                b.miss("epochs", m.reason)
                return ms21Blank(b, at: at)
            case .success(let stage):
                tallies[stage, default: 0] += 1
                stages.append(stage)
            }
        }
        let staged = nEp - skipped
        if nEp == 0 || Double(staged) / Double(nEp) < 0.7 {
            a.miss("epochs", "only \(staged) of \(nEp) epochs have HR, 5-min RMSSD, respiration and motion "
                   + "(needs 70%; \(v0))")
            return ms21Blank(a, at: at)
        }
        a.notes.append("\(staged) of \(nEp) 30-s epochs staged, \(skipped) left out for missing HR, RMSSD, respiration "
                       + "or motion; temp_dev has no ambient correction (script argument name says corrected; noted); "
                       + "motion = r18 acceleration change per epoch / the night's 95th percentile (\(v0))")
        let cov = Double(staged) / Double(nEp)
        let minutes: [MS21Stage: Double] = tallies.mapValues { Double($0) * 30.0 / 60.0 }
        let byOutput: [String: MS21Stage] = ["sleep_deep": .deep, "sleep_light": .light, "sleep_rem": .rem,
                                             "sleep_wake": .wake]
        let metrics = ms21Outputs.map { name in
            emit("MS-21", name, "night", .success(minutes[byOutput[name]!] ?? 0), at: at, args: a, coverage: cov,
                 note: "minutes in this stage over the staged epochs")
        }
        let code: [MS21Stage: String] = [.wake: "W", .light: "L", .deep: "D", .rem: "R"]
        let states: [String?] = stages.map { $0.flatMap { code[$0] } }
        let hyp = Series(name: "hypnogram", unit: "stage", start: Date(timeIntervalSince1970: t0), stepS: 30,
                         values: [Double?](repeating: nil, count: states.count), state: states, group: "G-STAGE",
                         variant: "MS-21", tier: .estimate, computedOn: .phone)
        return (metrics, [hyp])
    }

    // MARK: morning (MS-18, MS-20)  (MS-19 Orchard is ALG-160 in MorningStage since r9h, D-RECOV-WALK-2; MS-22 removed 2026-10-17)

    public static func morning(_ d: ScriptDay, at: Date, core: any SignalCore = Signal.core) -> [Metric] {
        let sw = d.sleepWindow()
        return [ms18(d, sw, at: at, core: core), ms20(d, sw, at: at, core: core)]
    }

    static func zscore(_ x: Double, _ base: [Double], _ label: String) -> Computed<Double> {
        guard base.count >= 2 else { return .missing("\(label): baseline needs at least 2 values") }
        let sd = SignalMath.sampleSD(base)
        guard sd > 0 else { return .missing("\(label): baseline has no spread") }
        return .success((x - SignalMath.mean(base)) / sd)
    }

    /// z against the baseline with the SD floored (Loop v2: sleep performance and the SpO2 byte can be flat for 14 nights).
    static func zscoreFloor(_ x: Double, _ base: [Double], _ label: String, floor: Double) -> Computed<Double> {
        guard base.count >= 2 else { return .missing("\(label): baseline needs at least 2 values") }
        return .success((x - SignalMath.mean(base)) / max(SignalMath.sampleSD(base), floor))
    }

    static func ms18(_ d: ScriptDay, _ sw: Computed<(on: Double, wake: Double)>, at: Date,
                     core: any SignalCore) -> Metric {
        let (a, x) = ms18Inputs(d, sw, core: core)
        guard let x else { return emit("MS-18", "readiness", "morning", .missing(""), at: at, args: a) }
        return emit("MS-18", "readiness", "morning",
                    MS18Fixed.recoveryLoopFixed(hrvLnZ: x["hrv"]!, rhrZ: x["rhr"]!, respDev: x["breathing"]!,
                                                sleepZ: x["sleep"]!, tempDev: x["temp"]!, spo2Z: x["spo2"]!),
                    at: at, args: a)
    }

    /// Loop v2's six inputs (D-RECOV-WALK-2): HRV, resting HR, sleep performance and the SpO2 byte as z-scores against the
    /// previous 14 nights, breathing as a deviation from its 14-night median, skin temperature as the raw ALG-110 deviation
    /// (counted in both directions). Nil with the misses named in `args`.
    static func ms18Inputs(_ d: ScriptDay, _ sw: Computed<(on: Double, wake: Double)>,
                           core: any SignalCore) -> (args: Args, inputs: [String: Double]?) {
        var a = Args()
        let ln = d.nightValue(true, sw, core: core)
        let b = d.baseline("the 14-day lnRMSSD baseline", "hrv_ln_rmssd", nil, "night", days: 14)
        var hrvZ: Double?
        if let l = ln.value, let bb = b.value {
            hrvZ = a.need("hrv_ln_z", zscore(l, bb, "hrv_ln_z"))
        } else {
            a.miss("hrv_ln_z", ln.missingReason ?? b.missingReason ?? "")
        }
        let rhr = d.metric("rhr", window: "night")
        let rb = d.baseline("the 14-day RHR baseline", "rhr", nil, "night", days: 14)
        var rhrZ: Double?
        if let r = rhr.value, let bb = rb.value {
            rhrZ = a.need("rhr_z", zscore(r, bb, "rhr_z"))
        } else {
            a.miss("rhr_z", rhr.missingReason ?? rb.missingReason ?? "")
        }
        var respDev: Double?
        var problems: [String] = []
        var member: (Double, String)?
        for v in ["ALG-020", "ALG-121"] {
            let x = d.metric("resp_rate", variant: v, window: "night")
            if let val = x.value { member = (val, v); break }
            problems.append("\(v): \(x.missingReason ?? "")")
        }
        if let mem = member {
            let (val, v) = mem
            let rb2 = d.baseline("the 14-day median of the same G-RESP member", "resp_rate", v, "night", days: 14)
            if let bb = rb2.value {
                respDev = val - SignalMath.median(bb)
                a.notes.append("resp_dev = \(v) night value minus its 14-day median (\(v0))")
            } else {
                a.miss("resp_dev", rb2.missingReason ?? "")
            }
        } else {
            a.miss("resp_dev", "no G-RESP night value (" + problems.joined(separator: "; ") + ")")
        }
        var sleepZ: Double?
        let perf = d.metric("sleep_performance", window: "night")
        let pb = d.baseline("the 14-night sleep performance", "sleep_performance", nil, "night", days: 14)
        if let p = perf.value, let bb = pb.value {
            sleepZ = a.need("sleep_z", zscoreFloor(p, bb, "sleep_z", floor: MS18Fixed.sleepSDFloor))
            if sleepZ != nil { a.notes.append("sleep_z = last night's sleep performance against its 14-night baseline") }
        } else {
            a.miss("sleep_z", perf.missingReason ?? pb.missingReason ?? "")
        }
        let temp = a.need("temp_dev", d.metric("skin_temp_dev", variant: "ALG-110:100", window: "night"))
        if temp != nil { a.notes.append("temp_dev is ALG-110 in raw/100 units, not degrees; a cold night counts like a warm one") }
        var spo2Z: Double?
        let sp = d.metric("spo2_strap_mean", window: "night")
        let sb = d.baseline("the 14-night SpO2 byte", "spo2_strap_mean", nil, "night", days: 14)
        if let v = sp.value, let bb = sb.value {
            spo2Z = a.need("spo2_z", zscoreFloor(v, bb, "spo2_z", floor: MS18Fixed.spo2SDFloor))
            if spo2Z != nil {
                a.notes.append("spo2_z = the strap's raw SpO2 byte night mean against its own 14-night baseline "
                               + "(a count, not a validated percentage)")
            }
        } else {
            a.miss("spo2_z", sp.missingReason ?? sb.missingReason ?? "")
        }
        a.notes.append("Loop v2: our estimate of WHOOP's described inputs (WHOOP publishes no weights); scale x30 and "
                       + "centre 58 fitted to the WHOOP export")
        guard a.missing.isEmpty, let h = hrvZ, let r = rhrZ, let rd = respDev, let p = sleepZ, let t = temp,
              let s = spo2Z else {
            return (a, nil)
        }
        return (a, ["hrv": h, "rhr": r, "breathing": rd, "sleep": p, "temp": t, "spo2": s])
    }

    /// MS-20 Aurora v2 (D-RECOV-WALK-2): HRV and resting HR are z-scores against your own nights (resting HR used to be raw
    /// bpm, which clipped the score to 0 every day); the other contributors are the 0–1 fractions of ours v0. Every weight
    /// is our estimate of Oura's described contributors; Oura publishes none.
    static func ms20(_ d: ScriptDay, _ sw: Computed<(on: Double, wake: Double)>, at: Date,
                     core: any SignalCore) -> Metric {
        var a = Args()
        var hrvZ: Double?
        let ln = d.nightValue(true, sw, core: core)
        let b90 = d.baseline("the 90-day night lnRMSSD baseline", "hrv_ln_rmssd", nil, "night", days: 90)
        if let l = ln.value, let bb = b90.value {
            hrvZ = a.need("hrv_z", zscore(l, bb, "hrv_z"))
        } else {
            a.miss("hrv_z", ln.missingReason ?? b90.missingReason ?? "")
        }
        var rhrZ: Double?
        let rhr = d.metric("rhr", window: "night")
        let rb = d.baseline("the 14-day RHR baseline", "rhr", nil, "night", days: 14)
        if let r = rhr.value, let bb = rb.value {
            rhrZ = a.need("rhr_z", zscore(r, bb, "rhr_z"))
        } else {
            a.miss("rhr_z", rhr.missingReason ?? rb.missingReason ?? "")
        }
        let temp = a.need("temp_dev", d.metric("skin_temp_dev", variant: "ALG-110:100", window: "night"))
        let prev = a.need("sleep_prev", d.metric("sleep_performance", window: "night"))
        let sb = a.need("sleep_balance", d.baseline("the 14-day sleep performance", "sleep_performance", nil, "night",
                                                    days: 14, includeToday: true))
        let y = a.need("act_prev", d.metric("strain", variant: "ALG-036", on: d.day.adding(days: -1)))
        let atl = d.metric("atl", variant: "ALG-036", window: "day")
        let ctl = d.metric("ctl", variant: "ALG-036", window: "day")
        var actBalance: Double?
        if let at_ = atl.value, let ct = ctl.value {
            if ct <= 0 {
                a.miss("act_balance", "CTL is 0, so ATL/CTL is undefined")
            } else {
                actBalance = min(2.0, max(0.0, at_ / ct)) / 2.0
            }
        } else {
            a.miss("act_balance", "ATL/CTL: " + [atl.missingReason, ctl.missingReason].compactMap { $0 }
                .joined(separator: "; "))
        }
        let dip = a.need("recovery_idx", d.metric("hr_dip", window: "night"))
        let sri = a.need("sleep_reg", d.metric("sri"))
        guard a.missing.isEmpty, let hz = hrvZ, let rz = rhrZ, let t = temp, let p = prev, let s = sb, let yy = y,
              let ab = actBalance, let dp = dip, let sr = sri else {
            return emit("MS-20", "readiness", "morning", .missing(""), at: at, args: a)
        }
        a.notes.append("Aurora v2: our estimate of Oura's described contributors (Oura publishes no weights); "
                       + "ours v0 adapters as ms_inputs.build_ms20")
        return emit("MS-20", "readiness", "morning",
                    MS20Fixed.readinessAuraFixed(hrvZ: hz, rhrZ: rz, tempDev: t, sleepPrev: p,
                                                 sleepBalance: SignalMath.mean(s), sleepReg: sr / 100.0,
                                                 actPrev: yy / 21.0, actBalance: ab, recoveryIdx: dp / 100.0),
                    at: at, args: a)
    }

    // MARK: day (MS-01 … MS-06)

    /// MS-01 / MS-02 per logged workout (MS-04 training effect removed 2026-10-17, r9p), MS-01 / MS-02 day totals, MS-03, MS-05 / MS-06 (blank: they need a
    /// timed 1-mile effort). `wornMinutes` = worn minutes of the day so far (≥ 60 = worn, main's rule).
    public static func day(_ d: ScriptDay, at: Date, wornMinutes: Int) -> [Metric] {
        var out: [Metric] = []
        let wos = d.workouts()
        let hm = d.hrmax()
        var perWorkout: [String: [Metric]] = ["MS-01": [], "MS-02": []]
        for w in wos {
            let win = "workout:\(PipelineSpecs.id8(w.event.id))"
            let wat = w.end
            let hr = d.workoutHR(w)
            // MS-01 Banister TRIMP
            var a1 = Args()
            let info = hr.value
            if let r = hr.missingReason { a1.miss("hr_ex", r) }
            let rest = d.baseline("the 7-day RHR median (ALG-012)", "rhr", nil, "night", days: 7, includeToday: true)
            let hrRest = a1.need("hr_rest", rest.map { SignalMath.median($0) })
            if let r = rest.value { a1.notes.append("hr_rest = median RHR of \(r.count) of the last 7 days (\(v0))") }
            let hrMax = a1.need("hr_max", hm)
            let male = a1.need("male", d.sexIsMale())
            if let i = info {
                a1.notes.append("mean HR over the workout (\(Int((i.coverage * 100).rounded()))% coverage)")
            }
            var v1: Computed<Double> = .missing("")
            if let i = info, let r = hrRest, let mx = hrMax, let m = male {
                v1 = MS01.trimpBanister(durationMin: (w.end.timeIntervalSince1970 - w.event.at.timeIntervalSince1970) / 60,
                                        hrEx: SignalMath.mean(i.bpm), hrRest: r, hrMax: mx, male: m)
            }
            let m1 = emit("MS-01", "strain", win, v1, at: wat, args: a1, coverage: info?.coverage,
                          note: "workout \(w.event.id.uuidString.lowercased())")
            perWorkout["MS-01"]!.append(m1)
            out.append(m1)
            // MS-02 Edwards zones
            var a2 = Args()
            if let r = hr.missingReason { a2.miss("mins_in_5_zones", r) }
            var v2: Computed<Double> = .missing("")
            if let mx = hm.value {
                if let i = info {
                    var mins = [Double](repeating: 0, count: 5)
                    for b in i.bpm {
                        let frac = b / mx
                        if frac >= 0.5 { mins[min(4, Int(((frac - 0.5) / 0.1).rounded(.towardZero)))] += i.stepS / 60.0 }
                    }
                    a2.notes.append("zones are 50-60 ... 90-100 % of HRmax; samples under 50 % are not counted (\(v0))")
                    v2 = MS02.trimpEdwards(minsInFiveZones: mins)
                }
            } else {
                a2.miss("mins_in_5_zones", "needs HRmax: " + (hm.missingReason ?? ""))
            }
            let m2 = emit("MS-02", "strain", win, v2, at: wat, args: a2, coverage: info?.coverage,
                          note: "workout \(w.event.id.uuidString.lowercased())")
            perWorkout["MS-02"]!.append(m2)
            out.append(m2)
        }
        // day totals: the sum of the workouts (ms_runner._day_aggregate); a worn rest day = 0 (main's rule)
        var ms01Day: Computed<Double> = .missing("no workout")
        if !wos.isEmpty {
            for id in ["MS-01", "MS-02"] {
                let parts = perWorkout[id] ?? []
                let blanks = parts.filter { $0.value == nil }
                let s = spec(id, "strain", "day", source: "fixed script, workouts of the day")
                let m: Metric
                if blanks.isEmpty {
                    m = s.metric(.success(parts.compactMap(\.value).reduce(0, +)), at: at,
                                 note: "sum of \(parts.count) workout value(s) (ARCHITECTURE 8.2: day = sum of workouts)")
                } else {
                    let why = blanks.map { "workout \($0.window ?? ""): \($0.note ?? "")" }.joined(separator: "; ")
                    m = s.blank("no day sum - \(blanks.count) of \(parts.count) workouts have no value (\(why))", at: at)
                }
                if id == "MS-01" { ms01Day = m.value.orMissing(m.note ?? "no MS-01 day value") }
                out.append(m)
            }
        } else {
            for id in ["MS-01", "MS-02"] {
                let s = spec(id, "strain", "day", source: "fixed script, workouts of the day")
                if wornMinutes >= ALG036.dayStrainMinMinutes {
                    out.append(s.metric(.success(0), at: at, note: "worn day (\(wornMinutes) min) with no workout: a "
                                        + "real 0 load (main 2026-10-11, so MS-03 can count it)"))
                    if id == "MS-01" { ms01Day = .success(0) }
                } else {
                    out.append(s.blank("no strap data this day (\(wornMinutes) worn min, needs "
                                       + "\(ALG036.dayStrainMinMinutes)): no day load, never a 0", at: at))
                }
            }
        }
        // MS-03 acute:chronic from 28 daily MS-01 values (never a zero for a missing day)
        var a3 = Args()
        var v28: [Double?] = (1...27).reversed().map {
            d.metric("strain", variant: "MS-01", window: "day", on: d.day.adding(days: -$0)).value
        }
        v28.append(ms01Day.value ?? d.metric("strain", variant: "MS-01", window: "day").value)
        let have = v28.compactMap { $0 }
        var v3: Computed<Double> = .missing("")
        if have.count < 28 {
            a3.miss("week28_trimp", "\(have.count) of the last 28 days have an MS-01 day value (a rest day needs a "
                    + "written 0)")
            a3.miss("week7_trimp", "\(v28.suffix(7).compactMap { $0 }.count) of the last 7 days have an MS-01 day value")
        } else {
            let r = MS03.aclCtl(week7Trimp: have.suffix(7).reduce(0, +), week28Trimp: have.reduce(0, +))
            v3 = r.flatMap { x in
                x.ratio.orMissing("no ratio (band \(x.band.rawValue))")
            }
            if let band = r.value?.band { a3.notes.append("band \(band.rawValue)") }
        }
        out.append(emit("MS-03", "acwr", "day", v3, at: at, args: a3))
        // MS-05 / MS-06 need a timed 1-mile effort (none logged in this build)
        for id in ["MS-05", "MS-06"] {
            var a = Args()
            if id == "MS-05" { a.miss("time_1mi_s", "needs a timed 1-mile effort (none in the day's events)") }
            a.miss("hr_1mi", "needs the HR over a timed 1-mile effort (none in the day's events)")
            let rest = d.baseline("the 7-day RHR median (ALG-012)", "rhr", nil, "night", days: 7, includeToday: true)
            if let r = rest.missingReason { a.miss("hr_rest", r) }
            _ = a.need("age", d.age())
            _ = a.need("kg", d.weightKg())
            out.append(emit(id, "vo2max", "day", .missing(""), at: at, args: a))
        }
        return out
    }
}
