import Foundation

/// Records when each strap feature (raw optical, ECG, raw motion, offload) was on, for `BatteryEstimator.featureLog`
/// (T107/T59, 2026-10-12). The app calls `update(on:at:)` whenever it looks at the features; the recorder opens a span
/// for a feature that appeared and closes the span of one that went away.
///
/// Persisted as JSON. `lastUpdate` is the last time the app saw the features, so a span left open by a killed app is
/// closed there on restore, not at the next launch (that would claim the feature ran through the hours the app was dead).
public struct FeatureLogRecorder: Sendable, Equatable, Codable {
    public private(set) var spans: [FeatureSpan]
    public private(set) var lastUpdate: Date?

    public init() {
        spans = []
        lastUpdate = nil
    }

    public init(spans: [FeatureSpan], lastUpdate: Date?) {
        self.spans = spans
        self.lastUpdate = lastUpdate
    }

    /// From a saved recorder: every span still open is closed at `lastUpdate` (dropped if it has no time to stand on).
    public init(restoring saved: FeatureLogRecorder) {
        let end = saved.lastUpdate
        spans = saved.spans.compactMap { s in
            guard s.to == nil else { return s }
            guard let end, end > s.from else { return nil }
            return FeatureSpan(feature: s.feature, from: s.from, to: end)
        }
        lastUpdate = end
    }

    /// `on` is the set of features running right now.
    public mutating func update(on: Set<StrapFeature>, at now: Date) {
        let open = Set(spans.filter { $0.to == nil }.map(\.feature))
        for i in spans.indices where spans[i].to == nil && !on.contains(spans[i].feature) {
            spans[i].to = now
        }
        for f in StrapFeature.allCases where on.contains(f) && !open.contains(f) {
            spans.append(FeatureSpan(feature: f, from: now, to: nil))
        }
        lastUpdate = now
    }

    /// Drops closed spans that ended before `date`; open spans stay.
    public mutating func prune(keepingSince date: Date) {
        spans.removeAll { s in s.to.map { $0 < date } ?? false }
    }
}
