import Foundation
import MGContext
import MGDomain
import MGStore

// WP-23a — Mo's settings and the app's small bookkeeping, kept in MGStore's key-value table (ARCHITECTURE §4.5 `kv`:
// "profile, settings, install salt, results cursor, consents"). The profile itself lives under MGStore's own
// `profile()` / `setProfile(_:)`. JSON through MGJSON so dates are RFC 3339 like every other file the app writes.
//
// WRITTEN, NOT COMPILED.

/// Settings › … (UX §14) plus the switches Tonight and Explore keep. Every field is optional-tolerant on decode so a
/// later build can add fields without losing what an earlier build stored.
struct AppSettings: Codable, Equatable, Sendable {
    var theme: ThemeSetting = .followDay
    /// SAMPLE mode: off by default (BRIEF hard rule). While on, nothing is written and nothing syncs.
    var sampleData: Bool = false
    var researchRowsShown: Bool = true
    /// T142 (Mo 2026-10-12): hide the moving "Working on:" strip (uploading / processing / waiting on the PC). Shown by default.
    var hideWorkingBars: Bool = true   // 2026-10-12 10 PM PT: was false; Mo asked for the top bars hidden (T142/T149), the detail lives in Settings › Working on
    /// "Must be up by" per weekday, "1"…"7" (1 = Sunday) → minutes after midnight. Blank until Mo fills it.
    var latestWakeMinutes: [String: Int] = [:]
    /// 10…45, default 30 (BRIEF default 3).
    var wakeWindowMinutes: Int = 30
    var needOverrideMinutes: Int?
    var schedules: [MedSchedule] = []
    var drinkPresets: [StoredDrinkPreset] = []
    /// T9746: Mo's editable Medications / Supplements / Drinks lists, seeded once (PresetLists.seedIfNeeded). Part of
    /// this document, so Export's kv/kv.json carries them.
    var presetLists = PresetLists()
    var usualDrink: String?
    /// Settings › Quick-log surfaces by id ("doubleTap", "widget", "actionButton"). A missing id = on.
    var quickLogSurfaces: [String: Bool] = [:]
    var smartWakeOn: Bool = true
    var windDownOn: Bool = true
    /// T31: the 5:00 PM daily body-arousal summary notification. On by default; the plan skips it when off.
    var stressSummaryOn: Bool = true
    var phoneHaptics: Bool = true
    var pinnedMetrics: [String] = []
    var explorePeriod: String = ExplorePeriod.days30.key
    /// T9822: the last custom range picked (kept when a preset is chosen); ISO days, nil = none yet.
    var customRangeStart: String?
    var customRangeEnd: String?
    var matrixKeys: [String] = []
    /// The standing consent for the strap clock set (D6), given at strap pairing. nil = only read the clock.
    var clockConsentAt: Date?
    /// Mo answered the clock question (yes or no) — so the sheet is not shown again.
    var clockConsentAsked: Bool = false
    /// Apple Health mirror (D12): off by default; no Settings row offers it in B1.
    var healthMirrorOn: Bool = false
    /// Strap & sync › "Raw optical (uses strap battery)": live R20 (108), in the background too (T10000: since 0.5.8,
    /// until switched off; it pauses only for history downloads). OFF by default again since 2026-10-13 (T147, Mo; D-028 done): on from Settings or the Live
    /// tab. Same for the three switches below (`StrapSwitchDefaults`); a value already saved is kept.
    var rawOpticalOn: Bool = StrapSwitchDefaults.fresh.rawOptical
    /// Watching for R22 records after the one enable_r22_packets = '1' write (Mo 2026-10-11: "Single write, then see");
    /// nil when no write is being watched (never written, or restored).
    var r22Watch: R22Watch?
    /// Wave 4 (#65): raw optical's night windows in the background (under `rawOpticalOn`); off by default (T147).
    /// Since wave W11 the app-open live optical runs as well.
    var rawOpticalNightsOnly: Bool = StrapSwitchDefaults.fresh.rawOpticalNights
    /// The strap's SpO₂ burst schedule learned from its R18 (nil = the research default).
    var spo2Schedule: SpO2BurstSchedule?
    /// Nights watched (planned window, live R20 records stored), newest last, at most 30; the battery cost compares
    /// nights with and without raw optical. `rawOpticalPendingNight` is tonight's, closed when it ends.
    var rawOpticalNights: [RawOpticalNightLog] = []
    var rawOpticalPendingNight: RawOpticalNightLog?
    /// T124 (2026-10-13): more raw-optical windows, in the background too (under `rawOpticalOn`): during a workout
    /// (on), "SpO₂ on for X every X" (nil = off), and while the wrist is still (off; battery).
    var rawOpticalInWorkout: Bool = true
    var spo2Every: SpO2Every?
    var rawOpticalWhenStill: Bool = false
    /// Settings › Front page (tracker #34, 2026-10-11): Today's cards in Mo's order, hidden / removed ones, and the dial
    /// layers switched off. Missing (settings from an earlier build) = the default front page.
    var frontPage = FrontPageLayout.standard
    /// T104: the daily calorie goal behind the Sundial's burn ring. nil = none set; the ring then shows the burn with
    /// no fill. Never a default number.
    var calorieGoalKcal: Double?
    /// Settings â€º Sun vitamin D: quiz result and a hand-entered place, never GPS or location permission.
    var fitzpatrickSkinType: Int?
    var vitaminDLocation: VitaminDRoughLocation?
    /// Strap & sync › "ECG (MG)" and "Raw motion (100 Hz)" (wave W8, 2026-10-11; CLAUDE.md rule 5: each behind its own
    /// switch — OFF by default again since 2026-10-13, T147). `ecgWrist` = the wrist the strap is worn
    /// on ("left" / "right"), sent as SELECT_WRIST (123).
    var ecgOn: Bool = StrapSwitchDefaults.fresh.ecg
    var rawMotionOn: Bool = StrapSwitchDefaults.fresh.rawMotion
    var ecgWrist: String = "left"
    /// `StrapSwitchDefaults.version` these settings were migrated to. A fresh install starts current; settings saved
    /// before the field existed decode as 0, nothing resets the switches from it any more (T147).
    var strapDefaultsVersion: Int = StrapSwitchDefaults.version
    /// Strap & sync › "Hand the strap back to WHOOP" (wave W12b, #103): while on, the link is not started. The summary
    /// of the last hand-back, and whether it put enable_r22_packets back (switching off re-applies it, confirm sheet).
    var handBackToWhoop: Bool = false
    /// 0.6.0.3 "Ring live": which device feeds the live heart rate (Settings › Strap & sync › Input device).
    var inputDevice: InputDevice = .auto
    var handBackLines: [String] = []
    var handBackR22Restored: Bool = false
    /// T77 (Mo 2026-10-13): Settings › "Broadcast heart rate to other devices" (commands 14 + 119). OFF by default (battery).
    var hrBroadcastOn: Bool = false
    /// 0.6.0.12: "Read WHOOP 5.0 heart-rate broadcast" (off by default) and the one sensor Mo picked (peripheral id on this phone).
    var hrReadOn: Bool = false
    var hrReadChoiceID: String?
    var hrReadChoiceName: String?
    /// T9992 (Mo, Oct 16): "Keep raw on the strap if the app is closed (fills strap memory, longer downloads)": while raw
    /// optical is on, also ask the strap (107) to bank R20 into its own history. Off by default; its own switch.
    var keepRawOnStrap: Bool = false
    /// r9q (D-LOAD-WALK-2, D-TRENDS-1): automatic raw streams for workouts (with Mo's yes / no answers and what the detector
    /// learned from them), raw bursts at quiet moments, and the 50 Hz log. All of it is MGContext `AutoRawSettings`.
    var autoRaw = AutoRawSettings()
    /// T9841: notification kinds Mo chose to skip (`NotifyKind` raw values, sorted).
    var skippedNotifications: [String] = []
    /// T9841: smart-wake mode (`SmartWakeModes` ids; "window" = the original rule), the time gate (minutes after midnight,
    /// nil = not set) and the minimum rest share in percent.
    var smartWakeMode: String = SmartWakeModes.defaultID
    var smartWakeGateMinutes: Int?
    var smartWakeRestPercent: Int = SmartWakeModes.defaultRestPercent

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = (try? c.decodeIfPresent(ThemeSetting.self, forKey: .theme)) ?? d.theme
        sampleData = (try? c.decodeIfPresent(Bool.self, forKey: .sampleData)) ?? d.sampleData
        researchRowsShown = (try? c.decodeIfPresent(Bool.self, forKey: .researchRowsShown)) ?? d.researchRowsShown
        hideWorkingBars = (try? c.decodeIfPresent(Bool.self, forKey: .hideWorkingBars)) ?? d.hideWorkingBars
        latestWakeMinutes = (try? c.decodeIfPresent([String: Int].self, forKey: .latestWakeMinutes)) ?? d.latestWakeMinutes
        wakeWindowMinutes = (try? c.decodeIfPresent(Int.self, forKey: .wakeWindowMinutes)) ?? d.wakeWindowMinutes
        needOverrideMinutes = try? c.decodeIfPresent(Int.self, forKey: .needOverrideMinutes)
        schedules = (try? c.decodeIfPresent([MedSchedule].self, forKey: .schedules)) ?? d.schedules
        drinkPresets = (try? c.decodeIfPresent([StoredDrinkPreset].self, forKey: .drinkPresets)) ?? d.drinkPresets
        presetLists = (try? c.decodeIfPresent(PresetLists.self, forKey: .presetLists)) ?? d.presetLists
        usualDrink = try? c.decodeIfPresent(String.self, forKey: .usualDrink)
        quickLogSurfaces = (try? c.decodeIfPresent([String: Bool].self, forKey: .quickLogSurfaces)) ?? d.quickLogSurfaces
        smartWakeOn = (try? c.decodeIfPresent(Bool.self, forKey: .smartWakeOn)) ?? d.smartWakeOn
        windDownOn = (try? c.decodeIfPresent(Bool.self, forKey: .windDownOn)) ?? d.windDownOn
        stressSummaryOn = (try? c.decodeIfPresent(Bool.self, forKey: .stressSummaryOn)) ?? d.stressSummaryOn
        phoneHaptics = (try? c.decodeIfPresent(Bool.self, forKey: .phoneHaptics)) ?? d.phoneHaptics
        pinnedMetrics = (try? c.decodeIfPresent([String].self, forKey: .pinnedMetrics)) ?? d.pinnedMetrics
        explorePeriod = (try? c.decodeIfPresent(String.self, forKey: .explorePeriod)) ?? d.explorePeriod
        customRangeStart = try? c.decodeIfPresent(String.self, forKey: .customRangeStart)
        customRangeEnd = try? c.decodeIfPresent(String.self, forKey: .customRangeEnd)
        matrixKeys = (try? c.decodeIfPresent([String].self, forKey: .matrixKeys)) ?? d.matrixKeys
        clockConsentAt = try? c.decodeIfPresent(Date.self, forKey: .clockConsentAt)
        clockConsentAsked = (try? c.decodeIfPresent(Bool.self, forKey: .clockConsentAsked)) ?? d.clockConsentAsked
        healthMirrorOn = (try? c.decodeIfPresent(Bool.self, forKey: .healthMirrorOn)) ?? d.healthMirrorOn
        rawOpticalOn = (try? c.decodeIfPresent(Bool.self, forKey: .rawOpticalOn)) ?? d.rawOpticalOn
        r22Watch = try? c.decodeIfPresent(R22Watch.self, forKey: .r22Watch)
        rawOpticalNightsOnly = (try? c.decodeIfPresent(Bool.self, forKey: .rawOpticalNightsOnly)) ?? d.rawOpticalNightsOnly
        spo2Schedule = try? c.decodeIfPresent(SpO2BurstSchedule.self, forKey: .spo2Schedule)
        rawOpticalNights = (try? c.decodeIfPresent([RawOpticalNightLog].self, forKey: .rawOpticalNights)) ?? []
        rawOpticalPendingNight = try? c.decodeIfPresent(RawOpticalNightLog.self, forKey: .rawOpticalPendingNight)
        rawOpticalInWorkout = (try? c.decodeIfPresent(Bool.self, forKey: .rawOpticalInWorkout)) ?? d.rawOpticalInWorkout
        spo2Every = try? c.decodeIfPresent(SpO2Every.self, forKey: .spo2Every)
        rawOpticalWhenStill = (try? c.decodeIfPresent(Bool.self, forKey: .rawOpticalWhenStill)) ?? d.rawOpticalWhenStill
        frontPage = (try? c.decodeIfPresent(FrontPageLayout.self, forKey: .frontPage)) ?? d.frontPage
        calorieGoalKcal = try? c.decodeIfPresent(Double.self, forKey: .calorieGoalKcal)
        fitzpatrickSkinType = try? c.decodeIfPresent(Int.self, forKey: .fitzpatrickSkinType)
        vitaminDLocation = try? c.decodeIfPresent(VitaminDRoughLocation.self, forKey: .vitaminDLocation)
        ecgOn = (try? c.decodeIfPresent(Bool.self, forKey: .ecgOn)) ?? d.ecgOn
        rawMotionOn = (try? c.decodeIfPresent(Bool.self, forKey: .rawMotionOn)) ?? d.rawMotionOn
        ecgWrist = (try? c.decodeIfPresent(String.self, forKey: .ecgWrist)) ?? d.ecgWrist
        strapDefaultsVersion = (try? c.decodeIfPresent(Int.self, forKey: .strapDefaultsVersion)) ?? 0
        handBackToWhoop = (try? c.decodeIfPresent(Bool.self, forKey: .handBackToWhoop)) ?? d.handBackToWhoop
        inputDevice = (try? c.decodeIfPresent(InputDevice.self, forKey: .inputDevice)) ?? d.inputDevice
        handBackLines = (try? c.decodeIfPresent([String].self, forKey: .handBackLines)) ?? d.handBackLines
        handBackR22Restored = (try? c.decodeIfPresent(Bool.self, forKey: .handBackR22Restored)) ?? d.handBackR22Restored
        hrBroadcastOn = (try? c.decodeIfPresent(Bool.self, forKey: .hrBroadcastOn)) ?? d.hrBroadcastOn
        hrReadOn = (try? c.decodeIfPresent(Bool.self, forKey: .hrReadOn)) ?? d.hrReadOn
        hrReadChoiceID = try? c.decodeIfPresent(String.self, forKey: .hrReadChoiceID)
        hrReadChoiceName = try? c.decodeIfPresent(String.self, forKey: .hrReadChoiceName)
        skippedNotifications = (try? c.decodeIfPresent([String].self, forKey: .skippedNotifications)) ?? d.skippedNotifications
        smartWakeMode = (try? c.decodeIfPresent(String.self, forKey: .smartWakeMode)) ?? d.smartWakeMode
        smartWakeGateMinutes = try? c.decodeIfPresent(Int.self, forKey: .smartWakeGateMinutes)
        smartWakeRestPercent = (try? c.decodeIfPresent(Int.self, forKey: .smartWakeRestPercent)) ?? d.smartWakeRestPercent
        keepRawOnStrap = (try? c.decodeIfPresent(Bool.self, forKey: .keepRawOnStrap)) ?? d.keepRawOnStrap
        autoRaw = (try? c.decodeIfPresent(AutoRawSettings.self, forKey: .autoRaw)) ?? d.autoRaw
    }

    // MARK: Typed views

    var latestWake: [Int: TimeOfDay] {
        var out: [Int: TimeOfDay] = [:]
        for (k, m) in latestWakeMinutes {
            guard let day = Int(k), (1...7).contains(day), (0..<(24 * 60)).contains(m) else { continue }
            out[day] = TimeOfDay(hour: m / 60, minute: m % 60)
        }
        return out
    }

    mutating func setLatestWake(weekday: Int, time: TimeOfDay?) {
        guard (1...7).contains(weekday) else { return }
        if let time {
            latestWakeMinutes[String(weekday)] = time.hour * 60 + time.minute
        } else {
            latestWakeMinutes.removeValue(forKey: String(weekday))
        }
    }

    /// The last custom range picked, nil when none (or the stored days are not real dates).
    var customRange: CustomRange? {
        guard let s = customRangeStart.flatMap({ LocalDay(iso: $0) }), let e = customRangeEnd.flatMap({ LocalDay(iso: $0) }),
              CustomRange.problem(start: s, end: e, today: Self.localToday()) == nil else { return nil }
        return CustomRange(start: s, end: e)
    }

    /// Today in the app's calendar (the phone's zone): a stored range ending after it is refused, same as a newly picked one.
    private static func localToday(calendar: Calendar = .autoupdatingCurrent) -> LocalDay {
        LocalDay(date: Date(), calendar: calendar)
    }

    var period: ExplorePeriod { ExplorePeriod(key: explorePeriod, custom: customRange) ?? .days30 }

    var drinkPresetStates: [DrinkPreset] { drinkPresets.map { DrinkPreset(name: $0.name, caffeineMg: $0.caffeineMg) } }

    /// The drink presets the Log and the quick-log pill use: Settings' list, else the UX §7 standard five.
    var effectiveDrinks: [StoredDrinkPreset] {
        if !drinkPresets.isEmpty { return drinkPresets }
        return LogCatalogue.standard.drinks.map { StoredDrinkPreset(name: $0.name, caffeineMg: $0.caffeineMg) }
    }

    func surfaceOn(_ id: String) -> Bool { quickLogSurfaces[id] ?? true }

    func presenterSettings(profile: Profile, nightSoundsOn: Bool, ringer: SmartWakeBlockState.Ringer) -> PresenterSettings {
        var presenter = PresenterSettings(profile: profile, latestWake: latestWake, wakeWindowMinutes: wakeWindowMinutes,
                          needOverrideMinutes: needOverrideMinutes, schedules: schedules,
                          drinkPresets: drinkPresetStates, usualDrink: usualDrink, quickLogSurfaces: quickLogSurfaces,
                          theme: theme, researchRowsShown: researchRowsShown, smartWakeOn: smartWakeOn,
                          nightSoundsOn: nightSoundsOn, windDownOn: windDownOn, stressSummaryOn: stressSummaryOn,
                          phoneHaptics: phoneHaptics,
                          ringer: ringer, pinnedMetrics: pinnedMetrics, frontPage: frontPage,
                          hideWorkingBars: hideWorkingBars, calorieGoalKcal: calorieGoalKcal,
                          fitzpatrickSkinType: fitzpatrickSkinType, vitaminDLocation: vitaminDLocation)
        presenter.presetLists = presetLists
        presenter.skippedNotifications = Set(skippedNotifications)
        presenter.smartWakeMode = smartWakeMode
        presenter.smartWakeGateMinutes = smartWakeGateMinutes
        presenter.smartWakeRestPercent = smartWakeRestPercent
        return presenter
    }

    func computeSettings(profile: Profile, timeZone: TimeZone) -> ComputeSettings {
        // Adherence counts scheduled, current medications only: as-needed and stopped entries of the medications list
        // (tracker #42, 2026-10-11) have no doses due.
        ComputeSettings(needOverrideMinutes: needOverrideMinutes, latestWake: latestWake, timeZone: timeZone,
                        profile: profile, medSchedules: schedules.filter { $0.asNeeded != true && $0.stopped == nil },
                        lisdexAliases: LocalPresetLoader.lisdexAliases)
    }
}

