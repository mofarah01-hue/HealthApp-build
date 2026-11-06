import Foundation

// T32 (2026-10-13): which hours of a day count as "daytime" for the daytime recovery / stress models (T31, T33; ALG-105,
// ALG-012, ALG-054). Three choices: clock hours (default 9 AM - 5 PM, needs no location), the office geofence (the
// time Mo's Work place says he was there), or both (the union: office time OR clock hours).
//
// Privacy: the geofence needs location permission, which is Mo's call and is NOT requested or read here. This file only
// reads the Places visit log that already exists, and only when the caller says location is allowed AND Places presence
// is on. Until a Work place with a location is saved and that is true, the geofence is inactive and the window falls
// back to the clock hours (so the models never go blank because of a missing permission). Pure logic; tests in
// DaytimeWindowTests.

public enum DaytimeWindowMode: String, Codable, CaseIterable, Sendable {
    case clockHours = "clock_hours"
    case officeGeofence = "office_geofence"
    case both
}

public struct DaytimeWindow: Codable, Equatable, Sendable {
    public static let defaultStartHour = 9
    public static let defaultEndHour = 17

    public var mode: DaytimeWindowMode
    /// Clock window, local hours 0...24 (24 = midnight at the end of the day). Used by `clockHours` and `both`, and as
    /// the fallback when the geofence is chosen but inactive. An invalid pair (end <= start) means 9-17.
    public var startHour: Int
    public var endHour: Int

    public init(mode: DaytimeWindowMode = .clockHours, startHour: Int = defaultStartHour, endHour: Int = defaultEndHour) {
        self.mode = mode
        self.startHour = startHour
        self.endHour = endHour
    }

    public struct Resolved: Equatable, Sendable {
        /// Sorted, non-overlapping spans inside the day.
        public var spans: [DateInterval]
        /// True when the office visits were used (a Work place with a location, location allowed).
        public var geofenceActive: Bool
        /// Plain words for the model's note when the setting could not be followed exactly; nil when it was.
        public var note: String?

        public func contains(_ t: Date) -> Bool { spans.contains { $0.start <= t && t < $0.end } }
    }

    /// The daytime spans of the local day holding `day`. `locationAllowed`: iOS permission granted and Places presence
    /// on (the caller decides; nothing is requested here). `now` closes a visit still open.
    public func resolve(day: Date, calendar: Calendar, places: PlacesSnapshot, locationAllowed: Bool,
                        now: Date) -> Resolved {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return Resolved(spans: [], geofenceActive: false, note: nil)
        }
        let clock = clockSpan(start: start, end: end, calendar: calendar)

        let workIds = Set(places.places.filter { $0.kind == .work && $0.hasLocation }.map(\.id))
        let active = mode != .clockHours && locationAllowed && !workIds.isEmpty
        let office: [DateInterval] = active ? places.visits.compactMap { v in
            guard workIds.contains(v.placeId), let a = v.arrived else { return nil }
            let s = max(a, start)
            let e = min(v.departed ?? now, end)
            return e > s ? DateInterval(start: s, end: e) : nil
        } : []

        switch mode {
        case .clockHours:
            return Resolved(spans: clock, geofenceActive: false, note: nil)
        case .officeGeofence where active:
            return Resolved(spans: Self.merged(office), geofenceActive: true, note: nil)
        case .both where active:
            return Resolved(spans: Self.merged(office + clock), geofenceActive: true, note: nil)
        case .officeGeofence, .both:
            return Resolved(spans: clock, geofenceActive: false, note: Self.fallbackNote(noPlace: workIds.isEmpty))
        }
    }

    private func clockSpan(start: Date, end: Date, calendar: Calendar) -> [DateInterval] {
        let ok = (0...24).contains(startHour) && (0...24).contains(endHour) && endHour > startHour
        let (h0, h1) = ok ? (startHour, endHour) : (Self.defaultStartHour, Self.defaultEndHour)
        let s = calendar.date(bySettingHour: h0, minute: 0, second: 0, of: start) ?? start
        let e = h1 == 24 ? end : (calendar.date(bySettingHour: h1, minute: 0, second: 0, of: start) ?? end)
        return e > s ? [DateInterval(start: s, end: e)] : []
    }

    private static func fallbackNote(noPlace: Bool) -> String {
        noPlace ? "No Work place with a location is saved, so the clock hours are used."
            : "Location is off, so the clock hours are used instead of the office."
    }

    static func merged(_ spans: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: max(last.end, s.end))
            } else {
                out.append(s)
            }
        }
        return out
    }
}
