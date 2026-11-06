import Foundation
import MGDomain

/// ALG-170 v1 — relative trends (D-TRENDS-1, D-POP-PRIOR): a measured quantity against Mo's OWN normal, never an absolute
/// clinical value, never a diagnosis. Python reference: pclab/mglab/ref/trends.py; goldens shared/golden/trends/ALG-170.json.
///
/// The baseline starts at the published population value and moves toward Mo's own as nights accumulate (D-POP-PRIOR):
/// the weight of his own data is w = n / (n + K), K = 14 nights (ours: the prior is worth as much as the 14-night minimum of
/// audit/RESEARCH-RELATIVE-TRENDS.md rule 1; a conventional weak-prior strength, not fitted).
///   centre = w·(own median) + (1 − w)·(population centre)   — only where a population centre is meaningful
///   spread = w·(own 1.4826·MAD, SD if MAD is 0) + (1 − w)·(population spread)
/// A population CENTRE is used only where people differ little next to the alert width (breathing rate, cyclic variation of
/// heart rate); never for resting HR, HRV or the raw skin-temperature counts (then the centre is his own median and at most
/// the spread is shrunk). Without a published spread the baseline is his own alone and needs 14 nights; with one, 7 nights
/// show a trend, labelled with the prior's weight. Levels: concerning z ≥ 2 → 1 (worth noting), ≥ 3 → 2 (thresholds as ALG-161).
///
/// The six trends and their backing (the card text lives in MGContext `TrendCatalogue`):
/// - breathing  night breathing-rate estimate (ALG-121 R-R; enhanced: ALG-121 from the pulse) vs own baseline.
/// - apnea      cyclic variation of heart rate per hour (ALG-023, nights with ≥ 4 h) — a screen trend, not AHI.
/// - afburden   share of still 5-min R-R windows flagged irregular (ALG-013) over the last 7 nights; ECG confirms or clears.
/// - orthostatic  heart-rate rise at a rest-to-walk onset (ALG-171) vs own baseline.
/// - perfusion  PPG perfusion index (ALG-172) vs own baseline; enhanced only (raw PPG).
/// - illness    RHR up, HRV down, breathing up, skin temperature up (D-BODY-WALK-1: ± from baseline feeds it) together on two nights.
public enum ALG170 {
    public static let id = "ALG-170"
    public static let version = "ALG-170@1"
    public static let citation = "Mishra 2020; Smarr 2020; Radin 2020; Hayano 2020; Chen 2018 (AHA AF burden); Perez 2019; "
        + "Freeman 2011; Plews 2013 (priors and thresholds ours)"
    public static let paramsVersion = "k14 win28 min7/14 note2 strong3 sign1.5 af7n3 priors:br15/1 cvhr6.4/4 rhr2 ln.15"

    public static let kPrior = 14.0
    public static let window = 28
    public static let minWithPrior = 7
    public static let minOwn = 14
    public static let noteZ = 2.0
    public static let strongZ = 3.0
    public static let signZ = 1.5
    public static let illnessMinSigns = 3
    public static let madToSD = 1.4826
    /// Nights the caller hands over per series: the window, the night before it, and last night.
    public static let historyNights = 29
    /// The AF share's one-value night series (written by NightPipeline, read back by later mornings).
    public static let afShareSeries = "af_irregular_share"

    public enum Variant: String, CaseIterable, Sendable {
        case breathing, apnea, afburden, orthostatic, perfusion, illness
    }

    public enum Direction: Sendable { case up, down, both }

    public struct Prior: Sendable, Equatable {
        public var centre: Double?
        public var spread: Double?
        public init(centre: Double?, spread: Double?) {
            self.centre = centre
            self.spread = spread
        }
    }

    /// Population priors (see the file header for which carry a centre).
    public static let breathingPrior = Prior(centre: 15.0, spread: 1.0)
    public static let apneaPrior = Prior(centre: 6.4, spread: 4.0)
    public static let rhrPrior = Prior(centre: nil, spread: 2.0)
    public static let lnRmssdPrior = Prior(centre: nil, spread: 0.15)
    public static let ownOnly = Prior(centre: nil, spread: nil)

