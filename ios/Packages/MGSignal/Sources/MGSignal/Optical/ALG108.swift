import Foundation
import MGDomain

/// ALG-108 v1 (wave 4, 2026-10-11) — heart rate and a spot HRV from the strap's v26 PPG bursts (the "Pulse Information
/// Packet": one 25-sample optical window per record, stored as `PPGBlock` = base + offsets, raw counts).
///
/// Rate: each window's own flags bit 7 (25 Hz set / 50 Hz clear; OpenStrap gen5_records.dart L65-104), carried in
/// `PPGBlock.rateHz` by MGBLE — not noop's fixed 24 Hz (PpgHr.swift), which reads ~4 % off. A 50 Hz record covers only
/// 0.5 s of its second, so consecutive 50 Hz windows are not one waveform: those bursts are left blank with that reason.
///
/// Per burst (records ≤ 2 s apart, ≥ 8 s long): HR = 60·fs / lag of the strongest normalised autocorrelation peak in
/// 30–220 bpm on the linearly detrended waveform (noop PpgHr's method: 8 s minimum, fundamental-period preference,
/// minimum confidence 0.3), with parabolic interpolation of the lag. Spot HRV: pulse peaks on the waveform minus its
/// ~0.7-period moving average, at least 0.6 of the period apart, each time refined by a parabola through its three
/// samples; intervals within ±30 % of their median; RMSSD over ≥ 10 intervals. At 25 Hz a pulse peak is timed to a few
/// ms only after interpolation, and pulse-to-pulse intervals are not R-R intervals: research tier, decoded, untested on
/// Mo's strap. The night = medians over the bursts inside the sleep period.
public enum ALG108 {
    public static let citation = "noop PpgHr.swift method @e580175; rate flag OpenStrap gen5_records.dart L65-104 @6e8c570"
    public static let minBurstSeconds = 8
    public static let maxGapSeconds: Int64 = 2
    public static let hrRange: ClosedRange<Double> = 30...220
    public static let minConfidence = 0.3
    public static let minIntervals = 10

    public struct Burst: Sendable, Equatable {
        public var start: Int64
        public var seconds: Int
        public var rateHz: Double
        public var samples: [Double]
    }

    public struct BurstResult: Sendable, Equatable {
        public var start: Int64
        public var hr: Double
        public var confidence: Double
        /// Pulse-to-pulse intervals (ms) that passed the ±30 % filter.
        public var intervalsMs: [Double]
        public var rmssd: Double?
    }

    /// Consecutive blocks of one rate, ≤ 2 s apart.
    public static func bursts(_ blocks: [PPGBlock]) -> [Burst] {
        var out: [Burst] = []
        var last: Int64?
        for b in blocks.sorted(by: { $0.ts < $1.ts }) {
            let abs = b.samples.map { Double($0) + Double(b.base) }
            if let l = last, b.ts - l <= maxGapSeconds, b.ts > l, var cur = out.last, cur.rateHz == b.rateHz {
                cur.samples += abs
                cur.seconds += Int(b.ts - l)
                out[out.count - 1] = cur
            } else {
                out.append(Burst(start: b.ts, seconds: 1, rateHz: b.rateHz, samples: abs))
            }
            last = b.ts
        }
        return out
    }

    /// x minus its centred moving average over `window` samples (prefix sums; the window shrinks at the ends).
    static func highPass(_ x: [Double], window w: Int) -> [Double] {
        var pre = [0.0]
        pre.reserveCapacity(x.count + 1)
        for v in x { pre.append(pre[pre.count - 1] + v) }
        return x.indices.map { i in
            let a = max(0, i - w / 2), b = min(x.count - 1, i + w / 2)
            return x[i] - (pre[b + 1] - pre[a]) / Double(b - a + 1)
        }
    }

    static func acf(_ x: [Double], _ lag: Int) -> Double {
        let n = x.count - lag
        guard n > 0 else { return 0 }
        var den = 0.0
        for v in x { den += v * v }
        guard den > 0 else { return 0 }
        var num = 0.0
        for i in 0..<n { num += x[i] * x[i + lag] }
        return num / den
    }

    /// (bpm, confidence) by autocorrelation; nil when nothing pulsatile clears 0.3.
    public static func heartRate(_ samples: [Double], fs: Double) -> (bpm: Double, conf: Double)? {
        guard samples.count >= Int(fs) * minBurstSeconds else { return nil }
        // breathing and perfusion move the baseline more than one pulse does: remove a centred 1.5-s moving average
        // first (pulses at ≥ 40 bpm pass; slower ones are attenuated, not lost), then the line
        let x = SignalMath.linearDetrend(t: (0..<samples.count).map(Double.init),
                                         y: highPass(samples, window: max(3, Int((1.5 * fs).rounded()))))
        let lo = max(2, Int((fs * 60 / hrRange.upperBound).rounded()))
        let hi = min(x.count - 2, Int((fs * 60 / hrRange.lowerBound).rounded()))
        guard hi > lo + 1 else { return nil }
        let r = (0...hi + 1).map { acf(x, $0) }
        var peaks: [Int] = []
        for k in lo...hi where r[k] > r[k - 1] && r[k] >= r[k + 1] && r[k] >= minConfidence { peaks.append(k) }
        guard let best = peaks.max(by: { r[$0] < r[$1] }) else { return nil }
        // fundamental-period preference: the smallest-lag peak within 85 % of the best one
        let k = peaks.first(where: { r[$0] >= 0.85 * r[best] }) ?? best
        let (a, b, c) = (r[k - 1], r[k], r[k + 1])
        let den = a - 2 * b + c
        let lag = Double(k) + (den != 0 ? 0.5 * (a - c) / den : 0)
        let bpm = 60 * fs / lag
        return hrRange.contains(bpm) ? (bpm, b) : nil
    }

