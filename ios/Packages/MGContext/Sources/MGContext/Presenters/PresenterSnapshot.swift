import Foundation
import MGDomain

// WP-23b. Everything a presenter reads, pre-fetched by the app composition (WP-23a, AppModel) from DayDataSource,
// MGStore, the strap link, the sync engine and MGSignal. Presenters are pure and synchronous: the same snapshot always
// gives the same state. They do no I/O, read no clock and compute no statistic — medians, bands, EWMA, CUSUM, ρ,
// coherence, TRIMP, caffeine curves arrive computed (MGContext does not depend on MGSignal; WP-08 rule "reuse the
// shared kernels, never re-implement"). Presenters only choose, word and format.

/// The one input of every presenter (`XPresenter.make(_:)`).
public struct PresenterSnapshot: Sendable {
    // MARK: Time and mode

    public var now: Date
    /// Its time zone places every time of day on screen.
    public var calendar: Calendar
    /// `DayDataSource.isSample`: every state is marked `sample: true` and every value carries `sample: true`.
    public var sample: Bool

    // MARK: Context

    /// `ContextEngine.evaluate(inputs)` at `now`.
    public var context: DayContext
    /// What the context was evaluated from (strap, sync, workout, nap, history, alerts, pending questions).
    public var inputs: ContextInputs

    // MARK: Day data (D13: last night's metrics belong to the wake day)

    /// The wake day: `LocalDay(date: context.anchors.wake, calendar: calendar)`.
    public var day: LocalDay
    /// `summary(for: day)?.metrics ?? []` — night, morning (G-READY) and day-so-far metrics, every group member,
    /// blanks included (a blank metric carries its reason in `note`).
    public var metrics: [Metric]
    /// That day's series: "hypnogram" per G-STAGE variant (`state` = one of W L D R S . per 30-s epoch, WP-10; the strap
    /// member is `hypnogram` / variant "strap" with S / W letters — its raw codes are `strap_sleep_state`, not drawn),
    /// "resp_rate_hourly", "spo2_strap" (raw byte), "movement" (ALG-030 minute activity).
    public var series: [Series]
    /// Events with `at` in [start of the day before `day`, `now`], removed ones excluded (yesterday feeds the
    /// morning check-in's "Yesterday from your log"; today feeds the dial, Now rows and the Log).
    public var events: [EventRecord]
    /// Events of the calendar month containing `now` (Log › month grid).
    public var monthEvents: [EventRecord]
    /// ALG-160 readiness for this morning, mapped field by field; nil = not computed (no night yet).
    public var recovery: RecoveryReading?
    /// Strain (G-LOAD read method) over Mo's last 28 days, for the late-afternoon verdict (UX §12); nil = too few days.
    public var strainQuartiles: Quartiles?
    /// Caffeine in the body, ALG-060 `curve` every 10 min from the first dose to bedtime; empty = no doses.
    public var caffeineCurve: [TimedValue]
    /// The bedtime caffeine limit of the read G-CAFF method (ALG-061 learned limit; 33 mg until learned, WP-16).
    public var caffeineLimitMg: Double?
    /// Mo's choices per comparison group id ("G-READY"); a missing group = defaults (highest rank read, none dropped).
    public var groupChoices: [String: GroupChoice]

    // MARK: Settings, strap, sync

    public var settings: PresenterSettings
    public var strapSync: StrapSyncInfo

    // MARK: Screens that need more than the day

    /// nil = the Live tab has nothing streaming (strap off, not connected).
    public var live: LiveInput?
    public var explore: ExploreInput
    public var breathe: BreatheInput?
    public var hrvCheck: HRVCheckInput?
    /// The workout `.openWorkout(id:)` asked for (nil id = latest); nil = none.
    public var workoutDetail: WorkoutDetailInput?
    /// T116: the recent finished workouts for Explore › Workouts, loaded only while Explore is on screen.
    public var workoutHistory: [WorkoutDetailInput] = []

    // MARK: State-driven expansion (WP-07 rule: never local view state)

    public var ui: PresenterUI

    // MARK: Additions (after the first draft sent to main; additive, defaulted)

    /// ALG-051 / ALG-052 dip forecast for today; nil = the model did not run (the `alertness` metric's note says why).
    public var dip: DipForecast?
    /// Tonight's smart-wake block, built by WP-23a with WP-11's SmartWakeBlockFactory (main, 2026-10-11);
    /// nil → `TonightPresenter` builds its own default from settings and the anchors.
    public var smartWake: SmartWakeBlockState?
    /// Last night's smart-wake result for the Just-woke "Smart wake result" Now row (main, 2026-10-11); nil = none.
    public var smartWakeResult: SmartWakeSummaryInput?
    /// The next alarm within 24 h for Today's chip (`AlarmsPresenter.chip`; added 2026-10-11); nil = none.
    public var alarmChip: String?
    /// Model status (2026-10-11): "metric|variant" → the newest value of the last 60 days, imported variants included
    /// (the app refreshes it at most every 15 min, and whenever the page opens). Empty = not read yet.
    public var modelOutputs: [String: ModelOutput] = [:]
    /// Round 2 (2026-10-14): the imported rows (WHOOP export, Apple Health) of the wake day that `metrics` leaves out on
    /// purpose. Only Today's recovery headline reads them (W10: no recovery of our own yet, WHOOP's for last night shown
    /// and labelled). Before, the app dropped them all, so that fallback could never fire and Recovery stayed blank.
    public var importedToday: [Metric] = []
    /// Round 4 (2026-10-14, tier S): when the live detector says Mo fell asleep (`SleepOnsetDetector`); nil = not
    /// detected. A display state only: Today says "Asleep since …" instead of "Past your bedtime"; never sleep data.
    public var asleepSince: Date?
    /// Round 5: the strap flag says Mo woke (after a sleep run) at this time, and it is under an hour ago. Same rule as
    /// `asleepSince`: Today never talks about bedtime or winding down while either is set.
    public var awakeSince: Date?
    /// Round 5 (tier L): the PC is reachable now, from the real sync state (online). Offline, error, pairing or no PC
    /// set up = not reachable, so the phone's tier M result is labelled as such.
    public var pcReachable: Bool { inputs.sync.state == .online }
    /// Asleep (tier S) or just woke: Today shows no bedtime / wind-down text.
    public var sleepStateHidesBedtime: Bool {
        if let a = asleepSince, a <= now { return true }
        if let w = awakeSince, w <= now, now.timeIntervalSince(w) <= SleepOnsetDetector.afterWakeQuiet { return true }
        return false
    }
    /// The Live tab's HR line (#35): stored + live HR of the last minutes, oldest first. Set every second with `live`;
    /// kept apart from it because it also shows while the strap is connected and the first beat has not come yet.
    public var liveHRTrace: [LiveHRPoint] = []
    /// Wave W11: when the window before now is empty the charts show the newest stored stretch (LiveBackfill): the HR
    /// line ends here (nil = now), and the labels say so.
    public var liveBackfill: LiveBackfill.Plan?
    /// 0.6.0.12: the app's own nightly lnRMSSD, oldest first, the last = last night (nil = no value that night); about 36 nights.
    /// Feeds the 7-night mean and normal band on the RMSSD / autonomic-load explainer cards.
    public var hrvLnNights: [Double?] = []
    /// 0.6.0.12: "WHOOP 4.0" is the selected strap device (Settings › Strap & sync › Device). The Live tab then offers the Raw 4.0 view.
    public var whoop4Selected = false
    /// Mo's saved places and the visit log (#41, phone only): the workout question names the place and uses its prior.
    public var places = PlacesSnapshot()
    /// Tracker #42: every health record and scan event (injuries, body composition) for Settings › Profile; read only
    /// while Settings is open (empty otherwise).
    public var profileRecords: [EventRecord] = []

