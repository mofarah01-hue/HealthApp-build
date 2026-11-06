import Foundation
import MGDomain

/// ALG-062 on the phone — which caffeine half-life the "caffeine in you" curve uses (r9t, D-BODY-WALK-1 + D-POP-PRIOR).
/// The reading and the words are `CaffeineHalfLife` (MGDomain, so the presenters can show them); this file hands the half-life
/// to ALG-060. The learning is the PC's (`pc.caffeine-personal@1`). Hand-checked curve values: `ALG062Tests`.
public enum ALG062 {
    public static let populationHalfLifeH = ALG060.defaultHalfLifeH

    /// The newest stored ALG-062 half-life in `metrics`, else the population 5 h.
    public static func halfLife(from metrics: [Metric]) -> CaffeineHalfLife { CaffeineHalfLife.from(metrics) }
}

extension CaffeineHalfLife {
    /// The ALG-060 parameters that carry this half-life (absorption and drink length stay the population ones).
    public var params: ALG060.Params { ALG060.Params(halfLifeH: hours) }
}
