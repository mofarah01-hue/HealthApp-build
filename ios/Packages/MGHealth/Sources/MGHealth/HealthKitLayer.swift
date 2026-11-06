// The only file that talks to HealthKit. Everything it decides lives in the platform-neutral files next to it; this layer
// converts. It is behind `#if canImport(HealthKit) && os(iOS)` (stricter than canImport alone: HealthKit imports on a Mac
// but several of the APIs used here, e.g. the ECG and workout-builder types, are not available there, and `swift test`
// on a Mac host must compile). WRITTEN, NOT COMPILED: the API calls follow noop:StrandiOS/Health/HealthKitBridge.swift,
// which builds, and Apple's documented signatures.
#if canImport(HealthKit) && os(iOS)
import Foundation
import HealthKit
import CoreLocation
import MGDomain

public enum HealthKitError: Error, CustomStringConvertible {
    case unsupportedType(String)
    case unreadableAnchor

    public var description: String {
        switch self {
        case .unsupportedType(let s): return "Apple Health has no type \(s) on this iOS version"
        case .unreadableAnchor: return "The stored Health anchor could not be read"
        }
    }
}

public enum HealthKitSupport {
    /// Does this build carry `com.apple.developer.healthkit`? A free-Apple-ID re-sign (AltStore, Sideloadly) strips it:
    /// `isHealthDataAvailable()` stays true but the permission sheet can never open (noop CHANGELOG #348).
    /// Same method as noop:StrandiOS/Health/HealthKitBridge.swift L1911: read the entitlements out of the embedded
    /// provisioning profile; no profile (App Store build) or an unparsable one counts as present.
    public static let hasEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8))
        else { return true }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return true }
        return entitlements["com.apple.developer.healthkit"] != nil
    }()

    /// Samples NOT written by this build: `NOT predicateForObjects(from: [HKSource.default()])`
    /// (noop:StrandiOS/Health/HealthKitBridge.swift L1431). `OwnSourceRule` repeats the test on what comes back.
    public static func notOwnSource() -> NSPredicate {
        NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()]))
    }

    /// This build's own samples with one of these external ids (the mirror's replace-write).
    public static func ownSource(withExternalKeys keys: [String]) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: keys),
        ])
    }

    public static func objectType(for type: HealthReadType) -> HKObjectType? {
        switch type.kind {
        case .quantity: return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: type.rawValue))
        case .category: return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: type.rawValue))
        case .correlation: return HKObjectType.correlationType(forIdentifier: .bloodPressure)
        case .workout: return HKObjectType.workoutType()
        case .ecg: return HKObjectType.electrocardiogramType()
        }
    }

    /// Health Records need BOTH the `health-records` entitlement in the provisioning profile and the usage-description key;
    /// asking without either raises an Objective-C exception, so no profile (or a profile without it) counts as absent.
    public static let hasClinicalAccess: Bool = {
        guard Bundle.main.object(forInfoDictionaryKey: "NSHealthClinicalHealthRecordsShareUsageDescription") != nil,
              let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound), options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let access = entitlements["com.apple.developer.healthkit.access"] as? [String]
        else { return false }
        return access.contains("health-records")
    }()

    /// Everything the app asks to read.
    public static var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        for t in HealthReadType.allCases where t.kind != .correlation {
            if let o = objectType(for: t) { s.insert(o) }
        }
        // HealthKit refuses authorization for a correlation type itself: ask for its two component types instead.
        for id in [HealthReadType.systolicIdentifier, HealthReadType.diastolicIdentifier] {
            if let q = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)) { s.insert(q) }
        }
        // T9739: one permission sheet for the old reader and the automatic PC read (every type of HealthAutoCatalogue).
        s.formUnion(HealthKitAutoProvider.readTypes)
        return s
    }

    public static func shareType(for metric: MirrorMetric) -> HKSampleType? {
        switch metric {
        case .heartRate, .restingHeartRate, .hrvSDNN, .dietaryCaffeine:
            return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: metric.hkIdentifier))
        case .sleepAsleep:
            return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: metric.hkIdentifier))
        case .workout:
            return HKObjectType.workoutType()
        }
    }

    /// The write-permission set: exactly the six `MirrorMetric` types. Respiratory rate and oxygen saturation are never
    /// in it (D12); the precondition makes an edit that adds them fail loudly in every build.
    public static var mirrorShareTypes: Set<HKSampleType> {
        precondition(MirrorMetric.allCases.allSatisfy { !MirrorPolicy.neverMirrored.contains($0.hkIdentifier) },
                     "MirrorMetric contains a type that is never mirrored")
        return Set(MirrorMetric.allCases.compactMap { shareType(for: $0) })
    }

    public static func device(_ d: MirrorDevice) -> HKDevice {
        HKDevice(name: d.name, manufacturer: d.manufacturer, model: d.model, hardwareVersion: d.hardwareVersion,
                 firmwareVersion: d.firmwareVersion, softwareVersion: d.softwareVersion,
                 localIdentifier: d.localIdentifier, udiDeviceIdentifier: d.udiDeviceIdentifier)
    }

    /// Our activity names (free text typed or confirmed by Mo) -> HealthKit; anything unknown is `.other`, never dropped.
    public static func activityType(for name: String) -> HKWorkoutActivityType {
        switch name.lowercased() {
        case let n where n.contains("run"): return .running
        case let n where n.contains("walk"): return .walking
        case let n where n.contains("hik"): return .hiking
        case let n where n.contains("cycl") || n.contains("bike"): return .cycling
        case let n where n.contains("swim"): return .swimming
        case let n where n.contains("row"): return .rowing
        case let n where n.contains("yoga"): return .yoga
        case let n where n.contains("strength") || n.contains("lift") || n.contains("weight"): return .traditionalStrengthTraining
        case let n where n.contains("hiit") || n.contains("interval"): return .highIntensityIntervalTraining
        default: return .other
        }
    }

    static func authState(read: Set<HKObjectType>, share: Set<HKSampleType>, store: HKHealthStore) async -> HealthAuthState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        guard hasEntitlement else { return .entitlementMissing }
        let status = try? await store.statusForAuthorizationRequest(toShare: share, read: read)
        return status == .shouldRequest ? .notRequested : .requested
    }
}

