import Foundation

// T61 (2026-10-13): the places visit log -> an activity class per stay. Data and logic only: it reads the visit log
// Places already keeps on the phone (never sent anywhere), requests no location permission and reads no location. The
// "Always" permission that feeds the log is Mo's call and stays inactive until it is set elsewhere; with no log the
// result is empty. Tests: PlaceActivityTests (a synthetic day driven through PlaceMatcher and PlaceLog).

public enum PlaceActivityClass: Equatable, Sendable {
    /// A gym, soccer field or pickup field: an activity ("strength", "soccer") is likely here.
    case exercise(String)
    case office
    case home
    case elsewhere
}

public struct ClassifiedStay: Equatable, Sendable {
    public var placeId: String
    public var name: String
    public var start: Date
    public var end: Date
    public var activityClass: PlaceActivityClass
}

public enum PlaceActivity {
    /// A stay shorter than this is passing by, not being there.
    public static let minStay: TimeInterval = 10 * 60

    public static func activityClass(_ kind: PlaceKind) -> PlaceActivityClass {
        if let a = kind.likelyActivity, kind != .work { return .exercise(a) }
        switch kind {
        case .work: return .office
        case .home: return .home
        default: return .elsewhere
        }
    }

    /// The stays inside `window`, in time order: cut to the window, a stay still open runs to `now`, a stay with no
    /// known arrival or at a place no longer saved is skipped, an overlap goes to the later arrival, and a stay under
    /// `minStay` is dropped.
    public static func classify(_ window: DateInterval, now: Date, _ s: PlacesSnapshot) -> [ClassifiedStay] {
        var stays: [ClassifiedStay] = []
        for v in s.visits {
            guard let a = v.arrived, let p = s.places.first(where: { $0.id == v.placeId }) else { continue }
            let start = max(a, window.start), end = min(v.departed ?? now, window.end)
            if end > start {
                stays.append(ClassifiedStay(placeId: p.id, name: p.name, start: start, end: end,
                                            activityClass: activityClass(p.kind)))
            }
        }
        stays.sort { $0.start < $1.start }
        for i in stays.indices.dropLast() where stays[i].end > stays[i + 1].start {
            stays[i].end = stays[i + 1].start
        }
        return stays.filter { $0.end.timeIntervalSince($0.start) >= minStay }
    }
}
