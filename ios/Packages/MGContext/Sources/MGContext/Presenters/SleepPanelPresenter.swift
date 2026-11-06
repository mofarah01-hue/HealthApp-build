import Foundation
import MGDomain

/// T100: sleep accounting, night HRV and stage totals in one expandable panel.
public enum SleepPanelPresenter {
    public static let defaultAlgorithmID = "ALG-151"

    static let stages = ["sleep_deep", "sleep_light", "sleep_rem", "sleep_wake"]
    // Need and debt are ALG-115's alone (T7): listing them under ALG-150 too made rows nothing fills.
    static let accounting = ["sleep_total", "sleep_latency", "waso", "rem_latency",
                             "sleep_performance", "sleep_efficiency", "awakenings"]
    static let specs: [PanelOptionSpec] = {
        let whoop = ImportedHistory.whoopExport
        let apple = ImportedHistory.appleHealth
        let stageNote = "Sleep stages need strap data for that night."
        let ownHeadlines = [("sleep_total", "ALG-150"), ("sleep_performance", "ALG-150"),
                            ("sleep_efficiency", "ALG-150"), ("hrv_rmssd", "ALG-010"),
                            ("hrv_sdnn", "ALG-010")]
        let ownStages = pairs(stages, "ALG-151")
        let ownHRV = [("hrv_rmssd", "ALG-010"), ("hrv_sdnn", "ALG-010")]
        return [
            PanelOptionSpec("ALG-151", "Ours (phone), fused stager",
                            metrics: ownHeadlines + pairs(stages, "ALG-151"), window: "night", note: stageNote),
            PanelOptionSpec("ALG-120", "Ours, motion + heart-rate rules (Cole-Kripke, Webster; no Markov step)",
                            metrics: ownHeadlines + pairs(stages, "ALG-120"), window: "night", note: stageNote),
            PanelOptionSpec("ALG-031:A", "Ours A",
                            metrics: ownHeadlines + pairs(stages, "ALG-031:A"), window: "night", note: stageNote),
            PanelOptionSpec("MS-21", "Rule-based",
                            metrics: ownHeadlines + pairs(stages, "MS-21"), window: "night", note: stageNote),
            PanelOptionSpec("ALG-141", "Foundation-model staging",
                            metrics: ownHeadlines + pairs(stages, "ALG-141"), window: "night", note: stageNote),
            // PC Lab's optional ML estimates (pc.* pipelines, off by default). A night they did not run on is a blank
            // that carries its reason, e.g. "no overnight raw PPG stored".
            PanelOptionSpec("pc.sleep-ecg", "PC: SleepECG (wake / REM / NREM)",
                            metrics: pairs(["sleep_wake", "sleep_rem", "sleep_light", "sleep_deep"], "pc.sleep-ecg"), window: "night",
                            note: "Estimate run on the PC: the night window comes from the strap's sleep flag; stages come from SleepECG (wake / REM / NREM) on beat-to-beat R-R plus your age, sex and clock time. NREM is given in the note; no light or deep split."),
            PanelOptionSpec("pc.wav2sleep", "PC: wav2sleep (PPG)",
                            metrics: pairs(stages, "pc.wav2sleep"), window: "night",
                            note: "Estimate from the raw pulse signal, run on the PC; needs overnight raw PPG stored."),
            PanelOptionSpec("ALG-150", "Strap-night accounting",
                            metrics: pairs(accounting, "ALG-150") + ownHRV + ownStages, window: "night"),
            PanelOptionSpec("ALG-115", "Sleep need, debt, recommended bedtime",
                            metrics: pairs(["sleep_total", "sleep_need", "sleep_debt", "sleep_latency", "waso",
                                            "rem_latency", "bedtime_recommended"], "ALG-115")
                                + [("sleep_performance", "ALG-150"), ("sleep_efficiency", "ALG-150")]
                                + ownHRV + ownStages, window: "night"),
            PanelOptionSpec("ALG-010", "Night HRV", metrics: ownHeadlines + ownStages, window: "night"),
            PanelOptionSpec(whoop, "WHOOP export",
                            metrics: pairs(["sleep_total", "sleep_need", "sleep_debt", "sleep_performance",
                                            "sleep_efficiency", "sleep_onset", "wake_time"] + stages + ["hrv_rmssd"],
                                           whoop), window: "night", imported: true, formulaUnpublished: true),
            // Apple Health's imported sleep row is kept to accounting + SDNN; no stage claim is made here.
            PanelOptionSpec(apple, "Apple Health", metrics: pairs(["sleep_total", "hrv_sdnn"], apple), window: "night",
                            note: "No sleep-stage metrics are shown for Apple Health.", imported: true),
        ]
    }()

    public static func make(_ snapshot: PresenterSnapshot, selectedID: String? = nil) -> AlgorithmPanelState {
        return AlgorithmPanelBuilder.make(
            snapshot,
            title: "Sleep",
            summary: "Strap-night accounting, night HRV and sleep stages.",
            defaultID: defaultAlgorithmID,
            selectedID: selectedID,
            specs: specs,
            note: "Sleep HRV may be RMSSD or SDNN; each value keeps its stored unit.",
            groupID: "G-STAGE"
        )
    }

    static func pairs(_ names: [String], _ variant: String) -> [(String, String)] {
        names.map { ($0, variant) }
    }
}
