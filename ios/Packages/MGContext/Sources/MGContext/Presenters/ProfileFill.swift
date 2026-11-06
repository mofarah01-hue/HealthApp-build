import Foundation
import MGDomain

// Settings › Profile › "Use values from Apple Health (via your PC)" (tracker #90, 2026-10-11). The PC derives birth date,
// sex, height and weight from Mo's Apple Health export (pclab mglab/profile_derive.py) and serves the merged profile with
// a source per field (GET /v1/profile). After Mo taps, the app fills ONLY the fields Settings › Profile leaves empty;
// anything Mo typed stays. A PC value outside the range Settings accepts when typed (AppModel+Settings ProfileParsing)
// is not filled and is named, so a unit slip never lands in the profile.

/// The PC's merged profile as the app hands it to `ProfileFill` (MGSync `PCProfile`, mapped by the app).
public struct PCProfileValues: Equatable, Sendable {
    public var birthDate: String?
    public var sex: String?
    public var heightCm: Double?
    public var weightKg: Double?
    public var hrMaxMeasured: Double?
    public var hrRestBaseline: Double?
    /// Contract field name → where the PC got it.
    public var sources: [String: String]

    public init(birthDate: String? = nil, sex: String? = nil, heightCm: Double? = nil, weightKg: Double? = nil,
                hrMaxMeasured: Double? = nil, hrRestBaseline: Double? = nil, sources: [String: String] = [:]) {
        self.birthDate = birthDate
        self.sex = sex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.hrMaxMeasured = hrMaxMeasured
        self.hrRestBaseline = hrRestBaseline
        self.sources = sources
    }
}

public enum ProfileFill {
    public struct Outcome: Equatable, Sendable {
        public var profile: Profile
        /// "Birth date 1990-05-04 (Apple Health export (derived 2026-10-11))", one per filled field.
        public var filled: [String]
        /// Fields the PC has that were not filled, with why ("Height: you already set it").
        public var kept: [String]
        /// PC values refused (out of range / unreadable), with why.
        public var refused: [String]
    }

    /// Same ranges Settings accepts when Mo types the value (ProfileParsing).
    static let heightRange = 100.0...250.0
    static let weightRange = 30.0...300.0
    static let hrMaxRange = 100.0...240.0
    static let hrRestRange = 25.0...120.0

    /// T27: true while any field the PC can fill is empty, i.e. while asking the PC could change something.
    public static func hasGaps(_ p: Profile) -> Bool {
        p.birthDate == nil || p.sex == nil || p.heightCm == nil || p.weightKg == nil
            || p.hrMaxMeasured == nil || p.hrRestBaseline == nil
    }

    public static func fill(_ phone: Profile, from pc: PCProfileValues, today: LocalDay) -> Outcome {
        var p = phone
        var out = Outcome(profile: phone, filled: [], kept: [], refused: [])
        func src(_ field: String) -> String { pc.sources[field].map { " (\($0))" } ?? "" }

        if let text = pc.birthDate {
            if p.birthDate != nil {
                out.kept.append("Birth date: you already set it")
            } else if let d = LocalDay(iso: text), d <= today, d.year >= today.year - 120 {
                p.birthDate = d
                out.filled.append("Birth date \(d.iso)\(src("birth_date"))")
            } else {
                out.refused.append("Birth date '\(text)' is not a date in the last 120 years")
            }
        }
        if let text = pc.sex {
            if p.sex != nil {
                out.kept.append("Sex: you already set it")
            } else if let s = Profile.Sex(rawValue: text) {
                p.sex = s
                out.filled.append("Sex \(s.rawValue)\(src("sex"))")
            } else {
                out.refused.append("Sex '\(text)' is not male, female or other")
            }
        }
        func number(_ v: Double?, _ current: Double?, _ range: ClosedRange<Double>, _ field: String, _ label: String,
                    _ unit: String, shown: ((Double) -> String)? = nil, _ set: (Double) -> Void) {
            guard let v else { return }
            if current != nil {
                out.kept.append("\(label): you already set it")
            } else if v.isFinite, range.contains(v) {
                set(v)
                let text = shown?(v) ?? "\(MGFormat.number(v, decimals: v == v.rounded() ? 0 : 1)) \(unit)"
                out.filled.append("\(label) \(text)\(src(field))")
            } else if let shown {
                // T3/T111: weight and height are said in lb / ft-in even when refused; the stored value stays metric.
                out.refused.append("\(label) \(shown(v)) is outside what Settings accepts")
            } else {
                out.refused.append("\(label) \(v) \(unit) is outside \(Int(range.lowerBound))–\(Int(range.upperBound))")
            }
        }
        // T3/T111: Mo reads feet-inches and pounds; the stored value stays cm / kg.
        number(pc.heightCm, p.heightCm, heightRange, "height_cm", "Height", "cm",
               shown: { ProfileUnits.heightText(cm: $0) }) { p.heightCm = $0 }
        number(pc.weightKg, p.weightKg, weightRange, "weight_kg", "Weight", "kg",
               shown: { ProfileUnits.weightText(kg: $0) }) { p.weightKg = $0 }
        number(pc.hrMaxMeasured, p.hrMaxMeasured, hrMaxRange, "hr_max_measured", "Max heart rate", "bpm") {
            p.hrMaxMeasured = $0
        }
        number(pc.hrRestBaseline, p.hrRestBaseline, hrRestRange, "hr_rest_baseline", "Resting heart rate", "bpm") {
            p.hrRestBaseline = $0
        }
        out.profile = p
        return out
    }

    /// The notice after the tap: what was filled, what was kept, what was refused; or that there was nothing to fill.
    public static func notice(_ o: Outcome) -> String {
        var parts: [String] = []
        if o.filled.isEmpty {
            parts.append(o.kept.isEmpty && o.refused.isEmpty ? "Your PC has no profile values yet (import the Apple "
                         + "Health export there first)." : "Nothing filled.")
        } else {
            parts.append("Filled: " + o.filled.joined(separator: "; ") + ".")
        }
        if !o.kept.isEmpty { parts.append("Kept yours: " + o.kept.map { $0.components(separatedBy: ":")[0] }
            .joined(separator: ", ") + ".") }
        if !o.refused.isEmpty { parts.append("Not used: " + o.refused.joined(separator: "; ") + ".") }
        return parts.joined(separator: " ")
    }
}