    /// The place a workout candidate [start, end] happened at (most of it), if any.
    public func placeTag(_ start: Date, _ end: Date) -> PlaceTag? {
        PlacePresence.tag(start: start, end: end, now: now, places)
    }
    /// Wave 2 (2026-10-11): the newest stored PC result of every model (lab_result, imported-history models left out:
    /// they are rows in `metrics` / Explore already), newest first; and results the phone could not read.
    public var pcResults: [LabResult] = []
    /// T9809: metric name -> primary source ("phone:<variant>" | "pc.<model>@<ver>[#<variant>]") as the PC last served it
    /// (versions/primary.json); empty = the PC named none, the app's own rule applies.
    public var primary: [String: String] = [:]
    /// Wave 4 (#77): an experimental SpO₂ spot measurement runs until this time (nil = none running).
    public var spo2SpotUntil: Date?
    public var pcResultsUnreadable: [String] = []
    /// Today's non-metric pipeline outputs and the on-demand pipelines (habits, social jetlag); nil = not computed yet.
    public var dayExtras: DayExtrasInput?
    /// GroupPipeline's view of the open group (Explore › group), one entry per metric name.
    public var groupMeasures: [GroupMeasureInput] = []
    /// What is running now (history download, compute, sync), for the "Working on…" line.
    public var working: WorkingInput = .idle
    /// Today's strap data since local midnight (tracker #75): time worn, heart rate, step ticks; nil = not read.
    public var todaySoFar: TodaySoFarInput?
    /// P03, the Sundial's detail sheets: the 7 days ending today (today last) of "strain", "stress", "sleep_total",
    /// "sleep_need" and "recovery_score", one value per day. Empty = not read (the sheet then draws no week).
    public var dialWeek: [String: [DayPoint]] = [:]
    /// P03: per-minute heart rate (one mean per minute, oldest first) from 30 min before today's first vape hit or
    /// medication dose to now, for their heart-rate effects. Empty = none of those today, or not read.
    public var minuteHR: [HRPoint] = []
    /// P03: the ALG-051 alertness score (0…100) through today's waking day; empty = no forecast.
    public var alertnessCurve: [TimedValue] = []
    /// R9m (D-HRV-WALK-2): where the two-week check of the alertness model against Mo's reaction tests stands; nil = not read.
    public var alertnessSelfCheck: AlertnessSelfCheck?
    /// Round 8 (T10023): the stored 5-minute series the Sundial's time scrub reads (`DialSeries.wantedNames`: "hr_5min", and
    /// the strain / stress ones once something writes them) from the two calendar days the dial's 24 h window can
    /// cover (today and the day before). Empty = not read; the card then says nothing is stored.
    public var dialSeries: [Series] = []
    /// Apple Health's last night read on the phone itself (HealthKit SleepAnalysis, read-only); nil = none read / none found.
    /// The PC's pc.history row wins over it when both exist (same data, deduped).
    public var phoneAppleSleep: PhoneAppleSleep?

    public init(now: Date, calendar: Calendar, sample: Bool, context: DayContext, inputs: ContextInputs,
                day: LocalDay, metrics: [Metric], series: [Series], events: [EventRecord], monthEvents: [EventRecord],
                recovery: RecoveryReading?, strainQuartiles: Quartiles?, caffeineCurve: [TimedValue],
                caffeineLimitMg: Double?, groupChoices: [String: GroupChoice], settings: PresenterSettings,
                strapSync: StrapSyncInfo, live: LiveInput?, explore: ExploreInput, breathe: BreatheInput?,
                hrvCheck: HRVCheckInput?, workoutDetail: WorkoutDetailInput?, ui: PresenterUI,
                dip: DipForecast? = nil, smartWake: SmartWakeBlockState? = nil,
                smartWakeResult: SmartWakeSummaryInput? = nil, alarmChip: String? = nil) {
        self.now = now
        self.calendar = calendar
        self.sample = sample
        self.context = context
        self.inputs = inputs
        self.day = day
        self.metrics = metrics
        self.series = series
        self.events = events
        self.monthEvents = monthEvents
        self.recovery = recovery
        self.strainQuartiles = strainQuartiles
        self.caffeineCurve = caffeineCurve
        self.caffeineLimitMg = caffeineLimitMg
        self.groupChoices = groupChoices
        self.settings = settings
        self.strapSync = strapSync
        self.live = live
        self.explore = explore
        self.breathe = breathe
        self.hrvCheck = hrvCheck
        self.workoutDetail = workoutDetail
        self.ui = ui
        self.dip = dip
        self.smartWake = smartWake
        self.smartWakeResult = smartWakeResult
        self.alarmChip = alarmChip
    }
}

/// Last night's smart-wake result as the Just-woke Now row shows it (main, 2026-10-11; WP-23a words it from WP-11's
/// controller): "Smart wake got you up at 06:52" · "light sleep · 18 min before 07:10" — or "Smart wake couldn't
/// watch" · "strap disconnected at 03:12 — only the backstop rang".
public struct SmartWakeSummaryInput: Equatable, Sendable {
    public var title: String
    public var detail: String?
    /// The receipt's method ("ALG-031 live stager", "backstop alarm").
    public var receiptMethod: String
    /// When it rang (or when watching stopped): the receipt's `at` and the dial's wake marker.
    public var at: Date

    public init(title: String, detail: String?, receiptMethod: String, at: Date) {
        self.title = title
        self.detail = detail
        self.receiptMethod = receiptMethod
        self.at = at
    }
}

