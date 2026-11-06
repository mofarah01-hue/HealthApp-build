import CryptoKit
import Foundation
import MGDomain

/// Screen Time through Family Controls (Mac build, Nov 2026; docs/features/SCREEN-TIME.md section 4). Pure part: the plan
/// (which schedules, which thresholds), the event name the Activity Monitor extension writes, and the `screen_time` event
/// the app logs from it. iOS gives the monitor extension callbacks only ("selected apps passed N minutes in this window"),
/// never a running total, so every event says "at least N minutes" (`minutes_min`) and nothing more.
public enum ScreenTimePlan {
    public struct Window: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var startHour: Int
        public var startMinute: Int
        public var endHour: Int
        public var endMinute: Int
        /// Minutes of use inside the window at which iOS calls the extension.
        public var thresholds: [Int]
    }

    /// Pre-filled values (Mo, Nov 2026): the evening threshold is 60 minutes; the evening window runs from 9 PM to the usual
    /// bedtime (the 14-day median the app already computes) when that is before midnight, else to 11:59 PM.
    public static let defaultEveningThreshold = 60
    public static let eveningThresholdChoices = [30, 60, 120]
    public static let defaultEveningEndMinutes = 23 * 60 + 59

    /// The evening window's end as minutes since midnight, from a bedtime (minutes since midnight, nil = unknown): at least
    /// 9:30 PM (iOS wants an interval of at least 15 minutes), 11:59 PM when the bedtime is after midnight.
    public static func eveningEnd(bedtimeMinutes: Int?) -> Int {
        guard let b = bedtimeMinutes else { return defaultEveningEndMinutes }
        if b < 12 * 60 { return defaultEveningEndMinutes }          // after midnight: the night window covers it
        return min(max(b, 21 * 60 + 30), defaultEveningEndMinutes)
    }

    /// `day` is the whole day, `night` is midnight to 6 AM, `evening` is 9 PM to `eveningEndMinutes` with one threshold.
    public static func windows(eveningEndMinutes: Int = defaultEveningEndMinutes,
                               eveningThreshold: Int = defaultEveningThreshold) -> [Window] {
        let end = min(max(eveningEndMinutes, 21 * 60 + 15), defaultEveningEndMinutes)
        return [
            Window(id: "day", title: "All day", startHour: 0, startMinute: 0, endHour: 23, endMinute: 59,
                   thresholds: [30, 60, 120, 240]),
            Window(id: "evening", title: "Evening (9 PM to bedtime)", startHour: 21, startMinute: 0,
                   endHour: end / 60, endMinute: end % 60, thresholds: [eveningThreshold]),
            Window(id: "night", title: "Night (midnight to 6 AM)", startHour: 0, startMinute: 0, endHour: 6, endMinute: 0,
                   thresholds: [5, 15, 30]),
        ]
    }

    /// The window ids and titles (thresholds depend on the chosen evening threshold).
    public static let windows: [Window] = windows()

    public static func window(_ id: String) -> Window? { windows.first { $0.id == id } }

    /// A threshold iOS can report for a window: any whole number of minutes from 1 to 600.
    static let minutesRange = 1...600

    /// "st.evening.60": the DeviceActivityEvent.Name the app registers.
    public static func eventName(window: String, minutes: Int) -> String { "st.\(window).\(minutes)" }

    /// Inverse of `eventName`; nil for anything that is not exactly a planned window and one of its thresholds.
    public static func parse(eventName: String) -> (window: String, minutes: Int)? {
        let parts = eventName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "st", let w = window(parts[1]), let m = Int(parts[2]),
              minutesRange.contains(m) else { return nil }
        return (w.id, m)
    }
}

public enum ScreenTimeThresholds {
    /// One threshold the extension reported.
    public struct Reading: Equatable, Sendable, Identifiable {
        public var window: String
        public var minutes: Int
        public var at: Date
        public var id: String { "\(window).\(minutes).\(at.timeIntervalSince1970)" }
        public init(window: String, minutes: Int, at: Date) {
            self.window = window
            self.minutes = minutes
            self.at = at
        }
    }

    /// The window and threshold in an event name, at `at`; nil for a name that is not in the plan (never invented).
    public static func reading(eventName: String, at: Date) -> Reading? {
        ScreenTimePlan.parse(eventName: eventName).map { Reading(window: $0.window, minutes: $0.minutes, at: at) }
    }

    /// Same window + threshold on the same local day is the same event: a re-read or a second callback never duplicates.
    static func eventID(_ r: Reading, calendar: Calendar) -> UUID {
        let c = calendar.dateComponents([.year, .month, .day], from: r.at)
        let day = "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        let key = "screentime|\(ScreenTimeFields.Route.deviceActivityThreshold.rawValue)|\(r.window)|\(r.minutes)|\(day)"
        var h = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        h[6] = (h[6] & 0x0F) | 0x80
        h[8] = (h[8] & 0x3F) | 0x80
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }

    public static func event(_ r: Reading, calendar: Calendar) -> EventRecord {
        let title = ScreenTimePlan.window(r.window)?.title ?? r.window
        return EventRecord(id: eventID(r, calendar: calendar), type: .screenTime, at: r.at, loggedAt: nil, source: .detected,
                           note: "Screen Time (iOS Family Controls): the apps and categories you picked passed \(r.minutes) minutes "
                               + "of use in the window \"\(title)\" by this time; at least \(r.minutes), not a total",
                           payload: .screenTime(ScreenTimeFields(kind: .use, minutesMin: Double(r.minutes),
                                                                  route: .deviceActivityThreshold, category: r.window)))
    }
}

// MARK: Settings > Screen Time page

public enum ScreenTimeAuthorization: Equatable, Sendable {
    case notDetermined, approved, denied
}

