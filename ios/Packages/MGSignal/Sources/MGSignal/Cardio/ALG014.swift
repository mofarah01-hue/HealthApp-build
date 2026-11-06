import Foundation
import MGDomain

/// ALG-014 v1 (part) — heart rate from the R-peaks of an MG ECG reading. Research tier. Added 2026-10-11 19:50 PT (wave W8).
///
/// Input: the R17 filtered samples in arrival order (raw signed counts; no voltage scale, PROTOCOL_ECG.md L186-195) and
/// the packets they came in. RATE: noop's docs do not establish one (PROTOCOL_ECG.md L195, L293-296, L335-338); one
/// hardware report saw ~1 packet/s of 100 samples on fw 50.41.1.0 (noop issue #891, 2026-10-04). So the rate is MEASURED
/// per reading: samples received ÷ the phone-clock span of their packets, and the reading is refused outside 70-130 Hz.
/// DETECTOR: Pan J, Tompkins WJ. IEEE Trans Biomed Eng 1985;32(3):230-236 — band-pass 5-15 Hz, five-point derivative,
/// squaring, 150 ms moving-window integration, adaptive signal / noise peak levels (threshold = NPKI + 0.25·(SPKI − NPKI)),
/// 200 ms refractory; the R sample is the largest band-passed |x| in the integration window. Simplified: no search-back,
/// no T-wave slope test (the 360 ms rule is replaced by the refractory and the adaptive level). HR = 60 / median R-R of
/// 0.3-2.0 s intervals. Not validated at ~100 Hz (ALGORITHM-REQUIREMENTS ALG-014: PhysioNet 2017 methods are at 300 Hz).
/// The rhythm classes of ALG-014 (normal / AF / other / noisy) are not built; the strap's own screen is shown beside.
public enum ALG014 {
    public static let minSeconds = 20.0
    public static let minBeats = 5
    public static let rateRange = 70.0...130.0

    public struct Result: Sendable, Equatable {
        public var bpm: Double
        public var beats: Int
        public var rrSeconds: [Double]
        /// Sample indices of the R-peaks in the samples used.
        public var peaks: [Int]
        public var rateHz: Double
        /// Seconds of signal analysed (after dropping the settling zeros).
        public var seconds: Double
        /// Samples dropped at the start (front-end settling zeros): `peaks` index the samples after them.
        public var settled: Int = 0
    }

    /// Samples / phone-clock span over the packets (the last packet's samples excluded: it closes the span).
    public static func rate(_ packets: [EcgTracePacket]) -> Computed<Double> {
        guard packets.count >= 5, let first = packets.first, let last = packets.last,
              last.receivedAt > first.receivedAt else {
            return .missing("too few ECG packets to measure the sample rate")
        }
        let samples = packets.dropLast().reduce(0) { $0 + $1.sampleCount }
        let hz = Double(samples) / (last.receivedAt - first.receivedAt)
        guard rateRange.contains(hz) else {
            return .missing(String(format: "sample rate not established for this reading (%.0f Hz from arrival times)", hz))
        }
        return .success(hz)
    }

    /// HR from the trace. Leading packets of all-zero samples (the front end settling, PROTOCOL_ECG.md L284-289) are skipped.
    public static func heartRate(samples: [Int16], packets: [EcgTracePacket]) -> Computed<Result> {
        let fs: Double
        switch rate(packets) {
        case .success(let hz): fs = hz
        case .failure(let m): return .failure(m)
        }
        var start = 0
        var skip = 0
        for p in packets {
            let end = min(samples.count, skip + p.sampleCount)
            if skip < end, samples[skip..<end].allSatisfy({ $0 == 0 }) { skip = end; start = end } else { break }
        }
        let x = samples[start...].map(Double.init)
        let seconds = Double(x.count) / fs
        guard seconds >= minSeconds else {
            return .missing(String(format: "%.0f s of ECG after settling; %.0f s needed", seconds, minSeconds))
        }
        let peaks = detect(x, fs: fs)
        let rr = zip(peaks.dropFirst(), peaks).map { Double($0 - $1) / fs }.filter { $0 >= 0.3 && $0 <= 2.0 }
        guard peaks.count >= minBeats, rr.count >= minBeats - 1 else {
            return .missing("too few clear beats (\(peaks.count)) — keep the finger still on the sensor")
        }
        return .success(Result(bpm: 60 / SignalMath.median(rr), beats: peaks.count, rrSeconds: rr, peaks: peaks,
                               rateHz: fs, seconds: seconds, settled: start))
    }