/// Answer strings the peeks send in `.answerPeek(_:answer:)` (main, 2026-10-11). Step-1 answers stay as before
/// (feel words lowercased, nap labels, "yes" / "not_workout", wear-location raw values, "kss1"…"kss9").
public enum PeekAnswerID {
    /// Morning check-in step 2: "Yesterday from your log — right?"
    public static let looksRight = "looks_right"
    public static let addSomething = "add"
    /// Nap step 2 and nap + 30 min: groggy (1) ↔ refreshed (5).
    public static let napRatings = ["1", "2", "3", "4", "5"]
}

/// ALG-051 / ALG-052 output for today (UX §12 dip rule).
public struct DipForecast: Equatable, Sendable {
    /// The predicted dip; nil = none predicted ("Clear afternoon.").
    public var window: DialSpan?
    /// Reaction tests behind the curve; < 5 = population curve ("population, not yours yet").
    public var reactionTests: Int
    public var at: Date

    public init(window: DialSpan?, reactionTests: Int, at: Date) {
        self.window = window
        self.reactionTests = reactionTests
        self.at = at
    }
}

// MARK: - Small value types

/// A value at an instant (caffeine curve sample).
public struct TimedValue: Equatable, Sendable {
    public var at: Date
    public var value: Double

    public init(at: Date, value: Double) {
        self.at = at
        self.value = value
    }
}

/// p25 / p75 of a distribution and how many days it covers.
public struct Quartiles: Equatable, Sendable {
    public var p25: Double
    public var p75: Double
    public var n: Int

    public init(p25: Double, p75: Double, n: Int) {
        self.p25 = p25
        self.p75 = p75
        self.n = n
    }
}

/// ALG-160 readiness (Orchard "MS-19" rebuilt, D-RECOV-WALK-2), mirrored so MGContext needs no MGSignal (SnapshotMath copies
/// it field by field). Replaces the ALG-036 "n of 5 in your range" count (removed 2026-10-17).
public struct RecoveryReading: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// HRV status scored and at least 2 other components scored: `score` is set.
        case ok = "ok"
        /// 3 or more valid nights this week, but the baseline is under `baselineNightsNeeded` own nights.
        case learning = "learning"
        /// HRV missing (under 3 valid nights this week), or fewer than 2 other components scored.
        case tooLittle = "too_little"
    }

    public enum HRVState: String, Sendable {
        case below, balanced, above
    }

    /// Garmin's published bands: 1-24 Poor, 25-49 Low, 50-74 Moderate, 75-94 High, 95-100 Prime.
    public enum Band: String, Sendable {
        case poor, low, moderate, high, prime
    }

    /// `base` = overnight R-R; `enhanced` = 60 s morning readings (D-ALG-TIERS).
    public enum Tier: String, Sendable {
        case base, enhanced
    }

    /// One of the scored parts (top-level type `RecoveryComponent`).
    public typealias Component = RecoveryComponent

    /// Own nights needed before the readiness is no longer labelled an estimate, and before it is shown at all.
    public static let baselineNightsNeeded = 14
    public static let baselineNightsFull = 28

    public var status: Status
    /// 1-100 when `status == .ok`.
    public var score: Int?
    public var band: Band?
    public var tier: Tier
    public var hrvState: HRVState?
    /// Distance of the 7-day lnRMSSD mean from your normal, in half-SD steps; band edges at -1 and +1.
    public var hrvDistance: Double?
    public var components: [Component]
    /// Own nights in the HRV baseline (14 needed, 28 for a full-length baseline).
    public var hrvNights: Int
    /// Days of fatigue left to burn off from recent training load (7 ln(ATL/CTL)); nil without a load.
    public var recoveryDays: Double?
    /// Why there is no score (learning / too little); nil when ok.
    public var reason: String?
    /// When it was computed (the receipt's `at`).
    public var at: Date

    public init(status: Status, score: Int? = nil, band: Band? = nil, tier: Tier = .base, hrvState: HRVState? = nil,
                hrvDistance: Double? = nil, components: [Component] = [], hrvNights: Int = 0, recoveryDays: Double? = nil,
                reason: String? = nil, at: Date) {
        self.status = status
        self.score = score
        self.band = band
        self.tier = tier
        self.hrvState = hrvState
        self.hrvDistance = hrvDistance
        self.components = components
        self.hrvNights = hrvNights
        self.recoveryDays = recoveryDays
        self.reason = reason
        self.at = at
    }

    /// True while the baseline is shorter than a full 28 nights: Today and the ring then say "estimate".
    public var isEstimate: Bool { status == .ok && hrvNights < Self.baselineNightsFull }
}

/// One ALG-160 part: "hrv", "sleep", "recovery_time", "load_balance", "stress" (ALG160.order).
public struct RecoveryComponent: Equatable, Sendable {
    public var name: String
    /// 0-100, nil = not scored.
    public var points: Double?
    public var weight: Double
    /// Why it was not scored.
    public var reason: String?

    public init(name: String, points: Double?, weight: Double, reason: String?) {
        self.name = name
        self.points = points
        self.weight = weight
        self.reason = reason
    }
}

/// Mo's marks on one comparison group (UX §11): the method he reads, keep / drop. Drop hides, never deletes.
public struct GroupChoice: Equatable, Sendable {
    /// nil = default (highest rank).
    public var readVariant: String?
    public var readChosenAt: Date?
    public var kept: Set<String>
    public var dropped: Set<String>

    public init(readVariant: String? = nil, readChosenAt: Date? = nil, kept: Set<String> = [], dropped: Set<String> = []) {
        self.readVariant = readVariant
        self.readChosenAt = readChosenAt
        self.kept = kept
        self.dropped = dropped
    }
}

