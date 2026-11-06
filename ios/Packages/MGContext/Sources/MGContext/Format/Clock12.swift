import Foundation
import MGDomain

/// 12-hour clock text for the lines wave W11 adds ("9:12 PM"; Mo reads times as AM/PM). Since the W10 merge
/// (2026-10-11) it is a calendar-taking shim over W10's shared formatter, `MGDomain.ClockText`, so every clock time
/// comes from one place.
enum Clock12 {
    static func hm(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return ClockText.hm(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }
}
