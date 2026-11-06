import Foundation
import MGDomain

/// ALG-030 v1 — sleep window (van Hees 2015 angle rule), wake day (D13), regularity: SRI (Phillips 2017), IS / IV
/// (Witting 1990), L5 / M10 / RA (van Someren 1999). Cosinor is phase N (not built). Python: `mglab.ref.sleep`.
public enum ALG030 {
    static let stillDeg = 5.0                // van Hees 2015: no z-angle change > 5° …
    static let stillMinEpochs = 60           // … for ≥ 5 min (sixty 5-s epochs)
    static let windowBridgeSeconds: Int64 = 1800   // OpenStrap van_hees.dart bridgeGapMin 30 (HDCZA uses 60)
    static let windowMinSeconds: Int64 = 1800      // van Hees 2018 HDCZA: blocks < 30 min are not a sleep period
    static let sriMinPairedDays = 5          // ours v1
    static let npHourMinMinutes = 30         // ours v1
    static let npMinHours = 120              // ours v1: 5 days of valid hours
    static let npMinPerHourOfDay = 2
    public static let citation = "van Hees et al. 2015 PLoS One 10:e0142533; 2018 Sci Rep 8:12975; Phillips et al. "
        + "2017 Sci Rep 7:3216; Witting et al. 1990; van Someren et al. 1999"

    /// A joined block of sustained-inactivity bouts: [start, end) unix s, first / last 5-s index, bouts joined.
    public struct InactivityBlock: Sendable, Equatable {
        public var start: Int64
        public var end: Int64
        public var k0: Int
        public var k1: Int
        public var bouts: Int

        public init(start: Int64, end: Int64, k0: Int, k1: Int, bouts: Int) {
            self.start = start
            self.end = end
            self.k0 = k0
            self.k1 = k1
            self.bouts = bouts
        }
    }

    /// The night's rest window — the "time in bed" proxy (a REST window, not PSG sleep).
    public struct RestWindow: Sendable, Equatable {
        public var restStart: Int64
        public var restEnd: Int64
        public var minutes: Double
        public var stillMin: Double
        public var unobservedMin: Double
        public var bouts: Int

        public init(restStart: Int64, restEnd: Int64, minutes: Double, stillMin: Double, unobservedMin: Double,
                    bouts: Int) {
            self.restStart = restStart
            self.restEnd = restEnd
            self.minutes = minutes
            self.stillMin = stillMin
            self.unobservedMin = unobservedMin
            self.bouts = bouts
        }
    }

    /// van Hees 2015 sustained-inactivity bouts (5-s epoch k still when d[k] ≤ 5°; a bout = ≥ 60 still epochs), joined
    /// when the gap from one bout's end to the next one's start is < `maxGapSeconds`.
    public static func inactivityBouts(_ g: SleepMotionGrid, maxGapSeconds: Int64,
                                       minEpochs: Int = 60) -> [InactivityBlock] {
        let still = g.d.map { v -> Bool in
            guard let v else { return false }
            return v <= stillDeg
        }
        let bouts = SleepMath.runs(still).filter { $0.1 - $0.0 + 1 >= minEpochs }
        var blocks: [(Int, Int, Int)] = []
        for (a, b) in bouts {
            if let last = blocks.last, Int64(a - last.1 - 1) * SleepMotionGrid.angleEpochSeconds < maxGapSeconds {
                blocks[blocks.count - 1] = (last.0, b, last.2 + 1)
            } else {
                blocks.append((a, b, 1))
            }
        }
        return blocks.map {
            InactivityBlock(start: g.t0 + Int64($0.0) * SleepMotionGrid.angleEpochSeconds,
                            end: g.t0 + Int64($0.1 + 1) * SleepMotionGrid.angleEpochSeconds, k0: $0.0, k1: $0.1,
                            bouts: $0.2)
        }
    }

