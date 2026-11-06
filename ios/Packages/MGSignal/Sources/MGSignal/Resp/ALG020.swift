import Foundation
import MGDomain

/// ALG-020 v1 — respiratory-rate framework: 64-s windows every 10 s, Smart Fusion of the estimators, span (night) and
/// hourly roll-ups. Tonight the only estimator is RSA from R-R (ALG-121); the three PPG modulations (amplitude,
/// baseline, frequency — Charlton 2016, Karlen 2013) are not built, so the FUSED rate is blank with "only 1 estimator
/// available" until they are — never the RSA value relabelled (ARCHITECTURE.md 8.1). Python reference:
/// app/pclab/mglab/ref/resp.py `fuse`, `resp_windows`, `resp_span`, `resp_hourly`; goldens
/// app/shared/golden/resp/ALG-020.json.
public enum ALG020 {
    public static let citation = "Charlton 2016 (benchmark); Karlen 2013 IEEE TBME (Smart Fusion)"
    public static let windowSeconds = 64.0
    public static let stepSeconds = 10.0
    /// Same beat-coverage rule as the HRV windows.
    public static let minCoverage = 0.8
    /// A beat-clock step this much longer than the beat itself is a dropout inside the window.
    public static let gapSlackSeconds = 0.5
    /// ALG-020: fuse only agreeing estimates, none if fewer than two agree.
    public static let fuseMinAgree = 2
    /// Karlen 2013 Smart Fusion: the window is discarded when the estimates' SD (ddof 1) exceeds 4 br/min.
    public static let fuseMaxSD = 4.0
    public static let hourSeconds: Int64 = 3600
    /// At least 5 min worth of 10-s windows before an hour gets a value (ours).
    public static let hourMinWindows = 30
    /// One minute of 10-s windows before a span gets a value (ours).
    public static let spanMinWindows = 6
    public static let ppgNotBuilt = "PPG modulations (amplitude, baseline, frequency) are not built yet (ALG-020 tonight: N)"

    /// The estimators ALG-020 fuses.
    public enum Estimator: String, Sendable, CaseIterable {
        case rsa = "rsa"
        case ppgAM = "ppg_am"
        case ppgBW = "ppg_bw"
        case ppgFM = "ppg_fm"
    }

    /// The hour's state for the hourly roll-up (supplied by the caller).
    public enum State: String, Sendable, CaseIterable {
        case asleep = "asleep"
        case awakeStill = "awake_still"
        case awakeActive = "awake_active"
        case workout = "workout"
        case unknown = "unknown"
    }

    /// ALG-020 v1 — Karlen 2013 Smart Fusion: the mean of the available estimates when ≥ 2 exist and their SD
    /// (ddof 1) ≤ 4 br/min; otherwise Missing. Order is kept (it only matters for the reason text).
    public static func fuse(_ estimates: [(Estimator, Computed<Double>)]) -> Computed<Double> {
        let have = estimates.compactMap { e -> (Estimator, Double)? in e.1.value.map { (e.0, $0) } }
        guard have.count >= fuseMinAgree else {
            let names = have.isEmpty ? "none" : have.map { $0.0.rawValue }.joined(separator: ", ")
            return .missing("only \(have.count) estimator available (\(names)); fusion needs at least "
                            + "\(fuseMinAgree) that agree")
        }
        let vals = have.map { $0.1 }
        let sd = SignalMath.sampleSD(vals)
        guard sd <= fuseMaxSD else {
            return .missing("estimators disagree (SD \(String(format: "%.1f", sd)) br/min > \(Int(fuseMaxSD)))")
        }
        return .success(SignalMath.mean(vals))
    }

    public struct Window: Sendable, Equatable {
        public var start: Int64
        public var beats: Int
        public var coverage: Double
        /// ALG-121 on this window's R-R.
        public var rsa: Computed<RespEstimate>
        /// ALG-020 fusion of every estimator.
        public var fused: Computed<Double>

        public init(start: Int64, beats: Int, coverage: Double, rsa: Computed<RespEstimate>, fused: Computed<Double>) {
            self.start = start
            self.beats = beats
            self.coverage = coverage
            self.rsa = rsa
            self.fused = fused
        }
    }

