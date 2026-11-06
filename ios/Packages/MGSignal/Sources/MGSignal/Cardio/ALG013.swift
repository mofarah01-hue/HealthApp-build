import Foundation
import MGDomain

/// ALG-013 v1 — AF screen over still, high-coverage 5-min windows of R-R, plus sample entropy (`hrv_sampen`, APP-233).
/// A SCREEN, not a diagnosis: wrist pulse R-R has no P waves. Constants marked "ours v0" have no labelled wrist data
/// behind them yet. Python reference: app/pclab/mglab/ref/cardio.py `sample_entropy`, `sampen_standard`,
/// `nightly_sampen`, `af_window_features`, `af_screen`; goldens app/shared/golden/cardio/ALG-013.json.
public enum ALG013 {
    public static let citation = "Richman & Moorman 2000 (SampEn); Dash 2009 Ann Biomed Eng 37:1701 (nRMSSD, TPR); "
        + "Perez 2019 NEJM (repeated tachograms)"

    /// Registry `af_screen` classes (ARCHITECTURE.md 8.3).
    public enum ScreenClass: Int, Sendable, CaseIterable {
        case regular = 0
        case possibleAF = 1
        case otherIrregular = 2
        case poorQuality = 3

        public var label: String {
            switch self {
            case .regular: return "regular"
            case .possibleAF: return "possible AF"
            case .otherIrregular: return "other irregular"
            case .poorQuality: return "poor quality"
            }
        }
    }

    // Sample entropy
    /// O(N²) pairs: a night is screened in windows, never as one series.
    public static let sampEnMaxBeats = 5000

    // Screen (ours v0 unless cited)
    public static let windowSeconds = 300.0
    public static let minCoverage = 0.9
    public static let minBeats = 100
    /// Physiological range (whoop-rs hrv.rs RR_MIN_MS / RR_MAX_MS; OpenStrap irregular_rhythm.dart).
    public static let rrRange: ClosedRange<Double> = 300.0...2000.0
    /// RMSSD / mean NN marks irregularity (ours v0, after Dash 2009).
    public static let nRmssdThreshold = 0.10
    /// SampEn(2, 0.2 SD) at or above this = unpredictable beat to beat (ours v0).
    public static let sampEnThreshold = 1.0
    /// Turning-point test for randomness at 5 % (Kendall; Brockwell & Davis §1.6).
    public static let tprZ = 1.96
    /// "Repeated positive windows": 3 possible-AF windows within 4 consecutive assessed windows.
    public static let confirmPositive = 3
    public static let confirmSpan = 4
    /// A "regular" verdict needs 3 assessed windows (15 min).
    public static let minAssessed = 3

    // MARK: sample entropy

    /// ALG-013 v1 — sample entropy (Richman & Moorman 2000). `r` is ABSOLUTE, in the units of `x` (the HRV convention
    /// passes 0.2 × SD: `sampEnStandard`). B = template pairs i < j of length m matching within r (Chebyshev), A = the
    /// same for m + 1, both over the same N − m starts; SampEn = −ln(A/B). Missing when m < 1, r ≤ 0 or not finite,
    /// N < m + 2, N > 5000, or A or B is 0 (no match is an absence of evidence, not infinite entropy).
    public static func sampleEntropy(_ x: [Double], m: Int, r: Double) -> Computed<Double> {
        let n = x.count
        guard m >= 1, r.isFinite, r > 0 else { return .missing("sample entropy needs m >= 1 and a positive tolerance r") }
        guard n >= m + 2 else { return .missing("sample entropy needs at least \(m + 2) values (have \(n))") }
        guard n <= sampEnMaxBeats else {
            return .missing("sample entropy is computed on windows of at most \(sampEnMaxBeats) beats (have \(n))")
        }
        let templates = n - m
        var a = 0
        var b = 0
        for i in 0..<templates {
            var j = i + 1
            while j < templates {
                var ok = true
                for k in 0..<m where abs(x[i + k] - x[j + k]) > r {
                    ok = false
                    break
                }
                if ok {
                    b += 1
                    if abs(x[i + m] - x[j + m]) <= r { a += 1 }
                }
                j += 1
            }
        }
        guard a > 0, b > 0 else { return .missing("no matching templates: sample entropy undefined") }
        return .success(-log(Double(a) / Double(b)) + 0.0)   // + 0.0: A == B gives 0, not −0
    }

