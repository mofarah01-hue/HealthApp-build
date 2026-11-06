import DeviceActivity
import Foundation

// Screen Time: the DeviceActivityMonitor extension (Mac build, Nov 2026). iOS starts it in its own process when a schedule the
// app registered (ScreenTimePlan: day, evening, night) starts or ends, or when the picked apps pass a threshold. It writes one
// record per callback to the App Group file (App/ScreenTime/ScreenTimeShared.swift, compiled into this target) and does
// nothing else: no network (the sandbox forbids it), no usage numbers (iOS does not hand them to a monitor).
// WRITTEN, NOT COMPILED: first runner build.

final class ActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        ScreenTimeShared.append(.init(kind: "interval_start", activity: activity.rawValue, event: nil, at: Date()))
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        ScreenTimeShared.append(.init(kind: "interval_end", activity: activity.rawValue, event: nil, at: Date()))
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        ScreenTimeShared.append(.init(kind: "threshold", activity: activity.rawValue, event: event.rawValue, at: Date()))
    }
}
