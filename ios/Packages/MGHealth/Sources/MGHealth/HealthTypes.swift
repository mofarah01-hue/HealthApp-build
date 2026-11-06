import Foundation
import MGDomain

// Platform-neutral description of what Apple Health holds and what this app reads from it (ARCHITECTURE.md 4.10).
// Nothing in this file imports HealthKit: the HealthKit layer (HealthKitLayer.swift) converts to and from these types,
// so the decisions (what is ours, what becomes a bp_cuff event, what is aggregated) are tested on a Mac.

/// The types read from Apple Health in B1 (ARCHITECTURE.md 4.10 "Read"). Raw values are Apple's own type identifier
/// strings, which is also the key each type's anchor is stored under (`HealthSampleSink.anchor(for:)`).
/// Medication doses (iOS 26) are not in this list: see the report.
public enum HealthReadType: String, CaseIterable, Sendable {
    /// Blood pressure is read as the HealthKit correlation (systolic + diastolic together), never as two loose
    /// quantity samples: a correlation's halves are also returned by quantity queries, so reading both would count a
    /// reading twice.
    case bloodPressure = "HKCorrelationTypeIdentifierBloodPressure"
    case heartRate = "HKQuantityTypeIdentifierHeartRate"
    case restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
    case hrvSDNN = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    case oxygenSaturation = "HKQuantityTypeIdentifierOxygenSaturation"
    case respiratoryRate = "HKQuantityTypeIdentifierRespiratoryRate"
    case stepCount = "HKQuantityTypeIdentifierStepCount"
    case walkingAsymmetry = "HKQuantityTypeIdentifierWalkingAsymmetryPercentage"
    case bodyMass = "HKQuantityTypeIdentifierBodyMass"
    case bodyFatPercentage = "HKQuantityTypeIdentifierBodyFatPercentage"
    case leanBodyMass = "HKQuantityTypeIdentifierLeanBodyMass"
    case bloodGlucose = "HKQuantityTypeIdentifierBloodGlucose"
    case dietaryCaffeine = "HKQuantityTypeIdentifierDietaryCaffeine"
    case dietaryEnergy = "HKQuantityTypeIdentifierDietaryEnergyConsumed"
    case activeEnergy = "HKQuantityTypeIdentifierActiveEnergyBurned"
    case vo2Max = "HKQuantityTypeIdentifierVO2Max"
    case sleepAnalysis = "HKCategoryTypeIdentifierSleepAnalysis"
    case sleepingWristTemperature = "HKQuantityTypeIdentifierAppleSleepingWristTemperature"
    case workout = "HKWorkoutTypeIdentifier"
    /// Read-only: classification and summary, no voltages in B1.
    case electrocardiogram = "HKDataTypeIdentifierElectrocardiogram"

    public enum Kind: Sendable { case quantity, category, correlation, workout, ecg }

    public var kind: Kind {
        switch self {
        case .bloodPressure: return .correlation
        case .sleepAnalysis: return .category
        case .workout: return .workout
        case .electrocardiogram: return .ecg
        default: return .quantity
        }
    }

    /// How a type becomes events. Heart rate, steps and active energy arrive as a sample every few seconds to minutes
    /// from a watch; one event per sample would be tens of thousands of events a day in `events.jsonl`, so they are
    /// summarised per hour and source (ARCHITECTURE.md 4.10 says "each sample -> event"; this is the one deliberate
    /// departure, flagged in the WP-14 report). Everything else is one event per sample.
    public enum Granularity: Hashable, Sendable {
        case perSample
        /// One event per (hour, source): mean / min / max / n.
        case hourlyMean
        /// One event per (hour, source): sum / n.
        case hourlySum
    }

    public var granularity: Granularity {
        switch self {
        case .heartRate: return .hourlyMean
        case .stepCount, .activeEnergy: return .hourlySum
        default: return .perSample
        }
    }

    /// HealthKit unit string used to read the value, the factor that turns it into the unit written in the event, and
    /// that unit's name. HealthKit holds percentages as fractions (0.97), so those are scaled by 100 and written as "%".
    /// Nil for types that are not plain quantities.
    public var unit: (hk: String, scale: Double, label: String)? {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate: return ("count/min", 1, "count/min")
        case .hrvSDNN: return ("ms", 1, "ms")
        case .oxygenSaturation, .walkingAsymmetry, .bodyFatPercentage: return ("%", 100, "%")
        case .stepCount: return ("count", 1, "count")
        case .bodyMass, .leanBodyMass: return ("kg", 1, "kg")
        case .bloodGlucose: return ("mg/dL", 1, "mg/dL")
        case .dietaryCaffeine: return ("mg", 1, "mg")
        case .dietaryEnergy, .activeEnergy: return ("kcal", 1, "kcal")
        case .vo2Max: return ("mL/(kg*min)", 1, "mL/(kg*min)")
        case .sleepingWristTemperature: return ("degC", 1, "degC")
        case .bloodPressure, .sleepAnalysis, .workout, .electrocardiogram: return nil
        }
    }

    /// Identifiers of the two halves of a blood-pressure correlation.
    public static let systolicIdentifier = "HKQuantityTypeIdentifierBloodPressureSystolic"
    public static let diastolicIdentifier = "HKQuantityTypeIdentifierBloodPressureDiastolic"
}