// MARK: - Reading

/// `HealthDataProvider` over `HKAnchoredObjectQuery`, one query per type, anchors archived with `NSKeyedArchiver`
/// (stored by `HealthReader` through `HealthSampleSink.setAnchor`, in MGStore's `kv`). Every query carries
/// `HealthKitSupport.notOwnSource()`.
public final class HealthKitProvider: HealthDataProvider, @unchecked Sendable {
    private let store: HKHealthStore
    private let gate = ObserverGate()

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public var authState: HealthAuthState {
        get async { await HealthKitSupport.authState(read: HealthKitSupport.readTypes, share: [], store: store) }
    }

    public func requestReadAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: HealthKitSupport.readTypes)
    }

    public func changes(for type: HealthReadType, anchor: Data?, since: Date) async throws -> HealthChangeBatch {
        guard let object = HealthKitSupport.objectType(for: type), let sampleType = object as? HKSampleType else {
            throw HealthKitError.unsupportedType(type.rawValue)
        }
        var queryAnchor: HKQueryAnchor?
        if let anchor {
            guard let a = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor) else {
                throw HealthKitError.unreadableAnchor
            }
            queryAnchor = a
        }
        // Only the first run is limited by date; later runs take every change since the anchor, however old the sample.
        var parts: [NSPredicate] = [HealthKitSupport.notOwnSource()]
        if queryAnchor == nil { parts.append(HKQuery.predicateForSamples(withStart: since, end: nil, options: [])) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts)

        let (samples, deleted, newAnchor) = try await anchored(sampleType, predicate: predicate, anchor: queryAnchor)
        var chosen = samples
        if type.granularity != .perSample, !samples.isEmpty {
            // Hourly summaries are recomputed from every sample of each touched hour, not just the new ones.
            let hour: TimeInterval = 3600
            let lo = (samples.map(\.startDate.timeIntervalSince1970).min()! / hour).rounded(.down) * hour
            let hi = ((samples.map(\.startDate.timeIntervalSince1970).max()! / hour).rounded(.down) + 1) * hour
            let span = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HealthKitSupport.notOwnSource(),
                HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: max(lo, hi - 14 * 86_400)),
                                            end: Date(timeIntervalSince1970: hi), options: .strictStartDate),
            ])
            chosen = try await fetch(sampleType, predicate: span)
        }
        let records = chosen.compactMap { record($0, as: type) }
        let archived = try newAnchor.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return HealthChangeBatch(records: records, deleted: deleted.map(\.uuid), newAnchor: archived)
    }

    private func anchored(_ type: HKSampleType, predicate: NSPredicate, anchor: HKQueryAnchor?) async throws
        -> ([HKSample], [HKDeletedObject], HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { cont in
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) {
                _, samples, deleted, newAnchor, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (samples ?? [], deleted ?? [], newAnchor)) }
            }
            store.execute(query)
        }
    }

    private func fetch(_ type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) {
                _, samples, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }

    // MARK: HKSample -> HealthSampleRecord

    private func record(_ s: HKSample, as type: HealthReadType) -> HealthSampleRecord? {
        let value: HealthValue
        switch type.kind {
        case .quantity:
            guard let q = s as? HKQuantitySample, let u = type.unit else { return nil }
            value = .quantity(q.quantity.doubleValue(for: HKUnit(from: u.hk)) * u.scale)
        case .category:
            guard let c = s as? HKCategorySample else { return nil }
            value = .category(code: c.value, name: SleepAnalysisValue.name(for: c.value))
        case .correlation:
            guard let c = s as? HKCorrelation else { return nil }
            func half(_ id: String) -> Double? {
                guard let t = HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)) else { return nil }
                return (c.objects(for: t).first as? HKQuantitySample)?.quantity.doubleValue(for: .millimeterOfMercury())
            }
            value = .bloodPressure(systolic: half(HealthReadType.systolicIdentifier), diastolic: half(HealthReadType.diastolicIdentifier))
        case .workout:
            guard let w = s as? HKWorkout else { return nil }
            let energy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
                .flatMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .kilocalorie()) }
            value = .workout(WorkoutSummary(activity: "\(w.workoutActivityType)", durationSeconds: w.duration, energyKcal: energy))
        case .ecg:
            guard let e = s as? HKElectrocardiogram else { return nil }
            value = .ecg(ECGSummary(
                classification: "\(e.classification)",
                averageHeartRate: e.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                samplingFrequencyHz: e.samplingFrequency?.doubleValue(for: .hertz()),
                symptomsStatus: "\(e.symptomsStatus)"))
        }
        let source = s.sourceRevision.source
        let device = s.device.map {
            HealthDeviceInfo(name: $0.name, manufacturer: $0.manufacturer, model: $0.model, hardwareVersion: $0.hardwareVersion,
                             firmwareVersion: $0.firmwareVersion, softwareVersion: $0.softwareVersion)
        }
        var meta: [String: String] = [:]
        for (k, v) in s.metadata ?? [:] { meta[k] = "\(v)" }
        return HealthSampleRecord(uuid: s.uuid, type: type, start: s.startDate, end: s.endDate, value: value,
                                  source: HealthSourceInfo(name: source.name, bundleId: source.bundleIdentifier),
                                  device: device, metadata: meta)
    }

    // MARK: Background delivery (hourly)

    /// One observer query per type plus hourly background delivery (ARCHITECTURE.md 4.10). `onChange` is typically
    /// `{ _ = await reader.sync() }`; a burst of observers (several types change at once) runs it once more at most.
    /// Needs the `com.apple.developer.healthkit.background-delivery` entitlement (WP-03's entitlements file).
    public func startObserving(onChange: @escaping @Sendable () async -> Void) {
        for type in HealthReadType.allCases {
            guard let sampleType = HealthKitSupport.objectType(for: type) as? HKSampleType else { continue }
            let gate = self.gate
            let observer = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completion, _ in
                Task {
                    await gate.run(onChange)
                    completion()
                }
            }
            store.execute(observer)
            let name = "reader." + String(describing: type)
            store.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { success, error in
                HealthBackgroundDeliveryLog.shared.record(typeID: name, success: success, error: error)
            }
        }
    }
}

