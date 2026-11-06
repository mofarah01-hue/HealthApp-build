import Foundation

/// Settings > Screen Time (Mac build, Nov 2026). Sent as `UIIntent.screenTime(_:)`. The apps/categories picker is a system
/// view and keeps its own selection; only the actions below go through the intent path.
public enum ScreenTimeAction: Equatable, Sendable {
    /// Settings row: push the page (it reads the App Group log on open).
    case open
    /// Read the events the Activity Monitor extension wrote and log new ones.
    case refresh
    /// `AuthorizationCenter.requestAuthorization(for: .individual)` (Face ID / passcode prompt from iOS).
    case requestAuthorization
    /// Register the day / evening / night schedules and their thresholds for the chosen apps and categories.
    case startMonitoring
    /// Stop every schedule.
    case stopMonitoring
    /// The evening threshold in minutes (30, 60 or 120; 60 by default). Applies from the next start.
    case setEveningThreshold(Int)
}
