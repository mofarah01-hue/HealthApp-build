import Foundation
import MGDomain

/// ALG-010 v1 — Task Force 1996 time-domain HRV + Poincaré, and the nightly value (median of clean 5-min windows).
/// Python reference: app/pclab/mglab/ref/hrv.py `hrv_time`, `nightly_time`; goldens app/shared/golden/hrv/ALG-010.json.
/// This is pulse-rate variability from the strap's PPG R-R unless checked against ECG (ALGORITHM-REQUIREMENTS §4).
public enum ALG010 {
    public static let citation = "Task Force of the ESC and NASPE. Circulation 1996;93:1043-1065; Brennan 2001 (Poincaré)"
    public static let minBeats = 3

    /// ALG-010 v1 — time domain on one corrected R-R series (ms).
    /// meanRR; SDNN = SD with ddof 1; RMSSD = √(Σd² / (n−1)) over the n−1 successive differences;
    /// pNN50 = 100 · #(|d| > 50 ms, strictly) / (n−1) — divided by the number of PAIRS (NeuroKit2 convention and the
    /// ARCHITECTURE.md 4.6 worked example; Task Force / Kubios divide by the n intervals, a factor n/(n−1));
    /// lnRMSSD = ln RMSSD; SD1 = SD (ddof 1) of (x − y)/√2, SD2 = SD (ddof 1) of (x + y)/√2, x = rr[..<n−1],
    /// y = rr[1...] (Brennan 2001 rotation, NeuroKit2 hrv_nonlinear). Missing below 3 beats or with RMSSD = 0.
    public static func time(rrMs rr: [Double]) -> Computed<HRVTime> {
        let n = rr.count
        guard n >= minBeats else { return .missing("needs at least \(minBeats) R-R intervals (have \(n))") }
        let mean = SignalMath.mean(rr)
        let sdnn = SignalMath.sampleSD(rr)
        let r2 = 2.0.squareRoot()
        var ss = 0.0
        var nn50 = 0
        var minus: [Double] = []
        var plus: [Double] = []
        minus.reserveCapacity(n - 1)
        plus.reserveCapacity(n - 1)
        for i in 0..<(n - 1) {
            let d = rr[i + 1] - rr[i]
            ss += d * d
            if abs(d) > 50.0 { nn50 += 1 }
            minus.append((rr[i] - rr[i + 1]) / r2)
            plus.append((rr[i] + rr[i + 1]) / r2)
        }
        let rmssd = (ss / Double(n - 1)).squareRoot()
        guard rmssd > 0 else { return .missing("no beat-to-beat variation (RMSSD 0): not a usable R-R stream") }
        return .success(HRVTime(meanRR: mean, sdnn: sdnn, rmssd: rmssd, pnn50: 100.0 * Double(nn50) / Double(n - 1),
                                lnRmssd: log(rmssd), sd1: SignalMath.sampleSD(minus),
                                sd2: SignalMath.sampleSD(plus), n: n))
    }

    /// The nightly value: medians over clean windows.
    public struct Night: Sendable, Equatable {
        public var meanRR: Double
        public var sdnn: Double
        public var rmssd: Double
        public var pnn50: Double
        public var sd1: Double
        public var sd2: Double
        /// ln of the nightly RMSSD (not the median of per-window logs).
        public var lnRmssd: Double
        public var windowsTotal: Int
        public var windowsClean: Int
        /// Clean windows / windows with beats.
        public var coverage: Double
        /// ALG-004 A corrected share of the night's beats, %.
        public var artefactPct: Double

        public init(meanRR: Double, sdnn: Double, rmssd: Double, pnn50: Double, sd1: Double, sd2: Double,
                    lnRmssd: Double, windowsTotal: Int, windowsClean: Int, coverage: Double, artefactPct: Double) {
            self.meanRR = meanRR
            self.sdnn = sdnn
            self.rmssd = rmssd
            self.pnn50 = pnn50
            self.sd1 = sd1
            self.sd2 = sd2
            self.lnRmssd = lnRmssd
            self.windowsTotal = windowsTotal
            self.windowsClean = windowsClean
            self.coverage = coverage
            self.artefactPct = artefactPct
        }
    }

