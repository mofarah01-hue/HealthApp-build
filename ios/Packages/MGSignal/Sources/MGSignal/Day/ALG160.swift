import Foundation
import MGDomain

/// ALG-160 v1 — readiness 1-100, Garmin-style Training Readiness (Orchard "MS-19" rebuilt; D-RECOV-WALK-2). Replaces the
/// ALG-036 "n of 5 in your range" count. Python reference: pclab/mglab/ref/readiness.py; goldens
/// shared/golden/readiness/ALG-160.json.
///
/// The CORE is published and backed: HRV status = the 7-day rolling mean of nightly lnRMSSD against your own normal range
/// (Plews et al., Eur J Appl Physiol 2012;112:3729; Sports Med 2013;43:773; ≥ 3 valid nights a week is enough, Plews IJSPP
/// 2014), the range being baseline mean ± 0.5 SD (Buchheit, Front Physiol 2014;5:73). HRV-guided training from that status
/// has small trials behind it (Kiviniemi 2007; Granero-Gallegos 2020: 6 RCTs, 195 people) — NOT a validated clinical score.
/// The five weights, the points curves and the load maths are OUR ESTIMATE (Garmin, WHOOP and Oura publish no weights).
/// Above your range is never penalised (the old two-sided count punished a good night; audit 6.1).
///
/// BASE tier: nightly R-R from the strap's own sleep period + sleep performance + strap-HR training load + daily stress.
/// ENHANCED tier (D-ALG-TIERS): the same status computed on a series of 60 s morning readings (Esco & Flatt 2014; Flatt &
/// Esco 2016) when that series alone has enough nights. The two series are never mixed.
public enum ALG160 {
    public static let id = "ALG-160"
    public static let citation = "Plews 2012/2013/2014; Buchheit 2014; Kiviniemi 2007; Banister 1975; Gabbett 2016 (weights: our estimate)"
    public static let paramsVersion = "w7 min3 base60 min14 full28 swc0.5 weights hrv.40 sleep.20 rt.15 lb.10 stress.15"

    /// Variant of the optional ENHANCED input: lnRMSSD of the 60 s morning reading (window "morning").
    public static let morningVariant = "ALG-010:spot60"
    public static let hrvWindow = 7
    public static let hrvMinInWindow = 3
    public static let baseMax = 60
    public static let baseMin = 14
    public static let baseFull = 28
    public static let swcK = 0.5
    public static let weights: [String: Double] = ["hrv": 0.40, "sleep": 0.20, "recovery_time": 0.15,
                                                   "load_balance": 0.10, "stress": 0.15]
    /// Component order of a result (HRV first).
    public static let order = ["hrv", "sleep", "recovery_time", "load_balance", "stress"]
    public static let minOthers = 2
    static let recoveryTauDays = 7.0
    static let recoveryFullDays = 4.0
    static let sweetLow = 0.8
    static let sweetHigh = 1.3
    static let ratioFloor = 0.4
    static let ratioCeil = 2.0
    static let stressNeutral = 1.5
    static let stressMax = 3.0
    static let sleepLastShare = 0.7
    /// Nights the caller must hand over: the baseline plus last night.
    public static let historyNights = baseMax + 1

    public enum HRVState: String, Sendable { case below, balanced, above }
    public enum Tier: String, Sendable { case base, enhanced }
    public enum Band: String, Sendable { case poor, low, moderate, high, prime }

    public struct HRVStatus: Sendable, Equatable {
        public var mean7: Double
        public var mu: Double
        public var sd: Double
        public var swc: Double
        /// (mean7 − mu) / swc: distance from the normal in "smallest worthwhile change" units; band edges at ±1.
        public var d: Double
        public var state: HRVState
        public var nWindow: Int
        public var nBase: Int
        public var cv7: Double?
    }

    public struct Component: Sendable, Equatable {
        public var name: String
        public var points: Double
        public var weight: Double
    }

