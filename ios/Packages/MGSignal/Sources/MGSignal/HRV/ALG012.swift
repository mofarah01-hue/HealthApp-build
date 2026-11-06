import Foundation
import MGDomain

/// ALG-012 — resting HR (v1), day-average HR (v1) and the overnight HR dip (v2, 2026-10-17, D-HRV-WALK-2). HR-recovery τ
/// is its own file. Python reference: app/pclab/mglab/ref/hrv.py `resting_hr`, `hr_avg`, `hr_dip`, `dip_day_pick`,
/// `hr_dip_trend`; goldens app/shared/golden/hrv/ALG-012.json. HR ≤ 0 is off-skin and never counts as bradycardia.
public enum ALG012 {
    public static let citation = "Avram 2019 (lowest 30-min nocturnal HR); dip: Ben-Dov et al., Arch Intern Med 2007;167:2116-21 "
        + "(blunted dip < 10 %, n = 3,957 ambulatory-monitoring referrals; CHAMP1ON diabetes cohort n = 349)"
    public static let windowSeconds: Int64 = 1800
    public static let minCoverage = 0.9
    public static let minSamples = 300

    /// On-skin samples sorted by (ts, bpm).
    static func valid(ts: [Int64], bpm: [Double]) -> (ts: [Int64], bpm: [Double]) {
        var pairs: [(Int64, Double)] = []
        for i in 0..<min(ts.count, bpm.count) where bpm[i].isFinite && bpm[i] > 0 {
            pairs.append((ts[i], bpm[i]))
        }
        pairs.sort { $0 < $1 }
        return (pairs.map { $0.0 }, pairs.map { $0.1 })
    }

    /// ALG-012 v1 — resting HR = lowest 30-min mean of on-skin HR in the sleep window. The window slides over
    /// wall-clock time: for each sample as the end, it holds the valid samples with end − 1800 < ts ≤ end, and counts
    /// when it holds at least ⌈0.9 · 1800 / cadence⌉ of them (cadence = median step between valid samples; 1 s for
    /// the strap). Missing when no window qualifies.
    public static func restingHR(ts: [Int64], bpm: [Double]) -> Computed<Double> {
        let v = valid(ts: ts, bpm: bpm)
        let t = v.ts
        let b = v.bpm
        guard t.count >= 2 else { return .missing("no on-skin heart rate in the sleep window") }
        var steps: [Double] = []
        for i in 0..<(t.count - 1) where t[i + 1] > t[i] { steps.append(Double(t[i + 1] - t[i])) }
        guard !steps.isEmpty else { return .missing("heart-rate timestamps do not advance") }
        let cadence = SignalMath.median(steps)
        let need = Int((minCoverage * Double(windowSeconds) / cadence).rounded(.up))
        var best: Double?
        var lo = 0
        var sum = 0.0
        for hi in 0..<t.count {
            sum += b[hi]
            while t[hi] - t[lo] >= windowSeconds {
                sum -= b[lo]
                lo += 1
            }
            let count = hi - lo + 1
            if count >= need {
                let m = sum / Double(count)
                if best == nil || m < best! { best = m }
            }
        }
        guard let best else { return .missing("no 30-min stretch with 90 % on-skin heart rate in the sleep window") }
        return .success(best)
    }

    public static func restingHR(_ samples: [HRPoint]) -> Computed<Double> {
        restingHR(ts: samples.map(\.ts), bpm: samples.map(\.bpm))
    }

    /// ALG-012 v1 — mean of on-skin HR over a span (≥ 300 valid samples).
    public static func average(ts: [Int64], bpm: [Double]) -> Computed<Double> {
        let b = valid(ts: ts, bpm: bpm).bpm
        guard b.count >= minSamples else {
            return .missing("needs \(minSamples) on-skin heart-rate samples (have \(b.count))")
        }
        return .success(SignalMath.mean(b))
    }

    public static func average(_ samples: [HRPoint]) -> Computed<Double> {
        average(ts: samples.map(\.ts), bpm: samples.map(\.bpm))
    }

    // MARK: night HR dip (v2)

