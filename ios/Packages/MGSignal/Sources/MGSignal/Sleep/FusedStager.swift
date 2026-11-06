import Foundation
import MGDomain

/// ALG-151 v1 — the phone fused stager (D-SLEEP-WALK-1 item 2, Mo Oct 17 2026; replaces the ALG-120 "hybrid").
/// The strap's own sleep flag is a HARD GATE: every strap-awake epoch is W and the strap-asleep minutes are untouched, so
/// ALG-150 totals stay the strap's. Inside strap-asleep epochs a small gradient-boosted tree ensemble, trained on
/// polysomnography, picks light / deep / REM from what the phone has every night: epoch HR relative to the night's median,
/// wrist-angle activity (degrees per minute from `SleepMotionGrid`) and their rolling context, and the time since the first
/// strap-asleep epoch. Python reference (VERIFIED against it by goldens): `mglab.ref.sleep_fused`; model, training and
/// validation: `pclab/prototypes/train_phone_stager.py`, `shared/models/fused_stager_v1.json`.
///
/// Source: Walch et al. 2019, SLEEP 42(12) (PhysioNet sleep-accel 1.0.0, DOI 10.13026/hmhs-py35, ODC-By) for the PSG-labelled
/// training data; van Hees et al. 2015, PLoS ONE 10(11) for the z-angle; Friedman 2001, Ann. Stat. 29 for the trees.
/// Activity scale: Walch's accelerometer was reduced to a 1 Hz gravity vector and run through the same motion grid, so the
/// feature is degrees on both sides (not a count scale). Leave-subjects-out numbers: docs/research/FUSED-STAGER-ALG151-2026-10-17.md.
public enum FusedStager {
    /// The G-STAGE member / registry variant this stager writes (display label: "ours (phone), fused stager").
    public static let variant = "ALG-151"
    public static let method = "ALG-151@1 base tier: fused stager (strap gate + HR + wrist-angle activity + night time, PSG-trained trees)"
    public static let citation = "Walch et al. 2019 SLEEP 42(12) (PhysioNet sleep-accel, PSG labels); van Hees et al. 2015 PLoS ONE "
        + "10(11):e0142533; Friedman 2001 Ann Stat 29; docs/research/FUSED-STAGER-ALG151-2026-10-17.md"
    public static let confidenceNote = "base tier (R18 HR + wrist angle + strap flag; no R-R or raw stream needed), estimate: asleep / awake is the strap's own flag; light / deep / REM come from a small "
        + "tree model trained on polysomnography (heart rate + wrist movement only; leave-subjects-out kappa about 0.45)"

    static let epochSeconds: Int64 = 30
    static let dPerEpoch = 6
    static let epochMinValidD = 3
    static let minCoverage = 0.5
    static let quietDeg = 5.0
    static let featureNames = ["t_h", "frac", "a_s", "a_s_m5", "a_s_m10", "a_s_m20", "a_s_max10", "a_s_lag10", "a_s_lead10",
                               "quiet_epochs", "hr_rel", "hr_rel_m5", "hr_rel_m10", "hr_rel_m20", "hr_sd10", "hr_lag10",
                               "hr_lead10", "hr_dev20"]
    static let labels: [UInt8] = [SleepStageCode.light.byte, SleepStageCode.deep.byte, SleepStageCode.rem.byte]

    public struct Night: Sendable, Equatable {
        /// On the strap's epoch grid: W strap-awake, L / D / R staged, S strap-asleep but not staged, . no sample.
        public var hypnogram: SleepHypnogram
        /// False: the asleep time is unstaged `S` and `stageReason` says why.
        public var staged: Bool
        public var stageReason: String?
        /// Strap-asleep epochs left `S` (outside the staged window, or the whole night when not staged).
        public var unstagedAsleepEpochs: Int

