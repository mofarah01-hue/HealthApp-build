import Foundation
import MGDomain

/// ALG-041 v1 — workout detection from heart rate plus activity ("did you just work out?"). A suggestion only: it never
/// writes an event. Python reference: `detect_workouts`; goldens app/shared/golden/day/ALG-041.json. Workout TYPE is not
/// built (it needs the 100 Hz IMU, R21): every result is typed "detected".
///
/// Source: OpenStrap/analytics workout/auto_detect.dart (constants re-checked 2026-10-11). Ours: the strap activity-class
/// corroboration (≥ half of the classed seconds walk / run), and the floor is not rounded to whole bpm.
public enum ALG041 {
    public static let method = "ALG-041@1 hr-motion-detect"
    public static let paramsVersion = "1"

    /// HR gate: max(rhr + 40, rhr + 0.45·(hrmax − rhr)).
    public static let elevatedMarginBpm = 40.0
    public static let hrrFloorFraction = 0.45
    /// Longer than this is lifestyle activity, not a workout.
    public static let maxWorkoutMin = 120
    /// A span must hold the gate this long.
    public static let minSustainedSeconds = 12.0 * 60.0
    /// A dip below the gate no longer than this does not break the span.
    public static let maxDipSeconds = 90
    /// A hole in the data longer than this breaks the span.
    public static let maxGapSeconds = 90
    /// Spans separated by less than this merge.
    public static let mergeGapSeconds = 5 * 60
    public static let motionConfirmMean = 0.15
    public static let classConfirmShare = 0.5
    public static let onsetLookbackSeconds = 180
    public static let onsetWindowSeconds = 180
    public static let onsetRiseBpm = 25.0

    public enum Confirmation: String, Sendable {
        /// Mean gravity change ≥ 0.15 g across the span.
        case motion = "motion"
        /// At least half of the classed seconds are walk or run.
        case activityClass = "class"
        /// Low motion, but HR rose ≥ 25 bpm over the 3 minutes at the start (cycling, rowing).
        case onset = "onset"
        /// No motion or class series was given.
        case hrOnly = "hr_only"
    }

    public struct ActivityClassSample: Sendable, Equatable {
        public var ts: Int
        public var activityClass: Int

        public init(ts: Int, activityClass: Int) {
            self.ts = ts
            self.activityClass = activityClass
        }
    }

    public struct DetectedWorkout: Sendable, Equatable {
        public var startTs: Int
        public var endTs: Int
        public var durationMin: Int
        public var avgBpm: Double
        public var peakBpm: Double
        public var confirmedBy: Confirmation
        public var meanMotion: Double?
        public var floorBpm: Double

        public init(startTs: Int, endTs: Int, durationMin: Int, avgBpm: Double, peakBpm: Double, confirmedBy: Confirmation,
                    meanMotion: Double?, floorBpm: Double) {
            self.startTs = startTs
            self.endTs = endTs
            self.durationMin = durationMin
            self.avgBpm = avgBpm
            self.peakBpm = peakBpm
            self.confirmedBy = confirmedBy
            self.meanMotion = meanMotion
            self.floorBpm = floorBpm
        }
    }

    /// ALG-041 v1 — the vigorous gate: max(rhr + 40, rhr + 0.45·(hrmax − rhr)) bpm (not rounded to whole bpm; OpenStrap rounds).
    /// One definition for the detector and for ALG-106's measured-HRmax guard.
    public static func vigorousFloor(rhr: Double, hrmax: Double) -> Double {
        max(rhr + elevatedMarginBpm, rhr + hrrFloorFraction * (hrmax - rhr))
    }

    /// Mean of `vals` for lo ≤ ts < hi, or nil.
    private static func meanIn(_ ts: [Int], _ vals: [Double], _ lo: Int, _ hi: Int) -> Double? {
        var s = 0.0
        var c = 0
        for i in 0..<ts.count where ts[i] >= lo && ts[i] < hi {
            s += vals[i]
            c += 1
        }
        return c == 0 ? nil : s / Double(c)
    }

