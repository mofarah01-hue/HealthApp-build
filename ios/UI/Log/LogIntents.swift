import Foundation
import MGContext
import MGDomain

/// The one place the Log tab builds the intents WP-06 added for WP-18 (MGContext/Intent/EntryIntents.swift and the
/// four cases in UIIntent). If main renames one, this file is the only change in UI/Log.
enum LogIntents {
    /// A new event (fresh id, revision 1). `at` = happened, `loggedAt` = save time (APP-082).
    static func save(_ event: EventRecord) -> UIIntent { .saveEvent(event) }

    /// Log › Sleepy & check-in › [Reaction test, 3 min] (APP-062).
    static let startReactionTest: UIIntent = .startReactionTest

    /// Existing entry: negative minutes = earlier (approved clarification a).
    static func shift(id: UUID, minutes: Int) -> UIIntent { .shiftHappenedAt(id: id, minutes: minutes) }

    /// "Sample data is on" — logging and editing are switched off (ARCHITECTURE §4.12: sample data is never written).
    static let sampleReason = "Sample data is on, so nothing is saved. Switch it off in Settings › Sample data."
}
