import Foundation

// Phase vocabulary of UX-SPEC §1.1 and §2 (frozen names: ARCHITECTURE §4.7).

/// The six day phases. They are anchored to Mo's wake W and bedtime B, never to the clock (UX §2).
public enum DayPhase: String, Sendable, CaseIterable {
    case morning, earlyAfternoon, lateAfternoon, sundown, night, lateNight

    /// Display name as UX §2 writes it ("Early afternoon").
    public var title: String {
        switch self {
        case .morning: return "Morning"
        case .earlyAfternoon: return "Early afternoon"
        case .lateAfternoon: return "Late afternoon"
        case .sundown: return "Sundown"
        case .night: return "Night"
        case .lateNight: return "Late night"
        }
    }
}

/// The four themes of UX §1.1. Colours live in MGDesign (`Theme.colors(for:)`).
public enum ThemeName: String, Sendable {
    case cream, creamGolden, emerald, emeraldLow
}

/// Where tonight's bedtime B came from (UX §2 "No bedtime" fallback).
public enum BedtimeSource: Sendable {
    /// ALG-115 recommended bedtime for tonight.
    case model
    /// Median sleep onset of the last 14 days. Kicker: "bedtime from your usual".
    case usual
    /// Nothing known: 23:00 (UX §2).
    case fallback2300
}

/// Settings → Theme (UX §1.1). `followSystem` carries the system appearance because MGContext is pure Foundation;
/// the app reads `@Environment(\.colorScheme)` and passes it in.
public enum ThemePreference: Equatable, Sendable {
    case followDay
    case cream
    case emerald
    case followSystem(systemIsDark: Bool)
}

/// The stored form of the theme setting (no system appearance inside), for Settings and persistence.
public enum ThemeSetting: String, Codable, Sendable, CaseIterable {
    case followDay, cream, emerald, followSystem

    public var title: String {
        switch self {
        case .followDay: return "Follow the day"
        case .cream: return "Cream"
        case .emerald: return "Emerald low"
        case .followSystem: return "Follow iOS"
        }
    }

    public func preference(systemIsDark: Bool) -> ThemePreference {
        switch self {
        case .followDay: return .followDay
        case .cream: return .cream
        case .emerald: return .emerald
        case .followSystem: return .followSystem(systemIsDark: systemIsDark)
        }
    }
}

/// A wall-clock time of day (no date). Used for the 14-day medians, the latest-wake setting and the fallbacks.
public struct TimeOfDay: Equatable, Hashable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int
    public var second: Int

    public init(hour: Int, minute: Int, second: Int = 0) {
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// The time of day of `date` in `calendar`'s time zone (the date part is dropped).
    public init(of date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }

    /// From settings components; `nil` when `hour` is missing.
    public init?(_ components: DateComponents) {
        guard let h = components.hour else { return nil }
        self.init(hour: h, minute: components.minute ?? 0, second: components.second ?? 0)
    }

    public var secondsIntoDay: Int { hour * 3600 + minute * 60 + second }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool { lhs.secondsIntoDay < rhs.secondsIntoDay }
}

/// W, B and L for the wake day that contains `now` (UX §2).
public struct PhaseAnchors: Equatable, Sendable {
    /// W: today's wake (strap-detected, or assumed).
    public var wake: Date
    /// true when W is not a detection: 14-day median, else the latest-wake setting, else 07:00. Kicker says "wake assumed".
    public var wakeAssumed: Bool
    /// B: tonight's bedtime.
    public var bedtime: Date
    public var bedtimeSource: BedtimeSource
    /// L: the latest wake for the morning after B (Settings → Sleep & wake). `nil` until Mo fills it (BRIEF default 3).
    public var latestWake: Date?

    public init(wake: Date, wakeAssumed: Bool, bedtime: Date, bedtimeSource: BedtimeSource, latestWake: Date?) {
        self.wake = wake
        self.wakeAssumed = wakeAssumed
        self.bedtime = bedtime
        self.bedtimeSource = bedtimeSource
        self.latestWake = latestWake
    }
}

/// The phase start instants for one wake day, after the UX §2 clamps. Always monotonic:
/// wake ≤ earlyAfternoon ≤ lateAfternoon ≤ sundown ≤ night ≤ lateNight. A phase whose start equals the next one's is skipped.
public struct PhaseBoundaries: Equatable, Sendable {
    public var wake: Date
    public var earlyAfternoon: Date
    public var lateAfternoon: Date
    public var sundown: Date
    public var night: Date
    public var lateNight: Date
    /// Start of "Cream, golden" (last 60 min of late afternoon); `nil` when late afternoon is skipped (short day).
    public var goldenStart: Date?

    public init(wake: Date, earlyAfternoon: Date, lateAfternoon: Date, sundown: Date, night: Date, lateNight: Date,
                goldenStart: Date?) {
        self.wake = wake
        self.earlyAfternoon = earlyAfternoon
        self.lateAfternoon = lateAfternoon
        self.sundown = sundown
        self.night = night
        self.lateNight = lateNight
        self.goldenStart = goldenStart
    }

    /// The phase at `date`. Before W it is still last night's Late night.
    public func phase(at date: Date) -> DayPhase {
        if date < wake { return .lateNight }
        if date < earlyAfternoon { return .morning }
        if date < lateAfternoon { return .earlyAfternoon }
        if date < sundown { return .lateAfternoon }
        if date < night { return .sundown }
        if date < lateNight { return .night }
        return .lateNight
    }

    /// Where a phase starts in this wake day.
    public func start(of phase: DayPhase) -> Date {
        switch phase {
        case .morning: return wake
        case .earlyAfternoon: return earlyAfternoon
        case .lateAfternoon: return lateAfternoon
        case .sundown: return sundown
        case .night: return night
        case .lateNight: return lateNight
        }
    }

    /// Every boundary after the wake, in order (golden included when present).
    public var changeInstants: [Date] {
        var all = [earlyAfternoon, lateAfternoon, sundown, night, lateNight]
        if let g = goldenStart { all.append(g) }
        return all.sorted()
    }
}