    /// ALG-041 v1 — suggestions for sustained hard efforts. A span is a stretch where HR holds at or above the floor for ≥ 12
    /// min, dips ≤ 90 s bridged, a hole in the data > 90 s ends it, spans < 5 min apart merged; longer than 120 min is
    /// lifestyle; the window mean must clear the floor; overlap with a saved workout is dropped. Confirmation: mean
    /// gravity change ≥ 0.15 g → motion; else ≥ half the classed seconds walk / run → class; else HR onset ≥ 25 bpm over
    /// the 3 min before the span → onset; no motion and no class series → hrOnly. An empty list is a valid answer; Missing
    /// only when the resting HR or HRmax is.
    public static func detect(hrTs: [Int], hrBpm: [Double], rhr: Double?, hrmax: Double?, motion: ALG044.MotionSeries? = nil,
                              classes: [ActivityClassSample]? = nil, savedSpans: [DayWindow] = []) -> Computed<[DetectedWorkout]> {
        DayKit.compute { () throws -> [DetectedWorkout] in
            let a = try DayKit.requireAnchors(rhr: rhr, hrmax: hrmax)
            let (t, b) = DayKit.validPairs(ts: hrTs, vals: hrBpm)
            let n = t.count
            if n == 0 { return [] }
            let floor = vigorousFloor(rhr: a.rhr, hrmax: a.hrmax)

            var spans: [(Int, Int)] = []
            var start: Int?
            var end = 0
            var dip: Int?
            func close() {
                if let s = start, Double(end - s) >= minSustainedSeconds { spans.append((s, end)) }
                start = nil
                dip = nil
            }
            for k in 0..<n {
                if k > 0 && start != nil && t[k] - t[k - 1] > maxGapSeconds { close() }
                if b[k] >= floor {
                    if start == nil { start = t[k] }
                    end = t[k]
                    dip = nil
                } else if start != nil {
                    if dip == nil { dip = t[k] }
                    if t[k] - dip! > maxDipSeconds { close() }
                }
            }
            close()
            if spans.isEmpty { return [] }

            var merged: [(Int, Int)] = []
            var cs = spans[0].0
            var ce = spans[0].1
            for sp in spans.dropFirst() {
                if sp.0 - ce < mergeGapSeconds {
                    ce = max(ce, sp.1)
                } else {
                    merged.append((cs, ce))
                    cs = sp.0
                    ce = sp.1
                }
            }
            merged.append((cs, ce))

            let motionSeries: ALG044.MotionSeries? = (motion?.ts.isEmpty == false) ? motion : nil
            let classSeries: [ActivityClassSample]? = (classes?.isEmpty == false) ? classes : nil
            var out: [DetectedWorkout] = []
            for (s, e) in merged {
                if e - s > maxWorkoutMin * 60 { continue }
                if savedSpans.contains(where: { s <= $0.end && $0.start <= e }) { continue }
                var win: [Double] = []
                for k in 0..<n where t[k] >= s && t[k] <= e { win.append(b[k]) }
                if win.isEmpty { continue }
                var sum = 0.0
                for v in win { sum += v }
                let meanHr = sum / Double(win.count)
                if meanHr < floor { continue }
                var confirmed: Confirmation? = .hrOnly
                var meanMotion: Double?
                if motionSeries != nil || classSeries != nil {
                    confirmed = nil
                    if let m = motionSeries {
                        var ms = 0.0
                        var mc = 0
                        for i in 0..<min(m.ts.count, m.intensity.count) where m.ts[i] >= s && m.ts[i] <= e {
                            ms += m.intensity[i]
                            mc += 1
                        }
                        let mm = mc == 0 ? 0.0 : ms / Double(mc)
                        meanMotion = mm
                        if mm >= motionConfirmMean { confirmed = .motion }
                    }
                    if confirmed == nil, let cl = classSeries {
                        var knownCount = 0
                        var loco = 0
                        for c in cl where c.ts >= s && c.ts <= e && (c.activityClass == 0 || c.activityClass == 1 || c.activityClass == 2) {
                            knownCount += 1
                            if ALG040.locomotionClasses.contains(c.activityClass) { loco += 1 }
                        }
                        if knownCount > 0 && Double(loco) / Double(knownCount) >= classConfirmShare { confirmed = .activityClass }
                    }
                    if confirmed == nil {
                        let pre = meanIn(t, b, s - onsetLookbackSeconds, s)
                        let early = meanIn(t, b, s, min(e + 1, s + onsetWindowSeconds))
                        if let pre, let early, early - pre >= onsetRiseBpm { confirmed = .onset }
                    }
                    if confirmed == nil { continue }
                }
                out.append(DetectedWorkout(startTs: s, endTs: e, durationMin: (e - s) / 60, avgBpm: meanHr,
                                           peakBpm: win.max() ?? meanHr, confirmedBy: confirmed ?? .hrOnly,
                                           meanMotion: meanMotion, floorBpm: floor))
            }
            return out
        }
    }
}