/// Settings and profile the screens show or depend on.
public struct PresenterSettings: Equatable, Sendable {
    public var profile: Profile
    /// "Must be up by" per weekday, 1 = Sunday … 7 = Saturday; a missing weekday = blank (BRIEF default 3).
    public var latestWake: [Int: TimeOfDay]
    /// 10…45, default 30.
    public var wakeWindowMinutes: Int
    public var needOverrideMinutes: Int?
    public var schedules: [MedSchedule]
    public var drinkPresets: [DrinkPreset]
    /// The drink on the quick-log pill ("DrinkA"); nil = the first preset.
    public var usualDrink: String?
    /// Settings › Quick-log surfaces by id ("doubleTap", "widget", "actionButton").
    public var quickLogSurfaces: [String: Bool]
    public var theme: ThemeSetting
    public var researchRowsShown: Bool
    /// T142: Settings › Top bar › hide the "Working on:" strip.
    public var hideWorkingBars: Bool
    public var smartWakeOn: Bool
    public var nightSoundsOn: Bool
    public var windDownOn: Bool
    public var stressSummaryOn: Bool
    public var phoneHaptics: Bool
    /// AlarmKit on iOS 26+, notification below (ARCHITECTURE §4.11).
    public var ringer: SmartWakeBlockState.Ringer
    /// Explore shelf, in Mo's order.
    public var pinnedMetrics: [String]
    /// Settings › Front page: Today's cards and the dial's layers (tracker #34).
    public var frontPage: FrontPageLayout
    /// T104: the daily calorie goal behind the Sundial's burn ring. nil = none set: the ring then shows the burn with
    /// no fill, never a default number.
    public var calorieGoalKcal: Double?
    /// Settings â€º Sun vitamin D: quiz result and hand-entered rough location for the PC estimate.
    public var fitzpatrickSkinType: Int?
    public var vitaminDLocation: VitaminDRoughLocation?
    /// T9746: Mo's editable Medications / Supplements / Drinks lists. Set after construction so the init stays as it is.
    public var presetLists = PresetLists()
    /// T9841: the notification kinds Mo chose to skip (`NotifyKind` raw values). Set after construction.
    public var skippedNotifications: Set<String> = []
    /// T9841: the smart-wake mode, its gate (minutes after midnight) and the minimum rest share (percent).
    public var smartWakeMode = SmartWakeModes.defaultID
    public var smartWakeGateMinutes: Int?
    public var smartWakeRestPercent = SmartWakeModes.defaultRestPercent

    public init(profile: Profile = Profile(), latestWake: [Int: TimeOfDay] = [:], wakeWindowMinutes: Int = 30,
                needOverrideMinutes: Int? = nil, schedules: [MedSchedule] = [], drinkPresets: [DrinkPreset] = [],
                usualDrink: String? = nil, quickLogSurfaces: [String: Bool] = [:], theme: ThemeSetting = .followDay,
                researchRowsShown: Bool = true, smartWakeOn: Bool = true, nightSoundsOn: Bool = false,
                windDownOn: Bool = true, stressSummaryOn: Bool = true, phoneHaptics: Bool = true,
                ringer: SmartWakeBlockState.Ringer = .notification,
                pinnedMetrics: [String] = [], frontPage: FrontPageLayout = .standard,
                hideWorkingBars: Bool = false, calorieGoalKcal: Double? = nil, fitzpatrickSkinType: Int? = nil,
                vitaminDLocation: VitaminDRoughLocation? = nil) {
        self.calorieGoalKcal = calorieGoalKcal
        self.fitzpatrickSkinType = fitzpatrickSkinType
        self.vitaminDLocation = vitaminDLocation
        self.profile = profile
        self.latestWake = latestWake
        self.wakeWindowMinutes = wakeWindowMinutes
        self.needOverrideMinutes = needOverrideMinutes
        self.schedules = schedules
        self.drinkPresets = drinkPresets
        self.usualDrink = usualDrink
        self.quickLogSurfaces = quickLogSurfaces
        self.theme = theme
        self.researchRowsShown = researchRowsShown
        self.smartWakeOn = smartWakeOn
        self.nightSoundsOn = nightSoundsOn
        self.windDownOn = windDownOn
        self.stressSummaryOn = stressSummaryOn
        self.phoneHaptics = phoneHaptics
        self.ringer = ringer
        self.pinnedMetrics = pinnedMetrics
        self.frontPage = frontPage
        self.hideWorkingBars = hideWorkingBars
    }
}

/// The phone-to-PC half of Strap & sync (P9734, 2026-10-14): MGSync `SyncPanel` copied by the app, so MGContext does not
/// import MGSync. Times are plain `Date`s; the presenter words them (12-hour, Pacific).
public struct PCSyncPanelInfo: Equatable, Sendable {
    public var state: SyncState
    public var lastSuccess: Date?
    public var lastAcceptedAt: Date?
    public var queueDrops: Int
    public var queueBytes: Int
    public var bytesDelivered: Int
    public var lastError: String?
    public var lastErrorAt: Date?
    public var nextRetryAt: Date?
    public var consecutiveFailures: Int
    public var authFailures: Int
    public var authFailuresToRepair: Int
    public var needsRepair: Bool
    /// "PC not receiving since 2:21 AM"; nil = nothing stuck.
    public var banner: String?
    /// T9988: "stopped, 2.4 MB left" after a sync that ran out of time; nil once a sync finishes.
    public var lastStop: String?
    public var lastStopAt: Date?

    public init(state: SyncState, lastSuccess: Date? = nil, lastAcceptedAt: Date? = nil, queueDrops: Int = 0,
                queueBytes: Int = 0, bytesDelivered: Int = 0, lastError: String? = nil, lastErrorAt: Date? = nil,
                nextRetryAt: Date? = nil, consecutiveFailures: Int = 0, authFailures: Int = 0,
                authFailuresToRepair: Int = 3, needsRepair: Bool = false, banner: String? = nil,
                lastStop: String? = nil, lastStopAt: Date? = nil) {
        self.lastStop = lastStop
        self.lastStopAt = lastStopAt
        self.state = state
        self.lastSuccess = lastSuccess
        self.lastAcceptedAt = lastAcceptedAt
        self.queueDrops = queueDrops
        self.queueBytes = queueBytes
        self.bytesDelivered = bytesDelivered
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
        self.nextRetryAt = nextRetryAt
        self.consecutiveFailures = consecutiveFailures
        self.authFailures = authFailures
        self.authFailuresToRepair = authFailuresToRepair
        self.needsRepair = needsRepair
        self.banner = banner
    }
}

