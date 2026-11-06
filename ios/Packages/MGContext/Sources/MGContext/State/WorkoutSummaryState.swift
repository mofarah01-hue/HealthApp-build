import Foundation

/// T116: the WHOOP-style workout summary. A card with the headline numbers that opens in place
/// (`.toggleRow(id: toggleId)`) to the rest. Shown on Live while the workout runs and listed in Explore after.
/// Every number is the presenter's; views only draw. Things the app cannot measure yet are blank rows that say why.
public struct WorkoutSummaryState: Equatable, Sendable, Identifiable {
    /// The workout event id (`.openWorkout(id:)` opens the full detail page).
    public var id: UUID
    /// "Gym, strength".
    public var title: String
    /// "5:32 PM – 6:20 PM".
    public var kicker: String
    /// `.toggleRow(id:)` id that opens the card.
    public var toggleId: String
    public var isOpen: Bool
    /// Time · Avg HR · Max HR · Calories.
    public var headline: [LabeledValue]
    /// Time in zones · Steps · HR recovery · Wind-down · SpO₂ · Impact · HRV hint · VO₂ max.
    public var details: [LabeledValue]
    /// The HR through the workout (beat-to-beat is not stored per workout, so 5-second readings); nil = none.
    public var hrMap: WorkoutHRMapState?
    /// "Flags are wellness hints, not a diagnosis."
    public var flagsNote: String

    public init(id: UUID, title: String, kicker: String, toggleId: String, isOpen: Bool, headline: [LabeledValue],
                details: [LabeledValue], hrMap: WorkoutHRMapState?, flagsNote: String) {
        self.id = id
        self.title = title
        self.kicker = kicker
        self.toggleId = toggleId
        self.isOpen = isOpen
        self.headline = headline
        self.details = details
        self.hrMap = hrMap
        self.flagsNote = flagsNote
    }
}

/// Explore › Workouts: the recent finished workouts, newest first.
public struct WorkoutHistoryState: Equatable, Sendable {
    public var rows: [WorkoutSummaryState]
    /// Why the list is empty; nil when it has rows.
    public var emptyReason: String?

    public init(rows: [WorkoutSummaryState] = [], emptyReason: String? = nil) {
        self.rows = rows
        self.emptyReason = emptyReason
    }
}
