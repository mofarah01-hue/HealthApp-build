import Foundation

/// r9t (D-POP-PRIOR): the words and readers that say whose number a personal value is. Shared by the algorithm that writes
/// them (MGSignal) and the presenters that show them (MGContext imports MGDomain only).
public enum PersonalBasis {
    /// "yours (21 nights)": a baseline made only of his own nights (a skin-temperature count has no population value).
    public static func nightsWords(_ nights: Int) -> String { "yours (\(nights) \(nights == 1 ? "night" : "nights"))" }

    /// The N in `nightsWords` out of a metric note; nil when the note has none.
    public static func nights(inNote note: String?) -> Int? {
        guard let note, let r = note.range(of: #"yours \((\d+) nights?\)"#, options: .regularExpression) else { return nil }
        return Int(note[r].filter(\.isNumber))
    }
}

/// The caffeine half-life the "caffeine in you" curve uses: the population 5 h, or his own from the PC's ALG-062 fit.
///
/// The learning runs on the PC (`pc.caffeine-personal@1`, `pclab/mglab/alg/caffeine_personal.py`): a grid posterior of the
/// half-life from his total sleep against the caffeine on board at sleep onset (Drake 2013) and from his PVT-B reaction times,
/// starting from the population prior (lognormal, median 5 h, IOM 2001 range 1.5-9.5 h). A posterior IS the shrinkage
/// D-POP-PRIOR asks for: with no usable log it equals the prior, and each night or test moves it toward his own value as far
/// as the data pin it down. The PC marks a fit with `params_version` `posterior;logs=N` (N = nights plus tests the fit used)
/// and the prior with `prior-lognormal-5h`. This type only reads that metric: anything missing, outside the PC's own 1-15 h
/// grid or not finite is the population value, never a blank and never an invented number.
public struct CaffeineHalfLife: Sendable, Equatable {
    public static let populationHours = 5.0
    public static let variant = "ALG-062"
    public static let plausibleHours: ClosedRange<Double> = 1.0...15.0

    public var hours: Double
    /// Nights plus reaction tests the fit used; nil = population value, or a fit from before the PC wrote the count.
    public var logs: Int?
    public var isYours: Bool
    /// 80 % interval of the posterior (hours), when the PC sent one.
    public var low: Double?
    public var high: Double?

    public static let population = CaffeineHalfLife(hours: populationHours, logs: nil, isYours: false, low: nil, high: nil)

    /// "population 5 h", or "yours 4.2 h (23 logs)".
    public var words: String {
        guard isYours else { return "population \(Self.hoursText(hours)) h" }
        let n = logs.map { " (\($0) \($0 == 1 ? "log" : "logs"))" } ?? ""
        return "yours \(Self.hoursText(hours)) h\(n)"
    }

    /// The line the caffeine panels show: both numbers, so the move away from the prior is visible.
    public var line: String {
        isYours
            ? "Half-life: \(words) · population \(Self.hoursText(Self.populationHours)) h."
            : "Half-life: \(words) until your own nights and reaction tests say otherwise."
    }

    /// The newest stored `caffeine_half_life` / ALG-062 metric, as the half-life the curve should use.
    public static func from(_ metrics: [Metric]) -> CaffeineHalfLife {
        let mine = metrics.filter { $0.name == MetricKey.caffeineHalfLife.rawValue && $0.variant == variant }
        guard let m = mine.max(by: { $0.at < $1.at }) else { return .population }
        return from(m)
    }

    public static func from(_ m: Metric) -> CaffeineHalfLife {
        guard let v = m.value, v.isFinite, plausibleHours.contains(v),
              let pv = m.paramsVersion, pv.hasPrefix("posterior") else { return .population }
        let logs = pv.split(separator: ";").compactMap { part -> Int? in
            part.hasPrefix("logs=") ? Int(part.dropFirst(5)) : nil
        }.first
        if let logs, logs <= 0 { return .population }
        return CaffeineHalfLife(hours: v, logs: logs, isYours: true, low: m.uncertainty?.low, high: m.uncertainty?.high)
    }

    static func hoursText(_ h: Double) -> String {
        let r = (h * 10).rounded() / 10
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }
}
