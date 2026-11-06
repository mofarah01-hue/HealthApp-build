import Foundation
import MGDomain

// T10009 (2026-10-17): a background night run does not read the R20 optical records (`NightPipeline.loadInputs(includeR20:
// false)`). Members that need those records would then compute from nothing, or (R18QualityNight's saturation share) fall
// back to a different definition, and writing that would replace the foreground run's values. This names those members so the
// caller leaves their stored values alone. No maths changes here.

extension NightPipeline {
    /// The night metrics that are computed from the R20 records: ALG-015 pulse shape, the dicrotic-notch members and the
    /// optical saturation share (which falls back to the R18 flag when there are no R20 records).
    public static var r20DerivedSpecs: [MetricSpec] {
        [ALG015.riseSpec, ALG015.widthSpec, PulseNotch.notchSpec, PulseNotch.reflectionSpec, PulseNotch.rateSpec,
         R18QualityNight.saturatedSpec, PPGSignalQuality.spec, ALG022Night.spec]
    }

    /// `metrics` without the ones above (matched by name and variant).
    public static func removingR20Derived(from metrics: [Metric]) -> [Metric] {
        let skip = Set(r20DerivedSpecs.map { "\($0.key.rawValue)|\($0.variant)" })
        return metrics.filter { !skip.contains("\($0.name)|\($0.variant ?? "")") }
    }
}
