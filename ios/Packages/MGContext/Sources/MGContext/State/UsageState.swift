import Foundation

/// Settings › Usage (tracker #40): phone storage, background runs, the app's own compute, and the PC's storage and
/// compute with the time of its answer ("PC not reachable" when there is none). Built by `UsagePresenter`.
public struct UsageState: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var value: String
        public var detail: String?
        /// Indented under the row above (a part of it, not added to the total).
        public var isPart: Bool

        public init(id: String, title: String, value: String, detail: String? = nil, isPart: Bool = false) {
            self.id = id
            self.title = title
            self.value = value
            self.detail = detail
            self.isPart = isPart
        }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var note: String?
        public var rows: [Row]
        /// Shown instead of rows (or under them) when a part could not be measured.
        public var message: String?

        public init(id: String, title: String, note: String? = nil, rows: [Row], message: String? = nil) {
            self.id = id
            self.title = title
            self.note = note
            self.rows = rows
            self.message = message
        }
    }

    public var sample: Bool
    /// "Measured 14:05".
    public var measured: String
    public var sections: [Section]
    public var refresh: ActionState
    /// U2 (r8p): one plain line when nothing could be measured and no measuring is running; nil otherwise.
    public var failure: String? = nil

    public init(sample: Bool, measured: String, sections: [Section], refresh: ActionState) {
        self.sample = sample
        self.measured = measured
        self.sections = sections
        self.refresh = refresh
    }
}
