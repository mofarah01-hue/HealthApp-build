import Foundation

/// Settings › Places (tracker #41): Mo's saved places and the low-power presence that tags workouts with them. Sent as
/// `UIIntent.places(_:)`.
public enum PlacesAction: Equatable, Sendable {
    /// Settings › Places row: push the page.
    case open
    /// Add a place of this kind with its preset name (Home, Work, Gym, Soccer field, Pickup field, or a new place).
    case add(PlaceKind)
    case rename(id: String, name: String)
    /// 50–500 m.
    case setRadius(id: String, meters: Int)
    case remove(id: String)
    /// One precise fix now (when-in-use permission) becomes the place's centre.
    case useCurrentLocation(id: String)
    /// Notice when Mo is at his places, in the background too (region monitoring + visits; asks for "Always").
    case setPresence(Bool)
}