    /// SampEn(m = 2, r = 0.2 × SD ddof 1) — the convention for `hrv_sampen`.
    public static func sampEnStandard(_ rr: [Double], core: any SignalCore = Signal.core) -> Computed<Double> {
        guard rr.count >= 4 else { return .missing("sample entropy needs at least 4 values (have \(rr.count))") }
        let r = 0.2 * SignalMath.sampleSD(rr)
        if core.implementation == .swift { return sampleEntropy(rr, m: 2, r: r) }
        if let v = core.sampleEntropy(rrMs: rr, m: 2, r: r) { return .success(v) }
        return .missing("sample entropy undefined (\(core.implementation.rawValue) core)")
    }

    public struct SampEnNight: Sendable, Equatable {
        public var value: Double
        public var windows: Int

        public init(value: Double, windows: Int) {
            self.value = value
            self.windows = windows
        }
    }

    /// `hrv_sampen` night value: median SampEn(2, 0.2 SD) over the clean 5-min windows of the HRV windowing (WP-08
    /// rules: ALG-004 A on the span, clock-aligned 300 s, coverage ≥ 0.8, ≥ 30 beats, ≤ 5 % corrected); needs 3.
    public static func nightlySampEn(points: [RRPoint], core: any SignalCore = Signal.core) -> Computed<SampEnNight> {
        let sorted = BeatClock.sorted(points)
        let art = ALG004.correct(rrMs: sorted.map(\.rrMs), times: BeatClock.times(points: sorted))
        var order: [Int64] = []
        var byWindow: [Int64: [Int]] = [:]
        for (i, t) in art.times.enumerated() {
            let w = Int64((t / HRVWindows.windowSeconds).rounded(.down))
            if byWindow[w] == nil {
                byWindow[w] = []
                order.append(w)
            }
            byWindow[w]!.append(i)
        }
        var vals: [Double] = []
        for w in order.sorted() {
            let idx = byWindow[w]!
            let r = idx.map { art.rrMs[$0] }
            let flagged = idx.filter { art.flags[$0] != ArtefactFlag.ok.rawValue }.count
            var sum = 0.0
            for v in r { sum += v }
            let cov = min(1.0, sum / 1000.0 / HRVWindows.windowSeconds)
            let afrac = Double(flagged) / Double(idx.count)
            guard cov >= HRVWindows.minCoverage, r.count >= HRVWindows.minBeats,
                  afrac <= ALG004.windowMaxArtefactFraction else { continue }
            if case .success(let se) = sampEnStandard(r, core: core) { vals.append(se) }
        }
        guard vals.count >= HRVWindows.minCleanWindows else {
            return .missing("needs \(HRVWindows.minCleanWindows) clean 5-min windows with a sample entropy "
                            + "(have \(vals.count))")
        }
        return .success(SampEnNight(value: SignalMath.median(vals), windows: vals.count))
    }

    // MARK: window features

    /// Turning points (strictly above or below both neighbours) / (n − 2). Requires n ≥ 3.
    public static func turningPointRatio(_ x: [Double]) -> Double {
        var tp = 0
        for i in 1..<(x.count - 1) {
            if (x[i] > x[i - 1] && x[i] > x[i + 1]) || (x[i] < x[i - 1] && x[i] < x[i + 1]) { tp += 1 }
        }
        return Double(tp) / Double(x.count - 2)
    }

    /// TPR band of an i.i.d. series: E[TP] = 2(n−2)/3, Var[TP] = (16n − 29)/90; mean ± 1.96 SD, over n − 2.
    public static func tprRandomBand(_ n: Int) -> ClosedRange<Double> {
        let mu = 2.0 * Double(n - 2) / 3.0
        let sd = ((16.0 * Double(n) - 29.0) / 90.0).squareRoot()
        return ((mu - tprZ * sd) / Double(n - 2))...((mu + tprZ * sd) / Double(n - 2))
    }

    public struct WindowFeatures: Sendable, Equatable {
        public var screenClass: ScreenClass
        public var nRmssd: Double?
        public var tpr: Double?
        public var tprRandom: Bool?
        public var sampEn: Double?
        /// nil when SD2 is 0 (bigeminy-like pure alternation).
        public var sd1sd2: Double?
        public var meanRR: Double?
        /// Why the window could not be classified (class 3), or why it was not assessed.
        public var reason: String?