    // MARK: engine

    public struct Baseline: Sendable, Equatable {
        public var n: Int
        public var median: Double
        public var ownSpread: Double?
        public var centre: Double
        public var spread: Double
        public var wOwn: Double
        public var prior: Prior
    }

    public struct TrendResult: Sendable, Equatable {
        public var base: Baseline
        public var latest: Double
        public var z: Double
        public var level: Int
    }

    static func ok(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }

    static func clean(_ history: [Double?], window: Int = ALG170.window) -> [Double] {
        let h = history.compactMap(ok)
        return h.count > window ? Array(h.suffix(window)) : h
    }

    public static func baseline(_ history: [Double?], prior: Prior) -> Computed<Baseline> {
        let h = clean(history)
        let n = h.count
        let need = prior.spread != nil ? minWithPrior : minOwn
        if n < need { return .missing("collecting: \(n) of \(need) nights so far") }
        let med = SignalMath.median(h)
        let mad = SignalMath.median(h.map { abs($0 - med) }) * madToSD
        var own: Double? = mad > 0 ? mad : (n >= 2 ? SignalMath.sampleSD(h) : 0)
        if let o = own, !(o > 0) { own = nil }
        let w = Double(n) / (Double(n) + kPrior)
        guard let ps = prior.spread else {
            guard let o = own else { return .missing("no spread in your baseline") }
            return .success(Baseline(n: n, median: med, ownSpread: o, centre: med, spread: o, wOwn: 1.0, prior: prior))
        }
        let centre = prior.centre.map { w * med + (1 - w) * $0 } ?? med
        let spread = own.map { w * $0 + (1 - w) * ps } ?? ps
        return .success(Baseline(n: n, median: med, ownSpread: own, centre: centre, spread: spread, wOwn: w, prior: prior))
    }

    public static func trend(_ history: [Double?], latest: Double?, prior: Prior, direction: Direction) -> Computed<TrendResult> {
        guard let x = ok(latest) else { return .missing("no value last night") }
        switch baseline(history, prior: prior) {
        case .failure(let m): return .failure(m)
        case .success(let b):
            let z = (x - b.centre) / b.spread
            let concern: Double
            switch direction {
            case .up: concern = z
            case .down: concern = -z
            case .both: concern = abs(z)
            }
            let level = concern >= strongZ ? 2 : concern >= noteZ ? 1 : 0
            return .success(TrendResult(base: b, latest: x, z: z, level: level))
        }
    }

    /// CVHR per hour counts only for nights with ≥ 4 observed hours (Hayano; the ALG-161 gate).
    public static func gateHours(_ values: [Double?], hours: [Double?], minHours: Double = 4.0) -> [Double?] {
        zip(values, hours).map { v, h in
            if let v = ok(v), let h = ok(h), h >= minHours { return v }
            return nil
        }
    }

    // MARK: AF burden

    public struct AFBurden: Sendable, Equatable {
        public var value: Double
        public var nights: Int
        public var flaggedNights: Int
        public var level: Int
        public var ecg: Bool?
    }

    public static func afBurden(shares: [Double?], flagged: [Bool?], ecgIrregular: Bool?) -> Computed<AFBurden> {
        let s = Array(shares.suffix(7))
        let f = Array(flagged.suffix(7))
        let g = s.compactMap(ok)
        if g.count < 3 { return .missing("collecting: \(g.count) of 3 nights with enough still R-R so far") }
        let nFlag = f.filter { $0 == true }.count
        var level = 0
        if nFlag >= 1 && ecgIrregular != false { level = ecgIrregular == true ? 2 : 1 }
        return .success(AFBurden(value: SignalMath.mean(g) * 100.0, nights: g.count, flaggedNights: nFlag, level: level,
                                 ecg: ecgIrregular))
    }

