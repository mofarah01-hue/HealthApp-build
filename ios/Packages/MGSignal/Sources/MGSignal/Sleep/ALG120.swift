import Foundation
import MGDomain

/// ALG-120 v1 — Cole–Kripke / Webster + HRV fusion ("ours v1" after OpenStrap cardio_stager.dart and stager.dart),
/// a G-STAGE member. Retrospective: uses up to 2 min of future activity and a centred 5-min R-R window, so WP-11's
/// live (causal) stager compares against it, not the other way round. Python: `mglab.ref.sleep.stage_night`.
///
/// 1. Wake / sleep per minute: Cole et al. 1992 (1-min epochs, P = 0.001, weights 106 54 58 76 230 74 67 for
///    A(t−4) … A(t+2), D ≥ 1 → wake) on the minute activity × 0.1 (UNCALIBRATED, ours v1), OR minute HR ≥ the span's
///    median minute HR + 10 bpm (needs 30 HR minutes, else the HR rule is off and `hrRef` says why); then Webster
///    rescoring (Cole 1992 rules a–e).
/// 2. Each asleep 30-s epoch: lnRMSSD of the beats within ±150 s (`SignalCore.hrvTime`, ALG-010; ≥ 30 beats covering
///    ≥ 180 s) and the epoch's mean HR, robust-z'd against the night's asleep epochs (median, 1.4826·MAD, floors 0.1 /
///    1 bpm): REM if z_ln ≤ −0.5 and z_hr ≥ +0.5 and its minute moved ≤ 5° (atonia); deep if z_ln ≥ +0.5 and z_hr ≤ 0;
///    else light; no features → S. Fewer than 50 % of asleep epochs with features → W / S only, with the reason.
/// 3. Consolidation: L / D / R bouts < 5 min take the stage of the longer adjacent L / D / R bout.
public enum ALG120 {
    static let ckP = 0.001
    static let ckWeights: [Double] = [106, 54, 58, 76, 230, 74, 67]     // offsets −4 … +2
    static let ckActScale = 0.1               // ours v1, uncalibrated: degrees per minute → Cole–Kripke count
    static let hrWakeDelta = 10.0             // ours v1
    static let hrRefMinMinutes = 30
    static let websterAfter: [(Int, Int)] = [(15, 4), (10, 3), (4, 1)]
    static let websterSurround: [(Int, Int)] = [(6, 10), (10, 20)]
    static let rmssdHalfSeconds = 150.0
    static let rmssdMinBeats = 30
    static let rmssdMinCoverSeconds = 180.0
    static let stageMinCoverage = 0.5         // OpenStrap cardio_stager minHrCoverage
    static let zFloorLn = 0.1
    static let zFloorHR = 1.0
    static let zStage = 0.5
    static let remStillDeg = 5.0
    static let stageMinBout = 10              // epochs = 5 min (OpenStrap stageBoutMinMin)
    public static let citation = "Cole et al. 1992 Sleep 15:461 (Cole-Kripke + Webster 1982 rules); OpenStrap "
        + "analytics cardio_stager.dart / stager.dart (HR fusion, consolidation)"

    public struct StagedNight: Sendable, Equatable {
        public var hypnogram: SleepHypnogram
        /// The minute wake / sleep layer before staging, expanded to 30-s epochs (W / S / .).
        public var wakeLayer: String
        public var hrRef: Computed<Double>
        public var staged: Bool
        public var stageReason: String?
        public var featureCoverage: Double
        public var lnRmssdMedian: Double?
        public var lnRmssdSD: Double?
        public var hrMedian: Double?
        public var hrSD: Double?

        public init(hypnogram: SleepHypnogram, wakeLayer: String, hrRef: Computed<Double>, staged: Bool,
                    stageReason: String?, featureCoverage: Double, lnRmssdMedian: Double?, lnRmssdSD: Double?,
                    hrMedian: Double?, hrSD: Double?) {
            self.hypnogram = hypnogram
            self.wakeLayer = wakeLayer
            self.hrRef = hrRef
            self.staged = staged
            self.stageReason = stageReason
            self.featureCoverage = featureCoverage
            self.lnRmssdMedian = lnRmssdMedian
            self.lnRmssdSD = lnRmssdSD
            self.hrMedian = hrMedian
            self.hrSD = hrSD
        }
    }

    private static let W = SleepStageCode.wake.byte
    private static let S = SleepStageCode.asleep.byte
    private static let L = SleepStageCode.light.byte
    private static let D = SleepStageCode.deep.byte
    private static let R = SleepStageCode.rem.byte
    private static let N = SleepStageCode.noData.byte

    static func ckScore(_ act: [Double?], _ j: Int) -> Double {
        var s = 0.0
        for (i, w) in ckWeights.enumerated() {
            let jj = j + i - 4
            if jj >= 0 && jj < act.count, let a = act[jj] { s += w * a * ckActScale }
        }
        return ckP * s
    }

