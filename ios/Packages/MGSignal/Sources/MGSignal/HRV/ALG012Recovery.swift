import Foundation
import MGDomain

/// ALG-012 HR recovery v1 — the heart-rate drop 60 s and 120 s after a defined effort end (a logged workout's end) and
/// the time constant τ of a single exponential on the tail. Python reference: app/pclab/mglab/ref/screens.py `hr_recovery`;
/// goldens app/shared/golden/hrv/ALG-012-tau.json.
///
/// Effort gate from whoop-rs physio-algo hr_recovery.rs @ d11d8ef (≥ 120 s of contiguous samples at ≥ 70 % HRmax in the
/// 5 min before the end). Then OpenStrap/analytics workout/hr_recovery.dart @ 458ba36 on the clock: peak = highest on-skin
/// HR in the 30 s before the end; HR at +60 s = median within ±3 s of the sample nearest +60 s (Cole 1999 measures the
/// drop at 1 min); τ = grid fit 5…200 s of HR = a + b·e^(−t/τ) on the 0–180 s tail (≥ 90 s of it), refused when rising,
/// on a grid edge, or with an RMSE above 15 % of the amplitude. Compare τ only between recoveries that started from a
/// similar HR (the start HR goes in the note).
///
/// Honest limits (Mo's D-RECOV-WALK-2, Oct 17 2026): Imai 1994 fitted T30 on beat-by-beat ECG over the first 30 s;
/// ours is wrist 1 Hz HR over a 180 s tail, so τ is a research-tier estimate, compared only within the same workout
/// type. Al Haddad 2011: HRR60 measurement error is large after submaximal exercise (SEM 26.7 %, HRR120 19.5 %), so the
/// app shows the change against your own baseline for that workout type only when it has enough workouts (see
/// MGContext `HRRBaseline`). The day-level "wind-down to resting" readout (ours, T34) was removed: it had no source.
public enum ALG012Recovery {
    public static let citation = "Cole CR et al. NEJM 1999;341:1351-7; Imai H et al. JACC 1994;24:1529-35 (T30, "
        + "beat-by-beat ECG, 30 s: ours is wrist 1 Hz HR over 180 s, a research estimate); Al Haddad H et al. "
        + "IJSPP 2011 (HRR60 SEM 26.7 % after submaximal exercise); OpenStrap hr_recovery.dart @ 458ba36; "
        + "whoop-rs hr_recovery.rs @ d11d8ef (effort gate)"
    public static let recoveryS: Int64 = 60
    public static let recovery2S: Int64 = 120
    public static let peakWindowS: Int64 = 30
    public static let maxGapS: Int64 = 30
    public static let medianHalfS: Int64 = 3
    public static let tauWindowS: Int64 = 180
    public static let tauMin = 5
    public static let tauMax = 200
    public static let tauMinPoints = 30
    public static let tauMaxResidual = 0.15
    public static let eligibilityFraction = 0.70
    public static let eligibilityMinS: Int64 = 120
    public static let eligibilityLookbackS: Int64 = 300
    public static let eligibilityMaxGapS: Int64 = 10

    public struct Tau: Sendable, Equatable {
        public var tau: Double
        public var startHR: Double
        public var amplitude: Double
        public var asymptote: Double
        public var residualRatio: Double

        public init(tau: Double, startHR: Double, amplitude: Double, asymptote: Double, residualRatio: Double) {
            self.tau = tau
            self.startHR = startHR
            self.amplitude = amplitude
            self.asymptote = asymptote
            self.residualRatio = residualRatio
        }
    }

    public struct Recovery: Sendable, Equatable {
        /// Peak minus HR at +60 s, bpm.
        public var hrr60: Double
        public var peak: Double
        public var hr60: Double
        public var tau: Computed<Tau>
        /// Peak minus HR at +120 s (same rules as the 60 s one, ±3 s); missing with the reason when the data end first.
        public var hrr120: Computed<Double>

        public init(hrr60: Double, peak: Double, hr60: Double, tau: Computed<Tau>,
                    hrr120: Computed<Double> = .missing("HR at +120 s not computed")) {
            self.hrr60 = hrr60
            self.peak = peak
            self.hr60 = hr60
            self.tau = tau
            self.hrr120 = hrr120
        }
    }