    /// Share of a night's assessed still windows flagged irregular (possible AF or other irregular); nil under 12 windows.
    public static let afMinAssessed = 12
    public static func afShare(_ s: ALG013.Screen) -> Computed<(share: Double, assessed: Int)> {
        let a = s.assessed
        if a < afMinAssessed { return .missing("only \(a) still 5-minute windows assessed, \(afMinAssessed) needed") }
        return .success((Double(s.possibleAFWindows + s.irregularWindows) / Double(a), a))
    }

    // MARK: illness

    public struct Illness: Sendable, Equatable {
        public var index: Double
        public var signs: Int
        public var high: Int
        public var level: Int
        public var twoNights: Bool
        /// (input name, concerning z) of tonight, in the order resting HR, HRV, breathing, skin temperature.
        public var parts: [Part]
    }

    public struct Part: Sendable, Equatable {
        public var name: String
        public var z: Double
    }

    public static func illness(rhr: [Double?], lnRmssd: [Double?], resp: [Double?], temp: [Double?]) -> Computed<Illness> {
        let inputs: [(vals: [Double?], name: String, prior: Prior, sign: Double)] = [
            (rhr, "resting heart rate", rhrPrior, 1), (lnRmssd, "HRV", lnRmssdPrior, -1),
            (resp, "breathing", Prior(centre: nil, spread: breathingPrior.spread), 1), (temp, "skin temperature", ownOnly, 1),
        ]
        func night(_ k: Int) -> Computed<Illness> {
            var parts: [Part] = []
            for i in inputs where i.vals.count > k && k >= 1 {
                if case .success(let t) = trend(Array(i.vals[..<k]), latest: i.vals[k], prior: i.prior,
                                                direction: i.sign > 0 ? .up : .down) {
                    parts.append(Part(name: i.name, z: i.sign * t.z))
                }
            }
            if parts.count < illnessMinSigns {
                return .missing("collecting: \(parts.count) of \(illnessMinSigns) inputs have a baseline yet")
            }
            let hi = parts.filter { $0.z >= signZ }.count
            return .success(Illness(index: SignalMath.mean(parts.map(\.z)), signs: parts.count, high: hi,
                                    level: hi >= 3 ? 2 : hi >= 2 ? 1 : 0, twoNights: false, parts: parts))
        }
        let n = inputs.map(\.vals.count).max() ?? 0
        if n < 2 { return .missing("collecting: no nights yet") }
        guard case .success(var tonight) = night(n - 1) else { return night(n - 1) }
        let last = night(n - 2)
        tonight.level = min(tonight.level, last.value?.level ?? 0)
        tonight.twoNights = last.value != nil
        return .success(tonight)
    }

    // MARK: stage

    public struct StageInput: Sendable {
        public var resp: [Double?] = []
        public var respEnhanced: [Double?] = []
        public var cvhr: [Double?] = []
        public var cvhrHours: [Double?] = []
        public var afShares: [Double?] = []
        public var afFlags: [Bool?] = []
        public var ecgIrregular: Bool?
        public var orthostatic: [Double?] = []
        public var perfusion: [Double?] = []
        public var rhr: [Double?] = []
        public var lnRmssd: [Double?] = []
        public var temp: [Double?] = []
        public init() {}
    }

    public enum Detail: Sendable, Equatable {
        case trend(TrendResult)
        case af(AFBurden)
        case illness(Illness)
    }

    public struct Out: Sendable, Equatable {
        public var value: Computed<Double>
        public var level: Int?
        public var tier: String
        public var detail: Detail?
    }

    static func pack(_ r: Computed<TrendResult>, tier: String) -> Out {
        switch r {
        case .failure(let m): return Out(value: .failure(m), level: nil, tier: tier, detail: nil)
        case .success(let t): return Out(value: .success(t.z), level: t.level, tier: tier, detail: .trend(t))
        }
    }

