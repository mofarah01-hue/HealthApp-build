import CryptoKit
import Foundation
import MGDomain

// The Apple Health mirror (ARCHITECTURE.md 4.10 "Mirror", D12; PLAN §3.1): OFF by default, measured or directly derived
// values only, every sample labelled as coming from the device "WHOOP MG".
//
// Never mirrored (D12, APP-111 "measured values only", PLAN §3.1 "never mirror research or estimate values", BRIEF "raw
// counts are not units"): breathing rate, the SpO2 byte / any SpO2, BP estimates, skin temperature, sleep stages,
// recovery / strain scores, anything with tier estimate / relative / research. `MirrorMetric` is a closed list of six,
// so such a sample cannot even be constructed; `MirrorPolicy.check` and the HealthKit layer's share-type set repeat the
// rule so a later edit has to break three places.

/// The six things the mirror may write. Raw values are Apple's type identifiers.
public enum MirrorMetric: String, CaseIterable, Sendable {
    case heartRate = "HKQuantityTypeIdentifierHeartRate"
    case restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
    case hrvSDNN = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    case dietaryCaffeine = "HKQuantityTypeIdentifierDietaryCaffeine"
    case workout = "HKWorkoutTypeIdentifier"
    /// Asleep, no stages: `HKCategoryValueSleepAnalysis.asleepUnspecified`.
    case sleepAsleep = "HKCategoryTypeIdentifierSleepAnalysis"

    public var hkIdentifier: String { rawValue }

    /// The `<metric>` part of `HKMetadataKeyExternalUUID = "mgapp:<metric>:<day or ts>"`.
    public var keyName: String {
        switch self {
        case .heartRate: return "hr"
        case .restingHeartRate: return "rhr"
        case .hrvSDNN: return "hrv_sdnn"
        case .dietaryCaffeine: return "caffeine"
        case .workout: return "workout"
        case .sleepAsleep: return "sleep"
        }
    }

    /// HealthKit unit string for quantity metrics.
    public var hkUnit: String? {
        switch self {
        case .heartRate, .restingHeartRate: return "count/min"
        case .hrvSDNN: return "ms"
        case .dietaryCaffeine: return "mg"
        case .workout, .sleepAsleep: return nil
        }
    }
}

/// The HKDevice every mirrored sample carries (ARCHITECTURE.md 4.10: `HKDevice(name: "WHOOP MG", manufacturer: "WHOOP",
/// model: "MG", hardwareVersion: nil, firmwareVersion: <fw>, softwareVersion: <app>, localIdentifier: nil,
/// udiDeviceIdentifier: nil)`; noop writes no HKDevice, we do).
public struct MirrorDevice: Hashable, Sendable {
    public static let defaultName = "WHOOP MG"
    public static let defaultManufacturer = "WHOOP"
    public static let defaultModel = "MG"

    public var name: String
    public var manufacturer: String
    public var model: String
    public var hardwareVersion: String?
    public var firmwareVersion: String?
    public var softwareVersion: String?
    public var localIdentifier: String?
    public var udiDeviceIdentifier: String?

    /// `firmwareVersion` is the strap's (from the strap table), `softwareVersion` this app's.
    public init(firmwareVersion: String? = nil, softwareVersion: String? = nil) {
        name = MirrorDevice.defaultName
        manufacturer = MirrorDevice.defaultManufacturer
        model = MirrorDevice.defaultModel
        hardwareVersion = nil
        self.firmwareVersion = firmwareVersion
        self.softwareVersion = softwareVersion
        localIdentifier = nil
        udiDeviceIdentifier = nil
    }
}

/// One sample the mirror would write.
public struct MirrorSample: Hashable, Sendable {
    public enum Payload: Hashable, Sendable {
        case quantity(value: Double, unit: String)
        /// A category value (`HKCategoryValueSleepAnalysis` raw value).
        case category(value: Int)
        case workout(activity: String, energyKcal: Double?, distanceMeters: Double?)
    }

