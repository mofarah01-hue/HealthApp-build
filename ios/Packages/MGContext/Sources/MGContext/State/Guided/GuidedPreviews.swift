import Foundation
import MGDomain

// SAMPLE previews for the guided flows and the workout detail (ARCHITECTURE §4.7: every state type ships a
// `static let preview` with sample: true). Times are the prototype's sample day (Sun 11 Oct 2026, gym 17:32–18:20,
// app/prototype/index.html `D.workout`, `workoutView()`, GROUPS.load / .cal). The workout HR curve is the prototype's
// `hrSeries` without its random noise; the summary, window and zone numbers below were computed from that same curve
// (scratchpad wp29/sample_workout.py) so the preview agrees with what it draws.
//
// The two RUNNING previews (pacer, HRV countdown) anchor their clock on `Date()` when first read, so the pacer
// animates and the countdown moves in Xcode previews; nothing else here reads the clock.

private enum GuidedSample {
    static let strapNote = "iPhone haptics only · strap buzz not used here"

    static func strap(_ h: Int, _ m: Int) -> Receipt { SampleDay.receipt(.strap, .strap, h, m) }

    static func phone(_ h: Int, _ m: Int, _ tier: Tier = .high, _ method: String? = nil) -> Receipt {
        SampleDay.receipt(.phone, tier, h, m, method: method)
    }
}

// MARK: - Breathe

extension BreatheState {
    /// Running at 6 /min, 5 min, started when first read (so the pacer moves in Xcode previews).
    public static let preview: BreatheState = {
        let start = Date()
        var s = BreatheState.previewReady
        s.phase = .running
        s.startedAt = start
        s.endsAt = start.addingTimeInterval(Double(BreatheState.defaultMinutes) * 60)
        s.beatsCollected = 142
        return s
    }()

    /// The ready screen (Night: "Breathe (pacer, 5 min)").
    public static let previewReady = BreatheState(
        sample: true, phase: .ready, breathsPerMinute: BreatheState.defaultBreathsPerMinute, inhaleFraction: 0.5,
        minutes: BreatheState.defaultMinutes, rateOptions: [5, 5.5, 6, 6.5, 7], minuteOptions: [3, 5, 10],
        startedAt: nil, endsAt: nil, heartRate: SampleDay.value("61", "bpm", GuidedSample.strap(22, 10)),
        beatsCollected: nil, strapNote: nil, phoneHaptics: true, cueNote: GuidedSample.strapNote, result: nil)

    /// Running with no strap: the pacer still leads, coherence will be blank.
    public static let previewNoStrap: BreatheState = {
        var s = BreatheState.preview
        s.heartRate = .blank(reason: "Strap not connected.", receipt: nil)
        s.beatsCollected = nil
        s.strapNote = "Strap not connected — the pacer runs, no coherence."
        return s
    }()

    /// Five minutes done at 22:15.
    public static let previewFinished: BreatheState = {
        var s = BreatheState.previewReady
        s.phase = .finished
        s.startedAt = SampleDay.at(22, 10)
        s.endsAt = SampleDay.at(22, 15)
        s.beatsCollected = 309
        s.result = BreatheResult.preview
        return s
    }()
}

extension BreatheResult {
    public static let preview: BreatheResult = {
        let r = GuidedSample.phone(22, 15, .high, "ALG-104 coherence ratio")
        return BreatheResult(
            coherence: SampleDay.value("3.4", nil, r),
            coherenceWord: "higher than your usual (median 2.1)",
            resonanceLine: "peak 0.100 Hz = 6.0 /min — on your pace",
            rows: [
                LabeledValue(id: "hr", label: "Mean HR", value: SampleDay.value("62", "bpm", GuidedSample.strap(22, 15))),
                LabeledValue(id: "rmssd", label: "RMSSD", value: SampleDay.value("58", "ms",
                                                                                 GuidedSample.phone(22, 15, .high, "ALG-010"))),
                LabeledValue(id: "resp", label: "Breathing rate",
                             value: SampleDay.value("6.1", "/min", GuidedSample.phone(22, 15, .estimate, "ALG-121 RSA"),
                                                    .estimate(nil)),
                             caption: "paced 6.0 — agrees (APP-031 check)"),
                LabeledValue(id: "time", label: "Paced", value: SampleDay.value("5:00", nil, GuidedSample.phone(22, 15))),
            ],
            note: "Not saved — sample data.")
    }()
}

