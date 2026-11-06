import Foundation
import MGDomain

/// ALG-051 v1 — alertness from sleep and caffeine: the Unified Model of Performance (UMP) with its caffeine factor.
///
/// Source: Ramakrishnan S et al. "A Unified Model of Performance for Predicting the Effects of Sleep and Caffeine",
/// Sleep 2016;39(10):1827–1841 (PMC5020365), Table 2 eqs. 2–6, Table 3 (PVT **lapse** column); read from the paper's
/// own table images 2026-10-11. Population parameters only: the model is not yet fitted to Mo's reaction tests
/// (2B-Alert style individualisation, Liu et al. 2017 J Sleep Res 26:820–831, is the next step; ALG-050 events are
/// stored for it).
///
///     P0(t) = S(t) + κ·C(t)                                                          (eq. 2)
///     C(t)  = Σ_{i=1..5} a_i · sin(i · 2π/τ · (t + φ)),  a = 0.97, 0.22, 0.07, 0.03, 0.001, τ = 24 h   (eq. 3)
///     S(t)  = U − (U − S0)·e^(−t/τw)                                            awake                 (eq. 4)
///           = −2U + (2U + S0)·e^(−t/τs) + (2U + L0)·τLA/(τLA − τs)·(e^(−t/τLA) − e^(−t/τs))   asleep
///     L(t)  = max[U − (U − L0)·e^(−t/τLA), −0.11U]                               awake                 (eq. 5)
///           = max[−2U + (2U + L0)·e^(−t/τLA), −0.11U]                            asleep
///     Pc(t) = P0(t) · gPD(t, c)                                                                         (eq. 1)
///     gPD   = [1 + M_c · k_a/(k_a − k_c) · (e^(−k_c(t−t0)) − e^(−k_a(t−t0)))]^−1,  M_c = M0·c,  k_c = k0·e^(−z·c)  (eq. 6)
///
/// t restarts at every sleep/wake switch with S0, L0 = the values at the switch. Table 3, lapses (10-min PVT, lapse =
/// RT > 500 ms): U 18.4 lapses, τw 40.0 h, τs 2.1 h, κ 3.3 lapses, φ 2.3 h, τLA 7.0 d; M0 9.86 g⁻¹, k0 0.49 h⁻¹,
/// z 1.63 g⁻¹, k_a 2.06 h⁻¹ (capsule; gum 3.21). Dose c is in **grams** (M0 is per gram: 200 mg → M_c 1.97).
///
/// Choices that are OURS (each flagged, each one line to change):
/// - **Clock time of t = 0 for C: 05:00 local** (`Params.originH`). The paper does not say where t = 0 sits on the
///   clock. Fitted to the same paper's Fig. 1 (study V1, read by eye): 05:00 reproduces the placebo lapse curve with RMS
///   0.27 lapses (mean RT: 9 ms) against 2.1 lapses (62 ms) for midnight. Script: app/tools/alg051_ump_reference.py.
/// - **Own phase (v2)**: the origin above is for a sleeper whose nights are centred on 03:00 (the 23:00–07:00 default).
///   It moves by how far the median sleep midpoint of the last 14 nights (main sleeps of 3 h or more, at least 3 of
///   them recorded) lies from 03:00, so a sleeper 3 h earlier gets a curve 3 h earlier. Circular median, so a midpoint
///   just after midnight is not confused with one at noon. Fewer nights = no shift, said in the note. Sleep midpoint
///   as a phase marker of the circadian clock: Roenneberg et al. 2003 J Biol Rhythms 18:80–90 (MSF); the shift is
///   1:1, an assumption (the paper's own curve does not say how it moves with habit).
/// - **Lapses, not mean RT.** The lapse column's L0 is 0 (no sleep debt), so "8 h a night, no debt" (2B-Alert Web,
///   Reifman 2016 Sleep 39:2157) gives sensible absolute levels; the mean-RT column needs a study offset δ.
/// - **Repeated doses**: the paper refers to Ramakrishnan 2014 (J Theor Biol 358:11) for them; the rule used is the one
///   printed in US 11,241,194 B2 col. 11 eqs. 6–8 (same group): at each dose the effective dose is D_j + E(t_j⁻), the
///   caffeine still on board, and k = k0·e^(−z(D_j + E)). Applied to a gut + body pair so that one dose reduces exactly
///   to eq. 6 and instant absorption reduces exactly to the patent's eqs. 6–8.
/// - A drink is one dose at the midpoint of start and finish (no finish: start + 20 min, half of ALG-060's 40 min).
/// - A drink logged without mg is left out (said in the note); it does not blank the model.
/// - Caffeine multiplies only a positive impairment (lapses cannot be negative; after long sleep P0 can dip below 0).
/// - History: the 14 nights before; a night with no sleep record is assumed 23:00–07:00 (the 2B-Alert default) and
///   counted in the note. Before that, the steady state of 23:00–07:00 nights (no sleep debt). Last night's sleep must
///   be known (a main sleep of ≥ 3 h ending in the last 24 h), else Missing.
/// - **Alertness score 0–100**: 100 = the model's best waking value after rested 23:00–07:00 nights, 0 = after 24 h
///   awake from that state (2B-Alert Web's 0.08 % BAC line, Dawson & Reid 1997); linear in predicted lapses between the
///   two, clamped. The 19-h line (0.06 % BAC) lands near 61.
/// Python reference + checks: app/tools/alg051_ump_reference.py (same equations, ODE cross-check, Fig. 1 readings).
public enum ALG051 {
    public static let method = "ALG-051@2 ump-caffeine-lapses personal-phase"
    /// The previous method (v1): the circadian origin fixed at 05:00 clock time (`forecast(personalPhase: false)`), kept
    /// beside the new one so the two can be compared (R-062).
    public static let methodFixedClock = "ALG-051@1 ump-caffeine-lapses"
    public static let citation = "Ramakrishnan S et al. Sleep 2016;39(10):1827-1841 (Table 2 eqs 2-6, Table 3 lapses); "
        + "repeated doses: US 11,241,194 B2 col. 11 eqs 6-8"
    public static let paramsVersion = "T3-lapses origin05+midpoint-shift ka2.06 population"
    public static let populationNote = "population model, not yet personalised"