    public var metric: MirrorMetric
    public var start: Date
    public var end: Date
    public var payload: Payload
    /// `HKMetadataKeyExternalUUID`: `mgapp:<metric>:<day or ts>`. Writing the same key again replaces the sample
    /// (the writer deletes this app's earlier sample with the key first, as noop does).
    public var externalKey: String
    public var device: MirrorDevice
    /// The metric's tier: only measured or directly derived values pass `MirrorPolicy`.
    public var tier: Tier
    public var method: String?

    public init(metric: MirrorMetric, start: Date, end: Date, payload: Payload, externalKey: String,
                device: MirrorDevice, tier: Tier, method: String? = nil) {
        self.metric = metric
        self.start = start
        self.end = end
        self.payload = payload
        self.externalKey = externalKey
        self.device = device
        self.tier = tier
        self.method = method
    }

    /// Changes whenever anything the sample says changes; the ledger writes a key again only when this differs.
    public var digest: String {
        var text = "\(metric.rawValue)|\(Int64(start.timeIntervalSince1970))|\(Int64(end.timeIntervalSince1970))|"
        switch payload {
        case .quantity(let v, let u): text += "q|\(String(format: "%.4f", v))|\(u)"
        case .category(let v): text += "c|\(v)"
        case .workout(let a, let e, let d): text += "w|\(a)|\(e.map { String(format: "%.2f", $0) } ?? "-")|\(d.map { String(format: "%.1f", $0) } ?? "-")"
        }
        text += "|\(device.firmwareVersion ?? "-")"
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Metadata written with the sample besides the external id.
    public var metadata: [String: String] {
        var m = [HealthMetadataKey.externalUUID: externalKey, "mg_tier": tier.rawValue, "mg_origin": "WHOOP MG strap via MG app"]
        if let method { m["mg_method"] = method }
        return m
    }
}

public enum MirrorError: Error, Equatable, CustomStringConvertible {
    case forbiddenType(String)
    case tierNotAllowed(String)
    case unlabelled(String)
    case badValue(String)
    case notAvailable(HealthAuthState)

    public var description: String {
        switch self {
        case .forbiddenType(let s), .tierNotAllowed(let s), .unlabelled(let s), .badValue(let s): return s
        case .notAvailable(let s): return s.message ?? "Apple Health is not available (\(s.rawValue))"
        }
    }
}

public enum MirrorPolicy {
    /// Written never, whatever a caller asks (ARCHITECTURE.md D12): breathing rate and SpO2.
    public static let neverMirrored: Set<String> = [
        "HKQuantityTypeIdentifierRespiratoryRate",
        "HKQuantityTypeIdentifierOxygenSaturation",
    ]

    /// Tiers that count as measured or directly derived (contract `tier`): `verified` (own reference device), `strap`
    /// (the strap's own value), `high` (a standard method on measured data). `estimate`, `relative` and `research` are
    /// never written (PLAN §3.1).
    public static let allowedTiers: Set<Tier> = [.verified, .strap, .high]

