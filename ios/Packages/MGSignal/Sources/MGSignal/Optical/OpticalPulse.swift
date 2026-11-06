import Foundation
import MGDomain

/// T47 (2026-10-13) — pulse-wave heart rate and breathing from the live raw optical stream (R20), the same maths as the
/// v26 PPG path (ALG-108 rate, ALG-121:riiv / :riav breathing) on the longest unbroken run of ONE block's slot A.
/// Which block is the pulse-bearing one is not established for every WHOOP 5.0/MG firmware: `block` is a parameter
/// (default ALG-015's block 0, the green HR channel); the caller says which block it chose and why. Research tier, decoded,
/// untested on Mo's strap. Breathing is a rate WE derive (br/min), shown as an "estimate" (rule 4 / D-025), never a strap count.
public enum OpticalPulse {
    public static let citation = "ALG-108 autocorrelation HR + ALG-121 RIIV/RIAV Lomb-Scargle on a named R20 block (T47)"
    /// Two modulations that disagree by more than this (br/min) leave breathing blank rather than pick one.
    public static let maxModulationGap = 3.0

    public struct Spot: Sendable, Equatable {
        public var hrBpm: Double
        public var confidence: Double
        /// nil when the run is shorter than 40 s or the two modulations do not give one clear rate.
        public var breathingPerMin: Double?
        public var seconds: Int
    }

    public static func spot(records: [R20Record], block: Int = ALG015.block) -> Computed<Spot> {
        guard let run = ALG015.runs(records, block: block).max(by: { $0.x.count < $1.x.count }) else {
            return .missing("block \(block) carried no samples in \(records.count) R20 records")
        }
        let seconds = Int((Double(run.x.count) / run.rate).rounded())
        let burst = ALG108.Burst(start: records.map(\.ts).min() ?? 0, seconds: seconds, rateHz: run.rate, samples: run.x)
        guard burst.rateHz == 25 else { return .missing("block \(block) at \(Int(run.rate)) Hz: only 25 Hz windows are handled") }
        guard let hr = ALG108.heartRate(run.x, fs: run.rate) else {
            return .missing("no pulse in the longest run of block \(block) (\(seconds) s; at least 8 s needed)")
        }
        let rates = ALG121PPG.Modulation.allCases.compactMap { ALG121PPG.burst(burst, $0).value }
        var breathing: Double?
        if let lo = rates.min(), let hi = rates.max(), hi - lo <= maxModulationGap { breathing = (lo + hi) / 2 }
        return .success(Spot(hrBpm: hr.bpm, confidence: hr.conf, breathingPerMin: breathing, seconds: seconds))
    }

    // MARK: Bug 3 (2026-10-14): the Live tab's pulse wave from the live raw optical records

    /// The R20 sample value of a clipped (saturated) reading: the 19-bit ceiling (same constant as MGContext LiveWaves).
    public static let clippedCount: Int32 = 524_287
    /// More than this share of clipped samples in the chosen block = "optical signal saturated".
    public static let saturatedShare = 0.5
    /// The Live pulse box shows this many seconds of the chosen block (LiveState: "last 8 s").
    public static let liveWaveSeconds = 8

    /// What the Live tab's Pulse wave box shows while raw optical streams. Raw counts (no unit); `hrBpm` is a research-
    /// tier rate WE derive (decoded, untested), `reason` is the blank / no-pulse reason when there is no rate.
    public struct Live: Sendable, Equatable {
        /// The block shown: the first whose stored LED-drive bytes are not all zero (not the ambient one) and that
        /// carries samples, the same choice the Live presenter made since T22 (which wavelength it is stays unknown, T20).
        public var block: Int?
        /// Samples per second of that block in the newest record (25 or 50).
        public var rateHz: Double?
        /// Slot A of that block over the last `liveWaveSeconds`, clipped samples dropped, oldest first.
        public var wave: [Double]
        public var clippedShare: Double?
        public var hrBpm: Double?
        public var reason: String?
    }

