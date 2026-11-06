import Foundation
import MGDomain

/// ALG-121:riiv / ALG-121:riav v1 (wave 4, 2026-10-11) — breathing rate from the pulse itself, in the strap's v26 PPG
/// bursts: RIIV = the beat-to-beat baseline (trough) intensity, RIAV = the beat amplitude (peak − trough). Breathing
/// modulates both; the rate is the Lomb–Scargle peak of each beat series in 0.15–0.40 Hz (9–24 br/min) with ALG-121's
/// own checks (beat-rate Nyquist, peak not on the band edge, ≥ 40 % of band power around the peak). Per burst ≥ 40 s
/// (the research: RIAV/RIIV over 40-s v26 bursts gave 13–15 br/min vs WHOOP's 15, one night, noop #103 4943150517); the
/// night = median of the bursts. A rate, not a strap count (rule 4 is about the strap's raw respiration counts); research
/// tier, shown beside ALG-121 (from R-R) and WHOOP's own nightly respiratory_rate_rpm on the breathing screen.
public enum ALG121PPG {
    public static let citation = "RIAV/RIIV Lomb-Scargle 0.15-0.40 Hz over v26 bursts (CAPABILITIES; noop #103 4943150517)"
    public static let minBurstSeconds = 40
    public static let minBeats = 20

    public enum Modulation: String, Sendable, CaseIterable {
        case riiv = "riiv"
        case riav = "riav"
    }

    /// (beat times s, RIIV, RIAV) of one 25 Hz burst.
    static func beatSeries(_ b: ALG108.Burst) -> (t: [Double], riiv: [Double], riav: [Double])? {
        guard b.rateHz == 25, let hr = ALG108.heartRate(b.samples, fs: b.rateHz) else { return nil }
        let p = ALG108.peaks(b.samples, fs: b.rateHz, periodS: 60 / hr.bpm)
        guard p.count > minBeats else { return nil }
        let idx = p.map { min(b.samples.count - 1, Int(($0 * b.rateHz).rounded())) }
        // trough k = the lowest sample between peaks k−1 and k
        var troughs: [Double?] = [nil]
        for k in idx.indices.dropFirst() {
            troughs.append(idx[k] > idx[k - 1] + 1 ? b.samples[idx[k - 1]...idx[k]].min() : nil)
        }
        // RIAV on the pulse with the slow baseline removed (the same 0.7-period high-pass the peak finder uses), so a
        // large baseline swing (that is RIIV) does not leak into the amplitude
        let hp = ALG108.highPass(b.samples, window: max(3, Int((0.7 * 60 / hr.bpm * b.rateHz).rounded())))
        var t: [Double] = [], iv: [Double] = [], av: [Double] = []
        for k in idx.indices.dropFirst().dropLast() {
            guard let before = troughs[k], troughs[k + 1] != nil else { continue }
            let lo = idx[k - 1], mid = idx[k], hi = idx[k + 1]
            let peak = hp[max(mid - 1, 0)...min(mid + 1, hp.count - 1)].max()!
            let floor = (hp[lo...mid].min()! + hp[mid...hi].min()!) / 2
            t.append(p[k])
            iv.append(before)                                  // RIIV: the baseline just before the beat
            av.append(peak - floor)                            // RIAV: the beat's height above its two troughs
        }
        return t.count >= minBeats ? (t, iv, av) : nil
    }

    /// The breathing peak of one beat series (ALG-121's band and checks).
    static func rate(times t: [Double], values v: [Double]) -> Computed<Double> {
        let n = t.count
        guard n >= minBeats else { return .missing("\(n) beats, at least \(minBeats) needed") }
        let meanIBI = (t[n - 1] - t[0]) / Double(n - 1)
        guard 0.5 / meanIBI >= Double(ALG121.hfK.hi) * LombScargle.gridStepHz else {
            return .missing("heart rate too slow to resolve breathing up to 24 br/min")
        }
        let y = SignalMath.linearDetrend(t: t, y: v)
        let psd = LombScargle.psd(times: t, values: y, kMax: ALG121.hfK.hi - 1)
        guard psd.count == ALG121.hfK.hi - 1 else { return .missing("beat times do not advance") }
        var kp = ALG121.hfK.lo
        for k in (ALG121.hfK.lo + 1)..<ALG121.hfK.hi where psd[k - 1] > psd[kp - 1] { kp = k }
        let hf = LombScargle.bandPower(psd: psd, kLo: ALG121.hfK.lo, kHi: ALG121.hfK.hi)
        guard hf > 0, kp != ALG121.hfK.lo, kp != ALG121.hfK.hi - 1 else {
            return .missing("no breathing peak inside 9–24 br/min")
        }
        let q = LombScargle.bandPower(psd: psd, kLo: max(kp - ALG121.peakHalfK, ALG121.hfK.lo),
                                      kHi: min(kp + ALG121.peakHalfK + 1, ALG121.hfK.hi)) / hf
        guard q >= ALG121.minQuality else { return .missing("no clear breathing peak") }
        return .success(Double(kp) * LombScargle.gridStepHz * 60)
    }

    public static func burst(_ b: ALG108.Burst, _ m: Modulation) -> Computed<Double> {
        guard b.rateHz == 25 else { return .missing("a \(Int(b.rateHz)) Hz burst is not one continuous waveform") }
        guard b.seconds >= minBurstSeconds else { return .missing("burst of \(b.seconds) s, at least 40 s needed") }
        guard let s = beatSeries(b) else { return .missing("too few clean pulses in the burst") }
        return rate(times: s.t, values: m == .riiv ? s.riiv : s.riav)
    }

    public static func night(_ blocks: [PPGBlock], start: Int64, end: Int64, _ m: Modulation) -> Computed<Double> {
        let bursts = ALG108.bursts(blocks.filter { $0.ts >= start && $0.ts < end })
        guard !bursts.isEmpty else { return .missing("no v26 PPG bursts in the sleep period") }
        let v = bursts.compactMap { burst($0, m).value }
        guard !v.isEmpty else { return .missing("\(bursts.count) PPG bursts, none ≥ 40 s with a clear breathing peak") }
        return .success(SignalMath.median(v))
    }

    public static func spec(_ m: Modulation) -> MetricSpec {
        MetricSpec(key: .respRate, unit: "br_min", group: "G-RESP", variant: "ALG-121:\(m.rawValue)",
                   method: "ALG-121:\(m.rawValue)@1 \(m == .riiv ? "baseline" : "amplitude") of v26 PPG beats, "
                       + "Lomb-Scargle 0.15-0.40 Hz, median of ≥ 40-s bursts",
                   tier: .estimate, source: "v26 ppg", window: "night", producer: .ours, citation: citation,
                   paramsVersion: "hf150-400 q0.4 min40s")
    }

    public static func metrics(_ ppg: [PPGBlock], start: Int64, end: Int64, at: Date) -> [Metric] {
        Modulation.allCases.map { spec($0).metric(night(ppg, start: start, end: end, $0), at: at) }
    }
}
