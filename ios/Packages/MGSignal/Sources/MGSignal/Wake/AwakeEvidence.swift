import Foundation
import MGDomain

/// Awake evidence for the strap alarms (added 2026-10-11; ours, v1 — every threshold is a named, tunable parameter).
///
/// Mo: "Some alarms I do multiple if it doesn't detect I'm moving" and "If it detects I stay awake, the second alarm
/// never fires — we'll use motion". The live BLE stream carries heart rate and R-R only; motion (the R18 step-motion
/// counter, activity class and wrist gravity) arrives with the history offloads — so the app pulls an offload every
/// few minutes while an alarm rings, and judges whole minutes:
///
/// * AWAKE when Mo taps "I'm up"; or he is WALKING (≥ `walkTicks` locomotion ticks in `walkWindowMinutes` — ALG-040's
///   golden-tested counter rules: wrap-aware u16 delta, walk/run class only, reboot / rate guards); or his heart rate
///   stays ≥ `hrRiseBpm` above his sleeping baseline for `sustainMinutes` minutes in a row AND he moves (locomotion
///   ticks or a wrist turn of ≥ `turnDegrees`) in at least `motionMinutesNeeded` minutes around that run. Heart rate
///   alone, or turning over alone, is not enough; a strap double-tap is never an input (it can be a reflex).
/// * STAYED AWAKE after a wake (for skipping the second alarm) when no `sleepRunMinutes`-long still stretch with
///   sleeping-level heart rate follows it AND at least `stayedAwakeCoverage` of the minutes have strap data. Missing
///   data, or a still stretch without heart rate, reads as "back to sleep" or "unknown" — the alarm then still fires
///   (the safe side).
///
/// Units: `ticks` are the strap's MOTION TICKS (R18 @57 step_motion_counter), not calibrated steps (ALG-040). The
/// "steps" in Mo's words are these ticks. Gravity components are in g (R18Second.gx…gz).
public enum AwakeEvidence {
    public struct Params: Equatable, Sendable {
        public var hrRiseBpm: Double = 10
        public var sustainMinutes: Int = 3
        public var motionMinutesNeeded: Int = 2
        /// Motion counts when it is within this many minutes of the heart-rate run.
        public var motionSlackMinutes: Int = 2
        public var ticksPerMotionMinute: Int = 5
        public var turnDegrees: Double = 30
        public var walkTicks: Int = 60
        public var walkWindowMinutes: Int = 5
        /// The sleeping baseline: median minute heart rate over this many minutes before the window opened.
        public var baselineMinutes: Int = 20
        /// A minute "has strap data" with at least this many R18 seconds.
        public var minCoverageSeconds: Int = 30
        public var sleepRunMinutes: Int = 20
        public var sleepHRMarginBpm: Double = 5
        public var stayedAwakeCoverage: Double = 0.7

        public init() {}

        public static let v1 = Params()

        /// The Fajr wake is "harder locked" (Mo): heart rate up for 5 min and moving in 3 minutes around it.
        public static let fajrLocked: Params = {
            var p = Params()
            p.sustainMinutes = 5
            p.motionMinutesNeeded = 3
            return p
        }()
    }

    public static let version = "awake-evidence@1"

    /// One minute of strap data.
    public struct Minute: Equatable, Sendable {
        /// Unix seconds, minute-aligned.
        public var start: Int64
        /// Mean heart rate (R18 + live beats); nil when none.
        public var hr: Double?
        /// Locomotion motion ticks (ALG-040 rules).
        public var ticks: Int
        /// The wrist turned by `turnDegrees` or more inside the minute or against the minute before.
        public var turned: Bool
        /// R18 seconds present.
        public var seconds: Int

        public init(start: Int64, hr: Double?, ticks: Int, turned: Bool, seconds: Int) {
            self.start = start
            self.hr = hr
            self.ticks = ticks
            self.turned = turned
            self.seconds = seconds
        }

        public func moving(_ p: Params) -> Bool { ticks >= p.ticksPerMotionMinute || turned }
    }