/// `DrinkPreset` (MGContext) is not Codable; this is its stored form.
struct StoredDrinkPreset: Codable, Equatable, Sendable {
    var name: String
    var caffeineMg: Double
}

/// The questions bookkeeping the context engine needs but the store has no table for (UX §5): what was answered,
/// swiped away, shown today; nap / workout answers that are not in a contract field yet.
struct PeekLedger: Codable, Equatable, Sendable {
    /// PendingQuestion ids answered (or expired with an assumed answer). Trimmed to the last 400.
    var answered: [String] = []
    /// PendingQuestion id → when it was swiped down ("later").
    var deferred: [String: Date] = [:]
    /// Ids shown as a peek, per wake day ("2026-10-11" → ids), for the daily cap of 4.
    var shown: [String: [String]] = [:]
    /// Consecutive swipe-aways per kind (PeekKindKey raw value).
    var swipeStreak: [String: Int] = [:]
    /// The last WRIST_ON (live strap event 9) and the location before it, for the wear-location question.
    var wristOnAt: Date?
    var wearBefore: WearLocation?
    /// Detected workout id → Mo's answer (true = yes, false = not a workout). The contract has no confirmed field.
    var workoutAnswers: [String: Bool] = [:]
    /// Naps Mo labelled nap / dozed: their end, for the "30 min after your nap" question.
    var napEnds: [Date] = []
    /// Morning check-in: the wake it belongs to and the step reached (1 = feel asked, 2 = "yesterday" asked).
    var checkinWake: Date?
    var checkinStep: Int = 1
    var checkinDone: Bool = false
    /// WP-22 DayPipeline suggestions not stored as events (never logged automatically): ALG-041 workouts and ALG-033
    /// naps, each asked about once ("Workout 17:32–18:20 — right?", "Nap 14:05–14:31?").
    var suggestedWorkouts: [SuggestionSpan] = []
    var suggestedNaps: [SuggestionSpan] = []