        public init(screenClass: ScreenClass, nRmssd: Double? = nil, tpr: Double? = nil, tprRandom: Bool? = nil,
                    sampEn: Double? = nil, sd1sd2: Double? = nil, meanRR: Double? = nil, reason: String? = nil) {
            self.screenClass = screenClass
            self.nRmssd = nRmssd
            self.tpr = tpr
            self.tprRandom = tprRandom
            self.sampEn = sampEn
            self.sd1sd2 = sd1sd2
            self.meanRR = meanRR
            self.reason = reason
        }
    }

    /// ALG-013 v1 window class from in-range R-R (ms): ALG-010 mean NN / RMSSD / SD1 / SD2, nRMSSD = RMSSD / mean NN,
    /// TPR, SampEn(2, 0.2 SD).
    /// possible AF = nRMSSD ≥ 0.10 AND TPR inside the random band AND SampEn ≥ 1.0 (irregularly irregular);
    /// other irregular = nRMSSD ≥ 0.10 without that pattern (bigeminy: too many turning points); else regular.
    public static func windowFeatures(_ rr: [Double], core: any SignalCore = Signal.core) -> WindowFeatures {
        let ht = ALG010.time(rrMs: rr)
        let se = sampEnStandard(rr, core: core)
        guard case .success(let t) = ht, case .success(let s) = se, rr.count >= 3 else {
            let why = ht.missingReason ?? se.missingReason ?? "too few beats"
            return WindowFeatures(screenClass: .poorQuality, reason: why)
        }
        let nr = t.rmssd / t.meanRR
        let tpr = turningPointRatio(rr)
        let random = tprRandomBand(rr.count).contains(tpr)
        let cls: ScreenClass
        if nr >= nRmssdThreshold && random && s >= sampEnThreshold {
            cls = .possibleAF
        } else if nr >= nRmssdThreshold {
            cls = .otherIrregular
        } else {
            cls = .regular
        }
        return WindowFeatures(screenClass: cls, nRmssd: nr, tpr: tpr, tprRandom: random, sampEn: s,
                              sd1sd2: t.sd2 > 0 ? t.sd1 / t.sd2 : nil, meanRR: t.meanRR)
    }

    // MARK: screen

    public struct ScreenWindow: Sendable, Equatable {
        public var start: Int64
        public var beats: Int
        public var coverage: Double
        public var assessed: Bool
        public var features: WindowFeatures

        public init(start: Int64, beats: Int, coverage: Double, assessed: Bool, features: WindowFeatures) {
            self.start = start
            self.beats = beats
            self.coverage = coverage
            self.assessed = assessed
            self.features = features
        }
    }

    public struct Screen: Sendable, Equatable {
        public var screenClass: ScreenClass
        public var assessed: Int
        public var possibleAFWindows: Int
        public var irregularWindows: Int
        /// Start (unix s) of the window that confirmed "possible AF", else nil.
        public var confirmedAt: Int64?
        public var windows: [ScreenWindow]

        public init(screenClass: ScreenClass, assessed: Int, possibleAFWindows: Int, irregularWindows: Int,
                    confirmedAt: Int64?, windows: [ScreenWindow]) {
            self.screenClass = screenClass
            self.assessed = assessed
            self.possibleAFWindows = possibleAFWindows
            self.irregularWindows = irregularWindows
            self.confirmedAt = confirmedAt
            self.windows = windows
        }
    }