    /// Table 2 eq. 3.
    public static let harmonics = [0.97, 0.22, 0.07, 0.03, 0.001]
    /// Table 2 eq. 5: L never goes below −0.11·U.
    public static let floorFraction = 0.11
    public static let periodH = 24.0
    /// Ours (see above): the default night when there is no record, and the history length.
    public static let defaultBedH = 23
    public static let defaultWakeH = 7
    public static let historyNights = 14
    /// Ours: a main sleep is at least 3 h (naps shorter than that still count as sleep in the model).
    public static let mainSleepSeconds = 3.0 * 3600
    /// Ours: the sleep midpoint the default origin belongs to (23:00–07:00), and the fewest recorded nights to trust.
    public static let defaultMidpointH = 3.0
    public static let minPhaseNights = 3
    /// Ours: the forecast runs from waking to bedtime, or 17 h after waking when bedtime is unknown.
    public static let defaultDaySeconds = 17.0 * 3600

    public struct Params: Sendable, Hashable {
        /// U, upper asymptote (lapses).
        public var upper: Double
        public var tauWakeH: Double
        public var tauSleepH: Double
        /// κ, circadian amplitude (lapses).
        public var kappa: Double
        /// φ, circadian phase (h).
        public var phaseH: Double
        public var tauLAH: Double
        public var m0PerGram: Double
        public var k0PerH: Double
        public var zPerGram: Double
        public var kaPerH: Double
        /// Clock hour (local) of t = 0 in C(t). Ours: 05:00, fitted to the paper's Fig. 1.
        public var originH: Double