    public struct Input: Sendable {
        /// Nightly lnRMSSD, oldest → newest, last = last night (nil = none). Own nights only.
        public var lnNights: [Double?]
        /// The enhanced series (60 s morning readings), same shape; nil = none exist.
        public var morningLn: [Double?]?
        public var sleepLast: Double?
        public var sleepPrev: [Double?]
        public var atl: Double?
        public var ctl: Double?
        public var stressDays: [Double?]

        public init(lnNights: [Double?], morningLn: [Double?]? = nil, sleepLast: Double? = nil, sleepPrev: [Double?] = [],
                    atl: Double? = nil, ctl: Double? = nil, stressDays: [Double?] = []) {
            self.lnNights = lnNights
            self.morningLn = morningLn
            self.sleepLast = sleepLast
            self.sleepPrev = sleepPrev
            self.atl = atl
            self.ctl = ctl
            self.stressDays = stressDays
        }
    }

    public struct Reading: Sendable, Equatable {
        public var score: Int
        public var raw: Double
        public var band: Band
        public var tier: Tier
        public var hrvState: HRVState
        public var hrvD: Double
        public var nBase: Int
        public var nWindow: Int
        /// Baseline shorter than 28 nights: shown as an estimate.
        public var provisional: Bool
        /// Days of fatigue left to burn off (7 ln(ATL/CTL)); nil without a load.
        public var recoveryDays: Double?
        public var components: [Component]
    }

    static func ok(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }

    // MARK: HRV status

    public static func hrvStatus(_ lnNights: [Double?]) -> Computed<HRVStatus> {
        if lnNights.isEmpty { return .missing("no nights") }
        let window = lnNights.suffix(hrvWindow).compactMap { ok($0) }
        if window.count < hrvMinInWindow {
            return .missing("needs \(hrvMinInWindow) valid nights in the last \(hrvWindow) (have \(window.count))")
        }
        let base = lnNights.dropLast().suffix(baseMax).compactMap { ok($0) }
        if base.count < baseMin { return .missing("Learning your normal: \(base.count) of \(baseMin) nights so far") }
        let sd = SignalMath.sampleSD(base)
        guard sd > 0 else { return .missing("baseline has no spread") }
        let mu = SignalMath.mean(base)
        let m7 = SignalMath.mean(window)
        let swc = swcK * sd
        let d = (m7 - mu) / swc
        let state: HRVState = d < -1.0 ? .below : (d > 1.0 ? .above : .balanced)
        let cv: Double? = (window.count >= 2 && m7 > 0) ? SignalMath.sampleSD(window) / m7 * 100.0 : nil
        return .success(HRVStatus(mean7: m7, mu: mu, sd: sd, swc: swc, d: d, state: state, nWindow: window.count,
                                  nBase: base.count, cv7: cv))
    }

    /// The enhanced status when the morning series is complete by itself, else the base one.
    public static func chooseHRV(night: [Double?], morning: [Double?]?) -> (status: Computed<HRVStatus>, tier: Tier) {
        if let morning, case .success(let e) = hrvStatus(morning) { return (.success(e), .enhanced) }
        return (hrvStatus(night), .base)
    }

    // MARK: Component points

    /// 100 at or above the lower edge of the band; 30 points per unit below it. Above is never penalised.
    public static func hrvPoints(_ d: Double) -> Double {
        d >= -1.0 ? 100.0 : max(0.0, 100.0 + 30.0 * (d + 1.0))
    }

    public static func sleepPoints(last: Double?, previous: [Double?]) -> Computed<Double> {
        guard let last = ok(last) else { return .missing("no sleep performance for last night") }
        var s = 100.0 * min(max(last, 0.0), 1.0)
        let prev = previous.compactMap { ok($0) }.map { 100.0 * min(max($0, 0.0), 1.0) }
        if !prev.isEmpty { s = sleepLastShare * s + (1.0 - sleepLastShare) * SignalMath.mean(prev) }
        return .success(s)
    }

