import Foundation

/// ALG-005 v1 — PPG signal quality: skewness SQI (Elgendi 2016) + the Orphanidou 2015 feasibility rules on beats found
/// by Elgendi 2013's two-moving-average detector. Also the beat detector for ALG-015 / ALG-108. Template matching
/// ("when foreground") is not built (N). Python reference: app/pclab/mglab/ref/cardio.py `ppg_detrend`,
/// `ppg_skewness_sqi`, `ppg_beats`, `ppg_quality`; goldens app/shared/golden/cardio/ALG-005.json.
///
/// Orientation: pass the pulse with systolic peaks UP (blood volume). A raw light intensity that falls with each beat
/// reads with negative skewness and its "peaks" are the feet; the caller flips it.
public enum ALG005 {
    public static let citation = "Elgendi 2016 Bioengineering 3:21 (skewness SQI); Elgendi 2013 PLoS ONE 8:e76585 "
        + "(two moving averages); Orphanidou 2015 IEEE JBHI 19:832 (feasibility rules)"

    /// Centred moving mean over 2 s removed: a ~0.5 Hz high-pass in place of the published 0.5–8 Hz band-pass (ours).
    public static let detrendSeconds = 2.0
    public static let minSeconds = 4.0
    /// Elgendi 2013: W1 = 111 ms, W2 = 667 ms, β = 0.02.
    public static let w1Seconds = 0.111
    public static let w2Seconds = 0.667
    public static let beta = 0.02
    /// Two peaks closer than 0.3 s (200 bpm): the higher one stays (ours).
    public static let refractorySeconds = 0.3
    /// Orphanidou 2015: HR 40–180 bpm, longest gap < 3 s, longest / shortest interval < 2.2.
    public static let hrRange: ClosedRange<Double> = 40.0...180.0
    public static let maxIbiSeconds = 3.0
    public static let maxIbiRatio = 2.2

    /// Seconds → whole samples, halves rounded to EVEN — the same as the Python reference (`round()`) and Rust
    /// (`math::round_half_even`). Differs from half-up only on an exact .5 (e.g. 0.3 s at 15 Hz → 4); never at 25 Hz.
    static func samples(_ seconds: Double, _ fs: Double) -> Int {
        Int((seconds * fs).rounded(.toNearestOrEven))
    }