    /// Pan-Tompkins R-peak indices.
    public static func detect(_ x: [Double], fs: Double) -> [Int] {
        guard x.count > Int(fs) else { return [] }
        let bp = filtfilt(highpass: 5, lowpass: 15, fs: fs, x)
        var d = [Double](repeating: 0, count: bp.count)
        for i in 4..<bp.count { d[i] = (2 * bp[i] + bp[i - 1] - bp[i - 3] - 2 * bp[i - 4]) / 8 }
        let sq = d.map { $0 * $0 }
        let w = max(1, Int((0.150 * fs).rounded()))
        var integ = [Double](repeating: 0, count: sq.count)
        var run = 0.0
        for i in 0..<sq.count {
            run += sq[i]
            if i >= w { run -= sq[i - w] }
            integ[i] = run / Double(w)
        }
        let refractory = Int((0.2 * fs).rounded())
        let learn = min(integ.count, Int(2 * fs))
        var spki = 0.25 * (integ[0..<learn].max() ?? 0)
        var npki = 0.5 * (integ[0..<learn].reduce(0, +) / Double(max(learn, 1)))
        var peaks: [Int] = []
        var lastR = -refractory
        var i = 1
        while i < integ.count - 1 {
            if integ[i] > integ[i - 1], integ[i] >= integ[i + 1] {
                let threshold = npki + 0.25 * (spki - npki)
                if integ[i] > threshold, i - lastR > refractory {
                    // the R sample: largest |band-passed| value in the window that fed this integration peak
                    let lo = max(0, i - w - 2)
                    let r = (lo...i).max { abs(bp[$0]) < abs(bp[$1]) } ?? i
                    if let prev = peaks.last, r - prev <= refractory {
                        // two integration peaks on one QRS: keep the larger
                        if abs(bp[r]) > abs(bp[prev]) { peaks[peaks.count - 1] = r }
                    } else {
                        peaks.append(r)
                    }
                    lastR = i
                    spki = 0.125 * integ[i] + 0.875 * spki
                } else {
                    npki = 0.125 * integ[i] + 0.875 * npki
                }
            }
            i += 1
        }
        return peaks
    }

    /// Zero-phase band-pass: a 2nd-order Butterworth high-pass then low-pass (bilinear transform), run forward and back.
    static func filtfilt(highpass: Double, lowpass: Double, fs: Double, _ x: [Double]) -> [Double] {
        let hp = biquad(highpass: true, fc: highpass, fs: fs)
        let lp = biquad(highpass: false, fc: lowpass, fs: fs)
        var y = run(lp, run(hp, x))
        y.reverse()
        y = run(lp, run(hp, y))
        y.reverse()
        return y
    }

    struct Biquad { var b0, b1, b2, a1, a2: Double }

    static func biquad(highpass: Bool, fc: Double, fs: Double) -> Biquad {
        let k = tan(Double.pi * fc / fs)
        let q = 1 / 2.0.squareRoot()
        let norm = 1 / (1 + k / q + k * k)
        if highpass {
            return Biquad(b0: norm, b1: -2 * norm, b2: norm, a1: 2 * (k * k - 1) * norm, a2: (1 - k / q + k * k) * norm)
        }
        let b0 = k * k * norm
        return Biquad(b0: b0, b1: 2 * b0, b2: b0, a1: 2 * (k * k - 1) * norm, a2: (1 - k / q + k * k) * norm)
    }

    static func run(_ f: Biquad, _ x: [Double]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let v = f.b0 * x[i] + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
            x2 = x1; x1 = x[i]; y2 = y1; y1 = v
            y[i] = v
        }
        return y
    }

    /// The strap's own rhythm screen, as decoded by noop (Whoop5Ecg.swift L61-69 `EcgArrhythmiaCheckResult`, codes read
    /// from the official client): words for the result screen, always called the strap's screen (the "not a diagnosis" sentence was removed
    /// 2026-10-11 at Mo's request, tracker #89). PROTOCOL_ECG.md L145
    /// says the classifier code has no established diagnostic interpretation, so the raw code is always shown with it.
    public static func strapScreenWords(code: Int, state: Int) -> String {
        let name: String
        switch code {
        case 0: name = "not complete"
        case 1: name = "normal sinus rhythm"
        case 2: name = "signal unreadable"
        case 3: name = "low heart rate (bradycardia)"
        case 4: name = "possible AFib"
        case 5: name = "high heart rate (tachycardia)"
        case 6: name = "inconclusive"
        default: name = "unknown code"
        }
        let done = state == 2 ? "" : " (classifier still running, state \(state))"
        return "Strap's screen: \(name) — code \(code)\(done)."
    }
}
