import Foundation
import MGDomain

/// What produced one corrected interval (ARCHITECTURE.md 4.6 flag codes; the C ABI uses the raw values).
public enum ArtefactFlag: UInt8, Sendable, CaseIterable {
    case ok = 0
    case ectopic = 1
    case missed = 2
    case extra = 3
    case longShort = 4
}

/// ALG-004 v1 — R-R artefact correction. A: Lipponen & Tarvainen 2019 (J Med Eng Technol 43:173-181) beat classes,
/// corrected so total duration is preserved. B: a 5-min window with more than 5 % corrected beats is dropped
/// (`HRVWindows`), never "corrected" into sinus rhythm. Python reference: app/pclab/mglab/ref/hrv.py
/// `classify_beats` / `correct_artefacts`; goldens app/shared/golden/hrv/ALG-004.json.
public enum ALG004 {
    public static let method = "ALG-004@1 lipponen-tarvainen-2019"
    public static let citation = "Lipponen JA, Tarvainen MP. J Med Eng Technol 2019;43(3):173-181"

    // Lipponen & Tarvainen 2019 constants (as NeuroKit2 signal_fixpeaks, method "Kubios").
    public static let c1 = 0.13
    public static let c2 = 0.17
    public static let alpha = 5.2
    public static let qdHalfWindow = 45          // 91-beat centred window
    public static let medianHalfWindow = 5       // 11-beat centred median
    // Ours, documented additions:
    /// A zero-spread window (quantised or constant R-R) must not switch detection off.
    public static let thresholdFloorMs = 10.0
    /// Longer than 2× the slowest plausible beat (HR 30): not an interval but a dropout → removed and counted.
    public static let maxValidMs = 4000.0
    public static let minBeats = 3
    /// ALG-004 B.
    public static let windowMaxArtefactFraction = 0.05

    /// Corrected series with beat end times carried through.
    public struct Corrected: Sendable, Equatable {
        public var rrMs: [Double]
        public var flags: [UInt8]
        public var times: [Double]
        public var correctedFraction: Double

        public init(rrMs: [Double], flags: [UInt8], times: [Double], correctedFraction: Double) {
            self.rrMs = rrMs
            self.flags = flags
            self.times = times
            self.correctedFraction = correctedFraction
        }

        public var result: ArtefactResult {
            ArtefactResult(rrMs: rrMs, flags: flags, correctedFraction: correctedFraction)
        }
    }

    /// ALG-004 A: classify, then correct in one left-to-right pass.
    /// - invalid (non-finite, ≤ 0, > 4000 ms) → removed, counted;
    /// - extra at j → rr[j] + rr[j+1] merged (flag 3); missed at j → rr[j] split in halves (flag 2 on both);
    /// - ectopic at f → the beat between rr[f−1] and rr[f] moves to their midpoint (both = mean, flag 1);
    /// - long/short at j → rr[j], rr[j+1] = their mean (flag 4).
    /// Where two corrections claim the same interval the earlier wins; at the same start: extra > missed > ectopic >
    /// long/short (NeuroKit2's order). `correctedFraction` = (corrections applied + invalid removed) / input count —
    /// one correction per beat moved, added or removed (Kubios' "beats corrected").
    /// `times` = beat end times of the input (s); nil → running sum of the valid R-R from 0.
    public static func correct(rrMs input: [Double], times inputTimes: [Double]? = nil) -> Corrected {
        let nIn = input.count
        var r: [Double] = []
        var t: [Double] = []
        r.reserveCapacity(nIn)
        var acc = 0.0
        for i in 0..<nIn {
            let v = input[i]
            guard v.isFinite, v > 0, v <= maxValidMs else { continue }
            r.append(v)
            if let inputTimes, i < inputTimes.count {
                t.append(inputTimes[i])
            } else {
                acc += v / 1000.0
                t.append(acc)
            }
        }
        let n = r.count
        let cls = classify(rrMs: r)

        // One action per start index; lower rank = higher priority.
        enum Kind: Int { case merge = 0, split = 1, pairEctopic = 2, pairLongShort = 3 }
        var action = [Kind?](repeating: nil, count: n)
        func want(_ start: Int, _ kind: Kind) {
            guard start >= 0, start < n else { return }
            if let cur = action[start], cur.rawValue <= kind.rawValue { return }
            action[start] = kind
        }
        for j in 0..<n {
            switch ArtefactFlag(rawValue: cls[j]) ?? .ok {
            case .extra:
                if j + 1 < n { want(j, .merge) }
            case .missed:
                want(j, .split)
            case .ectopic:
                let s = max(j - 1, 0)
                if s + 1 < n { want(s, .pairEctopic) }
            case .longShort:
                if j + 1 < n { want(j, .pairLongShort) }
            case .ok:
                break
            }
        }

        var outR: [Double] = []
        var outF: [UInt8] = []
        var outT: [Double] = []
        outR.reserveCapacity(n + 4)
        var applied = 0
        var k = 0
        while k < n {
            let a = action[k]
            let hasNext = k + 1 < n
            if a == .merge && hasNext {
                outR.append(r[k] + r[k + 1]); outF.append(ArtefactFlag.extra.rawValue); outT.append(t[k + 1])
                applied += 1
                k += 2
            } else if (a == .pairEctopic || a == .pairLongShort) && hasNext {
                let code = (a == .pairEctopic ? ArtefactFlag.ectopic : ArtefactFlag.longShort).rawValue
                let mid = (r[k] + r[k + 1]) / 2.0
                let start = t[k] - r[k] / 1000.0
                outR.append(mid); outF.append(code); outT.append(start + mid / 1000.0)
                outR.append(mid); outF.append(code); outT.append(t[k + 1])
                applied += 1
                k += 2
            } else if a == .split {
                let h = r[k] / 2.0
                outR.append(h); outF.append(ArtefactFlag.missed.rawValue); outT.append(t[k] - h / 1000.0)
                outR.append(h); outF.append(ArtefactFlag.missed.rawValue); outT.append(t[k])
                applied += 1
                k += 1
            } else {
                outR.append(r[k]); outF.append(ArtefactFlag.ok.rawValue); outT.append(t[k])
                k += 1
            }
        }
        let bad = (nIn - n) + applied
        return Corrected(rrMs: outR, flags: outF, times: outT,
                         correctedFraction: nIn > 0 ? Double(bad) / Double(nIn) : 0)
    }

