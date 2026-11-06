import Foundation

/// Six-answer Fitzpatrick skin phototype quiz. Each answer scores I...VI (1...6); the six scores use the standard
/// 6-point bands: 6 = I, 7...13 = II, 14...20 = III, 21...27 = IV, 28...34 = V, 35...36 = VI.
public enum SkinTypeQuiz {
    public enum SkinType: Int, CaseIterable, Sendable {
        case typeI = 1, typeII, typeIII, typeIV, typeV, typeVI

        public var roman: String { ["I", "II", "III", "IV", "V", "VI"][rawValue - 1] }
    }

    public struct Question: Sendable {
        public var prompt: String
        public var options: [String]

        public init(prompt: String, options: [String]) {
            self.prompt = prompt
            self.options = options
        }
    }

    public static let questions = [
        Question(prompt: "What usually happens when your skin first gets strong sun?",
                 options: ["Always burns painfully", "Burns easily", "Sometimes burns", "Rarely burns",
                           "Very rarely burns", "Never burns"]),
        Question(prompt: "How does your skin tan?",
                 options: ["Never", "Only a little", "Gradually", "Easily", "Very easily", "Deeply"]),
        Question(prompt: "How intense is a sunburn for you?",
                 options: ["Blisters or peels", "Usually peels", "Mild burn", "Minimal burn", "Barely noticeable",
                           "No burn"]),
        Question(prompt: "How deep is your tan after repeated sun?",
                 options: ["No tan", "Light", "Light brown", "Moderate brown", "Dark brown", "Very dark brown"]),
        Question(prompt: "How quickly do you tan?",
                 options: ["Never", "Slowly", "After several exposures", "After a few exposures", "Quickly",
                           "Immediately"]),
        Question(prompt: "How sensitive is your face to sun?",
                 options: ["Very sensitive", "Sensitive", "Somewhat sensitive", "Resistant", "Very resistant",
                           "Never a problem"]),
    ]

    /// Six scores in question order, each 1...6. Incomplete or invalid answers have no result.
    public static func type(for answers: [Int]) -> SkinType? {
        guard answers.count == questions.count, answers.allSatisfy({ (1...6).contains($0) }) else { return nil }
        switch answers.reduce(0, +) {
        case 6: return .typeI
        case 7...13: return .typeII
        case 14...20: return .typeIII
        case 21...27: return .typeIV
        case 28...34: return .typeV
        case 35...36: return .typeVI
        default: return nil
        }
    }
}
