import Foundation
import MGDomain

/// The four tabs (UX §3.1, BRIEF default 1).
public enum AppTab: String, Sendable, CaseIterable {
    case today, live, log, explore

    public var title: String {
        switch self {
        case .today: return "Today"
        case .live: return "Live"
        case .log: return "Log"
        case .explore: return "Explore"
        }
    }
}

/// The Log tab's rows, in their stable order (UX §7: the list never reorders).
public enum LogItemID: String, Sendable, CaseIterable {
    case vape, medication, caffeine, supplements, food, symptom, sleepy, alcohol, water, sore, note, more
}

/// One-tap logs from the quick-log bar and Log row buttons (UX §3.2 row 8, §7).
public enum QuickLogAction: Equatable, Sendable {
    case vapeHit
    /// A scheduled medication by name ("MedA 20 mg").
    case medication(name: String)
    /// Start sipping a drink preset ("DrinkA", "Coffee").
    case drinkStart(preset: String)
    case drinkFinish
    case supplementsStack
    case food
    case symptom
    case sleepy
    case alcohol
    case note
    /// "More" → Log tab.
    case more
}

/// A picked start and end day (T9822, C14): inclusive, Pacific calendar days (a night belongs to its wake day).
public struct CustomRange: Hashable, Sendable {
    public let start: LocalDay
    public let end: LocalDay
    /// Longest span the picker accepts (3 years).
    public static let maxDays = 1096

    public init(start: LocalDay, end: LocalDay) {
        self.start = start
        self.end = end
    }

    /// Days covered, both ends counted.
    public var days: Int { start.days(to: end) + 1 }

    /// nil when the pick is allowed, else the sentence the sheet shows: end not before start, not after `today`, at
    /// most `maxDays` long.
    public static func problem(start: LocalDay, end: LocalDay, today: LocalDay) -> String? {
        if end < start { return "The end date is before the start date." }
        if end > today { return "The end date is after today." }
        let n = start.days(to: end) + 1
        if n > maxDays { return "That is \(n) days; the longest range is \(maxDays) days (3 years)." }
        return nil
    }

    /// The range, or the reason it is refused.
    public static func make(start: LocalDay, end: LocalDay, today: LocalDay) -> Result<CustomRange, ValidationError> {
        if let p = problem(start: start, end: end, today: today) { return .failure(ValidationError(message: p)) }
        return .success(CustomRange(start: start, end: end))
    }

    public struct ValidationError: Error, Equatable, Sendable { public let message: String }

    /// True when `day` is inside the range, both ends included.
    public func contains(_ day: LocalDay) -> Bool { day >= start && day <= end }

    /// "Oct 12 – Nov 4, 2026" (the year once when both ends share it).
    public var label: String {
        func md(_ d: LocalDay) -> String {
            let m = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.month - 1]
            return "\(m) \(d.day)"
        }
        if start.year == end.year { return "\(md(start)) – \(md(end)), \(end.year)" }
        return "\(md(start)), \(start.year) – \(md(end)), \(end.year)"
    }
}

/// Explore's period picker (UX §9). `custom(range)` is the picked range (T9822); nil = Custom chosen, no range picked
/// yet, which shows the last 30 days and says so.
public enum ExplorePeriod: Hashable, Sendable {
    /// `years2`, `years5`, `all` added 2026-10-11 (tracker #7): reaching before the phone's window, the app asks the
    /// PC for the older days (PCHistoryPlan).
    case today, days7, days30, days90, year1, years2, years5, all
    case custom(CustomRange?)

    /// The chips of the picker, in order; Custom is the last one (`customChip`).
    public static let presets: [ExplorePeriod] = [.today, .days7, .days30, .days90, .year1, .years2, .years5, .all]
    public static var pickerChips: [ExplorePeriod] { presets + [.custom(nil)] }

    public var isCustom: Bool { if case .custom = self { return true }; return false }
    public var customRange: CustomRange? { if case .custom(let r) = self { return r }; return nil }

    /// Stored name (settings); the custom range is stored beside it.
    public var key: String {
        switch self {
        case .today: return "today"
        case .days7: return "days7"
        case .days30: return "days30"
        case .days90: return "days90"
        case .year1: return "year1"
        case .years2: return "years2"
        case .years5: return "years5"
        case .all: return "all"
        case .custom: return "custom"
        }
    }

    /// The period for a stored name; `custom` takes the stored range.
    public init?(key: String, custom: CustomRange? = nil) {
        if key == "custom" { self = .custom(custom); return }
        guard let p = Self.presets.first(where: { $0.key == key }) else { return nil }
        self = p
    }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .days7: return "7 d"
        case .days30: return "30 d"
        case .days90: return "90 d"
        case .year1: return "1 y"
        case .years2: return "2 y"
        case .years5: return "5 y"
        case .all: return "All"
        case .custom(let r): return r?.label ?? "Custom"
        }
    }
}

/// Metric detail's view toggle (UX §9).
public enum MetricViewMode: String, Sendable, CaseIterable {
    case number, graph, trend

