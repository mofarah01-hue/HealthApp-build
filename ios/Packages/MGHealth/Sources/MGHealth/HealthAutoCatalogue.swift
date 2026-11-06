import Foundation

// Apple Health -> PC without Mo (T9739, fix brief C). The list of every Health type the app asks to read, in plain Swift so
// the list is tested on a Mac; `HealthKitLayer.swift` turns each entry into an HKObjectType (an identifier this iOS version
// does not know is skipped there, never an error). Read-only: nothing here writes to Health.

public struct HealthAutoType: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case quantity, category, workout, ecg
        // P9817 (#1): the sample families the first four kinds missed. Each is availability-gated by `minIOS`.
        case stateOfMind, medicationDose, audiogram, correlation, heartbeatSeries, workoutRoute, clinical, visionPrescription
        // Round 5 (#1): CDA documents (HKDocumentType) and the scored questionnaires (HKScoredAssessmentType, iOS 18).
        case document, scoredAssessment
    }

    /// Apple's identifier string ("HKQuantityTypeIdentifierStepCount"); also the key the type's anchor is stored under.
    public let id: String
    public let kind: Kind
    /// The HealthKit unit string the value is read in (quantities only). Sent as given: the PC's importer applies its own
    /// unit rules (the 0-1 fraction under "%" becomes a percentage there, not here).
    public let unit: String?
    /// First iOS major version that has this type (nil = every supported version). The reader reports "unsupported" below it.
    public let minIOS: Int?

    public init(id: String, kind: Kind, unit: String? = nil, minIOS: Int? = nil) {
        self.id = id
        self.kind = kind
        self.unit = unit
        self.minIOS = minIOS
    }
}

public enum HealthAutoCatalogue {
    /// The unit text for Apple's effort score (iOS 18); `HealthKitAutoProvider.hkUnit` maps it to `HKUnit.appleEffortScore()`.
    public static let effortScoreUnit = "appleEffortScore"

    private static let q = "HKQuantityTypeIdentifier"
    private static let c = "HKCategoryTypeIdentifier"

