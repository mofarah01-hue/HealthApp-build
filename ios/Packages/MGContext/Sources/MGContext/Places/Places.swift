import Foundation

// Places (tracker #41, Mo 2026-10-11: "home location and work and gym and soccer field pickup field"). Purpose, his:
// tell a real walk from office work, stop "running around the house" becoming a workout, and ask him to confirm.
//
// Mo saves places (Settings › Places: "Use my current location" + a radius). The phone notices when he is at one with
// iOS region monitoring and visits (low power, no continuous GPS) and keeps a visit log ON THE PHONE. A workout
// candidate (ALG-041) is tagged with the place he was at for most of it, and the place is a prior for the question:
// Gym → strength likely, Soccer field / Pickup field → soccer, Work → a real walk or moving about, Home → never a workout
// without him saying so. Coordinates never leave the phone: a logged workout carries the place's name and id only
// (contract eventBase.location.label / saved_place_id). Pure logic here; failure modes in PlacesTests.

public enum PlaceKind: String, Codable, Sendable, CaseIterable {
    case home
    case work
    case gym
    case soccerField = "soccer_field"
    case pickupField = "pickup_field"
    case other

    /// The preset name a new place of this kind gets (Mo can rename it).
    public var presetName: String {
        switch self {
        case .home: return "Home"
        case .work: return "Work"
        case .gym: return "Gym"
        case .soccerField: return "Soccer field"
        case .pickupField: return "Pickup field"
        case .other: return "New place"
        }
    }

    /// Radius a new place starts with, metres (fields and offices are bigger than a flat).
    public var defaultRadius: Double {
        switch self {
        case .home, .gym, .other: return 100
        case .work, .soccerField, .pickupField: return 150
        }
    }

    /// The activity a workout here most likely is (nil = no guess).
    public var likelyActivity: String? {
        switch self {
        case .gym: return "strength"
        case .soccerField, .pickupField: return "soccer"
        case .work: return "walk"
        case .home, .other: return nil
        }
    }

    /// Home and Work: moving about is normal there, so a candidate is NOT a workout unless Mo says so (the question's
    /// default answer is "not a workout", and nothing is logged on its own).
    public var askFirst: Bool { self == .home || self == .work }
}

public struct SavedPlace: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: PlaceKind
    /// nil until "Use my current location".
    public var latitude: Double?
    public var longitude: Double?
    public var radiusMeters: Double
    public var setAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), name: String, kind: PlaceKind, latitude: Double? = nil,
                longitude: Double? = nil, radiusMeters: Double? = nil, setAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters ?? kind.defaultRadius
        self.setAt = setAt
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
}

/// One stay at a saved place. `arrived` nil = not known (an exit seen without its entry), `departed` nil = still there.
public struct PlaceVisit: Codable, Equatable, Sendable {
    public var placeId: String
    public var arrived: Date?
    public var departed: Date?
    /// "region" (enter / exit), "visit" (CLVisit), "state" (asked when the app came to the front).
    public var source: String

    public init(placeId: String, arrived: Date?, departed: Date?, source: String) {
        self.placeId = placeId
        self.arrived = arrived
        self.departed = departed
        self.source = source
    }
}

/// What the presenters need: the places and the visit log (phone only).
public struct PlacesSnapshot: Equatable, Sendable {
    public var places: [SavedPlace]
    public var visits: [PlaceVisit]

    public init(places: [SavedPlace] = [], visits: [PlaceVisit] = []) {
        self.places = places
        self.visits = visits
    }
}

/// The place a workout candidate happened at, and what that suggests.
public struct PlaceTag: Equatable, Sendable {
    public var placeId: String
    public var name: String
    public var kind: PlaceKind

    public init(placeId: String, name: String, kind: PlaceKind) {
        self.placeId = placeId
        self.name = name
        self.kind = kind
    }

