import Foundation
import MGDomain

// T9976 (Oct 17 2026): the PC's HRV suite on the HRV group. `pc.hrv-suite@1` (pclab/mglab/alg/hrv_suite.py) writes
// `hrvs_<method>` metrics with variant `hrvs:<window>`; this only chooses and words them (no statistic here). Ours are
// the strap's R-R computed on the PC. Apple's SDNN (its spot readings) and WHOOP's cloud history (its HRV, history
// only) are separate labelled rows below, never in the method rows and never called RMSSD. A blank cell says why.

enum HRVSuitePresenter {
    static let modelId = "pc.hrv-suite"
    static let namePrefix = "hrvs_"

    /// Method key (the metric name after `hrvs_`) and its name on screen, in the order shown.
    static let methods: [(key: String, name: String)] = [
        ("rmssd", "RMSSD"), ("ln_rmssd", "ln RMSSD"), ("sdnn", "SDNN"), ("pnn50", "pNN50"), ("mean_nn", "Mean NN"),
        ("hr", "Heart rate"), ("sd1", "Poincaré SD1"), ("sd2", "Poincaré SD2"), ("sd1_sd2", "SD1 / SD2"),
        ("lf", "LF power"), ("hf", "HF power"), ("lf_hf", "LF / HF"), ("lf_nu", "LF (n.u.)"), ("hf_nu", "HF (n.u.)"),
        ("sampen", "Sample entropy"),
    ]
    /// Window id (the variant after `hrvs:`), its short title and the sentence that says what it is (the PC's own
    /// sentence in the result replaces it when present).
    static let windows: [(id: String, title: String, detail: String)] = [
        ("night", "Night", "the strap's asleep stretch (WHOOP-style, sleep only)"),
        ("deep", "Deep sleep", "5-minute windows inside 5 minutes or more of stager deep sleep (estimate; needs a stored stager result)"),
        ("morning5", "Morning 5 min", "the first clean 5 minutes within an hour after waking"),
        ("day", "Whole day", "awake and asleep, the Pacific calendar day (Apple-style idea; not Apple's number)"),
    ]
    static let noResult = "No PC result yet: the PC computes the suite when a night closes."
    static let noMeaning = "The PC result carries no explanation for this method."
    static let noSource = "source not in this PC result"

    static func make(_ s: PresenterSnapshot) -> HRVSuiteState {
        let result = newest(s.pcResults)
        let info = detail(result)
        var legend = windows.map { HRVSuiteWindow(id: $0.id, title: $0.title, detail: $0.detail) }
        if case .object(let labels)? = info["labels"] {
            legend = legend.map { w in
                var w = w
                if case .string(let t)? = labels[w.id] { w.detail = t }
                return w
            }
        }
        var meaning: [String: JSONValue] = [:]
        if case .object(let o)? = info["meaning"] { meaning = o }
        // r8h E2 (Oct 17 2026): with no PC result there is nothing per method to show; the view draws ONE empty-state
        // card (the sentence once) plus "Other sources", instead of 16 cards of the same two sentences.
        let rows: [HRVSuiteMethod] = result == nil ? [] : methods.map { m -> HRVSuiteMethod in
            let own = result?.metrics.filter { $0.name == namePrefix + m.key } ?? []
            var text = noMeaning
            if case .string(let t)? = meaning[m.key] { text = t }
            let cells = windows.map { w -> HRVSuiteCell in
                let value: DisplayValue
                if let found = own.first(where: { $0.variant == "hrvs:" + w.id }) {
                    value = s.display(found)
                } else if let result {
                    value = .blank(reason: (result.status ?? "ok") == "ok" ? "Not in this PC result."
                                   : (result.reason ?? "The PC result has no values."), receipt: nil)
                } else {
                    value = .blank(reason: noResult, receipt: nil)
                }
                return HRVSuiteCell(id: w.id, window: w.title, value: value)
            }
            return HRVSuiteMethod(id: m.key, name: m.name, meaning: text,
                                  source: own.compactMap(\.citation).first { !$0.isEmpty } ?? sourceFallback(result), cells: cells)
        }
        return HRVSuiteState(title: "HRV by method and window",
                             intro: "Ours: the strap's beat-to-beat intervals (wrist pulse, not ECG), cleaned and scored on the PC. "
                                 + "Estimates. Compare a method only with the same method in the same window.",
                             resultLine: resultLine(result, s), windows: legend, methods: rows,
                             othersTitle: "Other sources (not ours, kept apart)", others: otherSources(s))
    }

    /// r8h E3: when the result carries no citation for a method, name the model line instead of "not in this result".
    static func sourceFallback(_ r: LabResult?) -> String {
        guard let r else { return noSource }
        return "\(modelId)@\(r.modelVersion)"
    }

    /// The newest `pc.hrv-suite` result: an ok one by date (newest seq first within a date), else the newest of any status.
    static func newest(_ results: [LabResult]) -> LabResult? {
        let mine = results.filter { $0.modelId == modelId }
        var best: LabResult?
        for r in mine where (r.status ?? "ok") == "ok" && (best == nil || r.date > best!.date) { best = r }
        return best ?? mine.first
    }

    static func detail(_ r: LabResult?) -> [String: JSONValue] {
        if case .object(let o)? = r?.extra["detail"] { return o }
        return [:]
    }

    static func resultLine(_ r: LabResult?, _ s: PresenterSnapshot) -> String {
        guard let r else { return noResult }
        let status = r.status ?? "ok"
        let head = "\(modelId)@\(r.modelVersion) · computed on PC · night of \(Outputs.dayText(r.date, s)) · \(status)"
        return status == "ok" ? head : head + " · " + (r.reason ?? "no reason given")
    }

    /// Apple's SDNN and WHOOP's cloud HRV (history), each the newest stored day of its own source, labelled.
    static func otherSources(_ s: PresenterSnapshot) -> [LabeledValue] {
        func isWhoop(_ m: Metric) -> Bool {
            m.variant == ImportedHistory.whoopExport
                || (m.variant == ImportedHistory.appleHealth && m.source.localizedCaseInsensitiveContains("WHOOP"))
        }
        func newest(_ key: String, _ keep: (Metric) -> Bool) -> DatedMetric? {
            (s.explore.latest[key] ?? []).filter { keep($0.metric) && ($0.metric.value?.isFinite ?? false) }
                .max { $0.day < $1.day }
        }
        let apple = newest(MetricKey.hrvSdnn.rawValue) { $0.variant == ImportedHistory.appleHealth && !isWhoop($0) }
        let whoop = newest(MetricKey.hrvRmssd.rawValue, isWhoop)
        func row(_ id: String, _ label: String, _ d: DatedMetric?, missing: String, note: String) -> LabeledValue {
            guard let d else { return LabeledValue(id: id, label: label, value: .blank(reason: missing, receipt: nil), caption: note) }
            return LabeledValue(id: id, label: label, value: s.display(d.metric),
                                caption: "\(note) · \(Outputs.dayText(d.day, s))")
        }
        return [
            row("apple-sdnn", "SDNN (Apple)", apple, missing: "No Apple Health SDNN imported yet.",
                note: "Apple Health, Apple's own number: SDNN of its spot readings, not RMSSD"),
            row("whoop-cloud", "HRV (WHOOP cloud, history)", whoop, missing: "No WHOOP history imported yet.",
                note: "WHOOP's own number from its export, history only (last import), never today's"),
        ]
    }
}