    public static func stage(_ inp: StageInput) -> [Variant: Out] {
        var out: [Variant: Out] = [:]
        // breathing: the pulse-derived series when it has a baseline of its own, else the R-R one; never mixed
        let enh = inp.respEnhanced
        let useEnh = enh.count >= 2 && ok(enh.last ?? nil) != nil && clean(Array(enh.dropLast())).count >= minWithPrior
        let series = useEnh ? enh : inp.resp
        out[.breathing] = pack(series.count >= 2
            ? trend(Array(series.dropLast()), latest: series.last ?? nil, prior: breathingPrior, direction: .up)
            : .missing("no nights yet"), tier: useEnh ? "enhanced" : "base")
        // apnea
        let g = inp.cvhr.count == inp.cvhrHours.count ? gateHours(inp.cvhr, hours: inp.cvhrHours)
            : [Double?](repeating: nil, count: inp.cvhr.count)
        out[.apnea] = pack(g.count >= 2 ? trend(Array(g.dropLast()), latest: g.last ?? nil, prior: apneaPrior, direction: .up)
            : .missing("no nights yet"), tier: "base")
        // AF burden
        switch afBurden(shares: inp.afShares, flagged: inp.afFlags, ecgIrregular: inp.ecgIrregular) {
        case .failure(let m): out[.afburden] = Out(value: .failure(m), level: nil, tier: "base", detail: nil)
        case .success(let a): out[.afburden] = Out(value: .success(a.value), level: a.level, tier: "base", detail: .af(a))
        }
        // orthostatic (own baseline only)
        let o = inp.orthostatic
        out[.orthostatic] = pack(o.count >= 2 ? trend(Array(o.dropLast()), latest: o.last ?? nil, prior: ownOnly, direction: .up)
            : .missing("no days yet"), tier: "base")
        // perfusion (raw PPG, own baseline only)
        let p = inp.perfusion
        out[.perfusion] = pack(p.count >= 2 ? trend(Array(p.dropLast()), latest: p.last ?? nil, prior: ownOnly, direction: .both)
            : .missing("no nights yet"), tier: "enhanced")
        // illness
        switch illness(rhr: inp.rhr, lnRmssd: inp.lnRmssd, resp: inp.resp, temp: inp.temp) {
        case .failure(let m): out[.illness] = Out(value: .failure(m), level: nil, tier: "base", detail: nil)
        case .success(let i): out[.illness] = Out(value: .success(i.index), level: i.level, tier: "base", detail: .illness(i))
        }
        return out
    }

    // MARK: words

    static func f(_ x: Double, _ d: Int = 1) -> String { String(format: "%.\(d)f", x) }

    /// "Baseline 15.0 br/min: population 15.0 and yours 15.2 (20 nights), yours counts for 59 %." The card shows 'population'
    /// beside 'yours (N days)' from this (D-POP-PRIOR).
    static func baselineLine(_ b: Baseline, unit: String, digits: Int = 1) -> String {
        if let pc = b.prior.centre {
            return "Baseline \(f(b.centre, digits)) \(unit): population \(f(pc, digits)), yours \(f(b.median, digits)) "
                + "(\(b.n) nights); yours counts for \(Int((b.wOwn * 100).rounded())) %."
        }
        if b.prior.spread != nil {
            return "Baseline \(f(b.centre, digits)) \(unit): yours (\(b.n) nights); the usual night-to-night spread leans on the "
                + "population value (yours counts for \(Int((b.wOwn * 100).rounded())) %)."
        }
        return "Baseline \(f(b.centre, digits)) \(unit): yours only (\(b.n) nights), no population value."
    }

