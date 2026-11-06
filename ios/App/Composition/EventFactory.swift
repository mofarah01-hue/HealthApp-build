import Foundation
import MGContext
import MGDomain
import MGSignal

// WP-23a — the contract events the app writes for one-tap logs, strap gestures, peek answers and sessions. Every event
// is a new id at revision 1 with `loggedAt` = the tap (APP-082); `at` = when it happened. Field meanings follow the
// contract (v0.4 + v0.5 proposals, ARCHITECTURE D10).
//
// WRITTEN, NOT COMPILED.

enum EventFactory {
    // MARK: Reaction test (ALG-050, PVT-B)

    /// A finished 3-minute PVT-B (contract reactionTestEvent): `at` = when it started, `loggedAt` = when it ended.
    static func reactionTest(_ s: ALG050.Score, startedAt: Date, endedAt: Date) -> EventRecord {
        EventRecord(at: startedAt, loggedAt: endedAt, source: .manual,
                    payload: .reactionTest(ReactionTestFields(test: "pvt-b-3min", meanRtMs: s.meanRtMs, lapses: s.lapses,
                                                              falseStarts: s.falseStarts, trials: s.trials)))
    }

    // MARK: Substances and medication (UX §7)

    /// One vape hit (Mo, 2026-10-10: one event per hit). `trigger` .button / .doubleTap / .widget (APP-007, APP-071).
    static func vapeHit(at: Date, trigger: SubstanceFields.Vape.Trigger, wake: Date?) -> EventRecord {
        let sinceWake = wake.map { at.timeIntervalSince($0) / 60 }.flatMap { $0 >= 0 && $0 < 24 * 60 ? $0 : nil }
        let vape = SubstanceFields.Vape(hits: 1, trigger: trigger, minutesSinceWake: sinceWake)
        return EventRecord(at: at, loggedAt: at, source: trigger == .doubleTap ? .strap : .manual,
                           payload: .substance(SubstanceFields(kind: .vapeTick, vape: vape)))
    }

    /// A drink started (UX §7 Caffeine [Start]); `finishedAt` stays empty until [Finish] (ALG-060 reads it as 40 min).
    static func drinkStart(at: Date, product: String, caffeineMg: Double?) -> EventRecord {
        EventRecord(at: at, loggedAt: at, source: .manual,
                    payload: .substance(SubstanceFields(kind: .caffeine, product: product, caffeineMg: caffeineMg)))
    }

    /// A medication taken now. `title` is what the pill / row says ("MedA 20 mg"); the dose comes from a matching
    /// schedule, else from the title ("<name> <dose> <unit>"), else the Log catalogue preset (APP-076: MedA 20 mg).
    static func medicationTaken(title: String, at: Date, schedules: [MedSchedule],
                                presetLists: PresetLists = PresetLists()) -> EventRecord {
        let schedule = schedules.first { title.localizedCaseInsensitiveContains($0.name) }
        // T102: a tapped preset of the Medications list logs its own dose, not the schedule's (T9973: from the list).
        if let p = MedicationPresets.preset(titled: title, in: presetLists) {
            return MedicationPresets.takenEvent(p, at: at, scheduleId: schedule?.id)
        }
        let parsed = parseDose(title)
        let preset = LogCatalogue.standard.medication(matching: title)
        let name = schedule?.name ?? preset?.name ?? parsed.name
        let dose = schedule?.dose ?? parsed.dose ?? preset?.strength
        let unit = schedule?.unit ?? parsed.unit ?? preset?.strengthUnit
        let category: MedicationFields.Category = schedule?.kind.map { (k: MedSchedule.Kind) -> MedicationFields.Category in
            switch k {
            case .prescription: return .prescription
            case .supplement: return .supplement
            case .otc: return .otc
            }
        } ?? preset?.category ?? .prescription
        let fields = MedicationFields(name: name, dose: dose, doseUnit: unit, status: .taken, scheduleId: schedule?.id,
                                      category: category, units: preset?.units, unitKind: preset?.unitKind)
        return EventRecord(at: at, loggedAt: at, source: .manual, payload: .medication(fields))
    }

