import Foundation
import MGDomain

/// ALG-040 v1 — strap step counter (G-STEPS). Python reference: `step_ticks`, `steps_from_ticks`, `fit_ticks_per_step`;
/// goldens app/shared/golden/day/ALG-040.json.
///
/// R18 @57 `step_motion_counter` is a cumulative u16 MOTION-TICK counter whose step semantics are unverified (noop
/// StepsCounter.swift, checked 2026-10-11). So this file returns ticks, and steps only with a calibration against iPhone steps —
/// raw counts are not units. Sources: noop Packages/StrandAnalytics StepsCounter.swift (walk/run class gate, 512-tick
/// reboot guard, 4 ticks/s rate guard); whoop-rs physio-algo steps.rs (wrap-aware u16 delta). The 100 Hz pedometer
/// (R21) is a separate member of the group and not built yet.
public enum ALG040 {
    public static let method = "ALG-040@1 strap-step-counter"
    public static let paramsVersion = "1"

    /// A bigger u16 jump between adjacent samples is a reboot or sync gap, not motion.
    public static let maxStepDelta = 512
    public static let maxTicksPerSecond = 4
    /// R18 activity_class: 0 still, 1 walk, 2 run (noop Streams.swift, community finding #316).
    public static let locomotionClasses: Set<Int> = [1, 2]
    /// Calibration needs this many days with both counts, each with at least `calibrationMinCount` of both.
    public static let calibrationMinDays = 7
    public static let calibrationMinCount = 1000.0

    /// The strap variant of `steps`. Only produced with a calibration; tier is "estimate".
    public static let spec = MetricSpec(
        key: .steps, unit: "count", group: "G-STEPS", variant: "strap", method: method, tier: .estimate, source: "R18",
        window: "day", producer: .strap, citation: nil, paramsVersion: paramsVersion)

    public struct StepSample: Sendable, Equatable {
        public var ts: Int
        /// u16 counter, 0…65535.
        public var counter: Int
        public var activityClass: Int?

        public init(ts: Int, counter: Int, activityClass: Int?) {
            self.ts = ts
            self.counter = counter
            self.activityClass = activityClass
        }
    }

    public struct Ticks: Sendable, Equatable {
        public var ticks: Int
        /// Increments kept.
        public var increments: Int
        /// Increments dropped because the strap did not label that second walk or run.
        public var skippedClass: Int
        /// Increments dropped as a reboot, wrap glitch or more than 4 ticks per second.
        public var skippedImplausible: Int
        public var spanS: Int

        public init(ticks: Int, increments: Int, skippedClass: Int, skippedImplausible: Int, spanS: Int) {
            self.ticks = ticks
            self.increments = increments
            self.skippedClass = skippedClass
            self.skippedImplausible = skippedImplausible
            self.spanS = spanS
        }
    }

    /// ALG-040 v1 — locomotion motion ticks from the cumulative u16 counter. Each increment (u16 wrap-aware) is credited to
    /// the LATER sample and kept only when the strap labels that sample walk or run (when no sample carries a class — the
    /// legacy case — all increments are kept) and it is plausible: 1 ≤ delta < 512 and ≤ 4 ticks per second of elapsed
    /// time (a reboot, sync gap or wrap glitch is dropped). Fewer than two samples is Missing, not zero.
    ///
    /// `excluding` (r9o, D-LOAD-WALK-1 item 12): an increment whose timestamp it returns true for is not counted at all (the strap
    /// was not on the wrist then, `WearPolicy`); nil counts everything, as before.
    public static func ticks(_ samples: [StepSample], excluding: ((Int) -> Bool)? = nil) -> Computed<Ticks> {
        if samples.count < 2 { return .missing("fewer than two step-counter samples") }
        var r = scan(samples)
        if let excluding { r.kept = r.kept.filter { !excluding($0.ts) } }
        return .success(Ticks(ticks: r.kept.reduce(0) { $0 + $1.delta }, increments: r.kept.count,
                              skippedClass: r.skippedClass, skippedImplausible: r.skippedImplausible, spanS: r.spanS))
    }

    /// r9o (D-LOAD-WALK-1 item 12): the kept ticks per bucket of `bucketS` seconds counted from `origin` (unix s), each increment
    /// credited to the LATER sample's bucket, by the same rules as `ticks` (the sum over buckets equals `ticks(samples).ticks`).
    /// Keys are bucket numbers `(ts - origin) / bucketS`, rounded down. Fewer than two samples = empty.
    public static func ticksByBucket(_ samples: [StepSample], origin: Int, bucketS: Int = 3600,
                                     excluding: ((Int) -> Bool)? = nil) -> [Int: Int] {
        guard samples.count >= 2, bucketS > 0 else { return [:] }
        var out: [Int: Int] = [:]
        for k in scan(samples).kept where !(excluding?(k.ts) ?? false) {
            let b = Int((Double(k.ts - origin) / Double(bucketS)).rounded(.down))
            out[b, default: 0] += k.delta
        }
        return out
    }

