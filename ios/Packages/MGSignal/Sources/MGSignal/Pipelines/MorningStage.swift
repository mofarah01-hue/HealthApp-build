import Foundation
import MGDomain

// WP-22 morning stage — the G-READY / anomaly members that need last night AND the baselines. Runs right
// after the night (NightPipeline) and again hourly inside DayPipeline (MS-20 reads the day's ATL / CTL), always on the
// day's table = stored metrics of the wake day with the fresh ones merged in. Mo's script members of this stage
// (MS-18, MS-19, MS-20) are ScriptMembers.morning. Python mirror: gen_pipelines.py `morning`.
// WRITTEN, NOT COMPILED.

public enum MorningStage {
    /// ALG-101 readiness, ALG-160 readiness (Orchard MS-19), ALG-161 warning signs, ALG-112 anomaly,
    /// ALG-037 (blank). r9h (D-RECOV-WALK-2): the ALG-036 "n of 5 in your range" metric is no longer written.
    /// `today` = the wake day's table; `tempRawTonight` = tonight's raw skin-temp median (ALG-110 night) or nil.
    public static func compute(day: LocalDay, at: Date, today: [Metric], history: MetricHistory,
                               tempRawTonight: Double?, extras: ALG161.NightExtras = ALG161.NightExtras()) -> [Metric] {
        // Today's own rows only: a morning score is never computed from an imported night (W10: the display shows
        // WHOOP's own value then, labelled); the baselines in `history` do count imported nights.
        let t = MetricHistory(metrics: [day: today])
        func tv(_ name: String, _ variant: String, _ window: String) -> Double? {
            t.value(name, variant: variant, window: window, on: day)
        }
        let n28 = PipelineConstants.readyComponentDays
        var out: [Metric] = []

        // ALG-101 (Plews): tonight's lnRMSSD against the previous 28 nights.
        let rm = history.dense("hrv_rmssd", variant: "ALG-010", window: "night", before: day, days: n28)
            + [tv("hrv_rmssd", "ALG-010", "night")]
        out.append(ALG101.metric(ALG101.readiness(rmssdNights: rm), at: at))

        // ALG-160 readiness 1-100 (Orchard MS-19 rebuilt, D-RECOV-WALK-2): HRV status first, own nights only.
        out.append(ALG160.metric(ALG160.readiness(readinessInput(day: day, today: t, history: history)), at: at))

        // ALG-161 warning signs against your own normal.
        out += ALG161.metrics(warningInput(day: day, today: t, history: history, tempRawTonight: tempRawTonight,
                                           extras: extras), at: at)

        // ALG-170 relative trends (r9s, D-TRENDS-1): breathing, apnea screen, AF burden, rest-to-walk rise, perfusion, illness.
        out += ALG170.metrics(trendInput(day: day, today: t, history: history, tempRawTonight: tempRawTonight,
                                         extras: extras), at: at)

        // ALG-112 robust Mahalanobis distance (research, no alert threshold).
        var nights: [ALG112.Night] = []
        for k in (1...n28).reversed() {
            let d = day.adding(days: -k)
            nights.append(ALG112.Night(rhr: history.value("rhr", variant: "ALG-012", window: "night", on: d),
                                       hrv: history.value("hrv_ln_rmssd", variant: "ALG-010", window: "night", on: d),
                                       temp: history.series0(Baselines.skinTempNightRaw, on: d),
                                       resp: history.value("resp_rate", variant: "ALG-121", window: "night", on: d)))
        }
        nights.append(ALG112.Night(rhr: tv("rhr", "ALG-012", "night"), hrv: tv("hrv_ln_rmssd", "ALG-010", "night"),
                                   temp: tempRawTonight, resp: tv("resp_rate", "ALG-121", "night")))
        out.append(ALG112.metric(ALG112.anomaly(nights: nights), at: at))
        return out
    }

    /// ALG-160 inputs from the stored history: OWN nights only (audit 6.6: WHOOP's or Apple's number is never mixed into
    /// our baseline). The enhanced series is the 60 s morning readings (`hrv_ln_rmssd`, variant ALG-010:spot60, window
    /// morning); it is passed only when it holds anything.
    public static func readinessInput(day: LocalDay, today t: MetricHistory, history: MetricHistory) -> ALG160.Input {
        func tv(_ name: String, _ variant: String, _ window: String) -> Double? {
            t.ownValue(name, variant: variant, window: window, on: day)
        }
        let nBase = ALG160.baseMax
        let ln = history.ownDense("hrv_ln_rmssd", variant: "ALG-010", window: "night", before: day, days: nBase)
            + [tv("hrv_ln_rmssd", "ALG-010", "night")]
        let morningEcg = history.ownDense("hrv_ln_rmssd", variant: ALG160.morningVariant, window: "morning", before: day,
                                          days: nBase) + [tv("hrv_ln_rmssd", ALG160.morningVariant, "morning")]
        let morningPpg = history.ownDense("hrv_ln_rmssd", variant: MorningCheck.ppgVariant, window: "morning", before: day,
                                          days: nBase) + [tv("hrv_ln_rmssd", MorningCheck.ppgVariant, "morning")]
        let morning = MorningCheck.readinessSeries(ecg: morningEcg, ppg: morningPpg)
        let prev = history.ownDense("sleep_performance", variant: "ALG-150", window: "night", before: day, days: 2)
        // Training load: this morning's ATL / CTL when the day has them, else the end of yesterday (both or neither).
        var atl = tv("atl", "ALG-036", "day")
        var ctl = tv("ctl", "ALG-036", "day")
        if atl == nil || ctl == nil {
            atl = history.ownValue("atl", variant: "ALG-036", window: "day", on: day.adding(days: -1))
            ctl = history.ownValue("ctl", variant: "ALG-036", window: "day", on: day.adding(days: -1))
        }
        let stress = history.ownDense("stress", variant: "ALG-123:daytime", window: "day", before: day, days: 3)
        return ALG160.Input(lnNights: ln, morningLn: morning,
                            sleepLast: tv("sleep_performance", "ALG-150", "night"), sleepPrev: prev, atl: atl, ctl: ctl,
                            stressDays: stress)
    }

