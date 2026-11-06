import Foundation
import MGDomain

/// T129: the saved activity labels (what Mo says he is doing), and a rule-based "push or relax" suggestion, with
/// "watch TV" as the relax example. Labels stay on the phone; the export is a local file. No model is called here:
/// `OnDeviceModelHook` (T83) is where a learned model plugs in later, once enough weeks of labels exist.
public enum ActivityLabels {
    /// The labels in `events` (removed ones skipped), oldest first.
    public static func from(events: [EventRecord]) -> [ActivityLabel] {
        events.filter { !$0.removed }.compactMap { ActivityLabel(event: $0) }.sorted { $0.at < $1.at }
    }

    /// How many labels of each kind in the `days` before `now` (T126 chronic stress takes this as an optional input).
    public static func countByKind(_ labels: [ActivityLabel], now: Date, days: Int = 28) -> [ActivityKind: Int] {
        let from = now.addingTimeInterval(-Double(days) * 86_400)
        var out: [ActivityKind: Int] = [:]
        for l in labels where l.at > from && l.at <= now { out[l.kind, default: 0] += 1 }
        return out
    }

    /// The local training-data export: a JSON array, each row marked `training_data: true`.
    public static func exportJSON(_ labels: [ActivityLabel]) throws -> Data {
        try MGJSON.encoder().encode(labels)
    }
}

/// Points per signal; push needs `pushAtScore` or more. Named defaults, not fitted to anyone (D-046-T129).
public enum PushOrRelax {
    /// Weeks of labels before a learned model may replace the rules.
    public static let minLabelWeeks = 4.0
    /// Acute stress (ALG-123:daytime, 0-3; 1.5 is your usual): at or above is high, at or below is calm.
    public static let highStressAt = 2.0
    public static let calmStressAt = 1.0
    /// Local hours when the advice is always relax.
    public static let windDownHour = 21
    public static let wakeHour = 6
    public static let pushAtScore = 2

    public enum Advice: Sendable { case push, relax }

    public struct Suggestion: Equatable, Sendable {
        public var advice: Advice?
        public var text: String
        /// Why there is no advice, nil otherwise.
        public var reason: String?
        public var labelWeeks: Double
        public var enoughLabels: Bool
    }

    public static func make(_ s: PresenterSnapshot, labels: [ActivityLabel]) -> Suggestion {
        let weeks = labels.map(\.at).min().map { max(0, s.now.timeIntervalSince($0)) / (7 * 86_400) } ?? 0
        let enough = weeks >= minLabelWeeks
        let status = enough
            ? "rule-based; \(Int(weeks)) weeks of labels are ready for a local model, which is not connected yet"
            : "rule-based, not learned yet: \(Int(weeks)) of \(Int(minLabelWeeks)) weeks of labels"

        let stress = s.metrics.first { $0.name == MetricKey.stress.rawValue && $0.variant == "ALG-123:daytime"
            && ($0.value?.isFinite ?? false) }?.value
        let guidance = WorkoutGuidance.make(s)
        guard stress != nil || guidance.band != nil else {
            let why = "No daytime body-arousal score and no readiness yet."
            return Suggestion(advice: nil, text: "\(why) (\(status))", reason: why, labelWeeks: weeks, enoughLabels: enough)
        }

        var score = 0
        var parts: [String] = []
        if let stress {
            if stress >= highStressAt { score -= 2; parts.append("body arousal is high") }
            else if stress <= calmStressAt { score += 1; parts.append("body arousal is calm") }
        }
        switch guidance.band {
        case .hard: score += 2; parts.append("readiness is high")
        case .moderate: score += 1
        case .light: score -= 1
        case .rest: score -= 2; parts.append("readiness is low")
        case nil: break
        }
        if guidance.remaining == 0 { score -= 1; parts.append("today's effort is already reached") }
        let hour = s.calendar.component(.hour, from: s.now)
        if hour >= windDownHour || hour < wakeHour { score -= 2; parts.append("it is late") }

        let advice: Advice = score >= pushAtScore ? .push : .relax
        let because = parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
        let head = advice == .push ? "Push: a good time for focused work or study" : "Relax: a good time to watch TV or rest"
        return Suggestion(advice: advice, text: "\(head)\(because); \(status).",
                          reason: nil, labelWeeks: weeks, enoughLabels: enough)
    }
}
