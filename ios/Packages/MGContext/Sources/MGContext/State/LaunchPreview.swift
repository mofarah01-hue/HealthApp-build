import Foundation

/// R7 / T23 (Mo: "preload the app so it opens faster"): the front page as it was when the app last finished a refresh,
/// kept as a small file and drawn at once on the next launch while the real Today is still being built. It is text only:
/// the header, the verdict and the first strip's values. Nothing is recomputed from it, and it is replaced by the real
/// Today as soon as that exists.
///
/// Every value keeps its mark (an estimate says "est.", research says so); raw strap counts and blanks are left out, so
/// nothing is shown here that the real screen would not show with a label.
public struct LaunchPreview: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var label: String
        /// "62 ms est." — value, unit and mark as one line.
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// A saved front page older than this is not shown (it would read as today's).
    public static let maxAge: TimeInterval = 36 * 3600

    public var savedAt: Date
    public var kicker: String
    public var title: String
    public var headline: String
    public var sentence: String?
    public var stripTitle: String
    public var items: [Item]

    public init(savedAt: Date, kicker: String, title: String, headline: String, sentence: String?, stripTitle: String,
                items: [Item]) {
        self.savedAt = savedAt
        self.kicker = kicker
        self.title = title
        self.headline = headline
        self.sentence = sentence
        self.stripTitle = stripTitle
        self.items = items
    }

    /// nil for SAMPLE data (never kept for the next launch).
    public init?(from today: TodayState, savedAt: Date) {
        guard !today.sample else { return nil }
        var items: [Item] = []
        for v in today.primaryStrip.items {
            guard case let .value(text, unit, _, style, sample) = v.value, !sample else { continue }
            var line = unit.map { text + " " + $0 } ?? text
            switch style {
            case .strapRaw:
                continue
            case .estimate(let spread):
                line += " " + EstimateMark.text(spread, valueText: text)
            case .research:
                line += " (research)"
            case .measured, .plain:
                break
            }
            items.append(Item(label: v.label, value: line))
        }
        self.init(savedAt: savedAt, kicker: today.header.kicker, title: today.header.title,
                  headline: today.verdict.headline, sentence: today.verdict.sentence,
                  stripTitle: today.primaryStrip.title, items: items)
    }

    /// Saved in the past, and not too long ago (a clock set back or a day-old file is not shown).
    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= 0 && age <= Self.maxAge
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> LaunchPreview? { try? JSONDecoder().decode(LaunchPreview.self, from: data) }
}