    /// Every sample passes through this before it reaches the writer. Throws the reason it is refused.
    public static func check(_ s: MirrorSample) throws {
        if neverMirrored.contains(s.metric.rawValue) {
            throw MirrorError.forbiddenType("\(s.metric.rawValue) is never mirrored to Apple Health")
        }
        guard allowedTiers.contains(s.tier) else {
            throw MirrorError.tierNotAllowed("\(s.externalKey): tier \(s.tier.rawValue) is an estimate, not a measured value")
        }
        guard s.externalKey.hasPrefix(OwnSourceRule.externalUUIDPrefix) else {
            throw MirrorError.unlabelled("\(s.externalKey): the external id must start with \(OwnSourceRule.externalUUIDPrefix)")
        }
        guard s.device.name == MirrorDevice.defaultName, s.device.manufacturer == MirrorDevice.defaultManufacturer,
              s.device.model == MirrorDevice.defaultModel
        else { throw MirrorError.unlabelled("\(s.externalKey): the sample is not labelled as device WHOOP MG") }
        guard s.end >= s.start else { throw MirrorError.badValue("\(s.externalKey): end before start") }
        switch s.payload {
        case .quantity(let v, let unit):
            guard v.isFinite, v > 0 else { throw MirrorError.badValue("\(s.externalKey): value \(v) is not a positive number") }
            guard unit == s.metric.hkUnit else { throw MirrorError.badValue("\(s.externalKey): unit \(unit) is not \(s.metric.hkUnit ?? "none")") }
        case .category(let v):
            guard s.metric == .sleepAsleep, v == SleepAnalysisValue.asleepUnspecified else {
                throw MirrorError.badValue("\(s.externalKey): only asleep (no stages) is written")
            }
        case .workout:
            guard s.metric == .workout, s.end > s.start else { throw MirrorError.badValue("\(s.externalKey): a workout needs a duration") }
        }
    }
}

// MARK: - What the mirror reads from the app's own store

public struct HeartRateReading: Sendable, Equatable {
    public var at: Date
    public var bpm: Double

    public init(at: Date, bpm: Double) {
        self.at = at
        self.bpm = bpm
    }
}

/// A daily metric as the store holds it (the adapter picks the variant to mirror).
public struct MirrorDailyValue: Sendable, Equatable {
    public var value: Double
    public var at: Date
    public var tier: Tier
    public var method: String?

    public init(value: Double, at: Date, tier: Tier, method: String? = nil) {
        self.value = value
        self.at = at
        self.tier = tier
        self.method = method
    }
}

public struct MirrorSleepWindow: Sendable, Equatable {
    public var onset: Date
    public var wake: Date
    public var tier: Tier
    public var method: String?

    public init(onset: Date, wake: Date, tier: Tier, method: String? = nil) {
        self.onset = onset
        self.wake = wake
        self.tier = tier
        self.method = method
    }
}

/// The app's data the mirror draws from. WP-23 implements it over MGStore (`hrSamples`, `metrics(on:)`, `events(from:to:types:)`).
/// `day` is the wake day (D13). A method returns nil when the value does not exist; the mirror then writes nothing (R6).
public protocol HealthMirrorSource: Sendable {
    func heartRate(from: Date, to: Date) async throws -> [HeartRateReading]
    /// `rhr` of the night ending on `day`.
    func restingHeartRate(day: LocalDay) async throws -> MirrorDailyValue?
    /// `hrv_sdnn` of the night ending on `day`.
    func hrvSDNN(day: LocalDay) async throws -> MirrorDailyValue?
    /// Sleep onset and wake of the night ending on `day`.
    func sleepWindow(day: LocalDay) async throws -> MirrorSleepWindow?
    /// Events with `at` in [from, to], of the given types, INCLUDING soft-removed ones (so a removal can be retracted).
    func events(from: Date, to: Date, types: [EventType]) async throws -> [EventRecord]
}

// MARK: - Planning (pure)

public struct MirrorPlan: Sendable {
    public var samples: [MirrorSample] = []
    /// Keys of samples whose source event was removed: delete them from Health if they were written.
    public var removedKeys: [(metric: MirrorMetric, key: String)] = []

    public init() {}
}

public struct MirrorPlanner: Sendable {
    public var device: MirrorDevice

    public init(device: MirrorDevice) {
        self.device = device
    }

