import Foundation

/// ALG-104 v1 — cardiac coherence ratio for the Breathe pacer (Live tab, UX §6). No registry metric: a live readout.
/// McCraty & Zayas 2014 (Front Psychol 5:1090); McCraty et al. 2009 "The coherent heart": the highest peak in
/// 0.04–0.26 Hz, peak power = power in a 0.030 Hz window centred on it, ratio = peak / (total − peak), total over
/// 0.0033–0.4 Hz. HeartMath's emWave takes ln of the ratio for its score; we keep the ratio.
/// Python reference: app/pclab/mglab/ref/hrv.py `coherence`; goldens app/shared/golden/hrv/ALG-104.json.
public enum ALG104 {
    public static let peakK = 40...260           // 0.040–0.260 Hz inclusive
    public static let halfWindowK = 15           // ±0.015 Hz → 31 grid points
    public static let totalK = (lo: 4, hi: 400)  // 0.004–0.399 Hz on the 0.001 Hz grid
    public static let minDurationSeconds = 60.0
    public static let minBeats = 30

    public struct Coherence: Sendable, Equatable {
        public var ratio: Double
        /// Resonance frequency, Hz (× 60 = breaths per minute that would match it).
        public var peakHz: Double

        public init(ratio: Double, peakHz: Double) {
            self.ratio = ratio
            self.peakHz = peakHz
        }
    }

    /// ALG-104 v1 — Lomb–Scargle PSD of the linearly detrended R-R (same grid as ALG-011). Missing below 60 s or
    /// 30 beats.
    public static func coherence(rrMs rr: [Double]) -> Computed<Coherence> {
        guard rr.count >= minBeats else { return .missing("needs at least \(minBeats) beats (have \(rr.count))") }
        let t = BeatClock.runningSum(rrMs: rr)
        guard t[t.count - 1] - t[0] >= minDurationSeconds else {
            return .missing("needs at least \(Int(minDurationSeconds)) s of R-R")
        }
        let y = SignalMath.linearDetrend(t: t, y: rr)
        let psd = LombScargle.psd(times: t, values: y, kMax: totalK.hi - 1)
        guard !psd.isEmpty else { return .missing("beat times do not advance") }
        var kp = peakK.lowerBound
        for k in peakK where psd[k - 1] > psd[kp - 1] { kp = k }
        let lo = max(kp - halfWindowK, totalK.lo)
        let hi = min(kp + halfWindowK + 1, totalK.hi)
        let peak = LombScargle.bandPower(psd: psd, kLo: lo, kHi: hi)
        let total = LombScargle.bandPower(psd: psd, kLo: totalK.lo, kHi: totalK.hi)
        let rest = total - peak
        guard rest > 0 else { return .missing("no power outside the peak") }
        return .success(Coherence(ratio: peak / rest, peakHz: Double(kp) * LombScargle.gridStepHz))
    }
}