    /// OpenStrap `_fitTau`.
    static func fitTau(_ tt: [Double], _ yy: [Double]) -> Computed<Tau> {
        let m = tt.count
        guard m >= tauMinPoints else { return .missing("tau needs \(tauMinPoints) HR samples in the tail (have \(m))") }
        var best: (sse: Double, tau: Double, a: Double, b: Double)?
        for ti in tauMin...tauMax {
            let tau = Double(ti)
            var se = 0.0
            var see = 0.0
            var sy = 0.0
            var sey = 0.0
            for i in 0..<m {
                let e = exp(-tt[i] / tau)
                se += e
                see += e * e
                sy += yy[i]
                sey += e * yy[i]
            }
            let den = Double(m) * see - se * se
            if abs(den) < 1e-12 { continue }
            let b = (Double(m) * sey - se * sy) / den
            let a = (sy - b * se) / Double(m)
            var sse = 0.0
            for i in 0..<m {
                let r = yy[i] - (a + b * exp(-tt[i] / tau))
                sse += r * r
            }
            if best == nil || sse < best!.sse { best = (sse, tau, a, b) }
        }
        guard let b = best else { return .missing("tau fit had no usable grid point") }
        guard b.b > 0 else { return .missing("HR did not decay after the effort (tau fit rising)") }
        guard b.tau > Double(tauMin) && b.tau < Double(tauMax) else {
            return .missing("tau sits on the grid edge (\(Int(b.tau)) s): the tail does not constrain it")
        }
        let ratio = (b.sse / Double(m)).squareRoot() / b.b
        guard ratio.isFinite, ratio <= tauMaxResidual else {
            return .missing("tau fit residual \(String(format: "%.2f", ratio)) of the amplitude (limit \(tauMaxResidual))")
        }
        return .success(Tau(tau: b.tau, startHR: b.a + b.b, amplitude: b.b, asymptote: b.a, residualRatio: ratio))
    }

    /// whoop-rs `sustained_seconds` over [end − 300, end] (bpm 30…250, gaps 1…10 s, at or above 70 % HRmax).
    static func sustainedSeconds(ts: [Int64], bpm: [Double], endTs: Int64, hrmax: Double) -> Int64 {
        var pts: [(Int64, Double)] = []
        for i in 0..<min(ts.count, bpm.count)
        where ts[i] >= endTs - eligibilityLookbackS && ts[i] <= endTs && bpm[i] >= 30 && bpm[i] <= 250 {
            pts.append((ts[i], bpm[i]))
        }
        pts.sort { $0 < $1 }
        let thr = hrmax * eligibilityFraction
        var s: Int64 = 0
        if pts.count >= 2 {
            for i in 0..<(pts.count - 1) {
                let gap = pts[i + 1].0 - pts[i].0
                if gap >= 1 && gap <= eligibilityMaxGapS && pts[i].1 >= thr { s += gap }
            }
        }
        return s
    }