    public var likelyActivity: String? { kind.likelyActivity }
    public var askFirst: Bool { kind.askFirst }
}

public enum PlaceMatcher {
    static let earthRadius = 6_371_008.8

    /// Great-circle distance in metres (haversine).
    public static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = Double.pi / 180
        let dLat = (lat2 - lat1) * r
        let dLon = (lon2 - lon1) * r
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * r) * cos(lat2 * r) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// A fix this vague says nothing about a place of this radius.
    static func tooVague(accuracy: Double, radius: Double) -> Bool {
        !accuracy.isFinite || accuracy < 0 || accuracy > max(2 * radius, 200)
    }

    /// The saved place a fix is in: within its radius (plus up to 25 m of the fix's own uncertainty); of several, the
    /// one whose centre is nearest relative to its radius. nil when the fix is too vague for every candidate.
    public static func place(latitude: Double, longitude: Double, accuracy: Double,
                             in places: [SavedPlace]) -> SavedPlace? {
        var best: (place: SavedPlace, score: Double)?
        for p in places {
            guard let lat = p.latitude, let lon = p.longitude, p.radiusMeters > 0,
                  !tooVague(accuracy: accuracy, radius: p.radiusMeters) else { continue }
            let d = distance(latitude, longitude, lat, lon)
            guard d <= p.radiusMeters + min(max(accuracy, 0), 25) else { continue }
            let score = d / p.radiusMeters
            if best == nil || score < best!.score { best = (p, score) }
        }
        return best?.place
    }

    /// Hysteresis for fixes taken one after another: once at a place, Mo stays there until a fix is beyond its radius
    /// plus a margin (max(30 m, a quarter of the radius)), so GPS jitter at the edge does not log a new visit every fix.
    public static func next(current: String?, latitude: Double, longitude: Double, accuracy: Double,
                            places: [SavedPlace]) -> String? {
        if let id = current, let p = places.first(where: { $0.id == id }), let lat = p.latitude, let lon = p.longitude {
            if tooVague(accuracy: accuracy, radius: p.radiusMeters) { return id }      // a vague fix changes nothing
            let margin = max(30, p.radiusMeters / 4)
            if distance(latitude, longitude, lat, lon) <= p.radiusMeters + margin { return id }
        }
        return place(latitude: latitude, longitude: longitude, accuracy: accuracy, in: places)?.id
    }
}

public enum PlaceLog {
    static let keep: TimeInterval = 30 * 86_400
    static let maxVisits = 1000

    /// Entered a place: opens a visit unless one is already open there.
    public static func enter(_ placeId: String, at: Date, source: String, _ visits: inout [PlaceVisit]) {
        if visits.contains(where: { $0.placeId == placeId && $0.departed == nil }) { return }
        visits.append(PlaceVisit(placeId: placeId, arrived: at, departed: nil, source: source))
    }

    /// Left a place: closes its open visit. An exit with no open visit is dropped (its arrival is unknown).
    public static func exit(_ placeId: String, at: Date, _ visits: inout [PlaceVisit]) {
        guard let i = visits.lastIndex(where: { $0.placeId == placeId && $0.departed == nil }) else { return }
        visits[i].departed = max(at, visits[i].arrived ?? at)
    }

    /// A CLVisit matched to a place: the same stay seen again (by region monitoring, or the visit's arrival and later
    /// its departure) widens that stay; otherwise it is a new one. A region exit already seen is not undone.
    public static func visit(_ placeId: String, arrived: Date, departed: Date?, _ visits: inout [PlaceVisit]) {
        let end = departed ?? .distantFuture
        if let i = visits.lastIndex(where: { v in
            v.placeId == placeId && (v.arrived ?? .distantPast) <= end && (v.departed ?? .distantFuture) >= arrived
        }) {
            visits[i].arrived = min(visits[i].arrived ?? arrived, arrived)
            if let d = departed { visits[i].departed = max(visits[i].departed ?? d, d) }
            return
        }
        visits.append(PlaceVisit(placeId: placeId, arrived: arrived, departed: departed, source: "visit"))
    }

