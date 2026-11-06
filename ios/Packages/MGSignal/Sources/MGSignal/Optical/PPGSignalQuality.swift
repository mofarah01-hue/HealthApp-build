import Foundation
import MGDomain

/// ALG-005 night signal quality (r9l, D-HRV-WALK-1, 2026-10-17): the share of 10 s segments of the night's raw green PPG
/// (R20 block 0, slot A) whose skewness SQI is good. This is the ENHANCED signal-quality readout; the BASE one is the
/// Lipponen-Tarvainen artefact fraction on the R-R (`rr_artefact`, ALG-004) - the screens say which one they show.
///
/// Skewness SQI: Elgendi M, "Optimal signal quality index for photoplethysmogram signals", Bioengineering 2016;3(4):21
/// (the skewness of a clean pulse wave is high and positive; noise and motion lower it). The 10 s segment length and the
/// threshold are OURS (engineering starting values: no published value for this strap's 25 Hz green channel), so the
/// number is 'decoded, untested' until compared with a chest-strap ECG night. The R-R artefact method:
/// Lipponen JA, Tarvainen MP, J Med Eng Technol 2019;43(3):173-181.
/// Orientation: optical counts may fall with blood volume (as ALG-015), so a run is flipped when its mean skewness is
/// negative. Needs at least 30 segments (5 minutes) in the sleep period.
public enum PPGSignalQuality {
    public static let citation = "Elgendi 2016 Bioengineering 3:21 (skewness SQI) on 10 s segments of R20 block 0; "
        + "base readout: Lipponen & Tarvainen 2019 (R-R artefacts)"
    public static let segmentSeconds = 10
    public static let goodSkewness = 0.3
    public static let minSegments = 30

    public struct Night: Sendable, Equatable {
        public var goodPct: Double
        public var segments: Int
        public var good: Int
    }

    public static func night(_ r20: [R20Record], start: Int64, end: Int64) -> Computed<Night> {
        let recs = r20.filter { $0.ts >= start && $0.ts < end }
        guard !recs.isEmpty else { return .missing("no raw optical (R20) in the sleep period") }
        var total = 0
        var good = 0
        for run in ALG015.runs(recs, block: ALG015.block) {
            let n = Int(run.rate) * segmentSeconds
            guard n > 0, run.x.count >= n else { continue }
            var sk: [Double] = []
            var i = 0
            while i + n <= run.x.count {
                if case .success(let s) = ALG005.skewnessSQI(Array(run.x[i..<(i + n)]), fs: run.rate) { sk.append(s) } else { sk.append(0) }
                i += n
            }
            let flip = !sk.isEmpty && SignalMath.mean(sk) < 0
            if flip {
                sk = []
                i = 0
                while i + n <= run.x.count {
                    if case .success(let s) = ALG005.skewnessSQI(run.x[i..<(i + n)].map { -$0 }, fs: run.rate) { sk.append(s) } else { sk.append(0) }
                    i += n
                }
            }
            total += sk.count
            good += sk.filter { $0 >= goodSkewness }.count
        }
        guard total >= minSegments else {
            return .missing("\(total) usable 10 s segments of raw optical in the sleep period; \(minSegments) needed")
        }
        return .success(Night(goodPct: 100.0 * Double(good) / Double(total), segments: total, good: good))
    }

    public static let spec = MetricSpec(
        key: .ppgSqiGood, unit: "%", group: nil, variant: "ALG-005", method: "ALG-005@1 skewness-sqi-10s-segments",
        tier: .research, source: "r20 block 0", window: "night", producer: .ours, citation: citation,
        paramsVersion: "seg10s skew>=0.3 min30seg (ours)")

    public static func metrics(_ n: Computed<Night>, at: Date) -> [Metric] {
        let note = n.value.map {
            "\($0.good) of \($0.segments) 10 s segments of raw green pulse read as good (skewness SQI, Elgendi 2016); "
                + "decoded, untested; the base readout is the R-R artefact share"
        }
        return [spec.metric(n.map(\.goodPct), at: at, note: note)]
    }
}
