import Foundation

// Screen Time (Mac build, Nov 2026): the Family Controls side. Compiled only where the build defines SCREEN_TIME (project.yml,
// the Xcode build) AND the SDK has FamilyControls. The xtool build defines neither, so it is unchanged: no entitlement, no
// extensions, and the Screen Time page says so. WRITTEN, NOT COMPILED: this needs Xcode and has not run (first runner build).
#if SCREEN_TIME && canImport(FamilyControls)
import Combine
import DeviceActivity
import FamilyControls
import MGContext
import SwiftUI

@MainActor
final class ScreenTimeController: ObservableObject {
    private static let selectionKey = "screenTime.selection"

    @Published var selection = FamilyActivitySelection() {
        didSet { persistSelection() }
    }
    @Published private(set) var authorization: ScreenTimeAuthorization = .notDetermined
    @Published private(set) var monitoring = false
    /// Mo's pre-fill: 60 minutes. Applies from the next start.
    @Published var eveningThreshold: Int = {
        let v = UserDefaults.standard.integer(forKey: "screenTime.eveningThreshold")
        return ScreenTimePlan.eveningThresholdChoices.contains(v) ? v : ScreenTimePlan.defaultEveningThreshold
    }() {
        didSet { UserDefaults.standard.set(eveningThreshold, forKey: "screenTime.eveningThreshold") }
    }

    private let center = DeviceActivityCenter()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.selectionKey),
           let s = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selection = s
        }
        refresh()
    }

    func refresh() {
        switch AuthorizationCenter.shared.authorizationStatus {
        case .approved: authorization = .approved
        case .denied: authorization = .denied
        default: authorization = .notDetermined
        }
        monitoring = !center.activities.isEmpty
    }

    private func persistSelection() {
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: Self.selectionKey)
        }
    }

    /// "3 apps, 1 category"; nil when nothing is picked.
    var selectionSummary: String? {
        let a = selection.applicationTokens.count, c = selection.categoryTokens.count, w = selection.webDomainTokens.count
        guard a + c + w > 0 else { return nil }
        var parts: [String] = []
        if a > 0 { parts.append("\(a) app\(a == 1 ? "" : "s")") }
        if c > 0 { parts.append("\(c) categor\(c == 1 ? "y" : "ies")") }
        if w > 0 { parts.append("\(w) website\(w == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        refresh()
    }

    /// Registers the day / evening / night schedules (ScreenTimePlan) with one event per threshold on the picked apps.
    /// `eveningEndMinutes`: where the evening window ends (the usual bedtime, ScreenTimePlan.eveningEnd).
    func startMonitoring(eveningEndMinutes: Int) throws {
        guard !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty else {
            throw ScreenTimeError.nothingPicked
        }
        center.stopMonitoring()
        for w in ScreenTimePlan.windows(eveningEndMinutes: eveningEndMinutes, eveningThreshold: eveningThreshold) {
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            for m in w.thresholds {
                events[DeviceActivityEvent.Name(ScreenTimePlan.eventName(window: w.id, minutes: m))] = DeviceActivityEvent(
                    applications: selection.applicationTokens, categories: selection.categoryTokens,
                    webDomains: selection.webDomainTokens, threshold: DateComponents(minute: m))
            }
            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: w.startHour, minute: w.startMinute),
                intervalEnd: DateComponents(hour: w.endHour, minute: w.endMinute), repeats: true)
            try center.startMonitoring(DeviceActivityName(w.id), during: schedule, events: events)
        }
        refresh()
    }

    func stopMonitoring() {
        center.stopMonitoring()
        refresh()
    }

    enum ScreenTimeError: Error, CustomStringConvertible {
        case nothingPicked
        var description: String { "Pick apps or categories first." }
    }
}
#endif