    public var title: String { rawValue.capitalized }
}

/// Long-press on a methods row (UX §10): Keep · Drop (hides, never deletes) · Restore a dropped one.
public enum MethodMark: String, Sendable, CaseIterable { case keep, drop, restore }

/// Every tap and long-press of UX §10, as one enum. Views send these; presenters and the app handle them.
public enum UIIntent: Equatable, Sendable {
    // Navigation
    case selectTab(AppTab)
    /// Re-tap of the current tab.
    case scrollToTop(AppTab)
    /// T10022: Settings is the system and its connections (the gear); Preferences is you and how the app looks (the "M").
    case openSettings
    case openPreferences
    case openStrapSync
    /// Mo, Nov 6 2026: the "Process now" button on the sleep card: connect, download, compute and send, now (bypasses the
    /// wake-chain check and its attempts cap). Opens the step-by-step sheet.
    case processSleepNow
    /// Today's "N models not running ›" line and Settings › Model status (2026-10-11): every model and its state.
    case openModelStatus
    /// "Your ages" (W10, 2026-10-11): every age model on one screen, from an age metric's detail.
    case openAges
    case openTonight
    /// nil = last night.
    case openNight(LocalDay?)
    /// nil = the latest workout.
    case openWorkout(id: UUID?)
    case openMetric(key: String, variant: String?)
    case openGroup(groupId: String)
    case openCompare(key: String)
    case openMatrix
    case openMonthGrid
    case openLogItem(LogItemID)
    case openLive

    // In-place expansion (one open per list)
    case toggleRow(id: String)
    case toggleMethods(groupId: String)

    // Logging
    case quickLog(QuickLogAction)
    /// "Vape hit 10:31?" Yes / No (UX §7 ConfirmList).
    case confirmDetected(id: String, accepted: Bool)
    case addEntry(LogItemID)
    case editEntry(id: UUID)
    /// Soft remove: kept in history, hidden; Undo for 5 s (UX §7).
    case removeEntry(id: UUID)
    case undoRemove(id: UUID)
    /// "happened at" chips −5 / −15 / −30 / −60 min (APP-082).
    case shiftHappenedAt(id: UUID, minutes: Int)
    case undoLastLog
    /// A new or revised event from a Log entry form. New: fresh `id`, `revision` 1. Edit: same `id`; the store bumps
    /// `revision`. `at` = happened, `loggedAt` = when Mo tapped save (APP-082). Never sent while SAMPLE mode is on.
    /// (Added for WP-18 with main's OK, 2026-10-11.)
    case saveEvent(EventRecord)
    /// Log › Sleepy & check-in › [Reaction test, 3 min] (APP-062).
    case startReactionTest

    // Peeks (UX §5)
    case answerPeek(PeekKindKey, answer: String)
    /// Swipe down = later → header chip.
    case deferPeek(PeekKindKey)
    /// Tap on the header "1 question" chip.
    case openDeferredQuestion
    /// "Edit times" inside the nap / workout question.
    case editPeekTimes(PeekKindKey)

    // Methods (UX §11)
    case selectMethod(groupId: String, variant: String)
    case markMethod(groupId: String, variant: String, mark: MethodMark)
    case showDropped(groupId: String)
    /// Long-press on any number: receipt popover.
    case showReceipt(Receipt)
    case pinMetric(key: String, pinned: Bool)

    // Moment card actions (UX §4.2)
    case remindStrapOff(minutes: Int)
    case openTailscale
    case dismissMoment(MomentKind)
    case endNap
    case startNap(minutes: Int)

    // Live (UX §6)
    case startBreathe
    case startHRVCheck(minutes: Int)
    case startECG
    case startWorkout
    case endWorkout
    case nextWorkoutWindow
    case setBroadcast(Bool)
    case openResearch(String)
    /// Live › research screens: read again, start / stop a labelled capture (ResearchPresenter; W10, #91).
    case research(ResearchAction)
    /// Breathe / HRV check flows (APP-024, APP-025). Added for WP-29.
    case guided(GuidedAction)
    /// Workout detail edits (APP-051 windows, APP-058 type + place, notes). Added for WP-29.
    case editWorkout(id: UUID, edit: WorkoutEdit)

    // Tonight and sleep (UX §8)
    case setSmartWake(Bool)
    case setWakeWindow(minutes: Int)
    case setNightSounds(Bool)
    case setWindDown(Bool)
    /// weekday 1 = Sunday … 7 = Saturday (Calendar convention); nil time clears it.
    case setLatestWake(weekday: Int, time: TimeOfDay?)

    // Explore (UX §9)
    case setPeriod(ExplorePeriod)
    case setMetricView(MetricViewMode)
    case search(String)
    case setMatrixMetrics([String])
    case openMatrixCell(row: Int, column: Int)
    /// Compare with… → pick the second metric (added for WP-19, main's OK 2026-10-11).
    case setCompareWith(key: String)
    /// 0…`CompareState.maxLagDays`.
    case setCompareLag(days: Int)

