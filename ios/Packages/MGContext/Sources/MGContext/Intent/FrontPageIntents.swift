import Foundation

/// Settings › Front page (tracker #34): order, show / hide, add / remove Today's cards, and what the Sundial draws.
/// Sent as `UIIntent.frontPage(_:)`; each edit is saved with the other settings.
public enum FrontPageAction: Equatable, Sendable {
    /// Settings › Front page row: push the page.
    case open
    /// Drag to reorder: `FrontPageLayout.move(from:to:)` offsets (SwiftUI `onMove`).
    case move(from: [Int], to: Int)
    case setHidden(FrontPageItem, hidden: Bool)
    case add(FrontPageItem)
    case remove(FrontPageItem)
    /// "Reset to default" (the page; the dial keeps its switches).
    case reset
    case setDialLayer(DialLayer, shown: Bool)
    /// "Show every ring".
    case resetDial
    /// T96: put a metric on Today in this form (or change its form).
    case pickMetric(key: String, form: MetricPickForm)
    case unpickMetric(key: String)
}
