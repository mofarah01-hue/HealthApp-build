import CoreLocation
import Foundation
import MGContext

// Places (tracker #41): the phone's location, the low-power way. Two uses, one CLLocationManager:
//  1. "Use my current location" in Settings › Places: ONE precise fix (when-in-use permission, the same iOS permission
//     the Fajr wake asks for in AlarmsLocation — granted once, asked once), full precision, kept on the phone.
//  2. Presence: iOS region monitoring of the saved places (enter / exit) plus CLVisit (arrivals and departures iOS
//     works out on its own). Neither runs the GPS continuously; both wake the app in the background, which needs
//     "Always" permission (asked only when Mo switches presence on). No `location` background mode is used.
// The manager is made when the app model is (at launch), so iOS can hand over region events after relaunching the app
// in the background. Coordinates never leave the phone.

@MainActor
final class PlacesLocation: NSObject, CLLocationManagerDelegate {
    enum Event {
        case enter(placeId: String, at: Date)
        case exit(placeId: String, at: Date)
        /// From `requestState` when the app comes to the front.
        case inside(placeId: String, at: Date)
        case outside(placeId: String, at: Date)
        /// A CLVisit: arrival / departure nil when iOS does not know it yet.
        case visit(latitude: Double, longitude: Double, accuracy: Double, arrived: Date?, departed: Date?)
        case problem(String)
    }

    enum Failure: Error, Equatable {
        case denied
        case unavailable(String)

        var words: String {
            switch self {
            case .denied: return "Location is off for MG — allow it in iOS Settings › MG › Location."
            case .unavailable(let why): return "Couldn't read the location: \(why)"
            }
        }
    }

    nonisolated static let regionPrefix = "place."

    var onEvent: ((Event) -> Void)?
    var onAuthorization: ((PlacesAuthorization) -> Void)?

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<Result<CLLocation, Failure>, Never>?
    /// Presence was switched on before "when in use" was granted: ask for "Always" right after.
    private var wantAlways = false

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: PlacesAuthorization { Self.map(manager.authorizationStatus) }

    static func map(_ s: CLAuthorizationStatus) -> PlacesAuthorization {
        switch s {
        case .notDetermined: return .notDetermined
        case .authorizedWhenInUse: return .whenInUse
        case .authorizedAlways: return .always
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    // MARK: 1. One precise fix

    func readPrecise() async -> Result<CLLocation, Failure> {
        if waiting != nil { return .failure(.unavailable("a reading is already running")) }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        return await withCheckedContinuation { c in
            waiting = c
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()     // the delegate continues
            case .denied, .restricted: finish(.failure(.denied))
            default: manager.requestLocation()
            }
        }
    }

    private func finish(_ r: Result<CLLocation, Failure>) {
        let c = waiting
        waiting = nil
        c?.resume(returning: r)
    }

    // MARK: 2. Presence

    /// Presence on: permission as needed, the saved places as regions, and visits. Off: all of it stops.
    func setPresence(_ on: Bool, places: [SavedPlace]) {
        guard on else {
            wantAlways = false
            manager.stopMonitoringVisits()
            for r in manager.monitoredRegions where r.identifier.hasPrefix(Self.regionPrefix) {
                manager.stopMonitoring(for: r)
            }
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            wantAlways = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()          // iOS shows the upgrade once; the answer comes to the delegate
        default:
            break
        }
        syncRegions(places)
        switch manager.authorizationStatus {
        case .denied, .restricted: break
        default: manager.startMonitoringVisits()
        }
    }

    /// Monitored regions = the saved places that have a location (radius at least 100 m: iOS is unreliable below).
    func syncRegions(_ places: [SavedPlace]) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            onEvent?(.problem("This iPhone can't monitor regions; only visits are used."))
            return
        }
        var wanted: [String: CLCircularRegion] = [:]
        for p in places {
            guard let lat = p.latitude, let lon = p.longitude else { continue }
            let radius = min(max(p.radiusMeters, 100), manager.maximumRegionMonitoringDistance)
            let r = CLCircularRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), radius: radius,
                                     identifier: Self.regionPrefix + p.id)
            r.notifyOnEntry = true
            r.notifyOnExit = true
            wanted[r.identifier] = r
        }
        for r in manager.monitoredRegions where r.identifier.hasPrefix(Self.regionPrefix) {
            if let w = wanted[r.identifier], let c = r as? CLCircularRegion, c.center.latitude == w.center.latitude,
               c.center.longitude == w.center.longitude, c.radius == w.radius {
                wanted.removeValue(forKey: r.identifier)          // unchanged: keep monitoring
            } else {
                manager.stopMonitoring(for: r)
            }
        }
        for r in wanted.values { manager.startMonitoring(for: r) }
    }

    /// Asks iOS whether Mo is inside each monitored place now (the answers come as `.inside` / `.outside`).
    func checkStates() {
        for r in manager.monitoredRegions where r.identifier.hasPrefix(Self.regionPrefix) {
            manager.requestState(for: r)
        }
    }

    nonisolated static func placeId(_ region: CLRegion) -> String? {
        region.identifier.hasPrefix(regionPrefix) ? String(region.identifier.dropFirst(regionPrefix.count)) : nil
    }

    // MARK: Delegate (iOS calls these on the main thread; they hop to the main actor)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let a = Self.map(status)
            if self.waiting != nil {
                switch a {
                case .whenInUse, .always: self.manager.requestLocation()
                case .denied, .restricted: self.finish(.failure(.denied))
                case .notDetermined: break
                }
            }
            if self.wantAlways, a == .whenInUse {
                self.wantAlways = false
                self.manager.requestAlwaysAuthorization()
            }
            self.onAuthorization?(a)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.finish(.success(loc)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let why = error.localizedDescription
        Task { @MainActor in self.finish(.failure(.unavailable(why))) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let id = Self.placeId(region) else { return }
        let now = Date()
        Task { @MainActor in self.onEvent?(.enter(placeId: id, at: now)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let id = Self.placeId(region) else { return }
        let now = Date()
        Task { @MainActor in self.onEvent?(.exit(placeId: id, at: now)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState,
                                     for region: CLRegion) {
        guard let id = Self.placeId(region) else { return }
        let now = Date()
        Task { @MainActor in
            switch state {
            case .inside: self.onEvent?(.inside(placeId: id, at: now))
            case .outside: self.onEvent?(.outside(placeId: id, at: now))
            case .unknown: break
            @unknown default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let arrived = visit.arrivalDate == .distantPast ? nil : visit.arrivalDate
        let departed = visit.departureDate == .distantFuture ? nil : visit.departureDate
        let c = visit.coordinate
        let acc = visit.horizontalAccuracy
        Task { @MainActor in
            self.onEvent?(.visit(latitude: c.latitude, longitude: c.longitude, accuracy: acc, arrived: arrived,
                                 departed: departed))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                                     withError error: Error) {
        let why = error.localizedDescription
        Task { @MainActor in self.onEvent?(.problem("A place couldn't be watched: \(why)")) }
    }
}
