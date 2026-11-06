import Foundation

/// D-RECOV-WALK-2 (Mo, Oct 17 2026): HR recovery is judged against YOUR OWN baseline for that workout type, never a
/// population cut-off. Why: Al Haddad et al. 2011 (IJSPP) measured HRR60 after submaximal exercise with a standard error
/// of measurement of 26.7 % (HRR120 19.5 %), so one reading says little; peak HR is a known driver of HRR (Imai 1994,
/// Pecanha 2017 review), so only workouts that ended near the same peak HR are compared. Pure functions, no I/O.
///
/// Rules (ours, written down so they can be argued with):
///  * baseline = the median HRR60 of up to the last 20 earlier workouts of the SAME type that have a valid HRR60;
///  * under 5 such workouts: "learning", no comparison is shown;
///  * the comparison is shown only when this workout's peak HR is within +-10 bpm of the median peak HR of the baseline;
///  * if the strap says you fell asleep within 90 min after the workout ended, the reading is labelled not comparable
///    and that workout is left out of the baseline (sleep onset pulls HR down by itself).
public enum HRRBaseline {
    public static let minWorkouts = 5
    public static let maxWorkouts = 20
    public static let peakToleranceBpm = 10.0
    public static let sleepAfterMaxMin = 90

    public struct Entry: Equatable, Sendable {
        /// `typeKey(...)` of the workout's activity type.
        public var typeKey: String
        /// HR drop 60 s after the end, bpm (ALG-012).
        public var hrr60: Double
        /// Peak HR in the 30 s before the end, bpm.
        public var peak: Double
        public var end: Date
        /// Minutes between the workout end and the strap's asleep flag, when 90 or fewer (`sleepAfterMinutes`).
        public var sleepAfterMin: Int?

        public init(typeKey: String, hrr60: Double, peak: Double, end: Date, sleepAfterMin: Int? = nil) {
            self.typeKey = typeKey
            self.hrr60 = hrr60
            self.peak = peak
            self.end = end
            self.sleepAfterMin = sleepAfterMin
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// Fewer than `minWorkouts` comparable earlier workouts of this type: no comparison.
        case learning(n: Int)
        /// This workout's peak HR is not within the tolerance of the baseline workouts' peak HR.
        case peakMismatch(thisPeak: Double, baselinePeak: Double, n: Int)
        /// Fell asleep this many minutes after the workout: the reading is not comparable.
        case confounded(sleepAfterMin: Int)
        /// `delta` = this HRR60 minus the baseline median; both in bpm; `n` baseline workouts.
        case compared(delta: Double, median: Double, n: Int)

        /// One short line for the workout screen. `type` is the readable type name ("strength").
        public func caption(type: String) -> String {
            switch self {
            case .learning(let n):
                return "Learning your \(type) baseline: \(n) of \(HRRBaseline.minWorkouts) earlier workouts so far, "
                    + "no comparison yet."
            case .peakMismatch(let mine, let base, let n):
                return "Not compared: peak HR \(Int(mine.rounded())) bpm vs about \(Int(base.rounded())) bpm in your last "
                    + "\(n) \(type) workouts (peak HR drives recovery; the gap is over \(Int(HRRBaseline.peakToleranceBpm)) bpm)."
            case .confounded(let m):
                return "Went to sleep \(m) min after, recovery reading not comparable."
            case .compared(let delta, let median, let n):
                let sign = delta > 0.5 ? "+" : (delta < -0.5 ? "\u{2212}" : "\u{00B1}")
                let mag = Int(abs(delta).rounded())
                return "\(sign)\(mag) bpm vs your median \(Int(median.rounded())) bpm for \(type) (n=\(n)). "
                    + "One reading is noisy (Al Haddad 2011, error about 27 %): watch the trend."
            }
        }
    }

    /// Lowercased, trimmed activity type; an empty or missing one is "workout".
    public static func typeKey(_ raw: String?) -> String {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? "workout" : t
    }

    /// Whole minutes from the workout end to the first sleep start (the strap's asleep flag, via the night's sleep
    /// onset) when that start is at or after the end and at most `sleepAfterMaxMin` minutes later; else nil.
    public static func sleepAfterMinutes(endTs: Double, sleepStartTs: [Double]) -> Int? {
        let later = sleepStartTs.filter { $0.isFinite && $0 >= endTs }
        guard let first = later.min() else { return nil }
        let m = Int(((first - endTs) / 60).rounded())
        return m <= sleepAfterMaxMin ? m : nil
    }

    public static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return .nan }
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// The baseline workouts for `current`: same type, earlier, finite HRR60 and peak, not followed by sleep within 90 min,
    /// newest `maxWorkouts`.
    public static func baselineSet(for current: Entry, history: [Entry]) -> [Entry] {
        let ok = history.filter {
            $0.typeKey == current.typeKey && $0.end < current.end && $0.hrr60.isFinite && $0.hrr60 > 0
                && $0.peak.isFinite && ($0.sleepAfterMin.map { $0 > sleepAfterMaxMin } ?? true)
        }
        return Array(ok.sorted { $0.end > $1.end }.prefix(maxWorkouts))
    }

    public static func compare(_ current: Entry, history: [Entry]) -> Verdict {
        if let m = current.sleepAfterMin, m <= sleepAfterMaxMin { return .confounded(sleepAfterMin: m) }
        let base = baselineSet(for: current, history: history)
        guard base.count >= minWorkouts else { return .learning(n: base.count) }
        let basePeak = median(base.map(\.peak))
        guard abs(current.peak - basePeak) <= peakToleranceBpm else {
            return .peakMismatch(thisPeak: current.peak, baselinePeak: basePeak, n: base.count)
        }
        let med = median(base.map(\.hrr60))
        return .compared(delta: current.hrr60 - med, median: med, n: base.count)
    }
}
