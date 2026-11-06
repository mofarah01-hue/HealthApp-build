import Foundation
import MGDomain

/// ALG-015:notch (T89, 2026-10-13) — dicrotic notch and reflection index from the green pulse (R20 block 0), with the share
/// of beats where a notch could be found. The decoded PPG is about 25 Hz (one sample = 40 ms), so a notch shows only in still,
/// clean beats: this reports how often it was found and stays blank below `minDetectionRate`.
///
/// Per run (the same beats, orientation and cut as ALG-015: −0.4..+0.6 period around each systolic peak): a beat is clean when
/// it correlates ≥ `cleanCorrelation` with the run's median beat. Beat by beat, the clean beats within ±`halfEnsemble` beats
/// are averaged (≥ `minEnsemble`), smoothed [1 2 1]/4, and the first local minimum 80–400 ms after the peak followed by a
/// local maximum (the diastolic wave) is the notch when that wave stands above it by at least `minProminenceSE` standard errors
/// of the ensemble mean AND `minProminenceFrac` of the pulse height. Reflection index = diastolic height ÷ systolic height
/// above the foot. Research tier, an estimate (never a clinical unit); defaults, not fitted.
public enum PulseNotch {
    public static let citation = "ours (T89); ensemble-averaged green beats, first minimum + diastolic maximum after the systolic peak"
    public static let cleanCorrelation = 0.9
    public static let halfEnsemble = 4
    public static let minEnsemble = 5
    public static let minProminenceSE = 3.0
    public static let minProminenceFrac = 0.03
    /// Below this share of beats with a notch the notch time and reflection index stay blank.
    public static let minDetectionRate = 0.3
    public static let minBeats = 30

    /// One run: every beat counted, and the notch time (ms after the systolic peak) and reflection index (%) of each found beat.
    struct Run: Equatable {
        var beats = 0
        var notchMs: [Double] = []
        var reflectionPct: [Double] = []
    }

    /// Notch and reflection index of one ensemble-mean beat (systolic peak at `p`), nil when no notch passes the tests.
    static func detect(_ mean: [Double], peak p: Int, fs: Double, se: Double) -> (ms: Double, ri: Double)? {
        var y = mean
        for i in 1..<(mean.count - 1) { y[i] = (mean[i - 1] + 2 * mean[i] + mean[i + 1]) / 4 }
        guard p > 0, let foot = y[..<p].min(), y[p] > foot else { return nil }
        let amp = y[p] - foot
        let lo = p + max(2, Int(0.08 * fs)), hi = min(p + Int(0.40 * fs), y.count - 3)
        guard lo <= hi,
              let n = (lo...hi).first(where: { y[$0] < y[$0 - 1] && y[$0] <= y[$0 + 1] }),
              let d = ((n + 1)..<(y.count - 1)).first(where: { y[$0] > y[$0 - 1] && y[$0] >= y[$0 + 1] }) else { return nil }
        guard y[d] - y[n] >= max(minProminenceSE * se, minProminenceFrac * amp) else { return nil }
        let curve = y[n - 1] - 2 * y[n] + y[n + 1]
        let off = curve > 0 ? 0.5 * (y[n - 1] - y[n + 1]) / curve : 0
        return ((Double(n - p) + off) / fs * 1000, (y[d] - foot) / amp * 100)
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in a.indices {
            sab += (a[i] - ma) * (b[i] - mb)
            saa += (a[i] - ma) * (a[i] - ma)
            sbb += (b[i] - mb) * (b[i] - mb)
        }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
    }