        public init(hypnogram: SleepHypnogram, staged: Bool, stageReason: String?, unstagedAsleepEpochs: Int) {
            self.hypnogram = hypnogram
            self.staged = staged
            self.stageReason = stageReason
            self.unstagedAsleepEpochs = unstagedAsleepEpochs
        }
    }

    // MARK: epoch inputs

    /// Per 30-s epoch (start epoch0 + 30 e): mean of the epoch's valid 5-s angle changes x 12 (degrees per minute); nan when
    /// fewer than 3 of the 6 are valid. d[k] is the change INTO 5-s epoch k.
    static func epochActivity(grid g: SleepMotionGrid, epoch0: Int64, count n: Int) -> [Double] {
        var out = [Double](repeating: .nan, count: n)
        for e in 0..<n {
            let k0 = Int(SleepMath.floorDiv(epoch0 + Int64(e) * epochSeconds - g.t0, 5))
            var sum = 0.0
            var c = 0
            for k in k0..<(k0 + dPerEpoch) where k >= 0 && k < g.d.count {
                if let v = g.d[k] {
                    sum += v
                    c += 1
                }
            }
            if c >= epochMinValidD { out[e] = sum / Double(c) * 12.0 }
        }
        return out
    }

    static func epochHR(grid g: SleepMotionGrid, epoch0: Int64, count n: Int) -> [Double] {
        var out = [Double](repeating: .nan, count: n)
        for e in 0..<n {
            let k = Int(SleepMath.floorDiv(epoch0 + Int64(e) * epochSeconds - g.t0, epochSeconds))
            if k >= 0 && k < g.hr30.count, let v = g.hr30[k] { out[e] = v }
        }
        return out
    }

    // MARK: features

    static func nanMean(_ a: [Double], _ lo: Int, _ hi: Int) -> Double {
        var s = 0.0
        var c = 0
        var j = Swift.max(lo, 0)
        let end = Swift.min(hi, a.count - 1)
        while j <= end {
            if !a[j].isNaN {
                s += a[j]
                c += 1
            }
            j += 1
        }
        return c > 0 ? s / Double(c) : .nan
    }

    static func nanMax(_ a: [Double], _ lo: Int, _ hi: Int) -> Double {
        var best = Double.nan
        var found = false
        var j = Swift.max(lo, 0)
        let end = Swift.min(hi, a.count - 1)
        while j <= end {
            let v = a[j]
            if !v.isNaN && (!found || v > best) {
                best = v
                found = true
            }
            j += 1
        }
        return best
    }

    /// Population SD of the non-nan values; nan when fewer than 3.
    static func nanSD(_ a: [Double], _ lo: Int, _ hi: Int) -> Double {
        var vals: [Double] = []
        var j = Swift.max(lo, 0)
        let end = Swift.min(hi, a.count - 1)
        while j <= end {
            if !a[j].isNaN { vals.append(a[j]) }
            j += 1
        }
        if vals.count < 3 { return .nan }
        var s = 0.0
        for v in vals { s += v }
        let m = s / Double(vals.count)
        var q = 0.0
        for v in vals { q += (v - m) * (v - m) }
        return (q / Double(vals.count)).squareRoot()
    }

