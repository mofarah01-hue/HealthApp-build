import Foundation

/// Every clock time Mo sees, in one place: 12-hour with AM/PM ("9:24 PM"), whatever the phone's 24-hour setting
/// (W10, Mo 2026-10-11: every time 12-hour, never 24-hour). Durations ("7 h 32") are not clock times and data formats
/// (the contract's "HH:MM" schedule and must-be-up-by strings) are not display: neither uses this.
public enum ClockText {
    /// "9:24 PM", "12:05 AM", "12:00 PM".
    public static func hm(hour: Int, minute: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let h12 = h % 12 == 0 ? 12 : h % 12
        let mm = minute < 10 ? "0\(minute)" : "\(minute)"
        return "\(h12):\(mm) \(h < 12 ? "AM" : "PM")"
    }

    /// "1:50:07 PM" (Settings › Usage: when the PC answered).
    public static func hms(hour: Int, minute: Int, second: Int) -> String {
        let s = hm(hour: hour, minute: minute)
        let ss = second < 10 ? "0\(second)" : "\(second)"
        return String(s.dropLast(3)) + ":" + ss + String(s.suffix(3))
    }

    /// `date` in `timeZone`.
    public static func hm(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return hm(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    /// "2:05–2:31 PM" (one AM/PM when both share it), else "11:30 PM–1:05 AM".
    public static func range(_ a: (hour: Int, minute: Int), _ b: (hour: Int, minute: Int)) -> String {
        let sa = hm(hour: a.hour, minute: a.minute), sb = hm(hour: b.hour, minute: b.minute)
        if sa.suffix(2) == sb.suffix(2) { return String(sa.dropLast(3)) + "–" + sb }
        return sa + "–" + sb
    }
}