    /// ALG-161 inputs: the last 29 nights and tonight.
    static func warningInput(day: LocalDay, today t: MetricHistory, history: MetricHistory, tempRawTonight: Double?,
                             extras: ALG161.NightExtras) -> ALG161.Input {
        let n = ALG161.historyNights
        func tv(_ name: String, _ variant: String) -> Double? { t.ownValue(name, variant: variant, window: "night", on: day) }
        func own(_ name: String, _ variant: String) -> [Double?] {
            history.ownDense(name, variant: variant, window: "night", before: day, days: n) + [tv(name, variant)]
        }
        let days = (0...n).map { DayCalendar.dayNumber(day.adding(days: $0 - n)) }
        let af = tv("af_screen", "ALG-013").map { Int($0.rounded()) == 1 }
        return ALG161.Input(
            days: days, rhr: own("rhr", "ALG-012"),
            tempRaw: history.denseSeries0(Baselines.skinTempNightRaw, before: day, days: n) + [tempRawTonight],
            resp: own("resp_rate", "ALG-121"),
            first3Hr: history.denseSeries0(ALG161.first3hHrSeries, before: day, days: n) + [extras.first3Hr],
            first3LnRmssd: history.denseSeries0(ALG161.first3hLnRmssdSeries, before: day, days: n) + [extras.first3LnRmssd],
            afFlag: af, ecgIrregular: nil, cvhrPerHour: tv("breathing_disturbance", "ALG-023:cvhr"),
            cvhrHours: extras.cvhrHours)
    }

    /// ALG-170 inputs: the same nightly series ALG-161 reads (resting HR, skin-temperature counts, breathing, CVHR hours), plus
    /// HRV and the carry series of the trends (AF share, rest-to-walk rise, perfusion index). 29 earlier nights and tonight;
    /// the AF burden looks back 7 nights. Own nights only (audit 6.6).
    static func trendInput(day: LocalDay, today t: MetricHistory, history: MetricHistory, tempRawTonight: Double?,
                           extras: ALG161.NightExtras) -> ALG170.StageInput {
        let n = ALG170.historyNights
        func tv(_ name: String, _ variant: String) -> Double? { t.ownValue(name, variant: variant, window: "night", on: day) }
        func own(_ name: String, _ variant: String, days: Int = n) -> [Double?] {
            history.ownDense(name, variant: variant, window: "night", before: day, days: days) + [tv(name, variant)]
        }
        var i = ALG170.StageInput()
        i.resp = own("resp_rate", "ALG-121")
        i.respEnhanced = own("resp_rate", "ALG-121:riav")
        i.cvhr = own("breathing_disturbance", "ALG-023:cvhr")
        i.cvhrHours = history.denseSeries0(ALG023.hoursSeries, before: day, days: n) + [extras.cvhrHours]
        i.afShares = history.denseSeries0(ALG170.afShareSeries, before: day, days: 6) + [extras.afShare]
        i.afFlags = own("af_screen", "ALG-013", days: 6).map { $0.map { Int($0.rounded()) == 1 } }
        i.orthostatic = history.denseSeries0(ALG171.seriesName, before: day, days: n) + [extras.orthoRise]
        i.perfusion = history.denseSeries0(ALG172.seriesName, before: day, days: n) + [extras.perfusion]
        i.rhr = own("rhr", "ALG-012")
        i.lnRmssd = own("hrv_ln_rmssd", "ALG-010")
        i.temp = history.denseSeries0(Baselines.skinTempNightRaw, before: day, days: n) + [tempRawTonight]
        return i
    }

    /// ALG-036 components-in-band inputs (one definition for the score and its ALG-102 drivers). HRV = lnRMSSD (as
    /// ALG-101); temp = the raw night medians (ALG-110 carry series), never the deviation metric.
    public static func readinessInputs(day: LocalDay, today: [Metric], history: MetricHistory,
                                       tempRawTonight: Double?) -> [String: ALG036.ReadinessInput] {
        // Today's own rows only: a morning score is never computed from an imported night (W10: the display shows
        // WHOOP's own value then, labelled); the baselines in `history` do count imported nights.
        let t = MetricHistory(metrics: [day: today])
        let n28 = PipelineConstants.readyComponentDays
        func comp(_ name: String, _ variant: String, _ window: String) -> ALG036.ReadinessInput {
            ALG036.ReadinessInput(today: t.value(name, variant: variant, window: window, on: day),
                                  history: history.dense(name, variant: variant, window: window, before: day, days: n28))
        }
        return [
            "hrv": comp("hrv_ln_rmssd", "ALG-010", "night"),
            "rhr": comp("rhr", "ALG-012", "night"),
            "sleep": comp("sleep_performance", "ALG-150", "night"),
            "breathing": comp("resp_rate", "ALG-121", "night"),
            "temp": ALG036.ReadinessInput(today: tempRawTonight,
                                          history: history.denseSeries0(Baselines.skinTempNightRaw, before: day,
                                                                        days: n28)),
        ]
    }
}
