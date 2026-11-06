import Foundation
import MGDomain

/// ALG-134 v2 — CosinorAge transform (G-AGE). Python reference: app/pclab/mglab/ref/insights.py `cosinor_age`; goldens
/// app/shared/golden/day/ALG-134.json.
///
/// v2 (2026-10-17, Mo, D-LOAD-WALK-1 item 9): the "Body Age / vitality" readout is REMOVED (v1 was a port of whoop-rs
/// physio-algo vitality.rs @ d11d8ef: per-driver log-hazards that linearise published categorical results into a wellness
/// index that is not a validated age). Its computation, spec, presenters, registry variant `ALG-134:vitality` and tests are gone.
/// CosinorAge (whoop-rs biological_age.rs; Shim, Fleisch & Barata, npj Digit Med 2024) needs MESOR / amplitude /
/// acrophase of ENMO in mg from the 100 Hz IMU, which the strap streams behind the raw-motion switch. InsightMembers.day takes
/// the cosinor of minute ENMO from MGSignal RawMotion and fills this metric when ≥ 4 consecutive complete days exist;
/// otherwise it is blank with RawMotion's reason.
public enum ALG134 {
    public static let cosinorCitation = "Shim J, Fleisch E, Barata F. npj Digit Med 2024;7:146; whoop-rs biological_age.rs @ d11d8ef"

    // MARK: CosinorAge transform

    /// (rate, mesor, amp1, phi1, age) per sex, whoop-rs biological_age.rs.
    static func cosinorCoefficients(_ sex: Profile.Sex?) -> (Double, Double, Double, Double, Double) {
        switch sex {
        case .some(.female): return (-13.28530410, -0.02569062, -0.02170987, -0.13191562, 0.08840283)
        case .some(.male): return (-13.016951633, -0.023988922, -0.030620390, 0.008960155, 0.101726103)
        default: return (-13.36715309, -0.03204933, -0.01971357, -0.01664718, 0.10033692)
        }
    }

    public static func cosinorAge(mesor: Double, amplitude: Double, acrophase: Double, age: Double,
                                  sex: Profile.Sex?) -> Computed<Double> {
        let c = cosinorCoefficients(sex)
        let xb = mesor * c.1 + amplitude * c.2 + acrophase * c.3 + age * c.4 + c.0
        let surv = exp(-1.405276 * exp(xb) / 0.01462774)
        let outer = -0.01447851 * log(surv)
        guard outer > 0 else { return .missing("CosinorAge transform undefined for these inputs") }
        return .success(log(outer) / 0.112165 + 133.5989)
    }

    public static let cosinorSpec = MetricSpec(
        key: .bodyAge, unit: "years", group: "G-AGE", variant: "ALG-134:cosinor", method: "ALG-134@1 cosinor-age",
        tier: .research, source: "enmo", window: "day", citation: cosinorCitation)
    public static let cosinorBlankReason = "needs ENMO in mg from the 100 Hz IMU (raw motion): the CosinorAge coefficients "
        + "are fitted on mg-ENMO and the strap's 1 Hz activity is a different scale"

    /// The cosinor metric's note: under `RawMotion.cosinorMinDays` complete days it opens with the estimate label.
    public static func cosinorNote(_ fit: RawMotion.CosinorFit) -> String {
        let detail = String(format: "%d day(s) of minute ENMO: MESOR %.1f mg, amplitude %.1f mg, acrophase %.2f rad",
                            fit.days, fit.mesor, fit.amplitude, fit.acrophase)
        guard fit.days < RawMotion.cosinorMinDays else { return detail }
        return "estimate from \(fit.days) day(s) of motion, intended number after \(RawMotion.cosinorMinDays) days; " + detail
    }
}