/// `HKCategoryValueSleepAnalysis` raw values (iOS 16+). Names are what the event carries.
public enum SleepAnalysisValue {
    public static func name(for raw: Int) -> String {
        switch raw {
        case 0: return "inBed"
        case 1: return "asleepUnspecified"
        case 2: return "awake"
        case 3: return "asleepCore"
        case 4: return "asleepDeep"
        case 5: return "asleepREM"
        default: return "unknown(\(raw))"
        }
    }

    /// `HKCategoryValueSleepAnalysis.asleepUnspecified`: asleep, no stage. The only sleep value the mirror writes.
    public static let asleepUnspecified = 1
}

/// Who wrote a sample (HKSource).
public struct HealthSourceInfo: Hashable, Sendable {
    public var name: String
    public var bundleId: String?

    public init(name: String, bundleId: String? = nil) {
        self.name = name
        self.bundleId = bundleId
    }
}

/// HKDevice, field for field.
public struct HealthDeviceInfo: Hashable, Sendable {
    public var name: String?
    public var manufacturer: String?
    public var model: String?
    public var hardwareVersion: String?
    public var firmwareVersion: String?
    public var softwareVersion: String?

    public init(name: String? = nil, manufacturer: String? = nil, model: String? = nil, hardwareVersion: String? = nil,
                firmwareVersion: String? = nil, softwareVersion: String? = nil) {
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.hardwareVersion = hardwareVersion
        self.firmwareVersion = firmwareVersion
        self.softwareVersion = softwareVersion
    }

    /// The contract's `origin.device` text: the name, with the model in brackets when it adds something.
    public var originLabel: String? {
        switch (name, model) {
        case (let n?, let m?) where n != m: return "\(n) (\(m))"
        case (let n?, _): return n
        case (nil, let m?): return m
        default: return nil
        }
    }
}

public struct WorkoutSummary: Hashable, Sendable {
    public var activity: String
    public var durationSeconds: Double
    public var energyKcal: Double?
    public var distanceMeters: Double?

    public init(activity: String, durationSeconds: Double, energyKcal: Double? = nil, distanceMeters: Double? = nil) {
        self.activity = activity
        self.durationSeconds = durationSeconds
        self.energyKcal = energyKcal
        self.distanceMeters = distanceMeters
    }
}

public struct ECGSummary: Hashable, Sendable {
    public var classification: String
    public var averageHeartRate: Double?
    public var samplingFrequencyHz: Double?
    public var symptomsStatus: String?

    public init(classification: String, averageHeartRate: Double? = nil, samplingFrequencyHz: Double? = nil,
                symptomsStatus: String? = nil) {
        self.classification = classification
        self.averageHeartRate = averageHeartRate
        self.samplingFrequencyHz = samplingFrequencyHz
        self.symptomsStatus = symptomsStatus
    }
}

public enum HealthValue: Hashable, Sendable {
    /// Already converted to `HealthReadType.unit.label` (percentages scaled to 0...100).
    case quantity(Double)
    case category(code: Int, name: String)
    /// A blood-pressure correlation, mmHg. A half is nil when the correlation lacked that sample.
    case bloodPressure(systolic: Double?, diastolic: Double?)
    case workout(WorkoutSummary)
    case ecg(ECGSummary)
}

/// `HKMetadataKeyExternalUUID`'s string value.
public enum HealthMetadataKey {
    public static let externalUUID = "HKExternalUUID"
}

/// One Health sample, as the HealthKit layer hands it over (or a test builds it).
public struct HealthSampleRecord: Hashable, Sendable {
    /// `HKObject.uuid`. For a blood-pressure reading: the correlation's uuid.
    public var uuid: UUID
    public var type: HealthReadType
    public var start: Date
    public var end: Date
    public var value: HealthValue
    public var source: HealthSourceInfo
    public var device: HealthDeviceInfo?
    /// HealthKit metadata with every value rendered as text.
    public var metadata: [String: String]

    public init(uuid: UUID, type: HealthReadType, start: Date, end: Date, value: HealthValue, source: HealthSourceInfo,
                device: HealthDeviceInfo? = nil, metadata: [String: String] = [:]) {
        self.uuid = uuid
        self.type = type
        self.start = start
        self.end = end
        self.value = value
        self.source = source
        self.device = device
        self.metadata = metadata
    }
}

/// Where Apple Health stands for this build. HealthKit does not say whether a READ permission was granted (Apple hides
/// it on purpose), so there is no `denied` here: a type with no data and `requested` just shows blank.
public enum HealthAuthState: String, Sendable, Equatable {
    /// `HKHealthStore.isHealthDataAvailable()` is false (iPad, Mac).
    case unavailable
    /// The build was re-signed without `com.apple.developer.healthkit` (free Apple ID: noop CHANGELOG, #348). The
    /// permission sheet can never appear and the app can never appear under Settings > Health > Data Access.
    case entitlementMissing
    case notRequested
    case requested

    public var isUsable: Bool { self == .notRequested || self == .requested }

    /// The sentence shown instead of every Health value when it is not usable (R6: blank with its reason).
    public var message: String? {
        switch self {
        case .entitlementMissing: return "Apple Health isn't available in this build"
        case .unavailable: return "Apple Health isn't available on this device"
        case .notRequested, .requested: return nil
        }
    }
}
