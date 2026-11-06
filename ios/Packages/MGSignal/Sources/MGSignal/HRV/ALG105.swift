import Foundation
import MGDomain

/// ALG-105 v2 — live stress onset: a held, edge-triggered HRV dip, exercise-gated (G-STRESS). Python reference:
/// app/pclab/mglab/ref/screens.py `onset_evaluate`, `onset_replay`, `clean_rr`; goldens app/shared/golden/hrv/ALG-105.json.
///
/// Port of whoop-rs physio-algo stress_onset.rs @ d11d8ef: R-R cleaned (300–2000 ms, then a beat > 20 % from the median
/// of its ±2 neighbours dropped), fast RMSSD over the last 60 clean beats (≥ 20), baseline = EMA α 0.98 folded BEFORE the
/// compare (seeded by the first reading), a dip = fast < 0.6 × baseline, held for 60 s before firing once,
/// HR 55–100 bpm inclusive and not moving, at most once per 900 s. whoop-rs gates motion on dynamic acceleration
/// ≥ 0.15 g, which needs the 100 Hz IMU: here the strap's activity class ≥ 1 in the last 60 s stands in (ours v0).
///
/// `replay` runs the detector over a stored day's waking spans (one evaluation every 30 s, R-R of the last 120 s, mean
/// HR of the last 30 s, a fresh state each day; ours v0) so the onsets are counted from Mo's data. The live nudge (strap
/// buzz + notification, APP-026) is not wired: nothing evaluates the live stream yet.
public enum ALG105 {
    public static let citation = "whoop-rs physio-algo stress_onset.rs @ d11d8ef (JITAI stress onset)"
    public static let emaAlpha = 0.98
    public static let dropRatio = 0.6
    public static let fastBeats = 60
    public static let minBeats = 20
    public static let hrLow = 55.0
    public static let hrHigh = 100.0
    public static let refractoryS: Int64 = 900
    public static let holdS: Int64 = 60
    public static let rrMin = 300.0
    public static let rrMax = 2000.0
    public static let ectopic = 0.20
    public static let radius = 2
    public static let stepS: Int64 = 30
    public static let bufferS: Int64 = 120
    public static let hrS: Int64 = 30
    public static let motionS: Int64 = 60

    public struct State: Sendable, Equatable {
        public var baseline: Double
        public var wasBelow: Bool
        public var lastFire: Int64
        public var belowSince: Int64?
        public var firedBelow: Bool

        public init(baseline: Double = 0, wasBelow: Bool = false, lastFire: Int64 = 0, belowSince: Int64? = nil,
                    firedBelow: Bool = false) {
            self.baseline = baseline
            self.wasBelow = wasBelow
            self.lastFire = lastFire
            self.belowSince = belowSince
            self.firedBelow = firedBelow
        }
    }

    public enum Reason: String, Sendable {
        case onset = "onset"
        case holding = "holding"
        case insufficientData = "insufficient_data"
        case noDip = "no_dip"
        case notAnEdge = "not_an_edge"
        case exerciseGated = "exercise_gated"
        case suppressed = "suppressed"
    }

    public struct Decision: Sendable, Equatable {
        public var reason: Reason
        public var fast: Double?
        public var baseline: Double?
        public var state: State
    }

    /// whoop-rs `HrvReadiness::clean_rr`.
    public static func cleanRR(_ rr: [Double]) -> [Double] {
        let ranged = rr.filter { $0 >= rrMin && $0 <= rrMax }
        if ranged.count <= radius { return ranged }
        var out: [Double] = []
        for i in 0..<ranged.count {
            let lo = max(0, i - radius)
            let hi = min(ranged.count - 1, i + radius)
            var nb: [Double] = []
            for j in lo...hi where j != i { nb.append(ranged[j]) }
            if nb.count < 2 {
                out.append(ranged[i])
                continue
            }
            let med = SignalMath.median(nb)
            if med <= 0 || abs(ranged[i] - med) / med <= ectopic { out.append(ranged[i]) }
        }
        return out
    }

    static func rmssdPlain(_ rr: [Double]) -> Double? {
        guard rr.count >= 2 else { return nil }
        var s = 0.0
        for i in 1..<rr.count {
            let d = rr[i] - rr[i - 1]
            s += d * d
        }
        return (s / Double(rr.count - 1)).squareRoot()
    }

