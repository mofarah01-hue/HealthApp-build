import Foundation
import MGDomain

/// ALG-033 v1 — nap candidates (G-NAP member 1, "ours"): runs of low-motion worn minutes (minute activity ≤ 10°, HR
/// present), gaps < 5 min merged, ≥ 15 min (ALG-033 says 15–20; 15 is the more sensitive end — Mo answers every
/// candidate), not overlapping the night window(s) in `exclude`. A candidate is a NAP when its median minute HR is
/// ≥ 5 bpm below the median minute HR of the 60 min before it (≥ 20 HR minutes). Every candidate is returned with
/// `nap` and why; `probability` stays Missing until the personal model (ALG-033 online learning, fit on the PC)
/// exists. Python: `mglab.ref.sleep.nap_candidates_033`.
public enum ALG033 {
    static let lowMotionDeg = 10.0           // ours v1
    static let mergeGapMinutes = 5           // ALG-033
    static let minMinutes = 15               // ALG-033 (15–20)
    static let refMinutes = 60               // ours v1
    static let refMinMinutes = 20
    static let hrDropBpm = 5.0               // ours v1

    public struct Candidate: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var minutes: Double
        public var hrMedian: Double
        public var hrRef: Computed<Double>
        public var hrDrop: Computed<Double>
        public var nap: Bool
        public var why: String
        public var probability: Computed<Double>

        public init(start: Double, end: Double, minutes: Double, hrMedian: Double, hrRef: Computed<Double>,
                    hrDrop: Computed<Double>, nap: Bool, why: String, probability: Computed<Double>) {
            self.start = start
            self.end = end
            self.minutes = minutes
            self.hrMedian = hrMedian
            self.hrRef = hrRef
            self.hrDrop = hrDrop
            self.nap = nap
            self.why = why
            self.probability = probability
        }
    }

    public static func candidates(grid g: SleepMotionGrid, exclude: [SleepInterval] = []) -> Computed<[Candidate]> {
        guard g.rows > 0 else { return .missing("no strap records") }
        let low = (0..<g.act.count).map { j -> Bool in
            guard let a = g.act[j], g.hrMin[j] != nil else { return false }
            return a <= lowMotionDeg
        }
        var blocks: [(Int, Int)] = []
        for (a, b) in SleepMath.runs(low) {
            if let last = blocks.last, a - last.1 - 1 < mergeGapMinutes {
                blocks[blocks.count - 1] = (last.0, b)
            } else {
                blocks.append((a, b))
            }
        }
        var out: [Candidate] = []
        for (a, b) in blocks where b - a + 1 >= minMinutes {
            let s = Double(g.t0 + Int64(a) * 60)
            let e = Double(g.t0 + Int64(b + 1) * 60)
            if SleepMath.overlaps(s, e, exclude) { continue }
            let inside = (a...b).compactMap { g.hrMin[$0] }
            let ref = (Swift.max(0, a - refMinutes)..<a).compactMap { g.hrMin[$0] }
            let med = SignalMath.median(inside)
            let prob: Computed<Double> = .missing("no personal nap model yet (ALG-033 learns from your answers)")
            if ref.count < refMinMinutes {
                out.append(Candidate(start: s, end: e, minutes: (e - s) / 60.0, hrMedian: med,
                                     hrRef: .missing("needs \(refMinMinutes) HR minutes in the hour before"),
                                     hrDrop: .missing("no reference"), nap: false, why: "no HR reference before it",
                                     probability: prob))
            } else {
                let r = SignalMath.median(ref)
                let drop = r - med
                let ok = drop >= hrDropBpm
                out.append(Candidate(start: s, end: e, minutes: (e - s) / 60.0, hrMedian: med, hrRef: .success(r),
                                     hrDrop: .success(drop), nap: ok,
                                     why: ok ? "low motion and HR dropped" : "HR did not drop 5 bpm",
                                     probability: prob))
            }
        }
        return .success(out)
    }
}

/// ALG-127 v1 — nap variant (G-NAP member 2; PLAN §4.8 original, van Hees 2015): blocks of sustained inactivity (no
/// z-angle change > 5° for ≥ 5 min) joined when < 5 min apart, ≥ 10 min long, outside `exclude`; a NAP when the block's
/// median minute HR is > 3 bpm below the seated-awake baseline. PLAN's third condition, "the R-R pattern of sleep
/// onset", is not in v1 (phase N). Python: `mglab.ref.sleep.seated_baseline` / `nap_candidates_127`.
public enum ALG127 {
    static let mergeGapSeconds: Int64 = 300  // ours v1
    static let minSeconds: Int64 = 600       // ours v1
    static let hrMarginBpm = 3.0             // ours v1
    static let seatedMinMinutes = 30
    static let seatedMinClassSamples = 30