    /// ALG-030 v1 — the longest joined block (bridge < 30 min) of ≥ 30 min. Pass one night's search span (recommended:
    /// 18:00 the evening before → 18:00 on the wake day).
    public static func sleepWindow(_ g: SleepMotionGrid) -> Computed<RestWindow> {
        // T9 (2026-10-12): no records, or none worn (strap off), is "no strap data", not a wrist-angle story.
        guard g.rows > 0, g.z.contains(where: { $0 != nil }) else { return .missing("no strap data for this night") }
        let blocks = inactivityBouts(g, maxGapSeconds: windowBridgeSeconds)
        guard var best = blocks.first else {
            return .missing("no 5-min stretch without a wrist-angle change > 5 deg while worn")
        }
        for b in blocks.dropFirst() where b.end - b.start > best.end - best.start { best = b }
        if best.end - best.start < windowMinSeconds {
            return .missing(String(format: "longest still block is %.1f min; a sleep period needs 30",
                                   Double(best.end - best.start) / 60.0))
        }
        var unobserved = 0
        var still = 0
        for k in best.k0...best.k1 {
            if g.z[k] == nil { unobserved += 1 }
            if let v = g.d[k], v <= stillDeg { still += 1 }
        }
        let e = SleepMotionGrid.angleEpochSeconds
        return .success(RestWindow(restStart: best.start, restEnd: best.end,
                                   minutes: Double(best.end - best.start) / 60.0,
                                   stillMin: Double(Int64(still) * e) / 60.0,
                                   unobservedMin: Double(Int64(unobserved) * e) / 60.0, bouts: best.bouts))
    }

    /// D13: a night belongs to the local calendar date of its final wake.
    public static func wakeDay(wake: Date, calendar: Calendar) -> LocalDay {
        LocalDay(date: wake, calendar: calendar)
    }

    /// D13 with a fixed UTC offset (golden parity; the app uses `wakeDay(wake:calendar:)`).
    public static func wakeDay(wakeUnix: Double, utcOffsetSeconds: Int) -> LocalDay {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? TimeZone(identifier: "UTC")!
        return LocalDay(date: Date(timeIntervalSince1970: wakeUnix.rounded(.down)), calendar: cal)
    }

    // MARK: SRI

    public struct SRI: Sendable, Equatable {
        public var sri: Double
        public var pairs: Int

        public init(sri: Double, pairs: Int) {
            self.sri = sri
            self.pairs = pairs
        }
    }

    /// Per-minute state: 1 asleep (minute start inside a sleep), 0 awake, nil unobserved (outside every observed
    /// interval). Sleeps = main sleeps (ALG-150 onset … final wake) and naps Mo confirmed.
    public static func minuteStates(start: Int64, minutes: Int, sleeps: [SleepInterval],
                                    observed: [SleepInterval]) -> [Int?] {
        (0..<minutes).map { i -> Int? in
            let t = Double(start + Int64(i) * 60)
            guard observed.contains(where: { $0.start <= t && t < $0.end }) else { return nil }
            return sleeps.contains(where: { $0.start <= t && t < $0.end }) ? 1 : 0
        }
    }

    /// ALG-030 SRI (Phillips et al. 2017): −100 + 200 · P(same state at t and t + 24 h) over observed pairs.
    public static func sri(_ states: [Int?], minutesPerDay: Int = 1440) -> Computed<SRI> {
        var same = 0
        var pairs = 0
        if states.count > minutesPerDay {
            for i in 0..<(states.count - minutesPerDay) {
                guard let a = states[i], let b = states[i + minutesPerDay] else { continue }
                pairs += 1
                if a == b { same += 1 }
            }
        }
        if pairs < sriMinPairedDays * minutesPerDay {
            return .missing(String(format: "needs %ld days of paired observed minutes (have %.1f)", sriMinPairedDays,
                                   Double(pairs) / Double(minutesPerDay)))
        }
        return .success(SRI(sri: -100.0 + 200.0 * Double(same) / Double(pairs), pairs: pairs))
    }

    // MARK: IS / IV / L5 / M10 / RA

