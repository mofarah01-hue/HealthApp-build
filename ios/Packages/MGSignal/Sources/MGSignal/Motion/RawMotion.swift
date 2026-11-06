import Foundation
import MGDomain

/// Raw motion (R21, 100 Hz six-axis IMU) → ENMO in mg per minute (ALG-113), wrist gait asymmetry `imu_asym` (ALG-114)
/// and the cosinor inputs of CosinorAge (ALG-134). Added 2026-10-11 19:50 PT (wave W8). Pure functions, no I/O.
///
/// SCALE. The stored samples are raw counts. noop converts accelerometer counts at 1/4096 g per LSB
/// (Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5RawImu.swift L51, "VALIDATED on 1423 buffers from a real 5.0
/// (fw 50.40.1.0): accel magnitude is a 1.01 g gravity shell", L22-24), while noop docs/PROTOCOL_SENSORS.md L419-424 call
/// it an earlier convention the layout does not establish. So no mg number is produced unless THIS strap's still wrist
/// reads 1 g at that scale: the median magnitude of still seconds must be within ±5 % of 4,096 counts
/// (`gravityCheck`). Gait asymmetry and the trace need no scale (autocorrelation is scale-free).
/// TIMING. A full buffer's sample i sits at base + i/100 s (PROTOCOL_SENSORS.md L419-421); partly filled buffers have no
/// established timing, so gait windows use full buffers only.
public enum RawMotion {
    public static let lsbPerG = 4096.0
    public static let gravityTolerance = 0.05
    /// A second is "still" when the SD of its magnitude is below 0.01 g.
    public static let stillSDLSB = 0.01 * lsbPerG
    public static let minStillSeconds = 30
    /// A minute counts toward ENMO when at least this many of its seconds were captured.
    public static let minSecondsPerMinute = 30

    /// Per-second accelerometer summaries in raw counts (MGDomain `MotionSecond.accelSummary`).
    public typealias SecondSummary = MotionAccelSummary

    public static func magnitudes(_ c: [[Int16]]) -> [Double] { MotionSecond.magnitudes(c) }

    public static func summarize(_ seconds: [MotionSecond]) -> [SecondSummary] { seconds.compactMap(\.accelSummary) }

    /// Whether 1/4096 g per LSB holds for this data: median still magnitude in g, or why it cannot be said.
    public static func gravityCheck(_ s: [SecondSummary]) -> Computed<Double> {
        let still = s.filter { $0.n >= 50 && $0.sdMagLSB < stillSDLSB }.map(\.meanMagLSB)
        guard still.count >= minStillSeconds else {
            return .missing("the accelerometer scale is checked against gravity on still seconds; only \(still.count) "
                            + "still second(s) of raw motion, \(minStillSeconds) needed")
        }
        let g = SignalMath.median(still) / lsbPerG
        guard abs(g - 1) <= gravityTolerance else {
            return .missing(String(format: "a still wrist reads %.3f g at 1/4096 g per count (expected 1 ± %.2f): the "
                                   + "accelerometer scale is not confirmed on this strap, so no mg value", g,
                                   gravityTolerance))
        }
        return .success(g)
    }

    /// ENMO (Euclidean norm minus one, negatives set to 0; van Hees et al. 2013, PLoS One 8(4):e61691) in mg, averaged per
    /// clock minute (unix minute start → mg, seconds captured). Only minutes with ≥ 30 captured seconds; call only after
    /// `gravityCheck` succeeded.
    public static func enmoMinutes(_ s: [SecondSummary]) -> [Int64: (mg: Double, seconds: Int)] {
        var acc: [Int64: (sum: Double, n: Int, seconds: Int)] = [:]
        for x in s {
            let minute = x.ts - ((x.ts % 60) + 60) % 60
            var a = acc[minute] ?? (0, 0, 0)
            a.sum += x.enmoLSB * Double(x.n)
            a.n += x.n
            a.seconds += 1
            acc[minute] = a
        }
        var out: [Int64: (mg: Double, seconds: Int)] = [:]
        for (m, a) in acc where a.seconds >= minSecondsPerMinute && a.n > 0 {
            out[m] = (a.sum / Double(a.n) / lsbPerG * 1000, a.seconds)
        }
        return out
    }

    // MARK: ALG-114 wrist gait asymmetry