    public struct Seated: Sendable, Equatable {
        public var bpm: Double
        public var minutes: Int

        public init(bpm: Double, minutes: Int) {
            self.bpm = bpm
            self.minutes = minutes
        }
    }

    public struct Candidate: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var minutes: Double
        public var hrMedian: Double
        public var seatedBpm: Double
        public var nap: Bool
        public var why: String

        public init(start: Double, end: Double, minutes: Double, hrMedian: Double, seatedBpm: Double, nap: Bool,
                    why: String) {
            self.start = start
            self.end = end
            self.minutes = minutes
            self.hrMedian = hrMedian
            self.seatedBpm = seatedBpm
            self.nap = nap
            self.why = why
        }
    }

    /// Seated-awake HR baseline: median minute HR over minutes that are on-skin, strap activity class 0 (still) on
    /// every sample (≥ 30 samples; noop activity_class@63), NOT inside any van Hees bout (the wrist still moves:
    /// awake), and outside `exclude`. Needs ≥ 30 such minutes.
    public static func seatedBaseline(grid g: SleepMotionGrid, seconds s: SleepSeconds,
                                      exclude: [SleepInterval] = []) -> Computed<Seated> {
        let nMin = g.hrMin.count
        var clsN = [Int](repeating: 0, count: nMin)
        var clsBad = [Int](repeating: 0, count: nMin)
        for (t, c) in zip(s.ts, s.activityClass) {
            guard let c else { continue }
            let j = Int(SleepMath.floorDiv(t - g.t0, 60))
            guard j >= 0 && j < nMin else { continue }
            clsN[j] += 1
            if c != 0 { clsBad[j] += 1 }
        }
        var inBout = [Bool](repeating: false, count: nMin)
        for b in ALG030.inactivityBouts(g, maxGapSeconds: 0) {
            let j0 = Int(SleepMath.floorDiv(b.start - g.t0, 60))
            let j1 = Int(SleepMath.floorDiv(b.end - 1 - g.t0, 60))
            for j in j0...j1 { inBout[j] = true }
        }
        var vals: [Double] = []
        for j in 0..<nMin {
            let st = Double(g.t0 + Int64(j) * 60)
            guard let h = g.hrMin[j], clsN[j] >= seatedMinClassSamples, clsBad[j] == 0, !inBout[j] else { continue }
            if SleepMath.overlaps(st, st + 60, exclude) { continue }
            vals.append(h)
        }
        guard vals.count >= seatedMinMinutes else {
            return .missing("seated-awake baseline needs \(seatedMinMinutes) still, awake, worn minutes "
                            + "(have \(vals.count))")
        }
        return .success(Seated(bpm: SignalMath.median(vals), minutes: vals.count))
    }

    public static func candidates(grid g: SleepMotionGrid, seatedBpm: Computed<Double>,
                                  exclude: [SleepInterval] = []) -> Computed<[Candidate]> {
        guard g.rows > 0 else { return .missing("no strap records") }
        guard let seated = seatedBpm.value else { return .missing(seatedBpm.missingReason ?? "no seated baseline") }
        var out: [Candidate] = []
        for b in ALG030.inactivityBouts(g, maxGapSeconds: mergeGapSeconds) {
            if b.end - b.start < minSeconds || SleepMath.overlaps(Double(b.start), Double(b.end), exclude) { continue }
            let j0 = Int(SleepMath.floorDiv(b.start - g.t0, 60))
            let j1 = Int(SleepMath.floorDiv(b.end - 1 - g.t0, 60))
            let inside = (j0...j1).compactMap { g.hrMin[$0] }
            guard !inside.isEmpty else { continue }
            let med = SignalMath.median(inside)
            let ok = med < seated - hrMarginBpm
            out.append(Candidate(start: Double(b.start), end: Double(b.end), minutes: Double(b.end - b.start) / 60.0,
                                 hrMedian: med, seatedBpm: seated, nap: ok,
                                 why: ok ? "still and HR below seated baseline"
                                     : "still but HR not below seated baseline"))
        }
        return .success(out)
    }
}
