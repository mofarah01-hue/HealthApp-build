import Foundation

// P9745 (2026-10-14): ONE profile for every phone model. Mo's birth date, sex and height are static facts he has given many
// times; they live in the phone's Me profile (Settings > Profile) AND on the PC (profile.json, Apple Health derived).
// Before this, DayPipeline read only the Me store, so a value that had reached the PC but not the Me store was a blank
// "profile has no birth date" on every older day. `EffectiveProfile.merged` is the one accessor: the Me profile wins, a
// field it leaves empty is filled from the last PC profile the phone fetched (GET /v1/profile, kept as `PCProfileSnapshot`).
// No model reads the Me store alone and none carries a default; a missing field is a blank with a reason.
// `ProfileNeeds.table` lists which model needs which field (tests in MGSignalTests/Pipelines/ProfileInputsGuardTests.swift
// fail if a listed model reads the profile another way, or blanks as "missing" while the merged profile has the value).

/// The last PC profile the phone fetched (GET /v1/profile), kept in the store so models can use it between fetches.
public struct PCProfileSnapshot: Codable, Hashable, Sendable {
    public var birthDate: String?
    public var sex: String?
    public var heightCm: Double?
    public var weightKg: Double?
    public var hrMaxMeasured: Double?
    public var hrRestBaseline: Double?
    /// D-LOAD-WALK-2: fat-free mass (kg) from the PC's body-composition scan, adjusted to the current weight.
    public var fatFreeMassKg: Double?
    /// Contract field name → where the PC got it.
    public var sources: [String: String]

    public init(birthDate: String? = nil, sex: String? = nil, heightCm: Double? = nil, weightKg: Double? = nil,
                hrMaxMeasured: Double? = nil, hrRestBaseline: Double? = nil, fatFreeMassKg: Double? = nil,
                sources: [String: String] = [:]) {
        self.fatFreeMassKg = fatFreeMassKg
        self.birthDate = birthDate
        self.sex = sex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.hrMaxMeasured = hrMaxMeasured
        self.hrRestBaseline = hrRestBaseline
        self.sources = sources
    }
}

public enum EffectiveProfile {
    /// The ranges Settings accepts when typed; a PC value outside them is not used (a unit slip never reaches a model).
    public static let heightRange = 100.0...250.0
    public static let weightRange = 30.0...300.0
    public static let hrMaxRange = 100.0...240.0
    public static let hrRestRange = 25.0...120.0
    public static let ffmRange = 20.0...150.0

    /// Me profile first; each empty field filled from the PC snapshot. `today` bounds the birth date.
    public static func merged(phone: Profile?, pc: PCProfileSnapshot?, today: LocalDay) -> Profile {
        var p = phone ?? Profile()
        guard let pc else { return p }
        if p.birthDate == nil, let t = pc.birthDate, let d = LocalDay(iso: t), d <= today, d.year >= today.year - 120 {
            p.birthDate = d
        }
        if p.sex == nil, let t = pc.sex, let s = Profile.Sex(rawValue: t) { p.sex = s }
        func ok(_ v: Double?, _ r: ClosedRange<Double>) -> Double? { v.flatMap { $0.isFinite && r.contains($0) ? $0 : nil } }
        if p.heightCm == nil { p.heightCm = ok(pc.heightCm, heightRange) }
        if p.weightKg == nil { p.weightKg = ok(pc.weightKg, weightRange) }
        if p.hrMaxMeasured == nil { p.hrMaxMeasured = ok(pc.hrMaxMeasured, hrMaxRange) }
        if p.hrRestBaseline == nil { p.hrRestBaseline = ok(pc.hrRestBaseline, hrRestRange) }
        p.fatFreeMassKg = ok(pc.fatFreeMassKg, ffmRange)
        return p
    }

    /// Contract names of the fields that differ (what "arrived later").
    public static func changedFields(from old: Profile, to new: Profile) -> [String] {
        var f: [String] = []
        if old.birthDate != new.birthDate { f.append("birth_date") }
        if old.sex != new.sex { f.append("sex") }
        if old.heightCm != new.heightCm { f.append("height_cm") }
        if old.weightKg != new.weightKg { f.append("weight_kg") }
        if old.hrMaxMeasured != new.hrMaxMeasured { f.append("hr_max_measured") }
        if old.hrRestBaseline != new.hrRestBaseline { f.append("hr_rest_baseline") }
        return f
    }

    /// True when every changed field was empty before (a fill), false when an existing value changed.
    public static func onlyFills(from old: Profile, to new: Profile) -> Bool {
        (old.birthDate == nil || old.birthDate == new.birthDate) && (old.sex == nil || old.sex == new.sex)
            && (old.heightCm == nil || old.heightCm == new.heightCm) && (old.weightKg == nil || old.weightKg == new.weightKg)
            && (old.hrMaxMeasured == nil || old.hrMaxMeasured == new.hrMaxMeasured)
            && (old.hrRestBaseline == nil || old.hrRestBaseline == new.hrRestBaseline)
    }

    /// Lower-case fragments of the blank reasons the phone models write when a profile field is missing.
    public static let profileBlankMarkers = [
        "profile has no", "needs profile.", "needs height", "needs your age", "needs your sex", "sex is not set",
        "settings › profile", "not set in the profile", "birth date",
    ]

    public static func isProfileBlank(_ m: Metric) -> Bool {
        guard m.value == nil, let n = m.note?.lowercased() else { return false }
        return profileBlankMarkers.contains { n.contains($0) }
    }

    /// Days to recompute when profile fields arrived or changed: today and yesterday, plus every stored day (newest
    /// first, at most `limit`) holding a blank whose reason names a missing profile field. A change to an existing
    /// value (not a fill) can change numbers on any day, so then every stored day up to `limit` is returned.
    public static func affectedDays(rows: [(day: LocalDay, metric: Metric)], today: LocalDay, filledOnly: Bool,
                                    limit: Int = 60) -> [LocalDay] {
        var days = Set([today, today.adding(days: -1)])
        for r in rows where !filledOnly || isProfileBlank(r.metric) { days.insert(r.day) }
        return Array(days.sorted(by: >).prefix(max(limit, 2)))
    }
}

/// Which model needs which profile fields (the guard table; mirrors pclab/mglab/profile.py PROFILE_NEEDS).
public enum ProfileNeeds {
    public struct Row: Sendable {
        public let model: String
        public let fields: [String]
        /// Source file (relative to Packages/MGSignal/Sources/MGSignal) where the model reads them.
        public let file: String
    }

    public static let table: [Row] = [
        Row(model: "ALG-106 HRmax (Tanaka / measured)", fields: ["birth_date", "hr_max_measured"], file: "Pipelines/DayPipeline.swift"),
        Row(model: "ALG-133 fitness age", fields: ["birth_date", "sex"], file: "Pipelines/DayPipeline.swift"),
        Row(model: "ALG-048 Mifflin / Keytel calories", fields: ["birth_date", "sex", "height_cm", "weight_kg"],
            file: "Pipelines/DayPipeline.swift"),
        Row(model: "ALG-036 strain / Banister TRIMP / Nes VO2", fields: ["birth_date", "sex", "hr_max_measured"],
            file: "Pipelines/DayPipeline.swift"),
        Row(model: "ALG-134 CosinorAge", fields: ["birth_date", "sex"], file: "Pipelines/InsightMembers.swift"),
        Row(model: "ALG-135 hydration baseline", fields: ["sex"], file: "Pipelines/DayPipeline.swift"),
        Row(model: "Night pipeline", fields: ["birth_date", "sex"], file: "Pipelines/NightPipeline.swift"),
    ]
}