    struct SuggestionSpan: Codable, Equatable, Sendable {
        var start: Date
        var end: Date
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answered = (try? c.decodeIfPresent([String].self, forKey: .answered)) ?? []
        deferred = (try? c.decodeIfPresent([String: Date].self, forKey: .deferred)) ?? [:]
        shown = (try? c.decodeIfPresent([String: [String]].self, forKey: .shown)) ?? [:]
        swipeStreak = (try? c.decodeIfPresent([String: Int].self, forKey: .swipeStreak)) ?? [:]
        wristOnAt = try? c.decodeIfPresent(Date.self, forKey: .wristOnAt)
        wearBefore = try? c.decodeIfPresent(WearLocation.self, forKey: .wearBefore)
        workoutAnswers = (try? c.decodeIfPresent([String: Bool].self, forKey: .workoutAnswers)) ?? [:]
        napEnds = (try? c.decodeIfPresent([Date].self, forKey: .napEnds)) ?? []
        checkinWake = try? c.decodeIfPresent(Date.self, forKey: .checkinWake)
        checkinStep = (try? c.decodeIfPresent(Int.self, forKey: .checkinStep)) ?? 1
        checkinDone = (try? c.decodeIfPresent(Bool.self, forKey: .checkinDone)) ?? false
        suggestedWorkouts = (try? c.decodeIfPresent([SuggestionSpan].self, forKey: .suggestedWorkouts)) ?? []
        suggestedNaps = (try? c.decodeIfPresent([SuggestionSpan].self, forKey: .suggestedNaps)) ?? []
    }

