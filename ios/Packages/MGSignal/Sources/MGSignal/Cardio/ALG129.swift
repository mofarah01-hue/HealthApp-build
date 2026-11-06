import Foundation
import MGDomain

/// ALG-129 v1 — the AF screen variants kept beside ALG-013 (G-AF): pNN70 + SD1/SD2 (OpenStrap) and COSEn + ectopy
/// (Lake & Moorman 2011; whoop-rs). Ports with the sources' constants unchanged. Screens, not diagnoses.
/// Python reference: app/pclab/mglab/ref/cardio.py `af_pnn70`, `cosen`, `malik_clean`, `af_cosen`; goldens
/// app/shared/golden/cardio/ALG-129.json. Classes are ALG013.ScreenClass (registry `af_screen`).
public enum ALG129 {
    public static let pnn70Citation = "OpenStrap analytics clinical/irregular_rhythm.dart irregularBeatScreen @0441ef9"
    public static let cosenCitation = "Lake & Moorman 2011 Am J Physiol 300:H319; whoop-rs rr_irregularity @d11d8ef"

    // MARK: pNN70 + SD1/SD2 (OpenStrap irregularBeatScreen, constants unchanged)

    public static let p70MinBeats = 500
    public static let p70SD1SD2 = 0.70
    public static let p70ThresholdMs = 70.0
    public static let p70FlagPct = 30.0
    public static let p70MaxArtefact = 0.30
    public static let p70WindowSeconds = 300.0
    public static let p70MinWindowBeats = 40
    public static let p70Sustained = 0.5

    public struct Poincare: Sendable, Equatable {
        public var sd1: Double
        public var sd2: Double
        public var sd1sd2: Double
        public var pnn70: Double

        public init(sd1: Double, sd2: Double, sd1sd2: Double, pnn70: Double) {
            self.sd1 = sd1
            self.sd2 = sd2
            self.sd1sd2 = sd1sd2
            self.pnn70 = pnn70
        }
    }

    /// SD1 = SD (ddof 1) of successive differences / √2, SD2 = √(2 SDNN² − SD1²) (OpenStrap), pNN70 over the
    /// differences between beats adjacent in the input (`adjacent[i]`: beat i directly follows beat i − 1).
    static func poincare(_ nn: [Double], adjacent: [Bool]) -> Computed<Poincare> {
        var diffs: [Double] = []
        if nn.count >= 2 {
            for i in 1..<nn.count where adjacent[i] { diffs.append(nn[i] - nn[i - 1]) }
        }
        guard diffs.count >= 2, nn.count >= 2 else { return .missing("no successive clean beats for a Poincare plot") }
        let sd1 = SignalMath.sampleSD(diffs) / 2.0.squareRoot()
        let sdnn = SignalMath.sampleSD(nn)
        let v = 2.0 * sdnn * sdnn - sd1 * sd1
        let sd2 = v > 0 ? v.squareRoot() : 0.0
        guard sd2 > 0 else { return .missing("no long-term variability (SD2 = 0): the SD1/SD2 ratio is undefined") }
        let over = diffs.filter { abs($0) > p70ThresholdMs }.count
        return .success(Poincare(sd1: sd1, sd2: sd2, sd1sd2: sd1 / sd2,
                                 pnn70: 100.0 * Double(over) / Double(diffs.count)))
    }

    public struct PNN70Result: Sendable, Equatable {
        public var screenClass: ALG013.ScreenClass
        public var poincare: Poincare?
        public var nBeats: Int
        public var windowsValid: Int
        public var windowsFlagged: Int
        public var reason: String?

        public init(screenClass: ALG013.ScreenClass, poincare: Poincare?, nBeats: Int, windowsValid: Int,
                    windowsFlagged: Int, reason: String?) {
            self.screenClass = screenClass
            self.poincare = poincare
            self.nBeats = nBeats
            self.windowsValid = windowsValid
            self.windowsFlagged = windowsFlagged
            self.reason = reason
        }
    }

