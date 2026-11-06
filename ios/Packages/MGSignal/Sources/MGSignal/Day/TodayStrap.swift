import Foundation
import MGDomain

/// Today's strap data so far, for Today's "Today so far" block (tracker #75, Mo 2026-10-11 15:13 PT: "ive had my whoop on
/// and the app connected most of today … the app displays nothing but i see the live hr"). Only shared kernels, nothing
/// new: worn minutes and their mean HR are ALG-036 `perMinuteHR` (a minute counts with ≥ 30 on-skin seconds), step ticks
/// are ALG-040 `ticks` (raw counter ticks, not steps), duplicates go through `PipelineStreams.dedupe` like every pipeline.
///
/// Bounded to [from, to] (local midnight → now): a sample outside it is never counted, and the step counter's first
/// increment of the day needs a predecessor inside the range (yesterday's last reading is not one).
public enum TodayStrap {
    public struct Summary: Sendable, Equatable {
        public var from: Int64
        public var to: Int64
        /// Distinct seconds with a stored heart rate in [from, to] (any value, before the on-skin rule).
        public var hrSeconds: Int
        /// ALG-036 worn minutes in [from, to]; time worn = this × 60 s. Gaps (no samples, off-wrist zeros) never count.
        public var wornMinutes: Int
        /// Mean of the worn minutes' mean HR (bpm); nil without a worn minute.
        public var averageHR: Double?
        /// The newest on-skin second (0 < bpm ≤ 250) and its HR.
        public var latestHR: Double?
        public var latestHRTs: Int64?
        /// ALG-040 locomotion ticks in [from, to]; nil when they can't be counted (`ticksMissing` says why).
        public var stepTicks: Int?
        public var ticksMissing: String?
        /// Distinct R18 seconds in [from, to].
        public var r18Seconds: Int

        public init(from: Int64, to: Int64, hrSeconds: Int, wornMinutes: Int, averageHR: Double?, latestHR: Double?,
                    latestHRTs: Int64?, stepTicks: Int?, ticksMissing: String?, r18Seconds: Int) {
            self.from = from
            self.to = to
            self.hrSeconds = hrSeconds
            self.wornMinutes = wornMinutes
            self.averageHR = averageHR
            self.latestHR = latestHR
            self.latestHRTs = latestHRTs
            self.stepTicks = stepTicks
            self.ticksMissing = ticksMissing
            self.r18Seconds = r18Seconds
        }

        public var wornSeconds: Int { wornMinutes * 60 }
    }

    public static func summarize(hr: [HRPoint], r18: [R18Second], from: Int64, to: Int64) -> Summary {
        let beats = PipelineStreams.dedupe(hr.filter { $0.ts >= from && $0.ts <= to })
        let mins = ALG036.perMinuteHR(ts: beats.map { Int($0.ts) }, bpm: beats.map(\.bpm))
        let onSkin = beats.last { $0.bpm.isFinite && $0.bpm > 0 && $0.bpm <= ALG036.bpmMaxValid }
        let seconds = PipelineStreams.dedupe(r18.filter { $0.ts >= from && $0.ts <= to })
        let samples = seconds.compactMap { r -> ALG040.StepSample? in
            r.steps.map { ALG040.StepSample(ts: Int(r.ts), counter: $0, activityClass: r.activityClass) }
        }
        let ticks: Computed<ALG040.Ticks> = samples.isEmpty ? .missing(noStepReadings) : ALG040.ticks(samples)
        return Summary(from: from, to: to, hrSeconds: beats.count, wornMinutes: mins.minuteTs.count,
                       averageHR: mins.hr.isEmpty ? nil : DayKit.mean(mins.hr), latestHR: onSkin?.bpm,
                       latestHRTs: onSkin?.ts, stepTicks: ticks.value?.ticks, ticksMissing: ticks.missingReason,
                       r18Seconds: seconds.count)
    }

    static let noStepReadings = "no step-counter readings stored today"

    // MARK: Incremental (the app's once-a-minute refresh)

    /// `summarize` kept up to date row by row, so a refresh reads only the rows stored since the last one (wave 6,
    /// 2026-10-11: re-reading the whole day every minute was up to ~86k rows per stream at night). Rows may arrive in
    /// any order — a history offload backfills seconds hours old — and twice (live, then history); `summary(to:)`
    /// equals `summarize` over everything added. Work per refresh: the minutes that got rows, plus a walk over the
    /// day's minute buckets (≤ 1440). The shared kernels run per minute: ALG-036 `perMinuteHR` on one minute's seconds,
    /// ALG-040 `ticks` on one minute's counter readings plus the reading before them.
    public struct Accumulator: Sendable {
        public let from: Int64
        /// Minute → second → the kept copy (history first, as `PipelineStreams.dedupe`).
        private var hr: [Int64: [Int64: HRPoint]] = [:]
        private var hrMinutes: [Int64] = []
        /// Minute → (distinct seconds, worn-minute mean or nil), for minutes whose rows have not changed since.
        private var hrCache: [Int64: (seconds: Int, mean: Double?)] = [:]
        /// Minute → second → counter reading (the first row of a second wins, as `PipelineStreams.dedupe`).
        private var steps: [Int64: [Int64: ALG040.StepSample]] = [:]
        private var stepMinutes: [Int64] = []
        private var r18: Set<Int64> = []
        /// Minute → ticks credited in it (with the reading before it and the class rule it was counted under), its
        /// readings and the last one, for minutes whose rows have not changed since.
        private var tickCache: [Int64: (prevTs: Int64?, classGate: Bool, ticks: Int, count: Int,
                                        last: ALG040.StepSample)] = [:]
        private var hasClass = false