    /// Adds new suggestions (same start = same suggestion) and forgets those that ended more than a day ago.
    mutating func merge(workouts: [DateInterval], naps: [DateInterval], now: Date) {
        func merged(_ old: [SuggestionSpan], _ new: [DateInterval]) -> [SuggestionSpan] {
            var out = old
            for i in new where !out.contains(where: { abs($0.start.timeIntervalSince(i.start)) < 60 }) {
                out.append(SuggestionSpan(start: i.start, end: i.end))
            }
            return out.filter { now.timeIntervalSince($0.end) < 24 * 3600 }.sorted { $0.start < $1.start }
        }
        suggestedWorkouts = merged(suggestedWorkouts, workouts)
        suggestedNaps = merged(suggestedNaps, naps)
    }

    mutating func markAnswered(_ id: String) {
        if !answered.contains(id) { answered.append(id) }
        if answered.count > 400 { answered.removeFirst(answered.count - 400) }
        deferred.removeValue(forKey: id)
    }

    func isAnswered(_ id: String) -> Bool { answered.contains(id) }

    /// How many questions of one kind were answered (id prefix: "wear:", "workout:", "nap:", "nap30:", "meal"): the
    /// `occurrence` a new question of that kind gets, so "asks half as often" (UX §5) alternates.
    func answeredCount(prefix: String) -> Int { answered.filter { $0.hasPrefix(prefix) }.count }