    public static let gaitWindowSeconds = 10
    public static let minWalkingWindows = 6
    public static let walkSDRangeG = (0.03, 0.5)
    public static let minStrideRegularity = 0.5

    /// One walking window: step and stride regularity and its asymmetry.
    public struct GaitWindow: Sendable, Equatable {
        public var start: Int64
        public var stepRegularity: Double
        public var strideRegularity: Double
        public var strideSeconds: Double
        public var asymmetry: Double
    }

    /// Unbiased autocorrelation r(k) = [Σ x_i x_{i+k} / (N − k)] / [Σ x_i² / N] of a mean-removed series.
    static func autocorrelation(_ x: [Double], lag k: Int) -> Double {
        let n = x.count
        guard k < n, k >= 0 else { return 0 }
        var num = 0.0
        for i in 0..<(n - k) { num += x[i] * x[i + k] }
        let den = x.reduce(0) { $0 + $1 * $1 } / Double(n)
        return den > 0 ? (num / Double(n - k)) / den : 0
    }

    /// Moe-Nilssen R, Helbostad JL. J Biomech 2004;37(1):121-126: step regularity Ad1 (first dominant autocorrelation peak)
    /// and stride regularity Ad2 (the peak at one stride); their ratio is step symmetry. Their sensor was on the trunk; here
    /// it is the wrist magnitude, so arm swing mixes in (ALGORITHM-REQUIREMENTS ALG-114: research). Our v0 index:
    /// asymmetry = min(1, |1 − Ad1 / Ad2|) per 10-s window of full buffers with magnitude SD 0.03–0.5 g (walking, not
    /// still, not running) and Ad2 ≥ 0.5; stride lag searched in 0.8–1.6 s, step lag in 0.35–0.65 of it. Left/right
    /// labelling by gyro phase (also in ALG-114) is not built.
    public static func gaitWindows(_ seconds: [MotionSecond]) -> [GaitWindow] {
        let full = seconds.filter { $0.accelCount == 100 }.sorted { $0.ts < $1.ts }
        var runs: [[MotionSecond]] = []
        for s in full {
            if let last = runs.last?.last, s.ts == last.ts + 1 { runs[runs.count - 1].append(s) } else { runs.append([s]) }
        }
        var out: [GaitWindow] = []
        for run in runs where run.count >= gaitWindowSeconds {
            var i = 0
            while i + gaitWindowSeconds <= run.count {
                let slice = run[i..<(i + gaitWindowSeconds)]
                var mag: [Double] = []
                for s in slice { if let c = s.columns { mag += magnitudes(c) } }
                i += gaitWindowSeconds
                guard mag.count == gaitWindowSeconds * 100 else { continue }
                let mean = mag.reduce(0, +) / Double(mag.count)
                let x = mag.map { $0 - mean }
                let sdG = (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot() / lsbPerG
                guard sdG >= walkSDRangeG.0, sdG <= walkSDRangeG.1 else { continue }
                var strideLag = 0
                var ad2 = -1.0
                for k in 80...160 {
                    let r = autocorrelation(x, lag: k)
                    if r > ad2 { ad2 = r; strideLag = k }
                }
                guard ad2 >= minStrideRegularity, strideLag > 80, strideLag < 160 else { continue }
                let lo = Int((0.35 * Double(strideLag)).rounded()), hi = Int((0.65 * Double(strideLag)).rounded())
                var ad1 = -1.0
                var stepLag = lo
                for k in lo...hi {
                    let r = autocorrelation(x, lag: k)
                    if r > ad1 { ad1 = r; stepLag = k }
                }
                guard stepLag > lo, stepLag < hi else { continue }   // a local peak, not the edge of the search
                let asym = ad1 <= 0 ? 1 : min(1, abs(1 - ad1 / ad2))
                out.append(GaitWindow(start: slice.first!.ts, stepRegularity: ad1, strideRegularity: ad2,
                                      strideSeconds: Double(strideLag) / 100, asymmetry: asym))
            }
        }
        return out
    }

    /// The day's `imu_asym`: median window asymmetry over ≥ 6 walking windows (1 min of walking).
    public static func gaitAsymmetry(_ seconds: [MotionSecond]) -> Computed<(value: Double, windows: Int)> {
        let w = gaitWindows(seconds)
        guard w.count >= minWalkingWindows else {
            return .missing("needs ≥ \(minWalkingWindows * gaitWindowSeconds) s of steady walking during raw motion "
                            + "(\(w.count * gaitWindowSeconds) s found)")
        }
        return .success((SignalMath.median(w.map(\.asymmetry)), w.count))
    }

    // MARK: CosinorAge inputs (ALG-134:cosinor)

    public struct CosinorFit: Sendable, Equatable {
        public var mesor: Double
        public var amplitude: Double
        /// Radians in (−2π, 0], CosinorPy convention: y = M + A·cos(2πt/1440 + φ).
        public var acrophase: Double
        public var days: Int
    }

    /// The intended number needs 4 complete days (the model was fitted on multi-day records); T18: from 1 complete day it
    /// still runs, labelled an estimate (`ALG134.cosinorNote`); below 1 it is blank with the reason.
    public static let cosinorMinDays = 4
    public static let cosinorMinEstimateDays = 1
    /// Days of history the CosinorAge read looks back over (the pipeline passes the summaries of these days).
    public static let cosinorWindowDays = 7

    /// Gravity check + minute ENMO + `cosinorInputs` over the summaries of the days before today.
    public static func cosinorFromSummaries(_ s: [MotionAccelSummary], dayStarts: [Int64]) -> Computed<CosinorFit> {
        guard !s.isEmpty else {
            return .missing("CosinorAge needs ≥ \(cosinorMinEstimateDays) complete day of minute ENMO from raw motion "
                            + "(raw motion on all day; \(cosinorMinDays) days give the intended number); none recorded in the "
                            + "last \(dayStarts.count) days")
        }
        if case .failure(let m) = gravityCheck(s) { return .failure(m) }
        return cosinorInputs(enmoMinutes: enmoMinutes(s).mapValues { $0.mg }, dayStarts: dayStarts)
    }
    public static let completeDayMinutes = 1368      // 95 % of 1,440

    /// Single-component cosinor by least squares on y = M + β·cos(2πt/1440) + γ·sin(2πt/1440), t in minutes counted from
    /// 1 at the first local midnight (CosinorAge cosinorage/features/utils/cosinor_analysis.py `cosinor_multiday`, which
    /// calls CosinorPy cosinor1.fit_cosinor with period 1440). A = √(β² + γ²); φ = atan2(−γ, β) moved into (−2π, 0] —
    /// the same angle CosinorPy `amp_acr` (corrected) returns quadrant by quadrant.
    public static func cosinor(_ points: [(t: Double, y: Double)]) -> (mesor: Double, amplitude: Double, acrophase: Double)? {
        guard points.count >= 3 else { return nil }
        let w = 2 * Double.pi / 1440
        // normal equations for [1, c, s]
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        var b = [0.0, 0.0, 0.0]
        for p in points {
            let row = [1, cos(w * p.t), sin(w * p.t)]
            for i in 0..<3 {
                b[i] += row[i] * p.y
                for j in 0..<3 { a[i][j] += row[i] * row[j] }
            }
        }
        guard let x = solve3(a, b) else { return nil }
        let (m, beta, gamma) = (x[0], x[1], x[2])
        var phi = atan2(-gamma, beta)
        if phi > 0 { phi -= 2 * Double.pi }
        return (m, (beta * beta + gamma * gamma).squareRoot(), phi)
    }

    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a
        var v = b
        for c in 0..<3 {
            guard let p = (c..<3).max(by: { abs(m[$0][c]) < abs(m[$1][c]) }), abs(m[p][c]) > 1e-12 else { return nil }
            m.swapAt(c, p)
            v.swapAt(c, p)
            for r in 0..<3 where r != c {
                let f = m[r][c] / m[c][c]
                for k in c..<3 { m[r][k] -= f * m[c][k] }
                v[r] -= f * v[c]
            }
        }
        return (0..<3).map { v[$0] / m[$0][$0] }
    }

