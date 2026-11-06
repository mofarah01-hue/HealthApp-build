import Foundation

// R9m (D-HRV-WALK-2, Oct 17 2026): "Predicted alertness (model estimate)" and the two-week check of it against Mo's own
// 3-minute reaction tests. MGSignal's AlertnessCheck does the maths (Spearman rank correlation of the prediction stored with
// each test against the negative mean reaction time; MGContext cannot import MGSignal, so AppModel hands the result in as
// this plain struct). This file only words it. One screen (the existing reaction test), one intent (.startReactionTest).

/// What the app knows about the self-check at snapshot time.
public struct AlertnessSelfCheck: Equatable, Sendable {
    /// Reaction tests in the last 14 days that carry a stored prediction, and on how many different days.
    public var checks: Int
    public var days: Int
    /// Present once there are enough checks (10 on 5 days): the rank correlation and its 95 % range.
    public var rho: Double?
    public var low: Double?
    public var high: Double?
    /// The lower end of the range is above 0.
    public var tracks: Bool?
    /// The thresholds (AlertnessCheck.minChecks / minDays / windowDays), so wording and maths cannot drift apart.
    public var minChecks: Int
    public var minDays: Int
    public var windowDays: Int

    public init(checks: Int, days: Int, rho: Double? = nil, low: Double? = nil, high: Double? = nil, tracks: Bool? = nil,
                minChecks: Int = 10, minDays: Int = 5, windowDays: Int = 14) {
        self.checks = checks
        self.days = days
        self.rho = rho
        self.low = low
        self.high = high
        self.tracks = tracks
        self.minChecks = minChecks
        self.minDays = minDays
        self.windowDays = windowDays
    }
}

enum AlertnessSelfCheckPresenter {
    static let title = "Predicted alertness: a model estimate, not a measurement"

    /// The plain-words block on the alertness screen: what it is, how it is checked, where the check stands.
    static func lines(_ c: AlertnessSelfCheck?) -> [String] {
        var out = [
            "A model estimate, not a measurement: the published Unified Model of Performance (Ramakrishnan 2016) run on "
                + "your recent sleep and the caffeine you logged. The paper's error is for group averages (6 to 27 %); "
                + "for you it is unproven.",
            "To check it on you, take the 3-minute reaction test a few times a day for two weeks. Each test keeps what "
                + "the model predicted for that moment. If the model does not track your reaction times it is dropped.",
        ]
        guard let c else { return out + ["Self-check: no reaction tests with a stored prediction yet."] }
        guard let rho = c.rho, let low = c.low, let high = c.high else {
            let days = c.days == 1 ? "1 day" : "\(c.days) different days"
            out.append("Self-check: \(c.checks) of \(c.minChecks) reaction tests so far, on \(days) (needs \(c.minDays) "
                       + "different days within \(c.windowDays) days). No agreement is shown before that.")
            return out
        }
        func n(_ v: Double) -> String { MGFormat.number(v, decimals: 2) }
        out.append("Self-check, last \(c.windowDays) days: \(c.checks) tests on \(c.days) days. Agreement of the prediction with "
                   + "your reaction times (rank correlation, 1 = same order, 0 = none, below 0 = opposite): \(n(rho)), "
                   + "95 % range \(n(low)) to \(n(high)).")
        out.append(c.tracks == true
            ? "So far the model tracks you: even the low end of the range is above 0."
            : "The model is not shown to track you yet: the low end of the range reaches down to 0 or below. More tests narrow the range.")
        return out
    }
}
