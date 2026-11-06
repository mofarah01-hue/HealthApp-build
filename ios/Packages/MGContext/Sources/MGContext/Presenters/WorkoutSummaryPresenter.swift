import Foundation
import MGDomain

/// T116: builds the WHOOP-style workout summary from one workout's `WorkoutDetailInput` (the same input the detail page
/// uses). Impact needs raw motion (T46 / T115) and SpO₂ needs T123: v1 shows those as "not available" with the reason.
/// HR recovery shows HRR60, HRR120 and the time constant, with the change against your own per-type baseline
/// (`HRRBaseline`, D-RECOV-WALK-2). The flags are wellness hints, never a diagnosis.
public enum WorkoutSummaryPresenter {
    static let flagsNote = "Flags are wellness hints, not a diagnosis."
    /// The most workouts Explore lists.
    public static let historyLimit = 8
    /// How many finished workouts the app loads so each one has its per-type HR-recovery baseline (20 + the one shown).
    public static let baselineLimit = HRRBaseline.maxWorkouts + 1

    /// The metric measured over this workout only: a day-level row of the same name must never stand in for it.
    private static func inWorkout(_ name: String, _ d: WorkoutDetailInput) -> Metric? {
        d.metrics.first { $0.name == name && windowIsThisWorkout($0.window, d.event) && $0.value != nil }
    }

    /// "workout" or this workout's "workout:<first 8 of the event id>" (the phone's per-workout rows); never a day row.
    static func windowIsThisWorkout(_ window: String?, _ event: EventRecord) -> Bool {
        guard let window else { return false }
        return window == "workout" || window == "workout:" + String(event.id.uuidString.lowercased().prefix(8))
    }

    /// Like `inWorkout`, but a blank row still comes back so its reason ("the data end before +120 s") shows.
    private static func rowInWorkout(_ name: String, _ d: WorkoutDetailInput) -> Metric? {
        d.metrics.first { $0.name == name && windowIsThisWorkout($0.window, d.event) }
    }

    /// Peak HR in the 30 s before the end, from the workout HR map (ALG-012's peak rule); nil without a map.
    static func peakBeforeEnd(_ d: WorkoutDetailInput) -> Double? {
        guard let map = d.hrMap, case let .workout(f) = d.event.payload, map.stepS > 0 else { return nil }
        let endOffset = f.end.timeIntervalSince(map.start)
        var best: Double?
        for (i, v) in map.values.enumerated() {
            guard let v, v.isFinite, v > 0 else { continue }
            let t = Double(i) * map.stepS
            // a bucket counts when it overlaps the 30 s before the end
            if t + map.stepS > endOffset - peakWindowS && t < endOffset { best = max(best ?? v, v) }
        }
        return best
    }
    private static let peakWindowS = 30.0

    /// The baseline entry for one finished workout; nil without a stored HRR60 or a peak.
    static func hrrEntry(_ d: WorkoutDetailInput) -> HRRBaseline.Entry? {
        guard case let .workout(f) = d.event.payload, !d.isLive,
              let hrr = inWorkout(MetricKey.hrRecovery60.rawValue, d)?.value, hrr.isFinite,
              let peak = peakBeforeEnd(d) else { return nil }
        return HRRBaseline.Entry(typeKey: HRRBaseline.typeKey(f.activityTypeUser ?? f.activityTypeAuto), hrr60: hrr,
                                 peak: peak, end: f.end, sleepAfterMin: d.asleepAfterMin)
    }

    /// This workout's HRR60 against your own median for the same type (nil while it runs or without a reading).
    static func hrrCaption(_ s: PresenterSnapshot, _ d: WorkoutDetailInput) -> String? {
        guard let me = hrrEntry(d) else { return nil }
        let history = s.workoutHistory.filter { $0.event.id != d.event.id }.compactMap(hrrEntry)
        let verdict = HRRBaseline.compare(me, history: history)
        return verdict.caption(type: me.typeKey)
    }

