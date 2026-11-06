import Foundation
import MGDomain

/// The Log tab (UX §7). Rows never reorder (`LogItemID` order); only each row's primary button changes.
public enum LogPresenter {
    public static let monthGridRowID = "monthGrid"
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                             "October", "November", "December"]

    public static func make(_ s: PresenterSnapshot) -> LogState {
        let confirm = confirmList(s)
        return LogState(sample: s.sample, confirmCount: confirm.count, confirmList: confirm,
                        items: LogItemID.allCases.map { row(s, $0) }, spine: spine(s), monthGrid: monthGrid(s))
    }

    // MARK: Confirm list

    /// Detected vape hits (ALG-046) plus nap / workout questions Mo swiped away (UX §7 ConfirmList).
    static func confirmList(_ s: PresenterSnapshot) -> [ConfirmItem] {
        var out = s.unconfirmedVapeHits().map { e -> ConfirmItem in
            let id = e.id.uuidString.lowercased()
            return ConfirmItem(id: id, title: "Vape hit \(s.hm(e.at))?", yes: .confirmDetected(id: id, accepted: true),
                               no: .confirmDetected(id: id, accepted: false))
        }
        for q in s.context.deferredQuestions {
            switch q {
            case let .nap(start, end):
                out.append(ConfirmItem(id: "nap:\(Int(start.timeIntervalSince1970))", title: "Nap \(s.range(start, end))?",
                                       yes: .answerPeek(.nap, answer: "nap"), no: .answerPeek(.nap, answer: "no")))
            case let .workoutConfirm(start, end):
                // #41: "Soccer at Pickup field, 17:32–18:20 — right?"; yes takes the place's likely activity.
                let tag = s.placeTag(start, end)
                let yes = tag?.likelyActivity != nil ? PlaceQuestion.acceptPrior : "yes"
                out.append(ConfirmItem(id: "workout:\(Int(start.timeIntervalSince1970))",
                                       title: tag.map { PlaceQuestion.question($0, range: s.range(start, end)) }
                                           ?? "Workout \(s.range(start, end))?",
                                       yes: .answerPeek(.workoutConfirm, answer: yes),
                                       no: .answerPeek(.workoutConfirm, answer: "not_workout")))
            default:
                continue
            }
        }
        return out
    }

    // MARK: Rows

    static func isOpen(_ s: PresenterSnapshot, _ item: LogItemID) -> Bool { s.ui.openRows.contains(item.rawValue) }

    static func plus(_ item: LogItemID, _ title: String = "+") -> ActionState {
        ActionState(id: item.rawValue, title: title, intent: .addEntry(item))
    }

    static func row(_ s: PresenterSnapshot, _ item: LogItemID) -> LogItemRow {
        switch item {
        case .vape: return vapeRow(s)
        case .medication: return medicationRow(s)
        case .caffeine: return caffeineRow(s)
        case .supplements: return supplementsRow(s)
        case .food:
            let last = s.eventsSinceWake(.food).last
            var text = "nothing yet"
            if let last, case let .food(f) = last.payload { text = "\(f.text ?? "food") \(s.hm(last.at))" }
            return LogItemRow(item: .food, title: "Food", collapsedText: text, primaryButton: plus(.food, "+ Food"),
                              isOpen: isOpen(s, .food))
        case .symptom:
            let n = s.eventsSinceWake(.symptom).count
            return LogItemRow(item: .symptom, title: "Symptom", collapsedText: n == 0 ? "none today" : "\(n) today",
                              primaryButton: plus(.symptom), isOpen: isOpen(s, .symptom))
        case .sleepy:
            var text = "none yet"
            if let e = s.eventsSinceWake(.checkin).last(where: { e in
                if case let .checkin(f) = e.payload { return f.kss != nil }
                return false
            }), case let .checkin(f) = e.payload, let kss = f.kss {
                text = "KSS \(kss) at \(s.hm(e.at))"
            }
            return LogItemRow(item: .sleepy, title: "Sleepy & check-in", collapsedText: text, primaryButton: plus(.sleepy),
                              isOpen: isOpen(s, .sleepy),
                              expansion: NowRowExpansion(actions: [ActionState(id: "pvt", title: "Reaction test, 3 min",
                                                                               intent: .startReactionTest)]))
        case .alcohol:
            let n = s.eventsSinceWake(.substance).filter { e in
                if case let .substance(f) = e.payload { return f.kind == .alcohol }
                return false
            }.count
            return LogItemRow(item: .alcohol, title: "Alcohol", collapsedText: n == 0 ? "none today" : "\(n) today",
                              primaryButton: plus(.alcohol), isOpen: isOpen(s, .alcohol))
        case .water: return waterRow(s)
        case .sore: return soreRow(s)
        case .note:
            let n = s.eventsSinceWake(.journal).count
            return LogItemRow(item: .note, title: "Note", collapsedText: n == 0 ? "" : "\(n) today",
                              primaryButton: plus(.note), isOpen: isOpen(s, .note))
        case .more:
            return LogItemRow(item: .more, title: "More ›", collapsedText: "Health record, scan, BP cuff, reaction tests",
                              primaryButton: nil, isOpen: isOpen(s, .more))
        }
    }

    /// Drinks logged on the calendar day, in ml (substance events of kind drink with a volume).
    static func drinksToday(_ s: PresenterSnapshot) -> [Double] {
        let start = s.day.start(in: s.calendar.timeZone)
        return s.events.compactMap { e -> Double? in
            guard !e.removed, e.at >= start, e.at <= s.now, case let .substance(f) = e.payload, f.kind == .drink,
                  let v = f.volumeMl, v.isFinite, v > 0 else { return nil }
            return v
        }
    }

    /// r9p (D-LOAD-WALK-2): the Water row. Drinks logged today next to the EFSA reference; never a "dehydrated" word.
    static func waterRow(_ s: PresenterSnapshot) -> LogItemRow {
        let drinks = drinksToday(s)
        let total = drinks.reduce(0, +)
        let ref = s.metric(.hydrationGoal, variant: "ALG-135", window: "day")?.value
        var text = drinks.isEmpty ? "nothing logged today" : "\(MGFormat.number(total, decimals: 0)) ml today"
        if let ref, ref.isFinite, !drinks.isEmpty { text += " of \(MGFormat.number(ref, decimals: 0))" }
        var lines: [String] = []
        if let l = LoadReadouts.hydrationLine(s) { lines.append(l) }
        if let m = s.metric(.hydrationGoal, variant: "ALG-135:sweat_rate", window: "day"), let v = m.value, v.isFinite {
            lines.append("Your sweat rate \(MGFormat.number(v, decimals: 0)) ml per hour: " + (m.note ?? ""))
        }
        lines.append("Log your weight before and after a workout (open the workout) to get its sweat loss.")
        return LogItemRow(item: .water, title: "Water", collapsedText: text, primaryButton: plus(.water, "+ Water"),
                          isOpen: isOpen(s, .water), expansion: NowRowExpansion(lines: lines))
    }

    /// r9p (D-LOAD-WALK-2): injury / soreness log (body area + 0 to 10), shown beside the load.
    static func soreRow(_ s: PresenterSnapshot) -> LogItemRow {
        let lines = LoadReadouts.bodyLines(s)
        let text = lines.first.map { lines.count > 1 ? "\($0) +\(lines.count - 1)" : $0 } ?? "none logged"
        return LogItemRow(item: .sore, title: "Sore or injured", collapsedText: text, primaryButton: plus(.sore),
                          isOpen: isOpen(s, .sore),
                          expansion: lines.isEmpty ? nil : NowRowExpansion(lines: lines))
    }

    static func vapeRow(_ s: PresenterSnapshot) -> LogItemRow {
        let hits = s.vapeHitsSinceWake()
        var text = "\(hits.count) today"
        if let last = hits.last { text += " · last \(s.hm(last.at))" }
        var lines: [String] = []
        if let m = s.metric(.vapeFirstAfterWake) {
            if let v = m.value, v.isFinite {
                lines.append("First hit \(MGFormat.number(v, decimals: 0)) min after waking.")
            } else if let note = m.note {
                lines.append("First hit after waking: \(note)")
            }
        }
        let dtap = s.settings.quickLogSurfaces["doubleTap"] ?? false
        lines.append("Double-tap on the strap logs a hit: \(dtap ? "on" : "off").")
        // T58: VapeAnalysis's two estimates. T9722 (bug 13, 2026-10-14): the per-minute HR now comes from the snapshot
        // (`minuteHR`, 30 min before the first hit to now), so the heart-rate line is no longer always blank. This is the
        // 10-min-each-side variant; ALG-063 (30 / 60 min, per session) is the other, shown on the vape detail, labelled.
        let analysis = VapeAnalysis.analyze(events: s.events, perMinuteHeartRate: s.minuteHR,
                                            days: [VapeAnalysis.Day(wake: s.context.anchors.wake, wakeRestingHR: s.metric(.rhr)?.value)],
                                            calendar: s.calendar)
        if let last = analysis.ticks.last {
            lines.append(analysisLine(last.heartRateChange, unit: "bpm"))
        } else {
            lines.append("Heart-rate change after a tick (estimate): no vape tick logged yet.")
        }
        lines.append(analysisLine(analysis.wakeCorrelation, unit: nil))
        // Hits per hour of the day (a count, for the 24 h strip).
        var perHour = [Double?](repeating: 0, count: 24)
        for e in hits {
            let h = s.calendar.component(.hour, from: e.at)
            perHour[h] = (perHour[h] ?? 0) + 1
        }
        return LogItemRow(item: .vape, title: "Vape", collapsedText: text,
                          primaryButton: ActionState(id: "hit", title: "+ Hit", intent: .quickLog(.vapeHit)),
                          isOpen: isOpen(s, .vape),
                          expansion: NowRowExpansion(lines: lines, chart: perHour, chartCaption: "hits per hour, today"))
    }

    /// "<label>: <value> <unit>" with its value, or "<label>: <reason>" blank (`Estimate.label` already carries the
    /// "(estimate)" suffix — CLAUDE.md rule 4, raw counts/derived values are never shown unlabelled).
    static func analysisLine(_ e: VapeAnalysis.Estimate, unit: String?) -> String {
        guard let v = e.value, v.isFinite else { return "\(e.label): \(e.reason ?? "not enough data yet")" }
        let number = MGFormat.number(v, decimals: unit == nil ? 2 : 1)
        return unit.map { "\(e.label): \(number) \($0)" } ?? "\(e.label): \(number)"
    }

    static func medicationRow(_ s: PresenterSnapshot) -> LogItemRow {
        let lines = ["Tracks and reminds only.",
                     "Any prescription cut-down target is yours and your prescriber's."]
        // T102: one tap per preset ("I took a 30"); any other dose goes through the form.
        // T9973: the presets are the user's own Medications list (name + strength), none written in source. With more
        // than one medication the button carries the name too.
        let listed = MedicationPresets.presets(from: s.settings.presetLists)
        let manyNames = Set(listed.map { $0.name.lowercased() }).count > 1
        let presets = listed.map {
            ActionState(id: "took-\($0.name.lowercased())-\(Int($0.mg))",
                        title: manyNames ? "Took \($0.title)" : "Took \(Int($0.mg)) mg",
                        intent: .quickLog(.medication(name: $0.title)))
        }
        guard let sched = s.prescriptionSchedules().first else {
            let medications = s.medicationsSinceWake().filter { $0.fields.category != .supplement }.count
            let pills = s.eventsSinceWake(.substance).filter {
                guard case let .substance(fields) = $0.payload else { return false }
                return fields.kind == .pill
            }.count
            let n = medications + pills
            return LogItemRow(item: .medication, title: "Pills", collapsedText: n == 0 ? "none today" : "\(n) today",
                              primaryButton: plus(.medication), isOpen: isOpen(s, .medication),
                              expansion: NowRowExpansion(lines: lines, actions: presets))
        }
        let title = PresenterSnapshot.scheduleTitle(sched)
        if let taken = s.taken(sched) {
            return LogItemRow(item: .medication, title: title, collapsedText: "taken \(s.hm(taken.at)) ✓",
                              primaryButton: nil, isOpen: isOpen(s, .medication), expansion: NowRowExpansion(lines: lines, actions: presets))
        }
        let due = s.scheduleTime(sched).map { "not yet · schedule \(s.hm($0))" } ?? "not yet"
        return LogItemRow(item: .medication, title: title, collapsedText: due,
                          primaryButton: ActionState(id: "took", title: "Took it", intent: .quickLog(.medication(name: title))),
                          isOpen: isOpen(s, .medication), expansion: NowRowExpansion(lines: lines, actions: presets))
    }

    static func caffeineRow(_ s: PresenterSnapshot) -> LogItemRow {
        var text = "none today"
        if let now = s.number(.caffeineNow) {
            text = "\(MGFormat.number(now, decimals: 0)) mg in you"
        } else if !s.caffeineSinceWake().isEmpty {
            text = "\(s.caffeineSinceWake().count) today"
        }
        let open = s.caffeineSinceWake().last { $0.fields.finishedAt == nil }
        let drink = s.settings.usualDrink ?? s.settings.drinkPresets.first?.name ?? "Coffee"
        let button = open != nil
            ? ActionState(id: "finish", title: "Finish", intent: .quickLog(.drinkFinish))
            : ActionState(id: "start", title: "Start", intent: .quickLog(.drinkStart(preset: drink)))
        var lines = CaffeineDrinks.lines(s)
        if let bed = s.number(.caffeineBedtime) {
            var t = "Bedtime \(MGFormat.number(bed, decimals: 0)) mg"
            if let l = s.caffeineLimitMg { t += " — your limit is \(MGFormat.number(l, decimals: 0))" }
            lines.append(t + ".")
        }
        lines.append(CaffeineDrinks.halfLifeLine(s))
        lines.append(CaffeineDrinks.sleepLine(s))
        return LogItemRow(item: .caffeine, title: "Caffeine", collapsedText: text, primaryButton: button,
                          isOpen: isOpen(s, .caffeine),
                          expansion: NowRowExpansion(lines: lines, chart: s.caffeineCurve.map { Optional($0.value) },
                                                     chartCaption: "mg in you → bedtime",
                                                     methods: s.methodsStrip("G-CAFF"),
                                                     algorithmPanel: CaffeinePanelPresenter.make(s)))
    }

    static func supplementsRow(_ s: PresenterSnapshot) -> LogItemRow {
        let taken = s.medicationsSinceWake().filter { $0.fields.category == .supplement && $0.fields.status != .skipped }
        let hasStack = s.settings.schedules.contains { $0.kind == .supplement }
        let text: String
        if taken.isEmpty {
            text = hasStack ? "stack not logged yet" : "none saved yet"
        } else {
            text = hasStack ? "stack ✓ \(s.hm(taken[0].event.at))" : "\(taken.count) logged"
        }
        let button = hasStack && taken.isEmpty
            ? ActionState(id: "stack", title: "Log stack", intent: .quickLog(.supplementsStack))
            : plus(.supplements)
        return LogItemRow(item: .supplements, title: "Supplements", collapsedText: text, primaryButton: button,
                          isOpen: isOpen(s, .supplements))
    }

    // MARK: Day spine (Vernier): ○ logged, ■ measured, │ vape stroke, bar for a drink's sip time

    static func spine(_ s: PresenterSnapshot) -> [SpineEntry] {
        let start = s.day.start(in: s.calendar.timeZone)
        return s.events.filter { $0.at >= start && $0.at <= s.now && !$0.removed }.sorted { $0.at < $1.at }
            .compactMap { spineEntry(s, $0) }
    }

    static func spineEntry(_ s: PresenterSnapshot, _ e: EventRecord) -> SpineEntry? {
        var timing: String?
        if let logged = e.loggedAt, abs(logged.timeIntervalSince(e.at)) >= 60 {
            timing = "happened \(s.hm(e.at)) · logged \(s.hm(logged))"
        }
        func entry(_ mark: SpineEntry.Mark, _ title: String, end: Date? = nil, unconfirmed: Bool = false) -> SpineEntry {
            SpineEntry(id: e.id, mark: mark, at: e.at, end: end, title: title, timing: timing, unconfirmed: unconfirmed)
        }
        switch e.payload {
        case let .substance(f):
            switch f.kind {
            case .vapeTick, .vape:
                if f.vape?.detectedStatus == .rejected { return nil }
                return entry(.vapeStroke, "Vape hit", unconfirmed: f.vape?.detectedStatus == .unconfirmed)
            case .caffeine:
                let mg = f.caffeineMg.map { " · \(MGFormat.number($0, decimals: 0)) mg" } ?? ""
                return entry(.drinkBar, (f.product ?? "Caffeine") + mg, end: f.finishedAt)
            case .alcohol: return entry(.logged, f.product ?? "Alcohol")
            case .drink:
                let ml = f.volumeMl.map { " · \(MGFormat.number($0, decimals: 0)) ml" } ?? ""
                return entry(.logged, (f.product ?? "Water") + ml)
            case .pill:
                let mg = f.pillMg.map { " · \(MGFormat.number($0, decimals: 0)) mg" } ?? ""
                return entry(.logged, (f.product ?? "Pill") + mg)
            case .other: return entry(.logged, f.product ?? "Substance")
            }
        case let .medication(f):
            if f.status == .skipped { return entry(.logged, "\(f.name ?? "Medication") — skipped") }
            return entry(.logged, DialPresenter.medicationLabel(f))
        case let .food(f):             // quality, calories and typed macros on the line (tracker #42, T62)
            func g(_ label: String, _ v: Double?) -> String? {
                v.map { "\(label) \(ProfileRecords.num($0)) g" }
            }
            let extra = [f.quality.map { "quality \($0)/5" }, f.kcal.map { "\(MGFormat.number($0, decimals: 0)) kcal" },
                         g("protein", f.proteinG), g("carbs", f.carbG), g("fat", f.fatG)].compactMap { $0 }
            return entry(.logged, ([f.text ?? "Food"] + extra).joined(separator: " · "))
        case let .symptom(f):
            let word = f.stoolWord.map { " · \($0.rawValue.replacingOccurrences(of: "_", with: " "))" } ?? ""
            return entry(.logged, f.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalizedFirst + word)
        case let .checkin(f): return entry(.logged, f.kss.map { "KSS \($0)" } ?? "Check-in")
        case let .reactionTest(f): return entry(.measured, "Reaction test · \(MGFormat.number(f.meanRtMs, decimals: 0)) ms")
        case let .bpCuff(f):
            return entry(.measured, "BP \(MGFormat.number(f.systolic, decimals: 0))/\(MGFormat.number(f.diastolic, decimals: 0))")
        case let .journal(f): return entry(.logged, f.text ?? "Note")
        case .scan: return entry(.measured, "Scan")
        case let .record(f):
            if f.kind == .soreness || f.kind == .injury {
                let area = [f.side.flatMap { $0 == .notApplicable ? nil : $0.rawValue }, f.bodyPart].compactMap { $0 }
                    .joined(separator: " ")
                return entry(.logged, "\(f.kind == .injury ? "Injury" : "Sore") \(area)" + (f.level.map { " \($0)/10" } ?? ""))
            }
            return entry(.measured, "Health record")
        default: return nil
        }
    }

    // MARK: Month grid

    static func monthGrid(_ s: PresenterSnapshot) -> MonthGridState? {
        let cal = s.calendar
        guard let range = cal.range(of: .day, in: .month, for: s.now) else { return nil }
        let c = cal.dateComponents([.year, .month], from: s.now)
        guard let y = c.year, let m = c.month else { return nil }
        let days = range.compactMap { LocalDay(iso: String(format: "%04d-%02d-%02d", y, m, $0)) }
        let today = LocalDay(date: s.now, calendar: cal)
        func dayOf(_ e: EventRecord) -> LocalDay { LocalDay(date: e.at, calendar: cal) }
        var rows: [MonthGridRow] = []
        for sched in s.settings.schedules {
            let taken = Set(s.monthEvents.compactMap { e -> LocalDay? in
                guard case let .medication(f) = e.payload, !e.removed, f.status != .skipped,
                      f.scheduleId == sched.id || f.name == sched.name else { return nil }
                return dayOf(e)
            })
            let marks: [Bool?] = days.map { d in
                if taken.contains(d) { return true }
                guard d <= today, scheduled(sched, on: d, calendar: cal) else { return nil }
                return d < today ? false : nil
            }
            rows.append(MonthGridRow(item: sched.kind == .supplement ? .supplements : .medication,
                                     title: PresenterSnapshot.scheduleTitle(sched), marks: marks))
        }
        let logged: [(LogItemID, SubstanceFields.Kind, String)] = [(.vape, .vape, "Vape"), (.caffeine, .caffeine, "Caffeine"),
                                                                  (.alcohol, .alcohol, "Alcohol")]
        for (item, kind, title) in logged {
            let days0 = Set(s.monthEvents.compactMap { e -> LocalDay? in
                guard !e.removed, case let .substance(f) = e.payload else { return nil }
                let matches = f.kind == kind || (kind == .vape && f.kind == .vapeTick)
                guard matches else { return nil }
                if f.vape?.detectedStatus == .rejected { return nil }
                return dayOf(e)
            })
            rows.append(MonthGridRow(item: item, title: title, marks: days.map { days0.contains($0) ? true : nil }))
        }
        // r9v (G4): the entries of each day from the month's events already in the snapshot (no extra read).
        var byDay: [String: [SpineEntry]] = [:]
        var totals: [String: Int] = [:]
        for e in s.monthEvents.sorted(by: { $0.at < $1.at }) where !e.removed {
            guard let entry = spineEntry(s, e) else { continue }
            let key = dayOf(e).iso
            totals[key, default: 0] += 1
            if byDay[key, default: []].count < MonthGridState.entryCap { byDay[key, default: []].append(entry) }
        }
        return MonthGridState(title: monthNames[(m - 1) % 12], days: days, rows: rows,
                              isCollapsed: !s.ui.openRows.contains(monthGridRowID),
                              entries: byDay, entryTotals: totals.filter { $0.value > MonthGridState.entryCap })
    }

    /// Whether a schedule applies on a day (no `days` = daily).
    static func scheduled(_ sched: MedSchedule, on day: LocalDay, calendar: Calendar) -> Bool {
        guard let days = sched.days, !days.isEmpty else { return true }
        let wd = calendar.component(.weekday, from: day.start(in: calendar.timeZone))
        let map: [Int: MedSchedule.Weekday] = [1: .sun, 2: .mon, 3: .tue, 4: .wed, 5: .thu, 6: .fri, 7: .sat]
        guard let w = map[wd] else { return false }
        return days.contains(w)
    }
}
