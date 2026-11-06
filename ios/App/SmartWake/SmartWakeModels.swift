import Foundation
import MGContext
import MGDomain
import MGSignal

// Smart wake, app side (WP-11; ARCHITECTURE 4.11, UX-SPEC 8.1). The decision logic is MGSignal's (LiveStager,
// ALG035, SmartWakeSession — golden-tested); this folder schedules, watches, rings and remembers.

/// What the controller needs to plan tonight. WP-23 builds it from Settings and the context engine.
public struct SmartWakeRequest: Equatable, Sendable {
    /// The Tonight toggle.
    public var enabled: Bool
    /// L: the "must be up by" time for the COMING morning (WP-06: the caller picks the weekday); nil = blank setting
    /// → no wake plan (BRIEF default 3).
    public var mustBeUpBy: Date?
    /// 10–45, default 30 (clamped by ALG035.plan).
    public var windowMinutes: Int?
    /// B (PhaseAnchors.bedtime).
    public var bedtime: Date
    /// ALG-115 predicted onset, when known.
    public var asleepAround: Date?
    /// ALG-115 tonight's need (minutes), when known (needs 7 free nights). Drives the short-night narrowing.
    public var needMinutes: Double?
    /// T9841: the smart-wake mode (window / time gate / open / need met), its gate time and minimum rest share.
    public var options: SmartWakeOptions

    public init(enabled: Bool, mustBeUpBy: Date?, windowMinutes: Int?, bedtime: Date, asleepAround: Date?,
                needMinutes: Double?, options: SmartWakeOptions = .standard) {
        self.options = options
        self.enabled = enabled
        self.mustBeUpBy = mustBeUpBy
        self.windowMinutes = windowMinutes
        self.bedtime = bedtime
        self.asleepAround = asleepAround
        self.needMinutes = needMinutes
    }
}

/// Where tonight's smart wake is.
public enum SmartWakeStatus: Equatable, Sendable {
    /// No plan, and why ("No 'must be up by' for tomorrow…", "Smart wake is off").
    case off(reason: String)
    /// Backstop scheduled; watching starts at `watchFrom`.
    case armed(plan: SmartWakePlan, watchFrom: Date)
    /// Realtime toggles on, the live stager running.
    case watching(plan: SmartWakePlan)
    case ringing(at: Date, smart: Bool)
    case done(SmartWakeNightResult)
}

/// One night's result, kept for the morning row, the check-in and the G-INERTIA label (stage at wake).
public struct SmartWakeNightResult: Codable, Equatable, Sendable {
    /// "L unix seconds" — one result per wake time.
    public var nightId: String
    public var plan: SmartWakePlan
    public var outcome: SmartWakeOutcome
    public var cause: SmartWakeWords.Cause
    public var batteryAtBed: Double?
    public var batteryAtWake: Double?
    /// "alarmKit" or "notification" (MGContext SmartWakeBlockState.Ringer raw value).
    public var ringer: String
    public var paramsVersion: String
    public var recordedAt: Date

    public init(nightId: String, plan: SmartWakePlan, outcome: SmartWakeOutcome, cause: SmartWakeWords.Cause,
                batteryAtBed: Double?, batteryAtWake: Double?, ringer: String, paramsVersion: String, recordedAt: Date) {
        self.nightId = nightId
        self.plan = plan
        self.outcome = outcome
        self.cause = cause
        self.batteryAtBed = batteryAtBed
        self.batteryAtWake = batteryAtWake
        self.ringer = ringer
        self.paramsVersion = paramsVersion
        self.recordedAt = recordedAt
    }

    /// The morning words (Now row title/detail, heart-only note, battery line, first check-in question).
    public func words(timeZone: TimeZone = .current) -> SmartWakeWords {
        let at = Date(timeIntervalSince1970: TimeInterval(outcome.at ?? plan.windowEnd))
        return SmartWakeWords.make(outcome, utcOffsetSeconds: timeZone.secondsFromGMT(for: at), cause: cause,
                                   batteryAtBed: batteryAtBed, batteryAtWake: batteryAtWake)
    }

    /// Receipt method for the Now row ("research" tier, ALGORITHM ids, params version).
    public var method: String { "ALG-031 live + ALG-035 \(paramsVersion)" }
}

