import Foundation

/// Settings › Places (tracker #41). Built by `PlacesPresenter`.
public struct PlacesState: Equatable, Sendable {
    public struct PlaceRow: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// "Gym · strength likely" · "Home · never a workout without asking".
        public var kindLine: String
        /// "Set 11 Oct 17:02 · you're here" · "No location yet — stand there and tap Use my current location."
        public var status: String
        public var radiusMeters: Int
        public var hasLocation: Bool
        public var isHere: Bool

        public init(id: String, name: String, kindLine: String, status: String, radiusMeters: Int, hasLocation: Bool,
                    isHere: Bool) {
            self.id = id
            self.name = name
            self.kindLine = kindLine
            self.status = status
            self.radiusMeters = radiusMeters
            self.hasLocation = hasLocation
            self.isHere = isHere
        }
    }

    public var sample: Bool
    public var places: [PlaceRow]
    /// One button per preset not added yet, plus "Other place".
    public var add: [ActionState]
    public var presence: ToggleState
    /// Permission and what presence does, in words.
    public var presenceDetail: String
    /// Shown when the permission needs changing in iOS Settings.
    public var permissionProblem: String?
    /// "reading the location…" or why the last reading failed.
    public var note: String?
    /// The last stays, newest first: "Gym · Sat 10 Oct 17:30–18:25".
    public var recent: [String]
    public var howUsed: String

    public init(sample: Bool, places: [PlaceRow], add: [ActionState], presence: ToggleState, presenceDetail: String,
                permissionProblem: String?, note: String?, recent: [String], howUsed: String) {
        self.sample = sample
        self.places = places
        self.add = add
        self.presence = presence
        self.presenceDetail = presenceDetail
        self.permissionProblem = permissionProblem
        self.note = note
        self.recent = recent
        self.howUsed = howUsed
    }
}
