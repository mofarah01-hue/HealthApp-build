import Foundation
import MGDomain

/// ALG-015 v1 (wave 4, 2026-10-11) — pulse shape from raw optical: the median beat of R20 block 0 (slot A), the one
/// block every source agrees is the green HR channel (CAPABILITIES "Optical, SpO₂ and R22"; noop Whoop5RawOptical: block 0
/// driveB = 2 × driveA). Needs raw optical (108 live, e.g. the nights-only schedule, or 107 banked).
///
/// Per run of consecutive R20 records (≥ 8 s, one rate = the block's sampleCount per second): beats from ALG-108's
/// autocorrelation period and peak finder; each beat cut from 0.4 period before to 0.6 period after its peak; the
/// median beat sample by sample. The orientation is chosen so the upstroke is the steeper side (optical counts may fall
/// with blood volume; nothing on this firmware says which way). Features on the median beat, by linear interpolation:
/// rise time = 10 % → 90 % of the upstroke; width = time above half amplitude. At 25 Hz these are coarse: research tier,
/// decoded, untested on Mo's strap. The night = medians over the runs inside the sleep period.
public enum ALG015 {
    public static let citation = "median beat of R20 block 0 (green); 10-90 % rise, half-amplitude width; ALG-015"
    public static let block = 0
    public static let minRunSeconds = 8

    public struct Shape: Sendable, Equatable {
        public var riseMs: Double
        public var widthMs: Double
        public var beats: Int
        /// +1 when the pulse rises in counts, −1 when it was flipped.
        public var polarity: Int
    }

    /// Runs of consecutive records (≤ 1 s apart) with block `b` populated at one rate.
    static func runs(_ recs: [R20Record], block b: Int) -> [(rate: Double, x: [Double])] {
        var out: [(rate: Double, x: [Double])] = []
        var last: Int64?
        for r in recs.sorted(by: { $0.ts < $1.ts }) {
            guard b < r.blocks.count else { continue }
            let a = r.blocks[b].slotA
            guard !a.isEmpty, a.contains(where: { $0 != 0 }) else { last = nil; continue }
            let rate = Double(a.count)
            if let l = last, r.ts - l == 1, let cur = out.last, cur.rate == rate {
                out[out.count - 1].x += a.map(Double.init)
            } else {
                out.append((rate, a.map(Double.init)))
            }
            last = r.ts
        }
        return out
    }

    /// Linear-interpolated crossing of `level` between samples i and i+1 (fractional index).
    static func cross(_ y: [Double], _ i: Int, _ level: Double) -> Double {
        let d = y[i + 1] - y[i]
        return Double(i) + (d != 0 ? (level - y[i]) / d : 0)
    }

    /// Rise (10–90 %) and half-amplitude width, in samples, of one beat template with its peak at `p`.
    static func features(_ y: [Double], peak p: Int) -> (rise: Double, width: Double, fall: Double)? {
        guard p > 0, p < y.count - 1 else { return nil }
        let footBefore = y[..<p].min()!, footAfter = y[(p + 1)...].min()!
        let amp = y[p] - footBefore
        guard amp > 0 else { return nil }
        func up(_ frac: Double) -> Double? {
            let level = footBefore + frac * amp
            guard let i = (0..<p).last(where: { y[$0] < level && y[$0 + 1] >= level }) else { return nil }
            return cross(y, i, level)
        }
        func down(_ frac: Double, base: Double) -> Double? {
            let level = base + frac * (y[p] - base)
            guard let i = (p..<(y.count - 1)).first(where: { y[$0] >= level && y[$0 + 1] < level }) else { return nil }
            return cross(y, i, level)
        }
        guard let r10 = up(0.1), let r90 = up(0.9), let h1 = up(0.5), let h2 = down(0.5, base: footBefore),
              let f90 = down(0.9, base: footAfter), let f10 = down(0.1, base: footAfter) else { return nil }
        return (r90 - r10, h2 - h1, f10 - f90)
    }

    /// The median beat of one run and its features (best orientation); nil when no clean beats.
    public static func shape(_ x: [Double], fs: Double) -> Shape? {
        guard x.count >= Int(fs) * minRunSeconds, let hr = ALG108.heartRate(x, fs: fs) else { return nil }
        let period = 60 / hr.bpm * fs
        let before = Int((0.4 * period).rounded()), after = Int((0.6 * period).rounded())
        var best: Shape?
        for sign in [1.0, -1.0] {
            let y = x.map { $0 * sign }
            let pk = ALG108.peaks(y, fs: fs, periodS: 60 / hr.bpm).map { Int(($0 * fs).rounded()) }
                .filter { $0 - before >= 0 && $0 + after < y.count }
            guard pk.count >= 5 else { continue }
            let tmpl = (0...(before + after)).map { j in SignalMath.median(pk.map { y[$0 - before + j] }) }
            guard let f = features(tmpl, peak: before), f.rise < f.fall else { continue }
            let s = Shape(riseMs: f.rise / fs * 1000, widthMs: f.width / fs * 1000, beats: pk.count, polarity: Int(sign))
            if best == nil || s.riseMs < best!.riseMs { best = s }
        }
        return best
    }

    public struct Night: Sendable, Equatable {
        public var riseMs: Double
        public var widthMs: Double
        public var runs: Int
        public var beats: Int
    }

    public static func night(_ r20: [R20Record], start: Int64, end: Int64) -> Computed<Night> {
        let recs = r20.filter { $0.ts >= start && $0.ts < end }
        guard !recs.isEmpty else {
            // The switch was "› Nights only" before the W10 merge (2026-10-11 11:20 PM).
            return .missing("no raw optical (R20) in the sleep period — Strap & sync › Raw optical › At night too")
        }
        let shapes = runs(recs, block: block).compactMap { shape($0.x, fs: $0.rate) }
        guard !shapes.isEmpty else { return .missing("\(recs.count) R20 records, no run ≥ 8 s with clean green pulses") }
        return .success(Night(riseMs: SignalMath.median(shapes.map(\.riseMs)), widthMs: SignalMath.median(shapes.map(\.widthMs)),
                              runs: shapes.count, beats: shapes.reduce(0) { $0 + $1.beats }))
    }

    public static let riseSpec = MetricSpec(
        key: .pulseRiseTime, unit: "ms", group: "G-VASC", variant: "ALG-015", method: "ALG-015@1 median green beat, 10-90 % rise",
        tier: .research, source: "r20 block 0", window: "night", producer: .ours, citation: citation,
        paramsVersion: "beat -0.4..+0.6 period, min8s")
    public static let widthSpec = MetricSpec(
        key: .pulseWidthHalf, unit: "ms", group: "G-VASC", variant: "ALG-015",
        method: "ALG-015@1 median green beat, width at half amplitude", tier: .research, source: "r20 block 0",
        window: "night", producer: .ours, citation: citation, paramsVersion: "beat -0.4..+0.6 period, min8s")

    public static func metrics(_ n: Computed<Night>, at: Date) -> [Metric] {
        let note = n.value.map { "\($0.runs) runs, \($0.beats) beats of block 0 (green); 25 Hz, coarse — research" }
        return [riseSpec.metric(n.map(\.riseMs), at: at, note: note), widthSpec.metric(n.map(\.widthMs), at: at, note: note)]
    }
}