    static func analyze(_ x: [Double], fs: Double) -> Run? {
        guard let shape = ALG015.shape(x, fs: fs), let hr = ALG108.heartRate(x, fs: fs) else { return nil }
        let y = x.map { $0 * Double(shape.polarity) }
        let before = Int((0.4 * 60 / hr.bpm * fs).rounded()), after = Int((0.6 * 60 / hr.bpm * fs).rounded())
        let pk = ALG108.peaks(y, fs: fs, periodS: 60 / hr.bpm).map { Int(($0 * fs).rounded()) }
            .filter { $0 - 1 - before >= 0 && $0 + 1 + after < y.count }
            .map { p in (p - 1...p + 1).max { y[$0] < y[$1] }! }          // snap to the sample maximum
        guard pk.count >= 5 else { return nil }
        let segs = pk.map { p in Array(y[(p - before)...(p + after)]) }
        let median = (0..<segs[0].count).map { j in SignalMath.median(segs.map { $0[j] }) }
        let clean = segs.map { correlation($0, median) >= cleanCorrelation }
        var run = Run(beats: pk.count)
        for k in pk.indices where clean[k] {
            let group = ((k - halfEnsemble)...(k + halfEnsemble)).filter { $0 >= 0 && $0 < pk.count && clean[$0] }
            guard group.count >= minEnsemble else { continue }
            let mean = (0..<median.count).map { j in group.reduce(0.0) { $0 + segs[$1][j] } / Double(group.count) }
            var ss = 0.0
            for g in group { for j in mean.indices { ss += (segs[g][j] - mean[j]) * (segs[g][j] - mean[j]) } }
            let sd = (ss / Double((group.count - 1) * mean.count)).squareRoot()
            if let f = detect(mean, peak: before, fs: fs, se: sd / Double(group.count).squareRoot()) {
                run.notchMs.append(f.ms)
                run.reflectionPct.append(f.ri)
            }
        }
        return run
    }

    public struct Night: Sendable, Equatable {
        public var beats: Int
        public var found: Int
        /// Share of beats (0–1) where a notch was found.
        public var rate: Double { beats > 0 ? Double(found) / Double(beats) : 0 }
        public var notchMs: Double?
        public var reflectionIndexPct: Double?
    }

    public static func night(_ r20: [R20Record], start: Int64, end: Int64) -> Computed<Night> {
        let recs = r20.filter { $0.ts >= start && $0.ts < end }
        guard !recs.isEmpty else { return .missing("no raw optical (R20) in the sleep period — Strap & sync › Raw optical › At night too") }
        let runs = ALG015.runs(recs, block: ALG015.block).compactMap { analyze($0.x, fs: $0.rate) }
        let beats = runs.reduce(0) { $0 + $1.beats }
        guard beats >= minBeats else { return .missing("\(beats) beats with clean green pulses (\(minBeats) needed)") }
        let ms = runs.flatMap(\.notchMs), ri = runs.flatMap(\.reflectionPct)
        return .success(Night(beats: beats, found: ms.count, notchMs: ms.isEmpty ? nil : SignalMath.median(ms),
                              reflectionIndexPct: ri.isEmpty ? nil : SignalMath.median(ri)))
    }

    public static func spec(_ key: MetricKey, unit: String, what: String) -> MetricSpec {
        MetricSpec(key: key, unit: unit, group: "G-VASC", variant: "ALG-015:notch", method: "ALG-015:notch@1 \(what)",
                   tier: .research, source: "r20 block 0", window: "night", producer: .ours, citation: citation,
                   paramsVersion: "corr0.9 ens±4 prom3SE,3% rate0.3")
    }
    public static let notchSpec = spec(.pulseNotchTime, unit: "ms", what: "time from systolic peak to dicrotic notch")
    public static let reflectionSpec = spec(.pulseReflectionIndex, unit: "%", what: "diastolic / systolic height")
    public static let rateSpec = spec(.pulseNotchRate, unit: "%", what: "share of beats with a notch found")

    /// Notch time and reflection index are blank, with the reason, below `minDetectionRate`; the rate itself always shows.
    public static func metrics(_ n: Computed<Night>, at: Date) -> [Metric] {
        let gated: Computed<Night> = n.flatMap { v in
            let pct = Int((v.rate * 100).rounded())
            return v.rate >= minDetectionRate ? .success(v)
                : .missing("detection rate \(pct) % of \(v.beats) beats, below \(Int(minDetectionRate * 100)) %: at 25 Hz the notch shows only in still, clean beats")
        }
        func note(_ v: Night) -> String {
            "estimate — notch found in \(Int((v.rate * 100).rounded())) % of \(v.beats) beats; 25 Hz, coarse; not checked against WHOOP"
        }
        let time: Computed<Double> = gated.flatMap { v in v.notchMs.map { .success($0) } ?? .missing("no notch") }
        let index: Computed<Double> = gated.flatMap { v in v.reflectionIndexPct.map { .success($0) } ?? .missing("no notch") }
        return [notchSpec.metric(time, at: at, note: gated.value.map(note)),
                reflectionSpec.metric(index, at: at, note: gated.value.map(note)),
                rateSpec.metric(n.map { $0.rate * 100 }, at: at, note: n.value.map(note))]
    }
}