    /// ALG-004 A classification (Lipponen & Tarvainen 2019 Fig. 1 decision flow, as NeuroKit2 implements it), one
    /// `ArtefactFlag` raw value per input interval. dRR[i] = rr[i] − rr[i−1], dRR[0] = mean(dRR[1…]).
    /// Thresholds: α × quartile deviation of the SIGNED series over 91 beats, floored at 10 ms (NeuroKit2 uses |x|,
    /// which flagged 0.5–2 % of clean jittered beats in the reference's synthetic test; see hrv.py `_qd_threshold`).
    public static func classify(rrMs rr: [Double]) -> [UInt8] {
        let n = rr.count
        var cls = [UInt8](repeating: ArtefactFlag.ok.rawValue, count: n)
        guard n >= minBeats else { return cls }

        var drr = [Double](repeating: 0, count: n)
        for i in 1..<n { drr[i] = rr[i] - rr[i - 1] }
        drr[0] = SignalMath.mean(Array(drr[1...]))
        let th1 = qdThreshold(drr)
        let d = (0..<n).map { drr[$0] / th1[$0] }
        // numpy.pad(d, 2, "reflect") for n >= 3
        let dp = [d[2], d[1]] + d + [d[n - 2], d[n - 3]]
        var s12 = [Double](repeating: 0, count: n)
        var s22 = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let p = i + 2
            if dp[p] > 0 {
                s12[i] = max(dp[p - 1], dp[p + 1])
            } else if dp[p] < 0 {
                s12[i] = min(dp[p - 1], dp[p + 1])
            }
            if dp[p] >= 0 {
                s22[i] = min(dp[p + 1], dp[p + 2])
            } else {
                s22[i] = max(dp[p + 1], dp[p + 2])
            }
        }
        let med = rollingMedian(rr, half: medianHalfWindow)
        let mrr = (0..<n).map { i -> Double in
            let v = rr[i] - med[i]
            return v < 0 ? v * 2.0 : v
        }
        let th2 = qdThreshold(mrr)
        let m = (0..<n).map { mrr[$0] / th2[$0] }

        var i = 0
        while i < n - 2 {
            if abs(d[i]) <= 1 {
                i += 1
                continue
            }
            let eq1 = d[i] > 1 && s12[i] < (-c1 * d[i] - c2)
            let eq2 = d[i] < -1 && s12[i] > (-c1 * d[i] + c2)
            if eq1 || eq2 {
                cls[i] = ArtefactFlag.ectopic.rawValue
                i += 1
                continue
            }
            var candidates = [i]
            if abs(d[i + 1]) < abs(d[i + 2]) { candidates.append(i + 1) }
            for j in candidates {
                let eq3 = d[j] > 1 && s22[j] < -1
                let eq4 = abs(m[j]) > 3
                let eq5 = d[j] < -1 && s22[j] > 1
                if !(eq3 || eq4 || eq5) {
                    i += 1
                    continue
                }
                let eq6 = abs(rr[j] / 2.0 - med[j]) < th2[j]
                let eq7 = abs(rr[j] + rr[j + 1] - med[j]) < th2[j]
                if eq5 && eq7 {
                    cls[j] = ArtefactFlag.extra.rawValue
                } else if eq3 && eq6 {
                    cls[j] = ArtefactFlag.missed.rawValue
                } else {
                    cls[j] = ArtefactFlag.longShort.rawValue
                }
                i += 1
            }
        }
        return cls
    }

    /// α × (Q3 − Q1)/2 of the signed series over the centred 91-beat window (clipped at the ends), floored.
    static func qdThreshold(_ x: [Double]) -> [Double] {
        let n = x.count
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let seg = Array(x[max(0, i - qdHalfWindow)...min(n - 1, i + qdHalfWindow)]).sorted()
            let qd = (SignalMath.quantileSorted(seg, 0.75) - SignalMath.quantileSorted(seg, 0.25)) / 2.0
            out[i] = max(alpha * qd, thresholdFloorMs)
        }
        return out
    }

    static func rollingMedian(_ x: [Double], half: Int) -> [Double] {
        let n = x.count
        return (0..<n).map { i in SignalMath.median(Array(x[max(0, i - half)...min(n - 1, i + half)])) }
    }

    /// The `rr_artefact` metric (%, window night): the share of beats ALG-004 A corrected over the night.
    public static let artefactSpec = MetricSpec(
        key: .rrArtefact, unit: "%", group: nil, variant: "ALG-004", method: method, tier: .high, source: "rr",
        window: "night", citation: citation, paramsVersion: "LT2019 a5.2 c0.13/0.17 w91/11 signedQD floor10")

    /// `rr_artefact` from the night's window set. Missing when there were no beats.
    public static func metric(_ set: HRVWindowSet, at: Date) -> Metric {
        artefactSpec.metric(set.beatsIn > 0 ? .success(100.0 * set.artefactFraction) : .missing("no R-R in the night"),
                            at: at)
    }
}
