import Foundation
import MGDomain

/// ALG-101 v1 — Plews lnRMSSD readiness (G-READY rank 1): z of last night's lnRMSSD against the previous 28 nights.
/// Python reference: app/pclab/mglab/ref/hrv.py `readiness_z`; goldens app/shared/golden/hrv/ALG-101.json.
public enum ALG101 {
    public static let citation = "Plews DJ et al. Sports Med 2013;43:773-781"
    public static let windowNights = 28
    /// UX §12: "Learning your normal" until 14 nights.
    public static let minNights = 14

    public struct Readiness: Sendable, Equatable {
        public var z: Double
        public var lnToday: Double
        public var baselineMean: Double
        public var baselineSD: Double
        /// Valid nights in the baseline.
        public var nights: Int

        public init(z: Double, lnToday: Double, baselineMean: Double, baselineSD: Double, nights: Int) {
            self.z = z
            self.lnToday = lnToday
            self.baselineMean = baselineMean
            self.baselineSD = baselineSD
            self.nights = nights
        }
    }

    /// ALG-101 v1 — z = (ln RMSSD_today − mean) / SD (ddof 1) of ln RMSSD over the valid nights among the 28 before
    /// today (needs 14). `rmssdNights` oldest → newest, the last element is last night; nil or ≤ 0 = no value.
    /// The missing reason for a short baseline reads "Learning your normal: n of 14 nights so far" (UX §12).
    public static func readiness(rmssdNights: [Double?]) -> Computed<Readiness> {
        guard let last = rmssdNights.last else { return .missing("no nights") }
        func ok(_ v: Double?) -> Double? {
            guard let v, v.isFinite, v > 0 else { return nil }
            return v
        }
        guard let today = ok(last) else { return .missing("no HRV for last night") }
        let base = rmssdNights.dropLast().suffix(windowNights).compactMap { ok($0) }.map { log($0) }
        guard base.count >= minNights else {
            return .missing("Learning your normal: \(base.count) of \(minNights) nights so far")
        }
        let sd = SignalMath.sampleSD(base)
        guard sd > 0 else { return .missing("baseline has no spread") }
        let mu = SignalMath.mean(base)
        return .success(Readiness(z: (log(today) - mu) / sd, lnToday: log(today), baselineMean: mu, baselineSD: sd,
                                  nights: base.count))
    }

    public static let spec = MetricSpec(
        key: .readiness, unit: "z", group: "G-READY", variant: "ALG-101", method: "ALG-101@1 plews-lnrmssd-z",
        tier: .estimate, source: "hrv_rmssd", window: "morning", citation: citation, paramsVersion: "w28 min14 ddof1")

    public static func metric(_ r: Computed<Readiness>, at: Date) -> Metric {
        spec.metric(r.map(\.z), at: at)
    }
}
