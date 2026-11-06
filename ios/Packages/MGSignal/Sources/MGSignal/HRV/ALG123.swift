import Foundation
import MGDomain

/// ALG-123 — the "body arousal" family (key `stress`, group G-STRESS; Mo, D-HRV-WALK-1/2, Oct 17 2026: stress -> body
/// arousal). The shown metric is `ALG123Daytime` (daytime HR / HRV against your own baseline, motion-gated).
/// R9m (D-HRV-R9M): the noop daily 0–3 (`daily`), the overnight Baevsky 0–100 (ALG123Overnight) and the chronic drift
/// (ALG123Chronic) are REMOVED as duplicates / made-up; the Baevsky index is no longer a shown metric (its spec and
/// pipeline row are gone). Only the pure `baevsky` function stays, because ALG-107 and `HRVWindows` still call it
/// (ALG-107 is on builder r9l's removal list; delete this function when it goes).
/// Python reference: app/pclab/mglab/ref/hrv.py `baevsky_si`, `window_median_si`; goldens app/shared/golden/hrv/ALG-123.json.
public enum ALG123 {
    // MARK: Baevsky stress index (variant "ALG-123:baevsky")

    public static let baevskyCitation = "Baevsky RM, Chernikova AG. Hum Physiol 2017;43:796-803; Baevsky 2008"
    public static let binMs = 50.0
    public static let minBeats = 20

    public struct Baevsky: Sendable, Equatable {
        /// SI = AMo / (2 · Mo · MxDMn), dimensionless (classic form, not Kubios' square root).
        public var si: Double
        /// Centre of the fullest 50 ms bin, seconds.
        public var moS: Double
        /// Share of intervals in that bin, %.
        public var amoPct: Double
        /// max − min R-R, seconds.
        public var mxdmnS: Double

        public init(si: Double, moS: Double, amoPct: Double, mxdmnS: Double) {
            self.si = si
            self.moS = moS
            self.amoPct = amoPct
            self.mxdmnS = mxdmnS
        }
    }

    /// ALG-123:baevsky v1 — histogram of R-R in 50 ms bins on the fixed grid [k·50, (k+1)·50) ms; Mo = centre of the
    /// fullest bin (ties → lowest bin); AMo = % of intervals in it; MxDMn = max − min. Kubios reports √SI and takes
    /// Mo as the median; we keep Baevsky's form. Missing below 20 beats or with no spread.
    public static func baevsky(rrMs rr: [Double]) -> Computed<Baevsky> {
        let n = rr.count
        guard n >= minBeats else { return .missing("needs at least \(minBeats) beats (have \(n))") }
        var counts: [Int: Int] = [:]
        for v in rr { counts[Int((v / binMs).rounded(.down)), default: 0] += 1 }
        var bestK = Int.max
        var bestCount = 0
        for k in counts.keys.sorted() where counts[k]! > bestCount {
            bestCount = counts[k]!
            bestK = k
        }
        let mo = (Double(bestK) + 0.5) * binMs / 1000.0
        let amo = 100.0 * Double(bestCount) / Double(n)
        let mxdmn = (rr.max()! - rr.min()!) / 1000.0
        guard mxdmn > 0 else { return .missing("all intervals equal: SI undefined") }
        return .success(Baevsky(si: amo / (2.0 * mo * mxdmn), moS: mo, amoPct: amo, mxdmnS: mxdmn))
    }

    /// ALG-123:baevsky over a span (day or night): median SI of its clean 5-min windows (≥ 3).
    public static func baevskyMedian(_ set: HRVWindowSet) -> Computed<Double> {
        HRVWindows.medianOrMissing(set.cleanWindows.compactMap { $0.baevsky?.si })
    }
}
