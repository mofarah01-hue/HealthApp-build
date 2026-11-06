import CoreLocation
import Foundation
import MGContext

// The Fajr wake's location (added 2026-10-11): the phone's location, read ONCE when Mo taps "Use my location"
// (when-in-use permission, NSLocationWhenInUseUsageDescription), reduced to two decimals (~1 km — prayer times move by
// seconds over that distance) and kept in the alarm settings so Fajr works on offline days. The place name comes from
// reverse geocoding when the phone is online; without it the coordinates are shown.

@MainActor
final class AlarmsLocation: NSObject, CLLocationManagerDelegate {
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

    private var manager: CLLocationManager?
    private var waiting: CheckedContinuation<Result<CLLocation, Failure>, Never>?

    /// Asks for when-in-use permission if needed, then one location fix.
    func readOnce() async -> Result<SavedLocation, Failure> {
        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        if waiting != nil { return .failure(.unavailable("a reading is already running")) }
        let fix: Result<CLLocation, Failure> = await withCheckedContinuation { c in
            waiting = c
            switch m.authorizationStatus {
            case .notDetermined: m.requestWhenInUseAuthorization()     // the delegate continues
            case .denied, .restricted: finish(.failure(.denied))
            default: m.requestLocation()
            }
        }
        switch fix {
        case .failure(let f): return .failure(f)
        case .success(let loc):
            let lat = (loc.coordinate.latitude * 100).rounded() / 100
            let lon = (loc.coordinate.longitude * 100).rounded() / 100
            let name = await placeName(loc)
            return .success(SavedLocation(coordinates: PrayerCoordinates(latitude: lat, longitude: lon), name: name,
                                          timeZoneId: TimeZone.current.identifier, at: Date()))
        }
    }

    private func finish(_ r: Result<CLLocation, Failure>) {
        let c = waiting
        waiting = nil
        c?.resume(returning: r)
    }

    private func placeName(_ loc: CLLocation) async -> String? {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(loc)
        return marks?.first?.locality ?? marks?.first?.administrativeArea
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.waiting != nil else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager?.requestLocation()
            case .denied, .restricted: self.finish(.failure(.denied))
            default: break
            }
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
}
