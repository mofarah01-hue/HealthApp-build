import Foundation

/// A plain read-out screen (W10, 2026-10-11): a header, sections of rows (a headline, an optional value on the right,
/// plain lines under it, an optional tap), and actions. Used by "Your ages" and the three Live research screens
/// (record inspector, capture session, raw retention); UI/Info/InfoScreenView.swift draws it.
public struct InfoScreenState: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var value: String?
        public var lines: [String]
        public var intent: UIIntent?

        public init(id: String, title: String, value: String? = nil, lines: [String] = [], intent: UIIntent? = nil) {
            self.id = id
            self.title = title
            self.value = value
            self.lines = lines
            self.intent = intent
        }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var note: String?
        public var rows: [Row]

        public init(id: String, title: String, note: String? = nil, rows: [Row]) {
            self.id = id
            self.title = title
            self.note = note
            self.rows = rows
        }
    }

    public var sample: Bool
    public var kicker: String
    public var title: String
    public var summary: String?
    public var sections: [Section]
    public var actions: [ActionState]
    /// A text field above the actions (capture label); nil = none. The view sends `textIntent(text)`.
    public var textPrompt: String?

    public init(sample: Bool, kicker: String, title: String, summary: String? = nil, sections: [Section],
                actions: [ActionState] = [], textPrompt: String? = nil) {
        self.sample = sample
        self.kicker = kicker
        self.title = title
        self.summary = summary
        self.sections = sections
        self.actions = actions
        self.textPrompt = textPrompt
    }
}
