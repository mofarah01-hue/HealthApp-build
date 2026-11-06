import Foundation

/// Every registry metric the HRV family writes (WP-08), for WP-22's pipelines and the registry test.
public enum HRVFamily {
    public static let specs: [MetricSpec] = [
        ALG004.artefactSpec,
        ALG010.rmssdSpec, ALG010.lnRmssdSpec, ALG010.sdnnSpec, ALG010.pnn50Spec, ALG010.sd1Spec, ALG010.sd2Spec,
        ALG011.lfHfSpec, PPGSignalQuality.spec,
        ALG012.rhrSpec, ALG012.hrAvgSpec, ALG012.hrDipSpec,
        ALG054.spec,
    ] + MorningCheck.specs + [
        ALG101.spec,
        ALG123Daytime.spec,
    ]
}
