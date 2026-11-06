import Foundation
import MGDomain

// MARK: - Strap battery: percent + estimated time left (added 2026-10-11)
//
// Mo (2026-10-11): "battery estimated remaining with percentage would be nice — days, times, and if it's low hours,
// dynamic". Ours, v1: a least-squares line through the stored battery readings (MGStore `battery`: the 0x2A19 read on
// every connect and the strap's BATTERY_LEVEL events) since the last charge, at most `lookbackHours` back. Discharging
// needs `minSpanHours` and a drop of `minDropPoints` before it says anything; charging needs a rise over
// `minChargeSpanMinutes`. Below that it says "estimating" — never a number from two readings.

public struct BatteryEstimate: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case discharging(hoursLeft: Double, percentPerHour: Double)
        /// nil when the charge rate is not known yet.
        case charging(hoursToFull: Double?)
        case full
        case unknown(String)
    }

    public var percent: Double?
    public var state: State
    /// The instant the battery is expected to be empty (discharging) or full (charging).
    public var at: Date?
    /// For Strap & sync: "≈ 9 days left (empty ~Wed)", "≈ 14 h left (empty ~21:30)", "Charging — full in ~1.0 h."
    public var words: String
    /// For the Today chip: "9 d", "14 h", "40 min", "full in 1 h", "charging".
    public var short: String?
}

public enum BatteryEstimator {
    /// A week of readings (was 72 h): the fit is robust, and a longer window keeps the number from jumping between opens.
    public static let lookbackHours: Double = 168
    public static let minSpanHours: Double = 3
    public static let minDropPoints: Double = 2
    public static let minChargeSpanMinutes: Double = 10
    /// A rise of this much between two readings means a charge happened in between.
    public static let chargeJumpPoints: Double = 2

    /// - Parameters:
    ///   - readings: stored battery readings (any order, any age).
    ///   - chargingNow: the live charging state (strap events 7 / 8) when known; it wins over the readings' flags.
    ///   - featureLog: when/which strap features (raw optical, ECG, raw motion, offload) were on. Empty (the
    ///     default) gives exactly the old feature-blind answer; non-empty applies the assumed extra-drain model
    ///     (see `BatteryLoadModel`); the words say "measured" or "guessed" per feature that is on.
    ///   - learned: the per-feature extra drain `BatteryRateLearner` measured; features not in it use the guess.
    public static func estimate(_ readings: [BatteryReading], now: Date, chargingNow: Bool?,
                                calendar: Calendar, featureLog: [FeatureSpan] = [],
                                learned: BatteryLearnedRates? = nil) -> BatteryEstimate {
        let since = now.timeIntervalSince1970 - lookbackHours * 3600
        var r = readings.filter { Double($0.ts) >= since && Double($0.ts) <= now.timeIntervalSince1970 + 60
            && $0.percent.isFinite && (0...100).contains($0.percent) }
        r.sort { $0.ts < $1.ts }
        guard let last = r.last else {
            return BatteryEstimate(percent: nil, state: .unknown("no battery reading yet"), at: nil,
                                   words: "No battery reading yet.", short: nil)
        }
        let p = last.percent
        let charging = chargingNow ?? last.charging ?? risingTail(r)
        if charging {
            if p >= 99.5 {
                return BatteryEstimate(percent: p, state: .full, at: nil, words: "Charged (100 %).", short: "full")
            }
            let seg = chargeSegment(r)
            if let (slope, spanH) = fit(seg), spanH * 60 >= minChargeSpanMinutes, slope > 0.1 {
                let h = (100 - p) / slope
                let at = now.addingTimeInterval(h * 3600)
                return BatteryEstimate(percent: p, state: .charging(hoursToFull: h), at: at,
                                       words: "Charging — full in ~\(duration(h)).", short: "full in \(duration(h))")
            }
            return BatteryEstimate(percent: p, state: .charging(hoursToFull: nil), at: nil,
                                   words: "Charging.", short: "charging")
        }
        let seg = dischargeSegment(r)
        guard let (slope, spanH) = robustFit(seg), let first = seg.first else {
            return estimating(p)
        }
        let drop = first.percent - p
        guard spanH >= minSpanHours, drop >= minDropPoints, slope < 0 else { return estimating(p) }
        // Feature-load model (T107/T59): the fitted rate includes whatever extra the logged features drained
        // while they were on, and days-left should instead project with the features that are on *now*. Strip
        // the window-averaged extra off the observed rate (floored, so the fit cannot be dragged under it), add
        // back the extra of the features on at `now`, and only the resulting rate drives the projection.
        var rate = -slope
        var loadNote = ""
        if !featureLog.isEmpty {
            // The slope was measured over first..last reading, so average the extra over exactly that span
            // (not "the last spanH hours before now": the newest reading can be hours old).
            let windowStart = Date(timeIntervalSince1970: Double(first.ts))
            let windowEnd = Date(timeIntervalSince1970: Double(seg.last?.ts ?? first.ts))
            let loads = BatteryLoadModel.rates(learned)
            let extraWindow = BatteryLoadModel.averageExtraOverWindow(featureLog, windowStart: windowStart,
                                                                       windowEnd: windowEnd, now: now, loads: loads)
            let on = BatteryLoadModel.onNow(featureLog, now: now)
            let extraNow = on.reduce(0) { $0 + (loads[$1] ?? 0) }
            loadNote = BatteryLoadModel.note(on: on, learned: learned)
            rate = max(rate - extraWindow, BatteryLoadModel.floorPercentPerHour) + extraNow
        }
        let hoursLeft = p / rate
        let at = now.addingTimeInterval(hoursLeft * 3600)
        let day = MGFormat.weekdayMid[(calendar.component(.weekday, from: at) - 1) % 7]
        let when = hoursLeft < 24 ? MGFormat.time(at, calendar: calendar)
            : hoursLeft < 72 ? day + " " + MGFormat.time(at, calendar: calendar) : day
        return BatteryEstimate(percent: p, state: .discharging(hoursLeft: hoursLeft, percentPerHour: rate), at: at,
                               words: "≈ \(longDuration(hoursLeft)) left (empty ~\(when))\(loadNote).",
                               short: shortDuration(hoursLeft))
    }

