import Foundation
import MGDomain

// D-SLEEP-PRIORITY-1 item 3 (Mo, Nov 5 2026): "WHOOP just records it as HRV, we have to look at the numbers and when it was logged
// for what it relates to — is it WHOOP's sleep HRV, or Apple's RMSSD." Every HRV value is shown with its KIND (RMSSD or SDNN),
// who measured it and what it covers, and RMSSD and SDNN are never shown as the same number.
//
// What each writer puts where (checked against the PC's imports, Sep 14 - Nov 5 2026, read-only):
//   * Apple Watch -> Apple Health's HRV type (SDNN): short spot readings through the day and night (5-minute buckets in the
//     Shortcut POSTs); the PC's daily row is their mean (`hrv_sdnn`, window "day"). Shown as SDNN, "spot readings, daily average".
//   * WHOOP via Apple Health -> Mo says it writes its sleep RMSSD into that same SDNN type. The Shortcut POSTs of that period
//     hold NO row from WHOOP in the HRV type (WHOOP wrote heart rate, resting HR, SpO2, respiration, sleep, steps, energy and
//     workouts), so the claim could not be checked against numbers. The rule below follows Mo's statement for any WHOOP-written
//     HRV row that does appear: it reads as WHOOP's sleep HRV (RMSSD), never as SDNN.
//   * WHOOP export -> `heart_rate_variability_ms`, WHOOP's sleep HRV (RMSSD), window "night".
//   * Ours -> ALG-010: RMSSD (and an SDNN member), window "night".
enum HRVLabel {
    enum Kind: String { case rmssd = "RMSSD", sdnn = "SDNN" }

    static let names: Set<String> = [MetricKey.hrvRmssd.rawValue, MetricKey.hrvSdnn.rawValue]

    /// An imported row written by WHOOP (its export, or WHOOP via Apple Health).
    static func isWhoopWritten(_ m: Metric) -> Bool {
        guard ImportedHistory.isImported(m) else { return false }
        if m.variant == ImportedHistory.whoopExport { return true }
        return ImportedHistory.shortSource(m.source).hasPrefix("WHOOP")
    }

    /// The measure the number really is: a WHOOP-written value in Apple's SDNN-named type is WHOOP's RMSSD (Mo's statement).
    static func kind(_ m: Metric) -> Kind {
        if isWhoopWritten(m) { return .rmssd }
        return m.name == MetricKey.hrvSdnn.rawValue ? .sdnn : .rmssd
    }

    /// "WHOOP sleep HRV (RMSSD)", "Apple Watch SDNN (spot readings, daily average)", "Sleep HRV, ours (RMSSD)".
    static func text(_ m: Metric) -> String {
        let k = kind(m).rawValue
        if !ImportedHistory.isImported(m) {
            return (m.window == "night" ? "Sleep HRV" : "HRV") + ", ours (\(k))"
        }
        if isWhoopWritten(m) { return "WHOOP sleep HRV (\(k))" }
        return "\(ImportedHistory.shortSource(m.source)) \(k) (spot readings, daily average)"
    }
}

extension PresenterSnapshot {
    /// The RMSSD-kind figure for the night: ours (window night), else a WHOOP-written HRV (either type), else Apple's own RMSSD.
    func nightRmssd() -> Metric? {
        if let own = metric(.hrvRmssd, window: "night"), own.value?.isFinite ?? false, !ImportedHistory.isImported(own) { return own }
        let whoop = metrics.filter {
            HRVLabel.names.contains($0.name) && HRVLabel.isWhoopWritten($0) && ($0.value?.isFinite ?? false)
        }.sorted { ($0.window == "night" ? 0 : 1) < ($1.window == "night" ? 0 : 1) }
        if let w = whoop.first { return w }
        if let any = metric(.hrvRmssd, window: "night"), any.value?.isFinite ?? false { return any }
        return nil
    }

    /// The HRV rows of the sleep sheet and the Night page: the night's RMSSD-kind value (blank with its reason when none), and an
    /// SDNN of its own beside it when there is one; each captioned with kind, writer and coverage.
    func sleepHrvRows() -> [LabeledValue] {
        var out: [LabeledValue] = []
        if let r = nightRmssd() {
            out.append(LabeledValue(id: "hrv", label: "Sleep HRV", value: display(r), caption: HRVLabel.text(r),
                                    intent: .openMetric(key: MetricKey.hrvRmssd.rawValue, variant: nil)))
        } else {
            out.append(LabeledValue(id: "hrv", label: "Sleep HRV",
                                    value: .blank(reason: "No sleep HRV (RMSSD) for this night yet.", receipt: nil)))
        }
        if let sd = nightSdnn() {
            out.append(LabeledValue(id: "hrv_sdnn", label: "HRV (SDNN)", value: display(sd), caption: HRVLabel.text(sd),
                                    intent: .openMetric(key: MetricKey.hrvSdnn.rawValue, variant: nil)))
        }
        return out
    }

    /// An SDNN-kind figure: ours, else a non-WHOOP Apple Health SDNN (the Watch's), each under its own name.
    func nightSdnn() -> Metric? {
        let m = metric(.hrvSdnn, window: "night")
        guard let m, m.value?.isFinite ?? false, HRVLabel.kind(m) == .sdnn else { return nil }
        return m
    }
}