    /// Minute summaries for [from, to). `hr` is live heart rate (realtime stream) on top of R18's own.
    public static func minutes(r18: [R18Second], hr: [HRPoint], from: Int64, to: Int64,
                               params p: Params = .v1) -> [Minute] {
        let m0 = Int64((Double(from) / 60).rounded(.down)) * 60
        guard to > m0 else { return [] }
        let rows = r18.sorted { $0.ts < $1.ts }
        var out: [Minute] = []
        var lastSample: R18Second? = rows.last { $0.ts < m0 }
        var prevMean: (Double, Double, Double)?
        var i = rows.firstIndex { $0.ts >= m0 } ?? rows.count
        var m = m0
        while m < to {
            var secs: [R18Second] = []
            while i < rows.count, rows[i].ts < m + 60 {
                secs.append(rows[i])
                i += 1
            }
            let hrs = secs.compactMap { $0.hr }.filter { $0 > 0 }
                + hr.filter { $0.ts >= m && $0.ts < m + 60 && $0.bpm > 0 }.map(\.bpm)
            let meanHR = hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count)
            var counterRows = secs.compactMap { s in s.steps.map { ALG040.StepSample(ts: Int(s.ts), counter: $0,
                                                                                    activityClass: s.activityClass) } }
            if let prev = lastSample, let c = prev.steps {
                counterRows.insert(ALG040.StepSample(ts: Int(prev.ts), counter: c, activityClass: prev.activityClass), at: 0)
            }
            let ticks = ALG040.ticks(counterRows).value?.ticks ?? 0
            let g = secs.compactMap { s -> (Int64, Double, Double, Double)? in
                guard let x = s.gx, let y = s.gy, let z = s.gz else { return nil }
                return (s.ts, x, y, z)
            }
            var turned = false
            if g.count >= 6 {
                let first = mean(g.prefix(10).map { ($0.1, $0.2, $0.3) })
                let last = mean(g.suffix(10).map { ($0.1, $0.2, $0.3) })
                turned = angle(first, last) >= p.turnDegrees
                let all = mean(g.map { ($0.1, $0.2, $0.3) })
                if let pm = prevMean, angle(pm, all) >= p.turnDegrees { turned = true }
                prevMean = all
            } else {
                prevMean = nil
            }
            if let lastOfMinute = secs.last { lastSample = lastOfMinute }
            out.append(Minute(start: m, hr: meanHR, ticks: ticks, turned: turned, seconds: secs.count))
            m += 60
        }
        return out
    }

    /// The sleeping baseline: median minute heart rate over `baselineMinutes` before `before`; nil with fewer than 5.
    public static func baselineHR(_ minutes: [Minute], before: Int64, params p: Params = .v1) -> Double? {
        let from = before - Int64(p.baselineMinutes) * 60
        let v = minutes.filter { $0.start >= from && $0.start < before }.compactMap(\.hr).sorted()
        guard v.count >= 5 else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }

    public enum Verdict: Equatable, Sendable {
        case awake(at: Int64, why: String)
        case notYet(String)

        public var isAwake: Bool {
            if case .awake = self { return true }
            return false
        }
    }

    /// Is Mo up, judging the minutes from `since` (the window opening or the first buzz) to `now`?
    public static func evaluate(since: Int64, now: Int64, baselineHR: Double?, minutes all: [Minute], imUpAt: Int64?,
                                params p: Params = .v1) -> Verdict {
        if let t = imUpAt, t >= since - 60 { return .awake(at: t, why: "you tapped I'm up") }
        let ms = all.filter { $0.start >= since - 60 && $0.start < now }.sorted { $0.start < $1.start }
        // walking
        if ms.count >= 1 {
            for j in ms.indices {
                let window = ms[j...].prefix { $0.start < ms[j].start + Int64(p.walkWindowMinutes) * 60 }
                let ticks = window.reduce(0) { $0 + $1.ticks }
                if ticks >= p.walkTicks, let end = window.last {
                    return .awake(at: end.start + 60, why: "walking (\(ticks) motion ticks in \(p.walkWindowMinutes) min)")
                }
            }
        }
        guard let base = baselineHR else {
            return .notYet("no sleeping heart rate from before the alarm, so only walking or I'm up count")
        }
        var run: [Minute] = []
        var sawRise = false
        for m in ms {
            if let h = m.hr, h >= base + p.hrRiseBpm, run.last.map({ $0.start + 60 == m.start }) ?? true {
                run.append(m)
            } else if let h = m.hr, h >= base + p.hrRiseBpm {
                run = [m]
            } else {
                run = []
            }
            if run.count >= p.sustainMinutes {
                sawRise = true
                let a = run[run.count - p.sustainMinutes].start - Int64(p.motionSlackMinutes) * 60
                let b = m.start + Int64(p.motionSlackMinutes) * 60
                let moving = ms.filter { $0.start >= a && $0.start <= b && $0.moving(p) }
                if moving.count >= p.motionMinutesNeeded {
                    let mean = run.suffix(p.sustainMinutes).compactMap(\.hr).reduce(0, +) / Double(p.sustainMinutes)
                    return .awake(at: m.start + 60, why: "heart rate up \(Int((mean - base).rounded())) bpm for "
                                  + "\(p.sustainMinutes) min and moving")
                }
            }
        }
        return .notYet(sawRise ? "heart rate up but no movement yet" : "heart rate not up for \(p.sustainMinutes) min yet")
    }

    public enum StayedAwake: Equatable, Sendable {
        case stayedAwake(String)
        case backToSleep(at: Int64)
        case unknown(String)
    }

    /// After a wake at `awakeAt`: did Mo go back to sleep before `now`?
    public static func stayedAwake(from awakeAt: Int64, to now: Int64, sleepingHR: Double?, minutes all: [Minute],
                                   params p: Params = .v1) -> StayedAwake {
        let ms = all.filter { $0.start >= awakeAt && $0.start + 60 <= now }.sorted { $0.start < $1.start }
        let total = max(0, Int((now - awakeAt) / 60))
        guard total > 0 else { return .unknown("no time has passed since the wake") }
        var runStart: Int64?
        var runLen = 0
        var prev: Int64?
        for m in ms {
            let covered = m.seconds >= p.minCoverageSeconds
            let calmHR = sleepingHR.map { base in m.hr.map { $0 <= base + p.sleepHRMarginBpm } ?? true } ?? true
            let still = covered && !m.moving(p) && calmHR
            if still, prev.map({ $0 + 60 == m.start }) ?? true, runLen > 0 {
                runLen += 1
            } else if still {
                runStart = m.start
                runLen = 1
            } else {
                runLen = 0
            }
            prev = m.start
            if runLen >= p.sleepRunMinutes, let s = runStart { return .backToSleep(at: s) }
        }
        let covered = ms.filter { $0.seconds >= p.minCoverageSeconds }.count
        let share = Double(covered) / Double(total)
        guard share >= p.stayedAwakeCoverage else {
            return .unknown("only \(Int((share * 100).rounded())) % of the minutes since have strap data")
        }
        return .stayedAwake("no \(p.sleepRunMinutes)-min still stretch since the wake")
    }

    static func mean(_ v: [(Double, Double, Double)]) -> (Double, Double, Double) {
        let n = Double(max(1, v.count))
        return (v.reduce(0) { $0 + $1.0 } / n, v.reduce(0) { $0 + $1.1 } / n, v.reduce(0) { $0 + $1.2 } / n)
    }

    /// Angle between two gravity vectors, degrees (0 when either is ~zero).
    static func angle(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let na = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).squareRoot()
        let nb = (b.0 * b.0 + b.1 * b.1 + b.2 * b.2).squareRoot()
        guard na > 0.2, nb > 0.2 else { return 0 }
        let c = max(-1, min(1, (a.0 * b.0 + a.1 * b.1 + a.2 * b.2) / (na * nb)))
        return acos(c) * 180 / .pi
    }
}
