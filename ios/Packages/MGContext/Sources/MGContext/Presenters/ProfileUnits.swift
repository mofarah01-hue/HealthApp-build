import Foundation

// MARK: - Profile units (T3/T111, app/docs/T-LIST-v2.md, 2026-10-12)
//
// Mo types and reads pounds and feet/inches; the app stores metric (weight_kg, height_cm). A bare weight number is
// pounds. A bare height number is refused (58 could be inches or cm) — it needs a feet marker or "cm". Stored values
// are kept unrounded so that a whole lb / whole inch typed in is shown back unchanged.

public enum ProfileUnits {
    static let kgPerLb = 0.45359237
    static let cmPerInch = 2.54

    /// The sanity ranges of T3, on the stored metric value. Not part of the public four (T-LIST-v2.md T3/T111).
    static let weightRangeKg: ClosedRange<Double> = 30...300
    static let heightRangeCm: ClosedRange<Double> = 100...250

    /// "155", "155 lb", "155lbs" → kg; "70.3 kg" → kg. nil for junk or outside 30...300 kg.
    public static func parseWeightKg(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        var inKg = false
        // longest suffix first ("kilograms" before "kg"); the unit may be written out ("155 pounds")
        for unit in ["kilograms", "kilogram", "kgs", "kg"] where t.hasSuffix(unit) { t.removeLast(unit.count); inKg = true; break }
        if !inKg {
            for unit in ["pounds", "pound", "lbs", "lb"] where t.hasSuffix(unit) { t.removeLast(unit.count); break }
        }
        guard let n = plainNumber(t.trimmingCharacters(in: .whitespaces)) else { return nil }
        let kg = inKg ? n : n * kgPerLb
        return weightRangeKg.contains(kg) ? kg : nil
    }

    /// "5'8", "5′8″", "5 ft 8 in", "5 8", "6'" → cm; "172 cm" → cm. nil for junk, a bare number, or outside
    /// 100...250 cm (feet 3...8, inches 0...11).
    public static func parseHeightCm(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        for unit in ["centimeters", "centimetres", "centimeter", "centimetre", "cm"] where t.hasSuffix(unit) {
            t.removeLast(unit.count)
            guard let n = plainNumber(t.trimmingCharacters(in: .whitespaces)) else { return nil }
            return heightRangeCm.contains(n) ? n : nil
        }
        // words before the short forms: "inches" contains "in", "feet" must not be left as "fe" + "et"
        for (from, to) in [("′", "'"), ("’", "'"), ("″", ""), ("\"", ""), ("feet", "'"), ("foot", "'"), ("ft", "'"),
                           ("inches", ""), ("inch", ""), ("in", ""), (".", ""), (",", "")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        guard let first = t.first, first.isASCII, first.isNumber,
              t.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "'" || $0 == " " }) else { return nil }
        let parts = t.split(whereSeparator: { $0 == "'" || $0 == " " }).compactMap { Int($0) }
        let marked = t.contains("'")
        let feet: Int
        let inches: Int
        switch parts.count {
        case 1 where marked: (feet, inches) = (parts[0], 0)
        case 2: (feet, inches) = (parts[0], parts[1])
        default: return nil   // a bare "58" is ambiguous; three numbers are junk
        }
        guard (3...8).contains(feet), (0...11).contains(inches) else { return nil }
        let cm = Double(feet * 12 + inches) * cmPerInch
        return heightRangeCm.contains(cm) ? cm : nil
    }

    /// "155 lb"; "—" when unknown.
    public static func weightText(kg: Double?) -> String {
        guard let kg, kg.isFinite else { return "—" }
        return "\(Int((kg / kgPerLb).rounded())) lb"
    }

    /// "5′8″"; "—" when unknown.
    public static func heightText(cm: Double?) -> String {
        guard let cm, cm.isFinite else { return "—" }
        let inches = Int((cm / cmPerInch).rounded())
        return "\(inches / 12)′\(inches % 12)″"
    }

    /// Digits with at most one ".", nothing else (so "nan", "inf", "1e3" and "-5" are not numbers). Locale-independent.
    private static func plainNumber(_ s: String) -> Double? {
        guard !s.isEmpty, s.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
              s.filter({ $0 == "." }).count <= 1 else { return nil }
        return Double(s)
    }
}
