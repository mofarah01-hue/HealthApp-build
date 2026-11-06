import Foundation
import MGDomain

/// Breathe (WP-29 state, APP-024): the pacer flow. Coherence (ALG-104), RMSSD (ALG-010) and breathing rate (ALG-020)
/// arrive computed in `BreatheInput.result`; this only words them.
public enum BreathePresenter {
    public static let rateOptions: [Double] = [5, 5.5, 6, 6.5, 7]
    public static let minuteOptions: [Int] = [3, 5, 10]
    public static let cueNote = "iPhone haptics only · strap buzz not used here"

    public static func make(_ s: PresenterSnapshot) -> BreatheState? {
        guard let b = s.breathe else { return nil }
        let strapReason = LivePresenter.blankReason(s)
        let hr: DisplayValue
        if let v = s.live?.heartRate, v.isFinite, strapReason == nil {
            hr = s.worded(MGFormat.number(v, decimals: 0), unit: "bpm",
                          receipt: Receipt(computedOn: .strap, tier: .strap, at: s.live?.heartRateAt ?? s.now))
        } else {
            hr = .blank(reason: strapReason ?? "No beat in the last few seconds.", receipt: nil)
        }
        let note = b.strapNote ?? (strapReason == nil ? nil : "Strap not connected — the pacer runs, no coherence.")
        return BreatheState(sample: s.sample, phase: b.phase, breathsPerMinute: b.breathsPerMinute, inhaleFraction: 0.5,
                            minutes: b.minutes, rateOptions: rateOptions, minuteOptions: minuteOptions,
                            startedAt: b.startedAt, endsAt: b.endsAt, heartRate: hr, beatsCollected: b.beatsCollected,
                            strapNote: note, phoneHaptics: s.settings.phoneHaptics, cueNote: cueNote,
                            result: b.result.map { result(s, b, $0) })
    }

    static func result(_ s: PresenterSnapshot, _ b: BreatheInput, _ r: BreatheMeasured) -> BreatheResult {
        var word: String?
        if let v = r.coherence.value, v.isFinite, let usual = r.usualCoherence, usual.isFinite {
            let a = MGFormat.number(v, decimals: 2)
            let u = MGFormat.number(usual, decimals: 2)
            word = a == u ? "about your usual (\(u))" : (v > usual ? "higher than your usual (\(u))" : "lower than your usual (\(u))")
        }
        let resonance = r.peakHz.map {
            "peak \(MGFormat.number($0, decimals: 3)) Hz = \(MGFormat.number($0 * 60, decimals: 1)) /min · pace \(MGFormat.number(b.breathsPerMinute, decimals: 1)) /min"
        }
        let rows = [
            LabeledValue(id: "hr", label: "Mean HR", value: s.display(r.meanHR, missing: "Too few beats.")),
            LabeledValue(id: "rmssd", label: "RMSSD", value: s.display(r.rmssd, missing: "Too few clean beats.")),
            LabeledValue(id: "resp", label: "Breathing (ALG-020)", value: s.display(r.respRate, missing: "Needs two estimators that agree."),
                         caption: "pace \(MGFormat.number(b.breathsPerMinute, decimals: 1)) /min"),
            LabeledValue(id: "time", label: "Paced", value: s.worded(LivePresenter.elapsed(r.secondsPaced),
                                                                     receipt: s.phoneReceipt(.high, method: "pacer clock"))),
        ]
        var note: String?
        if r.endedEarly {
            note = "Ended early at \(LivePresenter.elapsed(r.secondsPaced)) of \(LivePresenter.elapsed(Double(b.minutes * 60)))."
        }
        let saved = s.sample ? "Not saved — sample data." : (r.saved ? "Saved to the log." : nil)
        if let saved { note = [note, saved].compactMap { $0 }.joined(separator: " ") }
        return BreatheResult(coherence: s.display(r.coherence, missing: "Needs at least 60 s of R-R."), coherenceWord: word,
                             resonanceLine: resonance, rows: rows, note: note)
    }
}

