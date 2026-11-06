import Foundation
import MGDomain

/// Tonight sheet (UX §8.1): bedtime, latest wake, smart wake, caffeine at bedtime, night sounds, wind-down.
public struct TonightState: Equatable, Sendable {
    public var sample: Bool
    /// B, always set (`PhaseAnchors.bedtime`); `bedtimeNote` says where it came from when it isn't the model's.
    public var bedtime: Date
    public var bedtimeNote: String?
    /// Predicted sleep onset ("asleep ≈ 22:44").
    public var asleepAround: Date?
    /// "Bed 22:30 → asleep ≈ 22:44 → up 06:40–07:10".
    public var summaryLine: String
    /// your baseline need (mean of free nights) − nap credit = tonight's need; the sleep debt row is listed beside it, not added.
    public var need: [NeedPart]
    public var needTotal: DisplayValue
    /// "Must be up by" per weekday (1 = Sunday … 7 = Saturday); a blank weekday = no wake plan that morning.
    public var latestWake: [WeekdayWake]
    public var smartWake: SmartWakeBlockState
    public var caffeineAtBedtime: DisplayValue
    /// "31 mg at 22:30 — under your 33".
    public var caffeineSentence: String?
    public var nightSounds: ToggleState
    public var windDown: ToggleState
    /// One line for the need parts ALG-115 does not report separately ("Your need is the mean of your free nights, less today's naps…").
    public var needNote: String?

    public init(sample: Bool, bedtime: Date, bedtimeNote: String?, asleepAround: Date?, summaryLine: String,
                need: [NeedPart], needTotal: DisplayValue, latestWake: [WeekdayWake], smartWake: SmartWakeBlockState,
                caffeineAtBedtime: DisplayValue, caffeineSentence: String?, nightSounds: ToggleState,
                windDown: ToggleState) {
        self.sample = sample
        self.bedtime = bedtime
        self.bedtimeNote = bedtimeNote
        self.asleepAround = asleepAround
        self.summaryLine = summaryLine
        self.need = need
        self.needTotal = needTotal
        self.latestWake = latestWake
        self.smartWake = smartWake
        self.caffeineAtBedtime = caffeineAtBedtime
        self.caffeineSentence = caffeineSentence
        self.nightSounds = nightSounds
        self.windDown = windDown
    }
}

public struct NeedPart: Equatable, Sendable, Identifiable {
    /// "your baseline need", "sleep debt", "nap credit".
    public var label: String
    /// Signed minutes (nap credit is negative).
    public var minutes: Int?
    public var value: DisplayValue

    public init(label: String, minutes: Int?, value: DisplayValue) {
        self.label = label
        self.minutes = minutes
        self.value = value
    }

    public var id: String { label }
}

public struct WeekdayWake: Equatable, Sendable, Identifiable {
    /// 1 = Sunday … 7 = Saturday.
    public var weekday: Int
    /// nil = blank (no wake plan that morning; BRIEF default 3).
    public var time: TimeOfDay?

    public init(weekday: Int, time: TimeOfDay?) {
        self.weekday = weekday
        self.time = time
    }

    public var id: Int { weekday }
}

/// Smart wake (UX §8.1, ARCHITECTURE §4.11). How it rings differs by iOS version.
public struct SmartWakeBlockState: Equatable, Sendable {
    public enum Ringer: String, Sendable { case alarmKit, notification }

    public var toggle: ToggleState
    /// 10…45 min, default 30.
    public var windowMinutes: Int
    public var windowStart: Date?
    public var windowEnd: Date?
    /// "Wakes you in light sleep inside the window (strap stager, live); otherwise at 07:10".
    public var sentence: String
    public var ringer: Ringer
    /// iOS < 26: "A notification may not wake you on Silent." nil on AlarmKit.
    public var silentWarning: String?
    /// No "must be up by" for tomorrow → no plan, and why.
    public var noPlanReason: String?

    public init(toggle: ToggleState, windowMinutes: Int, windowStart: Date?, windowEnd: Date?, sentence: String,
                ringer: Ringer, silentWarning: String?, noPlanReason: String?) {
        self.toggle = toggle
        self.windowMinutes = windowMinutes
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.sentence = sentence
        self.ringer = ringer
        self.silentWarning = silentWarning
        self.noPlanReason = noPlanReason
    }
}