/// Runs the callback one at a time; calls that arrive meanwhile collapse into one more run.
actor ObserverGate {
    private var running = false
    private var again = false

    func run(_ work: @Sendable () async -> Void) async {
        if running { again = true; return }
        running = true
        repeat {
            again = false
            await work()
        } while again
        running = false
    }
}

// MARK: - Reading everything, for the PC (T9739)

/// `HealthAutoProvider` over `HKAnchoredObjectQuery` for every type of `HealthAutoCatalogue.all`, read-only. WRITTEN, NOT
/// COMPILED here (package tests compile only the Mac-side logic): the conductor's xtool build compiles it.
public final class HealthKitAutoProvider: HealthAutoProvider, HealthAskedStatusSource, @unchecked Sendable {
    private let store: HKHealthStore
    private let gate = ObserverGate()
    /// Samples per query; more than this comes back as the next page (`hasMore`).
    private let pageLimit = 5000
    /// Nov 5 2026: the observer completion handler is called at the latest this many seconds after the callback (was 25; Apple
    /// wants it "promptly", and iOS stops delivering to an app that keeps missing it). The app calls it as soon as the samples
    /// are saved locally (`HealthAutoSync.runObserved(afterLocal:)`); this is only the safety cap.
    public static let observerCompletionCap: TimeInterval = 15

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    /// nil = this iOS version / build has no such type (availability-gated; reported as "unsupported", never as an empty read).
    static func sampleType(for type: HealthAutoType) -> HKSampleType? {
        // 0.5.7 V3: a kind that is not proven safe never becomes an HKObjectType here, so no HealthKit call can see it
        // (requestAuthorization, statusForAuthorizationRequest, HKObserverQuery, HKAnchoredObjectQuery). See HealthPollSchedule.swift.
        guard type.isSafeInThisBuild else { return nil }
        switch type.kind {
        case .quantity: return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: type.id))
        case .category: return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: type.id))
        case .workout: return HKObjectType.workoutType()
        case .ecg: return HKObjectType.electrocardiogramType()
        case .stateOfMind:
            if #available(iOS 18.0, *) { return HKObjectType.stateOfMindType() }
            return nil
        case .medicationDose:
            if #available(iOS 26.0, *) { return HKObjectType.medicationDoseEventType() }
            return nil
        case .audiogram: return HKObjectType.audiogramSampleType()
        // Vision prescriptions and CDA documents need per-object authorization (one item at a time), not the
        // permission sheet; asking for them there can raise. Unsupported in this build (0.5.7 V2 crash fix, Oct 15).
        case .visionPrescription: return nil
        case .correlation:
            return HKObjectType.correlationType(forIdentifier: HKCorrelationTypeIdentifier(
                rawValue: HealthAutoCatalogue.correlationPrefix + type.id.dropFirst(HealthAutoCatalogue.correlationPrefix.count)))
        case .heartbeatSeries: return HKSeriesType.heartbeat()
        case .workoutRoute: return HKSeriesType.workoutRoute()
        case .document: return nil
        case .scoredAssessment:
            // GAD-7 / PHQ-9: the iOS SDK this build uses has no scoredAssessmentType API, so these stay
            // "unsupported on this iOS version" (status shown in Settings) until the SDK has it (main, Oct 15).
            return nil
        case .clinical:
            guard HealthKitSupport.hasClinicalAccess else { return nil }
            return HKObjectType.clinicalType(forIdentifier: HKClinicalTypeIdentifier(rawValue: type.id))
        }
    }

    /// The permission sheet's read set in this build: quantity, category, workout and ECG types only (what 0.5.6 asked for).
    /// Correlation types are never requested (HealthKit refuses; their components are in the set).
    static var readTypes: Set<HKObjectType> {
        Set(HealthAutoCatalogue.all.filter { $0.isSafeInThisBuild && $0.kind != .correlation }
            .compactMap { sampleType(for: $0) })
    }

    public var authState: HealthAuthState {
        get async { await HealthKitSupport.authState(read: Self.readTypes, share: [], store: store) }
    }

    public func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    /// #3: has the permission sheet been shown? ONE `statusForAuthorizationRequest` for the whole safe read set (never one per
    /// type, never for the newer kinds: that call raised an uncatchable exception in 0.5.7 V1/V2). An error counts as asked.
    /// Read access itself is not knowable and is never inferred.
    public func askedTypeIDs(_ types: [HealthAutoType]) async -> Set<String>? {
        await HealthAskedTypes.ids(types, source: self)
    }

    public func readRequestAlreadyShown(typeIDs: [String]) async -> Bool {
        let wanted = Set(typeIDs)
        let set = Set(HealthAutoCatalogue.all.filter { wanted.contains($0.id) }.compactMap { Self.sampleType(for: $0) as HKObjectType? })
        guard !set.isEmpty else { return true }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: set)
        return status != .shouldRequest
    }

    public func changes(for type: HealthAutoType, anchor: Data?, since: Date) async throws -> HealthAutoBatch {
        guard let sampleType = Self.sampleType(for: type) else { return HealthAutoBatch(newAnchor: anchor, unsupported: true) }
        var queryAnchor: HKQueryAnchor?
        if let anchor {
            guard let a = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchor) else {
                throw HealthKitError.unreadableAnchor
            }
            queryAnchor = a
        }
        var parts: [NSPredicate] = [HealthKitSupport.notOwnSource()]
        if queryAnchor == nil { parts.append(HKQuery.predicateForSamples(withStart: since, end: nil, options: [])) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        let limit = pageLimit
        let (samples, newAnchor): ([HKSample], HKQueryAnchor?) = try await withCheckedThrowingContinuation { cont in
            let query = HKAnchoredObjectQuery(type: sampleType, predicate: predicate, anchor: queryAnchor, limit: limit) {
                _, samples, _, newAnchor, error in
                if let error { cont.resume(throwing: Self.lockedOrSame(error)) } else { cont.resume(returning: (samples ?? [], newAnchor)) }
            }
            store.execute(query)
        }
        let archived = try newAnchor.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        var out: [HealthAutoSample] = []
        var unstored = 0
        for s in samples {
            // A cancelled task (the run's deadline, iOS expiry) stops converting; what is left counts as unstored, so the
            // engine keeps the anchor and asks for it again.
            if Task.isCancelled { unstored += 1; continue }
            if let c = await convert(s, as: type) { out.append(c) } else { unstored += 1 }
        }
        return HealthAutoBatch(samples: out, newAnchor: archived, hasMore: samples.count >= limit, unstored: unstored)
    }

    /// T10033: the recent-days lane. Samples starting at or after `from`, oldest first, one page; no anchor is touched.
    public func recent(for type: HealthAutoType, from: Date) async throws -> HealthAutoBatch {
        guard let sampleType = Self.sampleType(for: type) else { return HealthAutoBatch(unsupported: true) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HealthKitSupport.notOwnSource(),
            HKQuery.predicateForSamples(withStart: from, end: nil, options: [.strictStartDate])])
        let limit = pageLimit
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples: [HKSample] = try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: limit, sortDescriptors: sort) {
                _, samples, error in
                if let error { cont.resume(throwing: Self.lockedOrSame(error)) } else { cont.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
        var out: [HealthAutoSample] = []
        var unstored = 0
        for s in samples {
            if Task.isCancelled { unstored += 1; continue }
            if let c = await convert(s, as: type) { out.append(c) } else { unstored += 1 }
        }
        return HealthAutoBatch(samples: out, hasMore: samples.count >= limit, unstored: unstored)
    }

    /// #2: a cast or unit failure becomes a raw record with the text HealthKit gave. nil = the sample could not be stored
    /// at all (a detail query for a heartbeat series, route or CDA document failed or was cancelled): the caller counts it
    /// as unstored, so the anchor stays and nothing is lost.
    private func convert(_ s: HKSample, as type: HealthAutoType) async -> HealthAutoSample? {
        let value: Double
        let unit: String
        var extras: [String: String] = [:]
        func raw(_ text: String, _ unit: String, _ why: String) -> HealthAutoSample {
            .rawFallback(typeID: type.id, uuid: s.uuid.uuidString, start: s.startDate, end: s.endDate,
                         source: s.sourceRevision.source.name, device: s.device?.name, valueText: text, unit: unit, reason: why)
        }
        switch type.kind {
        case .quantity:
            guard let q = s as? HKQuantitySample else { return raw("\(s)", type.unit ?? "", "not a quantity sample") }
            guard let u = type.unit else { return raw("\(q.quantity)", "", "no unit in the catalogue") }
            // HKUnit(from:) raises an Objective-C exception on text it does not know, so the one special unit is mapped here.
            var hkUnit: HKUnit?
            if u == HealthAutoCatalogue.effortScoreUnit { if #available(iOS 18.0, *) { hkUnit = .appleEffortScore() } } else { hkUnit = HKUnit(from: u) }
            guard let hkUnit else { return raw("\(q.quantity)", u, "unit not available on this iOS") }
            guard q.quantity.is(compatibleWith: hkUnit) else { return raw("\(q.quantity)", u, "unit not compatible with this quantity") }
            value = q.quantity.doubleValue(for: hkUnit)
            unit = u
        case .category:
            guard let c = s as? HKCategorySample else { return raw("\(s)", HealthAutoCatalogue.categoryUnit, "not a category sample") }
            value = Double(c.value)
            unit = HealthAutoCatalogue.categoryUnit
        case .workout:
            guard let w = s as? HKWorkout else { return raw("\(s)", "s", "not a workout") }
            value = w.duration
            unit = "s"
            extras["activity_type_code"] = "\(w.workoutActivityType.rawValue)"
            if let kcal = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
                .flatMap({ w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .kilocalorie()) }) {
                extras["active_energy_kcal"] = "\(kcal)"
            }
        case .ecg:
            guard let e = s as? HKElectrocardiogram else { return raw("\(s)", "ECG classification code", "not an ECG") }
            value = Double(e.classification.rawValue)
            unit = "ECG classification code"
            if let hr = e.averageHeartRate?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) {
                extras["average_heart_rate_bpm"] = "\(hr)"
            }
        case .stateOfMind:
            guard #available(iOS 18.0, *), let m = s as? HKStateOfMind else { return raw("\(s)", "valence -1 to 1", "not a state of mind") }
            value = m.valence
            unit = "valence -1 to 1"
            extras["kind_code"] = "\(m.kind.rawValue)"
            extras["label_codes"] = m.labels.map { "\($0.rawValue)" }.joined(separator: ",")
            extras["association_codes"] = m.associations.map { "\($0.rawValue)" }.joined(separator: ",")
        case .medicationDose, .visionPrescription:
            // Typed fields of these are not read here (names unverified); the length is a real number and the full
            // description text keeps what HealthKit prints.
            value = s.endDate.timeIntervalSince(s.startDate)
            unit = "s"
            extras["description"] = "\(s)"
        case .audiogram:
            guard let a = s as? HKAudiogramSample else { return raw("\(s)", "sensitivity points", "not an audiogram") }
            value = Double(a.sensitivityPoints.count)
            unit = "sensitivity points"
            extras["points_json"] = Self.json(a.sensitivityPoints.map { p -> [String: Any] in
                var o: [String: Any] = ["frequency_hz": p.frequency.doubleValue(for: .hertz())]
                if let l = p.leftEarSensitivity?.doubleValue(for: .decibelHearingLevel()) { o["left_db_hl"] = l }
                if let r = p.rightEarSensitivity?.doubleValue(for: .decibelHearingLevel()) { o["right_db_hl"] = r }
                return o
            })
        case .correlation:
            guard let c = s as? HKCorrelation else { return raw("\(s)", "component samples", "not a correlation") }
            value = Double(c.objects.count)
            unit = "component samples"
            extras["components_json"] = Self.json(c.objects.map { o -> [String: Any] in
                ["type": o.sampleType.identifier, "uuid": o.uuid.uuidString, "value": (o as? HKQuantitySample).map { "\($0.quantity)" } ?? "\(o)"]
            })
        case .heartbeatSeries:
            guard let h = s as? HKHeartbeatSeriesSample else { return raw("\(s)", "beats", "not a heartbeat series") }
            value = Double(h.count)
            unit = "beats"
            guard let b = try? await beats(of: h) else { return nil }
            extras["beats_json"] = Self.json(b)
        case .workoutRoute:
            guard let r = s as? HKWorkoutRoute else { return raw("\(s)", "locations", "not a workout route") }
            value = Double(r.count)
            unit = "locations"
            guard let l = try? await locations(of: r) else { return nil }
            extras["locations_json"] = Self.json(l)
        case .document:
            guard s is HKCDADocumentSample else { return raw("\(s)", "CDA bytes", "not a CDA document") }
            guard let doc = try? await cdaDocument(uuid: s.uuid) else { return nil }
            let data = doc.documentData ?? Data()
            value = Double(data.count)
            unit = "CDA bytes"
            extras["title"] = doc.title
            extras["patient_name"] = doc.patientName
            extras["author_name"] = doc.authorName
            extras["custodian_name"] = doc.custodianName
            extras["cda_xml"] = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        case .scoredAssessment:
            guard #available(iOS 18.0, *), let a = s as? HKScoredAssessment else { return raw("\(s)", "assessment score", "not a scored assessment") }
            value = Double(a.score)
            unit = "assessment score"
            if let g = a as? HKGAD7Assessment { extras["risk_code"] = "\(g.risk.rawValue)"; extras["answers"] = "\(g.answers)" }
            if let p = a as? HKPHQ9Assessment { extras["risk_code"] = "\(p.risk.rawValue)"; extras["answers"] = "\(p.answers)" }
        case .clinical:
            guard let c = s as? HKClinicalRecord else { return raw("\(s)", "FHIR bytes", "not a clinical record") }
            let data = c.fhirResource?.data ?? Data()
            value = Double(data.count)
            unit = "FHIR bytes"
            extras["display_name"] = c.displayName
            if let t = c.fhirResource?.resourceType { extras["fhir_resource_type"] = t.rawValue }
            extras["fhir_json"] = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        }
        return HealthAutoSample(typeID: type.id, value: value, unit: unit, start: s.startDate, end: s.endDate,
                                source: s.sourceRevision.source.name, device: s.device?.name, uuid: s.uuid.uuidString,
                                extras: extras)
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "\(object)" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// Resumes a continuation exactly once and stops its HealthKit query when the calling task is cancelled (the run's
    /// deadline), so a slow detail query cannot outlive the run.
    private final class OneShot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Error>?
        private var query: HKQuery?
        private var done = false
        private var cancelled = false
        func start(_ c: CheckedContinuation<T, Error>, query q: HKQuery, store: HKHealthStore) {
            lock.lock(); cont = c; query = q; let already = cancelled; lock.unlock()
            if already { finish(.failure(CancellationError())); return }
            store.execute(q)
        }
        func finish(_ r: Result<T, Error>) {
            lock.lock()
            guard !done, let c = cont else { lock.unlock(); return }
            done = true
            lock.unlock()
            c.resume(with: r)
        }
        func cancel(store: HKHealthStore) {
            lock.lock(); cancelled = true; let q = query; lock.unlock()
            if let q { store.stop(q) }
            finish(.failure(CancellationError()))
        }
    }

    /// [[seconds since series start, preceded by gap]] for every beat.
    private func beats(of series: HKHeartbeatSeriesSample) async throws -> [[Any]] {
        let once = OneShot<[[Any]]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[[Any]], Error>) in
                var rows: [[Any]] = []
                let q = HKHeartbeatSeriesQuery(heartbeatSeries: series) { _, time, gap, done, error in
                    if let error { once.finish(.failure(error)); return }
                    rows.append([time, gap])
                    if done { once.finish(.success(rows)) }
                }
                once.start(cont, query: q, store: store)
            }
        } onCancel: { once.cancel(store: store) }
    }

    /// [[lat, lon, altitude m, epoch seconds, horizontal accuracy m]] for every point of the route.
    private func locations(of route: HKWorkoutRoute) async throws -> [[Double]] {
        let once = OneShot<[[Double]]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[[Double]], Error>) in
                var rows: [[Double]] = []
                let q = HKWorkoutRouteQuery(route: route) { _, locs, done, error in
                    if let error { once.finish(.failure(error)); return }
                    for l in locs ?? [] {
                        rows.append([l.coordinate.latitude, l.coordinate.longitude, l.altitude, l.timestamp.timeIntervalSince1970,
                                     l.horizontalAccuracy])
                    }
                    if done { once.finish(.success(rows)) }
                }
                once.start(cont, query: q, store: store)
            }
        } onCancel: { once.cancel(store: store) }
    }

    /// The CDA document behind a document sample: the anchored query returns the sample only, the document (with its XML)
    /// comes from an HKDocumentQuery for that one sample.
    private func cdaDocument(uuid: UUID) async throws -> HKCDADocument {
        guard let type = HKObjectType.documentType(forIdentifier: .CDA) else { throw HealthKitError.unsupportedType("CDA document") }
        let once = OneShot<HKCDADocument>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HKCDADocument, Error>) in
                let q = HKDocumentQuery(documentType: type, predicate: HKQuery.predicateForObject(with: uuid), limit: 1,
                                        sortDescriptors: nil, includeDocumentData: true) { _, docs, done, error in
                    if let error { once.finish(.failure(error)); return }
                    if let d = (docs?.first as? HKCDADocumentSample)?.document { once.finish(.success(d)) }
                    else if done { once.finish(.failure(HealthKitError.unsupportedType("CDA document"))) }
                }
                once.start(cont, query: q, store: store)
            }
        } onCancel: { once.cancel(store: store) }
    }

    /// An observer query plus hourly background delivery (Apple: the system wakes the app at most once per period; hourly is the
    /// finest it grants for most types) for the "frequent" and "after wake" types of `HealthPollSchedule`, all of them safe kinds.
    /// The rest are polled by the schedule on foreground/background refresh or "Sync now". `onChange` is
    /// `{ _ = await auto.run(trigger: .automatic) }`; a burst of observers collapses into one run. Needs the
    /// `com.apple.developer.healthkit.background-delivery` entitlement (ios/xtool/HealthApp.entitlements). iOS delivers only
    /// while the phone has been unlocked once since boot, and may throttle.
    /// 0.6.0.7 (Oct 28 2026): registered at EVERY launch from MGApp.init, background relaunches included (Apple's pattern;
    /// before, R8o registered them only after the first screen, so a background delivery found no observer, completion was
    /// never called and iOS backed off: no heart rate reached the PC Oct 27-28). `onChange` gets the changed type's id and
    /// must stay light (it returns once the samples are saved on the phone, not when the PC has them); `completion` is called when it returns or after `completionCap` seconds, whichever is first, and
    /// at once on an observer error. Returns the type ids registered.
    @discardableResult
    public func startObserving(completionCap: TimeInterval = HealthKitAutoProvider.observerCompletionCap,
                               onChange: @escaping @Sendable (String) async -> Void) -> [String] {
        var registered: [String] = []
        for type in HealthAutoCatalogue.all where type.isSafeInThisBuild {
            let c = HealthPollSchedule.cadence(for: type)
            guard c == .frequent || c == .afterWake else { continue }
            guard let sampleType = Self.sampleType(for: type) else { continue }
            let id = type.id
            let observer = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completion, error in
                let once = CompletionOnce(completion)
                if error != nil { once.call(); return }
                let work = Task { await onChange(id); once.call() }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(completionCap * 1_000_000_000))
                    once.call()
                    work.cancel()
                }
            }
            store.execute(observer)
            // Nov 5 2026: the answer is kept per type (debug channel `health_sync`), not thrown away.
            store.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { success, error in
                HealthBackgroundDeliveryLog.shared.record(typeID: id, success: success, error: error)
            }
            registered.append(id)
        }
        return registered
    }

    /// HealthKit's "protected data unavailable" (phone locked) as `HealthAutoLocked`; any other error unchanged.
    static func lockedOrSame(_ error: Error) -> Error {
        let e = error as NSError
        if e.domain == HKErrorDomain && e.code == HKError.Code.errorDatabaseInaccessible.rawValue { return HealthAutoLocked() }
        return error
    }
}

