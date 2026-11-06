import Foundation
import MGContext
import MGDomain
import MGSignal
import MGStore
import UIKit

// WP-23a — logging (UX §7), peek answers (UX §5), method marks (UX §11). Every write goes through `write(_:)`: refused
// in SAMPLE mode (§4.12), stored through the one `.saveEvent` path (EventSaving), then a compute is asked for (log save
// is a compute trigger, §11 WP-23). Answer strings are WP-23b's (PeekAnswerID, TodayPresenter) and WP-24's
// (NotifyResponseMap, which also sends "same" for the wear question).
//
// WRITTEN, NOT COMPILED.

extension AppModel {
    // MARK: The one write path

    /// Stores an event (new id → revision 1; known id → the store bumps the revision). nil = refused or failed, with
    /// the reason on the notice line.
    @discardableResult
    func write(_ event: EventRecord, undoable: Bool = true) async -> EventRecord? {
        guard !isSample else {
            showNotice(LogIntents.sampleReason)
            return nil
        }
        do {
            let saved = try await EventSaving.save(event, now: clock.now, store: services.store)
            if undoable {
                lastLogged.append(saved.id)
                if lastLogged.count > 50 { lastLogged.removeFirst(lastLogged.count - 50) }
            }
            await services.compute.request(.logSaved)
            await publishWidgetSnapshot()
            return saved
        } catch {
            showNotice("Not saved: \(error)")
            return nil
        }
    }

