import Foundation

/// T80 (data side): what each describer said about one meal or drink photo, and how the answers compare. Kept on the
/// phone. The record holds a photo id, never the photo. Nothing here sends a photo anywhere or calls a model API; the
/// on-device describer goes through `OnDeviceModelHook` (T83). Gemini and Codex are not describers (decision D-042-T80).
public enum PhotoEstimateSource: String, Codable, CaseIterable, Sendable {
    case onDevice = "on_device", localModel = "local_model", claude, chatGPT = "chatgpt"

    public var name: String {
        switch self {
        case .onDevice: return "On-device model"
        case .localModel: return "Local model"
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        }
    }
}

public enum PhotoConfidence: String, Codable, Sendable { case low, medium, high }

public struct PhotoEstimate: Codable, Equatable, Sendable {
    public var photoID: String
    public var source: PhotoEstimateSource
    public var foodDescription: String
    public var kcalLow: Double
    public var kcalHigh: Double
    public var confidence: PhotoConfidence
    public var at: Date

    public var kcalMid: Double { (kcalLow + kcalHigh) / 2 }
    /// Every figure is a range with a confidence label, worded as an estimate.
    public var rangeLine: String {
        "estimate \(MGFormat.number(kcalLow, decimals: 0))–\(MGFormat.number(kcalHigh, decimals: 0)) kcal · \(confidence.rawValue) confidence"
    }
}

public struct PhotoComparison: Equatable, Sendable {
    public enum Agreement: Equatable, Sendable { case single, agree, disagree }
    public var agreement: Agreement
    /// The calorie range every describer's range includes; nil when they do not all overlap.
    public var commonRange: (low: Double, high: Double)?
    /// Distance of each describer's mid-point from the reference; empty without a reference.
    public var errors: [PhotoEstimateSource: Double]
    /// Named only when a known-calorie reference (a label or a weighed meal) was given.
    public var closest: PhotoEstimateSource?
    public var note: String

    public static func == (a: PhotoComparison, b: PhotoComparison) -> Bool {
        a.agreement == b.agreement && a.commonRange?.low == b.commonRange?.low && a.commonRange?.high == b.commonRange?.high
            && a.errors == b.errors && a.closest == b.closest && a.note == b.note
    }
}

public struct PhotoEstimateSet: Equatable, Sendable {
    public var estimates: [PhotoEstimate]
    public init(estimates: [PhotoEstimate]) { self.estimates = estimates }

    /// A re-run by the same describer replaces its earlier answer.
    public var latestPerSource: [PhotoEstimate] {
        Dictionary(grouping: estimates, by: \.source).values
            .compactMap { $0.max { $0.at < $1.at } }
            .sorted { $0.source.rawValue < $1.source.rawValue }
    }

    public func compare(referenceKcal: Double?) -> PhotoComparison {
        let list = latestPerSource
        let low = list.map(\.kcalLow).max(), high = list.map(\.kcalHigh).min()
        let common = (low != nil && high != nil && low! <= high!) ? (low: low!, high: high!) : nil
        let agreement: PhotoComparison.Agreement = list.count < 2 ? .single : (common == nil ? .disagree : .agree)
        var errors: [PhotoEstimateSource: Double] = [:]
        if let ref = referenceKcal { for e in list { errors[e.source] = abs(e.kcalMid - ref) } }
        let closest = errors.min { $0.value < $1.value || ($0.value == $1.value && $0.key.rawValue < $1.key.rawValue) }?.key
        let note = referenceKcal == nil
            ? "Photo calorie estimates are rough; only agreement is measured. Weigh the meal or use a label to rate a model."
            : "Closest to the reference by mid-point; one meal does not make a model better."
        return PhotoComparison(agreement: agreement, commonRange: common, errors: errors, closest: closest, note: note)
    }
}

public enum MealPhotoEstimates {
    /// Only Mo's note goes into the prompt: no location, no health data, no profile.
    public static func prompt(note: String) -> String {
        "Describe this meal or drink in one line and estimate its calories as a range. Note: \(note)\n"
            + "Reply exactly as three lines:\nDESCRIPTION: <what it is>\nKCAL: <low>-<high>\nCONFIDENCE: low|medium|high"
    }

    public static func ask(_ hook: OnDeviceModelHook, photoID: String, note: String, at: Date) async -> PhotoEstimate? {
        guard case let .answer(text) = await hook.ask(prompt(note: note)) else { return nil }
        return parse(text, photoID: photoID, source: .onDevice, at: at)
    }

    /// A reply with no usable positive range is no estimate. A missing or unknown label is low.
    public static func parse(_ text: String, photoID: String, source: PhotoEstimateSource, at: Date) -> PhotoEstimate? {
        func value(_ key: String) -> String? {
            text.split(whereSeparator: \.isNewline).lazy
                .compactMap { line -> String? in
                    let s = line.trimmingCharacters(in: .whitespaces)
                    return s.uppercased().hasPrefix(key + ":") ? String(s.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) : nil
                }.first
        }
        guard let kcal = value("KCAL") else { return nil }
        let numbers = kcal.replacingOccurrences(of: ",", with: "").split(whereSeparator: { !($0.isNumber || $0 == ".") }).compactMap { Double($0) }
        guard !kcal.hasPrefix("-"), numbers.count == 2, numbers.allSatisfy({ $0 > 0 }) else { return nil }
        let confidence = value("CONFIDENCE").flatMap { PhotoConfidence(rawValue: $0.lowercased()) } ?? .low
        return PhotoEstimate(photoID: photoID, source: source, foodDescription: value("DESCRIPTION") ?? "",
                             kcalLow: numbers.min()!, kcalHigh: numbers.max()!, confidence: confidence, at: at)
    }
}
