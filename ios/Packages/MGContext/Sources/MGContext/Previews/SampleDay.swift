import Foundation
import MGDomain

/// The prototype's SAMPLE day (Sun 11 Oct 2026; woke 06:52, bedtime 22:30, up by 07:10) for SwiftUI previews and
/// SAMPLE mode. Every value built here carries `sample: true`. Never written to the store (ARCHITECTURE §4.12).
/// Source of every number: app/prototype/index.html (SCN list, sample day `D`, caffeine model run with node).
public enum SampleDay {
    /// The phone's calendar, so the dial and times read right in any time zone.
    public static let calendar: Calendar = Calendar.current

    /// 2026-10-11 at hh:mm (dayOffset −1 = Sat 10 Oct, +1 = Mon 12 Oct).
    public static func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
        let c = DateComponents(year: 2026, month: 10, day: 11 + dayOffset, hour: hour, minute: minute)
        return calendar.date(from: c) ?? Date(timeIntervalSinceReferenceDate: 813_456_000)
    }

    /// Prototype hour floats on the day of 11 Oct: 23.03 of the previous evening is −0.97; 24.4 is 00:24 on the 12th.
    static func hours(_ h: Double) -> Date {
        at(0, 0).addingTimeInterval(h * 3600)
    }

    public static let wake = at(6, 52)
    public static let bedtime = at(22, 30)
    public static let latestWake = at(7, 10, dayOffset: 1)
    public static var day: LocalDay { LocalDay(date: at(12, 0), calendar: calendar) }

    public static func receipt(_ on: ComputedOn, _ tier: Tier, _ hour: Int, _ minute: Int, dayOffset: Int = 0,
                               method: String? = nil, citation: String? = nil) -> Receipt {
        Receipt(computedOn: on, tier: tier, at: at(hour, minute, dayOffset: dayOffset), method: method,
                citation: citation)
    }

    /// A sample value (`sample: true`).
    public static func value(_ text: String, _ unit: String? = nil, _ receipt: Receipt,
                             _ style: DisplayValue.Style = .plain) -> DisplayValue {
        .value(text: text, unit: unit, receipt: receipt, style: style, sample: true)
    }

    /// Phase anchors and context of the sample day at `now`, from the real phase arithmetic.
    public static func context(at now: Date) -> DayContext {
        let anchors = PhaseClock.anchors(now: now, calendar: calendar, detectedWake: wake, medianWake14: wake,
                                         latestWakeSetting: DateComponents(hour: 7, minute: 10),
                                         recommendedBedtime: bedtime, medianOnset14: at(22, 44))
        let bounds = PhaseClock.boundaries(anchors)
        let phase = bounds.phase(at: now)
        let theme = PhaseClock.dayTheme(at: now, phase: phase, boundaries: bounds)
        let justWoke = PhaseClock.isJustWoke(now: now, phase: phase, wake: anchors.wake, checkinAnswered: false)
        let next = bounds.changeInstants.first { $0 > now } ?? now.addingTimeInterval(3600)
        return DayContext(anchors: anchors, phase: phase, theme: theme, justWoke: justWoke, moments: [], peek: nil,
                          peeksHeld: phase == .night || phase == .lateNight, nextChange: next)
    }
}

/// The ten prototype scenarios (UX-SPEC header: woke, morning, lunch, nap, off, wlive, wend, sundown, night, late).
public enum PreviewScenario: String, Sendable, CaseIterable {
    case woke, morning, lunch, nap, off, wlive, wend, sundown, night, late

    public var label: String {
        switch self {
        case .woke: return "Just woke"
        case .morning: return "Mid-morning"
        case .lunch: return "After lunch"
        case .nap: return "Nap detected"
        case .off: return "Strap off"
        case .wlive: return "Workout live"
        case .wend: return "Workout just ended"
        case .sundown: return "Sundown"
        case .night: return "Bedtime"
        case .late: return "Late night"
        }
    }

    public var now: Date {
        switch self {
        case .woke: return SampleDay.at(7, 5)
        case .morning: return SampleDay.at(9, 40)
        case .lunch: return SampleDay.at(13, 50)
        case .nap: return SampleDay.at(14, 40)
        case .off: return SampleDay.at(15, 40)
        case .wlive: return SampleDay.at(17, 45)
        case .wend: return SampleDay.at(18, 25)
        case .sundown: return SampleDay.at(20, 5)
        case .night: return SampleDay.at(22, 10)
        case .late: return SampleDay.at(0, 40, dayOffset: 1)
        }
    }
}