    mutating func markShown(_ id: String, day: LocalDay) {
        var ids = shown[day.iso] ?? []
        if !ids.contains(id) { ids.append(id) }
        shown[day.iso] = ids
        // Keep a week.
        let keep = shown.keys.sorted().suffix(7)
        shown = shown.filter { keep.contains($0.key) }
    }

    func shownCount(day: LocalDay) -> Int { shown[day.iso]?.count ?? 0 }

    var streakByKind: [PeekKindKey: Int] {
        var out: [PeekKindKey: Int] = [:]
        for (k, v) in swipeStreak { if let key = PeekKindKey(rawValue: k) { out[key] = v } }
        return out
    }
}

/// A manual workout or nap timer that is running, kept across app restarts.
struct LiveSessions: Codable, Equatable, Sendable {
    struct Workout: Codable, Equatable, Sendable {
        var id: UUID
        var start: Date
        var activityType: String?
        var place: String?
        var note: String?
        var windows: [WorkoutFields.Window]
        var setsDone: Int
        var lastSetAt: Date?
        /// Where the strap is worn for this workout (r9o); nil = not set. Kept last so an older saved state still decodes.
        var wearLocation: WearLocation?
    }

    struct Nap: Codable, Equatable, Sendable {
        var start: Date
        var plannedMinutes: Int
    }