    /// 1-minute buckets (ARCHITECTURE.md 4.10): the mean bpm of the readings in each whole minute that has ended by
    /// `now`. Readings outside 20...250 bpm (no signal reads as 0) are ignored; a minute with none left gets no sample.
    public func heartRateBuckets(_ readings: [HeartRateReading], completeBefore now: Date) -> [MirrorSample] {
        var buckets: [Int64: [Double]] = [:]
        for r in readings where r.bpm.isFinite && r.bpm >= 20 && r.bpm <= 250 {
            buckets[Int64((r.at.timeIntervalSince1970 / 60).rounded(.down)), default: []].append(r.bpm)
        }
        let nowUnix = now.timeIntervalSince1970
        return buckets.keys.sorted().compactMap { (minute: Int64) -> MirrorSample? in
            let start = Double(minute) * 60
            guard start + 60 <= nowUnix, let values = buckets[minute], !values.isEmpty else { return nil }
            let mean = values.reduce(0, +) / Double(values.count)
            return MirrorSample(metric: .heartRate, start: Date(timeIntervalSince1970: start),
                                end: Date(timeIntervalSince1970: start + 60),
                                payload: .quantity(value: (mean * 100).rounded() / 100, unit: "count/min"),
                                externalKey: "mgapp:hr:\(minute * 60)", device: device, tier: .strap, method: "strap HR, 1 min mean")
        }
    }

    public func restingHeartRate(_ v: MirrorDailyValue, day: LocalDay) -> MirrorSample? {
        daily(.restingHeartRate, v, day: day)
    }

    public func hrvSDNN(_ v: MirrorDailyValue, day: LocalDay) -> MirrorSample? {
        daily(.hrvSDNN, v, day: day)
    }

    private func daily(_ metric: MirrorMetric, _ v: MirrorDailyValue, day: LocalDay) -> MirrorSample? {
        guard v.value.isFinite, v.value > 0, let unit = metric.hkUnit else { return nil }
        return MirrorSample(metric: metric, start: v.at, end: v.at, payload: .quantity(value: v.value, unit: unit),
                            externalKey: "mgapp:\(metric.keyName):\(day.iso)", device: device, tier: v.tier, method: v.method)
    }

    /// Logged caffeine (`substance` events of kind caffeine with an amount), one sample per event. Without an amount
    /// nothing is written (no invented dose). A removed event is returned as a key to retract.
    public func caffeine(_ events: [EventRecord]) -> MirrorPlan {
        var plan = MirrorPlan()
        for e in events {
            guard case .substance(let f) = e.payload, f.kind == .caffeine else { continue }
            let key = "mgapp:caffeine:\(e.id.uuidString.lowercased())"
            if e.removed { plan.removedKeys.append((.dietaryCaffeine, key)); continue }
            guard let mg = f.caffeineMg, mg.isFinite, mg > 0 else { continue }
            // A logged amount is Mo's own entry: the highest tier we have for it is "verified" (he typed what he drank).
            plan.samples.append(MirrorSample(metric: .dietaryCaffeine, start: e.at, end: e.at,
                                             payload: .quantity(value: mg, unit: "mg"), externalKey: key, device: device,
                                             tier: .verified, method: "logged by user"))
        }
        return plan
    }

    /// Confirmed workouts only: `activity_type_user` is set (Mo confirmed or typed the activity). A detected workout he
    /// has not confirmed is a guess and stays out.
    public func workouts(_ events: [EventRecord]) -> MirrorPlan {
        var plan = MirrorPlan()
        for e in events {
            guard case .workout(let f) = e.payload else { continue }
            let key = "mgapp:workout:\(e.id.uuidString.lowercased())"
            if e.removed { plan.removedKeys.append((.workout, key)); continue }
            guard let activity = f.activityTypeUser?.trimmingCharacters(in: .whitespacesAndNewlines), !activity.isEmpty,
                  f.end > e.at
            else { continue }
            plan.samples.append(MirrorSample(metric: .workout, start: e.at, end: f.end,
                                             payload: .workout(activity: activity, energyKcal: nil, distanceMeters: nil),
                                             externalKey: key, device: device, tier: .verified, method: "confirmed by user"))
        }
        return plan
    }

