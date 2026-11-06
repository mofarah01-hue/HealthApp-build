import Foundation
import MGDomain

/// T35: the skin-temperature screen's explainer. Only R18 byte 73 ÷ 100 is read as °C ("decoded, untested", CLAUDE.md
/// rule 4 / D3); the ÷ 128 alternative stays an estimate. One sensor (AS6221 per noop); bytes 69 and 71 are unresolved.
enum SkinTemperature {
    static let decodedVariant = "ALG-110:100"

    static func lines(_ s: PresenterSnapshot) -> [String] {
        var lines: [String] = []
        if let raw = s.series.last(where: { $0.name == "skin_temp_night_raw" })?.values.last(where: { $0 != nil }) ?? nil,
           raw.isFinite {
            lines.append("Absolute: \(MGFormat.number(raw / 100, decimals: 1)) °C · R18 byte 73 ÷ 100 (decoded, untested).")
        }
        if let d = s.metric(.skinTempDev, variant: decodedVariant, window: "night")?.value, d.isFinite {
            let basis = PersonalBasis.nights(inNote: s.metric(.skinTempDev, variant: decodedVariant, window: "night")?.note)
                .map { " · \(PersonalBasis.nightsWords($0))" } ?? ""
            lines.append("From your baseline: \(MetricText.signed(d, decimals: 1)) °C (decoded, untested) · tonight's median minus your previous 28-night median\(basis).")
        }
        lines.append("One temperature sensor is identified: AS6221. Bytes 69 and 71 are unresolved and are not shown.")
        lines.append("Choose °C (raw ÷ 100) or the alternative raw ÷ 128 below; only ÷ 100 is decoded as °C.")
        return lines
    }
}