    var workout: Workout?
    var nap: Nap?
    /// Moments Mo dismissed ("Later"), by MomentKind raw value → when.
    var dismissedMoments: [Int: Date] = [:]
    /// Wave 2: notifications the app posted by itself, slot → "<request id>@<unix time>" (alerts once each; reminders
    /// replaced when their time moves, withdrawn when no longer wanted).
    var notified: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workout = try? c.decodeIfPresent(Workout.self, forKey: .workout)
        nap = try? c.decodeIfPresent(Nap.self, forKey: .nap)
        dismissedMoments = (try? c.decodeIfPresent([Int: Date].self, forKey: .dismissedMoments)) ?? [:]
        notified = (try? c.decodeIfPresent([String: String].self, forKey: .notified)) ?? [:]
    }
}

/// Load / save of the three documents above. Errors surface to the caller (they become the app's notice line), never
/// swallowed.
struct AppSettingsStore: Sendable {
    let store: MGStore

    static let settingsKey = "app.settings"
    static let ledgerKey = "app.peek_ledger"
    static let sessionsKey = "app.live_sessions"
    static let syncLedgerKey = "mgsync.ledger"
    static let mirrorStateKey = "mghealth.mirror_state"
    static let healthAutoKey = "mghealth.auto_sync"     // T9739: anchors + queue of the automatic Health -> PC read

    func load<T: Decodable>(_ type: T.Type, key: String) async throws -> T? {
        guard let data = try await store.value(forKey: key) else { return nil }
        return try MGJSON.decoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, key: String) async throws {
        try await store.setValue(try MGJSON.encoder().encode(value), forKey: key)
    }
}