    func tapHaptic() {
        guard !quietHaptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: One-tap logs (UX §3.2 row 8, §7)

    func quickLog(_ action: QuickLogAction) async {
        let at = clock.now
        switch action {
        case .vapeHit:
            if await write(EventFactory.vapeHit(at: at, trigger: .button, wake: lastInputs?.detectedWake)) != nil {
                tapHaptic()
            }
        case .medication(let name):
            if await write(EventFactory.medicationTaken(title: name, at: at, schedules: settings.schedules,
                                                             presetLists: settings.presetLists)) != nil {
                tapHaptic()
            }
        case .drinkStart(let preset):
            let mg = settings.effectiveDrinks.first { $0.name.caseInsensitiveCompare(preset) == .orderedSame }?.caffeineMg
            if await write(EventFactory.drinkStart(at: at, product: preset, caffeineMg: mg)) != nil { tapHaptic() }
        case .drinkFinish:
            guard !isSample else { return showNotice(LogIntents.sampleReason) }
            let recent = (try? await services.store.events(from: at.addingTimeInterval(-12 * 3600), to: at,
                                                           types: [.substance])) ?? []
            guard let finished = IntentsEvents.finishing(recent, at: at) else {
                return showNotice("No drink is open, so there's nothing to finish.")
            }
            if await write(finished) != nil { tapHaptic() }
        case .supplementsStack:
            let stack = EventFactory.supplementStack(at: at, schedules: settings.schedules)
            guard !stack.isEmpty else {
                openLogRow(.supplements)
                return showNotice("No supplements yet: add them in Preferences › Medications & supplements.")
            }
            for e in stack { await write(e) }
            tapHaptic()
        case .food: openLogRow(.food)
        case .symptom: openLogRow(.symptom)
        case .sleepy: openLogRow(.sleepy)
        case .alcohol: openLogRow(.alcohol)
        case .note: openLogRow(.note)
        case .more: tab = .log
        }
    }

    /// A Log form's new or revised event (`.saveEvent`, BRIEF WP-12/13/18 row).
    func saveEvent(_ event: EventRecord) async {
        var event = event
        // R9m (D-HRV-WALK-2): a reaction test keeps what the alertness model predicted for its start, so the model can be
        // checked against Mo's own reaction times (AlertnessCheck). No curve value at that time = no prediction stored.
        if case .reactionTest(var f) = event.payload, f.predictedAlertness == nil,
           let curve = lastSnapshot?.alertnessCurve,
           let p = AlertnessCheck.prediction(curve: curve.map { ($0.at, $0.value) }, at: event.at) {
            f.predictedAlertness = p
            f.predictedBy = ALG051.method
            event.payload = .reactionTest(f)
        }
        if await write(event) != nil {
            if !quietHaptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }

    /// "Vape hit 10:31?" Yes / No — and skipped nap / workout questions that landed in the Log's confirm list.
    func confirmDetected(id: String, accepted: Bool) async {
        if let uuid = UUID(uuidString: id) {
            guard var e = try? await services.store.event(id: uuid), case .substance(var f) = e.payload,
                  var vape = f.vape else {
                return showNotice("That detection is no longer there.")
            }
            vape.detectedStatus = accepted ? .confirmed : .rejected
            f.vape = vape
            e.payload = .substance(f)
            await write(e, undoable: false)
        } else if id.hasPrefix("nap:") {
            await answerPeek(.nap, answer: accepted ? "nap" : "no")
        } else if id.hasPrefix("workout:") {
            await answerPeek(.workoutConfirm, answer: accepted ? "yes" : "not_workout")
        }
    }

    /// Spine › Edit: content edits are not built yet (BRIEF WP-18 row) — open the entry's Log row and say so.
    func editEntry(_ id: UUID) async {
        guard let e = try? await services.store.event(id: id) else { return }
        openLogRow(Self.logItem(for: e))
        showNotice("Editing an entry isn't built yet: shift its time or remove it from the day spine.")
    }

    func removeEntry(_ id: UUID) async {
        guard !isSample else { return showNotice(LogIntents.sampleReason) }
        do {
            try await services.store.removeEvent(id: id)
            await services.compute.request(.logSaved)
            await publishWidgetSnapshot()
        } catch { showNotice("Not removed: \(error)") }
    }

    func undoRemove(_ id: UUID) async {
        guard !isSample else { return showNotice(LogIntents.sampleReason) }
        do {
            try await services.store.restoreEvent(id: id)
            await services.compute.request(.logSaved)
            await publishWidgetSnapshot()
        } catch { showNotice("Not restored: \(error)") }
    }

    /// "happened at" −5 / −15 / −30 / −60 min (APP-082): a new revision with `at` moved.
    func shiftHappenedAt(_ id: UUID, minutes: Int) async {
        guard var e = try? await services.store.event(id: id) else { return }
        e.at = e.at.addingTimeInterval(TimeInterval(minutes) * 60)
        await write(e, undoable: false)
    }

    /// The Log toast's Undo: the newest event logged this session is soft-removed (kept, hidden — UX §7).
    func undoLastLog() async {
        guard let id = lastLogged.popLast() else { return }
        await removeEntry(id)
    }

    func logMedicationSkipped(name: String, scheduleId: String?) async {
        var e = EventFactory.medicationTaken(title: name, at: clock.now, schedules: settings.schedules,
                                             presetLists: settings.presetLists)
        if case .medication(var f) = e.payload {
            f.status = .skipped
            f.scheduleId = scheduleId ?? f.scheduleId
            e.payload = .medication(f)
        }
        await write(e)
    }

    static func logItem(for e: EventRecord) -> LogItemID {
        switch e.payload {
        case .substance(let f):
            switch f.kind {
            case .vapeTick, .vape: return .vape
            case .caffeine: return .caffeine
            case .alcohol: return .alcohol
            case .drink: return .water
            case .pill: return .medication
            case .other: return .more
            }
        case .medication(let f): return f.category == .supplement ? .supplements : .medication
        case .food: return .food
        case .symptom: return .symptom
        case .checkin, .reactionTest: return .sleepy
        case .record(let f) where f.kind == .soreness || f.kind == .injury: return .sore
        case .journal: return .note
        default: return .more
        }
    }

    // MARK: Methods (UX §11; APP-117 drop hides, never deletes)

    func markMethod(_ groupId: String, _ variant: String, _ mark: GroupMarkValue) async {
        guard !isSample else { return showNotice(LogIntents.sampleReason) }
        do {
            try await services.store.setGroupMark(groupId: groupId, variant: variant, mark: mark, at: clock.now)
        } catch { showNotice("Not saved: \(error)") }
    }

    // MARK: Peeks (UX §5)

    /// The open question of a kind: the one peeking, else a swiped-away one, else any waiting one.
    func activeQuestion(_ key: PeekKindKey) -> PeekKind? {
        if let p = lastContext?.peek, p.key == key { return p }
        if let d = lastContext?.deferredQuestions.first(where: { $0.key == key }) { return d }
        return lastInputs?.pending.first { $0.kind.key == key && $0.isActive(at: clock.now) }?.kind
    }

    /// The ledger id of a question (MGContext factories: ids are built from its times).
    static func questionId(_ kind: PeekKind) -> String {
        switch kind {
        case let .wearLocation(on, previous): return PendingQuestion.wearLocation(wristOnAt: on, previous: previous).id
        case let .workoutConfirm(start, end): return PendingQuestion.workoutConfirm(start: start, end: end).id
        case let .nap(start, end): return PendingQuestion.nap(start: start, end: end).id
        case let .napPlus30(end): return PendingQuestion.napPlus30(napEnd: end).id
        case let .morningCheckin(wake): return PendingQuestion.morningCheckin(wake: wake).id
        case let .mealCheckin(at, minutes): return PendingQuestion.mealCheckin(mealAt: at, minutesAfter: minutes).id
        }
    }

    func answerPeek(_ key: PeekKindKey, answer raw: String) async {
        guard !isSample else { return showNotice("Sample data is on, so answers aren't saved.") }
        let answer = raw.lowercased()
        // A notification answered before the first refresh (cold start): read the day first.
        if lastContext == nil { await refresh() }
        guard let kind = activeQuestion(key) else {
            return showNotice("That question has already closed.")
        }
        let id = Self.questionId(kind)
        var done = true
        ledger.swipeStreak[key.rawValue] = 0

        switch kind {
        case .morningCheckin(let wake):
            ledger.checkinWake = wake
            if let rating = Self.feelWords.firstIndex(of: answer) {
                let r = smartWake?.lastResult
                let stage = r?.outcome.stageAtWake.map { "\($0)" }
                let p = r?.outcome.pLightOrWakeAtWake.map { String(format: "%.2f", $0) }
                await write(EventFactory.morningFeel(word: answer, rating: rating + 1, wake: wake, now: clock.now,
                                                     stageAtWake: stage, pLightOrWake: p), undoable: false)
                ledger.checkinStep = 2
                done = false
            } else if answer == PeekAnswerID.addSomething {
                ledger.checkinDone = true
                tab = .log
            } else {
                // "looks_right", or anything else on step 2.
                ledger.checkinDone = true
                showNotice("Thanks — saved.")
            }

        case let .nap(start, end):
            if napPeekStep >= 2, stepQuestionId[.nap] == id, let n = Self.firstInt(answer), (1...5).contains(n) {
                await updateNap(start: start, createEnd: end) { $0.ratingWake = n }
                napPeekStep = 1
            } else {
                let label: NapFields.Label? = answer == "nap" ? .nap : answer == "dozed" ? .dozed
                    : answer == "quiet_rest_not_asleep" ? .quietRestNotAsleep : nil
                let accepted = answer != "no"
                // A WP-22 suggestion has no event yet: the answer creates it (a "no" is kept too — the detector learns).
                await updateNap(start: start, createEnd: end) {
                    $0.confirmed = accepted
                    $0.promptResponse = accepted ? .accepted : .rejected
                    $0.label = label
                }
                if label == .nap || label == .dozed {
                    ledger.napEnds.append(end)
                    if ledger.napEnds.count > 10 { ledger.napEnds.removeFirst(ledger.napEnds.count - 10) }
                    napPeekStep = 2
                    stepQuestionId[.nap] = id
                    done = false
                }
            }

        case .napPlus30(let napEnd):
            if let n = Self.firstInt(answer), (1...5).contains(n) {
                await updateNap(end: napEnd) { $0.rating30min = n }
            }

        case let .workoutConfirm(start, end):
            var event = try? await services.store.events(from: start.addingTimeInterval(-60), to: start.addingTimeInterval(60),
                                                         types: [.workout]).first
            // #41: "yes_prior" = yes, and it was the place's likely activity ("Soccer at Pickup field — right?").
            let acceptPrior = answer == PlaceQuestion.acceptPrior
            let tag = placeTag(start, end)
            if answer == "yes" || acceptPrior {
                if event == nil {
                    // A WP-22 (ALG-041) suggestion: confirming it is what logs it (suggestions are never logged on their own).
                    var e = EventRecord(at: start, loggedAt: clock.now, source: .detected, wearLocation: wearLocation,
                                        payload: .workout(WorkoutFields(end: end)))
                    if let tag { e = Self.tagged(e, with: tag, acceptActivity: acceptPrior) }
                    event = await write(e, undoable: false)
                } else if let e = event, let tag {
                    let t = Self.tagged(e, with: tag, acceptActivity: acceptPrior)
                    if t != e { event = await write(t, undoable: false) ?? e }
                }
            }
            let eventKey = event?.id.uuidString.lowercased()
            if acceptPrior {
                if let k = eventKey { ledger.workoutAnswers[k] = true }
                // r9p (D-LOAD-WALK-2): a confirmed workout is followed by the CR-10 rating, whichever way it was confirmed
                workoutPeekStep = 3
                stepQuestionId[.workoutConfirm] = id
                done = false
            } else if answer == "yes" {
                if let k = eventKey { ledger.workoutAnswers[k] = true }
                workoutPeekStep = 2
                stepQuestionId[.workoutConfirm] = id
                done = false
            } else if answer == "not_workout" {
                if let k = eventKey { ledger.workoutAnswers[k] = false }
            } else if answer.hasPrefix("type:"), let e = event {
                await editWorkout(id: e.id, edit: .setType(String(answer.dropFirst(5))))
                done = false
            } else if answer.hasPrefix("place:"), let e = event {
                await editWorkout(id: e.id, edit: .setPlace(String(answer.dropFirst(6))))
                workoutPeekStep = 3
                stepQuestionId[.workoutConfirm] = id
                done = false
            } else if answer.hasPrefix("rpe:") {
                // r9p: "rpe:0".."rpe:10" is the rating, "rpe:skip" leaves it unrated (never a 0)
                if let e = event, let n = Double(answer.dropFirst(4)), (0...10).contains(n) {
                    await editWorkout(id: e.id, edit: .setRPE(n))
                }
                workoutPeekStep = 1
            }

        case let .wearLocation(on, previous):
            let place = (answer == "same") ? (previous ?? wearLocation ?? .unknown)
                : (WearLocation(rawValue: answer) ?? previous ?? .unknown)
            await write(EventFactory.wear(.on, at: on, location: place, detectedBy: .strapEvent, promptedAt: on,
                                         answeredAt: clock.now, carriedOver: false), undoable: false)
            wearLocation = place
            ledger.wristOnAt = nil

        case let .mealCheckin(_, minutesAfter):
            if answer.hasPrefix("kss"), let k = Self.firstInt(answer), (1...9).contains(k) {
                await write(EventFactory.mealCheckin(kss: k, minutesAfter: minutesAfter, now: clock.now), undoable: false)
            }
        }

        if done {
            ledger.markAnswered(id)
            if key == .nap { napPeekStep = 1 }
            if key == .workoutConfirm { workoutPeekStep = 1 }
            if let q = lastInputs?.pending.first(where: { $0.id == id }) {
                await services.notifyCenter.withdraw(id: NotifyContent.requestID(for: q))
            }
        }
        await saveState()
    }

    static let feelWords = ["groggy", "slow", "ok", "clear", "sharp"]

    static func firstInt(_ s: String) -> Int? { SnapshotMath.firstInt(s) }

    /// Swipe down = "later" (UX §5): the question becomes the header chip; two in a row → asks half as often.
    func deferPeek(_ key: PeekKindKey) async {
        guard let kind = activeQuestion(key) else { return }
        let id = Self.questionId(kind)
        ledger.deferred[id] = clock.now
        ledger.swipeStreak[key.rawValue, default: 0] += 1
        if case .morningCheckin(let wake) = kind { ledger.checkinWake = wake }
        await saveState()
    }

    /// The header "1 question" chip: the highest-priority swiped-away question peeks again.
    func reopenDeferredQuestion() async {
        guard let kind = lastContext?.deferredQuestions.first else { return }
        ledger.deferred.removeValue(forKey: Self.questionId(kind))
        await saveState()
    }

    func editPeekTimes(_ key: PeekKindKey) {
        switch activeQuestion(key) {
        case .workoutConfirm(let start, _)?:
            Task { [weak self] in
                guard let self else { return }
                let e = try? await self.services.store.events(from: start.addingTimeInterval(-60),
                                                              to: start.addingTimeInterval(60), types: [.workout]).first
                self.workoutRequested = true
                self.workoutId = e?.id
                self.openRows.insert(WorkoutDetailState.timesRowId)
                self.push(.workout(e?.id))
                await self.refresh()
            }
        default:
            showNotice("Editing nap times isn't built yet: answer now, and fix the times later in the Log.")
        }
    }

    // MARK: Nap event edits

    /// Finds the nap (by start, else by end) and stores `change` as a new revision. `createEnd`: when no nap is
    /// stored yet (a WP-22 ALG-033 suggestion), create it as a detected nap ending there.
    private func updateNap(start: Date? = nil, end: Date? = nil, createEnd: Date? = nil,
                           _ change: (inout NapFields) -> Void) async {
        let from = (start ?? end ?? clock.now).addingTimeInterval(-6 * 3600)
        let naps = (try? await services.store.events(from: from, to: clock.now, types: [.nap])) ?? []
        var match = naps.last { e in
            guard case .nap(let f) = e.payload else { return false }
            if let start { return abs(e.at.timeIntervalSince(start)) < 60 }
            if let end { return abs(f.end.timeIntervalSince(end)) < 60 }
            return false
        }
        if match == nil, let start, let createEnd {
            match = EventRecord(at: start, loggedAt: clock.now, source: .detected,
                                payload: .nap(NapFields(end: createEnd, detector: "ALG-033", trigger: .detected)))
        }
        guard var e = match, case .nap(var f) = e.payload else {
            return showNotice("That nap is no longer in the log.")
        }
        change(&f)
        e.payload = .nap(f)
        await write(e, undoable: false)
    }

    // MARK: Housekeeping after each refresh

    func housekeeping(_ s: PresenterSnapshot) {
        var changed = false
        // UX §4.2 "Strap back on": unanswered after 1 h = same as before, marked assumed.
        if let on = ledger.wristOnAt, s.now.timeIntervalSince(on) >= 3600, !isSample {
            let previous = ledger.wearBefore ?? wearLocation
            let id = PendingQuestion.wearLocation(wristOnAt: on, previous: ledger.wearBefore).id
            ledger.markAnswered(id)
            ledger.wristOnAt = nil
            changed = true
            Task { [weak self] in
                await self?.write(EventFactory.wear(.on, at: on, location: previous, detectedBy: .strapEvent,
                                                    promptedAt: on, answeredAt: nil, carriedOver: true), undoable: false)
            }
        }
        // A new wake = a new morning check-in. The same morning's wake can move by minutes when the pipelines re-run
        // (more data), so only a wake more than 3 h from the stored one counts as new.
        let newWake = ledger.checkinWake.map { abs($0.timeIntervalSince(s.context.anchors.wake)) > 3 * 3600 } ?? true
        if !s.context.anchors.wakeAssumed, newWake, s.context.justWoke {
            ledger.checkinWake = s.context.anchors.wake
            ledger.checkinStep = 1
            ledger.checkinDone = false
            changed = true
        }
        // Step 2 belongs to one question; a different question starts at step 1.
        if let peek = s.context.peek {
            let id = Self.questionId(peek)
            if peek.key == .nap, stepQuestionId[.nap] != id { napPeekStep = 1 }
            if peek.key == .workoutConfirm, stepQuestionId[.workoutConfirm] != id { workoutPeekStep = 1 }
            // UX §5: max 4 a day — count each question once when it first peeks.
            let today = LocalDay(date: s.now, calendar: calendar)
            if !(ledger.shown[today.iso] ?? []).contains(id) {
                ledger.markShown(id, day: today)
                changed = true
            }
        }
        if changed { Task { [weak self] in await self?.saveState() } }
    }

    /// While the app is closed questions arrive as notifications (UX §5); never in SAMPLE mode (main, WP-24 wiring).
    func offerQuestionsAsNotifications() async {
        guard !isSample, let pending = lastInputs?.pending else { return }
        let now = clock.now
        for q in pending where !ledger.isAnswered(q.id) && q.expiresAt > now {
            guard let spec = NotifyContent.question(q, calendar: calendar) else { continue }
            _ = await services.notifyCenter.offer(spec, id: NotifyContent.requestID(for: q),
                                                  wanted: q.availableFrom > now ? q.availableFrom : nil,
                                                  expiresAt: q.expiresAt)
        }
    }
}