    /// Forgets stays that ended more than 30 days ago (and keeps at most 1000).
    public static func prune(now: Date, _ visits: inout [PlaceVisit]) {
        let cutoff = now.addingTimeInterval(-keep)
        visits.removeAll { v in (v.departed ?? .distantFuture) < cutoff }
        if visits.count > maxVisits { visits.removeFirst(visits.count - maxVisits) }
    }
}

public enum PlacePresence {
    /// The place Mo was at for at least half of [start, end] (stays at the same place add up; a stay with no known
    /// arrival counts for nothing; one still open runs to `now`). nil = no place, or no single place for half the time.
    public static func tag(start: Date, end: Date, now: Date, _ s: PlacesSnapshot) -> PlaceTag? {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return nil }
        var overlap: [String: TimeInterval] = [:]
        for v in s.visits {
            guard let a = v.arrived else { continue }
            let d = v.departed ?? now
            let o = min(d, end).timeIntervalSince(max(a, start))
            if o > 0 { overlap[v.placeId, default: 0] += o }
        }
        guard let best = overlap.max(by: { $0.value < $1.value }), best.value >= duration / 2,
              let p = s.places.first(where: { $0.id == best.key }) else { return nil }
        return PlaceTag(placeId: p.id, name: p.name, kind: p.kind)
    }

    /// Where Mo is now: the newest stay still open at a saved place.
    public static func current(now: Date, _ s: PlacesSnapshot) -> PlaceTag? {
        let open = s.visits.filter { $0.departed == nil && ($0.arrived ?? now) <= now }
        guard let v = open.max(by: { ($0.arrived ?? .distantPast) < ($1.arrived ?? .distantPast) }),
              let p = s.places.first(where: { $0.id == v.placeId }) else { return nil }
        return PlaceTag(placeId: p.id, name: p.name, kind: p.kind)
    }
}

/// The workout question with a place (UX §5 peek, Log confirm list): wording and answers.
public enum PlaceQuestion {
    /// Answer ids: "yes" = a workout (step 2 asks what), "yes_prior" = the place's likely activity there (done),
    /// "not_workout" = no.
    public static let acceptPrior = "yes_prior"

    public static func activityTitle(_ type: String) -> String {
        switch type {
        case "strength": return "Strength"
        case "soccer": return "Soccer"
        case "walk": return "A walk"
        case "run": return "Run"
        case "cycle": return "Cycle"
        default: return type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    /// "Soccer at Pickup field, 17:32–18:20 — right?" · "At Home 17:32–18:20 — a workout, or moving around the house?"
    public static func question(_ tag: PlaceTag, range: String) -> String {
        switch tag.kind {
        case .home: return "At \(tag.name) \(range) — a workout, or moving around the house?"
        case .work: return "At \(tag.name) \(range) — a real walk, or moving about at work?"
        default:
            if let a = tag.likelyActivity { return "\(activityTitle(a)) at \(tag.name), \(range) — right?" }
            return "Workout at \(tag.name), \(range) — right?"
        }
    }

    /// (answer id, title, is default), in order.
    public static func answers(_ tag: PlaceTag) -> [(id: String, title: String, isDefault: Bool)] {
        switch tag.kind {
        case .home:
            return [("not_workout", "Moving around the house", true), ("yes", "A workout", false)]
        case .work:
            return [("not_workout", "Moving about at work", true), (acceptPrior, "A real walk", false),
                    ("yes", "Something else", false)]
        default:
            if tag.likelyActivity != nil {
                return [(acceptPrior, "Yes", true), ("yes", "Something else", false),
                        ("not_workout", "Not a workout", false)]
            }
            return [("yes", "Yes", true), ("not_workout", "Not a workout", false)]
        }
    }
}