// MARK: - HRV check

extension HRVCheckState {
    /// Measuring, 3 min, 70 s in when first read (so the countdown moves in Xcode previews).
    public static let preview: HRVCheckState = {
        let start = Date().addingTimeInterval(-70)
        var s = HRVCheckState.previewReady
        s.phase = .measuring
        s.minutes = 3
        s.startedAt = start
        s.endsAt = start.addingTimeInterval(180)
        s.beats = 74
        s.flagged = 1
        s.gate = HRVCheckGate(status: .passing, line: "1 of 74 beats flagged (1.4 %)", rule: HRVCheckGate.previewRule)
        return s
    }()

    public static let previewReady = HRVCheckState(
        sample: true, phase: .ready, minutes: 3, minuteOptions: Array(HRVCheckState.minuteRange),
        instruction: "Sit still, breathe normally, keep the strap snug.", startedAt: nil, endsAt: nil,
        heartRate: SampleDay.value("64", "bpm", GuidedSample.strap(9, 40)), beats: nil, flagged: nil,
        gate: HRVCheckGate(status: .waiting, line: "No beats yet.", rule: HRVCheckGate.previewRule),
        result: nil, blankReason: nil)

    public static let previewResult: HRVCheckState = {
        var s = HRVCheckState.previewReady
        s.phase = .result
        s.startedAt = SampleDay.at(9, 40)
        s.endsAt = SampleDay.at(9, 43)
        s.beats = 183
        s.flagged = 2
        s.gate = HRVCheckGate(status: .passing, line: "2 of 183 beats flagged (1.1 %)", rule: HRVCheckGate.previewRule)
        s.result = HRVCheckResult.preview
        return s
    }()

    /// The gate failed: the values are blank with the reason (UX §13).
    public static let previewFailed: HRVCheckState = {
        var s = HRVCheckState.previewResult
        s.beats = 171
        s.flagged = 16
        s.gate = HRVCheckGate(status: .failing, line: "16 of 171 beats flagged (9.4 %)", rule: HRVCheckGate.previewRule)
        s.result = HRVCheckResult.previewFailed
        return s
    }()

    /// Strap off: nothing to measure.
    public static let previewBlocked: HRVCheckState = {
        var s = HRVCheckState.previewReady
        s.phase = .blocked
        s.heartRate = .blank(reason: "Strap's off your wrist.", receipt: nil)
        s.blankReason = "Strap's off your wrist — nothing to measure. Off since 15:12."
        return s
    }()
}

extension HRVCheckGate {
    static let previewRule = "Passes with at least 60 s of beats and no more than 5 % flagged (ALG-004 B)."
}

extension HRVCheckResult {
    public static let preview: HRVCheckResult = {
        let r = GuidedSample.phone(9, 43, .high, "ALG-010 RMSSD")
        return HRVCheckResult(
            passed: true,
            rmssd: SampleDay.value("49", "ms", r),
            lnRmssd: SampleDay.value("3.89", "ln ms", GuidedSample.phone(9, 43, .high, "ALG-010 lnRMSSD")),
            coherence: SampleDay.value("0.62", nil, GuidedSample.phone(9, 43, .high, "ALG-104 coherence ratio")),
            rows: [
                LabeledValue(id: "hr", label: "Mean HR", value: SampleDay.value("64", "bpm", GuidedSample.strap(9, 43))),
                LabeledValue(id: "sdnn", label: "SDNN", value: SampleDay.value("61", "ms",
                                                                               GuidedSample.phone(9, 43, .high, "ALG-010"))),
                LabeledValue(id: "beats", label: "Beats used", value: SampleDay.value("181", "of 183", r)),
            ],
            comparison: "Below your night median (52 ms).",
            qualityLine: "183 beats · 2 flagged (1.1 %) · passed",
            savedNote: "Not saved — sample data.")
    }()