    /// The accepted increments (timestamp of the later sample, tick delta) and what was dropped, one place for `ticks` and
    /// `ticksByBucket`. Needs at least two samples.
    private static func scan(_ samples: [StepSample]) -> (kept: [(ts: Int, delta: Int)], skippedClass: Int,
                                                          skippedImplausible: Int, spanS: Int) {
        var order = Array(0..<samples.count)
        order.sort { samples[$0].ts != samples[$1].ts ? samples[$0].ts < samples[$1].ts : $0 < $1 }
        let rows = order.map { samples[$0] }
        let hasClass = rows.contains { $0.activityClass != nil }
        var kept: [(ts: Int, delta: Int)] = []
        var skippedClass = 0
        var skippedImplausible = 0
        for i in 1..<rows.count {
            let delta = (rows[i].counter - rows[i - 1].counter) & 0xFFFF
            if delta == 0 { continue }
            if hasClass {
                guard let c = rows[i].activityClass, locomotionClasses.contains(c) else {
                    skippedClass += 1
                    continue
                }
            }
            let elapsed = rows[i].ts - rows[i - 1].ts
            var ok = delta >= 1 && delta < maxStepDelta && elapsed > 0
            if ok {
                let allowance = elapsed >= maxStepDelta / maxTicksPerSecond ? maxStepDelta - 1 : elapsed * maxTicksPerSecond
                ok = delta <= allowance
            }
            if ok {
                kept.append((rows[i].ts, delta))
            } else {
                skippedImplausible += 1
            }
        }
        return (kept, skippedClass, skippedImplausible, rows[rows.count - 1].ts - rows[0].ts)
    }

    /// ALG-040 v1 — steps = ticks / ticksPerStep, rounded to whole steps. No default calibration: Missing until one exists
    /// (`fitTicksPerStep`); below 0.5 ticks per step is not plausible and is refused rather than clamped.
    public static func steps(fromTicks ticks: Double?, ticksPerStep: Double?) -> Computed<Int> {
        guard let ticks, ticks.isFinite, ticks >= 0 else { return .missing("no step-counter ticks") }
        guard let tps = ticksPerStep, tps.isFinite, tps > 0 else {
            return .missing("the strap counts motion ticks, not steps - needs a ticks-per-step calibration against iPhone steps")
        }
        if tps < 0.5 { return .missing("a calibration under 0.5 ticks per step is not plausible") }
        return .success(DayKit.r0(ticks / tps))
    }

    /// G-STEPS member `ALG-040:ticks` (wave 2, 2026-10-11): the day's raw step-counter ticks, shown while the strap
    /// member is blank for want of a calibration. Ticks are not steps: own unit, research tier, the note says why.
    public static let ticksSpec = MetricSpec(
        key: .steps, unit: "ticks", group: "G-STEPS", variant: "ALG-040:ticks", method: method + " raw ticks",
        tier: .research, source: "R18", window: "day", producer: .strap, citation: nil, paramsVersion: paramsVersion)

    /// The uncalibrated ticks member for a day: nil when the strap member has a value (calibrated) or the day has no
    /// tick count (`step_ticks_day` series). `stepsNote` = the strap member's blank reason, kept in the note.
    public static func uncalibratedTicks(metrics: [Metric], series: [Series], at: Date) -> Metric? {
        let strap = metrics.first { $0.name == MetricKey.steps.rawValue && $0.variant == spec.variant }
        if let v = strap?.value, v.isFinite { return nil }
        guard let tk = series.first(where: { $0.name == Baselines.stepTicksDay })?.values.first ?? nil,
              tk.isFinite else { return nil }
        let why = strap?.note ?? "no step calibration yet"
        return ticksSpec.metric(.success(tk), at: at,
                                note: "Raw strap step-counter ticks, uncalibrated (not steps): \(why)")
    }

    /// One calibration day: strap ticks and the reference step count (iPhone steps from Apple Health) for the same day.
    public struct TicksDay: Sendable, Equatable {
        public var ticks: Double
        public var referenceSteps: Double

        public init(ticks: Double, referenceSteps: Double) {
            self.ticks = ticks
            self.referenceSteps = referenceSteps
        }
    }

    public struct TicksPerStep: Sendable, Equatable {
        public var ticksPerStep: Double
        public var days: Int
        /// SD / mean of the per-day ratios: the honest spread of the calibration.
        public var cv: Double

        public init(ticksPerStep: Double, days: Int, cv: Double) {
            self.ticksPerStep = ticksPerStep
            self.days = days
            self.cv = cv
        }
    }

    /// ALG-040 v1 (ours v0) — ticks-per-step = Σ ticks / Σ reference steps over the days that have both, needing 7 such days.
    public static func fitTicksPerStep(days: [TicksDay]) -> Computed<TicksPerStep> {
        let ok = days.filter {
            $0.ticks.isFinite && $0.referenceSteps.isFinite && $0.ticks >= calibrationMinCount
                && $0.referenceSteps >= calibrationMinCount
        }
        if ok.count < calibrationMinDays {
            return .missing("needs \(calibrationMinDays) days with both the strap counter and iPhone steps (have \(ok.count))")
        }
        var st = 0.0
        var sr = 0.0
        for d in ok {
            st += d.ticks
            sr += d.referenceSteps
        }
        let ratios = ok.map { $0.ticks / $0.referenceSteps }
        return .success(TicksPerStep(ticksPerStep: st / sr, days: ok.count,
                                     cv: DayKit.sampleSD(ratios) / DayKit.mean(ratios)))
    }
}