public struct ScreenTimeInput: Sendable {
    /// False on a build without Family Controls (the xtool build): the page says so and offers nothing.
    public var supported: Bool
    public var authorization: ScreenTimeAuthorization
    public var monitoring: Bool
    /// "3 apps, 1 category"; nil = nothing picked yet.
    public var selectionSummary: String?
    /// The evening window: 9 PM to this many minutes after midnight, with this threshold; `bedtimeNote` says where the end
    /// came from ("your usual bedtime", "the default").
    public var eveningEndMinutes: Int = ScreenTimePlan.defaultEveningEndMinutes
    public var eveningThreshold: Int = ScreenTimePlan.defaultEveningThreshold
    public var bedtimeNote: String = "the default (11:59 PM)"
    /// Thresholds read from the App Group log, newest last.
    public var readings: [ScreenTimeThresholds.Reading]
    /// Why the App Group log cannot be read (not provisioned in this signature), if so.
    public var logProblem: String?
    public var problem: String?
    public var now: Date
    public var calendar: Calendar

    public init(supported: Bool, authorization: ScreenTimeAuthorization, monitoring: Bool, selectionSummary: String?,
                readings: [ScreenTimeThresholds.Reading], logProblem: String?, problem: String?, now: Date, calendar: Calendar) {
        self.supported = supported
        self.authorization = authorization
        self.monitoring = monitoring
        self.selectionSummary = selectionSummary
        self.readings = readings
        self.logProblem = logProblem
        self.problem = problem
        self.now = now
        self.calendar = calendar
    }
}

public struct ScreenTimeState: Equatable, Sendable {
    public var supported: Bool
    public var message: String?
    public var sections: [UsageState.Section]
    public var actions: [ActionState]
}

public enum ScreenTimePresenter {
    typealias Row = UsageState.Row

    static let source = "Source: iOS Screen Time through Family Controls (DeviceActivity). Thresholds are the only numbers iOS lets the app keep; the usage totals in the box below are drawn by iOS and cannot be copied out of it."

    static func clock(_ minutes: Int) -> String { ClockText.hm(hour: minutes / 60, minute: minutes % 60) }

    public static func make(_ i: ScreenTimeInput) -> ScreenTimeState {
        guard i.supported else {
            return ScreenTimeState(
                supported: false,
                message: "This build of HealthApp was made without Family Controls, so Screen Time is off. It comes with the Xcode build (the Mac runner), which has the Screen Time extensions.",
                sections: [], actions: [])
        }
        let auth: String
        switch i.authorization {
        case .notDetermined: auth = "not asked yet"
        case .approved: auth = "approved"
        case .denied: auth = "denied: change it in iOS Settings > Screen Time > Apps with Screen Time Access"
        }
        var status = [
            Row(id: "auth", title: "Family Controls access", value: auth),
            Row(id: "pick", title: "Apps and categories", value: i.selectionSummary ?? "none picked"),
            Row(id: "mon", title: "Watching", value: i.monitoring ? "on: day, evening and night windows" : "off",
                detail: i.monitoring ? "iOS calls the app's extension when the picked apps pass each threshold." : nil),
            Row(id: "evening", title: "Evening window",
                value: "9 PM to \(clock(i.eveningEndMinutes)), at \(i.eveningThreshold) min",
                detail: "Ends at \(i.bedtimeNote). Set when you start watching; stop and start again to move it."),
        ]
        if let p = i.problem { status.append(Row(id: "problem", title: "Problem", value: p)) }
        var sections = [UsageState.Section(id: "status", title: "Screen Time", note: source, rows: status)]

        let day = i.calendar.startOfDay(for: i.now)
        let today = i.readings.filter { $0.at >= day }
        var rows: [Row] = []
        for w in ScreenTimePlan.windows {
            let got = today.filter { $0.window == w.id }
            guard let top = got.max(by: { $0.minutes < $1.minutes }) else { continue }
            let passed = got.sorted { $0.minutes < $1.minutes }
                .map { "\($0.minutes) at \(MGFormat.time($0.at, calendar: i.calendar))" }.joined(separator: ", ")
            rows.append(Row(id: "w.\(w.id)", title: w.title,
                            value: "at least \(top.minutes) min by \(MGFormat.time(top.at, calendar: i.calendar))",
                            detail: "thresholds passed today: " + passed))
        }
        var todaySection = UsageState.Section(id: "today", title: "Passed today (picked apps)",
                                              note: "At least, never a total: iOS only says a threshold was crossed.", rows: rows)
        if rows.isEmpty {
            todaySection.message = i.monitoring
                ? "No threshold passed yet today. That can also mean the extension has not run: iOS starts it when the picked apps are used."
                : "Switch watching on to start."
        }
        sections.append(todaySection)
        if let p = i.logProblem {
            sections.append(UsageState.Section(id: "log", title: "Log", rows: [], message: p))
        }

        var actions: [ActionState] = []
        switch i.authorization {
        case .approved:
            if i.monitoring {
                actions.append(ActionState(id: "stop", title: "Stop watching", intent: .screenTime(.stopMonitoring)))
            } else {
                actions.append(ActionState(id: "start", title: "Start watching", intent: .screenTime(.startMonitoring),
                                           enabled: i.selectionSummary != nil,
                                           disabledReason: i.selectionSummary == nil ? "Pick apps or categories first." : nil))
            }
        case .notDetermined:
            actions.append(ActionState(id: "auth", title: "Allow Screen Time access", intent: .screenTime(.requestAuthorization)))
        case .denied:
            break
        }
        actions.append(ActionState(id: "refresh", title: "Read the log now", intent: .screenTime(.refresh)))
        return ScreenTimeState(supported: true, message: nil, sections: sections, actions: actions)
    }
}
