import Foundation
import MGDomain

/// P03: mean heart rate before vs after one logged event, from today's per-minute HR (`PresenterSnapshot.minuteHR`).
/// Every result is an estimate and its label says so (CLAUDE.md rule 4); under 5 readings on a side there is a reason,
/// never a number.
enum EventHRResponse {
    static let minSamples = 5

    struct Result: Equatable {
        /// Ends "(estimate)".
        var label: String
        var before: Double?
        var after: Double?
        /// After minus before, bpm.
        var change: Double?
        var reason: String?
    }

    /// Vape: VapeAnalysis's change over 10 min each side (the number the Log's Vape row uses). The two means are the
    /// same windows, for the chart; they exist only when VapeAnalysis found enough readings.
    static func vape(_ s: PresenterSnapshot, at t: Date, event: EventRecord?) -> Result {
        let label = "Heart-rate change in the 10 min after (estimate)"
        let est = event.flatMap {
            VapeAnalysis.analyze(events: [$0], perMinuteHeartRate: s.minuteHR, days: [], calendar: s.calendar)
                .ticks.first?.heartRateChange
        }
        guard let change = est?.value else {
            return Result(label: label, reason: est?.reason ?? "This hit is not in the log, so it is not counted.")
        }
        let before = mean(s.minuteHR) { $0 >= t.addingTimeInterval(-600) && $0 < t }
        let after = mean(s.minuteHR) { $0 > t && $0 <= t.addingTimeInterval(600) }
        return Result(label: label, before: before.mean, after: after.mean, change: change)
    }

    /// Medication: the 30 min before the dose against 60 to 120 min after it.
    static func medication(_ s: PresenterSnapshot, at t: Date) -> Result {
        let label = "Heart-rate change 60–120 min after (estimate)"
        let before = mean(s.minuteHR) { $0 >= t.addingTimeInterval(-1800) && $0 < t }
        let after = mean(s.minuteHR) { $0 >= t.addingTimeInterval(3600) && $0 <= t.addingTimeInterval(7200) }
        guard let b = before.mean, let a = after.mean, before.n >= minSamples, after.n >= minSamples else {
            return Result(label: label, reason: "needs at least \(minSamples) per-minute HR samples on each side "
                          + "(have \(before.n) before and \(after.n) after)")
        }
        return Result(label: label, before: b, after: a, change: a - b)
    }

    private static func mean(_ hr: [HRPoint], in window: (Date) -> Bool) -> (mean: Double?, n: Int) {
        let v = hr.filter { $0.bpm.isFinite && $0.bpm > 0 && window(Date(timeIntervalSince1970: Double($0.ts))) }
            .map(\.bpm)
        return (v.isEmpty ? nil : v.reduce(0, +) / Double(v.count), v.count)
    }
}
