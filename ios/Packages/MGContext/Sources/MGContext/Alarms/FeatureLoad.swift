import Foundation

// MARK: - Strap feature load on the battery (added 2026-10-12, T107/T59)
//
// The days-left line in `BatteryEstimator` is a straight-line fit over battery % alone; it cannot tell that raw
// optical, ECG, raw motion or an offload drain the strap faster while they run. Until the app has days of feature
// on/off logged beside battery % (T107/T59 in app/docs/T-LIST-v2.md) the extra drain per feature is an ASSUMED number,
// and the estimate says "calibrating" while those numbers are in use.

/// A strap feature whose extra battery drain we model.
public enum StrapFeature: String, CaseIterable, Sendable, Codable {
    case rawOptical
    case ecg
    case rawMotion
    case offload
}

/// One interval during which a feature was on. `to == nil` means it is still on.
public struct FeatureSpan: Sendable, Equatable, Codable {
    public var feature: StrapFeature
    public var from: Date
    public var to: Date?

    public init(feature: StrapFeature, from: Date, to: Date?) {
        self.feature = feature
        self.from = from
        self.to = to
    }
}

/// Assumed (not measured) extra battery drain, in % per hour, while a feature is on.
public enum BatteryLoadModel {
    // Placeholders until the app has days of feature on/off logged beside battery %.
    public static let assumedExtraPercentPerHour: [StrapFeature: Double] = [
        .rawOptical: 0.25,
        .ecg: 0.15,
        .rawMotion: 0.10,
        .offload: 0.10,
    ]

    /// The base-rate floor (%/h) so an observed fit cannot be dragged to zero by subtracting the assumed loads.
    static let floorPercentPerHour: Double = 0.02

    /// The features on at `now`: a span whose `from` is at or before `now` and whose `to` is nil or after `now`.
    static func onNow(_ log: [FeatureSpan], now: Date) -> Set<StrapFeature> {
        var on = Set<StrapFeature>()
        for span in log where span.from <= now {
            if let to = span.to, to <= now { continue }
            on.insert(span.feature)
        }
        return on
    }

    /// Average extra %/h over [windowStart, windowEnd]: each span's assumed load times its overlap with the
    /// window, summed, divided by the window length in hours. Spans are clipped to the window; an open span
    /// (nil `to`) runs to `now` before clipping.
    static func averageExtraOverWindow(_ log: [FeatureSpan], windowStart: Date, windowEnd: Date,
                                       now: Date, loads: [StrapFeature: Double] = assumedExtraPercentPerHour) -> Double {
        let windowSeconds = windowEnd.timeIntervalSince(windowStart)
        guard windowSeconds > 0 else { return 0 }
        var extraPercent = 0.0
        for span in log {
            let load = loads[span.feature] ?? 0
            guard load > 0 else { continue }
            let from = max(span.from, windowStart)
            let to = min(span.to ?? now, windowEnd)
            guard to > from else { continue }
            extraPercent += load * (to.timeIntervalSince(from) / windowSeconds)
        }
        return extraPercent
    }

    /// The extra %/h per feature to use now: the learned value where `BatteryRateLearner` measured it, else the guess.
    static func rates(_ learned: BatteryLearnedRates?) -> [StrapFeature: Double] {
        var out = assumedExtraPercentPerHour
        for e in learned?.features ?? [] where e.measured { out[e.feature] = e.percentPerHour }
        return out
    }

    static func displayName(_ f: StrapFeature) -> String {
        switch f {
        case .rawOptical: return "raw optical"
        case .ecg: return "ECG"
        case .rawMotion: return "raw motion"
        case .offload: return "offload"
        }
    }

    /// " · raw optical on: −0.6 %/h measured over 9 h" for each feature on now ("guessed" when not measured); "" if none.
    static func note(on: Set<StrapFeature>, learned: BatteryLearnedRates?) -> String {
        var parts: [String] = []
        for f in StrapFeature.allCases where on.contains(f) {
            if let e = learned?.features.first(where: { $0.feature == f }), e.measured {
                parts.append("\(displayName(f)) on: \u{2212}\(rateText(e.percentPerHour)) %/h measured over \(hoursText(e.hours))")
            } else {
                let g = assumedExtraPercentPerHour[f] ?? 0
                parts.append("\(displayName(f)) on: \u{2212}\(rateText(g)) %/h guessed")
            }
        }
        return parts.isEmpty ? "" : " \u{00B7} " + parts.joined(separator: " \u{00B7} ")
    }

    static func rateText(_ x: Double) -> String {
        var s = String(format: "%.2f", x)
        if s.hasSuffix("0") { s.removeLast() }
        return s
    }

    static func hoursText(_ h: Double) -> String { h < 1 ? "<1 h" : "\(Int(h.rounded())) h" }
}
