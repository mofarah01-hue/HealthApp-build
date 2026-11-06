import Foundation
import MGDomain

// WP-22 Pipelines — the ports the pipelines read and write through (approved by main 2026-10-11).
// MGSignal depends only on MGDomain, so it cannot see MGStore. Every requirement below has EXACTLY the signature of an
// existing public MGStore method (app/ios/Packages/MGStore/Sources/MGStore/StreamReads.swift, Metrics.swift,
// Events.swift), so WP-23's conformance is `extension MGStore: PipelineSource, PipelineSink {}` plus `memberMarks()`
// (MGStore's GroupMarkValue / GroupMarkEntry are not visible here; `MemberMark` mirrors their raw values).
// WRITTEN, NOT COMPILED (no Swift toolchain on the build PC).

/// Reads of stored data for one pipeline run. Ranges of strap streams are unix seconds, inclusive (MGStore).
public protocol PipelineSource: Sendable {
    func hrSamples(from: Int64, to: Int64, strapId: StrapID?) async throws -> [HRPoint]
    func rrIntervals(from: Int64, to: Int64, strapId: StrapID?) async throws -> [RRPoint]
    func r18Seconds(from: Int64, to: Int64, strapId: StrapID?) async throws -> [R18Second]
    func events(from: Date, to: Date, types: [EventType]?, includeRemoved: Bool) async throws -> [EventRecord]
    /// Every metric stored for `day`, ordered (name, variant, window, computed_on) — the day summary's order.
    func metrics(on day: LocalDay) async throws -> [Metric]
    func metrics(named name: String, from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)]
    func series(on day: LocalDay) async throws -> [Series]
    func profile() async throws -> Profile?
    /// P9745: the profile every model reads: the Me profile with its empty fields filled from the PC's profile the phone
    /// last fetched (`EffectiveProfile.merged`). Pipelines call this, never `profile()` (ProfileInputsGuardTests).
    /// Default = `profile()` for sources that have no PC snapshot (tests).
    func effectiveProfile() async throws -> Profile?
    /// Mo's keep / drop marks (APP-117), every (group, variant) with its current mark. WP-23 maps MGStore's
    /// `groupMarks()` into this one-to-one (raw values read / keep / drop).
    func memberMarks() async throws -> [MemberMark]
    /// Imported history of one name (`ImportedHistory`, rows the pipelines otherwise never read), for the few inputs
    /// that may use it as a reference: ALG-040's step calibration. Wave 2, 2026-10-11; default: none.
    func importedMetrics(named name: String, from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)]
    /// Raw motion (wave W8, 2026-10-11): defaults below return none.
    func motionSeconds(from: Int64, to: Int64, strapId: StrapID?) async throws -> [MotionSecond]
    func motionSummaries(from: Int64, to: Int64, strapId: StrapID?) async throws -> [MotionAccelSummary]
}

extension PipelineSource {
    public func effectiveProfile() async throws -> Profile? { try await profile() }
    public func importedMetrics(named name: String, from: LocalDay,
                                to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] { [] }
    /// Raw-motion seconds (R21) with strap ts in [from, to]: the day's ALG-113 ENMO and ALG-114 asymmetry. Wave W8,
    /// 2026-10-11; default: none (MGStore `motionSeconds` in the app's adapter).
    public func motionSeconds(from: Int64, to: Int64, strapId: StrapID?) async throws -> [MotionSecond] { [] }
    /// Their per-second accelerometer summaries (no sample decoding): the week of minute ENMO CosinorAge reads. Wave W8;
    /// default: none (MGStore `motionSummaries`).
    public func motionSummaries(from: Int64, to: Int64, strapId: StrapID?) async throws -> [MotionAccelSummary] { [] }
}

/// Wave 4 (2026-10-11): the optical streams (MGStore `ppgBlocks` / `r20Records`, same signatures). Separate so a source
/// without them (tests, older fakes) still conforms: the default reads nothing, and every optical value is blank with
/// its reason.
public protocol OpticalSource: Sendable {
    func ppgBlocks(from: Int64, to: Int64, strapId: StrapID?) async throws -> [PPGBlock]
    func r20Records(from: Int64, to: Int64, strapId: StrapID?) async throws -> [R20Record]
}

/// Writes of one pipeline run (MGStore marks the day dirty; unchanged metrics are not rewritten).
public protocol PipelineSink: Sendable {
    @discardableResult func upsertMetrics(_ metrics: [Metric], day: LocalDay) async throws -> Int
    @discardableResult func upsertSeries(_ series: [Series], day: LocalDay) async throws -> Int
    /// Detected events a pipeline writes (ALG-023 breathing_event, wave 1, 2026-10-11): MGStore's own `upsertEvent`
    /// (same id + same content = no change; changed content = revision + 1), so a re-run never duplicates an event.
    @discardableResult func upsertEvent(_ event: EventRecord) async throws -> EventRecord
}

