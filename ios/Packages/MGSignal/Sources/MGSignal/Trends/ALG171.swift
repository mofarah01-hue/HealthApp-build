import Foundation
import MGDomain

/// ALG-171 v1 — heart-rate rise at a rest-to-walk onset, the base-tier input of the orthostatic-response trend (ALG-170).
/// Python reference: pclab/mglab/ref/trends.py `stand_events`, `stand_day`; goldens shared/golden/trends/ALG-171.json.
///
/// Method (theory + paper): on standing, blood pools in the legs and the baroreflex raises heart rate within seconds; the
/// clinical active-stand test reads the rise over minutes and calls a sustained rise of 30 bpm or more within 10 minutes of
/// standing the postural-tachycardia criterion (Freeman et al., Clin Auton Res 2011;21:69-72, abstract checked 2026-10-17).
/// A wrist strap cannot see posture, so the "stand" here is detected from MOVEMENT: ≥ 5 minutes of stillness (R18 activity
/// class 0, ≥ 98 %), then 30 s that are walking (class 1, ≥ 80 %, no running). That is a lie/sit-to-walk transition, NOT the
/// clinical test, and its rise (about the first half-minute, walking itself adds to it) is a different number from the 10-minute
/// one: it is only compared with Mo's own earlier days, with no population value (ALG-170 `ownOnly`).
/// Rise = highest 5-s median HR from 5 to 28 s after the onset minus the median of the 60 s before (baseline ≤ 100 bpm,
/// range ≤ 15 bpm, ≥ 54 of 60 s present). A day's value is the median of its valid onsets, needing at least 2.
/// BASE tier (R18 activity class + 1 Hz HR). ENHANCED tier (R21 100 Hz motion for a sharper onset) is not available to the
/// night run, which does not load R21: the trend is labelled base.
public enum ALG171 {
    public static let id = "ALG-171"
    public static let citation = "Freeman et al. 2011 (clinical stand test); onset rule and thresholds ours"
    public static let preSeconds = 300
    public static let preStillMin = 294
    public static let postSeconds = 30
    public static let postWalkMin = 24
    public static let hrBaseSeconds = 60
    public static let hrBaseMin = 54
    public static let hrBaseRange = 15.0
    public static let hrBaseMax = 100.0
    public static let peakFrom = 5
    public static let peakTo = 28
    public static let peakHalf = 2
    public static let peakMinCentres = 12
    public static let gapSeconds: Int64 = 330
    public static let minEvents = 2
    public static let seriesName = "orthostatic_rise"

    public struct Event: Sendable, Equatable {
        public var t0: Int64
        public var baseline: Double
        public var peak: Double
        public var rise: Double
    }

    /// `act`: activity class by second (0 still, 1 walk, 2 run, other invalid); `hr`: bpm by second.
    public static func events(act: [Int64: Int], hr: [Int64: Double]) -> [Event] {
        var out: [Event] = []
        var nextOK = Int64.min
        for t0 in act.keys.sorted() {
            if t0 < nextOK || act[t0] != 1 || act[t0 - 1] != 0 { continue }
            var still = 0
            for t in (t0 - Int64(preSeconds))..<t0 where act[t] == 0 { still += 1 }
            if still < preStillMin { continue }
            var walk = 0
            var run = false
            for t in t0..<(t0 + Int64(postSeconds)) {
                if act[t] == 1 { walk += 1 }
                if act[t] == 2 { run = true }
            }
            if walk < postWalkMin || run { continue }
            var b: [Double] = []
            for t in (t0 - Int64(hrBaseSeconds))..<t0 { if let v = hr[t] { b.append(v) } }
            if b.count < hrBaseMin { continue }
            let base = SignalMath.median(b)
            if b.max()! - b.min()! > hrBaseRange || base > hrBaseMax { continue }
            var peaks: [Double] = []
            for c in (t0 + Int64(peakFrom))...(t0 + Int64(peakTo)) {
                var w: [Double] = []
                for t in (c - Int64(peakHalf))...(c + Int64(peakHalf)) { if let v = hr[t] { w.append(v) } }
                if w.count >= 4 { peaks.append(SignalMath.median(w)) }
            }
            if peaks.count < peakMinCentres { continue }
            let peak = peaks.max()!
            out.append(Event(t0: t0, baseline: base, peak: peak, rise: peak - base))
            nextOK = t0 + gapSeconds
        }
        return out
    }

    public static func day(_ events: [Event]) -> Computed<(rise: Double, events: Int)> {
        if events.count < minEvents {
            return .missing("\(events.count) valid rest-to-walk onsets, \(minEvents) needed")
        }
        return .success((SignalMath.median(events.map(\.rise)), events.count))
    }

    /// The span's seconds from the stored rows (R18 activity class) and heart rate (bpm by second).
    public static func events(rows: [R18Second], hr: [HRPoint], from: Int64, to: Int64) -> [Event] {
        var act: [Int64: Int] = [:]
        for r in rows where r.ts >= from && r.ts < to {
            if let c = r.activityClass { act[r.ts] = c }
        }
        var h: [Int64: Double] = [:]
        for p in hr where p.ts >= from - Int64(hrBaseSeconds) && p.ts < to + Int64(postSeconds) && p.bpm.isFinite {
            h[p.ts] = p.bpm
        }
        return events(act: act, hr: h)
    }

    /// One-value carry series of a day: the median rise, with the number of onsets behind it.
    static func series(_ events: [Event], start: Int64, span: Int64) -> [Series] {
        guard case .success(let d) = day(events) else { return [] }
        return [PipelineOutput.carry(seriesName, variant: id, start: start, stepS: span, value: d.rise, n: d.events,
                                     unit: "bpm", tier: .research)]
    }
}
