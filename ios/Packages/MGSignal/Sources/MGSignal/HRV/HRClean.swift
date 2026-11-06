import Foundation
import MGDomain

/// HR-CLEAN v1 — the one shared cleaning step for the strap's 1 Hz heart rate (P200, Mo 2026-10-15: "pick the methods you
/// think is best for hr cleaning for now; I'll review and change later"). Used by resting HR (ALG-012), strain / TRIMP
/// (ALG-036), calories (ALG-048), the HR minute grid ALG-120 reads, and every algorithm built on those. Order:
///   1. range      30…220 bpm (the old path kept 0 < bpm ≤ 250; HR 0 stays "off skin" and is dropped first).
///   2. spikes     Hampel filter (Davies & Gather 1993; Pearson 2005): a second is dropped when it sits more than
///                 `madK` scaled MADs (1.4826·MAD) from the median of the seconds within ±`hampelHalfWindowS`
///                 (11 s window, 3 MAD). A floor on the scale (`minScaleBpm`) stops a flat stretch (MAD 0) from
///                 rejecting every 1-bpm wiggle. Dropped, never replaced: no invented values (a blank is a blank).
///   3. motion     (`requireStill` only: resting HR) drop seconds whose R18 activity class is not 0 (still) — the same
///                 still test the daytime-stress gate uses (`ALG054.stillPoints`, `ALG123Daytime`).
///   4. quality    drop seconds the strap's R18 optical-quality fields mark bad: the saturation flag, and (only when
///                 `psnrMinDb` is set) either pSNR channel below it. The pSNR floor is a PARAMETER, default off: no
///                 validated threshold exists in this repo (decoded, untested), so none is invented.
/// Task Force 1996 and Kubios (Tarvainen 2014, artefact correction by thresholds) treat beats the same way: detect
/// outliers against a local median, remove, do not interpolate silently. The old path is kept as `.raw`.
public enum HRClean {
    /// The method key a PC / primary map (T9809) can select per metric; `tag` is what a metric's method string carries.
    public enum Method: String, Sendable, CaseIterable {
        /// ALG-xxx@1 behaviour: every algorithm's own 0 < bpm ≤ 250 check, nothing else.
        case raw = "raw-1hz"
        /// HR-CLEAN@1: range + Hampel + (motion) + quality.
        case hampel = "hr-clean@1"
    }

    public struct Params: Sendable, Equatable {
        public var minBpm = 30.0
        public var maxBpm = 220.0
        public var hampelHalfWindowS: Int64 = 5
        public var madK = 3.0
        public var minScaleBpm = 1.0
        public var minNeighbours = 5
        public var stillClass = 0
        public var psnrMinDb: Int? = nil
        public init() {}
    }

    public struct Result: Sendable, Equatable {
        public var keep: [Bool]
        public var droppedRange = 0
        public var droppedSpike = 0
        public var droppedMotion = 0
        public var droppedQuality = 0
        /// False when `requireStill` was asked but no R18 activity class covered the seconds: the gate did not run.
        public var motionGateApplied = true
    }

    /// Keep mask over parallel 1 Hz arrays (ts ascending or not: sorted internally by index order of `ts`).
    /// `activityClass` / `quality` may be empty (gate skipped, reported) or the same length as `ts`.
    public static func mask(ts: [Int64], bpm: [Double?], activityClass: [Int?] = [], quality: [R18Quality?] = [],
                            requireStill: Bool = false, params p: Params = Params()) -> Result {
        let n = ts.count
        var r = Result(keep: [Bool](repeating: true, count: n))
        var ok = [Bool](repeating: false, count: n)
        for i in 0..<n {
            if let b = bpm[i], b.isFinite, b > 0, b >= p.minBpm, b <= p.maxBpm { ok[i] = true } else { r.droppedRange += 1 }
        }
        // Hampel over the range-valid seconds, in time order, window by timestamp.
        let order = (0..<n).filter { ok[$0] }.sorted { ts[$0] < ts[$1] }
        var lo = 0
        var hi = 0
        for k in 0..<order.count {
            let t = ts[order[k]]
            while ts[order[lo]] < t - p.hampelHalfWindowS { lo += 1 }
            while hi < order.count && ts[order[hi]] <= t + p.hampelHalfWindowS { hi += 1 }
            var win: [Double] = []
            for j in lo..<hi where j != k { win.append(bpm[order[j]]!) }   // neighbours only: the second under test must not vote
            guard win.count >= p.minNeighbours else { continue }
            let med = SignalMath.median(win)
            let scale = max(1.4826 * SignalMath.median(win.map { abs($0 - med) }), p.minScaleBpm)
            if abs(bpm[order[k]]! - med) > p.madK * scale {
                ok[order[k]] = false
                r.droppedSpike += 1
            }
        }
        let haveAct = activityClass.count == n && n > 0
        if requireStill && !haveAct { r.motionGateApplied = false }
        for i in 0..<n where ok[i] {
            if requireStill && haveAct, activityClass[i] != p.stillClass { ok[i] = false; r.droppedMotion += 1; continue }
            if quality.count == n, let q = quality[i] {
                var bad = q.saturated
                if let floor = p.psnrMinDb {
                    if let a = q.psnrA, a < floor { bad = true }
                    if let b = q.psnrB, b < floor { bad = true }
                }
                if bad { ok[i] = false; r.droppedQuality += 1 }
            }
        }
        r.keep = ok
        return r
    }

    /// HR points cleaned against the strap's R18 rows of the same seconds. `.raw` returns the points untouched.
    public static func apply(_ hr: [HRPoint], r18: [R18Second], method: Method, requireStill: Bool = false,
                             params: Params = Params()) -> [HRPoint] {
        guard method == .hampel, !hr.isEmpty else { return hr }
        var act: [Int64: Int?] = [:]
        var qual: [Int64: R18Quality?] = [:]
        for s in r18 { act[s.ts] = s.activityClass; qual[s.ts] = s.quality }
        let acts: [Int?] = requireStill && !act.isEmpty ? hr.map { act[$0.ts] ?? nil } : []
        let quals: [R18Quality?] = qual.isEmpty ? [] : hr.map { qual[$0.ts] ?? nil }
        let m = mask(ts: hr.map(\.ts), bpm: hr.map { Optional($0.bpm) }, activityClass: acts, quality: quals,
                     requireStill: requireStill, params: params)
        return zip(hr, m.keep).compactMap { $1 ? $0 : nil }
    }

    /// The metric method string for a spec that reads cleaned HR: "ALG-012@1 x" becomes "ALG-012@2 x + hr-clean@1".
    public static func tag(_ spec: MetricSpec, _ method: Method) -> MetricSpec {
        guard method == .hampel, let at = spec.method.firstIndex(of: "@") else { return spec }
        var s = spec
        let rest = spec.method[spec.method.index(after: at)...]
        let digits = rest.prefix { $0.isNumber }
        if let v = Int(digits) { s.method = String(spec.method[...at]) + String(v + 1) + rest.dropFirst(digits.count) + " + hr-clean@1" }
        return s
    }
}
