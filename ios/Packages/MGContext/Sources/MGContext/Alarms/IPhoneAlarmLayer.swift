import Foundation

/// Wave W11 (2026-10-11, Mo 9:30 PM: "setting an alarm gets me a widget error every time"). The iPhone backstop used to
/// try AlarmKit and, when AlarmKit threw, schedule nothing and put the error up as a notice — again on every launch
/// (the "already shown" memory was per launch) and for every alarm (the text carried its title). Now a refused AlarmKit
/// alarm falls back to a time-sensitive notification with sound for that alarm, the strap buzz is unchanged, and the
/// Alarms page carries ONE line saying which layer is armed and, when AlarmKit refused, AlarmKit's own words.
public enum IPhoneAlarmLayer {
    /// - Parameters:
    ///   - alarmKitCount / notificationCount: backstops scheduled now, by layer.
    ///   - alarmKitProblem: the last AlarmKit refusal in its own words (domain, code, text), nil when the last attempt
    ///     worked or none was made.
    ///   - problemAt: when it happened.
    ///   - notificationProblem: the last notification scheduling failure, nil if none.
    public static func line(alarmKitCount: Int, notificationCount: Int, alarmKitProblem: String?, problemAt: Date?,
                            notificationProblem: String?, calendar: Calendar) -> String {
        let when = problemAt.map { " (\(Clock12.hm($0, calendar: calendar)))" } ?? ""
        if let n = notificationProblem, alarmKitCount == 0 {
            return "iPhone alarm: NOT armed — \(n)\(when). The strap buzz still runs."
                + (alarmKitProblem.map { " AlarmKit refused: \($0)." } ?? "")
        }
        if notificationCount > 0 {
            let head = alarmKitCount > 0
                ? "iPhone alarm: AlarmKit for \(alarmKitCount), notification with sound for \(notificationCount)"
                : "iPhone alarm: notification with sound (may not wake you on Silent)"
            return head + (alarmKitProblem.map { " — AlarmKit refused: \($0)\(when)" } ?? "") + ". Plus the strap buzz."
        }
        if alarmKitCount > 0 {
            return "iPhone alarm: AlarmKit (rings through Silent and Focus). Plus the strap buzz."
        }
        if let p = alarmKitProblem {
            return "iPhone alarm: none scheduled — AlarmKit refused: \(p)\(when)."
        }
        return "iPhone alarm: none needed right now."
    }
}