    /// Pulse peak times (s from the burst start), refined by a parabola.
    static func peaks(_ x: [Double], fs: Double, periodS: Double) -> [Double] {
        let hp = highPass(x, window: max(3, Int((0.7 * periodS * fs).rounded())))
        guard hp.count >= 3 else { return [] }
        let minGap = Int(0.6 * periodS * fs)
        var idx: [Int] = []
        for i in 1..<(hp.count - 1) where hp[i] > 0 && hp[i] > hp[i - 1] && hp[i] >= hp[i + 1] {
            if let l = idx.last, i - l < minGap {
                if hp[i] > hp[l] { idx[idx.count - 1] = i }        // two maxima too close: keep the higher
                continue
            }
            idx.append(i)
        }
        return idx.map { i in
            let den = hp[i - 1] - 2 * hp[i] + hp[i + 1]
            return (Double(i) + (den != 0 ? 0.5 * (hp[i - 1] - hp[i + 1]) / den : 0)) / fs
        }
    }

    public static func analyse(_ b: Burst) -> Computed<BurstResult> {
        guard b.rateHz == 25 else {
            return .missing("a \(Int(b.rateHz)) Hz PPG burst: each stored second holds only part of the waveform")
        }
        guard b.seconds >= minBurstSeconds else { return .missing("burst of \(b.seconds) s, at least 8 s needed") }
        guard let hr = heartRate(b.samples, fs: b.rateHz) else { return .missing("no pulse in the burst") }
        let p = peaks(b.samples, fs: b.rateHz, periodS: 60 / hr.bpm)
        var ivs: [Double] = []
        for i in p.indices.dropFirst() { ivs.append((p[i] - p[i - 1]) * 1000) }
        let med = ivs.isEmpty ? 0 : SignalMath.median(ivs)
        let kept = ivs.filter { abs($0 - med) <= 0.3 * med }
        var rmssd: Double?
        if kept.count >= minIntervals {
            var s = 0.0
            for i in kept.indices.dropFirst() { s += (kept[i] - kept[i - 1]) * (kept[i] - kept[i - 1]) }
            rmssd = (s / Double(kept.count - 1)).squareRoot()
        }
        return .success(BurstResult(start: b.start, hr: hr.bpm, confidence: hr.conf, intervalsMs: kept, rmssd: rmssd))
    }

    public struct Night: Sendable, Equatable {
        public var hr: Double
        public var rmssd: Double?
        public var bursts: Int
        public var burstsWithHRV: Int
    }

    public static func night(_ blocks: [PPGBlock], start: Int64, end: Int64) -> Computed<Night> {
        let inside = blocks.filter { $0.ts >= start && $0.ts < end }
        guard !inside.isEmpty else {
            return .missing("no v26 PPG bursts in the sleep period (the strap writes them on some nights only)")
        }
        let res = bursts(inside).compactMap { analyse($0).value }
        guard !res.isEmpty else { return .missing("\(bursts(inside).count) PPG bursts, none with a usable pulse") }
        let hrv = res.compactMap(\.rmssd)
        return .success(Night(hr: SignalMath.median(res.map(\.hr)), rmssd: hrv.isEmpty ? nil : SignalMath.median(hrv),
                              bursts: res.count, burstsWithHRV: hrv.count))
    }

    public static let hrSpec = MetricSpec(
        key: .ppgHr, unit: "bpm", group: nil, variant: "ALG-108", method: "ALG-108@1 v26 PPG autocorrelation, median of bursts",
        tier: .research, source: "v26 ppg", window: "night", producer: .ours, citation: citation,
        paramsVersion: "rate=flags bit7 min8s 30-220bpm conf0.3")
    public static let hrvSpec = MetricSpec(
        key: .ppgHrvRmssd, unit: "ms", group: nil, variant: "ALG-108",
        method: "ALG-108@1 RMSSD of pulse-to-pulse intervals, median of bursts", tier: .research, source: "v26 ppg",
        window: "night", producer: .ours, citation: citation, paramsVersion: "peaks parabola ±30% min10")

    public static func metrics(_ n: Computed<Night>, at: Date) -> [Metric] {
        let note = n.value.map { "\($0.bursts) bursts, \($0.burstsWithHRV) with ≥ \(minIntervals) clean pulse intervals; "
            + "25 Hz pulse peaks, not R-R" }
        let hrv: Computed<Double> = n.flatMap { v in
            v.rmssd.map { .success($0) } ?? .missing("no burst had \(minIntervals) clean pulse intervals")
        }
        return [hrSpec.metric(n.map(\.hr), at: at, note: note), hrvSpec.metric(hrv, at: at, note: note)]
    }
}
