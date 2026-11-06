import Foundation
import MGDomain

/// ALG-044 v1 — movement summaries from the strap's own activity class and gravity vector. Python reference:
/// `movement_summary`, `motion_points`; goldens app/shared/golden/day/ALG-044.json. ENMO / MAD need the 100 Hz IMU
/// (R21, ALG-113 = X) and are not here; typing / eating classifiers (ALG-044 proper) are fit-then-run later.
///
/// R18 @63 activity_class: 0 still, 1 walk, 2 run (noop Streams.swift, community finding #316); gx / gy / gz are the
/// gravity vector in g (R18 per-second summary, FINDINGS §1).
public enum ALG044 {
    public static let method = "ALG-044@1 activity-minutes"
    public static let paramsVersion = "1"

    /// A minute is "known" with at least this many classed seconds, and "active" with at least this many walk / run seconds.
    public static let minuteSeconds = 30
    /// A step across a hole bigger than this in the gravity stream is not a per-second change.
    public static let motionMaxGapSeconds = 2.0

    public struct MovementSummary: Sendable, Equatable {
        public var knownMin: Int
        public var stillMin: Int
        public var activeMin: Int
        public var walkMin: Int
        public var runMin: Int

        public init(knownMin: Int, stillMin: Int, activeMin: Int, walkMin: Int, runMin: Int) {
            self.knownMin = knownMin
            self.stillMin = stillMin
            self.activeMin = activeMin
            self.walkMin = walkMin
            self.runMin = runMin
        }
    }

    /// ALG-044 v1 — minutes by strap activity class. A minute (floor(ts / 60)) is known with ≥ 30 classed seconds, active
    /// when ≥ 30 of its seconds are walk or run, a run minute when active and run seconds > walk seconds.
    public static func movementSummary(ts: [Int], activityClass: [Int]) -> MovementSummary {
        var walk: [Int: Int] = [:]
        var run: [Int: Int] = [:]
        var known: [Int: Int] = [:]
        for i in 0..<min(ts.count, activityClass.count) {
            let c = activityClass[i]
            if c != 0 && c != 1 && c != 2 { continue }
            let k = DayKit.floorDiv(ts[i], 60)
            known[k, default: 0] += 1
            if c == 1 { walk[k, default: 0] += 1 }
            if c == 2 { run[k, default: 0] += 1 }
        }
        var nKnown = 0
        var nStill = 0
        var nActive = 0
        var nWalk = 0
        var nRun = 0
        for (k, kn) in known where kn >= minuteSeconds {
            nKnown += 1
            let w = walk[k] ?? 0
            let r = run[k] ?? 0
            if w + r >= minuteSeconds {
                nActive += 1
                if r > w { nRun += 1 } else { nWalk += 1 }
            } else {
                nStill += 1
            }
        }
        return MovementSummary(knownMin: nKnown, stillMin: nStill, activeMin: nActive, walkMin: nWalk, runMin: nRun)
    }

    public struct MotionSeries: Sendable, Equatable {
        public var ts: [Int]
        /// Length of the change of the gravity vector (g) from the previous record, per second.
        public var intensity: [Double]

        public init(ts: [Int], intensity: [Double]) {
            self.ts = ts
            self.intensity = intensity
        }
    }

    /// ALG-044 v1 — per-second motion intensity = length of the gravity-vector change from the previous record; 0 for the
    /// first record and after a hole bigger than 2 s. Sorted by ts.
    public static func motionPoints(ts: [Int], gx: [Double], gy: [Double], gz: [Double]) -> MotionSeries {
        let n = min(ts.count, gx.count, gy.count, gz.count)
        var idx = (0..<n).filter { gx[$0].isFinite && gy[$0].isFinite && gz[$0].isFinite }
        idx.sort { ts[$0] != ts[$1] ? ts[$0] < ts[$1] : $0 < $1 }
        var outT: [Int] = []
        var outV: [Double] = []
        var prev: Int?
        for i in idx {
            var v = 0.0
            if let p = prev {
                let gap = Double(ts[i] - ts[p])
                if gap > 0 && gap <= motionMaxGapSeconds {
                    let dx = gx[i] - gx[p]
                    let dy = gy[i] - gy[p]
                    let dz = gz[i] - gz[p]
                    v = (dx * dx + dy * dy + dz * dz).squareRoot()
                }
            }
            outT.append(ts[i])
            outV.append(v)
            prev = i
        }
        return MotionSeries(ts: outT, intensity: outV)
    }
}