/// Calls an HKObserverQuery completion handler exactly once, from whichever path gets there first.
final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    func call() {
        lock.lock()
        let h = handler
        handler = nil
        lock.unlock()
        h?()
    }
}

// MARK: - Writing (the mirror)

public final class HealthKitMirrorWriter: HealthMirrorWriter, @unchecked Sendable {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public var authState: HealthAuthState {
        get async { await HealthKitSupport.authState(read: [], share: HealthKitSupport.mirrorShareTypes, store: store) }
    }

    public func requestMirrorAuthorization() async throws {
        try await store.requestAuthorization(toShare: HealthKitSupport.mirrorShareTypes, read: [])
    }

    public func write(_ samples: [MirrorSample]) async throws -> MirrorWriteResult {
        for s in samples { try MirrorPolicy.check(s) }          // a refused sample is a bug upstream: write nothing
        var written: [String] = []
        var skipped: [MirrorMetric] = []
        for (metric, group) in Dictionary(grouping: samples, by: \.metric) {
            guard let type = HealthKitSupport.shareType(for: metric),
                  store.authorizationStatus(for: type) == .sharingAuthorized
            else { skipped.append(metric); continue }
            // Replace: this app's earlier sample with the same external id goes first (noop's pattern, L1040-1056).
            _ = try? await store.deleteObjects(of: type, predicate: HealthKitSupport.ownSource(withExternalKeys: group.map(\.externalKey)))
            if metric == .workout {
                for s in group { try await saveWorkout(s) }
            } else {
                try await store.save(group.compactMap { hkSample($0, type: type) })
            }
            written += group.map(\.externalKey)
        }
        return MirrorWriteResult(writtenKeys: written, skippedMetrics: skipped)
    }