    public struct Rhythm: Sendable, Equatable {
        public var interdailyStability: Double
        public var intradailyVariability: Computed<Double>
        public var l5: Double
        public var m10: Double
        public var relativeAmplitude: Computed<Double>
        public var l5StartHour: Int
        public var m10StartHour: Int
        public var hours: Int

        public init(interdailyStability: Double, intradailyVariability: Computed<Double>, l5: Double, m10: Double,
                    relativeAmplitude: Computed<Double>, l5StartHour: Int, m10StartHour: Int, hours: Int) {
            self.interdailyStability = interdailyStability
            self.intradailyVariability = intradailyVariability
            self.l5 = l5
            self.m10 = m10
            self.relativeAmplitude = relativeAmplitude
            self.l5StartHour = l5StartHour
            self.m10StartHour = m10StartHour
            self.hours = hours
        }
    }

    /// IS / IV / L5 / M10 / RA on hourly means of the per-minute activity (`SleepMotionGrid.act`, ours v1). Hours are
    /// local clock hours with one `utcOffsetSeconds` for the span. IS = (Σ_h (mean_h − mean)² / 24) / (Σ (x − mean)² / N);
    /// IV = (Σ consecutive-pair (Δx)² / P) / (Σ (x − mean)² / N); L5 / M10 = lowest 5 / highest 10 consecutive hours
    /// (circular) of the 24-h profile; RA = (M10 − L5) / (M10 + L5).
    public static func nonparametric(start: Int64, minuteActivity: [Double?],
                                     utcOffsetSeconds: Int) -> Computed<Rhythm> {
        guard !minuteActivity.isEmpty else { return .missing("no activity minutes") }
        let off = Int64(utcOffsetSeconds)
        let baseHour = SleepMath.floorDiv(start + off, 3600)
        var sums: [Int64: Double] = [:]
        var cnts: [Int64: Int] = [:]
        for (i, v) in minuteActivity.enumerated() {
            guard let v else { continue }
            let h = SleepMath.floorDiv(start + Int64(i) * 60 + off, 3600) - baseHour
            sums[h, default: 0] += v
            cnts[h, default: 0] += 1
        }
        let hours = sums.keys.filter { cnts[$0]! >= npHourMinMinutes }.sorted()
        guard hours.count >= npMinHours else {
            return .missing("needs \(npMinHours) valid hours (5 days) of activity (have \(hours.count))")
        }
        var x: [Int64: Double] = [:]
        for h in hours { x[h] = sums[h]! / Double(cnts[h]!) }
        var profS = [Double](repeating: 0, count: 24)
        var profC = [Int](repeating: 0, count: 24)
        for h in hours {
            let hod = Int(SleepMath.floorMod(baseHour + h, 24))
            profS[hod] += x[h]!
            profC[hod] += 1
        }
        guard profC.min()! >= npMinPerHourOfDay else {
            return .missing("every clock hour needs \(npMinPerHourOfDay) days of data (some have fewer)")
        }
        let prof = (0..<24).map { profS[$0] / Double(profC[$0]) }
        let n = Double(hours.count)
        var s = 0.0
        for h in hours { s += x[h]! }
        let m = s / n
        var ss = 0.0
        for h in hours { ss += (x[h]! - m) * (x[h]! - m) }
        let variance = ss / n
        guard variance > 0 else { return .missing("activity never varies: IS and IV are undefined") }
        var ps = 0.0
        for p in prof { ps += (p - m) * (p - m) }
        let isValue = (ps / 24.0) / variance
        var dsum = 0.0
        var dn = 0
        for h in hours {
            if let prev = x[h - 1] {
                dsum += (x[h]! - prev) * (x[h]! - prev)
                dn += 1
            }
        }
        let iv: Computed<Double> = dn > 0 ? .success((dsum / Double(dn)) / variance)
            : .missing("no consecutive valid hours")
        func windowSum(_ s: Int, _ len: Int) -> Double {
            var t = 0.0
            for i in 0..<len { t += prof[(s + i) % 24] }
            return t
        }
        // Python: l5 = min over s of sum5(s) / 5, start = earliest s with the lowest sum (ties keep the earliest).
        var l5Best = Double.infinity
        var l5Start = 0
        var m10Best = -Double.infinity
        var m10Start = 0
        for s in 0..<24 {
            let a = windowSum(s, 5)
            if a < l5Best {
                l5Best = a
                l5Start = s
            }
            let b = windowSum(s, 10)
            if b > m10Best {
                m10Best = b
                m10Start = s
            }
        }
        let l5 = l5Best / 5.0
        let m10 = m10Best / 10.0
        let ra: Computed<Double> = (m10 + l5) > 0 ? .success((m10 - l5) / (m10 + l5)) : .missing("no activity at all")
        return .success(Rhythm(interdailyStability: isValue, intradailyVariability: iv, l5: l5, m10: m10,
                               relativeAmplitude: ra, l5StartHour: l5Start, m10StartHour: m10Start,
                               hours: hours.count))
    }