    /// ALG-129:pnn70 v1 — OpenStrap irregularBeatScreen. Beats outside 300–2000 ms are dropped (no difference spans a
    /// dropped beat). Needs ≥ 500 beats and artefact fraction ≤ 0.30 (else poor quality). Flagged when the whole span
    /// has SD1/SD2 ≥ 0.70 AND pNN70 ≥ 30 %, AND both hold in ≥ 50 % of the valid (≥ 40-beat) 5-min windows (a window
    /// starts at its first beat; a beat ≥ 300 s after that starts the next). `timesS` = beat end times (s).
    public static func pnn70(rrMs: [Double], timesS: [Double], artefactFraction: Double = 0.0) -> PNN70Result {
        var nn: [Double] = []
        var nnT: [Double] = []
        var adj: [Bool] = []
        var prev = -1
        for i in 0..<min(rrMs.count, timesS.count) where ALG013.rrRange.contains(rrMs[i]) {
            nn.append(rrMs[i])
            nnT.append(timesS[i])
            adj.append(prev == i - 1)
            prev = i
        }
        func poor(_ why: String) -> PNN70Result {
            PNN70Result(screenClass: .poorQuality, poincare: nil, nBeats: nn.count, windowsValid: 0, windowsFlagged: 0,
                        reason: why)
        }
        guard nn.count >= p70MinBeats else { return poor("needs \(p70MinBeats) clean beats (have \(nn.count))") }
        guard artefactFraction <= p70MaxArtefact else {
            return poor("artefact fraction \(String(format: "%.2f", artefactFraction)) > \(p70MaxArtefact)")
        }
        let agg: Poincare
        switch poincare(nn, adjacent: adj) {
        case .success(let p): agg = p
        case .failure(let m): return poor(m.reason)
        }
        let high = agg.sd1sd2 >= p70SD1SD2 && agg.pnn70 >= p70FlagPct
        var valid = 0
        var flagged = 0
        var bucket: [Double] = []
        var badj: [Bool] = []
        var w0 = nnT[0]
        func flush() {
            guard bucket.count >= p70MinWindowBeats else { return }
            valid += 1
            var a = badj
            a[0] = false
            if case .success(let p) = poincare(bucket, adjacent: a), p.sd1sd2 >= p70SD1SD2, p.pnn70 >= p70FlagPct {
                flagged += 1
            }
        }
        for i in 0..<nn.count {
            if nnT[i] - w0 >= p70WindowSeconds {
                flush()
                bucket = []
                badj = []
                w0 = nnT[i]
            }
            bucket.append(nn[i])
            badj.append(adj[i])
        }
        flush()
        let sustained = valid > 0 && Double(flagged) / Double(valid) >= p70Sustained
        return PNN70Result(screenClass: high && sustained ? .possibleAF : .regular, poincare: agg, nBeats: nn.count,
                           windowsValid: valid, windowsFlagged: flagged, reason: nil)
    }

    // MARK: COSEn + ectopy (whoop-rs rr_irregularity, constants unchanged)

    public static let cosenM = 1
    public static let cosenRMs = 30.0
    public static let cosenMinBeats = 12
    public static let cosenWindowBeats = 32
    public static let cosenStepBeats = 8
    public static let cosenMinEpisodeWindows = 24
    /// 32 + 23 × 8 = 216 beats before any episode is possible.
    public static let cosenMinScreenBeats = cosenWindowBeats + (cosenMinEpisodeWindows - 1) * cosenStepBeats
    public static let cosenIrregular = -1.28
    public static let cosenResidualFloor = -1.10
    public static let cosenMinAssessed = 0.50
    public static let cosenMaxRangeRejected = 0.20
    public static let cosenMaxGapSeconds: Int64 = 5
    /// Malik removal: > 20 % from the median of the up-to-4 neighbours (whoop-rs hrv.rs ECTOPIC_*).
    public static let malikRadius = 2
    public static let malikThreshold = 0.20

    /// ALG-129:cosen — COSEn = SampEn(1, 30 ms) + ln(2r) − ln(mean R-R) (Lake & Moorman 2011). Missing under 12 beats
    /// or when SampEn is undefined.
    public static func cosen(_ rr: [Double]) -> Computed<Double> {
        guard rr.count >= cosenMinBeats else { return .missing("COSEn needs \(cosenMinBeats) beats (have \(rr.count))") }
        let m = SignalMath.mean(rr)
        guard m > 0 else { return .missing("mean R-R is not positive") }
        return ALG013.sampleEntropy(rr, m: cosenM, r: cosenRMs).map { $0 + log(2.0 * cosenRMs) - log(m) }
    }

    /// Drop beats more than 20 % from the median of their up-to-4 neighbours (radius 2, itself excluded); survivors
    /// spliced together (whoop-rs hrv.rs clean_rr_kept). ≤ 2 beats are returned unchanged.
    public static func malikClean(_ rr: [Double]) -> [Double] {
        let n = rr.count
        guard n > malikRadius else { return rr }
        var out: [Double] = []
        for i in 0..<n {
            var nb: [Double] = []
            for j in max(0, i - malikRadius)...min(n - 1, i + malikRadius) where j != i { nb.append(rr[j]) }
            if nb.count < 2 {
                out.append(rr[i])
                continue
            }
            let med = SignalMath.median(nb)
            if med <= 0 || abs(rr[i] - med) / med <= malikThreshold { out.append(rr[i]) }
        }
        return out
    }

    public struct CosenResult: Sendable, Equatable {
        public var screenClass: ALG013.ScreenClass
        public var episodes: Int
        public var candidates: Int
        public var windows: Int
        public var windowsAssessed: Int
        public var windowsIrregular: Int
        public var reason: String?

        public init(screenClass: ALG013.ScreenClass, episodes: Int, candidates: Int, windows: Int,
                    windowsAssessed: Int, windowsIrregular: Int, reason: String?) {
            self.screenClass = screenClass
            self.episodes = episodes
            self.candidates = candidates
            self.windows = windows
            self.windowsAssessed = windowsAssessed
            self.windowsIrregular = windowsIrregular
            self.reason = reason
        }
    }