    /// HR recovery after the effort that ended at `endTs`. HR ≤ 0 is off-skin.
    public static func recovery(ts tsIn: [Int64], bpm bpmIn: [Double], endTs: Int64, hrmax: Double?) -> Computed<Recovery> {
        guard let hrmax, hrmax.isFinite, hrmax > 0 else {
            return .missing("needs HRmax for the effort gate (whoop-rs: 120 s at 70 % HRmax)")
        }
        var pairs: [(Int64, Double)] = []
        for i in 0..<min(tsIn.count, bpmIn.count) where bpmIn[i].isFinite { pairs.append((tsIn[i], bpmIn[i])) }
        pairs.sort { $0 < $1 }
        guard !pairs.isEmpty else { return .missing("no heart rate around the workout end") }
        let t = pairs.map(\.0)
        let h = pairs.map(\.1)
        let sus = sustainedSeconds(ts: t, bpm: h, endTs: endTs, hrmax: hrmax)
        guard sus >= eligibilityMinS else {
            return .missing("not a sustained effort: \(sus) s at >= 70 % HRmax in the last 5 min (needs \(eligibilityMinS) s)")
        }
        guard let end = t.lastIndex(where: { $0 <= endTs }) else { return .missing("no heart rate before the workout end") }
        var i = end
        while i > 0 && t[end] - t[i - 1] <= peakWindowS && t[i] - t[i - 1] <= maxGapS { i -= 1 }
        var peak = 0.0
        for k in i...end where h[k] > 0 && h[k] > peak { peak = h[k] }
        guard peak > 0 else { return .missing("off-skin or missing HR around the recovery point") }
        let hr60: Double
        switch hrAfter(t, h, end: end, offset: recoveryS) {
        case .failure(let m): return .missing(m.reason)
        case .success(let v): hr60 = v
        }
        let drop = peak - hr60
        guard drop > 0 else { return .missing("HR did not fall in the minute after the end: probably still moving") }
        var tt: [Double] = []
        var yy: [Double] = []
        var j = end
        while j < t.count {
            if j > end && t[j] - t[j - 1] > maxGapS { break }
            let dt = t[j] - t[end]
            if dt > tauWindowS { break }
            if h[j] > 0 {
                tt.append(Double(dt))
                yy.append(h[j])
            }
            j += 1
        }
        let tau: Computed<Tau>
        if tt.isEmpty || tt[tt.count - 1] < Double(tauWindowS) / 2 {
            tau = .missing("tau needs \(tauWindowS / 2) s of HR after the end (have \(tt.last.map { Int($0) } ?? 0) s)")
        } else {
            tau = fitTau(tt, yy)
        }
        let hrr120: Computed<Double> = hrAfter(t, h, end: end, offset: recovery2S).flatMap { (hr120: Double) -> Computed<Double> in
            peak - hr120 > 0 ? Computed<Double>.success(peak - hr120) : Computed<Double>.missing("HR at +120 s is not below the peak: probably moving again")
        }
        return .success(Recovery(hrr60: drop, peak: peak, hr60: hr60, tau: tau, hrr120: hrr120))
    }

    /// HR `offset` s after the sample at `end`: the median of the on-skin samples within ±3 s of the sample nearest it
    /// (refused if none lies within 3 s, or a hole over 30 s comes first). Same rule for +60 s and +120 s.
    static func hrAfter(_ t: [Int64], _ h: [Double], end: Int, offset: Int64) -> Computed<Double> {
        let want = t[end] + offset
        var tgt = end
        var k = end
        while k < t.count {
            if k > end && t[k] - t[k - 1] > maxGapS { break }
            tgt = k
            if t[k] >= want { break }
            k += 1
        }
        if tgt > end && want - t[tgt - 1] < t[tgt] - want { tgt -= 1 }
        guard abs(t[tgt] - want) <= medianHalfS else {
            let early = t[tgt] < want ? " (the data end or stop \(t[tgt] - t[end]) s after the end)" : ""
            return .missing("no HR sample within \(medianHalfS) s of +\(offset) s after the end\(early)")
        }
        var lo = tgt
        while lo > 0 && t[tgt] - t[lo - 1] <= medianHalfS { lo -= 1 }
        var hi = tgt
        while hi + 1 < t.count && t[hi + 1] - t[tgt] <= medianHalfS { hi += 1 }
        let rec = (lo...hi).compactMap { h[$0] > 0 ? h[$0] : nil }
        guard !rec.isEmpty else { return .missing("off-skin or missing HR around the recovery point") }
        return .success(SignalMath.median(rec))
    }

    public static func recovery(_ points: [HRPoint], endTs: Int64, hrmax: Double?) -> Computed<Recovery> {
        recovery(ts: points.map(\.ts), bpm: points.map(\.bpm), endTs: endTs, hrmax: hrmax)
    }

    public static let hrr60Spec = MetricSpec(
        key: .hrRecovery60, unit: "bpm", group: nil, variant: "ALG-012", method: "ALG-012@1 hrr60-after-workout",
        tier: .estimate, source: "hr", window: "workout", citation: citation, paramsVersion: "peak30s med+-3s gate70%x120s")
    public static let tauSpec = MetricSpec(
        key: .hrRecoveryTau, unit: "s", group: nil, variant: "ALG-012", method: "ALG-012@1 tau-single-exponential",
        tier: .research, source: "hr", window: "workout", citation: citation, paramsVersion: "grid5-200s tail180s resid0.15")
    public static let hrr120Spec = MetricSpec(
        key: .hrRecovery120, unit: "bpm", group: nil, variant: "ALG-012", method: "ALG-012@1 hrr120-after-workout",
        tier: .estimate, source: "hr", window: "workout", citation: citation, paramsVersion: "peak30s med+-3s gate70%x120s")
}