    // Strap, PC, settings (UX §14)
    /// Pull down on Today: reconnect strap + try sync.
    case refresh
    case pairPC
    case pairStrap
    /// Strap & sync > phone-to-PC panel > "Sync now": a manual sync at once (no ladder, no cadence gate).
    case syncNow
    /// Strap & sync > phone-to-PC panel > "Reset": clears the re-pair latch and the retry ladder, then tries once. It never
    /// deletes queued data.
    case resetSync
    case changeWearLocation(WearLocation)
    /// Strap & sync › R22 research stream › "Turn on R22": the one enable_r22_packets = '1' write (confirm sheet).
    case openUnlock
    /// Strap & sync › R22 research stream › "Restore the saved value" (confirm sheet; added 2026-10-11).
    case restoreR22
    /// Strap & sync › "Read strap settings": the read-only 117/118/128 snapshot (added 2026-10-11).
    case readStrapSettings
    /// Strap & sync › "Raw optical (uses strap battery)" switch, off by default (added 2026-10-11).
    case setRawOptical(Bool)
    /// Strap & sync › "Hand the strap back to WHOOP" (wave W12b, #103): leave-no-trace on / off.
    case setHandBackToWhoop(Bool)
    /// Strap & sync › "Input device" (0.6.0.3 Ring live): Auto / WHOOP strap / Ring feeds the live heart rate.
    case setInputDevice(InputDevice)
    /// Strap & sync › Raw optical › "At night too, in the background" (wave 4, #65; "Nights only, in the background"
    /// until the W10 merge): under the same switch.
    case setRawOpticalNightsOnly(Bool)
    /// Raw optical windows (T124): during a workout, "on for X every X" (nil = off), while the wrist is still.
    case setRawOpticalWindows(inWorkout: Bool, every: SpO2Every?, whenStill: Bool)
    /// SpO₂ screen › "Measure now (experimental, 60 s)" (wave 4, #77): 60 s of live raw optical (108, behind the raw
    /// optical switch), then the ratio-of-ratios estimate (MGSignal ALG022Spot).
    case measureSpO2Now
    /// Settings › Tests › SpO₂ test › Cancel (R9f, T10022 leftover): stops a running spot reading, puts raw optical back to its
    /// switch and saves a "cancelled" test row. No effect when none is running.
    case cancelSpO2Now
    /// The MG ECG reading and raw motion R21: their two switches, the wrist, raw-motion sessions and the ECG cover's
    /// steps (EcgMotionIntents.swift; wave W8, 2026-10-11).
    case ecgMotion(EcgMotionAction)
    /// r9q: the automatic raw streams (workouts, bursts) and the answer to "Workout?" (AutoRawUI.swift).
    case autoRaw(AutoRawAction)
    /// 0.6.0.12: "Read WHOOP 5.0 heart-rate broadcast": the switch, picking the sensor once, forgetting it (HRReadPresenter.swift).
    case hrRead(HRReadAction)
    case setTheme(ThemeSetting)
    case setSampleData(Bool)
    case setResearchRows(Bool)
    /// Settings > Notifications > daily 5:00 PM stress summary.
    case setStressSummary(Bool)
    /// T142: hide / show the "Working on:" strip at the top of every tab.
    case setHideWorkingBars(Bool)
    /// Settings › Quick-log surfaces (widget, Action Button, strap double-tap).
    case setQuickLogSurface(id: String, enabled: Bool)
    /// Settings edits that carry a value (added for WP-18 with main's OK, 2026-10-11).
    case editSetting(SettingEdit)
    /// Everything.
    case export
    /// Settings › Export for a date range (APP-114).
    case exportRange(from: LocalDay, to: LocalDay)
    /// Settings › Apple Health: the Shortcuts bridge (AppleHealthIntents.swift; added 2026-10-11 for Mo's decision).
    case appleHealth(AppleHealthAction)
    /// The alarm page: Fajr + normal wake on the strap, custom alarms, timers, calendar buzz (AlarmsIntents.swift;
    /// added 2026-10-11 for Mo's strap alarms).
    case alarms(AlarmsAction)
    /// Settings › Usage: phone and PC storage, background runs, compute (UsageIntents.swift; tracker #40, 2026-10-11).
    case usage(UsageAction)
    /// Settings › Places: saved places tag workouts and set the question's prior (PlacesIntents.swift; tracker #41).
    case places(PlacesAction)
    /// Settings › Front page: Today's cards and the dial's layers (FrontPageIntents.swift; tracker #34, 2026-10-11).
    case frontPage(FrontPageAction)
    /// Settings > Command test: send one strap command by number and mark the result (CommandTestIntents.swift; T87, 2026-10-13).
    case commandTest(CommandTestAction)
    /// Settings > Ring lab: try the ring's features by hand (RingLabIntents.swift; 0.6.0.5).
    case ringLab(RingLabAction)
    /// Settings > Screen Time: Family Controls access, schedules, the threshold log (ScreenTimeIntents.swift; Mac build, Nov 2026).
    case screenTime(ScreenTimeAction)
}