    /// One asleep sample from onset to wake (no stages, D12). Awake periods inside the night are not carved out: the
    /// staging methods are estimates, which the mirror does not write.
    public func sleep(_ w: MirrorSleepWindow, day: LocalDay) -> MirrorSample? {
        let hours = w.wake.timeIntervalSince(w.onset) / 3600
        guard hours > 0, hours <= 20 else { return nil }
        return MirrorSample(metric: .sleepAsleep, start: w.onset, end: w.wake,
                            payload: .category(value: SleepAnalysisValue.asleepUnspecified),
                            externalKey: "mgapp:sleep:\(day.iso)", device: device, tier: w.tier, method: w.method)
    }
}

// MARK: - Settings, state, writer

/// Mo's switch (Settings). The mirror is off until it says otherwise.
public protocol MirrorSettingsProviding: Sendable {
    var mirrorEnabled: Bool { get async }
}

public actor InMemoryMirrorSettings: MirrorSettingsProviding {
    private var enabled: Bool

    /// Off by default (D12).
    public init(enabled: Bool = false) { self.enabled = enabled }

    public var mirrorEnabled: Bool { get async { enabled } }

    public func setEnabled(_ value: Bool) { enabled = value }
}

/// Where the mirror remembers what it wrote (key -> digest). The app passes closures over MGStore's key-value table.
public protocol MirrorStateStore: Sendable {
    func load() async -> Data?
    func save(_ data: Data) async throws
}

public actor InMemoryMirrorStateStore: MirrorStateStore {
    private var data: Data?

    public init() {}

    public func load() async -> Data? { data }

    public func save(_ data: Data) async throws { self.data = data }
}

public struct ClosureMirrorStateStore: MirrorStateStore {
    private let read: @Sendable () async -> Data?
    private let write: @Sendable (Data) async throws -> Void

    public init(read: @escaping @Sendable () async -> Data?, write: @escaping @Sendable (Data) async throws -> Void) {
        self.read = read
        self.write = write
    }

    public func load() async -> Data? { await read() }
    public func save(_ data: Data) async throws { try await write(data) }
}

public struct MirrorWriteResult: Sendable, Equatable {
    /// External keys saved to Health.
    public var writtenKeys: [String]
    /// Metrics the user has not allowed this app to write; their samples are not recorded as written.
    public var skippedMetrics: [MirrorMetric]

    public init(writtenKeys: [String], skippedMetrics: [MirrorMetric] = []) {
        self.writtenKeys = writtenKeys
        self.skippedMetrics = skippedMetrics
    }
}

public protocol HealthMirrorWriter: Sendable {
    var authState: HealthAuthState { get async }
    /// The write-permission sheet for the six `MirrorMetric` types only.
    func requestMirrorAuthorization() async throws
    /// For each sample: delete this app's earlier sample with the same external key, then save the new one.
    func write(_ samples: [MirrorSample]) async throws -> MirrorWriteResult
    func delete(keys: [String], metric: MirrorMetric) async throws
}

public struct MirrorReport: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// The switch is off: nothing was read, asked or written.
        case off
        /// Apple Health cannot be used in this build / on this device.
        case blocked(HealthAuthState)
        case done
    }

    public var status: Status
    public var message: String?
    public var written = 0
    public var unchanged = 0
    public var retracted = 0
    /// Samples refused by `MirrorPolicy`, one line each.
    public var rejected: [String] = []
    public var skippedMetrics: [MirrorMetric] = []
    public var errors: [String] = []

    public init(status: Status, message: String? = nil) {
        self.status = status
        self.message = message
    }
}

private struct MirrorLedger: Codable {
    var entries: [String: String] = [:]
}