    /// A clock minute counts when it holds at least this many on-skin samples (half a minute at the strap's 1 Hz; ours).
    public static let dipMinuteMinSamples = 30
    /// Sleep side: at least 4 h of strap-asleep minutes; day side: at least 6 h of awake minutes (ours).
    public static let dipNightMinMinutes = 240
    public static let dipDayMinMinutes = 360
    /// "Blunted" below 10 % (the cut-off of Ben-Dov 2007 and the CHAMP1ON cohort). Not a risk score.
    public static let dipBluntedBelowPct = 10.0
    public static let dipTrendNights = 14
    /// D-POP-PRIOR: the usual dip starts at the population reference (the published 10 % cut-off; no population mean was
    /// checked) and moves toward your own nights: weight n / (n + k) on you, k = 7 (ours).
    public static let dipPopulationPct = 10.0
    public static let dipPriorNights = 7

    public struct Dip: Sendable, Equatable {
        public var dip: Double
        public var dayBpm: Double
        public var nightBpm: Double
        public var dayMinutes: Int
        public var nightMinutes: Int
        public var blunted: Bool { dip < ALG012.dipBluntedBelowPct }
    }

    /// Clock minute (unix s ÷ 60) → median of that minute's on-skin HR, for minutes with at least 30 samples; in minute order.
    static func minuteMedians(ts: [Int64], bpm: [Double]) -> [(minute: Int64, bpm: Double)] {
        let v = valid(ts: ts, bpm: bpm)
        var buckets: [Int64: [Double]] = [:]
        for i in 0..<v.ts.count { buckets[v.ts[i] / 60, default: []].append(v.bpm[i]) }
        return buckets.keys.sorted().compactMap { m in
            let x = buckets[m]!
            return x.count >= dipMinuteMinSamples ? (m, SignalMath.median(x)) : nil
        }
    }

    /// ALG-012 v2 — night HR dip % = (mean day HR − mean sleep HR) / mean day HR × 100 over 1-minute medians (spikes cannot
    /// move it). Needs ≥ 240 sleep minutes and ≥ 360 day minutes. Descriptive: a trend against your own nights, no risk
    /// score (the outcome evidence is between people, not within one person).
    public static func dip(dayTs: [Int64], dayBpm: [Double], nightTs: [Int64], nightBpm: [Double]) -> Computed<Dip> {
        let d = minuteMedians(ts: dayTs, bpm: dayBpm)
        guard d.count >= dipDayMinMinutes else {
            return .missing("day side: needs \(dipDayMinMinutes) awake minutes of heart rate (have \(d.count))")
        }
        let n = minuteMedians(ts: nightTs, bpm: nightBpm)
        guard n.count >= dipNightMinMinutes else {
            return .missing("night side: needs \(dipNightMinMinutes) asleep minutes of heart rate (have \(n.count))")
        }
        let dm = SignalMath.mean(d.map(\.bpm))
        let nm = SignalMath.mean(n.map(\.bpm))
        return .success(Dip(dip: (dm - nm) / dm * 100.0, dayBpm: dm, nightBpm: nm, dayMinutes: d.count, nightMinutes: n.count))
    }

    public static func dip(day: [HRPoint], night: [HRPoint]) -> Computed<Dip> {
        dip(dayTs: day.map(\.ts), dayBpm: day.map(\.bpm), nightTs: night.map(\.ts), nightBpm: night.map(\.bpm))
    }

    public struct DayPick: Sendable, Equatable {
        /// "daytime" (inside the 10:00-20:00 local window) or "awake" (all awake heart rate before sleep).
        public var basis: String
        public var minutes: Int
        public var ts: [Int64]
        public var bpm: [Double]
    }