    /// The cosinor of the longest run of complete consecutive local days (≥ 1,368 ENMO minutes each) among `dayStarts`
    /// (unix seconds of each local midnight, oldest first, consecutive). CosinorAge needs complete days (its generic data
    /// handler keeps at least 4 consecutive ones: cosinorage/datahandlers/utils/generic.py L259).
    public static func cosinorInputs(enmoMinutes: [Int64: Double], dayStarts: [Int64]) -> Computed<CosinorFit> {
        guard dayStarts.count >= 2 else { return .missing("no days to fit") }
        var complete: [Bool] = []
        for (i, d0) in dayStarts.enumerated() {
            let d1 = i + 1 < dayStarts.count ? dayStarts[i + 1] : d0 + 86_400
            complete.append(enmoMinutes.keys.filter { $0 >= d0 && $0 < d1 }.count >= completeDayMinutes)
        }
        var best = (start: 0, len: 0)
        var cur = (start: 0, len: 0)
        for (i, ok) in complete.enumerated() {
            if ok { cur = cur.len == 0 ? (i, 1) : (cur.start, cur.len + 1) } else { cur = (0, 0) }
            if cur.len > best.len { best = cur }
        }
        guard best.len >= cosinorMinEstimateDays else {
            return .missing("CosinorAge needs ≥ \(cosinorMinEstimateDays) complete day of minute ENMO from raw motion "
                            + "(raw motion on all day; \(cosinorMinDays) days give the intended number); "
                            + "\(complete.filter { $0 }.count) complete day(s) in the last \(dayStarts.count)")
        }
        let start = dayStarts[best.start]
        let end = best.start + best.len < dayStarts.count ? dayStarts[best.start + best.len] : start + Int64(best.len) * 86_400
        let pts = enmoMinutes.filter { $0.key >= start && $0.key < end }
            .map { (t: Double(($0.key - start) / 60 + 1), y: $0.value) }.sorted { $0.t < $1.t }
        guard let fit = cosinor(pts) else { return .missing("the cosinor fit did not converge") }
        return .success(CosinorFit(mesor: fit.mesor, amplitude: fit.amplitude, acrophase: fit.acrophase, days: best.len))
    }