/// What survives an app kill between bedtime and the morning (the backstop is the system's, not ours).
public struct SmartWakeArmedState: Codable, Equatable, Sendable {
    public var nightId: String
    public var plan: SmartWakePlan
    public var request: SmartWakeArmedRequest
    public var backstopIds: [String]
    public var ringIds: [String]
    public var ringer: String
    public var batteryAtBed: Double?
    /// The latest provisional outcome (backstop as of the last closed epoch, or the smart ring once it rang). If the
    /// app is killed overnight, the morning result is this.
    public var provisional: SmartWakeOutcome?
    public var disconnectedAt: Date?
    public var rang: Bool

    public init(nightId: String, plan: SmartWakePlan, request: SmartWakeArmedRequest, backstopIds: [String],
                ringIds: [String], ringer: String, batteryAtBed: Double?, provisional: SmartWakeOutcome?,
                disconnectedAt: Date?, rang: Bool) {
        self.nightId = nightId
        self.plan = plan
        self.request = request
        self.backstopIds = backstopIds
        self.ringIds = ringIds
        self.ringer = ringer
        self.batteryAtBed = batteryAtBed
        self.provisional = provisional
        self.disconnectedAt = disconnectedAt
        self.rang = rang
    }
}

/// The settings a plan was made from; a change re-plans the night.
public struct SmartWakeArmedRequest: Codable, Equatable, Sendable {
    public var mustBeUpBy: Int64
    public var windowMinutes: Int?
    public var needMinutes: Double?
    /// T9841: nil in a night armed by an earlier build = the standard window.
    public var options: SmartWakeOptions?

    public init(mustBeUpBy: Int64, windowMinutes: Int?, needMinutes: Double?, options: SmartWakeOptions? = nil) {
        self.mustBeUpBy = mustBeUpBy
        self.windowMinutes = windowMinutes
        self.needMinutes = needMinutes
        self.options = options
    }
}

/// Tunables of the controller (ours v0; Mo may change them).
public struct SmartWakeConfig: Sendable {
    /// Watching (realtime toggles 3 + 63 on, D8) starts this long before bedtime B, or at arming if later.
    public var watchLeadMinutes: Double
    /// Epochs close this many seconds after their end, so their last beats have arrived over BLE.
    public var closeGraceSeconds: Int64
    /// How often the controller re-checks while it is alive (beats also drive it, ~1 Hz).
    public var tickSeconds: Double
    /// Turn the realtime toggles off after the wake (the Live tab turns them on again when it opens).
    public var realtimeOffAfterWake: Bool
    /// Notification fallback: re-ring every minute this many extra times until Stop (one notification sound is short).
    public var notificationRepeats: Int
    /// AlarmKit "ring now" lead (ARCHITECTURE 4.11: now + 5 s).
    public var ringLeadSeconds: Double

    public init(watchLeadMinutes: Double = 30, closeGraceSeconds: Int64 = 5, tickSeconds: Double = 15,
                realtimeOffAfterWake: Bool = true, notificationRepeats: Int = 4, ringLeadSeconds: Double = 5) {
        self.watchLeadMinutes = watchLeadMinutes
        self.closeGraceSeconds = closeGraceSeconds
        self.tickSeconds = tickSeconds
        self.realtimeOffAfterWake = realtimeOffAfterWake
        self.notificationRepeats = notificationRepeats
        self.ringLeadSeconds = ringLeadSeconds
    }

    public static let standard = SmartWakeConfig()
}

/// Persistence for the armed night and the last result (the app's own container; nothing syncs from here —
/// WP-23 may also store the result as a contract event).
@MainActor
public protocol SmartWakeStore: AnyObject {
    func loadArmed() -> SmartWakeArmedState?
    func saveArmed(_ state: SmartWakeArmedState)
    func clearArmed()
    func loadResult() -> SmartWakeNightResult?
    func saveResult(_ result: SmartWakeNightResult)
}

/// UserDefaults-backed store (JSON). Small: one armed night + one result.
@MainActor
public final class SmartWakeDefaultsStore: SmartWakeStore {
    private let defaults: UserDefaults
    private let armedKey = "mg.smartwake.armed.v1"
    private let resultKey = "mg.smartwake.result.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadArmed() -> SmartWakeArmedState? { decode(armedKey) }
    public func saveArmed(_ state: SmartWakeArmedState) { encode(state, armedKey) }
    public func clearArmed() { defaults.removeObject(forKey: armedKey) }
    public func loadResult() -> SmartWakeNightResult? { decode(resultKey) }
    public func saveResult(_ result: SmartWakeNightResult) { encode(result, resultKey) }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
