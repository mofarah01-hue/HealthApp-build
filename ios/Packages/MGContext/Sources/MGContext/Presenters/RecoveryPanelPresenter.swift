import Foundation
import MGDomain

/// T133: recovery methods remain labelled on their own scales; their numbers are not presented as interchangeable.
public enum RecoveryPanelPresenter {
    public static let defaultAlgorithmID = "MS-19"
    static let specs = [
        PanelOptionSpec(ImportedHistory.whoopExport, "WHOOP export",
                        metrics: [("readiness", ImportedHistory.whoopExport)], window: "morning",
                        note: "Scale: 0–100 %, WHOOP's own number (red under 34, yellow 34–66, green 67 and up).",
                        imported: true, formulaUnpublished: true),
        PanelOptionSpec("MS-18", "Loop", metrics: [("readiness", "MS-18")], window: "morning",
                        note: "Scale: 0–100 (green 67 and up). Our estimate of WHOOP's described inputs; WHOOP publishes no weights. Not WHOOP's number."),
        PanelOptionSpec("noop-recovery:import", "WHOOP-style recovery (estimate), past data",
                        metrics: [("readiness", "noop-recovery:import")], window: "morning",
                        note: "Scale: 0–100. WHOOP-style recovery (estimate) on past data; against WHOOP's own number on 828 days: typical gap 9 points, r 0.94.", imported: true),
        PanelOptionSpec("ALG-101", "Plews lnRMSSD", metrics: [("readiness", "ALG-101")], window: "morning",
                        note: "Scale: z-score against your last 28 nights; 0 is your usual, below 0 is lower."),
        PanelOptionSpec("MS-19", "Orchard · readiness", metrics: [("readiness", "MS-19")], window: "morning",
                        note: "Scale: 1–100, Garmin's bands (Poor under 25, Low 25–49, Moderate 50–74, High 75–94, Prime 95 and up). "
                            + "Core: 7-day HRV against your own range (Plews). Weights are our estimate."),
        PanelOptionSpec("MS-20", "Aurora", metrics: [("readiness", "MS-20")], window: "morning",
                        note: "Scale: 0–100. Our estimate of Oura's described contributors; Oura publishes no weights or bands."),
    ]

    public static func make(_ snapshot: PresenterSnapshot, selectedID: String? = nil) -> AlgorithmPanelState {
        return AlgorithmPanelBuilder.make(
            snapshot,
            title: "Recovery",
            summary: "Each method keeps its own scale; unlike numbers do not mean the methods disagree.",
            defaultID: defaultAlgorithmID,
            selectedID: selectedID,
            specs: specs
        )
    }
}