    public static func live(records: [R20Record]) -> Live {
        let recs = records.sorted { $0.ts < $1.ts }
        guard let newest = recs.last else {
            return Live(block: nil, rateHz: nil, wave: [], clippedShare: nil, hrBpm: nil,
                        reason: "no raw optical records yet")
        }
        let lit = newest.blocks.filter { b in
            b.head.count >= 7 && [b.head[2], b.head[3], b.head[5], b.head[6]].contains { $0 != 0 }
                && b.slotA.contains { $0 != 0 }
        }
        guard let chosen = lit.first else {
            return Live(block: nil, rateHz: nil, wave: [], clippedShare: nil, hrBpm: nil,
                        reason: "every block in the newest raw optical record is dark or ambient (LED drive bytes all zero)")
        }
        let b = chosen.index
        let rate = Double(chosen.slotA.count)
        let raw = recs.suffix(liveWaveSeconds).flatMap { r in b < r.blocks.count ? r.blocks[b].slotA : [] }
        let clipped = raw.isEmpty ? 0 : Double(raw.filter { $0 == clippedCount }.count) / Double(raw.count)
        let wave = detrend(raw.filter { $0 != clippedCount }.map(Double.init))
        if clipped > saturatedShare {
            return Live(block: b, rateHz: rate, wave: wave, clippedShare: clipped, hrBpm: nil,
                        reason: "optical signal saturated: \(Int((clipped * 100).rounded())) % of block \(b)'s samples at the "
                            + "sensor's ceiling; a snugger or moved strap may help")
        }
        switch spot(records: recs, block: b) {
        case .success(let s):
            return Live(block: b, rateHz: rate, wave: wave, clippedShare: clipped, hrBpm: s.hrBpm, reason: nil)
        case .failure(let m):
            return Live(block: b, rateHz: rate, wave: wave, clippedShare: clipped, hrBpm: nil, reason: m.reason)
        }
    }

    /// Least-squares line removed (the same drift removal as MGContext LiveWaves.detrended, T22), so a slow baseline drift
    /// does not flatten the beats on an auto-scaled chart. Still raw counts, no unit.
    static func detrend(_ y: [Double]) -> [Double] {
        guard y.count >= 10 else { return y }
        let n = Double(y.count)
        let mx = (n - 1) / 2, my = y.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for (i, v) in y.enumerated() {
            sxx += (Double(i) - mx) * (Double(i) - mx)
            sxy += (Double(i) - mx) * (v - my)
        }
        let slope = sxx > 0 ? sxy / sxx : 0
        return y.enumerated().map { $0.element - (my + slope * (Double($0.offset) - mx)) }
    }

    public static func hrSpec(block: Int) -> MetricSpec {
        MetricSpec(key: .ppgHr, unit: "bpm", group: nil, variant: "ALG-108:r20", method: "ALG-108@1 autocorrelation on R20 block \(block)",
                   tier: .research, source: "r20 live", window: "instant", producer: .ours, citation: citation,
                   paramsVersion: "block=\(block) min8s 30-220bpm conf0.3")
    }

    public static func breathingSpec(block: Int) -> MetricSpec {
        MetricSpec(key: .respRate, unit: "br_min", group: "G-RESP", variant: "ALG-121:r20pulse",
                   method: "ALG-121:riiv/riav@1 Lomb-Scargle 0.15-0.40 Hz on R20 block \(block), mean of both when within 3 br/min",
                   tier: .research, source: "r20 live", window: "instant", producer: .ours, citation: citation,
                   paramsVersion: "block=\(block) min40s gap3")
    }

    public static func hrMetric(_ s: Computed<Spot>, block: Int, at: Date) -> Metric {
        hrSpec(block: block).metric(s.map(\.hrBpm), at: at,
                                    note: s.value.map { "pulse wave of raw optical block \(block), \($0.seconds) s; block choice assumed" })
    }

    /// Always labelled an estimate: a breathing rate derived from the pulse, not a strap count and not WHOOP's own.
    public static func breathingMetric(_ s: Computed<Spot>, block: Int, at: Date) -> Metric {
        let rate: Computed<Double> = s.flatMap { v in
            v.breathingPerMin.map { .success($0) } ?? .missing("no clear breathing rate in \(v.seconds) s (40 s and one clear peak needed)")
        }
        return breathingSpec(block: block).metric(rate, at: at,
            note: "estimate — derived from the pulse of raw optical block \(block), \(s.value?.seconds ?? 0) s; not checked against WHOOP")
    }
}