    public func delete(keys: [String], metric: MirrorMetric) async throws {
        guard let type = HealthKitSupport.shareType(for: metric), store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        _ = try await store.deleteObjects(of: type, predicate: HealthKitSupport.ownSource(withExternalKeys: keys))
    }

    private func metadata(_ s: MirrorSample) -> [String: Any] {
        s.metadata.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
    }

    private func hkSample(_ s: MirrorSample, type: HKSampleType) -> HKSample? {
        let device = HealthKitSupport.device(s.device)
        switch s.payload {
        case .quantity(let value, let unit):
            guard let q = type as? HKQuantityType else { return nil }
            return HKQuantitySample(type: q, quantity: HKQuantity(unit: HKUnit(from: unit), doubleValue: value),
                                    start: s.start, end: s.end, device: device, metadata: metadata(s))
        case .category(let value):
            guard let c = type as? HKCategoryType else { return nil }
            return HKCategorySample(type: c, value: value, start: s.start, end: s.end, device: device, metadata: metadata(s))
        case .workout:
            return nil
        }
    }

    private func saveWorkout(_ s: MirrorSample) async throws {
        guard case .workout(let activity, _, _) = s.payload else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = HealthKitSupport.activityType(for: activity)
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: HealthKitSupport.device(s.device))
        do {
            try await builder.beginCollection(at: s.start)
            try await builder.addMetadata(metadata(s))
            try await builder.endCollection(at: s.end)
            _ = try await builder.finishWorkout()
        } catch {
            builder.discardWorkout()
            throw error
        }
    }
}

#endif