        public init(upper: Double, tauWakeH: Double, tauSleepH: Double, kappa: Double, phaseH: Double, tauLAH: Double,
                    m0PerGram: Double, k0PerH: Double, zPerGram: Double, kaPerH: Double, originH: Double) {
            self.upper = upper
            self.tauWakeH = tauWakeH
            self.tauSleepH = tauSleepH
            self.kappa = kappa
            self.phaseH = phaseH
            self.tauLAH = tauLAH
            self.m0PerGram = m0PerGram
            self.k0PerH = k0PerH
            self.zPerGram = zPerGram
            self.kaPerH = kaPerH
            self.originH = originH
        }

        /// Table 3, lapse column; k_a = capsule (oral); origin = ours.
        public static let populationLapses = Params(
            upper: 18.4, tauWakeH: 40.0, tauSleepH: 2.1, kappa: 3.3, phaseH: 2.3, tauLAH: 7.0 * 24,
            m0PerGram: 9.86, k0PerH: 0.49, zPerGram: 1.63, kaPerH: 2.06, originH: 5.0)

        func check() -> Missing? {
            for (name, v) in [("U", upper), ("τw", tauWakeH), ("τs", tauSleepH), ("τLA", tauLAH), ("k0", k0PerH),
                              ("k_a", kaPerH)] where !(v.isFinite && v > 0) {
                return Missing("UMP parameter \(name) must be a positive number")
            }
            for (name, v) in [("κ", kappa), ("φ", phaseH), ("M0", m0PerGram), ("z", zPerGram), ("origin", originH)]
            where !v.isFinite {
                return Missing("UMP parameter \(name) is not a number")
            }
            if abs(tauLAH - tauSleepH) < 1e-9 { return Missing("UMP: τLA equals τs, the sleep equation divides by 0") }
            return nil
        }
    }

    /// Homeostatic state: S and its lower asymptote L (lapses).
    public struct State: Sendable, Equatable {
        public var s: Double
        public var l: Double

        public init(s: Double, l: Double) {
            self.s = s
            self.l = l
        }
    }

