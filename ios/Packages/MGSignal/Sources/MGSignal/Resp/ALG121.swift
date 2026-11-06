import Foundation

/// ALG-121 v1 — RSA breathing rate: the Lomb–Scargle peak of R-R in the HF band 0.15–0.40 Hz (9–24 br/min).
/// After OpenStrap analytics respiration/resp_rate.dart `rsaRespRate` (@0441ef9) and Laguna 1998; uses the shared
/// `LombScargle` grid (0.001 Hz, half-open integer bands). Python reference: app/pclab/mglab/ref/resp.py
/// `resp_from_rr`; goldens app/shared/golden/resp/ALG-121.json.
public enum ALG121 {
    public static let citation = "OpenStrap analytics resp_rate.dart rsaRespRate @0441ef9; Laguna 1998"
    /// HF [150, 400) on the 0.001 Hz grid.
    public static let hfK = (lo: 150, hi: 400)
    /// OpenStrap rsaRespRate: ≥ 20 beats.
    public static let minBeats = 20
    /// ALG-020 windows are 32–64 s; a shorter span cannot hold ~5 breaths at 9 br/min (ours).
    public static let minSpanSeconds = 30.0
    /// quality = share of HF power within ±0.020 Hz (±1.2 br/min) of the peak (ours).
    public static let peakHalfK = 20
    /// Ours v0: in 64-s windows white-noise R-R puts 0.25–0.31 of HF power around its tallest peak, a 10 ms RSA under
    /// 8 ms jitter 0.62 (gen_resp.py cases); below this no rate is reported.
    public static let minQuality = 0.4

    /// ALG-121 v1 — t = running sum of R-R (s); y = R-R minus its least-squares line; PSD k = 1…399; peak k* = highest
    /// PSD in HF (ties → lowest k); br/min = k* · 0.001 · 60; peakPower = PSD at k* (ms²/Hz); quality = power in
    /// [k* − 20, k* + 20] ∩ HF over HF power.
    /// Missing when: < 20 beats or < 30 s; the beat-rate Nyquist 0.5 / mean R-R (s) < 0.40 Hz (a slow heart cannot
    /// resolve the band: a peak could be an alias — OpenStrap rsaCeilingHz); no HF power; the peak on the first or last
    /// HF grid point (breathing outside 9–24 br/min); quality < 0.4 (no clear breathing peak).
    public static func estimate(rrMs rr: [Double]) -> Computed<RespEstimate> {
        let n = rr.count
        guard n >= minBeats else { return .missing("needs at least \(minBeats) beats (have \(n))") }
        guard !rr.contains(where: { !$0.isFinite || $0 <= 0 }) else {
            return .missing("R-R contains non-positive or non-finite values")
        }
        let t = BeatClock.runningSum(rrMs: rr)
        let span = t[n - 1] - t[0]
        guard span >= minSpanSeconds else {
            return .missing("needs at least \(Int(minSpanSeconds)) s of R-R (have \(String(format: "%.1f", span)) s)")
        }
        let meanRR = SignalMath.mean(rr)
        let nyquist = 0.5 / (meanRR / 1000.0)
        guard nyquist >= Double(hfK.hi) * LombScargle.gridStepHz else {
            return .missing("heart rate \(Int((60000.0 / meanRR).rounded())) bpm resolves breathing only up to "
                            + "\(String(format: "%.1f", nyquist * 60)) br/min, below the 24 br/min top of the band: "
                            + "a peak could be an alias")
        }
        let y = SignalMath.linearDetrend(t: t, y: rr)
        let psd = LombScargle.psd(times: t, values: y, kMax: hfK.hi - 1)
        guard psd.count == hfK.hi - 1 else { return .missing("R-R times do not advance") }
        var kp = hfK.lo
        for k in (hfK.lo + 1)..<hfK.hi where psd[k - 1] > psd[kp - 1] { kp = k }
        let hf = LombScargle.bandPower(psd: psd, kLo: hfK.lo, kHi: hfK.hi)
        guard hf > 0 else { return .missing("no power in the 0.15-0.40 Hz band") }
        guard kp != hfK.lo, kp != hfK.hi - 1 else {
            return .missing("spectral peak at the edge of 9-24 br/min: breathing outside the band or no clear rhythm")
        }
        let lo = max(kp - peakHalfK, hfK.lo)
        let hi = min(kp + peakHalfK + 1, hfK.hi)
        let quality = LombScargle.bandPower(psd: psd, kLo: lo, kHi: hi) / hf
        guard quality >= minQuality else {
            return .missing("no clear breathing peak (peak holds \(Int((100 * quality).rounded())) % of the band's "
                            + "power, needs \(Int(100 * minQuality)) %)")
        }
        return .success(RespEstimate(brPerMin: Double(kp) * LombScargle.gridStepHz * 60.0, peakPower: psd[kp - 1],
                                     quality: quality))
    }
}
