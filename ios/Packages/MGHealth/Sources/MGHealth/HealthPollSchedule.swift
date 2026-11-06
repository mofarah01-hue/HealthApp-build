import Foundation

// 0.5.7 V3: which Health types are safe to touch in this build, which are asked about permission, and when each is polled.
// Pure Swift (tested on a Mac); HealthKitLayer.swift only converts.
//
// WHY ONLY FOUR KINDS (Apple's HealthKit documentation, developer.apple.com, checked Oct 15 2026):
//  - HKHealthStore.requestAuthorization(toShare:read:): the read set may hold only HKObjectType subclasses the store can
//    authorize; a type it cannot authorize raises an Objective-C exception, which Swift cannot catch (SIGABRT).
//  - HKHealthStore.enableBackgroundDelivery(for:frequency:): "The system wakes your app at most once per time period";
//    iOS enforces an hourly maximum for some types transparently, so .hourly is the finest useful request.
//  - HKObserverQuery / statusForAuthorizationRequest: same family of calls; the phone's crash reports (V1: HKObserverQuery,
//    V2: statusForAuthorizationRequest) show both raise for state of mind, audiogram, heartbeat series and workout route.
//  - Per-object authorization (vision prescriptions, CDA documents, medication doses) is asked one item at a time, not on
//    the permission sheet; HKSeriesType (heartbeat, workout route) and HKStateOfMind are not plain sheet types.
// What 0.5.6 requested, observed and status-checked without a crash: quantity, category, workout, ecg. Everything else waits
// until it is proven on the phone ("not in this build (being made safe)"). See docs/DECISIONS.md D-V3-HK1.

extension HealthAutoType.Kind {
    /// Safe for requestAuthorization / status / observer / anchored queries in this build.
    public var isSafeInThisBuild: Bool {
        switch self {
        case .quantity, .category, .workout, .ecg: return true
        default: return false
        }
    }
}

extension HealthAutoType {
    public var isSafeInThisBuild: Bool { kind.isSafeInThisBuild }
    public static let notInBuildText = "not in this build (being made safe)"
}

/// Answers "has the permission sheet been shown for this read set?" with ONE HealthKit call for the whole set.
public protocol HealthAskedStatusSource: Sendable {
    /// One `statusForAuthorizationRequest` for these type ids together. true = already shown (an error counts as shown).
    func readRequestAlreadyShown(typeIDs: [String]) async -> Bool
}

public enum HealthAskedTypes {
    /// Safe types are all asked or all not (one sheet covers them); unsafe types are never sent to HealthKit.
    public static func ids(_ types: [HealthAutoType], source: any HealthAskedStatusSource) async -> Set<String> {
        let safe = types.filter { $0.isSafeInThisBuild && $0.kind != .correlation }
        guard !safe.isEmpty else { return [] }
        let shown = await source.readRequestAlreadyShown(typeIDs: safe.map(\.id))
        return shown ? Set(safe.map(\.id)) : []
    }
}

public enum HealthPollCadence: String, Sendable {
    case frequent       // observer + background delivery .hourly
    case afterWake      // the night's data: when the night ends, and on the first open after it
    case daily          // once a day
    case manual         // only on "Sync now"
}

public enum HealthPollTrigger: Sendable {
    /// Observer callback, launch / foreground, background refresh: only what is due.
    case automatic
    /// "Sync now": every safe type (still capped per run, resumed next time).
    case manual
}

public enum HealthPollSchedule {
    private static let q = "HKQuantityTypeIdentifier"
    private static let c = "HKCategoryTypeIdentifier"

