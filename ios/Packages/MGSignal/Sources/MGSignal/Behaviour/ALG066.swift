import Foundation

/// ALG-066 v1 — EAT-10 swallowing score. Belafsky et al. 2008 (Ann Otol Rhinol Laryngol 117:919–924): ten items, each
/// 0 (no problem) to 4 (severe problem), total 0–40; a total of 3 or more is abnormal. A symptom screen validated
/// against videofluoroscopy — not a diagnosis; for EoE the per-meal events and your GI decide.
/// Python reference: app/pclab/mglab/ref/behaviour.py `eat10`; goldens app/shared/golden/behaviour/ALG-066.json.
public enum ALG066 {
    public static let method = "ALG-066@1 eat-10"
    public static let citation = "Belafsky PC et al. Ann Otol Rhinol Laryngol 2008;117(12):919-924"
    public static let itemCount = 10
    public static let abnormalAt = 3

    public struct Score: Sendable, Equatable {
        public var total: Int
        public var abnormal: Bool

        public init(total: Int, abnormal: Bool) {
            self.total = total
            self.abnormal = abnormal
        }
    }

    /// ALG-066 v1 — `items` = the ten answers in order; nil = not answered. Missing unless all ten are whole numbers 0–4.
    public static func score(items: [Int?]) -> Computed<Score> {
        guard items.count == itemCount else { return .missing("EAT-10 has \(itemCount) items (got \(items.count))") }
        var total = 0
        for (i, v) in items.enumerated() {
            guard let value = v else { return .missing("item \(i + 1) is not answered") }
            guard (0...4).contains(value) else { return .missing("item \(i + 1) must be a whole number from 0 to 4") }
            total += value
        }
        return .success(Score(total: total, abnormal: total >= abnormalAt))
    }
}