    public static func make(_ s: PresenterSnapshot, _ d: WorkoutDetailInput, openPrefix: String) -> WorkoutSummaryState {
        guard case let .workout(f) = d.event.payload else {
            return WorkoutSummaryState(id: d.event.id, title: "Workout", kicker: "", toggleId: "", isOpen: false,
                                       headline: [], details: [], hrMap: nil, flagsNote: flagsNote)
        }
        let e = d.event
        let end = d.isLive ? s.now : f.end
        let toggleId = "\(openPrefix):\(e.id.uuidString)"
        let hrR = d.hrMap.map { Receipt(computedOn: $0.computedOn ?? .strap, tier: $0.tier ?? .strap, at: end) }
        let readings = d.hrMap?.values.compactMap { $0 }.filter { $0.isFinite } ?? []
        func metricRow(_ id: String, _ label: String, _ name: String, missing: String) -> LabeledValue {
            LabeledValue(id: id, label: label, value: s.display(inWorkout(name, d), missing: missing))
        }
        func notYet(_ id: String, _ label: String, _ why: String) -> LabeledValue {
            LabeledValue(id: id, label: label, value: .blank(reason: "Not available yet — \(why)", receipt: nil))
        }

        let headline = [
            LabeledValue(id: "time", label: "Time",
                         value: s.worded(MGFormat.duration(end.timeIntervalSince(e.at)), receipt: s.phoneReceipt(.high))),
            metricRow("avg", "Avg HR", MetricKey.hrAvg.rawValue, missing: "Not computed for this workout."),
            LabeledValue(id: "max", label: "Max HR",
                         value: readings.max().map {
                             s.worded(MGFormat.number($0, decimals: 0), unit: "bpm", receipt: hrR ?? s.phoneReceipt(.high))
                         } ?? .blank(reason: "No heart rate recorded.", receipt: nil)),
            metricRow("calories", "Calories", MetricKey.caloriesActive.rawValue, missing: "Not computed for this workout."),
        ]

        let zones: DisplayValue
        if d.zoneMinutes.count == 5 {
            let text = d.zoneMinutes.enumerated().map { "Z\($0.offset + 1) \(MGFormat.number($0.element, decimals: 0))" }
            zones = s.worded(text.joined(separator: " · "), unit: "min", receipt: s.phoneReceipt(.high, at: end))
        } else {
            zones = .blank(reason: "Zones need a max HR (profile age, or a measured peak).", receipt: nil)
        }
        let details = [
            LabeledValue(id: "zones", label: "Time in zones", value: zones, caption: d.zoneBasis),
            metricRow("steps", "Steps", MetricKey.steps.rawValue, missing: "No step count stored for this workout."),
            LabeledValue(id: "hrr", label: "HR recovery, 1 min",
                         value: s.display(rowInWorkout(MetricKey.hrRecovery60.rawValue, d), missing: PresenterKit.hrRecoveryNotBuilt),
                         caption: hrrCaption(s, d)),
            LabeledValue(id: "hrr120", label: "HR recovery, 2 min",
                         value: s.display(rowInWorkout(MetricKey.hrRecovery120.rawValue, d),
                                          missing: "No 120-second HR recovery was stored for this workout (the data may end before +120 s)."),
                         caption: "Peak minus HR 120 s after the end, same rules as the 1-minute one."),
            LabeledValue(id: "tau", label: "Recovery time constant",
                         value: s.display(rowInWorkout(MetricKey.hrRecoveryTau.rawValue, d),
                                          missing: "No time constant was stored for this workout."),
                         caption: "Research estimate from wrist heart rate (Imai 1994 used ECG); compare only with the same workout type."),
            notYet("spo2", "SpO₂", "needs the quality-gated SpO₂ (T123)."),
            notYet("impact", "Impact", "needs the raw motion stream (T46 / T115)."),
            metricRow("hrv", "HRV hint", MetricKey.hrvRmssd.rawValue, missing: "No HRV for this workout."),
            LabeledValue(id: "vo2", label: "VO₂ max (latest)",
                         value: s.display(s.metric(MetricKey.vo2max.rawValue), missing: "No VO₂ max stored yet."),
                         caption: "Trend on its metric page",
                         intent: .openMetric(key: MetricKey.vo2max.rawValue, variant: nil)),
        ]

        let hrMap = d.hrMap.map {
            WorkoutHRMapState(start: $0.start, stepSeconds: $0.stepS, bpm: $0.values, zoneEdgesBpm: d.zoneEdgesBpm,
                              zoneBasis: d.zoneBasis, zoneMinutes: d.zoneMinutes, receipt: hrR,
                              blankReason: readings.isEmpty ? "No heart rate — the strap was off the whole session." : nil)
        }
        let title = LivePresenter.workoutTitle(type: f.activityTypeUser ?? f.activityTypeAuto, place: e.location?.label)
        return WorkoutSummaryState(
            id: e.id, title: title, kicker: d.isLive ? "\(s.hm(e.at)) → now" : s.range(e.at, end), toggleId: toggleId,
            isOpen: s.ui.openRows.contains(toggleId), headline: headline, details: details, hrMap: hrMap,
            flagsNote: flagsNote)
    }

    /// Explore › Workouts: the finished workouts the app loaded (`PresenterSnapshot.workoutHistory`), newest first.
    public static func history(_ s: PresenterSnapshot) -> WorkoutHistoryState {
        let rows = s.workoutHistory.filter { !$0.isLive }.sorted { $0.event.at > $1.event.at }.prefix(historyLimit)
            .map { make(s, $0, openPrefix: "workout-history") }
        return WorkoutHistoryState(rows: rows, emptyReason: rows.isEmpty ? "No finished workouts this month yet." : nil)
    }
}
