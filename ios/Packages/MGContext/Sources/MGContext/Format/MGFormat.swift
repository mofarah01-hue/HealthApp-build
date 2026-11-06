import Foundation
import MGDomain

/// Text formats of UX-SPEC §1.3: clock times 12-hour with AM/PM ("10:30 PM", MGDomain ClockText; W10, 2026-10-11 —
/// it said 24-hour "22:30" before Mo asked), durations "7 h 08", English kicker dates ("SUN 11 OCT").
/// Locale-independent on purpose: the app's copy is English and must read the same on every phone setting.
public enum MGFormat {
    static let weekdayShort = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    static let weekdayLong = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdayMid = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let monthShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    // MARK: Times

    /// "6:52 AM" — 12-hour, in `calendar`'s time zone, whatever the phone's 12/24 h setting (ClockText).
    public static func time(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return ClockText.hm(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    public static func time(_ t: TimeOfDay) -> String { ClockText.hm(hour: t.hour, minute: t.minute) }

    /// "2:05–2:31 PM" / "11:30 PM–1:05 AM" (en dash, no spaces).
    public static func timeRange(_ start: Date, _ end: Date, calendar: Calendar) -> String {
        let a = calendar.dateComponents([.hour, .minute], from: start)
        let b = calendar.dateComponents([.hour, .minute], from: end)
        return ClockText.range((a.hour ?? 0, a.minute ?? 0), (b.hour ?? 0, b.minute ?? 0))
    }

    // MARK: Durations

    /// "7 h 08" from one hour up, "28 min" below. Whole minutes, truncated (elapsed time never rounds up);
    /// negative input reads as 0.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        return duration(minutes: Int((max(0, seconds) / 60).rounded(.down)))
    }

    public static func duration(minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) min" }
        return String(format: "%d h %02d", m / 60, m % 60)
    }

    /// "in 2 h 25" / "in 20 min" until `target`. Rounds up to the minute (a countdown never shows less time than is left);
    /// "now" once reached.
    public static func countdown(to target: Date, from now: Date) -> String {
        let s = target.timeIntervalSince(now)
        guard s > 0 else { return "now" }
        return "in " + duration(minutes: Int((s / 60).rounded(.up)))
    }

    // MARK: Dates

    /// "SUN 11 OCT".
    public static func kickerDate(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.weekday, .day, .month], from: date)
        let wd = weekdayShort[((c.weekday ?? 1) - 1) % 7]
        let mo = monthShort[((c.month ?? 1) - 1) % 12].uppercased()
        return "\(wd) \(c.day ?? 0) \(mo)"
    }

    /// "Sunday" (Today's title).
    public static func weekdayTitle(_ date: Date, calendar: Calendar) -> String {
        weekdayLong[((calendar.component(.weekday, from: date)) - 1) % 7]
    }

    /// "Thu 9 Oct" (old PC results: "PC · from Thu 9 Oct", UX §13).
    public static func shortDate(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.weekday, .day, .month], from: date)
        return "\(weekdayMid[((c.weekday ?? 1) - 1) % 7]) \(c.day ?? 0) \(monthShort[((c.month ?? 1) - 1) % 12])"
    }

    // MARK: Kicker

    /// Today's kicker (UX §3.2): "SUN 11 OCT · MORNING · WOKE 06:52".
    /// After midnight in Late night the wake reads "UP SINCE 06:52" (prototype). Fallbacks say so (UX §2):
    /// "WAKE ASSUMED 07:00"; from late afternoon on a bedtime that is not the model's adds "BEDTIME FROM YOUR USUAL"
    /// or "BEDTIME 11:00 PM DEFAULT".
    public static func kicker(_ context: DayContext, now: Date, calendar: Calendar) -> String {
        var parts = [kickerDate(now, calendar: calendar), context.phase.title.uppercased()]
        let w = time(context.anchors.wake, calendar: calendar)
        if context.anchors.wakeAssumed {
            parts.append("WAKE ASSUMED \(w)")
        } else if calendar.isDate(context.anchors.wake, inSameDayAs: now) {
            parts.append("WOKE \(w)")
        } else {
            parts.append("UP SINCE \(w)")
        }
        let bedtimePhases: [DayPhase] = [.lateAfternoon, .sundown, .night, .lateNight]
        if bedtimePhases.contains(context.phase) {
            switch context.anchors.bedtimeSource {
            case .model: break
            case .usual: parts.append("BEDTIME FROM YOUR USUAL")
            case .fallback2300: parts.append("BEDTIME 11:00 PM DEFAULT")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Numbers

    /// Fixed decimals with a dot, no grouping ("11.4"). Locale-independent.
    public static func number(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(max(0, decimals))f", value)
    }

    /// Thousands with commas ("1,840"), as the prototype.
    public static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (value < 0 ? "-" : "") + String(out.reversed())
    }
}