    // MARK: metrics (registry names, ARCHITECTURE.md 8.3)

    public static let onsetSpec = MetricSpec(
        key: .sleepOnset, unit: "unix_s", group: nil, variant: "ALG-030", method: "ALG-030@1 van-hees-window+ALG-120-onset",
        tier: .estimate, source: "R18", window: "night", citation: citation, paramsVersion: "5deg5min bridge30 min30")
    public static let wakeSpec = MetricSpec(
        key: .wakeTime, unit: "unix_s", group: nil, variant: "ALG-030", method: "ALG-030@1 van-hees-window+ALG-120-wake",
        tier: .estimate, source: "R18", window: "night", citation: citation, paramsVersion: "5deg5min bridge30 min30")
    public static let sriSpec = MetricSpec(
        key: .sri, unit: "score_0_100", group: nil, variant: "ALG-030", method: "ALG-030@1 sri-phillips-2017",
        tier: .estimate, source: "R18", window: "14d", citation: citation, paramsVersion: "min5days")
    public static let isSpec = MetricSpec(
        key: .circadianIs, unit: "ratio", group: nil, variant: "ALG-030", method: "ALG-030@1 is-witting",
        tier: .estimate, source: "R18", window: "14d", citation: citation, paramsVersion: "angle-activity hour30")
    public static let ivSpec = MetricSpec(
        key: .circadianIv, unit: "ratio", group: nil, variant: "ALG-030", method: "ALG-030@1 iv-witting",
        tier: .estimate, source: "R18", window: "14d", citation: citation, paramsVersion: "angle-activity hour30")
    public static let raSpec = MetricSpec(
        key: .circadianRa, unit: "ratio", group: nil, variant: "ALG-030", method: "ALG-030@1 ra-van-someren",
        tier: .estimate, source: "R18", window: "14d", citation: citation, paramsVersion: "angle-activity hour30")
    public static let l5Spec = MetricSpec(
        key: .circadianL5, unit: "count", group: nil, variant: "ALG-030", method: "ALG-030@1 l5-van-someren",
        tier: .estimate, source: "R18", window: "14d", citation: citation, paramsVersion: "angle-activity hour30")
    public static let m10Spec = MetricSpec(
        key: .circadianM10, unit: "count", group: nil, variant: "ALG-030", method: "ALG-030@1 m10-van-someren",
        tier: .estimate, source: "R18", window: "14d", citation: citation, paramsVersion: "angle-activity hour30")

    /// sri, circadian_is / iv / ra / l5 / m10 for a 14-day span ending `at`.
    public static func regularityMetrics(sri: Computed<SRI>, rhythm: Computed<Rhythm>, at: Date) -> [Metric] {
        [
            sriSpec.metric(sri.map(\.sri), at: at),
            isSpec.metric(rhythm.map(\.interdailyStability), at: at),
            ivSpec.metric(rhythm.flatMap(\.intradailyVariability), at: at),
            raSpec.metric(rhythm.flatMap(\.relativeAmplitude), at: at),
            l5Spec.metric(rhythm.map(\.l5), at: at),
            m10Spec.metric(rhythm.map(\.m10), at: at),
        ]
    }
}