    /// Days for the acute load to decay to the chronic level, 7 ln(ATL/CTL) when ATL > CTL; and its points.
    public static func recoveryTime(atl: Double?, ctl: Double?) -> Computed<(days: Double, points: Double)> {
        guard let a = ok(atl), let c = ok(ctl), a >= 0 else { return .missing("no acute/chronic load") }
        guard c > 0 else { return .missing("chronic load is 0, so the ratio is undefined") }
        let days = a > c ? recoveryTauDays * log(a / c) : 0.0
        return .success((days: days, points: 100.0 * max(0.0, 1.0 - days / recoveryFullDays)))
    }

    /// ATL/CTL 0.8-1.3 = 100; linear to 0 at 0.4 and at 2.0.
    public static func loadBalance(atl: Double?, ctl: Double?) -> Computed<(ratio: Double, points: Double)> {
        guard let a = ok(atl), let c = ok(ctl), a >= 0 else { return .missing("no acute/chronic load") }
        guard c > 0 else { return .missing("chronic load is 0, so the ratio is undefined") }
        let r = a / c
        let p: Double
        if r < sweetLow {
            p = 100.0 * max(0.0, (r - ratioFloor) / (sweetLow - ratioFloor))
        } else if r > sweetHigh {
            p = 100.0 * max(0.0, 1.0 - (r - sweetHigh) / (ratioCeil - sweetHigh))
        } else {
            p = 100.0
        }
        return .success((ratio: r, points: p))
    }

    public static func stressPoints(_ days: [Double?]) -> Computed<Double> {
        let v = days.compactMap { ok($0) }
        if v.count < 2 { return .missing("needs 2 of the last 3 days of stress (have \(v.count))") }
        let m = SignalMath.mean(v)
        return .success(m <= stressNeutral ? 100.0 : max(0.0, 100.0 * (stressMax - m) / (stressMax - stressNeutral)))
    }

    public static func band(_ score: Int) -> Band {
        if score < 25 { return .poor }
        if score < 50 { return .low }
        if score < 75 { return .moderate }
        if score < 95 { return .high }
        return .prime
    }

    // MARK: Score

    public static func readiness(_ inp: Input) -> Computed<Reading> {
        let (st, tier) = chooseHRV(night: inp.lnNights, morning: inp.morningLn)
        let status: HRVStatus
        switch st {
        case .failure(let m): return .failure(m)
        case .success(let s): status = s
        }
        var comps = [Component(name: "hrv", points: hrvPoints(status.d), weight: weights["hrv"]!)]
        if case .success(let s) = sleepPoints(last: inp.sleepLast, previous: inp.sleepPrev) {
            comps.append(Component(name: "sleep", points: s, weight: weights["sleep"]!))
        }
        let rt = recoveryTime(atl: inp.atl, ctl: inp.ctl)
        var recoveryDays: Double?
        if case .success(let r) = rt {
            recoveryDays = r.days
            comps.append(Component(name: "recovery_time", points: r.points, weight: weights["recovery_time"]!))
        }
        if case .success(let lb) = loadBalance(atl: inp.atl, ctl: inp.ctl) {
            comps.append(Component(name: "load_balance", points: lb.points, weight: weights["load_balance"]!))
        }
        if case .success(let s) = stressPoints(inp.stressDays) {
            comps.append(Component(name: "stress", points: s, weight: weights["stress"]!))
        }
        if comps.count - 1 < minOthers {
            return .missing("needs HRV and \(minOthers) of sleep, recovery time, load balance, stress (have \(comps.count - 1))")
        }
        var num = 0.0
        var den = 0.0
        for c in comps {
            num += c.points * c.weight
            den += c.weight
        }
        let raw = num / den
        let score = min(100, max(1, Int((raw + 0.5).rounded(.down))))
        return .success(Reading(score: score, raw: raw, band: band(score), tier: tier, hrvState: status.state,
                               hrvD: status.d, nBase: status.nBase, nWindow: status.nWindow,
                               provisional: status.nBase < baseFull, recoveryDays: recoveryDays, components: comps))
    }