    /// Webster et al. 1982 as listed by Cole et al. 1992 on a 1-min W / S string ('.' breaks a run):
    /// a–c) after ≥ 4 / 10 / 15 min of wake the next 1 / 3 / 4 min of sleep become wake; d–e) sleep runs ≤ 6 / 10 min
    /// with ≥ 10 / 20 min of wake before AND after become wake. a–c read the input, d–e read a–c's output (no cascade).
    public static func webster(_ minutes: String) -> String {
        let s0 = Array(minutes.utf8)
        var s1 = s0
        let r0 = SleepMath.byteRuns(s0)
        if r0.count > 1 {
            for ri in 0..<(r0.count - 1) {
                let (c, a, b) = r0[ri]
                let (c2, a2, b2) = r0[ri + 1]
                guard c == W, c2 == S else { continue }
                let length = b - a + 1
                for (need, take) in websterAfter where length >= need {
                    for x in a2...min(b2, a2 + take - 1) { s1[x] = W }
                    break
                }
            }
        }
        let r1 = SleepMath.byteRuns(s1)
        var s2 = s1
        if r1.count > 2 {
            for ri in 1..<(r1.count - 1) {
                let (c, a, b) = r1[ri]
                guard c == S else { continue }
                let (pc, pa, pb) = r1[ri - 1]
                let (nc, na, nb) = r1[ri + 1]
                guard pc == W, nc == W else { continue }
                let length = b - a + 1
                let before = pb - pa + 1
                let after = nb - na + 1
                if websterSurround.contains(where: { length <= $0.0 && before >= $0.1 && after >= $0.1 }) {
                    for x in a...b { s2[x] = W }
                }
            }
        }
        return String(decoding: s2, as: UTF8.self)
    }

    /// OpenStrap consolidateSleepStages step 2: an L / D / R bout shorter than 10 epochs takes the stage of the LONGER
    /// adjacent L / D / R bout (left on a tie), repeated to a fixed point. W, S and '.' never merge and are never a
    /// target. (Step 1, the REM-gap bridge, is not in v1.)
    public static func consolidate(_ hypnogram: String) -> String {
        var s = Array(hypnogram.utf8)
        func isStage(_ c: UInt8) -> Bool { c == L || c == D || c == R }
        var changed = true
        while changed {
            changed = false
            let runs = SleepMath.byteRuns(s)
            for (ri, run) in runs.enumerated() {
                let (c, a, b) = run
                guard isStage(c), b - a + 1 < stageMinBout else { continue }
                let left: (UInt8, Int, Int)? = (ri > 0 && isStage(runs[ri - 1].0)) ? runs[ri - 1] : nil
                let right: (UInt8, Int, Int)? = (ri + 1 < runs.count && isStage(runs[ri + 1].0)) ? runs[ri + 1] : nil
                let target: UInt8
                if let l = left, let r = right {
                    target = (l.2 - l.1) >= (r.2 - r.1) ? l.0 : r.0
                } else if let l = left {
                    target = l.0
                } else if let r = right {
                    target = r.0
                } else {
                    continue
                }
                if target == c { continue }
                for x in a...b { s[x] = target }
                changed = true
                break
            }
        }
        return String(decoding: s, as: UTF8.self)
    }