/// What the Strap & sync sheet shows beyond `inputs.strap` / `inputs.sync` / `inputs.history`.
public struct StrapSyncInfo: Equatable, Sendable {
    public var bonded: Bool?
    public var firmware: String?
    /// Last HISTORY_END ack (sent only after the chunk was stored).
    public var lastAckAt: Date?
    /// Strap writes today, newest first (MGStore `strapWriteEntries`): e.g. "clock set".
    public var writesToday: [String]
    /// Outbox bytes not yet delivered.
    public var unsyncedBytes: Int?
    public var healthAvailable: Bool
    public var healthGranted: [String]
    public var healthLastRead: Date?
    /// The newest stored strap settings snapshot (117/118/128 reads; added 2026-10-11, strap-raw-optical phase A).
    public var flagSnapshot: StrapFlagSnapshot?
    /// Raw optical (108 live R20, added 2026-10-11): the switch, whether ON is in effect, frames, why it stopped.
    public var rawOpticalWanted: Bool = false
    public var rawOpticalOn: Bool = false
    public var rawOpticalFrames: Int = 0
    public var rawOpticalLastFrameAt: Date?
    public var rawOpticalStopped: String?
    /// Wave 4 (#65): the "nights only" schedule, the burst schedule it follows, its decision now and the measured
    /// battery cost (RawOpticalNight / RawOpticalCost); nil = not computed.
    public var rawOpticalNightsOnly: Bool = false
    /// T124: the other raw optical windows (workout / every X / still wrist), so one switch can send all three.
    public var rawOpticalInWorkout: Bool = true
    public var rawOpticalEvery: SpO2Every?
    public var rawOpticalWhenStill: Bool = false
    public var rawOpticalSchedule: SpO2BurstSchedule?
    public var rawOpticalDecision: RawOpticalNight.Decision?
    public var rawOpticalCost: RawOpticalCost.Estimate?
    /// The R22 watch after the one enable_r22_packets write (2026-10-11); nil = nothing being watched.
    public var r22Watch: R22Watch?
    /// The last phone-side cleanup of PC-confirmed data older than 30 days (2026-10-11); nil = none yet.
    public var lastCleanup: PhoneRetentionReport?
    /// The newest enable_r22_packets write that read a value back (2026-10-11): the R22 header shows it when it is
    /// newer than the settings snapshot (Mo saw "off ('2') · read 12:03" after a write that read back '1').
    public var r22LastWrite: StrapFlagWrite?
    /// ECG and raw motion R21 (wave W8, 2026-10-11): switches, phase, R21 seconds, the live magnitude trace.
    public var ecgMotion = EcgMotionInfo()
    /// Wave W12b: the last "read history without deleting" test in words (MGBLE HistoryProbeResult.lines); empty = never run.
    public var historyReadTest: [String] = []
    public var historyReadTestRunning = false
    /// Wave W12b (#103): "Hand the strap back to WHOOP" is on, and the last hand-back's summary.
    public var handBackOn = false
    /// 0.6.0.3: Mo's input-device choice, whether the strap link is up, the ring's state and its last steps line.
    public var inputDevice: InputDevice = .auto
    public var strapLinkUp = false
    public var ringConnected = false
    public var ringName: String?
    public var ringStepsLine: String?
    public var handBackLines: [String] = []
    /// T77: the HR broadcast switch (default off) and what the strap reported when last read ("on" / "off" / "unknown (…)").
    public var hrBroadcastOn = false
    public var hrBroadcastReading: String?
    /// r9q: the automatic raw streams (workout switching, bursts, 50 Hz log).
    public var autoRaw = AutoRawInfo()
    /// 0.6.0.12: the 5.0 heart-rate broadcast reader (default off).
    public var hrRead = HRReadInfo()
    /// P9734: the phone-to-PC sync panel; nil = not known yet (sample mode, or before the first read).
    public var pcSync: PCSyncPanelInfo?
    /// Apple Health batches still waiting to go to the PC (the same count the debug status gives); nil = not known.
    public var healthQueuedBatches: Int?

    public init(bonded: Bool? = nil, firmware: String? = nil, lastAckAt: Date? = nil, writesToday: [String] = [],
                unsyncedBytes: Int? = nil, healthAvailable: Bool = false, healthGranted: [String] = [],
                healthLastRead: Date? = nil, flagSnapshot: StrapFlagSnapshot? = nil, rawOpticalWanted: Bool = false,
                rawOpticalOn: Bool = false, rawOpticalFrames: Int = 0, rawOpticalLastFrameAt: Date? = nil,
                rawOpticalStopped: String? = nil, r22Watch: R22Watch? = nil,
                lastCleanup: PhoneRetentionReport? = nil, r22LastWrite: StrapFlagWrite? = nil) {
        self.bonded = bonded
        self.firmware = firmware
        self.lastAckAt = lastAckAt
        self.writesToday = writesToday
        self.unsyncedBytes = unsyncedBytes
        self.healthAvailable = healthAvailable
        self.healthGranted = healthGranted
        self.healthLastRead = healthLastRead
        self.flagSnapshot = flagSnapshot
        self.rawOpticalWanted = rawOpticalWanted
        self.rawOpticalOn = rawOpticalOn
        self.rawOpticalFrames = rawOpticalFrames
        self.rawOpticalLastFrameAt = rawOpticalLastFrameAt
        self.rawOpticalStopped = rawOpticalStopped
        self.r22Watch = r22Watch
        self.lastCleanup = lastCleanup
        self.r22LastWrite = r22LastWrite
    }
}

/// One strap flag write and the value the strap read back after it.
public struct StrapFlagWrite: Equatable, Sendable {
    public var readback: String
    public var at: Date

    public init(readback: String, at: Date) {
        self.readback = readback
        self.at = at
    }
}

/// Which rows and strips are open (`.toggleRow(id:)`, `.toggleMethods(groupId:)`, `.showDropped(groupId:)`).
public struct PresenterUI: Equatable, Sendable {
    /// Row ids toggled open: Now rows ("focus", "caffeine", …), Log rows (`LogItemID.rawValue`), Explore sections,
    /// workout windows, `WorkoutDetailState.timesRowId`. Strips: "strip.lastNight" / "strip.todaySoFar" flip the
    /// phase default (UX §3.2 row 7: the other strip sits collapsed).
    public var openRows: Set<String>
    public var expandedGroups: Set<String>
    public var showDroppedGroups: Set<String>
    /// Morning check-in step: 1 = how do you feel, 2 = "Yesterday from your log — right?" (main, 2026-10-11).
    public var checkinStep: Int
    /// Nap question step: 1 = nap / dozed / rest / no, 2 = groggy ↔ refreshed 1–5 (main, 2026-10-11).
    public var napPeekStep: Int
    /// Workout-confirm step: 1 = right?, 2 = type + place chips (APP-058), 3 = the CR-10 rating (r9p). Added by WP-23b, defaulted.
    public var workoutPeekStep: Int
    /// T10004: the app has just opened and has not yet heard the PC's real sync state; the status chip says
    /// "PC connecting…" instead of "not synced yet" until it has.
    public var settling: Bool

    public init(openRows: Set<String> = [], expandedGroups: Set<String> = [], showDroppedGroups: Set<String> = [],
                checkinStep: Int = 1, napPeekStep: Int = 1, workoutPeekStep: Int = 1, settling: Bool = false) {
        self.settling = settling
        self.openRows = openRows
        self.expandedGroups = expandedGroups
        self.showDroppedGroups = showDroppedGroups
        self.checkinStep = checkinStep
        self.napPeekStep = napPeekStep
        self.workoutPeekStep = workoutPeekStep
    }
}

// MARK: - Live

