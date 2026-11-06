import Foundation

/// T129: what Mo is doing, as he labels it. Stored as the contract's `activity_label` event (`at` = start, `end`,
/// `label` = the kind's raw value, `note` = his optional words). Every label is also training data for a later local
/// model: `trainingData` is always true and is written in the export. Nothing here sends anything anywhere.
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case work, study, tv, exercise, social, rest, other

    public var word: String {
        switch self {
        case .tv: return "TV"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

public struct ActivityLabel: Codable, Hashable, Sendable {
    public var kind: ActivityKind
    public var at: Date
    public var end: Date
    public var note: String?
    /// Marked for the later local model (T129). A local export field only.
    public let trainingData: Bool

    public init(kind: ActivityKind, at: Date, end: Date, note: String? = nil) {
        self.kind = kind
        self.at = at
        self.end = end
        self.note = note
        self.trainingData = true
    }

    /// nil when the event is not an activity label. A label text this app does not know reads as `.other`.
    public init?(event: EventRecord) {
        guard case let .activityLabel(f) = event.payload else { return nil }
        self.init(kind: ActivityKind(rawValue: f.label) ?? .other, at: event.at, end: f.end, note: event.note)
    }

    public func event(loggedAt: Date) -> EventRecord {
        EventRecord(at: at, loggedAt: loggedAt, source: .manual, note: note,
                    payload: .activityLabel(ActivityLabelFields(end: end, label: kind.rawValue)))
    }

    enum CodingKeys: String, CodingKey {
        case kind, at, end, note
        case trainingData = "training_data"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(ActivityKind.self, forKey: .kind), at: try c.decode(Date.self, forKey: .at),
                  end: try c.decode(Date.self, forKey: .end), note: try c.decodeIfPresent(String.self, forKey: .note))
    }
}
