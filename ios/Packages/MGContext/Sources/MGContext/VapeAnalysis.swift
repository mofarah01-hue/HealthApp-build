import Foundation
import MGDomain

/// T58 estimates around explicitly logged vape ticks. All inputs stay local and all reported values are estimates.
public enum VapeAnalysis {
    public struct Estimate: Equatable, Sendable {
        public var value: Double?
        public var reason: String?
        public var label: String

        init(_ label: String, value: Double? = nil, reason: String? = nil) {
            self.value = value
            self.reason = reason
            self.label = label + " (estimate)"
        }
    }

    public struct Tick: Equatable, Sendable {
        public var at: Date
        public var heartRateChange: Estimate
    }

    public struct Day: Equatable, Sendable {
        public var wake: Date
        public var wakeRestingHR: Double?

        public init(wake: Date, wakeRestingHR: Double?) {
            self.wake = wake
            self.wakeRestingHR = wakeRestingHR
        }
    }

    public struct DayResult: Equatable, Sendable {
        public var wake: Date
        public var minutesToFirstTick: Estimate
    }

    public struct Result: Equatable, Sendable {
        public var ticks: [Tick]
        public var days: [DayResult]
        public var wakeCorrelation: Estimate
    }

    /// HR points are per-minute samples. A tick needs at least five valid samples in each open ten-minute side window.
    public static func analyze(events: [EventRecord], perMinuteHeartRate: [HRPoint], days: [Day],
                               calendar: Calendar) -> Result {
        let ticks = vapeTicks(events)
        let tickResults = ticks.map { tick -> Tick in
            let before = perMinuteHeartRate.filter {
                let at = Date(timeIntervalSince1970: Double($0.ts))
                return $0.bpm.isFinite && $0.bpm > 0 && at >= tick.addingTimeInterval(-600) && at < tick
            }
            let after = perMinuteHeartRate.filter {
                let at = Date(timeIntervalSince1970: Double($0.ts))
                return $0.bpm.isFinite && $0.bpm > 0 && at > tick && at <= tick.addingTimeInterval(600)
            }
            let estimate: Estimate
            if before.count < 5 || after.count < 5 {
                estimate = Estimate("Heart-rate change, 10 min after vs 10 min before (VapeAnalysis)", reason: "needs at least 5 per-minute HR samples on each side "
                                    + "(have \(before.count) before and \(after.count) after)")
            } else {
                estimate = Estimate("Heart-rate change, 10 min after vs 10 min before (VapeAnalysis)", value: mean(after.map(\.bpm)) - mean(before.map(\.bpm)))
            }
            return Tick(at: tick, heartRateChange: estimate)
        }

        let dayResults = days.map { day -> DayResult in
            let end = days.map(\.wake).filter { $0 > day.wake }.min()
                ?? calendar.date(byAdding: .day, value: 1, to: day.wake)
                ?? day.wake.addingTimeInterval(86_400)
            let first = ticks.first { $0 >= day.wake && $0 < end }
            let estimate = first.map {
                Estimate("Minutes from wake to first vape tick", value: $0.timeIntervalSince(day.wake) / 60)
            } ?? Estimate("Minutes from wake to first vape tick", reason: "no vape tick logged after wake")
            return DayResult(wake: day.wake, minutesToFirstTick: estimate)
        }

        let pairs = zip(days, dayResults).compactMap { day, result -> (Double, Double)? in
            guard let delay = result.minutesToFirstTick.value, let rhr = day.wakeRestingHR,
                  delay.isFinite, rhr.isFinite else { return nil }
            return (delay, rhr)
        }
        let correlation: Estimate
        if pairs.count < 14 {
            correlation = Estimate("First-vape delay and wake resting-HR Spearman correlation",
                                   reason: "needs at least 14 days with a first vape tick and wake resting HR "
                                       + "(have \(pairs.count))")
        } else if let value = spearman(pairs) {
            correlation = Estimate("First-vape delay and wake resting-HR Spearman correlation", value: value)
        } else {
            correlation = Estimate("First-vape delay and wake resting-HR Spearman correlation",
                                   reason: "rank correlation needs variation in both values")
        }
        return Result(ticks: tickResults, days: dayResults, wakeCorrelation: correlation)
    }

    private static func vapeTicks(_ events: [EventRecord]) -> [Date] {
        events.compactMap { event -> Date? in
            guard !event.removed, case let .substance(fields) = event.payload,
                  fields.kind == .vapeTick || fields.kind == .vape,
                  fields.vape?.detectedStatus != .rejected else { return nil }
            return event.at
        }.sorted()
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func spearman(_ pairs: [(Double, Double)]) -> Double? {
        let x = ranks(pairs.map(\.0))
        let y = ranks(pairs.map(\.1))
        let mx = mean(x)
        let my = mean(y)
        let dx = x.map { $0 - mx }
        let dy = y.map { $0 - my }
        let denominator = sqrt(dx.map { $0 * $0 }.reduce(0, +) * dy.map { $0 * $0 }.reduce(0, +))
        guard denominator > 0 else { return nil }
        return zip(dx, dy).map { $0.0 * $0.1 }.reduce(0, +) / denominator
    }

    /// Average ranks make tied observations deterministic.
    private static func ranks(_ values: [Double]) -> [Double] {
        let sorted = values.enumerated().sorted { $0.element < $1.element }
        var result = [Double](repeating: 0, count: values.count)
        var lower = 0
        while lower < sorted.count {
            var upper = lower + 1
            while upper < sorted.count && sorted[upper].element == sorted[lower].element { upper += 1 }
            let averageRank = (Double(lower + 1) + Double(upper)) / 2
            for position in lower ..< upper { result[sorted[position].offset] = averageRank }
            lower = upper
        }
        return result
    }
}