    /// The day side of the dip: the awake HR inside [winStart, winEnd) (10:00-20:00 local of the day before the night) when it
    /// holds ≥ 360 minutes, else all the awake HR given when that does, else missing.
    public static func dipDayPick(awakeTs: [Int64], awakeBpm: [Double], winStart: Int64, winEnd: Int64) -> Computed<DayPick> {
        let v = valid(ts: awakeTs, bpm: awakeBpm)
        var inTs: [Int64] = []
        var inBpm: [Double] = []
        for i in 0..<v.ts.count where v.ts[i] >= winStart && v.ts[i] < winEnd {
            inTs.append(v.ts[i])
            inBpm.append(v.bpm[i])
        }
        let nIn = minuteMedians(ts: inTs, bpm: inBpm).count
        if nIn >= dipDayMinMinutes { return .success(DayPick(basis: "daytime", minutes: nIn, ts: inTs, bpm: inBpm)) }
        let nAll = minuteMedians(ts: v.ts, bpm: v.bpm).count
        if nAll >= dipDayMinMinutes { return .success(DayPick(basis: "awake", minutes: nAll, ts: v.ts, bpm: v.bpm)) }
        return .missing("day side: needs \(dipDayMinMinutes) awake minutes of heart rate (have \(nIn) between 10:00 and 20:00, "
                        + "\(nAll) awake in all)")
    }

    public struct DipTrend: Sendable, Equatable {
        public var baseline: Double
        public var delta: Double
        public var nights: Int
        /// n / (n + k): how much of the baseline is yours.
        public var weightOwn: Double
        /// "population" when no night of yours is in it yet, else "yours".
        public var basis: String
        public var blunted: Bool
    }

    /// Tonight's dip against your usual: starts at the population value and moves toward the mean of your last 14 nights
    /// (`prior`, oldest first, nil = no dip that night): baseline = (n x own mean + 7 x 10) / (n + 7).
    public static func dipTrend(prior: [Double?], today: Double) -> Computed<DipTrend> {
        let vals = prior.suffix(dipTrendNights).compactMap { v -> Double? in
            guard let v, v.isFinite else { return nil }
            return v
        }
        let n = Double(vals.count)
        let own = vals.isEmpty ? 0.0 : SignalMath.mean(vals)
        let k = Double(dipPriorNights)
        let base = (n * own + k * dipPopulationPct) / (n + k)
        return .success(DipTrend(baseline: base, delta: today - base, nights: vals.count, weightOwn: n / (n + k),
                                 basis: vals.isEmpty ? "population" : "yours", blunted: today < dipBluntedBelowPct))
    }

    /// The words under the number: the dip, "blunted" when below 10 %, the trend against your own nights, how it was
    /// measured. Never a risk statement.
    public static func dipNote(_ d: Dip, basis: String, trend: Computed<DipTrend>) -> String {
        func f(_ v: Double, _ dec: Int = 1) -> String { String(format: "%.\(dec)f", v) }
        var parts: [String] = []
        parts.append(d.blunted ? "blunted: sleep heart rate is less than 10 % below the day's" : "heart rate drops 10 % or more in sleep")
        switch trend {
        case .success(let t):
            let dir = t.delta >= 0 ? "above" : "below"
            let who = t.basis == "population" ? "population value, none of your nights yet"
                : "yours (\(t.nights) nights), pulled toward the population value until there are more"
            parts.append("usual dip \(f(t.baseline)) % (\(who)); tonight \(f(abs(t.delta))) points \(dir) it")
        case .failure(let m):
            parts.append(m.reason)
        }
        let dayWords = basis == "daytime" ? "awake 10:00 to 20:00" : "all awake hours"
        parts.append("day \(f(d.dayBpm, 0)) bpm (\(dayWords)) vs sleep \(f(d.nightBpm, 0)) bpm, 1-minute medians; "
                     + "descriptive, not a risk score")
        return parts.joined(separator: " · ")
    }

    public static let rhrSpec = MetricSpec(
        key: .rhr, unit: "bpm", group: nil, variant: "ALG-012", method: "ALG-012@1 lowest-30min-mean", tier: .high,
        source: "hr", window: "night", citation: citation, paramsVersion: "w1800s cov0.9")
    public static let hrAvgSpec = MetricSpec(
        key: .hrAvg, unit: "bpm", group: nil, variant: "ALG-012", method: "ALG-012@1 mean-on-skin", tier: .high,
        source: "hr", window: "day", citation: citation, paramsVersion: "min300")
    public static let hrDipSpec = MetricSpec(
        key: .hrDip, unit: "%", group: nil, variant: "ALG-012", method: "ALG-012@2 day-night-dip-1min-medians", tier: .high,
        source: "hr", window: "night", citation: citation, paramsVersion: "min30per-minute night240 day360 blunted<10")
}