    static let frequent: Set<String> = [
        q + "HeartRate", q + "StepCount", q + "ActiveEnergyBurned", q + "BasalEnergyBurned", q + "DistanceWalkingRunning",
        q + "FlightsClimbed", q + "AppleExerciseTime", q + "AppleStandTime", q + "AppleMoveTime",
        q + "HeartRateVariabilitySDNN", q + "HeartRateVariabilityRMSSD", q + "RespiratoryRate", q + "OxygenSaturation",
        c + "AppleStandHour", c + "MindfulSession", c + "HighHeartRateEvent", c + "LowHeartRateEvent",
        c + "IrregularHeartRhythmEvent", HealthAutoCatalogue.workoutID, HealthAutoCatalogue.ecgID,
    ]
    /// Pulled once the night is over, in addition to their own cadence (Mo: "sleep should be grabbed after wake with the SpO2").
    static let afterWake: Set<String> = [
        c + "SleepAnalysis", q + "AppleSleepingWristTemperature", q + "AppleSleepingBreathingDisturbances",
        q + "OxygenSaturation", q + "HeartRateVariabilitySDNN", q + "HeartRateVariabilityRMSSD", q + "RespiratoryRate",
        c + "SleepApneaEvent",
    ]
    static let afterWakeOnly: Set<String> = [
        c + "SleepAnalysis", q + "AppleSleepingWristTemperature", q + "AppleSleepingBreathingDisturbances", c + "SleepApneaEvent",
    ]
    static let daily: Set<String> = [
        q + "BodyMass", q + "BodyMassIndex", q + "BodyFatPercentage", q + "LeanBodyMass", q + "Height", q + "VO2Max",
        q + "RestingHeartRate", q + "WalkingHeartRateAverage", q + "HeartRateRecoveryOneMinute", q + "WalkingSpeed",
        q + "WalkingStepLength", q + "WalkingAsymmetryPercentage", q + "WalkingDoubleSupportPercentage",
        q + "StairAscentSpeed", q + "StairDescentSpeed", q + "SixMinuteWalkTestDistance", q + "AppleWalkingSteadiness",
        q + "EnvironmentalAudioExposure", q + "HeadphoneAudioExposure", q + "TimeInDaylight", q + "UVExposure",
        q + "RunningSpeed", q + "RunningPower", q + "RunningStrideLength", q + "RunningVerticalOscillation",
        q + "RunningGroundContactTime", q + "AtrialFibrillationBurden", q + "BodyTemperature", q + "BasalBodyTemperature",
        c + "AppleWalkingSteadinessEvent", c + "EnvironmentalAudioExposureEvent", c + "HeadphoneAudioExposureEvent",
        c + "LowCardioFitnessEvent",
    ]

    public static func cadence(for type: HealthAutoType) -> HealthPollCadence {
        if afterWakeOnly.contains(type.id) { return .afterWake }
        if frequent.contains(type.id) { return .frequent }
        if daily.contains(type.id) { return .daily }
        return .manual
    }

    /// A frequent type is polled when its last complete read is older than this (background delivery is hourly at best).
    public static let frequentAge: TimeInterval = 50 * 60
    public static let dailyAge: TimeInterval = 20 * 3600
    /// T9974 (2026-10-17): the Watch writes the night's sleep, wrist temperature and breathing disturbances to Health some time
    /// AFTER the wake (it syncs to the iPhone later), so the one read at wake can come back empty and the type then waited
    /// 20 hours. For this long after a wake those types are read again whenever `frequentAge` has passed.
    public static let afterWakeWindow: TimeInterval = 6 * 3600

    /// Is `type` due now? `lastComplete` = when a read of it last caught up to the end (nil = never, or a history pull is
    /// still unfinished: always due). `wakeAt` = the most recent detected wake (strap flag or phone), if known.
    public static func isDue(_ type: HealthAutoType, trigger: HealthPollTrigger, lastComplete: Date?, wakeAt: Date?,
                             now: Date) -> Bool {
        guard type.isSafeInThisBuild, type.kind != .correlation else { return false }
        if trigger == .manual { return true }
        guard let last = lastComplete else { return cadence(for: type) != .manual }   // first pull / unfinished history
        let age = now.timeIntervalSince(last)
        var due = false
        switch cadence(for: type) {
        case .frequent: due = age >= frequentAge
        case .daily: due = age >= dailyAge
        case .afterWake: due = age >= dailyAge
        case .manual: due = false
        }
        if afterWake.contains(type.id), let wakeAt, last < wakeAt { due = true }
        if afterWakeOnly.contains(type.id), let wakeAt, now >= wakeAt, now.timeIntervalSince(wakeAt) < afterWakeWindow,
           age >= frequentAge { due = true }
        return due
    }

    /// The types a run reads, in order. T10015 (2026-10-17): the order used to put every type whose history was not fully
    /// pulled first, so a long first pull (years of steps and distance, 4 pages per type per run, 60 pages per run) used the
    /// whole run and the types that only needed a catch-up never got a turn: no sleep, heart rate or anything else reached the
    /// PC after Oct 15 (the PC log showed 2017 distance samples still arriving on Oct 17). Now:
    ///   0. after-wake types whose wake is newer than their last read (the night that just ended),
    ///   1. types whose history is complete, longest-waiting first (a catch-up is a page or two),
    ///   2. types whose history is still being pulled (the backfill takes what budget is left).
    /// The catalogue order breaks ties.
    public static func plan(_ types: [HealthAutoType], trigger: HealthPollTrigger, complete: [String: Date], wakeAt: Date?,
                            now: Date) -> [HealthAutoType] {
        let due = types.enumerated().filter {
            isDue($0.element, trigger: trigger, lastComplete: complete[$0.element.id], wakeAt: wakeAt, now: now)
        }
        func rank(_ type: HealthAutoType) -> Int {
            guard let last = complete[type.id] else { return 2 }
            if afterWake.contains(type.id), let wakeAt, last < wakeAt { return 0 }
            return 1
        }
        return due.sorted {
            let ra = rank($0.element), rb = rank($1.element)
            if ra != rb { return ra < rb }
            let a = complete[$0.element.id] ?? .distantPast, b = complete[$1.element.id] ?? .distantPast
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }
}