public struct LiveInput: Equatable, Sendable {
    /// Last live HR (strap) and when it arrived.
    public var heartRate: Double?
    public var heartRateAt: Date?
    /// Seconds between the last two beats (pulse dot).
    public var beatInterval: Double?
    /// ALG-010 over the last 5 min (blank metric with its reason when too few beats).
    public var rmssd5min: Metric?
    /// ALG-054 autonomic load vs baseline (z) — blank metric while learning.
    public var autonomicLoad: Metric?
    /// R26 PPG, last 8 s, oldest first.
    public var pulseWave: [Double]
    public var pulseHz: Double?
    /// ALG-005 quality word ("good", "fair", "poor"); nil = unknown.
    public var pulseQuality: String?
    /// R-R, last 60 s, with ALG-004 flags.
    public var rr: [TachogramPoint]
    public var rrMedianMs: Double?
    /// The 50 Hz mode flag as read from the strap; nil = not read.
    public var fiftyHzFlag: Bool?
    /// Live workout (Workout mode); nil when none runs.
    public var workout: LiveWorkoutInput?
    /// Wave 4: live raw optical (R20, 108 on), last ~5 s of both slots in every block with its stored head.
    public var opticalRecent: [R20Block] = []
    /// WHOOP4-WIRE 6: the WHOOP 4.0's live optical waveform (command 63, type 43 payload 1921), the last ~1,000 samples: signed
    /// 24-bit raw counts, one waveform, which LED each sample is unknown (decoded, untested). Empty = none / not a 4.0.
    public var opticalWhoop4: [Int32] = []
    /// Bug 3 (2026-10-14): where `pulseWave` came from when it is not R26 ("R20 raw optical block 2"); nil = R26 / none.
    /// R26 (the strap's ordinary pulse records) never arrives live: it comes with the history download.
    public var pulseSource: String?
    /// 0.6.0.12: where the live beats come from when it is not the MG link ("WHOOP 5.0 broadcast", "WHOOP 4.0"); nil = the MG link.
    public var hrSource: String?
    /// Bug 3: the pulse rate found in that wave (ALG-108 on raw optical, research tier, decoded, untested); nil = none.
    public var pulseRateBpm: Double?
    /// Bug 3: why no rate was found (OpticalPulse.live: "optical signal saturated…", "no pulse in the longest run of
    /// block 2 (5 s; at least 8 s needed)"); nil when a rate was found or nothing streams.
    public var pulseNote: String?
    /// P9729 (job 12): the ALG-144 cleaned wave, its pulse estimate and quality (or why not yet); nil = raw optical not
    /// flowing, so nothing to clean.
    public var cleanPulse: LiveCleanPulse?
    /// 0.6.0.12: the judged 5-minute windows behind the RMSSD tile (MGSignal LiveHRV): the window ending now and today's finished ones.
    public var hrv: LiveHRVReading?

    public init(heartRate: Double? = nil, heartRateAt: Date? = nil, beatInterval: Double? = nil,
                rmssd5min: Metric? = nil, autonomicLoad: Metric? = nil, pulseWave: [Double] = [],
                pulseHz: Double? = nil, pulseQuality: String? = nil, rr: [TachogramPoint] = [],
                rrMedianMs: Double? = nil, fiftyHzFlag: Bool? = nil, workout: LiveWorkoutInput? = nil) {
        self.heartRate = heartRate
        self.heartRateAt = heartRateAt
        self.beatInterval = beatInterval
        self.rmssd5min = rmssd5min
        self.autonomicLoad = autonomicLoad
        self.pulseWave = pulseWave
        self.pulseHz = pulseHz
        self.pulseQuality = pulseQuality
        self.rr = rr
        self.rrMedianMs = rrMedianMs
        self.fiftyHzFlag = fiftyHzFlag
        self.workout = workout
    }
}

public struct LiveWorkoutInput: Equatable, Sendable {
    public var session: WorkoutSession
    /// HR so far, one value per 5 s, oldest first.
    public var hrTrace: [Double]
    /// Minutes in zones 1…5 (ALG-106 `timeInZones`).
    public var zoneMinutes: [Double]
    /// Upper edges of zones 1–4 (ALG-106 `zoneEdges`); nil = no max known.
    public var zoneEdgesBpm: [Double]?
    /// "measured max 190" / "Tanaka estimate 186".
    public var zoneBasis: String?
    public var windows: [WorkoutFields.Window]
    /// One-minute breathing where two estimators agree (APP-031); blank metric otherwise.
    public var breathing: Metric?
    /// G-LOAD members for this workout so far (window "workout").
    public var strain: [Metric]
    /// Double-taps marked as "set done" (APP-007), last one.
    public var setsDone: Int
    public var lastSetAt: Date?

    public init(session: WorkoutSession, hrTrace: [Double] = [], zoneMinutes: [Double] = [],
                zoneEdgesBpm: [Double]? = nil, zoneBasis: String? = nil, windows: [WorkoutFields.Window] = [],
                breathing: Metric? = nil, strain: [Metric] = [], setsDone: Int = 0, lastSetAt: Date? = nil) {
        self.session = session
        self.hrTrace = hrTrace
        self.zoneMinutes = zoneMinutes
        self.zoneEdgesBpm = zoneEdgesBpm
        self.zoneBasis = zoneBasis
        self.windows = windows
        self.breathing = breathing
        self.strain = strain
        self.setsDone = setsDone
        self.lastSetAt = lastSetAt
    }
}

// MARK: - Explore

/// One metric over Explore's period, every statistic computed upstream (ALG-075 via MGSignal).
public struct MetricAnalysis: Equatable, Sendable {
    public var key: String
    public var variant: String?
    /// Daily values over the period, oldest first (nil = no value that day).
    public var points: [DayPoint]
    /// The newest metric in the period (title receipt, About); nil = none stored.
    public var latest: Metric?
    public var median: Double?
    public var q1: Double?
    public var q3: Double?
    /// Days with a value / days in the period.
    public var daysWithValue: Int
    public var daysInPeriod: Int
    /// Median of the previous period of the same length; nil = no data then.
    public var previousMedian: Double?
    /// T9894 (e-5): the median of the 7 days ending at the period's end, and how many of those 7 days had a value.
    /// nil / 0 = fewer than 3 days. Lets an empty header show "latest value + 7-day median".
    public var median7: Double?
    public var median7Days = 0
    /// Median ± 1.4826·MAD over 28 d (ALG-075 `normalBand`).
    public var bandLow: Double?
    public var bandHigh: Double?
    /// ALG-075 EWMA and CUSUM change points.
    public var ewma: [DayPoint]
    public var changeDays: [LocalDay]
    /// Why the numbers are blank, when they are ("Learning your normal — 6 of 14 nights").
    public var missingReason: String?
    /// Days of the period whose value is imported history, by source ("WHOOP export": 12); empty = all the app's own.
    public var importedDays: [String: Int] = [:]
    /// The part of the period fetched from the PC (tracker #7); nil = the phone holds the whole period.
    public var pcHistory: PCHistoryNote?
    /// T56: every `workout_hr_avg` row of the period (one per workout), for the by-activity trend; empty for other metrics.
    public var workoutRows: [DatedMetric] = []