    /// ALG-013 v1 — AF screen over a span of R-R points (a night, a day).
    /// R-R as delivered (NOT artefact-corrected: ALG-004 must never turn AF into sinus) → sorted (ts, ord) → beat clock
    /// → clock-aligned 5-min windows (start = floor(t / 300) · 300). `movingTs` = unix seconds the strap marked as
    /// moving (R18 activity_class ≥ 1); [] = none. A window is assessed when it has no moving second, every R-R is in
    /// 300–2000 ms, coverage ≥ 0.9 and ≥ 100 beats; then `windowFeatures`.
    /// Span: possible AF when some 4 consecutive assessed windows hold ≥ 3 possible-AF windows (never one window);
    /// else other irregular when any assessed window is irregular; else regular with ≥ 3 assessed; else poor quality.
    public static func screen(points: [RRPoint], movingTs: [Int64], core: any SignalCore = Signal.core) -> Screen {
        let sorted = BeatClock.sorted(points)
        let rr = sorted.map(\.rrMs)
        let times = BeatClock.times(points: sorted)
        var order: [Int64] = []
        var byWindow: [Int64: [Int]] = [:]
        for (i, t) in times.enumerated() {
            let w = Int64((t / windowSeconds).rounded(.down))
            if byWindow[w] == nil {
                byWindow[w] = []
                order.append(w)
            }
            byWindow[w]!.append(i)
        }
        let span = Int64(windowSeconds)
        var windows: [ScreenWindow] = []
        for w in order.sorted() {
            let r = byWindow[w]!.map { rr[$0] }
            let start = w * span
            var sum = 0.0
            for v in r { sum += v }
            let cov = min(1.0, sum / 1000.0 / windowSeconds)
            let features: WindowFeatures
            if movingTs.contains(where: { $0 >= start && $0 < start + span }) {
                features = WindowFeatures(screenClass: .poorQuality, reason: "not still (movement in the window)")
            } else if r.contains(where: { !rrRange.contains($0) }) {
                features = WindowFeatures(screenClass: .poorQuality, reason: "R-R outside 300-2000 ms")
            } else if cov < minCoverage || r.count < minBeats {
                features = WindowFeatures(screenClass: .poorQuality,
                                          reason: "coverage \(String(format: "%.2f", cov)) / \(r.count) beats "
                                              + "below 0.9 / \(minBeats)")
            } else {
                features = windowFeatures(r, core: core)
            }
            let assessed = features.screenClass != .poorQuality
            windows.append(ScreenWindow(start: start, beats: r.count, coverage: cov, assessed: assessed,
                                        features: features))
        }
        let assessedWindows = windows.filter(\.assessed)
        var confirmedAt: Int64?
        for i in 0..<assessedWindows.count {
            let run = assessedWindows[i..<min(i + confirmSpan, assessedWindows.count)]
            let hits = run.filter { $0.features.screenClass == .possibleAF }
            if hits.count >= confirmPositive {
                confirmedAt = hits[hits.startIndex + confirmPositive - 1].start
                break
            }
        }
        let cls: ScreenClass
        if confirmedAt != nil {
            cls = .possibleAF
        } else if assessedWindows.contains(where: { $0.features.screenClass == .possibleAF
                                                     || $0.features.screenClass == .otherIrregular }) {
            cls = .otherIrregular
        } else if assessedWindows.count >= minAssessed {
            cls = .regular
        } else {
            cls = .poorQuality
        }
        return Screen(screenClass: cls, assessed: assessedWindows.count,
                      possibleAFWindows: assessedWindows.filter { $0.features.screenClass == .possibleAF }.count,
                      irregularWindows: assessedWindows.filter { $0.features.screenClass == .otherIrregular }.count,
                      confirmedAt: confirmedAt, windows: windows)
    }

    // MARK: metrics

    public static let screenSpec = MetricSpec(
        key: .afScreen, unit: "class", group: "G-AF", variant: "ALG-013", method: "ALG-013@1 still-window-screen",
        tier: .research, source: "rr", window: "night", citation: citation,
        paramsVersion: "w300 cov0.9 beats100 nrmssd0.10 sampen1.0 tpr1.96 confirm3of4")

    public static let sampEnSpec = MetricSpec(
        key: .hrvSampen, unit: "unitless", group: "G-HRV", variant: "ALG-013", method: "ALG-013@1 sampen-m2-r0.2sd",
        tier: .research, source: "rr", window: "night", citation: "Richman & Moorman 2000",
        paramsVersion: "m2 r0.2sd w300 cov0.8 art0.05 min3windows")

    /// `af_screen` (value = class 0–3, note = its label) for the span. `at` = wake time for a night (D13).
    public static func screenMetric(_ s: Screen, at: Date) -> Metric {
        screenSpec.metric(.success(Double(s.screenClass.rawValue)), at: at,
                          note: "\(s.screenClass.label) (\(s.assessed) windows assessed)")
    }

    public static func sampEnMetric(_ night: Computed<SampEnNight>, at: Date) -> Metric {
        sampEnSpec.metric(night.map(\.value), at: at)
    }
}