    /// ALG-020 v1 windows with the RSA input. R-R points → sorted (ts, ord) → beat clock → ALG-004 A (WP-08) → 64-s
    /// windows starting every 10 s on the clock (the first multiple of 10 s at or after the first beat, while
    /// start + 64 ≤ the last beat). A window holds beats with start ≤ t < start + 64 and is usable when coverage ≥ 0.8,
    /// ≥ 20 beats, no dropout inside it and ≤ 5 % corrected beats (ALG-004 B); then rsa = ALG-121 of its R-R.
    public static func windows(points: [RRPoint], core: any SignalCore = Signal.core) -> [Window] {
        let sorted = BeatClock.sorted(points)
        guard !sorted.isEmpty else { return [] }
        let art = ALG004.correct(rrMs: sorted.map(\.rrMs), times: BeatClock.times(points: sorted))
        let r = art.rrMs
        let f = art.flags
        let t = art.times
        guard let tFirst = t.first, let tLast = t.last else { return [] }
        var out: [Window] = []
        var start = (tFirst / stepSeconds).rounded(.up) * stepSeconds
        var lo = 0
        while start + windowSeconds <= tLast {
            while lo < t.count && t[lo] < start { lo += 1 }
            var hi = lo
            while hi < t.count && t[hi] < start + windowSeconds { hi += 1 }
            let rrW = Array(r[lo..<hi])
            var sum = 0.0
            for v in rrW { sum += v }
            let cov = min(1.0, sum / 1000.0 / windowSeconds)
            var gap = false
            if hi > lo + 1 {
                for i in (lo + 1)..<hi where t[i] - t[i - 1] - r[i] / 1000.0 > gapSlackSeconds {
                    gap = true
                    break
                }
            }
            let flagged = f[lo..<hi].filter { $0 != ArtefactFlag.ok.rawValue }.count
            let afrac = rrW.isEmpty ? 1.0 : Double(flagged) / Double(rrW.count)
            let rsa: Computed<RespEstimate>
            if rrW.count < ALG121.minBeats {
                rsa = .missing("needs at least \(ALG121.minBeats) beats in the window (have \(rrW.count))")
            } else if cov < minCoverage {
                rsa = .missing("beat coverage \(String(format: "%.2f", cov)) < \(minCoverage)")
            } else if gap {
                rsa = .missing("R-R dropout inside the window")
            } else if afrac > ALG004.windowMaxArtefactFraction {
                rsa = .missing("\(Int((100 * afrac).rounded())) % corrected beats (> 5 %, ALG-004 B)")
            } else if core.implementation == .swift {
                rsa = ALG121.estimate(rrMs: rrW)
            } else if let e = core.respFromRR(rrMs: rrW) {
                rsa = .success(e)
            } else {
                rsa = .missing("no clear breathing peak (\(core.implementation.rawValue) core)")
            }
            let notBuilt: Computed<Double> = .missing(ppgNotBuilt)
            let fused = fuse([(.rsa, rsa.map(\.brPerMin)), (.ppgAM, notBuilt), (.ppgBW, notBuilt), (.ppgFM, notBuilt)])
            out.append(Window(start: Int64(start), beats: rrW.count, coverage: cov, rsa: rsa, fused: fused))
            start += stepSeconds
        }
        return out
    }

    public struct Summary: Sendable, Equatable {
        public var median: Double
        public var q25: Double
        public var q75: Double
        /// Usable windows.
        public var windows: Int
        /// Usable windows / possible windows.
        public var coverage: Double

        public init(median: Double, q25: Double, q75: Double, windows: Int, coverage: Double) {
            self.median = median
            self.q25 = q25
            self.q75 = q75
            self.windows = windows
            self.coverage = coverage
        }
    }

    static func summary(_ values: [Double], possible: Int, minWindows: Int, label: String) -> Computed<Summary> {
        guard values.count >= minWindows else {
            return .missing("\(label): needs \(minWindows) usable windows (have \(values.count))")
        }
        let s = values.sorted()
        return .success(Summary(median: SignalMath.quantileSorted(s, 0.5), q25: SignalMath.quantileSorted(s, 0.25),
                                q75: SignalMath.quantileSorted(s, 0.75), windows: values.count,
                                coverage: possible > 0 ? Double(values.count) / Double(possible) : 0.0))
    }

    public struct Span: Sendable, Equatable {
        /// ALG-121 member of G-RESP.
        public var rsa: Computed<Summary>
        /// ALG-020 member (blank while only one estimator exists).
        public var fused: Computed<Summary>

