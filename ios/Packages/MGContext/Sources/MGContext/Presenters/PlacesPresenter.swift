import Foundation

/// iOS location permission as the Places page words it.
public enum PlacesAuthorization: String, Equatable, Sendable {
    case notDetermined
    case whenInUse
    case always
    case denied
    case restricted
}

public struct PlacesInput: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var sample: Bool
    public var places: [SavedPlace]
    public var visits: [PlaceVisit]
    public var presenceOn: Bool
    public var authorization: PlacesAuthorization
    public var note: String?

    public init(now: Date, calendar: Calendar, sample: Bool, places: [SavedPlace], visits: [PlaceVisit],
                presenceOn: Bool, authorization: PlacesAuthorization, note: String?) {
        self.now = now
        self.calendar = calendar
        self.sample = sample
        self.places = places
        self.visits = visits
        self.presenceOn = presenceOn
        self.authorization = authorization
        self.note = note
    }
}

/// Settings › Places (tracker #41).
public enum PlacesPresenter {
    static let presets: [PlaceKind] = [.home, .work, .gym, .soccerField, .pickupField]

    public static func make(_ i: PlacesInput) -> PlacesState {
        let snap = PlacesSnapshot(places: i.places, visits: i.visits)
        let here = PlacePresence.current(now: i.now, snap)?.placeId
        let rows = i.places.map { p -> PlacesState.PlaceRow in
            var status: String
            if p.hasLocation {
                status = p.setAt.map { "Set \(when($0, i))" } ?? "Set"
                if here == p.id { status += " · you're here" }
                else if let last = lastStay(p.id, i) { status += " · last here \(last)" }
            } else {
                status = "No location yet — stand there and tap Use my current location."
            }
            return PlacesState.PlaceRow(id: p.id, name: p.name, kindLine: kindLine(p.kind), status: status,
                                        radiusMeters: Int(p.radiusMeters.rounded()), hasLocation: p.hasLocation,
                                        isHere: here == p.id)
        }
        let taken = Set(i.places.map(\.kind))
        var add = presets.filter { !taken.contains($0) }.map {
            ActionState(id: "add.\($0.rawValue)", title: "+ \($0.presetName)", intent: .places(.add($0)))
        }
        add.append(ActionState(id: "add.other", title: "+ Other place", intent: .places(.add(.other))))

        let (detail, problem) = presenceWords(i)
        let anySet = i.places.contains { $0.hasLocation }
        let presence = ToggleState(id: "presence", title: "Notice when I'm at these places",
                                   detail: detail, isOn: i.presenceOn, enabled: !i.sample && (anySet || i.presenceOn),
                                   disabledReason: i.sample ? "Sample data is on." :
                                    (anySet ? nil : "Set a place's location first."),
                                   intent: .places(.setPresence(!i.presenceOn)))
        return PlacesState(sample: i.sample, places: rows, add: add, presence: presence, presenceDetail: detail,
                           permissionProblem: problem, note: i.note, recent: recent(i),
                           howUsed: "A workout the strap finds is tagged with the place you were at for most of it, "
                           + "and the question uses it: Gym → strength likely, Soccer field and Pickup field → soccer, "
                           + "Work → a real walk or just moving about. At Home and Work nothing becomes a workout "
                           + "unless you say so. Coordinates stay on this iPhone; a logged workout carries only the "
                           + "place's name.")
    }

    static func kindLine(_ k: PlaceKind) -> String {
        switch k {
        case .home: return "Home · never a workout without asking"
        case .work: return "Work · a real walk, or moving about"
        case .gym: return "Gym · strength likely"
        case .soccerField: return "Soccer field · soccer likely"
        case .pickupField: return "Pickup field · soccer likely"
        case .other: return "Place · tags the workout, no guess"
        }
    }

    static func presenceWords(_ i: PlacesInput) -> (String, String?) {
        let how = "Uses iOS region monitoring and visits — low power, no continuous GPS. Kept on this iPhone."
        guard i.presenceOn else { return ("Off. " + how, nil) }
        switch i.authorization {
        case .always:
            return ("On, also in the background. " + how, nil)
        case .whenInUse:
            return ("On while the app is open only.",
                    "For the background too, allow location “Always” for MG in iOS Settings › MG › "
                    + "Location.")
        case .notDetermined:
            return ("Waiting for location permission.", nil)
        case .denied, .restricted:
            return ("Location is off for MG, so places can't be noticed.",
                    "Allow it in iOS Settings › MG › Location.")
        }
    }

    static func lastStay(_ id: String, _ i: PlacesInput) -> String? {
        let mine = i.visits.filter { $0.placeId == id && $0.arrived != nil }
        guard let v = mine.max(by: { $0.arrived! < $1.arrived! }), let a = v.arrived else { return nil }
        return when(a, i)
    }

    /// T61: `PlaceActivity.classify` (minStay-filtered, overlap-merged) turns the visit log into stays, each shown
    /// with its activity class so "Last stays" names what was likely happening, not just where.
    static func recent(_ i: PlacesInput) -> [String] {
        let snap = PlacesSnapshot(places: i.places, visits: i.visits)
        let window = DateInterval(start: .distantPast, end: i.now)
        let stays = PlaceActivity.classify(window, now: i.now, snap)
        return stays.sorted { $0.start > $1.start }
            .prefix(10)
            .map { stay in
                let end = stay.end == i.now ? "now" : MGFormat.time(stay.end, calendar: i.calendar)
                return "\(stay.name) · \(when(stay.start, i))–\(end) · \(activityLabel(stay.activityClass))"
            }
    }

    static func activityLabel(_ c: PlaceActivityClass) -> String {
        switch c {
        case .exercise(let activity): return "\(activity) likely"
        case .office: return "office"
        case .home: return "home"
        case .elsewhere: return "elsewhere"
        }
    }

    /// "17:02" today, "Sat 10 Oct 17:02" on another day.
    static func when(_ d: Date, _ i: PlacesInput) -> String {
        let t = MGFormat.time(d, calendar: i.calendar)
        return i.calendar.isDate(d, inSameDayAs: i.now) ? t : "\(MGFormat.shortDate(d, calendar: i.calendar)) \(t)"
    }
}