    /// Mean over a window of `w` samples centred on i (start i − w/2), shifted inside [0, n) at the edges so every
    /// window holds exactly w samples. Prefix sums, left to right. Requires 1 ≤ w ≤ n.
    static func movingMeanClamped(_ x: [Double], _ w: Int) -> [Double] {
        let n = x.count
        var c = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { c[i + 1] = c[i] + x[i] }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = min(max(0, i - w / 2), n - w)
            out[i] = (c[lo + w] - c[lo]) / Double(w)
        }
        return out
    }

    /// The window minus its 2-s centred moving mean.
    public static func detrend(_ x: [Double], fs: Double) -> Computed<[Double]> {
        let w = max(3, samples(detrendSeconds, fs))
        guard x.count >= w else { return .missing("needs at least \(w) samples (\(Int(detrendSeconds)) s)") }
        let mm = movingMeanClamped(x, w)
        return .success((0..<x.count).map { x[$0] - mm[$0] })
    }

    /// ALG-005 v1 — skewness SQI: S = (1/N) Σ((d − mean)/σ)³ with σ the population SD, on the detrended window.
    /// Missing under 4 s or for a flat window (off the wrist / no pulse).
    public static func skewnessSQI(_ x: [Double], fs: Double) -> Computed<Double> {
        guard fs > 0, x.count >= samples(minSeconds, fs) else {
            return .missing("needs at least \(Int(minSeconds)) s of PPG")
        }
        let d: [Double]
        switch detrend(x, fs: fs) {
        case .success(let v): d = v
        case .failure(let m): return .failure(m)
        }
        let n = Double(d.count)
        var s = 0.0
        for v in d { s += v }
        let m = s / n
        var s2 = 0.0
        for v in d { s2 += (v - m) * (v - m) }
        s2 /= n
        guard s2 > 1e-12 else { return .missing("flat PPG window: no pulse (off the wrist?)") }
        var s3 = 0.0
        for v in d { s3 += pow(v - m, 3) }
        s3 /= n
        return .success(s3 / pow(s2, 1.5))
    }

    /// ALG-005 / ALG-015 / ALG-108 v1 — systolic peak indices (Elgendi 2013 two moving averages on the detrended pulse):
    /// y = max(d, 0)²; MA_peak over W1 = 0.111 fs and MA_beat over W2 = 0.667 fs samples (clamped centred windows);
    /// THR = MA_beat + 0.02 · mean(y); blocks where MA_peak > THR; a block of ≥ W1 samples that does not touch either
    /// end of the window (an incomplete pulse) holds one peak = argmax d (first on ties). Peaks closer than 0.3 s: the
    /// higher one stays. [] for too short input.
    public static func beats(_ x: [Double], fs: Double) -> [Int] {
        guard fs > 0, case .success(let d) = detrend(x, fs: fs) else { return [] }
        let n = d.count
        let w1 = max(1, samples(w1Seconds, fs))
        let w2 = max(1, samples(w2Seconds, fs))
        guard n >= w2 else { return [] }
        let y = d.map { $0 > 0 ? $0 * $0 : 0.0 }
        let maPeak = movingMeanClamped(y, w1)
        let maBeat = movingMeanClamped(y, w2)
        var ys = 0.0
        for v in y { ys += v }
        let alpha = beta * (ys / Double(n))
        let refractory = samples(refractorySeconds, fs)
        var peaks: [Int] = []
        var i = 0
        while i < n {
            if !(maPeak[i] > maBeat[i] + alpha) {
                i += 1
                continue
            }
            let s = i
            while i < n && maPeak[i] > maBeat[i] + alpha { i += 1 }
            if i - s < w1 || s == 0 || i == n { continue }
            var p = s
            for k in (s + 1)..<i where d[k] > d[p] { p = k }
            if let last = peaks.last, p - last < refractory {
                if d[p] > d[last] { peaks[peaks.count - 1] = p }
                continue
            }
            peaks.append(p)
        }
        return peaks
    }

    /// The Orphanidou 2015 rule a window failed.
    public enum Rule: String, Sendable, CaseIterable {
        case beats = "beats"
        case hr = "hr"
        case gap = "gap"
        case ratio = "ratio"
        case skewness = "skewness"
    }

    public struct Quality: Sendable, Equatable {
        public var skewness: Computed<Double>
        public var beats: Int
        public var hrBpm: Double?
        public var maxIbiSeconds: Double?
        public var ibiRatio: Double?
        public var ok: Bool
        public var failed: [Rule]

        public init(skewness: Computed<Double>, beats: Int, hrBpm: Double?, maxIbiSeconds: Double?, ibiRatio: Double?,
                    ok: Bool, failed: [Rule]) {
            self.skewness = skewness
            self.beats = beats
            self.hrBpm = hrBpm
            self.maxIbiSeconds = maxIbiSeconds
            self.ibiRatio = ibiRatio
            self.ok = ok
            self.failed = failed
        }
    }

    /// ALG-005 v1 window verdict: skewness reported (no threshold — none is published for this strap) and the
    /// Orphanidou rules on the detected beats; `ok` = every rule passes, `failed` names the rest.
    public static func quality(_ x: [Double], fs: Double) -> Quality {
        let sk = skewnessSQI(x, fs: fs)
        let peaks = beats(x, fs: fs)
        guard peaks.count >= 3 else {
            return Quality(skewness: sk, beats: peaks.count, hrBpm: nil, maxIbiSeconds: nil, ibiRatio: nil, ok: false,
                           failed: [.beats])
        }
        let ibi = (1..<peaks.count).map { Double(peaks[$0] - peaks[$0 - 1]) / fs }
        let hr = 60.0 / SignalMath.mean(ibi)
        let mx = ibi.max()!
        let mn = ibi.min()!
        var failed: [Rule] = []
        if !hrRange.contains(hr) { failed.append(.hr) }
        if !(mx < maxIbiSeconds) { failed.append(.gap) }
        if !(mx / mn < maxIbiRatio) { failed.append(.ratio) }
        if sk.value == nil { failed.append(.skewness) }
        return Quality(skewness: sk, beats: peaks.count, hrBpm: hr, maxIbiSeconds: mx, ibiRatio: mx / mn,
                       ok: failed.isEmpty, failed: failed)
    }
}