/// One of Mo's marks on a comparison-group member (APP-117). `drop` hides the member; nothing is ever deleted.
public struct MemberMark: Sendable, Hashable {
    public enum Value: String, Sendable, Codable, CaseIterable {
        case read = "read"
        case keep = "keep"
        case drop = "drop"
    }

    public var groupId: String
    public var variant: String
    public var mark: Value
    public var at: Date

    public init(groupId: String, variant: String, mark: Value, at: Date) {
        self.groupId = groupId
        self.variant = variant
        self.mark = mark
        self.at = at
    }
}

/// Settings the store does not hold as metrics (WP-23 passes them from the settings / kv store).
public struct PipelineSettings: Sendable, Equatable {
    /// The phone's time zone: local days (D13), the 18:00 night span, hour-of-day slots.
    public var timeZone: TimeZone
    /// "Must be up by" per weekday, "HH:MM" local (Settings; blank = a free morning, UX-SPEC 15 default 3).
    public var mustBeUpBy: [MedSchedule.Weekday: String]
    /// Settings' sleep-need override in minutes (`SettingEdit.needOverride(minutes:)`), nil = learn it (ALG-115).
    public var needOverrideMin: Double?
    /// Only this strap's streams; nil = every strap (MGStore).
    public var strapId: StrapID?
    /// Medication / supplement schedules (contract `schedule`) for ALG-069 adherence; empty = nothing scheduled.
    public var medSchedules: [MedSchedule]
    /// T32: the daytime spans (absolute times, `DaytimeWindow.Resolved.spans` of the days being computed) the daytime
    /// stress (ALG-123:daytime) may score; nil = every waking window.
    public var daytimeSpans: [DateInterval]?
    /// D-9746-R2a (Mo, Oct 14): the strap's sleep / wake flag is the primary for asleep / awake and the night's totals,
    /// ALG-151 stages inside strap-asleep epochs (base tier estimate). False = the ALG-151 hypnogram is stored but ALG-120 alone, as the Python mirror and the
    /// goldens compute it. The app sets true.
    public var strapPrimary: Bool
    /// P200 (Mo, Oct 15): the HR cleaning method resting HR, strain, calories and ALG-120 HR rules read. `.raw` = the
    /// previous method (each algorithm own 0 < bpm <= 250 check); the PC / primary map (T9809) can pick either.
    public var hrCleaning: HRClean.Method
    /// R9m (D-ALG-TIERS): which R20 blocks are red and IR for the enhanced SpO₂ (ALG-022:night). The app fills it from the
    /// PC's LED experiment; the default is OpenStrap's unproven claim, said in the metric's note.
    public var spo2Blocks: SpO2Blocks
    /// D-SLEEP-LOW-5: what decides where the strap night starts and ends. `.strapFlag` = the method until Nov 5 2026 (the
    /// default, as the goldens compute it); `.motionWindow` = the ALG-030 motion rest window with the strap flag vouching.
    public var sleepStrapMethod: SleepStrapFlag.NightMethod

    /// Red / IR block numbers and where they come from (shown in the metric's note).
    public struct SpO2Blocks: Sendable, Equatable {
        public var red: Int
        public var ir: Int
        public var basis: String

        public init(red: Int, ir: Int, basis: String) {
            self.red = red
            self.ir = ir
            self.basis = basis
        }

        public static let assumed = SpO2Blocks(
            red: LEDIdentity.red, ir: LEDIdentity.ir,
            basis: "blocks \(LEDIdentity.red) (red) / \(LEDIdentity.ir) (IR) assumed from OpenStrap's unproven claim — not confirmed (pc.led-identity)")
    }

    /// T9973: extra product names the user logs the ALG-143 compound under (read at run time from the git-ignored local
    /// preset file; the code itself knows only the generic compound name). Empty = the generic name only.
    public var lisdexAliases: [String]

    public init(timeZone: TimeZone, mustBeUpBy: [MedSchedule.Weekday: String] = [:], needOverrideMin: Double? = nil,
                strapId: StrapID? = nil, medSchedules: [MedSchedule] = [], daytimeSpans: [DateInterval]? = nil,
                strapPrimary: Bool = false, hrCleaning: HRClean.Method = .raw, lisdexAliases: [String] = [],
                spo2Blocks: SpO2Blocks = .assumed, sleepStrapMethod: SleepStrapFlag.NightMethod = .strapFlag) {
        self.sleepStrapMethod = sleepStrapMethod
        self.spo2Blocks = spo2Blocks
        self.timeZone = timeZone
        self.lisdexAliases = lisdexAliases
        self.hrCleaning = hrCleaning
        self.mustBeUpBy = mustBeUpBy
        self.needOverrideMin = needOverrideMin
        self.strapId = strapId
        self.medSchedules = medSchedules
        self.daytimeSpans = daytimeSpans
        self.strapPrimary = strapPrimary
    }
}