    /// ALG-129:cosen v1 — whoop-rs irregular-rhythm screen on beats in order (`ts` unix s, R-R ms). Windows of 32 beats
    /// every 8; assessed when ≥ 12 beats are in 300–2000 ms and ≤ 20 % were out of range; irregular when no two
    /// successive beats are > 5 s apart and COSEn of the in-range beats ≥ −1.28. ≥ 24 consecutive irregular windows =
    /// a candidate; an episode when its median residual COSEn (after Malik removal) ≥ −1.10.
    /// possible AF = episodes; other irregular = candidates whose ectopy could not be excluded; regular = none;
    /// poor quality = under 216 beats or under half the windows assessed. Not ported: whoop-rs quality.rs duplicate /
    /// rescaled-copy / coverage gates (MGStore de-duplicates by (ts, ord) on write).
    public static func cosenScreen(ts: [Int64], rrMs: [Double]) -> CosenResult {
        let n = min(ts.count, rrMs.count)
        guard n >= cosenMinScreenBeats else {
            return CosenResult(screenClass: .poorQuality, episodes: 0, candidates: 0, windows: 0, windowsAssessed: 0,
                               windowsIrregular: 0, reason: "calibrating: needs \(cosenMinScreenBeats) beats (have \(n))")
        }
        let starts = Array(stride(from: 0, through: n - cosenWindowBeats, by: cosenStepBeats))
        var assessed: [Bool] = []
        var irregular: [Bool] = []
        var residual: [Double?] = []
        for s in starts {
            let win = Array(rrMs[s..<(s + cosenWindowBeats)])
            let ranged = win.filter { ALG013.rrRange.contains($0) }
            let ok = ranged.count >= cosenMinBeats
                && Double(win.count - ranged.count) / Double(win.count) <= cosenMaxRangeRejected
            assessed.append(ok)
            var contiguous = true
            for k in 0..<(cosenWindowBeats - 1) where ts[s + k + 1] - ts[s + k] > cosenMaxGapSeconds {
                contiguous = false
                break
            }
            let c: Double? = ok ? cosen(ranged).value : nil
            irregular.append(ok && contiguous && (c.map { $0 >= cosenIrregular } ?? false))
            residual.append(ok ? cosen(malikClean(ranged)).value : nil)
        }
        let nAssessed = assessed.filter { $0 }.count
        guard Double(nAssessed) >= cosenMinAssessed * Double(starts.count) else {
            return CosenResult(screenClass: .poorQuality, episodes: 0, candidates: 0, windows: starts.count,
                               windowsAssessed: nAssessed, windowsIrregular: 0,
                               reason: "poor input quality: \(nAssessed) of \(starts.count) windows assessed")
        }
        var episodes = 0
        var candidates = 0
        var i = 0
        while i < irregular.count {
            if !irregular[i] {
                i += 1
                continue
            }
            let s = i
            while i < irregular.count && irregular[i] { i += 1 }
            if i - s < cosenMinEpisodeWindows { continue }
            candidates += 1
            let res = residual[s..<i].compactMap { $0 }
            if !res.isEmpty && SignalMath.median(res) >= cosenResidualFloor { episodes += 1 }
        }
        let cls: ALG013.ScreenClass = episodes > 0 ? .possibleAF : (candidates > 0 ? .otherIrregular : .regular)
        return CosenResult(screenClass: cls, episodes: episodes, candidates: candidates, windows: starts.count,
                           windowsAssessed: nAssessed, windowsIrregular: irregular.filter { $0 }.count, reason: nil)
    }

    // MARK: metrics

    public static let pnn70Spec = MetricSpec(
        key: .afScreen, unit: "class", group: "G-AF", variant: "ALG-129:pnn70", method: "ALG-129@1 pnn70-sd1sd2",
        tier: .research, source: "rr", window: "night", producer: .ours, citation: pnn70Citation,
        paramsVersion: "beats500 sd1sd2 0.70 pnn70 30 art0.30 w300 sustained0.5")
    public static let cosenSpec = MetricSpec(
        key: .afScreen, unit: "class", group: "G-AF", variant: "ALG-129:cosen", method: "ALG-129@1 cosen-ectopy",
        tier: .research, source: "rr", window: "night", producer: .ours, citation: cosenCitation,
        paramsVersion: "m1 r30 w32 s8 run24 cosen-1.28 residual-1.10")

    public static func metrics(pnn70 p: PNN70Result, cosen c: CosenResult, at: Date) -> [Metric] {
        [pnn70Spec.metric(.success(Double(p.screenClass.rawValue)), at: at,
                          note: p.reason ?? p.screenClass.label),
         cosenSpec.metric(.success(Double(c.screenClass.rawValue)), at: at,
                          note: c.reason ?? c.screenClass.label)]
    }
}
