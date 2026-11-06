import Foundation
import MGDomain

/// How one algorithm writes one registry metric (ARCHITECTURE.md 4.6 "Output for anything shown is a Metric",
/// 8.3 names). Every family builds its `Metric`s through this so the fields are filled the same way everywhere:
/// computedOn `.phone`, a `method` like "ALG-010@1 rmssd-task-force", group + variant, producer, tier, params version,
/// and — when the value is missing — `Metric.blank` with the reason (R6).
public struct MetricSpec: Sendable, Hashable {
    public var key: MetricKey
    public var unit: String
    public var group: String?
    public var variant: String
    public var method: String
    public var tier: Tier
    public var source: String
    public var window: String
    public var producer: Producer
    public var citation: String?
    public var paramsVersion: String?

    public init(key: MetricKey, unit: String, group: String?, variant: String, method: String, tier: Tier,
                source: String, window: String, producer: Producer = .ours, citation: String? = nil,
                paramsVersion: String? = nil) {
        self.key = key
        self.unit = unit
        self.group = group
        self.variant = variant
        self.method = method
        self.tier = tier
        self.source = source
        self.window = window
        self.producer = producer
        self.citation = citation
        self.paramsVersion = paramsVersion
    }

    /// The metric for `value`: a number, or a blank carrying the reason. A non-finite number becomes a blank too.
    public func metric(_ value: Computed<Double>, at: Date, coverage: Double? = nil, note: String? = nil) -> Metric {
        switch value {
        case .success(let v) where v.isFinite:
            return Metric(name: key.rawValue, value: v, unit: unit, tier: tier, source: source, method: method,
                          citation: citation, window: window, computedOn: .phone, at: at, note: note, group: group,
                          variant: variant, producer: producer, paramsVersion: paramsVersion,
                          coverage: coverage.map { min(max($0, 0), 1) })
        case .success(let v):
            return blank("computed value is not finite (\(v))", at: at)
        case .failure(let m):
            return blank(m.reason, at: at)
        }
    }

    /// A blank with its reason (R6), keeping method, citation and params so the row says what was attempted.
    public func blank(_ reason: String, at: Date) -> Metric {
        var m = Metric.blank(name: key.rawValue, unit: unit, tier: tier, source: source, computedOn: .phone, at: at,
                             reason: reason, group: group, variant: variant)
        m.method = method
        m.citation = citation
        m.window = window
        m.producer = producer
        m.paramsVersion = paramsVersion
        return m
    }
}