/// Night (push, UX §8.2): hero, hypnogram + methods, lanes, details grid, regularity, naps.
public struct NightState: Equatable, Sendable {
    public var sample: Bool
    /// The wake day the night belongs to (D13).
    public var day: LocalDay
    /// "7 h 08".
    public var slept: DisplayValue
    /// "of 8 h 10 needed".
    public var needed: DisplayValue
    /// "1 h 02 short".
    public var shortBy: String?
    public var stages: [StageSegment]
    public var stageMethods: MethodsStripState?
    public var lanes: [NightLane]
    /// Night window, total sleep, onset latency, WASO, REM latency, awakenings, efficiency (APP-261, ALG-150).
    public var details: [LabeledValue]
    public var regularity: DisplayValue
    public var naps: [LabeledValue]
    /// "No night recorded — strap was off 22:10–06:50." Everything else blank.
    public var blankReason: String?
    /// T100: the tap-to-open sleep panel (hours, quality, night HRV, stages) with the algorithm dropdown.
    public var algorithmPanel: AlgorithmPanelState?
    /// T10011 (r8g): how far the night has got; decides what `slept` is (blank "Not processed yet", the strap flag's time
    /// asleep, the phone's or the PC's staging). Defaulted so existing callers and previews keep compiling.
    public var fill: NightFill = .phone
    /// The visible source word under the hero: "strap data · from the strap sleep flag", "ours on the phone · phone
    /// staging", "ours on the PC · wav2sleep staging". Empty while not processed.
    public var sourceLine: String = ""
    /// D-SLEEP-PRIORITY-1: the other sources' totals for the same night, "also: Watch 7 h 44 · WHOOP 7 h 18"; empty when none.
    public var alsoLine: String = ""
    /// Why the stage chart is empty ("Not processed yet — …" while downloading); nil when stages are drawn.
    public var stagesNote: String?
    /// Strap flag, phone and PC on the same clock, for the stacked compare under the hypnogram (Night 4). Rows without a
    /// night say why.
    public var stageCompare: [StageCompareRow] = []
    /// The shared time window of the charts, worked out here so the view does not rebuild it from every lane mark.
    public var clockWindow: NightClockWindow?
    /// Sleep expanded (Mo, Nov 5 2026): the full breakdown, spec §B 1-10. The page leads with it; the method picker, the
    /// stager compare and the lanes stay below it.
    public var breakdown: SleepBreakdownState?

    public init(sample: Bool, day: LocalDay, slept: DisplayValue, needed: DisplayValue, shortBy: String?,
                stages: [StageSegment], stageMethods: MethodsStripState?, lanes: [NightLane], details: [LabeledValue],
                regularity: DisplayValue, naps: [LabeledValue], blankReason: String?) {
        self.sample = sample
        self.day = day
        self.slept = slept
        self.needed = needed
        self.shortBy = shortBy
        self.stages = stages
        self.stageMethods = stageMethods
        self.lanes = lanes
        self.details = details
        self.regularity = regularity
        self.naps = naps
        self.blankReason = blankReason
    }
}

public struct StageSegment: Equatable, Sendable {
    /// `unstaged` = asleep but no stage known (strap member, or epochs without R-R; WP-10 hypnogram code "S").
    /// Never draw it as light (added with main's OK, 2026-10-11).
    public enum Stage: String, Sendable, CaseIterable { case deep, light, rem, awake, unstaged }

    public var stage: Stage
    public var start: Date
    public var end: Date
    /// 0…1, how sure the read stage method is; nil = not reported. Added for WP-12 with main's OK, 2026-10-11.
    public var confidence: Double?

    public init(stage: Stage, start: Date, end: Date, confidence: Double? = nil) {
        self.stage = stage
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// A lane on the night's clock: breathing events, sounds, SpO₂ byte dots, movement.
public struct NightLane: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var marks: [LaneMark]
    /// "Not listening last night — switch on in Tonight".
    public var blankReason: String?

    public init(id: String, title: String, marks: [LaneMark], blankReason: String?) {
        self.id = id
        self.title = title
        self.marks = marks
        self.blankReason = blankReason
    }
}

public struct LaneMark: Equatable, Sendable {
    public var at: Date
    public var end: Date?
    /// Raw value where the lane has one (SpO₂ byte: no % sign).
    public var value: Double?
    public var label: String?

    public init(at: Date, end: Date? = nil, value: Double? = nil, label: String? = nil) {
        self.at = at
        self.end = end
        self.value = value
        self.label = label
    }
}

/// One row of the phone-versus-PC stage compare: where the stages came from and the runs themselves.
public struct StageCompareRow: Equatable, Sendable, Identifiable {
    /// "strap", "phone" or "pc".
    public var id: String
    /// "Strap flag", "Phone", "PC (wav2sleep)".
    public var label: String
    public var segments: [StageSegment]
    /// Asleep minutes of the row ("7 h 21"); nil when it has no night.
    public var total: String?
    /// Why the row is empty ("PC result not back yet.").
    public var blankReason: String?

    public init(id: String, label: String, segments: [StageSegment], total: String?, blankReason: String?) {
        self.id = id
        self.label = label
        self.segments = segments
        self.total = total
        self.blankReason = blankReason
    }
}

/// The time window every chart on the Night screen shares (whole quarter hours around the stages, the compare rows and
/// every lane mark). Built by the presenter once per refresh.
public struct NightClockWindow: Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// nil when there is nothing at all.
    public init?(times: [Date]) {
        guard let lo = times.min(), let hi = times.max() else { return nil }
        let quarter: TimeInterval = 15 * 60
        let s = Date(timeIntervalSinceReferenceDate: (lo.timeIntervalSinceReferenceDate / quarter).rounded(.down) * quarter)
        var e = Date(timeIntervalSinceReferenceDate: (hi.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter)
        if e <= s { e = s.addingTimeInterval(quarter) }
        self.init(start: s, end: e)
    }
}