    public static let previewFailed: HRVCheckResult = {
        let r = GuidedSample.phone(9, 43, .high, "ALG-004 B gate")
        let reason = "9.4 % of beats were flagged — over the 5 % limit; nothing reliable."
        return HRVCheckResult(
            passed: false,
            rmssd: .blank(reason: reason, receipt: r), lnRmssd: .blank(reason: reason, receipt: r),
            coherence: .blank(reason: reason, receipt: r),
            rows: [LabeledValue(id: "hr", label: "Mean HR", value: SampleDay.value("66", "bpm", GuidedSample.strap(9, 43)))],
            comparison: nil,
            qualityLine: "171 beats · 16 flagged (9.4 %) · failed — try again sitting still",
            savedNote: "Nothing saved.")
    }()
}

// MARK: - Workout detail

extension WorkoutDetailState {
    /// "Workout just ended" (prototype scenario `wend`): gym, strength, 17:32–18:20.
    public static let preview: WorkoutDetailState = WorkoutDetailPreview.build(live: false)

    /// Opened during the live workout at 17:45: map so far, last window open-ended at now, double-tap hint.
    public static let previewLive: WorkoutDetailState = WorkoutDetailPreview.build(live: true)
}

enum WorkoutDetailPreview {
    static let start = SampleDay.at(17, 32)
    static let step: TimeInterval = 5

    /// The prototype's `hrSeries` shape without noise, 5 s steps 17:32–18:20, with a 20 s gap at 17:57.
    static func bpm(upTo last: Int) -> [Double?] {
        (0...last).map { i -> Double? in
            if (300..<304).contains(i) { return nil }
            let m = Double(i) * step / 60
            let v: Double
            if m < 6 {
                v = 92 + m * 5.5
            } else if m < 42 {
                let ph = (m - 6).truncatingRemainder(dividingBy: 6)
                v = ph < 1.6 ? 128 + ph * 24 : (ph < 2.4 ? 166 - (ph - 1.6) * 20 : 150 - (ph - 2.4) * 7)
            } else {
                v = 150 - (m - 42) * 8
            }
            return v + 2 * sin(Double(i) / 3)
        }
    }

    static func window(_ kind: WorkoutFields.Window.Kind, _ label: String, _ s: Date, _ e: Date, avg: String,
                       peak: String, trimp: String, zones: [Double], detail: String?, canMerge: Bool,
                       at: Receipt) -> WorkoutDetailWindow {
        WorkoutDetailWindow(id: WorkoutDetailWindow.makeID(kind: kind, start: s), kind: kind, label: label, start: s,
                            end: e, avgHR: SampleDay.value(avg, "bpm", at), peakHR: SampleDay.value(peak, "bpm", at),
                            trimp: SampleDay.value(trimp, nil, Receipt(computedOn: .phone, tier: .high, at: at.at,
                                                                       method: "MS-01 Banister TRIMP")),
                            zoneMinutes: zones, detail: detail, isOpen: false, canMergeWithNext: canMerge)
    }