    /// One row of `featureNames` per epoch of the window. `act` degrees / min, `hr` bpm (nan = none), `asleep` = the strap
    /// gate. Missing when under half of the asleep epochs have both HR and activity.
    static func features(act: [Double], hr: [Double], asleep: [Bool]) -> Computed<[[Double]]> {
        let n = act.count
        let nAsleep = asleep.filter { $0 }.count
        guard nAsleep > 0 else { return .missing("no strap-asleep epochs") }
        var both = 0
        for i in 0..<n where asleep[i] && !hr[i].isNaN && !act[i].isNaN { both += 1 }
        guard Double(both) >= minCoverage * Double(nAsleep) else {
            return .missing(String(format: "only %.0f %% of asleep epochs have HR and activity (needs %.0f %%)",
                                   100.0 * Double(both) / Double(nAsleep), 100.0 * minCoverage))
        }
        var hrAsleep: [Double] = []
        for i in 0..<n where asleep[i] && !hr[i].isNaN { hrAsleep.append(hr[i]) }
        let base = SignalMath.median(hrAsleep)
        let aS = act.map { $0.isNaN ? Double.nan : $0.squareRoot() }
        let hR = hr.map { $0.isNaN ? Double.nan : $0 - base }
        var rows: [[Double]] = []
        rows.reserveCapacity(n)
        var quiet = 0
        for i in 0..<n {
            quiet = (!act[i].isNaN && act[i] < quietDeg) ? quiet + 1 : 0
            let m20 = nanMean(hR, i - 20, i + 20)
            rows.append([
                Double(i) * Double(epochSeconds) / 3600.0,
                n > 1 ? Double(i) / Double(n - 1) : 0.0,
                aS[i],
                nanMean(aS, i - 5, i + 5),
                nanMean(aS, i - 10, i + 10),
                nanMean(aS, i - 20, i + 20),
                nanMax(aS, i - 10, i + 10),
                nanMean(aS, i - 10, i - 1),
                nanMean(aS, i + 1, i + 10),
                Double(quiet),
                hR[i],
                nanMean(hR, i - 5, i + 5),
                nanMean(hR, i - 10, i + 10),
                m20,
                nanSD(hR, i - 10, i + 10),
                nanMean(hR, i - 10, i - 1),
                nanMean(hR, i + 1, i + 10),
                (hR[i].isNaN || m20.isNaN) ? Double.nan : hR[i] - m20,
            ])
        }
        return .success(rows)
    }

    // MARK: the model

    struct Model {
        let feature: [Int16]
        let nanLeft: [Bool]
        let left: [Int]
        let right: [Int]
        let threshold: [Double]
        let value: [Double]

        static let shared: Model? = decode()