    /// (identifier suffix, HealthKit unit string).
    private static let quantities: [(String, String)] = [
        // body
        ("BodyMassIndex", "count"), ("BodyFatPercentage", "%"), ("Height", "m"), ("BodyMass", "kg"), ("LeanBodyMass", "kg"),
        ("WaistCircumference", "m"),
        // activity
        ("StepCount", "count"), ("DistanceWalkingRunning", "m"), ("DistanceCycling", "m"), ("DistanceWheelchair", "m"),
        ("BasalEnergyBurned", "kcal"), ("ActiveEnergyBurned", "kcal"), ("FlightsClimbed", "count"), ("NikeFuel", "count"),
        ("AppleExerciseTime", "min"), ("AppleMoveTime", "min"), ("AppleStandTime", "min"), ("PushCount", "count"),
        ("DistanceSwimming", "m"), ("SwimmingStrokeCount", "count"), ("VO2Max", "mL/(kg*min)"),
        ("DistanceDownhillSnowSports", "m"),
        // P9817: sport types the first list missed (an identifier an older iOS does not know is skipped, never an error)
        ("CyclingSpeed", "m/s"), ("CyclingPower", "W"), ("CyclingCadence", "count/min"), ("CyclingFunctionalThresholdPower", "W"),
        ("DistanceRowing", "m"), ("DistancePaddleSports", "m"), ("DistanceSkatingSports", "m"),
        ("DistanceCrossCountrySkiing", "m"), ("CrossCountrySkiingSpeed", "m/s"), ("RowingSpeed", "m/s"),
        ("PaddleSportsSpeed", "m/s"), ("PhysicalEffort", "kcal/(kg*hr)"),
        ("EstimatedWorkoutEffortScore", HealthAutoCatalogue.effortScoreUnit), ("WorkoutEffortScore", HealthAutoCatalogue.effortScoreUnit),
        ("NumberOfAlcoholicBeverages", "count"), ("ElectrodermalActivity", "S"),
        // heart
        ("HeartRate", "count/min"), ("RestingHeartRate", "count/min"), ("WalkingHeartRateAverage", "count/min"),
        ("HeartRateVariabilitySDNN", "ms"), ("HeartRateRecoveryOneMinute", "count/min"),
        // T9817 (2026-10-17): Apple Watch RMSSD, 800 samples in Mo's Health export but missing from this list, so never sent
        ("HeartRateVariabilityRMSSD", "ms"),
        ("AtrialFibrillationBurden", "%"), ("PeripheralPerfusionIndex", "%"),
        // breathing, blood
        ("OxygenSaturation", "%"), ("RespiratoryRate", "count/min"), ("ForcedVitalCapacity", "L"),
        ("ForcedExpiratoryVolume1", "L"), ("PeakExpiratoryFlowRate", "L/min"), ("InhalerUsage", "count"),
        ("BloodPressureSystolic", "mmHg"), ("BloodPressureDiastolic", "mmHg"), ("BloodGlucose", "mg/dL"),
        ("InsulinDelivery", "IU"), ("BloodAlcoholContent", "%"), ("NumberOfTimesFallen", "count"),
        ("AppleSleepingBreathingDisturbances", "count"),
        // mobility and running
        ("WalkingSpeed", "m/s"), ("WalkingStepLength", "m"), ("WalkingAsymmetryPercentage", "%"),
        ("WalkingDoubleSupportPercentage", "%"), ("StairAscentSpeed", "m/s"), ("StairDescentSpeed", "m/s"),
        ("SixMinuteWalkTestDistance", "m"), ("AppleWalkingSteadiness", "%"), ("RunningSpeed", "m/s"),
        ("RunningPower", "W"), ("RunningStrideLength", "m"), ("RunningVerticalOscillation", "cm"),
        ("RunningGroundContactTime", "ms"),
        // environment
        ("EnvironmentalAudioExposure", "dBASPL"), ("HeadphoneAudioExposure", "dBASPL"),
        ("EnvironmentalSoundReduction", "dBASPL"), ("TimeInDaylight", "min"), ("UVExposure", "count"),
        ("UnderwaterDepth", "m"), ("WaterTemperature", "degC"),
        // temperature
        ("BodyTemperature", "degC"), ("BasalBodyTemperature", "degC"), ("AppleSleepingWristTemperature", "degC"),
        // dietary
        ("DietaryEnergyConsumed", "kcal"), ("DietaryCarbohydrates", "g"), ("DietaryProtein", "g"), ("DietaryFatTotal", "g"),
        ("DietaryFatSaturated", "g"), ("DietaryFatMonounsaturated", "g"), ("DietaryFatPolyunsaturated", "g"),
        ("DietaryCholesterol", "mg"), ("DietarySodium", "mg"), ("DietaryFiber", "g"), ("DietarySugar", "g"),
        ("DietaryWater", "mL"), ("DietaryCaffeine", "mg"), ("DietaryCalcium", "mg"), ("DietaryIron", "mg"),
        ("DietaryPotassium", "mg"), ("DietaryMagnesium", "mg"), ("DietaryZinc", "mg"), ("DietaryPhosphorus", "mg"),
        ("DietaryCopper", "mg"), ("DietaryManganese", "mg"), ("DietarySelenium", "mcg"), ("DietaryChromium", "mcg"),
        ("DietaryMolybdenum", "mcg"), ("DietaryIodine", "mcg"), ("DietaryChloride", "mg"), ("DietaryVitaminA", "mcg"),
        ("DietaryVitaminB6", "mg"), ("DietaryVitaminB12", "mcg"), ("DietaryVitaminC", "mg"), ("DietaryVitaminD", "mcg"),
        ("DietaryVitaminE", "mg"), ("DietaryVitaminK", "mcg"), ("DietaryThiamin", "mg"), ("DietaryRiboflavin", "mg"),
        ("DietaryNiacin", "mg"), ("DietaryFolate", "mcg"), ("DietaryBiotin", "mcg"), ("DietaryPantothenicAcid", "mg"),
    ]