    public init(key: String, variant: String? = nil, points: [DayPoint] = [], latest: Metric? = nil,
                median: Double? = nil, q1: Double? = nil, q3: Double? = nil, daysWithValue: Int = 0,
                daysInPeriod: Int = 0, previousMedian: Double? = nil, bandLow: Double? = nil, bandHigh: Double? = nil,
                ewma: [DayPoint] = [], changeDays: [LocalDay] = [], missingReason: String? = nil) {
        self.key = key
        self.variant = variant
        self.points = points
        self.latest = latest
        self.median = median
        self.q1 = q1
        self.q3 = q3
        self.daysWithValue = daysWithValue
        self.daysInPeriod = daysInPeriod
        self.previousMedian = previousMedian
        self.bandLow = bandLow
        self.bandHigh = bandHigh
        self.ewma = ewma
        self.changeDays = changeDays
        self.missingReason = missingReason
    }
}

/// Spearman ρ, paired days and BH q (WP-09 `spearman` + Benjamini–Hochberg) for one pair of metrics.
public struct CorrelationInput: Equatable, Sendable {
    public var rho: Double?
    public var n: Int
    public var q: Double?

    public init(rho: Double?, n: Int, q: Double?) {
        self.rho = rho
        self.n = n
        self.q = q
    }
}

public struct ExploreInput: Equatable, Sendable {
    public var period: ExplorePeriod
    public var query: String
    public var viewMode: MetricViewMode
    /// One per pinned key (shelf) — `settings.pinnedMetrics` order.
    public var shelf: [MetricAnalysis]
    /// The open metric detail (`.openMetric`), nil = none open.
    public var detail: MetricAnalysis?
    /// Device-change and Health-vault markers for the detail graph (APP-101/102).
    public var markers: [GraphMarker]
    /// The open group (`.openGroup`), nil = none.
    public var groupId: String?
    /// ALG-079 agreement sentence per group id (PC result), when known.
    public var agreement: [String: String]
    /// Matrix metric keys (≤ 8) and row-major cells, same order; the diagonal is ρ = 1.
    public var matrixKeys: [String]
    public var matrixCells: [[CorrelationInput]]
    /// Compare with… (`.openCompare`): nil = not open.
    public var compare: CompareInput?
    /// Wave 2: the newest row of every (variant, computed_on) per metric name — own, PC and imported history — for
    /// "Every measure" and a metric's sources. Empty = not read yet.
    public var latest: [String: [DatedMetric]] = [:]
    /// Tracker #7: "Every measure" with a period reaching before the phone's window — the PC part (its newest values
    /// are in `latest`, `fromPC`); nil = not asked.
    public var measuresPC: PCHistoryNote?
    /// Tracker #7: the open group's older part from the PC, one summary per (metric, variant); nil = not asked.
    public var groupPC: GroupPCInput?
    /// W10 #99: the open detail's days split by where the strap was worn (ALG-042); nil = not computed.
    public var wearCompare: WearCompare.Result?
    /// T96: one per metric Mo picked for Today (`settings.frontPage.picks`); empty = not read yet.
    public var todayPicks: [MetricAnalysis] = []
    /// Sleep expanded (Mo, Nov 5 2026): the last 90 nights of the sleep card's keys (`SleepBreakdownPresenter.trendKeys`), phone
    /// rows, for the baselines under the card's physiology strip and the 7 / 30 / 90 trends. Empty = not read.
    public var sleepTrends: [MetricAnalysis] = []

    public init(period: ExplorePeriod = .days30, query: String = "", viewMode: MetricViewMode = .number,
                shelf: [MetricAnalysis] = [], detail: MetricAnalysis? = nil, markers: [GraphMarker] = [],
                groupId: String? = nil, agreement: [String: String] = [:], matrixKeys: [String] = [],
                matrixCells: [[CorrelationInput]] = [], compare: CompareInput? = nil) {
        self.period = period
        self.query = query
        self.viewMode = viewMode
        self.shelf = shelf
        self.detail = detail
        self.markers = markers
        self.groupId = groupId
        self.agreement = agreement
        self.matrixKeys = matrixKeys
        self.matrixCells = matrixCells
        self.compare = compare
    }
}

/// The open group's older years from the PC (tracker #7): the note and one summary per (metric, variant), computed by
/// the app (median with MGSignal); the presenter only words them.
public struct GroupPCInput: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var name: String
        public var variant: String
        /// "WHOOP export" / "Tester’s Apple Watch via Apple Health" / "ALG-101 on past data".
        public var label: String
        public var unit: String
        public var median: Double
        public var days: Int
        public var first: LocalDay
        public var last: LocalDay

        public init(name: String, variant: String, label: String, unit: String, median: Double, days: Int,
                    first: LocalDay, last: LocalDay) {
            self.name = name
            self.variant = variant
            self.label = label
            self.unit = unit
            self.median = median
            self.days = days
            self.first = first
            self.last = last
        }
    }

    public var note: PCHistoryNote
    public var rows: [Row]

    public init(note: PCHistoryNote, rows: [Row]) {
        self.note = note
        self.rows = rows
    }
}

public struct CompareInput: Equatable, Sendable {
    public var firstKey: String
    public var secondKey: String?
    public var lagDays: Int
    /// One per day where both have a value (after the lag); x = first metric, y = second.
    public var pairs: [ComparePair]
    public var result: CorrelationInput?
    public var xUnit: String?
    public var yUnit: String?

    public init(firstKey: String, secondKey: String? = nil, lagDays: Int = 0, pairs: [ComparePair] = [],
                result: CorrelationInput? = nil, xUnit: String? = nil, yUnit: String? = nil) {
        self.firstKey = firstKey
        self.secondKey = secondKey
        self.lagDays = lagDays
        self.pairs = pairs
        self.result = result
        self.xUnit = xUnit
        self.yUnit = yUnit
    }
}

// MARK: - Guided flows (WP-29 states)

public struct BreatheInput: Equatable, Sendable {
    public var phase: BreatheState.Phase
    public var breathsPerMinute: Double
    public var minutes: Int
    public var startedAt: Date?
    public var endsAt: Date?
    /// R-R beats collected so far; nil = nothing collected (no strap).
    public var beatsCollected: Int?
    /// Why coherence will be missing ("Strap not connected — the pacer runs, no coherence."); nil = collecting.
    public var strapNote: String?
    /// Finished: what was measured (MGSignal output), else nil.
    public var result: BreatheMeasured?

