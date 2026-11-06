import Foundation
import MGDomain

/// T99: day/workout strain methods on their own scales. No method is converted onto another method's scale.
/// T9987 (Mo Oct 15 10:30 PM: is strain a made-up metric?): one engine opens first, the same as the front page (ALG-036).
/// The published part is the training load (Banister TRIMP, Morton 1990, in arbitrary units); the 0-21 number is our
/// mapping of it, never validated, so it says so.
public enum StrainPanelPresenter {
    /// D-LOAD-WALK-1 item 1: the headline is the day's Banister TRIMP in its own units.
    public static let defaultAlgorithmID = "ALG-036:trimp"
    /// The one wording for the fitted 0-21 number, wherever it is shown.
    public static let fitLabel = "WHOOP-style strain (estimate)"
    /// The wording for our own net-load 0-21 map (kept as an option; not the headline).
    public static let scaleLabel = "WHOOP-style scale (our mapping, not validated)"
    static let specs = [
        PanelOptionSpec("ALG-036:trimp", "Banister TRIMP, whole day", metrics: [("strain", "ALG-036:trimp")], window: "day",
                        note: "The headline: the day's training impulse (Morton, Fitz-Clarke & Banister 1990) in TRIMP units, "
                            + "from strap heart rate over your waking minutes. Not a 0–21 number."),
        PanelOptionSpec("ALG-036", "Ours, 0–21 net-load map", metrics: [("strain", "ALG-036")], window: "day",
                        note: "The 0–21 number is a \(scaleLabel) of the day's training load above your quiet level."),
        PanelOptionSpec("MS-01", "Banister TRIMP (workouts only)", metrics: [("strain", "MS-01")]),
        PanelOptionSpec("MS-02", "Edwards zones", metrics: [("strain", "MS-02")]),
        PanelOptionSpec("ALG-036:fit", fitLabel, metrics: [("strain", "ALG-036:fit")], window: "day",
                        note: "Estimate - not WHOOP's number: fitted to your exported WHOOP days. Fitted on your older days, "
                            + "on your newest quarter it was off by 1.3 points on average (correlation 0.95)."),
        PanelOptionSpec(ImportedHistory.whoopExport, "WHOOP export",
                        metrics: [("strain", ImportedHistory.whoopExport)], window: "day", imported: true,
                        formulaUnpublished: true),
    ]

    public static func make(_ snapshot: PresenterSnapshot, selectedID: String? = nil) -> AlgorithmPanelState {
        return AlgorithmPanelBuilder.make(
            snapshot,
            title: "Strain",
            summary: "Headline: training load (Banister TRIMP from strap heart rate, in its own TRIMP units). "
                + "The 0–21 number is the \(fitLabel), fitted to your WHOOP history. Each method keeps its own scale.",
            defaultID: defaultAlgorithmID,
            selectedID: selectedID,
            specs: specs,
            note: LoadReadouts.strainNote(snapshot),
            groupID: "G-LOAD"
        )
    }
}
