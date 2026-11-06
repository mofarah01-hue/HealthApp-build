import Foundation
import MGDomain

/// T9841 (R-097, e-17): the smart-wake modes Mo can pick (Settings > Sleep & wake). The ids are
/// `SmartWakeOptions.Mode` raw values (MGSignal); the app turns the setting into the options for the plan.
/// Safe defaults (listed in DECISIONS): "Window" stays the default and behaves exactly as before; the three wider modes
/// need tonight's sleep need and fall back to the window without it; the minimum rest share is 75 % (e-17).
public enum SmartWakeModes {
    public struct Mode: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String
    }

    public static let defaultID = "window"
    public static let capMinutes = 90
    public static let restPercentRange = 50...100
    public static let defaultRestPercent = 75

    public static let all: [Mode] = [
        Mode(id: "window", title: "Window",
             detail: "Rings in light sleep inside your smart-wake window before your latest time (10-45 min)."),
        Mode(id: "timeGate", title: "Not before a time",
             detail: "Rings in light sleep after the time you set, up to \(capMinutes) min before your latest time."),
        Mode(id: "open", title: "Open",
             detail: "Rings in light sleep any time in the last \(capMinutes) min once you have had your minimum rest."),
        Mode(id: "needMet", title: "Sleep need met",
             detail: "Rings in light sleep only once your whole sleep need could have been slept, within the last \(capMinutes) min."),
    ]

    public static func isValid(_ id: String) -> Bool { all.contains { $0.id == id } }

    public static func title(_ id: String) -> String { all.first { $0.id == id }?.title ?? all[0].title }

    public static func detail(_ id: String) -> String { all.first { $0.id == id }?.detail ?? all[0].detail }

    /// The note that goes with every non-window mode.
    public static let needNote = "The three wider modes need tonight's sleep need; without it the window is used, so a ring never comes early on a guess."

    /// "6:15 AM", or "not set".
    public static func gateWords(minutes: Int?) -> String {
        guard let m = minutes, (0..<1440).contains(m) else { return "not set" }
        return ClockText.hm(hour: m / 60, minute: m % 60)
    }
}
