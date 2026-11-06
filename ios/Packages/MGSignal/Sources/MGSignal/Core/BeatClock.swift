import Foundation
import MGDomain

/// R-R points → beat end times (unix seconds). Python mirror: `mglab.ref.sort_rr_points` / `beat_times`.
///
/// The strap stamps each R-R with a whole second (ts = floor of the beat time; fixture EXPECTED.json notes), so
/// inside a contiguous run the clock is the running sum of the R-R values started at ts[0]. When the wall step
/// ts[i] − t[i−1] exceeds the beat's own interval by more than `gapSeconds`, the strap stopped reporting (a dropout):
/// the clock RE-ANCHORS to ts[i] instead of splicing the two sides of the hole together. It never moves backwards.
/// (Pattern from OpenStrap analytics rr_correction.dart `_beatTimes`; 2 s of slack covers the < 1 s flooring of ts.)
public enum BeatClock {
    public static let gapSeconds = 2.0

    /// Sorted by (ts, ord) — `ord` is the emission order inside one second (MGDomain RRPoint, noop #823).
    public static func sorted(_ points: [RRPoint]) -> [RRPoint] {
        points.sorted { ($0.ts, $0.ord) < ($1.ts, $1.ord) }
    }

    /// Beat end times for points already sorted by (ts, ord).
    public static func times(points: [RRPoint], gapSeconds: Double = BeatClock.gapSeconds) -> [Double] {
        times(ts: points.map(\.ts), rrMs: points.map(\.rrMs), gapSeconds: gapSeconds)
    }

    /// Beat end times from parallel arrays already sorted by (ts, ord).
    public static func times(ts: [Int64], rrMs: [Double], gapSeconds: Double = BeatClock.gapSeconds) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(ts.count)
        for i in 0..<min(ts.count, rrMs.count) {
            let wall = Double(ts[i])
            if i == 0 {
                out.append(wall)
                continue
            }
            let step = rrMs[i] / 1000.0
            var next = out[i - 1] + step
            if wall - out[i - 1] - step > gapSeconds && wall > next {
                next = wall
            }
            out.append(next)
        }
        return out
    }

    /// Beat end times of a contiguous R-R series (s, from 0): the running sum.
    public static func runningSum(rrMs: [Double]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(rrMs.count)
        var acc = 0.0
        for v in rrMs {
            acc += v / 1000.0
            out.append(acc)
        }
        return out
    }
}