        public init(from: Int64) {
            self.from = from
        }

        /// Rows before `from` are ignored; rows after "now" are kept and count once `summary(to:)` reaches them.
        public mutating func add(hr points: [HRPoint], r18 rows: [R18Second]) {
            for p in points where p.ts >= from {
                let minute = Int64(DayKit.floorDiv(Int(p.ts), 60))
                if let b = hr[minute]?[p.ts], PipelineStreams.sourceRank(b.source) <= PipelineStreams.sourceRank(p.source) {
                    continue
                }
                if hr[minute] == nil { Self.insertSorted(minute, into: &hrMinutes) }
                hr[minute, default: [:]][p.ts] = p
                hrCache[minute] = nil
            }
            for r in rows where r.ts >= from && !r18.contains(r.ts) {
                r18.insert(r.ts)
                guard let counter = r.steps else { continue }
                let minute = Int64(DayKit.floorDiv(Int(r.ts), 60))
                if steps[minute] == nil { Self.insertSorted(minute, into: &stepMinutes) }
                steps[minute, default: [:]][r.ts] = ALG040.StepSample(ts: Int(r.ts), counter: counter,
                                                                     activityClass: r.activityClass)
                tickCache[minute] = nil
                if r.activityClass != nil { hasClass = true }
            }
        }

        /// The same numbers as `summarize(hr:r18:from:to:)` over every row added.
        public mutating func summary(to: Int64) -> Summary {
            let last = Int64(DayKit.floorDiv(Int(to), 60))
            var seconds = 0
            var means: [Double] = []
            var latest: HRPoint?
            for minute in hrMinutes where minute <= last {
                guard let bucket = hr[minute] else { continue }
                let s: (seconds: Int, mean: Double?)
                if minute < last, let c = hrCache[minute] {
                    s = c
                } else {
                    let kept = bucket.values.filter { $0.ts <= to }.sorted { $0.ts < $1.ts }
                    let mins = ALG036.perMinuteHR(ts: kept.map { Int($0.ts) }, bpm: kept.map(\.bpm))
                    s = (kept.count, mins.hr.first)
                    if minute < last { hrCache[minute] = s }
                }
                seconds += s.seconds
                if let m = s.mean { means.append(m) }
            }
            for minute in hrMinutes.reversed() where minute <= last {
                latest = hr[minute]?.values
                    .filter { $0.ts <= to && $0.bpm.isFinite && $0.bpm > 0 && $0.bpm <= ALG036.bpmMaxValid }
                    .max { $0.ts < $1.ts }
                if latest != nil { break }
            }

            var ticks = 0
            var readings = 0
            var prev: ALG040.StepSample?
            for minute in stepMinutes where minute <= last {
                guard let bucket = steps[minute] else { continue }
                let prevTs = prev.map { Int64($0.ts) }
                if minute < last, let c = tickCache[minute], c.prevTs == prevTs, c.classGate == hasClass {
                    ticks += c.ticks
                    readings += c.count
                    prev = c.last
                    continue
                }
                let kept = bucket.values.filter { $0.ts <= Int(to) }.sorted { $0.ts < $1.ts }
                guard let lastKept = kept.last else { continue }
                // A reading with no class counts as "not walking" once any reading has one (the kernel's rule over
                // the whole day, which a one-minute slice could not see).
                let input = ((prev.map { [$0] } ?? []) + kept).map { s -> ALG040.StepSample in
                    var s = s
                    if hasClass, s.activityClass == nil { s.activityClass = -1 }
                    return s
                }
                let t = ALG040.ticks(input).value?.ticks ?? 0
                if minute < last { tickCache[minute] = (prevTs, hasClass, t, kept.count, lastKept) }
                ticks += t
                readings += kept.count
                prev = lastKept
            }
            let missing: String? = readings == 0 ? TodayStrap.noStepReadings
                : (readings == 1 ? ALG040.ticks([prev!]).missingReason : nil)
            return Summary(from: from, to: to, hrSeconds: seconds, wornMinutes: means.count,
                           averageHR: means.isEmpty ? nil : DayKit.mean(means), latestHR: latest?.bpm,
                           latestHRTs: latest?.ts, stepTicks: missing == nil ? ticks : nil, ticksMissing: missing,
                           r18Seconds: r18.filter { $0 <= to }.count)
        }

        private static func insertSorted(_ x: Int64, into a: inout [Int64]) {
            if let lastValue = a.last, lastValue < x { a.append(x); return }
            var lo = 0
            var hi = a.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if a[mid] < x { lo = mid + 1 } else { hi = mid }
            }
            a.insert(x, at: lo)
        }
    }
}