    // MARK: Assessment (what the presenters show: a score, or why not)

    public enum Status: String, Sendable { case ok, learning, tooLittle = "too_little" }

    /// One row per part, scored or not (a part that was not scored says why).
    public struct Row: Sendable, Equatable {
        public var name: String
        public var points: Double?
        public var weight: Double
        public var reason: String?
    }

    public struct Assessment: Sendable, Equatable {
        public var status: Status
        public var reading: Reading?
        public var rows: [Row]
        public var reason: String?
        /// Own nights in the baseline (what "learning" counts).
        public var nBase: Int
        public var tier: Tier
    }

    /// `readiness` plus the words for "learning" (3 or more valid nights this week, baseline under 14) and "too little".
    public static func assess(_ inp: Input) -> Assessment {
        let (st, tier) = chooseHRV(night: inp.lnNights, morning: inp.morningLn)
        let series = tier == .enhanced ? (inp.morningLn ?? []) : inp.lnNights
        let nBase = series.dropLast().suffix(baseMax).compactMap { ok($0) }.count
        let nWindow = series.suffix(hrvWindow).compactMap { ok($0) }.count
        var rows: [Row] = []
        switch st {
        case .success(let s):
            rows.append(Row(name: "hrv", points: hrvPoints(s.d), weight: weights["hrv"]!, reason: nil))
        case .failure(let m):
            rows.append(Row(name: "hrv", points: nil, weight: weights["hrv"]!, reason: m.reason))
        }
        func row(_ name: String, _ c: Computed<Double>) {
            switch c {
            case .success(let p): rows.append(Row(name: name, points: p, weight: weights[name]!, reason: nil))
            case .failure(let m): rows.append(Row(name: name, points: nil, weight: weights[name]!, reason: m.reason))
            }
        }
        row("sleep", sleepPoints(last: inp.sleepLast, previous: inp.sleepPrev))
        row("recovery_time", recoveryTime(atl: inp.atl, ctl: inp.ctl).map { $0.points })
        row("load_balance", loadBalance(atl: inp.atl, ctl: inp.ctl).map { $0.points })
        row("stress", stressPoints(inp.stressDays))
        switch readiness(inp) {
        case .success(let r):
            return Assessment(status: .ok, reading: r, rows: rows, reason: nil, nBase: nBase, tier: tier)
        case .failure(let m):
            let learning = nWindow >= hrvMinInWindow && nBase < baseMin
            return Assessment(status: learning ? .learning : .tooLittle, reading: nil, rows: rows, reason: m.reason,
                              nBase: nBase, tier: tier)
        }
    }

    // MARK: Metric

    /// Orchard keeps its variant id MS-19 (Mo's saved choices still point at it); the method string says what it is now.
    public static let spec = MetricSpec(
        key: .readiness, unit: "score_1_100", group: "G-READY", variant: "MS-19", method: "ALG-160@1 training-readiness-style",
        tier: .estimate, source: "hrv_ln_rmssd,sleep_performance,atl,ctl,stress", window: "morning", producer: .ours,
        citation: citation, paramsVersion: paramsVersion)

    /// The metric with a plain-words note. Enhanced/base and "estimate" (short baseline) are named in the note.
    public static func metric(_ r: Computed<Reading>, at: Date) -> Metric {
        switch r {
        case .failure(let m):
            return spec.blank(m.reason, at: at)
        case .success(let x):
            let hrv: String
            switch x.hrvState {
            case .below: hrv = "HRV below your normal range"
            case .balanced: hrv = "HRV in your normal range"
            case .above: hrv = "HRV above your normal range"
            }
            var parts = [hrv, x.tier == .enhanced ? "60 s morning readings" : "overnight R-R"]
            if x.provisional { parts.append("estimate: baseline \(x.nBase) of \(baseFull) nights") }
            parts.append("weights are our estimate, not WHOOP's or Garmin's")
            return spec.metric(.success(Double(x.score)), at: at, note: parts.joined(separator: " · "))
        }
    }
}
