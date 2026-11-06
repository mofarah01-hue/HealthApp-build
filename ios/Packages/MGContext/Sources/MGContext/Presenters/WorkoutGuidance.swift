import Foundation
import MGDomain

/// T128: the day's recommended workout intensity as a strain range (0-21) and a plain-words band, from this morning's
/// readiness (ALG-160 score 1-100, scored against Mo's own HRV range, sleep and training load), the sleep debt
/// (ALG-115, the sleep plan's ledger) and the day strain so far (ALG-036:fit or the read method). An estimate; the
/// thresholds below are named defaults, not personal numbers (D-046-T128). Pure: same snapshot, same answer.
public enum WorkoutGuidance {
    public enum Band: Int, Sendable, CaseIterable {
        case rest, light, moderate, hard

        public var word: String {
            switch self {
            case .rest: return "rest"
            case .light: return "light"
            case .moderate: return "moderate"
            case .hard: return "hard"
            }
        }

        /// Target strain range of the band, on the 0-21 scale.
        var range: (low: Double, high: Double) {
            switch self {
            case .rest: return (0, 4)
            case .light: return (4, 10)
            case .moderate: return (10, 14)
            case .hard: return (14, 18)
            }
        }
    }

    /// Share of the readiness score (score / 100) at or above which the band is reached.
    public static let hardAtShare = 0.8
    public static let moderateAtShare = 0.6
    public static let lightAtShare = 0.4
    /// A sleep debt at or above this (minutes) lowers the band by one.
    public static let debtDropsBandAtMin = 90.0
    public static let label = "estimate - not WHOOP's number"

    public struct Guidance: Equatable, Sendable {
        public var band: Band?
        public var targetLow: Double?
        public var targetHigh: Double?
        /// Strain still available to the top of the range today; nil when today's strain is unknown.
        public var remaining: Double?
        /// Why there is no advice (blank), nil otherwise.
        public var reason: String?
        public var text: String
    }

    public static func make(_ s: PresenterSnapshot) -> Guidance {
        guard let r = s.recovery else {
            return blank("No readiness yet: it needs last night's sleep and heart rate variability.")
        }
        switch r.status {
        case .learning:
            return blank("Still learning your normal: readiness needs \(RecoveryReading.baselineNightsNeeded) nights of heart rate variability (have \(r.hrvNights)).")
        case .tooLittle:
            return blank("Not enough of last night's readings to judge readiness (needs heart rate variability and 2 more).")
        case .ok:
            break
        }
        guard let score = r.score else { return blank("No readiness score last night.") }
        let share = Double(score) / 100.0
        var band: Band = share >= hardAtShare ? .hard : share >= moderateAtShare ? .moderate
            : share >= lightAtShare ? .light : .rest
        var why = "readiness \(score) of 100"
        if let debt = s.number(.sleepDebt), debt >= debtDropsBandAtMin, let lower = Band(rawValue: band.rawValue - 1) {
            band = lower
            why += ", sleep debt \(Int(debt.rounded())) min"
        }
        let (lo, hi) = band.range
        let range = "strain \(Int(lo))-\(Int(hi))"
        var text = "\(band.word.prefix(1).uppercased() + band.word.dropFirst()) day: aim for \(range) (\(label)); \(why)."
        var remaining: Double?
        if let done = s.dayStrain()?.value, done.isFinite {
            remaining = max(0, hi - done)
            text += remaining == 0 ? " Today's range is already reached."
                : " About \(Int(remaining!.rounded())) left today."
        }
        return Guidance(band: band, targetLow: lo, targetHigh: hi, remaining: remaining, reason: nil, text: text)
    }

    private static func blank(_ reason: String) -> Guidance {
        Guidance(band: nil, targetLow: nil, targetHigh: nil, remaining: nil, reason: reason, text: reason)
    }
}