        public init(rsa: Computed<Summary>, fused: Computed<Summary>) {
            self.rsa = rsa
            self.fused = fused
        }
    }

    /// ALG-020 / ALG-121 v1 span value (night or any period): per member, median, type-7 IQR, usable windows and
    /// coverage (usable / all windows). Needs 6 usable windows.
    public static func span(_ windows: [Window]) -> Span {
        let rsa = windows.compactMap { $0.rsa.value?.brPerMin }
        let fused = windows.compactMap { $0.fused.value }
        let rsaS = summary(rsa, possible: windows.count, minWindows: spanMinWindows, label: "RSA")
        let fusedS: Computed<Summary>
        if fused.isEmpty, let first = windows.first {
            fusedS = .missing(first.fused.missingReason ?? "no fused value")
        } else {
            fusedS = summary(fused, possible: windows.count, minWindows: spanMinWindows, label: "fusion")
        }
        return Span(rsa: rsaS, fused: fusedS)
    }

    public struct Hour: Sendable, Equatable {
        /// Unix seconds of the clock hour (floor(start / 3600) · 3600).
        public var hourStart: Int64
        public var state: State
        public var rsa: Computed<Summary>
        public var fused: Computed<Summary>

        public init(hourStart: Int64, state: State, rsa: Computed<Summary>, fused: Computed<Summary>) {
            self.hourStart = hourStart
            self.state = state
            self.rsa = rsa
            self.fused = fused
        }
    }

    /// ALG-020 v1 hourly roll-up (`resp_rate_hourly`): windows grouped by the clock hour of their start; per member
    /// median, IQR, usable windows, coverage = usable / 360 possible 10-s windows, and the hour's state (default
    /// unknown). An hour needs 30 usable windows. Workout hours: RSA withheld (workout mode needs ≥ 2 agreeing
    /// estimators).
    public static func hourly(_ windows: [Window], stateByHour: [Int64: State] = [:]) -> [Hour] {
        var order: [Int64] = []
        var byHour: [Int64: [Window]] = [:]
        for w in windows {
            let h = w.start / hourSeconds * hourSeconds
            if byHour[h] == nil {
                byHour[h] = []
                order.append(h)
            }
            byHour[h]!.append(w)
        }
        let possible = Int(Double(hourSeconds) / stepSeconds)
        return order.sorted().map { h -> Hour in
            let ws = byHour[h]!
            let state = stateByHour[h] ?? .unknown
            let rsa: Computed<Summary> = state == .workout
                ? .missing("workout: breathing rate needs at least 2 agreeing estimators (ALG-020 workout mode)")
                : summary(ws.compactMap { $0.rsa.value?.brPerMin }, possible: possible, minWindows: hourMinWindows,
                          label: "RSA")
            let fv = ws.compactMap { $0.fused.value }
            let fused: Computed<Summary> = fv.isEmpty
                ? .missing(ws[0].fused.missingReason ?? "no fused value")
                : summary(fv, possible: possible, minWindows: hourMinWindows, label: "fusion")
            return Hour(hourStart: h, state: state, rsa: rsa, fused: fused)
        }
    }

    // MARK: metrics (registry resp_rate: br_min, G-RESP, variants ALG-020 · ALG-121 · MS-07)

    public static let rsaSpec = MetricSpec(
        key: .respRate, unit: "br_min", group: "G-RESP", variant: "ALG-121", method: "ALG-121@1 rsa-lomb-scargle-hf",
        tier: .estimate, source: "rr", window: "night", citation: ALG121.citation,
        paramsVersion: "w64 s10 hf0.15-0.40 q0.4 min6windows")
    public static let fusedSpec = MetricSpec(
        key: .respRate, unit: "br_min", group: "G-RESP", variant: "ALG-020", method: "ALG-020@1 smart-fusion",
        tier: .estimate, source: "rr+ppg", window: "night", citation: citation,
        paramsVersion: "w64 s10 agree2 sd4 min6windows")

    /// Both G-RESP members for a span (ALG-020 blank with its reason until a second estimator exists).
    public static func metrics(_ s: Span, at: Date) -> [Metric] {
        [rsaSpec.metric(s.rsa.map(\.median), at: at, coverage: s.rsa.value?.coverage),
         fusedSpec.metric(s.fused.map(\.median), at: at, coverage: s.fused.value?.coverage)]
    }
}
