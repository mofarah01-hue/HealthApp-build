import Combine
import Foundation
import MGContext
import MGDomain

// Settings > Screen Time (Mac build, Nov 2026; docs/features/SCREEN-TIME.md section 4). Follows the Usage page's pattern:
// UIIntent.screenTime -> this file -> ScreenTimeModel.state (ScreenTimePresenter, MGContext) -> UI/ScreenTime.
// Thresholds the Activity Monitor extension wrote to the App Group are logged as `screen_time` events (route
// device_activity_threshold, minutes_min), so they reach the PC like every other event. Each is "at least N minutes".

@MainActor
final class ScreenTimeModel: ObservableObject {
    @Published var state: ScreenTimeState?
    var readings: [ScreenTimeThresholds.Reading] = []
    var problem: String?
    var logProblem: String?
    #if SCREEN_TIME && canImport(FamilyControls)
    let controller = ScreenTimeController()
    #endif
}

extension AppModel {
    private static let screenTimeIngestedKey = "screenTime.ingested"

    func screenTimeAction(_ action: ScreenTimeAction) async {
        let m = screenTime
        _ = m
        switch action {
        case .open:
            if paths[tab]?.last != .screenTime { push(.screenTime) }
            await ingestScreenTime()
        case .refresh:
            await ingestScreenTime()
        case .requestAuthorization:
            #if SCREEN_TIME && canImport(FamilyControls)
            do { try await m.controller.requestAuthorization(); m.problem = nil } catch { m.problem = "Access was not given: \(error)" }
            #else
            break
            #endif
        case .startMonitoring:
            #if SCREEN_TIME && canImport(FamilyControls)
            do { try m.controller.startMonitoring(eveningEndMinutes: screenTimeEveningEnd().minutes); m.problem = nil } catch { m.problem = "Could not start watching: \(error)" }
            #else
            break
            #endif
        case .stopMonitoring:
            #if SCREEN_TIME && canImport(FamilyControls)
            m.controller.stopMonitoring()
            #else
            break
            #endif
        case .setEveningThreshold(let minutes):
            #if SCREEN_TIME && canImport(FamilyControls)
            if ScreenTimePlan.eveningThresholdChoices.contains(minutes) { m.controller.eveningThreshold = minutes }
            #else
            _ = minutes
            #endif
        }
        screenTimePublish()
    }

    /// Reads the App Group log and upserts one `screen_time` event per new threshold. Safe to call often: ids are stable per
    /// window + threshold + local day, and what was already written is remembered (30 days).
    func ingestScreenTime() async {
        let m = screenTime
        guard ScreenTimeShared.fileURL() != nil else {
            m.logProblem = "The App Group is not provisioned in this signature, so the extension cannot pass anything to the app."
            screenTimePublish()
            return
        }
        m.logProblem = nil
        let records = ScreenTimeShared.readAll()
        var readings: [ScreenTimeThresholds.Reading] = []
        for r in records where r.kind == "threshold" {
            if let name = r.event, let reading = ScreenTimeThresholds.reading(eventName: name, at: r.at) { readings.append(reading) }
        }
        m.readings = readings
        if !isSample {
            let defaults = UserDefaults.standard
            let cutoff = clock.now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970
            var done = (defaults.dictionary(forKey: Self.screenTimeIngestedKey) as? [String: Double] ?? [:]).filter { $0.value >= cutoff }
            for reading in readings {
                let key = "\(reading.window).\(reading.minutes).\(reading.at.timeIntervalSince1970)"
                if done[key] != nil { continue }
                do {
                    _ = try await services.store.upsertEvent(ScreenTimeThresholds.event(reading, calendar: calendar))
                    done[key] = reading.at.timeIntervalSince1970
                } catch {
                    m.problem = "A threshold could not be saved: \(error)"
                    break
                }
            }
            defaults.set(done, forKey: Self.screenTimeIngestedKey)
        }
        screenTimePublish()
    }

    /// Where the evening window ends: the usual bedtime (the 14-day median Today already uses) when the app has one, else the
    /// default. `note` says which, for the page.
    func screenTimeEveningEnd() -> (minutes: Int, note: String) {
        guard let a = lastContext?.anchors, a.bedtimeSource == .usual else {
            return (ScreenTimePlan.defaultEveningEndMinutes, "the default (11:59 PM): no usual bedtime yet")
        }
        let c = calendar.dateComponents([.hour, .minute], from: a.bedtime)
        let bed = (c.hour ?? 23) * 60 + (c.minute ?? 0)
        return (ScreenTimePlan.eveningEnd(bedtimeMinutes: bed), "your usual bedtime (median of the last 14 nights)")
    }

    func screenTimePublish() {
        let m = screenTime
        #if SCREEN_TIME && canImport(FamilyControls)
        m.controller.refresh()
        var input = ScreenTimeInput(supported: true, authorization: m.controller.authorization, monitoring: m.controller.monitoring,
                                    selectionSummary: m.controller.selectionSummary, readings: m.readings,
                                    logProblem: m.logProblem, problem: m.problem, now: clock.now, calendar: calendar)
        let evening = screenTimeEveningEnd()
        input.eveningEndMinutes = evening.minutes
        input.eveningThreshold = m.controller.eveningThreshold
        input.bedtimeNote = evening.note
        #else
        let input = ScreenTimeInput(supported: false, authorization: .notDetermined, monitoring: false, selectionSummary: nil,
                                    readings: [], logProblem: nil, problem: nil, now: clock.now, calendar: calendar)
        #endif
        let s = ScreenTimePresenter.make(input)
        if m.state != s { m.state = s }
    }
}
