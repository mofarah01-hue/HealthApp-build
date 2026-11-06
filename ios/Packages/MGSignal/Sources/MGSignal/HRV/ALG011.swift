import Foundation
import MGDomain

/// ALG-011 v1 — frequency-domain HRV (Lomb–Scargle LF/HF). LAB / RESEARCH ONLY: not on the main screens (D-HRV-WALK-1,
/// 2026-10-17; the LF/HF "balance" reading is contested, Shaffer & Ginsberg 2017). DFA α1 was REMOVED 2026-10-17
/// (D-HRV-WALK-2: it needs chest-strap R-R; wrist pulse intervals cannot serve it).
/// Python reference: app/pclab/mglab/ref/hrv.py `hrv_freq`, `nightly_freq`;
/// goldens app/shared/golden/hrv/ALG-011.json.
public enum ALG011 {
    public static let citation = "Laguna 1998 (Lomb–Scargle for HRV); Task Force 1996 bands"
    public static let lfK = (lo: 40, hi: 150)        // 0.04 ≤ f < 0.15 Hz
    public static let hfK = (lo: 150, hi: 400)       // 0.15 ≤ f < 0.40 Hz
    public static let totalK = (lo: 1, hi: 400)      // 0.001 ≤ f < 0.40 Hz
    /// Task Force 1996: about 2 min for LF.
    public static let minDurationSeconds = 120.0
    public static let minBeats = 30

    /// ALG-011 v1 — Lomb–Scargle LF / HF on uneven beats (ms²). t = running sum of R-R; y = R-R minus its
    /// least-squares line; PSD on the 0.001 Hz grid (`LombScargle`). Missing below 120 s or 30 beats, or HF = 0.
    public static func freq(rrMs rr: [Double]) -> Computed<HRVFreq> {
        guard rr.count >= minBeats else { return .missing("needs at least \(minBeats) beats (have \(rr.count))") }
        let t = BeatClock.runningSum(rrMs: rr)
        let duration = t[t.count - 1] - t[0]
        guard duration >= minDurationSeconds else {
            return .missing("needs at least \(Int(minDurationSeconds)) s of R-R (have \(Int(duration.rounded())) s)")
        }
        let y = SignalMath.linearDetrend(t: t, y: rr)
        let psd = LombScargle.psd(times: t, values: y, kMax: totalK.hi - 1)
        guard !psd.isEmpty else { return .missing("beat times do not advance") }
        let lf = LombScargle.bandPower(psd: psd, kLo: lfK.lo, kHi: lfK.hi)
        let hf = LombScargle.bandPower(psd: psd, kLo: hfK.lo, kHi: hfK.hi)
        let total = LombScargle.bandPower(psd: psd, kLo: totalK.lo, kHi: totalK.hi)
        guard hf > 0 else { return .missing("no HF power") }
        return .success(HRVFreq(lf: lf, hf: hf, lfHf: lf / hf, total: total))
    }

    /// The nightly frequency-domain values: medians over clean windows.
    public struct Night: Sendable, Equatable {
        public var lf: Double
        public var hf: Double
        public var lfHf: Double
        public var total: Double

        public init(lf: Double, hf: Double, lfHf: Double, total: Double) {
            self.lf = lf
            self.hf = hf
            self.lfHf = lfHf
            self.total = total
        }
    }

    /// ALG-011 v1 nightly: medians over ≥ 3 clean windows of LF, HF, LF/HF, total.
    public static func nightly(_ set: HRVWindowSet) -> Computed<Night> {
        let fr = set.cleanWindows.compactMap(\.freq)
        guard fr.count >= HRVWindows.minCleanWindows else { return .failure(HRVWindows.notEnough(fr.count)) }
        return .success(Night(lf: SignalMath.median(fr.map(\.lf)), hf: SignalMath.median(fr.map(\.hf)),
                              lfHf: SignalMath.median(fr.map(\.lfHf)), total: SignalMath.median(fr.map(\.total))))
    }

    public static let lfHfSpec = MetricSpec(
        key: .hrvLfHf, unit: "ratio", group: nil, variant: "ALG-011", method: "ALG-011@1 lomb-scargle-lf-hf",
        tier: .research, source: "rr", window: "night", citation: citation,
        paramsVersion: "grid0.001Hz LF[0.04,0.15) HF[0.15,0.40) detrend-linear min120s")

    /// `hrv_lf_hf` for the night. `at` = wake time (D13).
    public static func metrics(_ night: Computed<Night>, at: Date) -> [Metric] {
        [lfHfSpec.metric(night.map(\.lfHf), at: at)]
    }
}