/// HRV spot check (WP-29 state, APP-025): ALG-010 RMSSD / lnRMSSD, ALG-104 coherence, ALG-004 gate.
public enum HRVCheckPresenter {
    public static let gateRule = "Passes with ≥ 60 s of beats and ≤ 5 % flagged (ALG-004 B)"
    public static let instruction = "Sit still, breathe normally, keep the strap snug."

    public static func make(_ s: PresenterSnapshot) -> HRVCheckState? {
        guard let h = s.hrvCheck else { return nil }
        let strapReason = LivePresenter.blankReason(s)
        let blocked = h.phase == .blocked
        let hr: DisplayValue
        if let v = s.live?.heartRate, v.isFinite, strapReason == nil {
            hr = s.worded(MGFormat.number(v, decimals: 0), unit: "bpm",
                          receipt: Receipt(computedOn: .strap, tier: .strap, at: s.live?.heartRateAt ?? s.now))
        } else {
            hr = .blank(reason: h.blockedReason ?? strapReason ?? "No beat in the last few seconds.", receipt: nil)
        }
        let status: HRVCheckGate.Status = h.gatePassing.map { $0 ? HRVCheckGate.Status.passing : .failing } ?? .waiting
        return HRVCheckState(sample: s.sample, phase: h.phase, minutes: min(max(h.minutes, 1), 5),
                             minuteOptions: Array(HRVCheckState.minuteRange), instruction: instruction,
                             startedAt: h.startedAt, endsAt: h.endsAt, heartRate: hr, beats: h.beats, flagged: h.flagged,
                             gate: HRVCheckGate(status: status, line: gateLine(h), rule: gateRule),
                             result: h.result.map { result(s, h, $0) },
                             blankReason: blocked ? (h.blockedReason ?? strapReason ?? "Can't measure right now.") : nil)
    }

    /// "1 of 108 beats flagged (0.9 %)".
    static func gateLine(_ h: HRVCheckInput) -> String {
        guard let beats = h.beats, beats > 0 else { return "waiting for beats" }
        let flagged = h.flagged ?? 0
        let pct = MGFormat.number(Double(flagged) / Double(beats) * 100, decimals: 1)
        return "\(flagged) of \(beats) beats flagged (\(pct) %)"
    }

    static func result(_ s: PresenterSnapshot, _ h: HRVCheckInput, _ r: HRVMeasured) -> HRVCheckResult {
        let passed = h.gatePassing == true && r.rmssd.value != nil
        var comparison: String?
        if let v = r.rmssd.value, v.isFinite, let base = h.nightMedianRmssd, base.isFinite {
            let a = MGFormat.number(v, decimals: 0)
            let b = MGFormat.number(base, decimals: 0)
            comparison = a == b ? "Same as your night median (\(b) ms)"
                : (v > base ? "Higher than your night median (\(b) ms)" : "Lower than your night median (\(b) ms)")
        }
        let rows = [
            LabeledValue(id: "hr", label: "Mean HR", value: s.display(r.meanHR, missing: "Too few beats.")),
            LabeledValue(id: "sdnn", label: "SDNN", value: s.display(r.sdnn, missing: "Too few clean beats.")),
            LabeledValue(id: "beats", label: "Beats used",
                         value: s.worded("\(r.beatsUsed)", receipt: s.phoneReceipt(.high, method: "ALG-004"))),
            LabeledValue(id: "time", label: "Measured",
                         value: s.worded(LivePresenter.elapsed(r.secondsMeasured), receipt: s.phoneReceipt(.high))),
        ]
        let quality = gateLine(h) + (passed ? " · passed" : " · failed")
        let saved: String? = s.sample ? "Not saved — sample data."
            : (r.saved ? "Saved · Explore › HRV" : (passed ? nil : "Not saved — the quality gate failed."))
        return HRVCheckResult(passed: passed, rmssd: s.display(r.rmssd), lnRmssd: s.display(r.lnRmssd),
                              coherence: s.display(r.coherence, missing: "Needs ≥ 60 s and 30 beats."), rows: rows,
                              comparison: comparison, qualityLine: quality, savedNote: saved)
    }
}