    /// ALG-010 v1 nightly: median over ≥ 3 clean 5-min windows of each time-domain value (ALGORITHM-REQUIREMENTS:
    /// "nightly = median of clean 5-min windows with coverage"). The caller passes the sleep window's R-R.
    public static func nightly(_ set: HRVWindowSet) -> Computed<Night> {
        let vals = set.cleanWindows.compactMap(\.time)
        guard vals.count >= HRVWindows.minCleanWindows else { return .failure(HRVWindows.notEnough(vals.count)) }
        let rmssd = SignalMath.median(vals.map(\.rmssd))
        return .success(Night(meanRR: SignalMath.median(vals.map(\.meanRR)), sdnn: SignalMath.median(vals.map(\.sdnn)),
                              rmssd: rmssd, pnn50: SignalMath.median(vals.map(\.pnn50)),
                              sd1: SignalMath.median(vals.map(\.sd1)), sd2: SignalMath.median(vals.map(\.sd2)),
                              lnRmssd: log(rmssd), windowsTotal: set.windows.count, windowsClean: vals.count,
                              coverage: Double(vals.count) / Double(set.windows.count),
                              artefactPct: 100.0 * set.artefactFraction))
    }

    static func spec(_ key: MetricKey, _ unit: String, _ what: String) -> MetricSpec {
        MetricSpec(key: key, unit: unit, group: "G-HRV", variant: "ALG-010", method: "ALG-010@1 \(what)", tier: .high,
                   source: "rr", window: "night", citation: citation,
                   paramsVersion: "w300 cov0.8 art0.05 min3windows")
    }

    public static let rmssdSpec = spec(.hrvRmssd, "ms", "rmssd-task-force")
    public static let lnRmssdSpec = spec(.hrvLnRmssd, "ln_ms", "ln-rmssd-task-force")
    public static let sdnnSpec = spec(.hrvSdnn, "ms", "sdnn-task-force")
    public static let pnn50Spec = spec(.hrvPnn50, "%", "pnn50-pairs")
    public static let sd1Spec = spec(.hrvSd1, "ms", "sd1-poincare")
    public static let sd2Spec = spec(.hrvSd2, "ms", "sd2-poincare")

    /// The six G-HRV ALG-010 metrics for the night (blank with the reason when missing). `at` = wake time (D13).
    public static func metrics(_ night: Computed<Night>, at: Date) -> [Metric] {
        let cov = night.value?.coverage
        func m(_ s: MetricSpec, _ f: (Night) -> Double) -> Metric { s.metric(night.map(f), at: at, coverage: cov) }
        return [m(rmssdSpec, \.rmssd), m(lnRmssdSpec, \.lnRmssd), m(sdnnSpec, \.sdnn), m(pnn50Spec, \.pnn50),
                m(sd1Spec, \.sd1), m(sd2Spec, \.sd2)]
    }

    /// The registry's daytime HRV members. The caller supplies only still, waking strap beat-to-beat windows; RMSSD
    /// and SDNN are the two ALG-010 members whose registry contract already permits a day window.
    public static func daytimeMetrics(_ day: Computed<Night>, at: Date) -> [Metric] {
        var rmssd = rmssdSpec
        rmssd.window = "day"
        var sdnn = sdnnSpec
        sdnn.window = "day"
        let cov = day.value?.coverage
        let note = day.value.map { "still daytime strap R-R: \($0.windowsClean) clean 5-min windows" }
        return [rmssd.metric(day.map(\.rmssd), at: at, coverage: cov, note: note),
                sdnn.metric(day.map(\.sdnn), at: at, coverage: cov, note: note)]
    }
}