/// Runs the mirror: plan -> policy check -> skip what is already written unchanged -> write -> retract what was removed.
public actor HealthMirror {
    private let source: any HealthMirrorSource
    private let writer: any HealthMirrorWriter
    private let settings: any MirrorSettingsProviding
    private let state: any MirrorStateStore
    private let device: @Sendable () async -> MirrorDevice
    private let clock: any MGDomain.Clock
    private let calendar: Calendar

    public init(source: any HealthMirrorSource, writer: any HealthMirrorWriter,
                settings: any MirrorSettingsProviding = InMemoryMirrorSettings(),
                state: any MirrorStateStore = InMemoryMirrorStateStore(),
                device: @escaping @Sendable () async -> MirrorDevice = { MirrorDevice() },
                clock: any MGDomain.Clock = SystemClock(), calendar: Calendar = .current) {
        self.source = source
        self.writer = writer
        self.settings = settings
        self.state = state
        self.device = device
        self.clock = clock
        self.calendar = calendar
    }

    /// Asks for write permission for the six mirrored types. Call it when Mo switches the mirror on, not before.
    public func requestAccess() async throws {
        let s = await writer.authState
        guard s.isUsable else { throw MirrorError.notAvailable(s) }
        try await writer.requestMirrorAuthorization()
    }

    public func run(daysBack: Int = 3) async -> MirrorReport {
        guard await settings.mirrorEnabled else { return MirrorReport(status: .off) }
        let auth = await writer.authState
        guard auth.isUsable else { return MirrorReport(status: .blocked(auth), message: auth.message) }

        var report = MirrorReport(status: .done)
        let now = clock.now
        let planner = MirrorPlanner(device: await device())
        let today = LocalDay(date: now, calendar: calendar)
        let firstDay = today.adding(days: -max(0, daysBack))
        let from = firstDay.start(in: calendar.timeZone)

        var planned: [MirrorSample] = []
        var removed: [(metric: MirrorMetric, key: String)] = []

        do {
            planned += planner.heartRateBuckets(try await source.heartRate(from: from, to: now), completeBefore: now)
        } catch { report.errors.append("heart rate: \(error)") }

        var day = firstDay
        while day <= today {
            do {
                if let v = try await source.restingHeartRate(day: day), let s = planner.restingHeartRate(v, day: day) { planned.append(s) }
                if let v = try await source.hrvSDNN(day: day), let s = planner.hrvSDNN(v, day: day) { planned.append(s) }
                if let w = try await source.sleepWindow(day: day), let s = planner.sleep(w, day: day) { planned.append(s) }
            } catch { report.errors.append("\(day.iso): \(error)") }
            day = day.adding(days: 1)
        }

        do {
            let events = try await source.events(from: from, to: now, types: [.substance, .workout])
            for plan in [planner.caffeine(events), planner.workouts(events)] {
                planned += plan.samples
                removed += plan.removedKeys
            }
        } catch { report.errors.append("events: \(error)") }

        // Policy: nothing reaches the writer unless it passes.
        var allowed: [MirrorSample] = []
        for s in planned {
            do { try MirrorPolicy.check(s); allowed.append(s) } catch { report.rejected.append("\(error)") }
        }

        var ledger = MirrorLedger()
        if let data = await state.load(), let decoded = try? JSONDecoder().decode(MirrorLedger.self, from: data) { ledger = decoded }

        let changed = allowed.filter { ledger.entries[$0.externalKey] != $0.digest }
        report.unchanged = allowed.count - changed.count
        if !changed.isEmpty {
            do {
                let result = try await writer.write(changed)
                let digests = Dictionary(changed.map { ($0.externalKey, $0.digest) }, uniquingKeysWith: { _, last in last })
                for key in result.writtenKeys { if let d = digests[key] { ledger.entries[key] = d } }
                report.written = result.writtenKeys.count
                report.skippedMetrics = result.skippedMetrics
            } catch { report.errors.append("write: \(error)") }
        }

        for item in removed where ledger.entries[item.key] != nil {
            do {
                try await writer.delete(keys: [item.key], metric: item.metric)
                ledger.entries[item.key] = nil
                report.retracted += 1
            } catch { report.errors.append("delete \(item.key): \(error)") }
        }

        if let data = try? JSONEncoder().encode(ledger) {
            do { try await state.save(data) } catch { report.errors.append("ledger: \(error)") }
        }
        return report
    }
}
