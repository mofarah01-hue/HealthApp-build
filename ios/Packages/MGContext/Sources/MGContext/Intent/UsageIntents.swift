import Foundation

/// Settings › Usage (tracker #40): what the app uses on the phone and the PC. Sent as `UIIntent.usage(_:)`.
public enum UsageAction: Equatable, Sendable {
    /// Settings › Usage row: push the page (it measures on open).
    case open
    /// "Measure again": phone sizes, the background log, the process counters and the PC's answer.
    case refresh
}