/// Workout detail (WP-29 state, UX §14): header chips, summary, HR map, windows, G-LOAD / G-CAL, notes.
public enum WorkoutDetailPresenter {
    static let typeOptions = [WorkoutChoice(id: "strength", label: "Strength"), WorkoutChoice(id: "run", label: "Run"),
                              WorkoutChoice(id: "cycle", label: "Cycle"), WorkoutChoice(id: "walk", label: "Walk"),
                              WorkoutChoice(id: "hiit", label: "Intervals"), WorkoutChoice(id: "sport", label: "Sport")]
    static let placeOptions = [WorkoutChoice(id: "gym", label: "Gym"), WorkoutChoice(id: "home", label: "Home"),
                               WorkoutChoice(id: "outdoors", label: "Outdoors")]

    /// #41: Mo's saved places (by name) first, then the fixed ones he has no saved place for.
    static func placeOptions(_ s: PresenterSnapshot) -> [WorkoutChoice] {
        let saved = s.places.places.map { WorkoutChoice(id: $0.name, label: $0.name) }
        let names = Set(saved.map { $0.label.lowercased() })
        return saved + placeOptions.filter { !names.contains($0.label.lowercased()) }
    }

    /// "Steps from the strap: off. Why …" per `WearPolicy.effects` (D-LOAD-WALK-1 item 12): exactly what the place changes.
    static func wearLines(_ wear: WearLocation?) -> [String] {
        WearPolicy.effects(for: wear).map { "\($0.what): \($0.change). \($0.why)" }
    }