    static func build(live: Bool) -> WorkoutDetailState {
        let strap = SampleDay.receipt(.strap, .strap, live ? 17 : 18, live ? 45 : 21)
        let ph = SampleDay.receipt(.phone, .high, 18, 21)
        let end: Date? = live ? nil : SampleDay.at(18, 20)
        let warmEnd = SampleDay.at(17, 38)
        let workEnd = SampleDay.at(18, 14)
        let windows: [WorkoutDetailWindow]
        let summary: [LabeledValue]
        let zoneMinutes: [Double]
        if live {
            let now = SampleDay.at(17, 45)
            windows = [
                window(.warmup, "Warm-up", start, warmEnd, avg: "108", peak: "123", trimp: "3", zones: [4, 2, 0, 0, 0],
                       detail: nil, canMerge: true, at: strap),
                window(.work, "Work · 1 set so far", warmEnd, now, avg: "142", peak: "164", trimp: "10",
                       zones: [0, 2, 3.6, 1.5, 0], detail: "open window · ends when you tap Next window or End",
                       canMerge: false, at: strap),
            ]
            summary = [
                LabeledValue(id: "time", label: "Time", value: SampleDay.value("13", "min", strap)),
                LabeledValue(id: "avg", label: "Avg HR", value: SampleDay.value("127", "bpm", strap)),
                LabeledValue(id: "peak", label: "Peak", value: SampleDay.value("164", "bpm", strap)),
                LabeledValue(id: "hrr", label: "HR rec.", value: .blank(reason: "after the workout ends", receipt: nil)),
            ]
            zoneMinutes = [4.4, 3.6, 3.6, 1.5, 0]
        } else {
            windows = [
                window(.warmup, "Warm-up", start, warmEnd, avg: "108", peak: "123", trimp: "3", zones: [4, 2, 0, 0, 0],
                       detail: nil, canMerge: true, at: strap),
                window(.work, "Work · 6 sets", warmEnd, workEnd, avg: "143", peak: "168", trimp: "52",
                       zones: [0, 9, 19, 8, 0], detail: "6 sets marked by double-tap · last 18:13", canMerge: true,
                       at: strap),
                window(.cooldown, "Cool-down", workEnd, SampleDay.at(18, 20), avg: "126", peak: "148", trimp: "6",
                       zones: [2, 2, 2, 0, 0], detail: nil, canMerge: false, at: strap),
            ]
            summary = [
                LabeledValue(id: "time", label: "Time", value: SampleDay.value("48", "min", strap)),
                LabeledValue(id: "avg", label: "Avg HR", value: SampleDay.value("136", "bpm", strap)),
                LabeledValue(id: "peak", label: "Peak", value: SampleDay.value("168", "bpm", strap)),
                LabeledValue(id: "hrr", label: "HR rec.",
                             value: SampleDay.value("−28", "bpm", SampleDay.receipt(.phone, .high, 18, 21,
                                                                                    method: "ALG-012 HR recovery")),
                             caption: "first minute after the end"),
            ]
            zoneMinutes = [6.0, 12.3, 21.8, 7.6, 0]
        }
        let map = WorkoutHRMapState(
            start: start, stepSeconds: step, bpm: bpm(upTo: live ? 156 : 576), zoneEdgesBpm: [114, 133, 152, 171],
            zoneBasis: "measured max 190", zoneMinutes: zoneMinutes, receipt: strap, blankReason: nil)
        return WorkoutDetailState(
            sample: true, id: UUID(uuidString: "6f1c2a3e-58b4-4a1d-9a3e-2b7c4d5e6f70") ?? UUID(),
            kicker: live ? "SUN 17:32 → NOW · GYM · STRENGTH" : "SUN 17:32–18:20 · GYM · STRENGTH",
            title: "Workout", start: start, end: end,
            typeRow: WorkoutChoiceRow(title: "What", options: [
                WorkoutChoice(id: "strength", label: "Strength"), WorkoutChoice(id: "run", label: "Run"),
                WorkoutChoice(id: "cycle", label: "Cycle"), WorkoutChoice(id: "walk", label: "Walk"),
                WorkoutChoice(id: "intervals", label: "Intervals"),
            ], selected: "strength", allowsOther: true),
            placeRow: WorkoutChoiceRow(title: "Where", options: [
                WorkoutChoice(id: "gym", label: "Gym"), WorkoutChoice(id: "home", label: "Home"),
                WorkoutChoice(id: "outdoors", label: "Outdoors"),
            ], selected: "gym", allowsOther: true),
            autoTypeNote: "Detector: no type yet — its model needs the motion stream (ALG-041). Yours is kept as the label.",
            summary: summary, hrMap: map, windows: windows,
            windowNote: "Your confirmed window is the detector's label (ALG-041 / 047).",
            doubleTapHint: live ? "Double-tap the strap = set done · 1 set so far · last 17:40" : nil,
            breathing: .blank(reason: "Only one breathing estimator runs yet (RSA); shown where two agree (ALG-020).",
                              receipt: live ? nil : ph),
            load: live ? nil : loadStrip(), calories: live ? nil : calorieStrip(), note: nil, timesOpen: false,
            editable: true, editDisabledReason: nil)
    }

