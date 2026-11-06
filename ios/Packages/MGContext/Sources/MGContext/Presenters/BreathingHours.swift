import Foundation
import MGDomain

/// Breathing rate every clock hour of the shown day (W10 #95): the night's `resp_rate_hourly` (asleep) and the day's
/// `resp_rate_hourly_awake` (still minutes outside workouts), oldest first; a blank hour says why. T88: above the hours,
/// the night's average and the period's trend. A rate we derive is breaths/min labelled "estimate" (rule 4, D-025);
/// the flag is a trend hint, never a diagnosis.
enum BreathingHours {
    static let stateWords = ["asleep": "asleep", "awake_still": "awake", "awake_active": "moving — RSA needs stillness",
                             "workout": "workout — needs a second estimator that agrees", "unknown": "no strap data"]

    private static func rate(_ v: Double) -> String { MGFormat.number(v, decimals: 1) }

    /// The night's average of the asleep hours, the period trend and the out-of-range hint (each only when it has data).
    static func summary(_ s: PresenterSnapshot, _ a: MetricAnalysis?) -> [String] {
        var out: [String] = []
        let asleep = s.series.filter { $0.name == "resp_rate_hourly" }.flatMap(\.values).compactMap { $0 }.filter(\.isFinite)
        let night = asleep.isEmpty ? nil : asleep.reduce(0, +) / Double(asleep.count)
        if let night {
            out.append("Last night: \(rate(night)) breaths/min (estimate), average of \(asleep.count) hours asleep")
        }
        guard let a, let m = a.median, m.isFinite else { return out }
        let label = a.importedDays.isEmpty ? "(estimate)" : "(estimate; WHOOP's own where imported)"
        var trend = "Trend: \(rate(m)) breaths/min \(label)"
        if let p = a.previousMedian, p.isFinite {
            trend += rate(m) == rate(p) ? ", the same as before" : (m > p ? ", up" : ", down") + " from \(rate(p)) before"
        }
        out.append(trend)
        if let night, let lo = a.bandLow, let hi = a.bandHigh, night < lo || night > hi {
            out.append("\(night > hi ? "Above" : "Below") your usual range (\(rate(lo))–\(rate(hi))). A trend hint, not a diagnosis.")
        }
        return out
    }

    static func lines(_ s: PresenterSnapshot, analysis: MetricAnalysis? = nil) -> [String] {
        var rows: [(Date, String)] = []
        for name in ["resp_rate_hourly", "resp_rate_hourly_awake"] {
            for x in s.series where x.name == name {
                for (i, v) in x.values.enumerated() {
                    let at = x.start.addingTimeInterval(Double(i) * x.stepS)
                    let st = x.state.flatMap { i < $0.count ? $0[i] : nil } ?? (name == "resp_rate_hourly" ? "asleep" : "unknown")
                    let word = stateWords[st] ?? st
                    if let v, v.isFinite {
                        rows.append((at, "\(MGFormat.time(at, calendar: s.calendar)) · \(MGFormat.number(v, decimals: 1)) breaths/min (estimate) · \(word)"))
                    } else {
                        rows.append((at, "\(MGFormat.time(at, calendar: s.calendar)) · — · \(word)"))
                    }
                }
            }
        }
        return summary(s, analysis) + rows.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
