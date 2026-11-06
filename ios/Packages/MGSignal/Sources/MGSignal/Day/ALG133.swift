import Foundation
import MGDomain

/// ALG-133 v2 — Fitness Age (G-VO2, G-AGE), Nes's definition: the age at which a typical healthy person of your sex has your
/// VO₂max. Python reference: `fitness_age`, `fa_reference_line`; goldens app/shared/golden/day/ALG-133.json.
///
/// Definition (Wisløff's wording for the NTNU / HUNT "Fitness Age"): a 70-year-old with the VO₂peak of a typical 20-year-old has a
/// fitness age of 20. The calculator (worldfitnesslevel.org) is the Nes BM, Janszky I, Vatten LJ, Nilsen TI, Aspenes ST, Wisløff U
/// non-exercise model, Med Sci Sports Exerc 2011;43(11):2024-2030, read against a table of the typical VO₂max at each age 20-90.
/// That table is not published as text, so the reference here is the same group's HUNT3 sample: Loe H, Rognmo Ø, Saltin B, Wisløff U,
/// PLoS ONE 2013;8(5):e64319, Table 2 (3,816 healthy adults 20-90, directly measured VO₂max): mean mL/kg/min per age band
/// 20-29 / 30-39 / 40-49 / 50-59 / 60-69 / 70+ — men 54.4, 49.1, 47.2, 42.6, 39.2, 35.3; women 43.0, 40.0, 38.4, 34.4, 31.1, 28.3.
/// Band mid-ages 25…65 and 75 for "70+" (ours: that band's mean age is not tabulated). The reference LINE is the least-squares line
/// through the six means; fitness age = the age at which it equals the VO₂max, clamped to 20…90.
/// Input: a VO₂max — the Nes non-exercise estimate (`ALG036.nesVO2max`, needs a waist), else the HR-ratio estimate (Uth 2004);
/// the caller says which. v1 (noop's reference-peer inversion, 20…80 clamp, ±5-year band — "not Nes's") is removed.
public enum ALG133 {
    public static let method = "ALG-133@2 nes-hunt3-reference-line"
    public static let citation = "Nes BM et al. Med Sci Sports Exerc 2011;43(11):2024-2030 (Fitness Age definition); "
        + "Loe H et al. PLoS ONE 2013;8(5):e64319 Table 2 (HUNT3 reference means)"
    public static let paramsVersion = "2"

    /// HUNT3 band mid-ages and mean VO₂max (mL/kg/min).
    public static let referenceAges: [Double] = [25, 35, 45, 55, 65, 75]
    public static let referenceMale: [Double] = [54.4, 49.1, 47.2, 42.6, 39.2, 35.3]
    public static let referenceFemale: [Double] = [43.0, 40.0, 38.4, 34.4, 31.1, 28.3]
    public static let clamp: ClosedRange<Double> = 20.0...90.0

    public static let spec = MetricSpec(
        key: .fitnessAge, unit: "years", group: "G-VO2", variant: "ALG-133", method: method, tier: .estimate,
        source: "profile", window: "day", producer: .ours, citation: citation, paramsVersion: paramsVersion)

    /// (intercept, slope) of the least-squares reference line for a sex.
    static func referenceLine(_ sex: DayKit.Sex) -> (intercept: Double, slope: Double) {
        let xs = referenceAges
        let ys = sex == .male ? referenceMale : referenceFemale
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var sxy = 0.0
        var sxx = 0.0
        for i in 0..<xs.count {
            sxy += (xs[i] - mx) * (ys[i] - my)
            sxx += (xs[i] - mx) * (xs[i] - mx)
        }
        let slope = sxy / sxx
        return (my - slope * mx, slope)
    }

    public struct FitnessAge: Sendable, Equatable {
        /// Years, clamped to 20…90.
        public var fitnessAge: Double
        public var unclamped: Double
        public var clamped: Bool
        /// Age − fitness age: positive = fitter than your age; nil without an age.
        public var deltaYears: Double?

        public init(fitnessAge: Double, unclamped: Double, clamped: Bool, deltaYears: Double?) {
            self.fitnessAge = fitnessAge
            self.unclamped = unclamped
            self.clamped = clamped
            self.deltaYears = deltaYears
        }
    }

    /// ALG-133 v2 — Nes's Fitness Age from a VO₂max (mL/kg/min, 5…100) and sex; `age` only adds `deltaYears`.
    public static func fitnessAge(vo2max: Double?, sex: Profile.Sex?, age: Double? = nil) -> Computed<FitnessAge> {
        DayKit.compute { () throws -> FitnessAge in
            let sx = try DayKit.sex(sex).get()
            guard let v = vo2max, v.isFinite, v >= 5, v <= 100 else {
                throw Missing("needs a VO2max between 5 and 100 ml/kg/min")
            }
            let line = referenceLine(sx)
            let fa = (v - line.intercept) / line.slope
            let shown = min(clamp.upperBound, max(clamp.lowerBound, fa))
            let delta: Double? = (age?.isFinite ?? false) ? age.map { $0 - shown } : nil
            return FitnessAge(fitnessAge: shown, unclamped: fa, clamped: !clamp.contains(fa), deltaYears: delta)
        }
    }
}
