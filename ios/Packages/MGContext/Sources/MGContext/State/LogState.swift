import Foundation
import MGDomain

/// The Log tab (UX §7). Rows keep a stable order; only each row's primary button changes.
public struct LogState: Equatable, Sendable {
    public var sample: Bool
    /// "{n} to confirm" chip in the header.
    public var confirmCount: Int
    /// Detected vape hits "Vape hit 10:31?" [Yes] [No]; skipped nap/workout questions land here too.
    public var confirmList: [ConfirmItem]
    /// In `LogItemID` order.
    public var items: [LogItemRow]
    /// Today's entries in time order (Vernier spine).
    public var spine: [SpineEntry]
    /// Collapsed by default; nil until built.
    public var monthGrid: MonthGridState?

    public init(sample: Bool, confirmCount: Int, confirmList: [ConfirmItem], items: [LogItemRow], spine: [SpineEntry],
                monthGrid: MonthGridState?) {
        self.sample = sample
        self.confirmCount = confirmCount
        self.confirmList = confirmList
        self.items = items
        self.spine = spine
        self.monthGrid = monthGrid
    }
}

public struct ConfirmItem: Equatable, Sendable, Identifiable {
    public var id: String
    /// "Vape hit 10:31?"
    public var title: String
    public var yes: UIIntent
    public var no: UIIntent

    public init(id: String, title: String, yes: UIIntent, no: UIIntent) {
        self.id = id
        self.title = title
        self.yes = yes
        self.no = no
    }
}

/// One Log row: collapsed text + right-side one-tap button; tap the row = open in place.
public struct LogItemRow: Equatable, Sendable, Identifiable {
    public var item: LogItemID
    /// "Vape", "MedA 20 mg".
    public var title: String
    /// "9 today · last 10:31".
    public var collapsedText: String
    /// "+ Hit", "Took it", "Start" / "Finish".
    public var primaryButton: ActionState?
    public var isOpen: Bool
    /// Opened in place: lines, chart, chips.
    public var expansion: NowRowExpansion?

    public init(item: LogItemID, title: String, collapsedText: String, primaryButton: ActionState?,
                isOpen: Bool = false, expansion: NowRowExpansion? = nil) {
        self.item = item
        self.title = title
        self.collapsedText = collapsedText
        self.primaryButton = primaryButton
        self.isOpen = isOpen
        self.expansion = expansion
    }

    public var id: String { item.rawValue }
}

/// A spine entry: ○ logged, ■ measured, │ vape stroke, bar for a drink's sip time (UX §7 DaySpine).
public struct SpineEntry: Equatable, Sendable, Identifiable {
    public enum Mark: String, Sendable, CaseIterable { case logged, measured, vapeStroke, drinkBar }

    public var id: UUID
    public var mark: Mark
    public var at: Date
    public var end: Date?
    public var title: String
    /// "happened 09:35 · logged 09:49" when they differ.
    public var timing: String?
    /// Detected and unconfirmed.
    public var unconfirmed: Bool

    public init(id: UUID, mark: Mark, at: Date, end: Date? = nil, title: String, timing: String? = nil,
                unconfirmed: Bool = false) {
        self.id = id
        self.mark = mark
        self.at = at
        self.end = end
        self.title = title
        self.timing = timing
        self.unconfirmed = unconfirmed
    }
}

/// The month grid: one row per item, one mark per day (adherence).
public struct MonthGridState: Equatable, Sendable {
    /// "October".
    public var title: String
    public var days: [LocalDay]
    public var rows: [MonthGridRow]
    public var isCollapsed: Bool
    /// r9v (UI-SCRUB G4): each day's entries (oldest first, capped at `entryCap`), keyed by `LocalDay.iso`; a tap on a day lists them.
    public var entries: [String: [SpineEntry]]
    /// The real number of entries that day, when more than `entryCap` (nothing is hidden silently).
    public var entryTotals: [String: Int]
    public static let entryCap = 60

    public init(title: String, days: [LocalDay], rows: [MonthGridRow], isCollapsed: Bool = true,
                entries: [String: [SpineEntry]] = [:], entryTotals: [String: Int] = [:]) {
        self.title = title
        self.days = days
        self.rows = rows
        self.isCollapsed = isCollapsed
        self.entries = entries
        self.entryTotals = entryTotals
    }
}

public struct MonthGridRow: Equatable, Sendable, Identifiable {
    public var item: LogItemID
    public var title: String
    /// One per day in `days`: true = done / logged, false = scheduled and missed, nil = nothing expected.
    public var marks: [Bool?]

    public init(item: LogItemID, title: String, marks: [Bool?]) {
        self.item = item
        self.title = title
        self.marks = marks
    }

    public var id: String { item.rawValue + ":" + title }
}