        static func decode() -> Model? {
            guard let data = Data(base64Encoded: FusedStagerModel.nodesBase64), data.count == FusedStagerModel.nodeCount * 16,
                  FusedStagerModel.features == FusedStager.featureNames else { return nil }
            let n = FusedStagerModel.nodeCount
            var f = [Int16](repeating: -1, count: n)
            var m = [Bool](repeating: false, count: n)
            var l = [Int](repeating: 0, count: n)
            var r = [Int](repeating: 0, count: n)
            var t = [Double](repeating: 0, count: n)
            var v = [Double](repeating: 0, count: n)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<n {
                    let o = i * 16
                    f[i] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: Int16.self))
                    m[i] = raw.load(fromByteOffset: o + 2, as: UInt8.self) != 0
                    l[i] = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 4, as: UInt16.self)))
                    r[i] = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 6, as: UInt16.self)))
                    t[i] = Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self))))
                    v[i] = Double(Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 12, as: UInt32.self))))
                }
            }
            return Model(feature: f, nanLeft: m, left: l, right: r, threshold: t, value: v)
        }

        /// Sum of the leaf values per class plus the class baseline; left when value <= threshold, nan goes where the node says.
        func rawScores(_ row: [Double]) -> [Double] {
            var s = FusedStagerModel.baseline
            for (start, cls) in zip(FusedStagerModel.treeStarts, FusedStagerModel.treeClass) {
                var i = start
                while feature[i] >= 0 {
                    let x = row[Int(feature[i])]
                    let goLeft = x.isNaN ? nanLeft[i] : x <= threshold[i]
                    i = goLeft ? left[i] : right[i]
                }
                s[cls] += value[i]
            }
            return s
        }

        /// Index of the largest raw score (first on a tie).
        func classify(_ row: [Double]) -> Int {
            let s = rawScores(row)
            var best = 0
            for k in 1..<s.count where s[k] > s[best] { best = k }
            return best
        }
    }

    // MARK: staging

    /// Mode filter over +-half epochs on the L / D / R characters (others pass through and do not vote); a tie keeps the
    /// epoch's own character, else the first winner in L, D, R order. half <= 0 is the identity.
    static func smooth(_ codes: [UInt8], half: Int) -> [UInt8] {
        if half <= 0 { return codes }
        var out: [UInt8] = []
        out.reserveCapacity(codes.count)
        for (i, c) in codes.enumerated() {
            guard labels.contains(c) else {
                out.append(c)
                continue
            }
            var counts = [Int](repeating: 0, count: labels.count)
            var j = Swift.max(0, i - half)
            let end = Swift.min(codes.count - 1, i + half)
            while j <= end {
                if let k = labels.firstIndex(of: codes[j]) { counts[k] += 1 }
                j += 1
            }
            let top = counts.max() ?? 0
            let winners = labels.indices.filter { counts[$0] == top }.map { labels[$0] }
            out.append(winners.contains(c) ? c : winners[0])
        }
        return out
    }

    /// W for strap-awake epochs, L / D / R for strap-asleep ones, over one window; Missing when the inputs are too sparse.
    static func stageEpochs(act: [Double], hr: [Double], asleep: [Bool]) -> Computed<[UInt8]> {
        guard let model = Model.shared else { return .missing("the embedded stager model failed to decode") }
        return features(act: act, hr: hr, asleep: asleep).map { rows in
            var out: [UInt8] = []
            out.reserveCapacity(rows.count)
            for (i, r) in rows.enumerated() {
                out.append(asleep[i] ? labels[model.classify(r)] : SleepStageCode.wake.byte)
            }
            return smooth(out, half: FusedStagerModel.smoothHalf)
        }
    }

    /// ALG-151 over one night on the strap's epoch grid. The window runs from the first to the last strap-asleep epoch; a
    /// strap-asleep epoch outside it, or the whole night when staging is Missing, stays `S`. Python: `sleep_fused.stage_night` +
    /// `overlay`.
    public static func stage(grid: SleepMotionGrid, strap: SleepStrapFlag.Epochs) -> Night {
        let W = SleepStageCode.wake.byte
        let S = SleepStageCode.asleep.byte
        let N = SleepStageCode.noData.byte
        let two = UInt8(ascii: "2")
        let codes = Array(strap.codes.utf8)
        func overlay(_ staged: [UInt8]?, firstEpoch: Int) -> Night {
            var out: [UInt8] = []
            out.reserveCapacity(codes.count)
            var unstaged = 0
            for (i, c) in codes.enumerated() {
                if c == N {
                    out.append(N)
                } else if c != two {
                    out.append(W)
                } else if let st = staged, i >= firstEpoch, i - firstEpoch < st.count {
                    out.append(st[i - firstEpoch])
                } else {
                    out.append(S)
                    unstaged += 1
                }
            }
            return Night(hypnogram: SleepHypnogram(epoch0: strap.epoch0, codes: String(decoding: out, as: UTF8.self)),
                         staged: staged != nil, stageReason: nil, unstagedAsleepEpochs: unstaged)
        }
        guard let first = codes.firstIndex(of: two), let last = codes.lastIndex(of: two) else {
            var n = overlay(nil, firstEpoch: 0)
            n.stageReason = "no strap-asleep epochs"
            return n
        }
        let count = last - first + 1
        let epoch0 = strap.epoch0 + Int64(first) * epochSeconds
        let win = Array(codes[first...last])
        let asleep = win.map { $0 == two }
        let act = epochActivity(grid: grid, epoch0: epoch0, count: count)
        let hr = epochHR(grid: grid, epoch0: epoch0, count: count)
        switch stageEpochs(act: act, hr: hr, asleep: asleep) {
        case .success(let st):
            // a "." inside the window stays "." (it was never asleep for the baseline)
            var merged = st
            for i in 0..<count where win[i] == N { merged[i] = N }
            return overlay(merged, firstEpoch: first)
        case .failure(let m):
            var n = overlay(nil, firstEpoch: 0)
            n.stageReason = m.reason
            return n
        }
    }
}