    /// Category types: the value is HealthKit's integer code (sleep stage, event happened, symptom severity ...).
    private static let categories: [String] = [
        "SleepAnalysis", "AppleStandHour", "MindfulSession", "HighHeartRateEvent", "LowHeartRateEvent",
        "IrregularHeartRhythmEvent", "LowCardioFitnessEvent", "HandwashingEvent", "ToothbrushingEvent",
        "AppleWalkingSteadinessEvent", "EnvironmentalAudioExposureEvent", "HeadphoneAudioExposureEvent",
        "MenstrualFlow", "IntermenstrualBleeding", "SexualActivity",
        "AbdominalCramps", "Acne", "AppetiteChanges", "BladderIncontinence", "Bloating", "BreastPain",
        "ChestTightnessOrPain", "Chills", "Constipation", "Coughing", "Diarrhea", "Dizziness", "DrySkin", "Fainting",
        "Fatigue", "Fever", "GeneralizedBodyAche", "HairLoss", "Headache", "Heartburn", "HotFlashes", "LossOfSmell",
        "LossOfTaste", "LowerBackPain", "MemoryLapse", "MoodChanges", "Nausea", "NightSweats", "PelvicPain",
        "RapidPoundingOrFlutteringHeartbeat", "RunnyNose", "ShortnessOfBreath", "SinusCongestion", "SkippedHeartbeat",
        "SleepChanges", "SoreThroat", "VaginalDryness", "Vomiting", "Wheezing",
        // P9817: the cycle-tracking, pregnancy and sleep-apnea categories the first list missed
        "CervicalMucusQuality", "OvulationTestResult", "PregnancyTestResult", "ProgesteroneTestResult", "Pregnancy",
        "Lactation", "Contraceptive", "InfrequentMenstrualCycles", "IrregularMenstrualCycles",
        "PersistentIntermenstrualBleeding", "ProlongedMenstrualPeriods", "BleedingAfterPregnancy",
        "BleedingDuringPregnancy", "SleepApneaEvent",
    ]

    public static let workoutID = "HKWorkoutTypeIdentifier"
    public static let ecgID = "HKDataTypeIdentifierElectrocardiogram"

    /// Every type, in a fixed order (a run reads them in this order; the order never changes an anchor).
    public static let all: [HealthAutoType] =
        quantities.map { HealthAutoType(id: q + $0.0, kind: .quantity, unit: $0.1) }
        + categories.map { HealthAutoType(id: c + $0, kind: .category) }
        + [HealthAutoType(id: workoutID, kind: .workout), HealthAutoType(id: ecgID, kind: .ecg)]
        + families

    /// P9817 (#1): everything that is not a plain quantity/category. Ids are this app's keys (also the anchor key); the
    /// Apple type behind each is chosen in HealthKitLayer.
    static let families: [HealthAutoType] = [
        HealthAutoType(id: "HKDataTypeIdentifierStateOfMind", kind: .stateOfMind, minIOS: 18),
        HealthAutoType(id: "HKDataTypeIdentifierMedicationDoseEvent", kind: .medicationDose, minIOS: 26),
        HealthAutoType(id: "HKDataTypeIdentifierAudiogram", kind: .audiogram),
        HealthAutoType(id: "HKDataTypeIdentifierVisionPrescription", kind: .visionPrescription, minIOS: 16),
        HealthAutoType(id: correlationPrefix + "BloodPressure", kind: .correlation),
        HealthAutoType(id: correlationPrefix + "Food", kind: .correlation),
        HealthAutoType(id: "HKDataTypeIdentifierHeartbeatSeries", kind: .heartbeatSeries),
        HealthAutoType(id: "HKWorkoutRouteTypeIdentifier", kind: .workoutRoute),
        HealthAutoType(id: documentCDAID, kind: .document, minIOS: 10),
        HealthAutoType(id: "HKScoredAssessmentTypeIdentifierGAD7", kind: .scoredAssessment, minIOS: 18),
        HealthAutoType(id: "HKScoredAssessmentTypeIdentifierPHQ9", kind: .scoredAssessment, minIOS: 18),
    ] + clinicalNames.map { HealthAutoType(id: clinicalPrefix + $0, kind: .clinical, minIOS: 12) }

    public static let documentCDAID = "HKDocumentTypeIdentifierCDA"
    public static let correlationPrefix = "HKCorrelationTypeIdentifier"
    public static let clinicalPrefix = "HKClinicalTypeIdentifier"
    /// HKClinicalTypeIdentifier suffixes (reading needs the health-records entitlement; without it these report unsupported).
    static let clinicalNames = ["AllergyRecord", "ConditionRecord", "CoverageRecord", "ImmunizationRecord", "LabResultRecord",
                                "MedicationRecord", "ProcedureRecord", "VitalSignRecord"]

    public static func type(id: String) -> HealthAutoType? { all.first { $0.id == id } }

    /// The unit text sent for a category value (the code itself is in `value`).
    public static let categoryUnit = "category code"
}