    /// G-LOAD for this session (ALGORITHM-COMPARISON ranks); Banister and Edwards from the sample curve.
    static func loadStrip() -> MethodsStripState {
        let ph = SampleDay.receipt(.phone, .high, 18, 21)
        let members = [
            MethodMember(variant: "ours", label: "Ours, 0–21", codename: "ALG-036", value: SampleDay.value("11.4", "/21", ph),
                         scaleNote: "day", bandIndex: 2, position: 0.72, isRead: true, isResearch: false, rank: 2),
            MethodMember(variant: "banister", label: "Banister TRIMP", codename: "MS-01",
                         value: SampleDay.value("61", nil, ph), scaleNote: "session", bandIndex: 2, position: 0.68,
                         isRead: false, isResearch: false, rank: 1),
            MethodMember(variant: "edwards", label: "Edwards zones", codename: "MS-02",
                         value: SampleDay.value("126", nil, ph), scaleNote: "session", bandIndex: 2, position: 0.7,
                         isRead: false, isResearch: false, rank: 2),
            MethodMember(variant: "acwr", label: "Acute:chronic", codename: "MS-03",
                         value: SampleDay.value("1.08", nil, SampleDay.receipt(.pc, .research, 18, 30), .research),
                         scaleNote: "7:28 · descriptive only", bandIndex: 1, position: 0.5, isRead: false,
                         isResearch: true, rank: 3),
        ]
        return MethodsStripState(sample: true, groupId: "G-LOAD", title: "Training load · 4 methods", members: members,
                                 caption: "Three put this session above your median gym day.",
                                 agreement: "Agreement, 30 days: Banister and ours ρ 0.94; Edwards runs 18 % higher on interval days.",
                                 droppedCount: 0, valuesLineOnly: false)
    }

    /// G-CAL for this session. Brage and cadence METs can't run in this build (ARCHITECTURE §8.1 ALG-048 "X").
    static func calorieStrip() -> MethodsStripState {
        let est = SampleDay.receipt(.phone, .estimate, 18, 21, method: "ALG-048 Keytel 2005")
        let members = [
            MethodMember(variant: "keytel", label: "Keytel (HR)", codename: "ALG-048 · Keytel 2005",
                         value: SampleDay.value("342", "kcal", est, .estimate(Uncertainty(sd: 60))), bandIndex: nil,
                         isRead: true, isResearch: false, rank: 1),
            MethodMember(variant: "brage", label: "Brage (HR + movement)", codename: "ALG-048 · Brage 2004",
                         value: .blank(reason: "needs movement counts from the motion stream (R21, locked)", receipt: nil),
                         bandIndex: nil, isRead: false, isResearch: false, rank: 1),
            MethodMember(variant: "cadence", label: "Cadence METs", codename: "ALG-048 · Tudor-Locke 2019",
                         value: .blank(reason: "walking only — needs steps per minute", receipt: nil), bandIndex: nil,
                         isRead: false, isResearch: false, rank: 2),
        ]
        return MethodsStripState(sample: true, groupId: "G-CAL", title: "Calories · 3 methods", members: members,
                                 caption: "One of three could run.", agreement: nil, droppedCount: 0,
                                 valuesLineOnly: true)
    }
}