    // MARK: metrics

    public static let enmoSpec = MetricSpec(
        key: .enmo, unit: "mg", group: nil, variant: "ALG-113:enmo", method: "ALG-113@1 enmo-minute-mean", tier: .research,
        source: "r21", window: "day",
        citation: "van Hees VT et al. PLoS One 2013;8(4):e61691 (ENMO); scale 1/4096 g per count (noop Whoop5RawImu.swift "
            + "L51), checked against gravity per day",
        paramsVersion: "minute>=30s still<0.01g grav±5%")
    public static let asymSpec = MetricSpec(
        key: .imuAsym, unit: "index_0_1", group: "G-GAIT", variant: "ALG-114", method: "ALG-114@1 step-stride-regularity",
        tier: .research, source: "r21", window: "day",
        citation: "Moe-Nilssen R, Helbostad JL. J Biomech 2004;37(1):121-126 (trunk; here the wrist magnitude)",
        paramsVersion: "win10s sd0.03-0.5g ad2>=0.5 min6")

    /// The day's two raw-motion metrics from that day's stored seconds.
    public static func dayMetrics(_ seconds: [MotionSecond], at: Date) -> [Metric] {
        guard !seconds.isEmpty else {
            let why = "no raw motion recorded today (Strap & sync › Raw motion, or a session from the Live tab)"
            return [enmoSpec.blank(why, at: at), asymSpec.blank(why, at: at)]
        }
        let summaries = summarize(seconds)
        var out: [Metric] = []
        switch gravityCheck(summaries) {
        case .failure(let m):
            out.append(enmoSpec.blank(m.reason, at: at))
        case .success:
            let minutes = enmoMinutes(summaries)
            if minutes.count >= 5 {
                let mean = minutes.values.reduce(0) { $0 + $1.mg } / Double(minutes.count)
                out.append(enmoSpec.metric(.success(mean), at: at, coverage: Double(minutes.count) / 1440,
                                           note: "\(minutes.count) minute(s) of raw motion"))
            } else {
                out.append(enmoSpec.blank("needs ≥ 5 minutes of raw motion today (\(minutes.count) with ≥ 30 s)", at: at))
            }
        }
        switch gaitAsymmetry(seconds) {
        case .success(let a):
            out.append(asymSpec.metric(.success(a.value), at: at, note: "\(a.windows) walking window(s) of 10 s"))
        case .failure(let m):
            out.append(asymSpec.blank(m.reason, at: at))
        }
        return out
    }
}