    public static func note(_ v: Variant, _ o: Out) -> String? {
        guard let d = o.detail else { return nil }
        switch (v, d) {
        case (.breathing, .trend(let t)):
            let how = t.level == 0 ? "within your usual range" : t.level == 1 ? "above your usual" : "well above your usual"
            return "Breathing rate last night \(f(t.latest)) br/min (estimate), \(how). \(baselineLine(t.base, unit: "br/min")) "
                + "A trend against your own baseline, not a clinical measurement."
        case (.apnea, .trend(let t)):
            let how = t.level == 0 ? "within your usual range" : t.level == 1 ? "above your usual" : "well above your usual"
            return "Heart-rate cycles per hour last night \(f(t.latest)) (a breathing-pattern screen), \(how). "
                + "\(baselineLine(t.base, unit: "per hour")) A screen trend, not an apnea-hypopnea index and not a diagnosis."
        case (.afburden, .af(let a)):
            let share = "\(f(a.value)) % of the still time on \(a.nights) of the last 7 nights"
            switch a.level {
            case 2: return "Your pulse looked irregular (\(share)) and a 60-second ECG check also looked irregular. "
                + "This is a screen, not a diagnosis; worth mentioning to a doctor, who can confirm with a proper ECG."
            case 1: return "Possible irregular rhythm on \(a.flaggedNights) of the last 7 nights (\(share)). This is a pulse "
                + "screen, not a diagnosis; a 60-second ECG check can look closer. Population norm for this share: about 0 %."
            default: return a.ecg == false
                ? "A 60-second ECG check looked regular. Irregular-looking time: \(share)."
                : "Irregular-looking time: \(share). Population norm: about 0 %."
            }
        case (.orthostatic, .trend(let t)):
            let how = t.level == 0 ? "within your usual range" : t.level == 1 ? "a bigger rise than usual" : "a much bigger rise than usual"
            return "Heart rate rose \(f(t.latest)) bpm in the half minute after standing up to walk, \(how). "
                + "\(baselineLine(t.base, unit: "bpm")) Detected from wrist movement, not a clinical stand test."
        case (.perfusion, .trend(let t)):
            let how = t.level == 0 ? "within your usual range" : t.z < 0 ? "lower than your usual" : "higher than your usual"
            return "Pulse-signal strength (perfusion index) last night \(f(t.latest, 2)) % of the signal, \(how) (uncalibrated, "
                + "raw-pulse bursts, still seconds only). \(baselineLine(t.base, unit: "%", digits: 2)) Not blood flow or circulation."
        case (.illness, .illness(let i)):
            let names = i.parts.filter { $0.z >= signZ }.map(\.name).joined(separator: ", ")
            let nights = i.twoNights ? "" : " (one night so far)"
            if i.level == 0 {
                return i.high == 0 ? "None of resting heart rate, HRV, breathing or skin temperature is past your usual."
                    : "\(i.high) of \(i.signs) inputs (\(names)) are past your usual\(nights). Worth watching, not a warning yet."
            }
            return "\(i.high) of \(i.signs) inputs (\(names)) are past your usual on two nights in a row. A pattern that often goes "
                + "with the body fighting something, or with a hard stretch of life, not a diagnosis."
        default: return nil
        }
    }

    // MARK: metrics

    public static func spec(_ v: Variant, tier: String) -> MetricSpec {
        MetricSpec(key: .trend, unit: v == .afburden ? "pct" : "z", group: "G-TREND", variant: v.rawValue,
                   method: "\(version) relative-trend \(tier)", tier: tier == "enhanced" ? .research : .estimate,
                   source: "night", window: "night", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    }

    public static func levelSpec(_ v: Variant, tier: String) -> MetricSpec {
        MetricSpec(key: .trendLevel, unit: "level_0_2", group: "G-TREND", variant: v.rawValue,
                   method: "\(version) relative-trend \(tier)", tier: tier == "enhanced" ? .research : .estimate,
                   source: "night", window: "night", producer: .ours, citation: citation, paramsVersion: paramsVersion)
    }

    /// Two metrics per trend: `trend` (z, or % for the AF share) with the calm sentence, and `trend_level` (0, 1, 2).
    /// Not enough data = both blank with "collecting: …".
    public static func metrics(_ inp: StageInput, at: Date) -> [Metric] {
        let r = stage(inp)
        var out: [Metric] = []
        for v in Variant.allCases {
            guard let o = r[v] else { continue }
            out.append(spec(v, tier: o.tier).metric(o.value, at: at, note: note(v, o)))
            if let l = o.level {
                out.append(levelSpec(v, tier: o.tier).metric(.success(Double(l)), at: at))
            } else {
                out.append(levelSpec(v, tier: o.tier).blank(o.value.missingReason ?? "no level", at: at))
            }
        }
        return out
    }
}