    public static func make(_ s: PresenterSnapshot) -> WorkoutDetailState? {
        guard let d = s.workoutDetail, case let .workout(f) = d.event.payload else { return nil }
        let e = d.event
        let end: Date? = d.isLive ? nil : f.end
        let type = f.activityTypeUser ?? f.activityTypeAuto
        let place = e.location?.label
        let wear: WearLocation? = e.wearLocation == .unknown ? nil : e.wearLocation
        var kick = [MGFormat.kickerDate(e.at, calendar: s.calendar).components(separatedBy: " ").first ?? ""]
        kick[0] += " " + (end.map { s.range(e.at, $0) } ?? "\(s.hm(e.at)) → NOW")
        if let place, !place.isEmpty { kick.append(place.uppercased()) }
        if let type, !type.isEmpty { kick.append(type.uppercased()) }

        let peak = d.hrMap?.values.compactMap { $0 }.filter { $0.isFinite }.max()
        let hrR = d.hrMap.map { Receipt(computedOn: $0.computedOn ?? .strap, tier: $0.tier ?? .strap, at: end ?? s.now) }
        let summary = [
            LabeledValue(id: "time", label: "Time",
                         value: s.worded(MGFormat.duration((end ?? s.now).timeIntervalSince(e.at)), receipt: s.phoneReceipt(.high))),
            LabeledValue(id: "avg", label: "Avg HR",
                         value: s.display(s.metric(MetricKey.hrAvg.rawValue, window: "workout", in: d.metrics),
                                          missing: "Not computed for this workout.")),
            LabeledValue(id: "peak", label: "Peak",
                         value: peak.map { s.worded(MGFormat.number($0, decimals: 0), unit: "bpm", receipt: hrR ?? s.phoneReceipt(.high)) }
                             ?? .blank(reason: "No heart rate recorded.", receipt: nil)),
            LabeledValue(id: "hrr", label: "HR rec. 1 min",
                         value: s.display(s.metric(PresenterKit.hrRecoveryName, window: "workout", in: d.metrics),
                                          missing: PresenterKit.hrRecoveryNotBuilt)),
        ]
        let hasHR = (d.hrMap?.values.contains { $0 != nil }) ?? false
        let map = WorkoutHRMapState(start: d.hrMap?.start ?? e.at, stepSeconds: d.hrMap?.stepS ?? 5,
                                    bpm: d.hrMap?.values ?? [], zoneEdgesBpm: d.zoneEdgesBpm, zoneBasis: d.zoneBasis,
                                    zoneMinutes: d.zoneMinutes, receipt: hrR,
                                    blankReason: hasHR ? nil : "No heart rate — the strap was off the whole session.")
        let wins = (f.windows ?? []).sorted { $0.start < $1.start }
        let windows = wins.enumerated().map { i, w -> WorkoutDetailWindow in
            let id = WorkoutDetailWindow.makeID(kind: w.kind, start: w.start)
            let st = d.windowStats[id]
            let bpmR = s.phoneReceipt(.high, at: w.end)
            var detail: [String] = []
            if let ex = w.exercise { detail.append(ex) }
            if let reps = w.reps { detail.append("\(reps) reps") }
            if let load = w.load { detail.append("\(MGFormat.number(load, decimals: 1)) \(w.loadUnit?.rawValue ?? "")") }
            return WorkoutDetailWindow(
                id: id, kind: w.kind, label: w.label ?? w.kind.map(WorkoutDetailWindow.title(for:)) ?? "Window",
                start: w.start, end: w.end,
                avgHR: st?.avgHR.map { s.worded(MGFormat.number($0, decimals: 0), unit: "bpm", receipt: bpmR) }
                    ?? .blank(reason: "No heart rate in this window.", receipt: nil),
                peakHR: st?.peakHR.map { s.worded(MGFormat.number($0, decimals: 0), unit: "bpm", receipt: bpmR) }
                    ?? .blank(reason: "No heart rate in this window.", receipt: nil),
                trimp: s.display(st?.trimp, missing: "Not computed for this window."), zoneMinutes: st?.zoneMinutes,
                detail: detail.isEmpty ? nil : detail.joined(separator: " · "), isOpen: s.ui.openRows.contains(id),
                canMergeWithNext: i < wins.count - 1)
        }
        var hint: String?
        if d.isLive {
            hint = "Double-tap the strap = set done"
            if d.setsDone > 0 { hint! += " · \(d.setsDone) set\(d.setsDone == 1 ? "" : "s") so far" }
        }
        let reason: String? = s.sample ? "Sample data — edits are off."
            : (d.isLive ? "Still running — end it to edit the times." : nil)
        var state = WorkoutDetailState(
            sample: s.sample, id: e.id, kicker: kick.joined(separator: " · "), title: "Workout", start: e.at, end: end,
            typeRow: WorkoutChoiceRow(title: "What", options: typeOptions, selected: f.activityTypeUser, allowsOther: true),
            placeRow: WorkoutChoiceRow(title: "Where", options: placeOptions(s), selected: place, allowsOther: true),
            autoTypeNote: f.activityTypeAuto.map { "Detector: \($0)" } ?? "Detector: no type yet — needs the motion stream.",
            summary: summary, hrMap: map, windows: windows,
            windowNote: "Your confirmed window is the detector's label (ALG-041 / 047).", doubleTapHint: hint,
            breathing: s.display(s.metric(MetricKey.respRate.rawValue, window: "workout", in: d.metrics),
                                 missing: "Shown only where two breathing estimators agree (APP-031)."),
            load: s.methodsStrip("G-LOAD", window: "workout", source: d.metrics),
            calories: s.methodsStrip("G-CAL", window: "workout", source: d.metrics), note: e.note,
            timesOpen: s.ui.openRows.contains(WorkoutDetailState.timesRowId), editable: !s.sample,
            editDisabledReason: reason, wearRow: WorkoutDetailState.wearChoices(selected: wear),
            wearLines: wearLines(wear))
        if !d.isLive {
            state.effort = WorkoutEffortState(rpe: f.sessionRpe, weightPreKg: f.weightPreKg, weightPostKg: f.weightPostKg,
                                              lines: LoadReadouts.workoutLines(s, metrics: d.metrics))
        }
        return state
    }
}
