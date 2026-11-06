import Foundation
import MGContext
import MGDomain

// Pure helpers for the Log tab: text, "happened at" arithmetic and the plain-word vocabularies.
// No SwiftUI here, so every function can be unit-tested on a Mac (proposed tests are listed in the WP-18 report).

enum LogText {
    /// 200 → "200", 0.5 → "0.5", 2.25 → "2.25". Locale independent.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == value.rounded(), abs(value) < 1_000_000 { return String(Int(value)) }
        return String(format: "%g", value)
    }

    /// A typed number: "12.5" or "12,5". nil for empty, negative, NaN or text.
    static func parse(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let v = Double(t), v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// "07:15" in the phone's calendar (24 h, UX §1.3).
    static func time(_ date: Date, _ calendar: Calendar) -> String { MGFormat.time(date, calendar: calendar) }

    /// Trimmed text, nil when empty.
    static func clean(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "a, b ,, c" → ["a", "b", "c"].
    static func tags(_ text: String) -> [String] {
        text.split(separator: ",").compactMap { clean(String($0)) }
    }
}

/// "Happened at" for a NEW entry (APP-082): now, minus 5 / 15 / 30 / 60 minutes, or a time from the wheel.
/// The wheel gives a clock time only; a clock time that is still ahead of now means yesterday's (a late-night entry
/// logged after midnight).
struct LogHappenedAt: Equatable {
    var minutesAgo: Int = 0
    /// Only the hour and minute are used.
    var clock: Date?

    var isNow: Bool { clock == nil && minutesAgo == 0 }

    func resolved(now: Date, calendar: Calendar) -> Date {
        if let clock {
            let c = calendar.dateComponents([.hour, .minute], from: clock)
            let today = calendar.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: now) ?? now
            if today > now { return calendar.date(byAdding: .day, value: -1, to: today) ?? today }
            return today
        }
        return now.addingTimeInterval(-Double(max(0, minutesAgo)) * 60)
    }
}

enum LogTime {
    /// An existing entry moved to the clock time of `clock`, on the entry's own day.
    static func moving(_ original: Date, toClockOf clock: Date, calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.hour, .minute], from: clock)
        return calendar.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: original) ?? original
    }

    /// Whole minutes from `a` to `b` (negative = b is earlier). Rounded to the nearest minute.
    static func minutes(from a: Date, to b: Date) -> Int {
        Int((b.timeIntervalSince(a) / 60).rounded())
    }
}

// MARK: - Vocabularies (plain words; the contract stores the matching codes)

/// Stool in plain words → Bristol 1…7 (APP-081 "stool in plain words (stored as Bristol)").
/// Descriptions paraphrase the Bristol Stool Form Scale (Lewis & Heaton 1997); they describe, never judge.
struct LogStoolChoice: Identifiable, Hashable {
    let word: SymptomFields.StoolWord
    let bristol: Int
    let label: String
    let plain: String
    var id: Int { bristol }
}

struct LogKindChoice: Identifiable, Hashable {
    let kind: SymptomFields.Kind
    let label: String
    var id: String { kind.rawValue }
}

struct LogFoodTag: Identifiable, Hashable {
    let id: String
    let label: String
}

enum LogVocabulary {
    static let stool: [LogStoolChoice] = [
        LogStoolChoice(word: .hardLumps, bristol: 1, label: "hard lumps", plain: "separate hard lumps, like nuts"),
        LogStoolChoice(word: .lumpy, bristol: 2, label: "lumpy", plain: "sausage-shaped but lumpy"),
        LogStoolChoice(word: .solid, bristol: 3, label: "solid", plain: "sausage-shaped with cracks on the surface"),
        LogStoolChoice(word: .soft, bristol: 4, label: "soft", plain: "smooth, soft sausage or snake"),
        LogStoolChoice(word: .semiSolid, bristol: 5, label: "semi-solid", plain: "soft blobs with clear edges"),
        LogStoolChoice(word: .runny, bristol: 6, label: "runny", plain: "mushy, fluffy pieces with ragged edges"),
        LogStoolChoice(word: .veryRunny, bristol: 7, label: "very runny", plain: "watery, no solid pieces"),
    ]

    /// Gut symptoms rated 0–3 (APP-081).
    static let gut: [LogKindChoice] = [
        LogKindChoice(kind: .bloating, label: "bloating"),
        LogKindChoice(kind: .gutPain, label: "pain"),
        LogKindChoice(kind: .urgency, label: "urgency"),
        LogKindChoice(kind: .nausea, label: "nausea"),
    ]

    static let severityWords: [String] = ["none", "mild", "moderate", "severe"]

    /// Swallowing (APP-081): stored as kind `swallowing` with this text in `detail`.
    static let swallowing: [String] = ["hard swallow", "pain", "food sticking"]

    /// Karolinska Sleepiness Scale (Åkerstedt & Gillberg 1990): short word for the button, full wording for the caption.
    static let kssShort: [Int: String] = [
        1: "extremely alert", 2: "very alert", 3: "alert", 4: "rather alert", 5: "neither",
        6: "some signs of sleepiness", 7: "sleepy, no effort", 8: "sleepy, some effort", 9: "fighting sleep",
    ]

    static let kssFull: [Int: String] = [
        1: "Extremely alert", 2: "Very alert", 3: "Alert", 4: "Rather alert", 5: "Neither alert nor sleepy",
        6: "Some signs of sleepiness", 7: "Sleepy, but no effort to keep awake",
        8: "Sleepy, some effort to keep awake", 9: "Very sleepy, great effort to keep awake, fighting sleep",
    ]

    /// Energy / focus / mood 1–5.
    static let scale5: [Int: String] = [1: "very low", 2: "low", 3: "middle", 4: "high", 5: "very high"]

    /// Contract foodEvent tags (dairy, wheat_gluten, high_fodmap, sugar_alcohols, spicy, fried_fatty, alcohol, caffeine)
    /// plus the eosinophilic-oesophagitis set (UX §7 "incl. the EoE set"): egg, soy, nuts, fish / shellfish.
    static let foodTags: [LogFoodTag] = [
        LogFoodTag(id: "dairy", label: "dairy"),
        LogFoodTag(id: "wheat_gluten", label: "wheat / gluten"),
        LogFoodTag(id: "egg", label: "egg"),
        LogFoodTag(id: "soy", label: "soy"),
        LogFoodTag(id: "nuts", label: "nuts"),
        LogFoodTag(id: "fish_shellfish", label: "fish / shellfish"),
        LogFoodTag(id: "high_fodmap", label: "high-FODMAP"),
        LogFoodTag(id: "sugar_alcohols", label: "sugar alcohols"),
        LogFoodTag(id: "spicy", label: "spicy"),
        LogFoodTag(id: "fried_fatty", label: "fried / fatty"),
        LogFoodTag(id: "alcohol", label: "alcohol"),
        LogFoodTag(id: "caffeine", label: "caffeine"),
    ]
}