    /// whoop-rs `evaluate` with the detector on, auto-nudge on, no session and no quiet hours.
    public static func evaluate(rrBuffer: [Double], hr: Double?, moving: Bool, state: State, now: Int64) -> Decision {
        let clean = cleanRR(rrBuffer)
        let fastW = clean.count > fastBeats ? Array(clean.suffix(fastBeats)) : clean
        guard fastW.count >= minBeats, let fast = rmssdPlain(fastW) else {
            var next = state
            next.wasBelow = false
            next.belowSince = nil
            next.firedBelow = false
            return Decision(reason: .insufficientData, fast: nil, baseline: state.baseline > 0 ? state.baseline : nil,
                            state: next)
        }
        let base = state.baseline == 0 ? fast : state.baseline * emaAlpha + fast * (1.0 - emaAlpha)
        var next = state
        next.baseline = base
        let below = fast < base * dropRatio
        let edge = below && !state.wasBelow
        next.wasBelow = below
        func out(_ r: Reason) -> Decision { Decision(reason: r, fast: fast, baseline: base, state: next) }
        if !below {
            next.belowSince = nil
            next.firedBelow = false
            return out(.noDip)
        }
        if state.firedBelow { return out(.notAnEdge) }
        guard let hr, hr >= hrLow, hr <= hrHigh, !moving else {
            next.belowSince = nil
            return out(.exerciseGated)
        }
        if edge || state.belowSince == nil { next.belowSince = now }
        let since = next.belowSince ?? now
        if now - since < holdS { return out(.holding) }
        if state.lastFire != 0 && now - state.lastFire < refractoryS {
            next.firedBelow = true
            return out(.suppressed)
        }
        next.lastFire = now
        next.firedBelow = true
        return out(.onset)
    }

    public struct Replay: Sendable, Equatable {
        public var onsets: [Int64]
        public var evaluations: Int
    }

    /// First index with a[i] > x (Python bisect_right) on a sorted array.
    static func upperBound(_ a: [Int64], _ x: Int64) -> Int {
        var lo = 0
        var hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The detector replayed over `spans` ([start, end) unix s, waking only). `movingTs` = seconds with activity class ≥ 1.
    public static func replay(rrTs: [Int64], rrMs: [Double], hrTs: [Int64], hrBpm: [Double], movingTs: [Int64],
                              spans: [(Double, Double)]) -> Computed<Replay> {
        let n = min(rrTs.count, rrMs.count)
        let order = (0..<n).sorted { rrTs[$0] != rrTs[$1] ? rrTs[$0] < rrTs[$1] : $0 < $1 }
        let rt = order.map { rrTs[$0] }
        let rv = order.map { rrMs[$0] }
        var hp: [(Int64, Double)] = []
        for i in 0..<min(hrTs.count, hrBpm.count) where hrBpm[i].isFinite && hrBpm[i] > 0 { hp.append((hrTs[i], hrBpm[i])) }
        hp.sort { $0 < $1 }
        let hpT = hp.map(\.0)
        let mv = movingTs.sorted()
        var state = State()
        var onsets: [Int64] = []
        var evaluated = 0
        for (a, b) in spans {
            state.wasBelow = false
            state.belowSince = nil
            state.firedBelow = false
            var tick = Int64(a.rounded(.down)) + stepS
            while Double(tick) <= b {
                let buf = Array(rv[upperBound(rt, tick - bufferS)..<upperBound(rt, tick)])
                let hs = hp[upperBound(hpT, tick - hrS)..<upperBound(hpT, tick)].map(\.1)
                let hr: Double? = hs.isEmpty ? nil : SignalMath.mean(Array(hs))
                let moving = upperBound(mv, tick) > upperBound(mv, tick - motionS)
                let d = evaluate(rrBuffer: buf, hr: hr, moving: moving, state: state, now: tick)
                state = d.state
                if d.reason != .insufficientData { evaluated += 1 }
                if d.reason == .onset { onsets.append(tick) }
                tick += stepS
            }
        }
        guard evaluated > 0 else { return .missing("no waking 2-min stretch with 20 clean beats") }
        return .success(Replay(onsets: onsets, evaluations: evaluated))
    }

    public static let spec = MetricSpec(
        key: .stressOnsets, unit: "count", group: "G-STRESS", variant: "ALG-105", method: "ALG-105@2 whoop-rs-onset-replay",
        tier: .estimate, source: "rr,hr,r18", window: "day", citation: citation,
        paramsVersion: "fast60 ema0.98 drop0.6 hold60s hr55-100 refr900 step30 buf120")
}
