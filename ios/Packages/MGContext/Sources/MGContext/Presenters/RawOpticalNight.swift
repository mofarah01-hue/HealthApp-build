import Foundation
import MGDomain

// Wave 4 (#65, 2026-10-11): raw optical at night, on a schedule, under the same off-by-default switch. Pure: the app
// passes the clock, the sleep window, the strap clock offset and what it learned; nothing here talks to the strap.
//
// Why short windows and live HR: iOS runs a backgrounded app only when a Bluetooth notification wakes it. With live HR
// on (the sanctioned toggle 3) the strap sends one every second, so the app can switch live optical (108 [01 01] /
// [01 00], rule 5, behind the switch) on just around the strap's own SpO₂ bursts instead of all night. The burst
// schedule is learned from stored R18 (ALG021Windows.duty); until then the one strap measured is used (unix % 1200 =
// 337, 30 s; CAPABILITIES "Optical, SpO₂ and R22").

/// The strap's SpO₂ burst schedule in strap unix seconds.
public struct SpO2BurstSchedule: Codable, Equatable, Sendable {
    public var periodS: Int64
    public var phaseS: Int64
    public var windowLenS: Int64
    /// When it was measured from this strap's R18; nil = the research default (another strap).
    public var learnedAt: Date?

    public init(periodS: Int64, phaseS: Int64, windowLenS: Int64, learnedAt: Date?) {
        self.periodS = periodS
        self.phaseS = phaseS
        self.windowLenS = windowLenS
        self.learnedAt = learnedAt
    }

    public static let researchDefault = SpO2BurstSchedule(periodS: 1200, phaseS: 337, windowLenS: 30, learnedAt: nil)
}

public enum RawOpticalNight {
    /// Live optical starts this long before a burst and stops this long after it: the R20 frames straddle the strap's
    /// SpO₂ window, so the LED experiment (pc.led-identity) sees blocks inside AND outside it.
    public static let leadS: Int64 = 90
    public static let tailS: Int64 = 90
    /// Live HR is kept on from this long before the sleep window (the app must be awake when it opens).
    public static let keepAwakeBeforeS: TimeInterval = 3 * 3600

    public struct Decision: Equatable, Sendable {
        /// 108 should be ON now.
        public var runNow: Bool
        /// Live HR should be on now to keep the app awake (sleep window or up to 3 h before it).
        public var keepAwake: Bool
        public var inSleepWindow: Bool
        /// The next moment `runNow` turns true (phone clock); nil outside the night.
        public var nextStart: Date?
    }

    static func mod(_ a: Int64, _ m: Int64) -> Int64 {
        let r = a % m
        return r < 0 ? r + m : r
    }

    /// Seconds into the run window (≥ 0, < period) for strap time `u`: the run window is [burst − lead, burst + len + tail).
    static func offset(_ u: Int64, _ s: SpO2BurstSchedule) -> Int64 { mod(u - (s.phaseS - leadS), s.periodS) }

    public static func runLength(_ s: SpO2BurstSchedule) -> Int64 { s.windowLenS + leadS + tailS }

    /// Share of the sleep window live optical runs (≈ 0.175 with the default schedule).
    public static func dutyFraction(_ s: SpO2BurstSchedule) -> Double {
        min(1, Double(runLength(s)) / Double(s.periodS))
    }

    public static func decide(now: Date, strapOffsetS: Double, sleepStart: Date, sleepEnd: Date,
                              schedule s: SpO2BurstSchedule) -> Decision {
        let inSleep = now >= sleepStart && now < sleepEnd
        let awake = now >= sleepStart.addingTimeInterval(-keepAwakeBeforeS) && now < sleepEnd
        let u = Int64((now.timeIntervalSince1970 + strapOffsetS).rounded(.down))
        let off = offset(u, s)
        let inRun = off < runLength(s)
        var next: Date?
        if now < sleepEnd {
            let from = max(now, sleepStart)
            let uf = Int64((from.timeIntervalSince1970 + strapOffsetS).rounded(.down))
            let o = offset(uf, s)
            let wait = o < runLength(s) ? 0 : s.periodS - o
            let at = from.addingTimeInterval(Double(wait))
            next = at < sleepEnd ? at : nil
        }
        return Decision(runNow: inSleep && inRun, keepAwake: awake, inSleepWindow: inSleep, nextStart: next)
    }
}

/// One night the app watched: its planned sleep window and how many live R20 records were stored in it.
public struct RawOpticalNightLog: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var frames: Int

    public init(start: Date, end: Date, frames: Int) {
        self.start = start
        self.end = end
        self.frames = frames
    }
}

/// The battery cost, measured — never assumed: strap battery drop per hour over nights with live optical vs without.
public enum RawOpticalCost {
    public static let minNightsEach = 2
    /// A night counts when its battery readings (not charging) span at least this long.
    public static let minSpanS: TimeInterval = 2 * 3600

    public struct Estimate: Equatable, Sendable {
        public var withRate: Double?
        public var withNights: Int
        public var withoutRate: Double?
        public var withoutNights: Int
    }

    /// %/h for one night: (first − last) / hours over its non-charging readings; nil with too little span.
    static func rate(_ readings: [BatteryReading], _ n: RawOpticalNightLog) -> Double? {
        let a = Int64(n.start.timeIntervalSince1970), b = Int64(n.end.timeIntervalSince1970)
        let r = readings.filter { $0.ts >= a && $0.ts <= b && $0.charging != true }.sorted { $0.ts < $1.ts }
        guard let f = r.first, let l = r.last, Double(l.ts - f.ts) >= minSpanS else { return nil }
        return (f.percent - l.percent) / (Double(l.ts - f.ts) / 3600)
    }

    public static func estimate(readings: [BatteryReading], nights: [RawOpticalNightLog]) -> Estimate {
        var with: [Double] = [], without: [Double] = []
        for n in nights {
            guard let r = rate(readings, n) else { continue }
            if n.frames > 0 { with.append(r) } else { without.append(r) }
        }
        func mean(_ x: [Double]) -> Double? { x.isEmpty ? nil : x.reduce(0, +) / Double(x.count) }
        return Estimate(withRate: mean(with), withNights: with.count, withoutRate: mean(without),
                        withoutNights: without.count)
    }

    public static func line(_ e: Estimate) -> String {
        guard e.withNights >= minNightsEach, e.withoutNights >= minNightsEach, let w = e.withRate,
              let o = e.withoutRate else {
            return "Battery cost: not measured yet — needs \(minNightsEach) nights with and \(minNightsEach) without "
                + "(has \(e.withNights) with, \(e.withoutNights) without)."
        }
        return "Battery cost, measured: \(MGFormat.number(w, decimals: 2)) %/h on \(e.withNights) nights with raw "
            + "optical vs \(MGFormat.number(o, decimals: 2)) %/h on \(e.withoutNights) without "
            + "(\(MetricText.signed(w - o, decimals: 2)) %/h)."
    }
}