    /// One known sleep (a night from the sleep window or an import, or a confirmed nap).
    public struct SleepSpan: Sendable, Hashable {
        public var start: Date
        public var end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }
    }

    public struct Sample: Sendable, Equatable {
        public var at: Date
        /// Predicted 10-min PVT lapses with caffeine (Pc).
        public var lapses: Double
        /// gPD (1 = no caffeine effect).
        public var caffeineFactor: Double
        /// The alertness score before clamping (can leave 0…100).
        public var rawScore: Double
        /// 0…100.
        public var score: Double

        public init(at: Date, lapses: Double, caffeineFactor: Double, rawScore: Double, score: Double) {
            self.at = at
            self.lapses = lapses
            self.caffeineFactor = caffeineFactor
            self.rawScore = rawScore
            self.score = score
        }
    }

    /// The two ends of the score: rested best (100) and 24 h awake (0), in predicted lapses.
    public struct Anchors: Sendable, Equatable {
        public var bestLapses: Double
        public var sleepless24Lapses: Double

        public init(bestLapses: Double, sleepless24Lapses: Double) {
            self.bestLapses = bestLapses
            self.sleepless24Lapses = sleepless24Lapses
        }
    }

    public struct Forecast: Sendable, Equatable {
        /// Every `step` from `wake` to `end` (both included when they fall on the grid; `end` always included).
        public var samples: [Sample]
        public var wake: Date
        public var end: Date
        /// The value at `now`; nil when `now` is outside [wake, end].
        public var current: Sample?
        public var anchors: Anchors
        public var assumedNights: Int
        public var drinksLeftOut: Int
        public var drinksUsed: Int
        /// Reaction tests behind the parameters: 0 until individualisation exists.
        public var reactionTestsUsed: Int
        /// "population model, not yet personalised" + what was assumed or left out.
        public var note: String
        /// The planned end of the waking day (bedtime, else wake + 17 h) before `end` is stretched to `now`; windows read
        /// off the curve (ALG-052 dip) stay inside it (W10, 2026-10-11: after a 3.5 h night and a 19:xx bedtime the
        /// stretch to 21:30 put the "best 3 h" at 18:29–21:29). nil = same as `end`.
        public var plannedEnd: Date? = nil
        /// Hours the circadian curve was moved for Mo's own sleep timing (0 = default clock) and the recorded nights
        /// behind it.
        public var phaseShiftH: Double = 0
        public var phaseNights: Int = 0
    }

    // MARK: kernel (hours)

    static func circadian(clockH: Double, _ p: Params) -> Double {
        let x = 2.0 * Double.pi / periodH * (clockH - p.originH + p.phaseH)
        var c = 0.0
        for (i, a) in harmonics.enumerated() { c += a * sin(Double(i + 1) * x) }
        return c
    }

    static func awake(_ st: State, hours h: Double, _ p: Params) -> State {
        let u = p.upper
        let s = u - (u - st.s) * exp(-h / p.tauWakeH)
        let l = max(u - (u - st.l) * exp(-h / p.tauLAH), -floorFraction * u)
        return State(s: s, l: l)
    }

    static func asleep(_ st: State, hours h: Double, _ p: Params) -> State {
        let u = p.upper
        let es = exp(-h / p.tauSleepH)
        let el = exp(-h / p.tauLAH)
        let s = -2 * u + (2 * u + st.s) * es + (2 * u + st.l) * (p.tauLAH / (p.tauLAH - p.tauSleepH)) * (el - es)
        let l = max(-2 * u + (2 * u + st.l) * el, -floorFraction * u)
        return State(s: s, l: l)
    }

    /// The periodic state at 07:00 of 23:00–07:00 nights (no sleep debt: L oscillates around 0, US 11,241,194 col. 10).
    static func steadyState(_ p: Params) -> State {
        var st = State(s: 0, l: 0)
        let wakeH = Double(defaultBedH - defaultWakeH)
        for _ in 0..<120 {
            st = awake(st, hours: wakeH, p)
            st = asleep(st, hours: 24 - wakeH, p)
        }
        return st
    }

    /// Median sleep-midpoint offset from `defaultMidpointH` (hours, −12…12, + = later) over the recorded main sleeps
    /// that ended in the 14 days up to `wake`; nil with fewer than `minPhaseNights` of them.
    static func midpointShift(_ known: [Segment], wake: Double, _ tz: TimeZone) -> (shiftH: Double, nights: Int)? {
        var d: [Double] = []
        for s in known where s.end - s.start >= mainSleepSeconds && s.end <= wake && s.end > wake - Double(historyNights) * 86_400 {
            let mid = clockHour((s.start + s.end) / 2, tz)
            let x = (mid - defaultMidpointH + 36).truncatingRemainder(dividingBy: 24) - 12
            d.append(x)
        }
        guard d.count >= minPhaseNights else { return nil }
        d.sort()
        let m = d.count / 2
        return (d.count % 2 == 1 ? d[m] : (d[m - 1] + d[m]) / 2, d.count)
    }

    /// P0 at a state and a clock hour.
    static func p0(_ st: State, clockH: Double, _ p: Params) -> Double {
        st.s + p.kappa * circadian(clockH: clockH, p)
    }

    /// Score anchors from the parameters: best waking value of the rested day (from 1 h after 07:00 to 23:00, every
    /// 10 min) and the value after 24 h awake from 07:00.
    public static func anchors(_ p: Params = .populationLapses) -> Anchors {
        let st0 = steadyState(p)
        var best = Double.infinity
        var h = 1.0
        while h <= Double(defaultBedH - defaultWakeH) + 1e-9 {
            best = min(best, p0(awake(st0, hours: h, p), clockH: Double(defaultWakeH) + h, p))
            h += 1.0 / 6.0
        }
        let worst = p0(awake(st0, hours: 24, p), clockH: Double(defaultWakeH), p)
        return Anchors(bestLapses: best, sleepless24Lapses: worst)
    }

    /// 100·(at24 − P)/(at24 − best), unclamped.
    public static func rawScore(lapses: Double, anchors a: Anchors) -> Double {
        100.0 * (a.sleepless24Lapses - lapses) / (a.sleepless24Lapses - a.bestLapses)
    }

    // MARK: caffeine (unix seconds outside, hours inside)

    struct Intake: Sendable, Equatable {
        var t: Double
        var grams: Double
    }

    /// Drinks as single doses at their midpoint; drinks without mg are counted, not used.
    static func intakes(_ doses: [ALG060.Dose], drinkSeconds: Double = ALG060.defaultDrinkSeconds)
        -> (items: [Intake], leftOut: Int) {
        var out: [Intake] = []
        var leftOut = 0
        for d in doses {
            guard let mg = d.mg, mg.isFinite, mg >= 0 else {
                leftOut += 1
                continue
            }
            if mg == 0 { continue }
            let s = d.start.timeIntervalSince1970
            let f = d.finish.map { max($0.timeIntervalSince1970, s) } ?? (s + drinkSeconds)
            out.append(Intake(t: (s + f) / 2, grams: mg / 1000))
        }
        return (out.sorted { $0.t < $1.t }, leftOut)
    }

    /// One compartment pair over `h` hours: gut → body at k_a, body out at k.
    static func advance(gut: Double, body: Double, hours h: Double, k: Double, ka: Double) -> (gut: Double, body: Double) {
        let ek = exp(-k * h)
        let ea = exp(-ka * h)
        let transfer = abs(ka - k) < 1e-9 ? gut * ka * h * ek : gut * ka / (ka - k) * (ek - ea)
        return (gut * ea, body * ek + transfer)
    }

    /// Caffeine in the body (g) at `t` under the repeated-dose rule (effective dose D_j + E(t_j⁻), k from it).
    static func bodyGrams(at t: Double, _ items: [Intake], _ p: Params) -> Double {
        var gut = 0.0
        var body = 0.0
        var last: Double?
        var k = p.k0PerH
        for d in items where d.t <= t {
            if let l = last {
                (gut, body) = advance(gut: gut, body: body, hours: (d.t - l) / 3600, k: k, ka: p.kaPerH)
            }
            k = p.k0PerH * exp(-p.zPerGram * (d.grams + gut + body))
            gut += d.grams
            last = d.t
        }
        guard let l = last else { return 0 }
        return advance(gut: gut, body: body, hours: (t - l) / 3600, k: k, ka: p.kaPerH).body
    }

    /// gPD at `t`.
    static func factor(at t: Double, _ items: [Intake], _ p: Params) -> Double {
        1.0 / (1.0 + p.m0PerGram * bodyGrams(at: t, items, p))
    }

    // MARK: timeline

    struct Segment {
        var start: Double
        var end: Double
        var asleep: Bool
    }

    static func clockHour(_ t: Double, _ tz: TimeZone) -> Double {
        let local = t + Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: t)))
        let s = (local.truncatingRemainder(dividingBy: 86_400) + 86_400).truncatingRemainder(dividingBy: 86_400)
        return s / 3600
    }

    /// The instant `hour`:00 on the local date of `day` (DST: Calendar's next valid time).
    static func at(_ day: Date, hour: Int, _ cal: Calendar) -> Double {
        (cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)
            ?? cal.startOfDay(for: day).addingTimeInterval(Double(hour) * 3600)).timeIntervalSince1970
    }

    /// Known sleeps clipped to [from, to], merged where they overlap or touch.
    static func merged(_ sleeps: [SleepSpan], from: Double, to: Double) -> [Segment] {
        let spans = sleeps.map { (max($0.start.timeIntervalSince1970, from), min($0.end.timeIntervalSince1970, to)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var out: [Segment] = []
        for (a, b) in spans {
            if let last = out.last, a <= last.end {
                out[out.count - 1].end = max(last.end, b)
            } else {
                out.append(Segment(start: a, end: b, asleep: true))
            }
        }
        return out
    }

    // MARK: public surface

    /// ALG-051 v1 — today's alertness curve from waking to `until` (bedtime; nil = 17 h after waking), every `step`.
    /// `sleeps`: known sleeps of the last ~15 days (nights and confirmed naps). `doses`: caffeine (ALG-060 doses) of
    /// the last ~2 days. Missing when last night's sleep is unknown or a parameter is invalid.
    public static func forecast(sleeps: [SleepSpan], doses: [ALG060.Dose], now: Date, until: Date?, timeZone: TimeZone,
                                params p: Params = .populationLapses, step: TimeInterval = 600,
                                reactionTestsUsed: Int = 0, personalPhase: Bool = true) -> Computed<Forecast> {
        if let m = p.check() { return .failure(m) }
        guard step > 0 else { return .missing("forecast step must be positive") }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let tNow = now.timeIntervalSince1970

        // Last night: the newest main sleep that has ended.
        let known = merged(sleeps, from: tNow - Double(historyNights + 2) * 86_400, to: tNow)
        guard let last = known.last(where: { $0.end - $0.start >= mainSleepSeconds && $0.end <= tNow }),
              tNow - last.end < 86_400 else {
            return .missing("no main sleep (3 h or more) recorded in the last 24 h: the alertness model needs last "
                            + "night's sleep (strap sleep window or imported sleep)")
        }
        let wake = last.end
        var phase = (shiftH: 0.0, nights: 0)
        if personalPhase, let ph = midpointShift(known, wake: wake, timeZone) { phase = ph }
        var pc = p                                  // the curve's own origin; the score scale (anchors) stays on `p`
        pc.originH += phase.shiftH
        var end = until.map { $0.timeIntervalSince1970 } ?? (wake + defaultDaySeconds)
        if end < wake + 3 * 3600 { end = wake + defaultDaySeconds }
        let planned = min(end, wake + 86_400)
        end = min(max(end, tNow), wake + 86_400)

        // History: 07:00 local, `historyNights` days before the wake day, in the rested steady state.
        let wakeDate = Date(timeIntervalSince1970: wake)
        guard let firstDay = cal.date(byAdding: .day, value: -historyNights, to: cal.startOfDay(for: wakeDate)) else {
            return .missing("calendar could not place the history start")
        }
        let start = at(firstDay, hour: defaultWakeH, cal)
        var sleepSegs = known.filter { $0.end > start }
        for i in sleepSegs.indices { sleepSegs[i].start = max(sleepSegs[i].start, start) }
        var assumed = 0
        var day = firstDay
        while true {
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            let windowA = at(day, hour: 18, cal)
            let windowB = at(next, hour: 12, cal)
            if windowA >= wake { break }
            if !sleepSegs.contains(where: { $0.start < windowB && $0.end > windowA }) {
                let a = at(day, hour: defaultBedH, cal)
                let b = at(next, hour: defaultWakeH, cal)
                if b <= wake {
                    sleepSegs.append(Segment(start: a, end: b, asleep: true))
                    assumed += 1
                }
            }
            day = next
        }
        sleepSegs.sort { $0.start < $1.start }

        // Walk start → end: awake between sleeps.
        var segs: [Segment] = []
        var cursor = start
        for s in sleepSegs where s.end > cursor {
            if s.start > cursor { segs.append(Segment(start: cursor, end: s.start, asleep: false)) }
            segs.append(Segment(start: max(s.start, cursor), end: s.end, asleep: true))
            cursor = s.end
        }
        if cursor < end { segs.append(Segment(start: cursor, end: end, asleep: false)) }
        var states: [State] = []
        var st = steadyState(p)
        for s in segs {
            states.append(st)
            let h = (s.end - s.start) / 3600
            st = s.asleep ? asleep(st, hours: h, p) : awake(st, hours: h, p)
        }

        let (items, leftOut) = intakes(doses)
        let used = items.filter { $0.t <= end }.count
        let a = anchors(p)
        guard a.sleepless24Lapses - a.bestLapses > 0 else {
            return .missing("UMP parameters give no difference between rested and 24 h awake")
        }
        func sample(_ t: Double) -> Sample {
            var idx = 0
            for (i, s) in segs.enumerated() where s.start <= t { idx = i }
            let s = segs[idx]
            let h = max(0, t - s.start) / 3600
            let state = s.asleep ? asleep(states[idx], hours: h, p) : awake(states[idx], hours: h, p)
            let base = p0(state, clockH: clockHour(t, timeZone), pc)
            let g = factor(at: t, items, p)
            let pc = base > 0 ? base * g : base
            let raw = rawScore(lapses: pc, anchors: a)
            return Sample(at: Date(timeIntervalSince1970: t), lapses: pc, caffeineFactor: g, rawScore: raw,
                          score: min(max(raw, 0), 100))
        }
        var out: [Sample] = []
        var t = wake
        while t <= end + 1e-6 {
            out.append(sample(t))
            t += step
        }
        if let lastAt = out.last?.at.timeIntervalSince1970, end - lastAt > 1 { out.append(sample(end)) }
        let current: Sample? = (tNow >= wake && tNow <= end) ? sample(tNow) : nil

        var notes = [populationNote]
        if personalPhase {
            if phase.nights == 0 {
                notes.append("body-clock phase = default (fewer than \(minPhaseNights) nights of sleep recorded)")
            } else {
                notes.append(String(format: "body-clock phase moved %+.1f h from your median sleep midpoint (%d nights)",
                                    phase.shiftH, phase.nights))
            }
        }
        if assumed > 0 { notes.append("\(assumed) of \(historyNights) nights assumed 23:00–07:00 (no sleep record)") }
        if leftOut > 0 { notes.append("\(leftOut) drink\(leftOut == 1 ? "" : "s") without mg left out") }
        return .success(Forecast(samples: out, wake: wakeDate, end: Date(timeIntervalSince1970: end), current: current,
                                 anchors: a, assumedNights: assumed, drinksLeftOut: leftOut, drinksUsed: used,
                                 reactionTestsUsed: reactionTestsUsed, note: notes.joined(separator: "; "),
                                 plannedEnd: Date(timeIntervalSince1970: planned), phaseShiftH: phase.shiftH,
                                 phaseNights: phase.nights))
    }

    // MARK: inputs from stored rows

    /// Known sleeps from stored day rows and events: per day, `sleep_onset` → `wake_time` of the app's own rest
    /// window (ALG-030) or, when the app has none that day, an imported one (WHOOP export, then Apple Health); plus
    /// confirmed naps. Blank rows are skipped.
    public static func sleepSpans(metricsByDay: [LocalDay: [Metric]], events: [EventRecord]) -> [SleepSpan] {
        func pick(_ ms: [Metric], _ name: String, _ variant: String) -> Double? {
            ms.first { $0.name == name && $0.variant == variant && ($0.value?.isFinite ?? false) }?.value
        }
        var out: [SleepSpan] = []
        for (_, ms) in metricsByDay {
            for variant in ["ALG-030"] + ImportedHistory.variants {
                if let on = pick(ms, MetricKey.sleepOnset.rawValue, variant),
                   let wk = pick(ms, MetricKey.wakeTime.rawValue, variant), wk > on {
                    out.append(SleepSpan(start: Date(timeIntervalSince1970: on), end: Date(timeIntervalSince1970: wk)))
                    break
                }
            }
        }
        for e in events where !e.removed {
            if case .nap(let f) = e.payload, f.confirmed == true, f.end > e.at {
                out.append(SleepSpan(start: e.at, end: f.end))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: metrics

    /// `alertness` (score 0–100), window "instant": the score at `now`.
    public static let alertnessSpec = MetricSpec(
        key: .alertness, unit: "score", group: nil, variant: "ALG-051", method: method, tier: .estimate,
        source: "sleep + caffeine log", window: "instant", citation: citation, paramsVersion: paramsVersion)

    /// The `alertness` metric at `now` from a forecast (blank with the reason when Missing or `now` is outside it).
    public static func alertnessMetric(_ f: Computed<Forecast>, at now: Date) -> Metric {
        switch f {
        case .failure(let m):
            return alertnessSpec.blank(m.reason, at: now)
        case .success(let fc):
            guard let c = fc.current else {
                return alertnessSpec.blank("now is outside today's waking forecast", at: now)
            }
            return alertnessSpec.metric(.success(c.score), at: now, note: fc.note)
        }
    }
}