    /// First index with times[i] >= x (Python bisect_left).
    static func lowerBound(_ times: [Double], _ x: Double) -> Int {
        var lo = 0
        var hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func epochLnRmssd(_ beats: SleepBeats, mid: Double, core: any SignalCore) -> Double? {
        let lo = lowerBound(beats.times, mid - rmssdHalfSeconds)
        let hi = lowerBound(beats.times, mid + rmssdHalfSeconds)
        guard hi - lo >= rmssdMinBeats else { return nil }
        let rr = Array(beats.rrMs[lo..<hi])
        var sum = 0.0
        for v in rr { sum += v }
        guard sum / 1000.0 >= rmssdMinCoverSeconds else { return nil }
        return core.hrvTime(rrMs: rr)?.lnRmssd
    }

    static func robust(_ values: [Double], floor: Double) -> (Double, Double) {
        let med = SignalMath.median(values)
        let mad = SignalMath.median(values.map { Swift.abs($0 - med) })
        return (med, Swift.max(1.4826 * mad, floor))
    }

    /// ALG-120 v1 over `spanStart … spanEnd` (the ALG-030 rest window), widened to whole minutes. `beats` = ALG-004 A
    /// corrected beats for the night (`SleepBeats`).
    public static func stage(grid g: SleepMotionGrid, beats: SleepBeats, spanStart: Double, spanEnd: Double,
                             core: any SignalCore = Signal.core) -> Computed<StagedNight> {
        guard g.rows > 0 else { return .missing("no strap records for the night") }
        let mLo = SleepMath.floorTo(spanStart, 60)
        let mHi = SleepMath.ceilTo(spanEnd, 60)
        guard mHi > mLo else { return .missing("empty span") }
        let nm = Int((mHi - mLo) / 60)
        func gj(_ m: Int64) -> Int { Int(SleepMath.floorDiv(m - g.t0, 60)) }
        func actAt(_ j: Int) -> Double? { j >= 0 && j < g.act.count ? g.act[j] : nil }
        func hrmAt(_ j: Int) -> Double? { j >= 0 && j < g.hrMin.count ? g.hrMin[j] : nil }

        let hrs: [Double?] = (0..<nm).map { hrmAt(gj(mLo + Int64($0) * 60)) }
        let hrsValid = hrs.compactMap { $0 }
        let hrRef: Double? = hrsValid.count >= hrRefMinMinutes ? SignalMath.median(hrsValid) : nil
        var raw: [UInt8] = []
        raw.reserveCapacity(nm)
        for i in 0..<nm {
            let j = gj(mLo + Int64(i) * 60)
            guard actAt(j) != nil else {
                raw.append(N)
                continue
            }
            let ckWake = ckScore(g.act, j) >= 1.0
            var hrWake = false
            if let ref = hrRef, let h = hrs[i] { hrWake = h - ref >= hrWakeDelta }
            raw.append(ckWake || hrWake ? W : S)
        }
        let minutes = Array(webster(String(decoding: raw, as: UTF8.self)).utf8)
        var ep: [UInt8] = []
        ep.reserveCapacity(nm * 2)
        for c in minutes {
            ep.append(c)
            ep.append(c)
        }
        let wakeLayer = String(decoding: ep, as: UTF8.self)
        let hrRefC: Computed<Double>
        if let ref = hrRef {
            hrRefC = .success(ref)
        } else {
            hrRefC = .missing("HR rule off: needs \(hrRefMinMinutes) minutes of on-skin HR")
        }

        var feats: [(Double, Double)?] = []
        feats.reserveCapacity(ep.count)
        for (e, c) in ep.enumerated() {
            guard c == S else {
                feats.append(nil)
                continue
            }
            let es = mLo + Int64(e) * 30
            let k30 = Int(SleepMath.floorDiv(es - g.t0, 30))
            let h: Double? = k30 >= 0 && k30 < g.hr30.count ? g.hr30[k30] : nil
            let ln = epochLnRmssd(beats, mid: Double(es) + 15.0, core: core)
            if let ln, let h { feats.append((ln, h)) } else { feats.append(nil) }
        }
        let nAsleep = ep.filter { $0 == S }.count
        let nFeat = feats.compactMap { $0 }.count
        let coverage = nAsleep > 0 ? Double(nFeat) / Double(nAsleep) : 0.0
        let unstaged = SleepHypnogram(epoch0: mLo, codes: wakeLayer)
        if nAsleep == 0 {
            return .success(StagedNight(hypnogram: unstaged, wakeLayer: wakeLayer, hrRef: hrRefC, staged: false,
                                        stageReason: "no asleep epochs", featureCoverage: coverage,
                                        lnRmssdMedian: nil, lnRmssdSD: nil, hrMedian: nil, hrSD: nil))
        }
        if coverage < stageMinCoverage {
            let reason = String(format: "only %.0f %% of asleep epochs have R-R and HR (needs %.0f %%)",
                                100.0 * Double(nFeat) / Double(nAsleep), 100.0 * stageMinCoverage)
            return .success(StagedNight(hypnogram: unstaged, wakeLayer: wakeLayer, hrRef: hrRefC, staged: false,
                                        stageReason: reason, featureCoverage: coverage, lnRmssdMedian: nil,
                                        lnRmssdSD: nil, hrMedian: nil, hrSD: nil))
        }
        let fs = feats.compactMap { $0 }
        let (medLn, sdLn) = robust(fs.map { $0.0 }, floor: zFloorLn)
        let (medHR, sdHR) = robust(fs.map { $0.1 }, floor: zFloorHR)
        var hyp: [UInt8] = []
        hyp.reserveCapacity(ep.count)
        for (e, c) in ep.enumerated() {
            guard c == S, let f = feats[e] else {
                hyp.append(c)
                continue
            }
            let zl = (f.0 - medLn) / sdLn
            let zh = (f.1 - medHR) / sdHR
            let a = actAt(gj(mLo + Int64(e / 2) * 60))
            if zl <= -zStage && zh >= zStage, let a, a <= remStillDeg {
                hyp.append(R)
            } else if zl >= zStage && zh <= 0.0 {
                hyp.append(D)
            } else {
                hyp.append(L)
            }
        }
        let codes = consolidate(String(decoding: hyp, as: UTF8.self))
        return .success(StagedNight(hypnogram: SleepHypnogram(epoch0: mLo, codes: codes), wakeLayer: wakeLayer,
                                    hrRef: hrRefC, staged: true, stageReason: nil, featureCoverage: coverage,
                                    lnRmssdMedian: medLn, lnRmssdSD: sdLn, hrMedian: medHR, hrSD: sdHR))
    }
}