    static func estimating(_ p: Double) -> BatteryEstimate {
        BatteryEstimate(percent: p, state: .unknown("needs a few more hours of readings"), at: nil,
                        words: "Estimating time left — needs a few more hours of readings.", short: nil)
    }

    /// The readings after the last charge: after the last reading flagged charging, or after the last rise of
    /// `chargeJumpPoints` or more between neighbours.
    static func dischargeSegment(_ r: [BatteryReading]) -> [BatteryReading] {
        var start = 0
        for i in r.indices {
            if r[i].charging == true { start = i + 1 }
            if i > 0, r[i].percent - r[i - 1].percent >= chargeJumpPoints { start = i }
        }
        return start < r.count ? Array(r[start...]) : []
    }

    /// The trailing non-decreasing run (1 point of noise allowed), at most 6 h.
    static func chargeSegment(_ r: [BatteryReading]) -> [BatteryReading] {
        guard let last = r.last else { return [] }
        var i = r.count - 1
        while i > 0, r[i - 1].percent <= r[i].percent + 1, last.ts - r[i - 1].ts <= 6 * 3600 { i -= 1 }
        return Array(r[i...])
    }

    static func risingTail(_ r: [BatteryReading]) -> Bool {
        guard r.count >= 2 else { return false }
        return r[r.count - 1].percent - r[r.count - 2].percent >= chargeJumpPoints
    }

    /// Theil-Sen slope (median of the pairwise slopes, pairs at least an hour apart) and the span in hours: one odd
    /// reading moves it far less than the least-squares line does. Falls back to `fit` when no pair is an hour apart.
    static func robustFit(_ seg: [BatteryReading]) -> (Double, Double)? {
        guard let ls = fit(seg) else { return nil }
        let stride = max(1, seg.count / 120)
        let pts = seg.enumerated().filter { $0.offset % stride == 0 || $0.offset == seg.count - 1 }.map(\.element)
        var slopes: [Double] = []
        for i in pts.indices {
            for j in (i + 1)..<max(pts.count, i + 1) {
                let dt = Double(pts[j].ts - pts[i].ts) / 3600
                if dt >= 1 { slopes.append((pts[j].percent - pts[i].percent) / dt) }
            }
        }
        guard slopes.count >= 3 else { return ls }
        slopes.sort()
        let m = slopes.count % 2 == 1 ? slopes[slopes.count / 2] : (slopes[slopes.count / 2 - 1] + slopes[slopes.count / 2]) / 2
        return (m, ls.1)
    }

    /// Least-squares slope (percent per hour) and the span in hours; nil for fewer than 2 distinct instants.
    static func fit(_ seg: [BatteryReading]) -> (Double, Double)? {
        guard seg.count >= 2, let t0 = seg.first?.ts, let t1 = seg.last?.ts, t1 > t0 else { return nil }
        let xs = seg.map { Double($0.ts - t0) / 3600 }
        let ys = seg.map(\.percent)
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0
        var sxx = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
        }
        guard sxx > 0 else { return nil }
        return (sxy / sxx, Double(t1 - t0) / 3600)
    }

    /// "11 days", "2.5 days", "14 h", "40 min".
    static func longDuration(_ hours: Double) -> String {
        if hours >= 240 { return "\(Int((hours / 24).rounded())) days" }
        if hours >= 24 { return "\(MGFormat.number(hours / 24, decimals: 1)) days" }
        if hours >= 1 { return "\(Int(hours.rounded())) h" }
        return "\(max(1, Int((hours * 60).rounded()))) min"
    }

    static func shortDuration(_ hours: Double) -> String {
        if hours >= 24 { return "\(Int((hours / 24).rounded())) d" }
        if hours >= 1 { return "\(Int(hours.rounded())) h" }
        return "\(max(1, Int((hours * 60).rounded()))) min"
    }

    /// "1.5 h", "40 min".
    static func duration(_ hours: Double) -> String {
        if hours >= 1 { return "\(MGFormat.number(hours, decimals: hours < 10 ? 1 : 0)) h" }
        return "\(max(1, Int((hours * 60).rounded()))) min"
    }
}