    public init(phase: BreatheState.Phase, breathsPerMinute: Double = BreatheState.defaultBreathsPerMinute,
                minutes: Int = BreatheState.defaultMinutes, startedAt: Date? = nil, endsAt: Date? = nil,
                beatsCollected: Int? = nil, strapNote: String? = nil, result: BreatheMeasured? = nil) {
        self.phase = phase
        self.breathsPerMinute = breathsPerMinute
        self.minutes = minutes
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.beatsCollected = beatsCollected
        self.strapNote = strapNote
        self.result = result
    }
}

public struct BreatheMeasured: Equatable, Sendable {
    /// ALG-104 coherence ratio (blank metric with its reason when too little R-R).
    public var coherence: Metric
    /// Mo's median coherence over earlier sessions; nil = no history.
    public var usualCoherence: Double?
    /// Where the heart rhythm peaked (Hz); nil = no peak.
    public var peakHz: Double?
    public var meanHR: Metric?
    public var rmssd: Metric?
    /// ALG-020 breathing rate, compared with the pace (APP-031).
    public var respRate: Metric?
    public var secondsPaced: Double
    public var endedEarly: Bool
    public var saved: Bool

    public init(coherence: Metric, usualCoherence: Double? = nil, peakHz: Double? = nil, meanHR: Metric? = nil,
                rmssd: Metric? = nil, respRate: Metric? = nil, secondsPaced: Double, endedEarly: Bool, saved: Bool) {
        self.coherence = coherence
        self.usualCoherence = usualCoherence
        self.peakHz = peakHz
        self.meanHR = meanHR
        self.rmssd = rmssd
        self.respRate = respRate
        self.secondsPaced = secondsPaced
        self.endedEarly = endedEarly
        self.saved = saved
    }
}

public struct HRVCheckInput: Equatable, Sendable {
    public var phase: HRVCheckState.Phase
    public var minutes: Int
    public var startedAt: Date?
    public var endsAt: Date?
    public var beats: Int?
    public var flagged: Int?
    /// Seconds of R-R collected (the gate needs ≥ 60).
    public var secondsOfBeats: Double
    /// The composition's gate verdict (ALG-004 B: ≥ 60 s of beats and ≤ 5 % flagged); nil = not enough beats to judge.
    public var gatePassing: Bool?
    /// Why it can't measure (phase `.blocked`).
    public var blockedReason: String?
    public var result: HRVMeasured?
    /// Mo's night RMSSD median (comparison line); nil = no baseline yet.
    public var nightMedianRmssd: Double?

    public init(phase: HRVCheckState.Phase, minutes: Int = 3, startedAt: Date? = nil, endsAt: Date? = nil,
                beats: Int? = nil, flagged: Int? = nil, secondsOfBeats: Double = 0, gatePassing: Bool? = nil,
                blockedReason: String? = nil, result: HRVMeasured? = nil, nightMedianRmssd: Double? = nil) {
        self.phase = phase
        self.minutes = minutes
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.beats = beats
        self.flagged = flagged
        self.secondsOfBeats = secondsOfBeats
        self.gatePassing = gatePassing
        self.blockedReason = blockedReason
        self.result = result
        self.nightMedianRmssd = nightMedianRmssd
    }
}

public struct HRVMeasured: Equatable, Sendable {
    public var rmssd: Metric
    public var lnRmssd: Metric
    public var coherence: Metric
    public var meanHR: Metric?
    public var sdnn: Metric?
    public var beatsUsed: Int
    public var secondsMeasured: Double
    public var saved: Bool

    public init(rmssd: Metric, lnRmssd: Metric, coherence: Metric, meanHR: Metric? = nil, sdnn: Metric? = nil,
                beatsUsed: Int, secondsMeasured: Double, saved: Bool) {
        self.rmssd = rmssd
        self.lnRmssd = lnRmssd
        self.coherence = coherence
        self.meanHR = meanHR
        self.sdnn = sdnn
        self.beatsUsed = beatsUsed
        self.secondsMeasured = secondsMeasured
        self.saved = saved
    }
}

/// One workout for Workout detail: the event, its HR map, per-window numbers and its group members.
public struct WorkoutDetailInput: Equatable, Sendable {
    /// The workoutEvent (latest revision); its `id` is what `.editWorkout(id:edit:)` carries.
    public var event: EventRecord
    /// true while it runs (opened from a live workout).
    public var isLive: Bool
    /// Contract series "workout HR map" (`start`, `step_s`, `values` with nulls); nil = no HR.
    public var hrMap: Series?
    public var zoneEdgesBpm: [Double]?
    public var zoneBasis: String?
    public var zoneMinutes: [Double]
    /// Per-window numbers by `WorkoutDetailWindow.makeID(kind:start:)`.
    public var windowStats: [String: WorkoutWindowStats]
    /// G-LOAD and G-CAL members for this workout, ALG-012 HR recovery at 60 s and 120 s (`hr_recovery_60`,
    /// `hr_recovery_120`) and its time constant (`hr_recovery_tau`), and breathing (`resp_rate`).
    public var metrics: [Metric]
    public var setsDone: Int
    public var lastSetAt: Date?
    /// Minutes from this workout's end to the strap's asleep flag when that is 90 or fewer (`HRRBaseline.sleepAfterMinutes`);
    /// nil = no sleep within 90 min, or unknown.
    public var asleepAfterMin: Int?

    public init(event: EventRecord, isLive: Bool, hrMap: Series?, zoneEdgesBpm: [Double]?, zoneBasis: String?,
                zoneMinutes: [Double], windowStats: [String: WorkoutWindowStats], metrics: [Metric],
                setsDone: Int = 0, lastSetAt: Date? = nil, asleepAfterMin: Int? = nil) {
        self.asleepAfterMin = asleepAfterMin
        self.event = event
        self.isLive = isLive
        self.hrMap = hrMap
        self.zoneEdgesBpm = zoneEdgesBpm
        self.zoneBasis = zoneBasis
        self.zoneMinutes = zoneMinutes
        self.windowStats = windowStats
        self.metrics = metrics
        self.setsDone = setsDone
        self.lastSetAt = lastSetAt
    }
}

public struct WorkoutWindowStats: Equatable, Sendable {
    public var avgHR: Double?
    public var peakHR: Double?
    /// MS-01 Banister TRIMP for the window (blank metric with its reason when it can't run).
    public var trimp: Metric?
    public var zoneMinutes: [Double]?

    public init(avgHR: Double?, peakHR: Double?, trimp: Metric?, zoneMinutes: [Double]?) {
        self.avgHR = avgHR
        self.peakHR = peakHR
        self.trimp = trimp
        self.zoneMinutes = zoneMinutes
    }
}