    /// The morning stack (UX §7 Supplements [Log stack]): one event per supplement schedule.
    static func supplementStack(at: Date, schedules: [MedSchedule]) -> [EventRecord] {
        schedules.filter { $0.kind == .supplement }.map { s in
            EventRecord(at: at, loggedAt: at, source: .manual,
                        payload: .medication(MedicationFields(name: s.name, dose: s.dose, doseUnit: s.unit,
                                                              status: .taken, scheduleId: s.id, category: .supplement)))
        }
    }

    /// "MedA 20 mg" → ("MedA", 20, "mg"); a title without a number → (title, nil, nil).
    static func parseDose(_ title: String) -> (name: String, dose: Double?, unit: String?) {
        let parts = title.split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(where: { Double($0) != nil }), i > 0 else { return (title, nil, nil) }
        let name = parts[..<i].joined(separator: " ")
        let unit = i + 1 < parts.count ? parts[i + 1] : nil
        return (name, Double(parts[i]), unit)
    }

    // MARK: Wear (ALG-007, APP-008)

    static func wear(_ state: WearFields.State, at: Date, location: WearLocation?, detectedBy: WearFields.DetectedBy,
                     promptedAt: Date? = nil, answeredAt: Date? = nil, carriedOver: Bool? = nil) -> EventRecord {
        EventRecord(at: at, loggedAt: answeredAt ?? at, source: detectedBy == .manual ? .manual : .strap,
                    wearLocation: location,
                    payload: .wear(WearFields(state: state, detectedBy: detectedBy, promptedAt: promptedAt,
                                              answeredAt: answeredAt, carriedOver: carriedOver)))
    }

    // MARK: Check-ins (UX §5)

    /// Meal check-in KSS (prompt after_meal_60 / after_meal_120).
    static func mealCheckin(kss: Int, minutesAfter: Int, now: Date) -> EventRecord {
        let prompt: CheckinFields.Prompt = minutesAfter >= 120 ? .afterMeal120 : .afterMeal60
        return EventRecord(at: now, loggedAt: now, source: .manual,
                           payload: .checkin(CheckinFields(kss: kss, prompt: prompt)))
    }

    /// Morning check-in, step 1 (UX §5.1): how Mo feels after waking — G-INERTIA's label, stored with the live
    /// stager's stage and P(light ∪ wake) at the wake (WP-11 `SmartWakeOutcome`). The contract has no grogginess
    /// field on a checkin yet, so it goes in the note as `wake_feel=<word> (<n>/5)` (main: contract v0.5 candidate
    /// `checkin.wake_feel`). Nothing numeric is invented.
    static func morningFeel(word: String, rating: Int, wake: Date, now: Date, stageAtWake: String?,
                            pLightOrWake: String?) -> EventRecord {
        var parts = ["wake_feel=\(word) (\(rating)/5)", "wake=\(Int(wake.timeIntervalSince1970))"]
        if let stageAtWake { parts.append("stage_at_wake=\(stageAtWake)") }
        if let pLightOrWake { parts.append("p_light_or_wake=\(pLightOrWake)") }
        return EventRecord(at: now, loggedAt: now, source: .manual, note: parts.joined(separator: "; "),
                           payload: .checkin(CheckinFields(prompt: .scheduled)))
    }

    // MARK: Naps (APP-042, APP-045)

    static func manualNap(start: Date, end: Date) -> EventRecord {
        EventRecord(at: start, loggedAt: end, source: .manual,
                    payload: .nap(NapFields(end: end, confirmed: true, trigger: .manual, promptResponse: nil,
                                            label: .nap)))
    }

    // MARK: Workouts (APP-051)

    /// A manual workout once Mo ends it.
    static func manualWorkout(_ w: LiveSessions.Workout, end: Date) -> EventRecord {
        var windows = w.windows.sorted { $0.start < $1.start }
        if var last = windows.last, last.end > end || last.end <= last.start {
            last.end = max(last.start, end)
            windows[windows.count - 1] = last
        }
        let fields = WorkoutFields(end: end, activityTypeUser: w.activityType,
                                   windows: windows.isEmpty ? nil : windows)
        return EventRecord(id: w.id, at: w.start, loggedAt: end, source: .manual, wearLocation: w.wearLocation, note: w.note,
                           location: w.place.map { EventLocation(label: $0) }, payload: .workout(fields))
    }
}
