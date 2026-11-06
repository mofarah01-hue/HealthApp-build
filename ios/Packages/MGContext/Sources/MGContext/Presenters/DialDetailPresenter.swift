import Foundation
import MGDomain

/// P03: what each Sundial tap opens (a ring, a rim mark, an arc, the focus band, the caffeine curve, the plan) and the
/// key chips under the dial. It words and arranges what the other presenters already compute (Strain, Night, Tonight,
/// the Log, the callouts); its only numbers of its own are EventHRResponse's labelled heart-rate windows. A blank keeps
/// the reason the presenter that owns the number gave.
enum DialDetailPresenter {
    // MARK: Sheets

    /// 0.C-2 (r8g): `night` and `tonight` are the states the screens already built this refresh; nil builds them here
    /// (tests, previews). Building them again for every dial made Night and Tonight run twice a minute.
    static func make(_ s: PresenterSnapshot, dial: DialState, night builtNight: NightState? = nil,
                     tonight builtTonight: TonightState? = nil) -> [DialDetail] {
        var out: [DialDetail] = []
        func add(_ d: DialDetail) { if !out.contains(where: { $0.id == d.id }) { out.append(d) } }
        let night = builtNight ?? NightPresenter.make(s)
        let plan = builtTonight ?? TonightPresenter.make(s)
        let stages: Set<DialArc.Kind> = [.deep, .light, .rem, .awake, .unstaged]
        for r in dial.rings {
            switch r.kind {
            case .strain: add(strain(s, r))
            case .recovery: add(recovery(s, r))
            case .sleep: add(sleep(s, night, plan.need, ring: r))
            case .stress: add(stress(s, r))
            case .burn, .eaten: add(tally(r))
            }
        }
        // 0.C-3: the vape analysis, the hit list and the event lookup are worked out once, not once per mark.
        let vape = dial.rimEvents.contains { $0.kind == .vape } ? VapeContext(s) : nil
        for e in dial.rimEvents { add(mark(s, e, dial, vape: vape)) }
        if dial.arcs.contains(where: { stages.contains($0.kind) }) || dial.ticks.contains(where: { $0.kind == .wakeMarker }) {
            add(sleep(s, night, plan.need, ring: nil))
        }
        add(tonight(s, plan))
        if !dial.caffeineCurve.isEmpty || dial.ticks.contains(where: { $0.kind == .caffeineCutoff }) {
            add(caffeine(s, nil, dial))
        }
        for arc in dial.arcs {
            switch arc.kind {
            case .workout: add(workout(s, arc))
            case .nap, .napUnconfirmed: add(nap(s, arc))
            case .strapOff: add(strapOff(s, arc))
            default: break
            }
        }
        return out.map { d -> DialDetail in
            var d = d
            let said = d.visuals.compactMap(describe).joined(separator: " ")
            d.visualSummary = said.isEmpty ? nil : said
            return d
        }
    }

    /// One chip per rim mark kind present; it opens the newest mark of that kind.
    static func legendItems(_ s: PresenterSnapshot, dial: DialState) -> [DialLegendItem] {
        let pieces = DialPresenter.legendPieces(s, shows: s.settings.frontPage.shows)
        let tones: [RimEvent.Kind: InkTone] = [.vape: .body, .medication: .ink, .caffeine: .caffeine, .food: .ink2,
                                               .supplement: .focus]
        return RimEvent.Kind.allCases.compactMap { kind -> DialLegendItem? in
            guard let newest = dial.rimEvents.filter({ $0.kind == kind }).max(by: { $0.at < $1.at }) else { return nil }
            return DialLegendItem(id: kind.rawValue, glyph: DialPresenter.legendGlyph[kind] ?? "●",
                                  text: pieces[kind] ?? kind.rawValue, tone: tones[kind] ?? .ink,
                                  target: .mark(kind, at: newest.at))
        }
    }

    // MARK: Rings

    private static func strain(_ s: PresenterSnapshot, _ r: DialRing) -> DialDetail {
        let g = WorkoutGuidance.make(s)
        let target: DisplayValue = g.targetLow.flatMap { lo in
            g.targetHigh.map { est(s, "\(Int(lo))–\(Int($0))", method: "T128 guidance") }
        } ?? .blank(reason: g.reason ?? g.text, receipt: nil)
        let left: DisplayValue = g.remaining.map { est(s, MGFormat.number($0, decimals: 0), method: "T128 guidance") }
            ?? .blank(reason: g.reason ?? "No strain yet today, so nothing to subtract.", receipt: nil)
        let workouts = workoutItems(s)
        return DialDetail(
            id: .ring(.strain), tone: .body, kicker: "STRAIN · TODAY SO FAR",
            title: r.value.isBlank ? "—" : "\(DialPresenter.strainText(s.dayStrain())) of 21", value: r.value,
            visuals: [ring(r)] + week(s, "strain", max: 21),
            rows: [LabeledValue(id: "target", label: "Target", value: target,
                                caption: g.band.map { "\($0.word) day · \(WorkoutGuidance.label)" }),
                   LabeledValue(id: "left", label: "Left today", value: left)],
            itemsTitle: workouts.isEmpty ? nil : "Workouts today", items: workouts, blankReason: r.value.blankReason,
            actions: [action("explore", "Strain in Explore ›", .openMetric(key: MetricKey.strain.rawValue, variant: nil))])
    }

    private static let componentNames = ["hrv": "HRV status", "sleep": "Sleep", "recovery_time": "Recovery time",
                                         "load_balance": "Training load balance", "stress": "Recent stress"]

    private static func recovery(_ s: PresenterSnapshot, _ r: DialRing) -> DialDetail {
        let rows = (s.recovery?.components ?? []).map { c -> LabeledValue in
            let value: DisplayValue = c.points.map { est(s, MGFormat.number($0, decimals: 0), unit: "/100", method: "ALG-160") }
                ?? .blank(reason: c.reason ?? "Not scored last night.", receipt: nil)
            return LabeledValue(id: c.name, label: componentNames[c.name] ?? c.name, value: value,
                                caption: c.points == nil ? nil : "our estimate · weight \(Int((c.weight * 100).rounded())) %")
        }
        return DialDetail(
            id: .ring(.recovery), tone: .focus, kicker: "RECOVERY · \(recoveryWord(s))",
            title: r.value.isBlank ? "—" : text(r.value), value: r.value,
            visuals: [ring(r)] + week(s, "recovery_score", max: 100), rows: rows, blankReason: r.value.blankReason,
            actions: [action("recovery", "Recovery on Today ›", .toggleRow(id: TodayPresenter.RowID.recovery))])
    }

    /// The ring (`ring` set) and the stage arcs (`ring` nil) open the same night.
    private static func sleep(_ s: PresenterSnapshot, _ n: NightState, _ need: [NeedPart], ring r: DialRing?) -> DialDetail {
        var visuals: [DialDetailVisual] = r.map { [ring($0)] } ?? []
        if !n.stages.isEmpty { visuals.append(.stages(n.stages)) }
        visuals += week(s, "sleep_total", max: nil, unit: "min")
        let slept = text(n.slept)
        var actions = [action("night", "Last night ›", .openNight(nil)), action("tonight", "Tonight ›", .openTonight)]
        // Nov 6 2026: a night that is not processed (and not already coming down) gets the Process now button first.
        if n.fill == .notProcessed, s.sleepNightStatus(s.sleepFill()).phase == .notProcessed {
            actions.insert(action("process", "Process now", .processSleepNow), at: 0)
        }
        return DialDetail(
            id: r == nil ? .sleep : .ring(.sleep), tone: .sleep, kicker: "SLEEP · \(nightWord(s))",
            title: n.slept.isBlank ? "—" : (n.needed.isBlank ? slept : "\(slept) of \(text(n.needed))"), value: n.slept,
            sentence: joinedOrNil([n.sourceLine.isEmpty ? nil : n.sourceLine, n.alsoLine.isEmpty ? nil : n.alsoLine, n.shortBy]),
            visuals: visuals,
            rows: sleepRows(s, n) + need.map { LabeledValue(id: $0.label, label: $0.label, value: $0.value) },
            blankReason: n.blankReason,
            actions: actions,
            legacyIntent: r == nil ? .openNight(nil) : nil)
    }

    private static func stress(_ s: PresenterSnapshot, _ r: DialRing) -> DialDetail {
        let top = ["score_0_3": 3.0, "score_0_100": 100.0][s.dayStress()?.unit ?? ""]
        // D-POP-PRIOR (R9m): say what the score is compared with: the population value or your own days.
        let basis = s.dayStress()?.note.flatMap { n in
            n.range(of: "baseline: ").map { String(n[$0.upperBound...]).split(separator: ";").first.map(String.init) } ?? nil
        }
        return DialDetail(
            id: .ring(.stress), tone: .ink2, kicker: "BODY AROUSAL · TODAY SO FAR", title: text(r.value), value: r.value,
            sentence: basis.map { "Compared with: \($0)." },
            visuals: [ring(r)] + week(s, "stress", max: top), blankReason: r.value.blankReason,
            actions: [action("explore", "Body arousal in Explore ›", .openMetric(key: MetricKey.stress.rawValue, variant: nil))])
    }

    /// Burned and eaten: the ring's own value and detail.
    private static func tally(_ r: DialRing) -> DialDetail {
        let burn = r.kind == .burn
        return DialDetail(
            id: .ring(r.kind), tone: burn ? .ink2 : .caffeine, kicker: "\(r.title.uppercased()) · TODAY",
            title: text(r.value), value: r.value, sentence: r.detail, visuals: [ring(r)], blankReason: r.value.blankReason,
            actions: [burn ? action("goal", "Set the goal in Preferences ›", .openPreferences)
                           : action("food", "Food log ›", .openLogItem(.food))])
    }

    // MARK: Rim marks

    private static func mark(_ s: PresenterSnapshot, _ e: RimEvent, _ dial: DialState, vape ctx: VapeContext?) -> DialDetail {
        switch e.kind {
        case .vape: return vape(s, e, ctx ?? VapeContext(s))
        case .medication: return medication(s, e)
        case .caffeine: return caffeine(s, e, dial)
        case .food, .supplement: return logged(s, e)
        }
    }

    /// What every vape mark's sheet shares: today's hits, the first-hit-after-waking figure, the events by id.
    private struct VapeContext {
        let hits: [EventRecord]
        let firstValue: DisplayValue
        let byID: [String: EventRecord]
        /// The hit list without a selection; a mark's sheet flips one row.
        let items: [DialDetailItem]
        let indexByID: [String: Int]

        init(_ s: PresenterSnapshot) {
            hits = s.vapeHitsSinceWake()
            let first = VapeAnalysis.analyze(events: s.events, perMinuteHeartRate: [],
                                             days: [VapeAnalysis.Day(wake: s.context.anchors.wake, wakeRestingHR: nil)],
                                             calendar: s.calendar).days.first?.minutesToFirstTick
            firstValue = first?.value.map {
                DialDetailPresenter.est(s, MGFormat.number($0, decimals: 0), unit: "min", method: "T58")
            } ?? .blank(reason: first?.reason ?? "No hit logged after waking.", receipt: nil)
            byID = Dictionary(s.events.filter { $0.type == .substance }.map { (DialPresenter.id($0), $0) },
                              uniquingKeysWith: { a, _ in a })
            items = hits.map { h in
                DialDetailItem(id: DialPresenter.id(h), title: s.hm(h.at),
                               detail: DialDetailPresenter.unconfirmed(h) ? "detected, not confirmed" : nil)
            }
            var idx: [String: Int] = [:]
            for (i, item) in items.enumerated() { idx[item.id] = i }
            indexByID = idx
        }
    }

    private static func vape(_ s: PresenterSnapshot, _ e: RimEvent, _ ctx: VapeContext) -> DialDetail {
        let hr = EventHRResponse.vape(s, at: e.at, event: e.eventID.flatMap { ctx.byID[$0] })
        let hits = ctx.hits
        let firstValue = ctx.firstValue
        var items = ctx.items
        if let id = e.eventID, let i = ctx.indexByID[id] { items[i].isSelected = true }
        var response: DisplayValue = .blank(reason: s.dayExtras?.nicotineReason ?? "Not computed yet.", receipt: nil)
        if let n = s.dayExtras?.nicotine {
            let parts = [n.hrDeltaBpm.map { "\(MetricText.signed($0, decimals: 1)) bpm" },
                         n.rmssdDeltaMs.map { "\(MetricText.signed($0, decimals: 1)) ms HRV" }].compactMap { $0 }
            if !parts.isEmpty { response = est(s, parts.joined(separator: " · "), method: "ALG-063") }
        }
        let around = s.minuteHR.filter { abs(Double($0.ts) - e.at.timeIntervalSince1970) <= 600 }
            .map { TimedValue(at: Date(timeIntervalSince1970: Double($0.ts)), value: $0.bpm) }
        var actions: [ActionState] = []
        if e.hollow, let id = e.eventID {
            actions = [action("yes", "Yes", .confirmDetected(id: id, accepted: true)),
                       action("no", "No", .confirmDetected(id: id, accepted: false))]
        }
        actions.append(action("log", "Vape log ›", .openLogItem(.vape)))
        return DialDetail(
            id: .mark(.vape, at: e.at), tone: .body, kicker: "VAPE · HIT", title: s.hm(e.at),
            sentence: e.hollow ? "Detected, not confirmed." : "Confirmed.",
            visuals: around.isEmpty ? [] : [.hrAround(around, at: e.at, before: hr.before, after: hr.after)],
            rows: [hrRow(s, hr),
                   LabeledValue(id: "hits", label: "Hits today", value: plain(s, "\(hits.count)")),
                   LabeledValue(id: "first", label: "First hit after waking (estimate)", value: firstValue),
                   LabeledValue(id: "response", label: "Day response (ALG-063)", value: response)],
            itemsTitle: "Hits today", items: items,
            actions: actions, legacyIntent: .openLogItem(.vape))
    }

    private static func medication(_ s: PresenterSnapshot, _ e: RimEvent) -> DialDetail {
        let x = s.dayExtras
        let name = (e.label ?? "").lowercased()
        var rows: [LabeledValue] = []
        var visuals: [DialDetailVisual] = []
        if let m = x?.medication, !name.isEmpty, name.contains(m.name.lowercased()) || m.name.lowercased().contains(name) {
            rows.append(LabeledValue(id: "level", label: "Level now", value: m.levelNow.map {
                est(s, MGFormat.number($0 * 100, decimals: 0), unit: "% of peak", method: "ALG-143")
            } ?? .blank(reason: "No level yet.", receipt: nil)))
            if let peak = m.peakAt {
                rows.append(LabeledValue(id: "peak", label: "Peak", value: est(s, s.hm(peak), method: "ALG-143")))
            }
            visuals.append(.curve(m.curve, window: nil, marks: [e.at], unit: nil))
        } else {
            rows.append(LabeledValue(id: "level", label: "Level now", value: .blank(
                reason: x?.medicationReason ?? "No level curve for this medication.", receipt: nil)))
        }
        rows.append(hrRow(s, EventHRResponse.medication(s, at: e.at)))
        rows.append(LabeledValue(id: "stress", label: "Body arousal change after the dose", value: .blank(
            reason: "Body arousal has no times yet: it is a day score, so its change after a dose can't be shown.",
            receipt: nil)))
        if let onsets = s.metric(.stressOnsets), onsets.value != nil {
            rows.append(LabeledValue(id: "onsets", label: "Arousal rises today", value: s.display(onsets)))
        }
        rows += (x?.adherence ?? []).map { a in
            LabeledValue(id: "adherence-\(a.name)", label: "\(a.name) taken today",
                         value: a.reason.map { DisplayValue.blank(reason: $0, receipt: nil) } ?? plain(s, "\(a.taken) of \(a.due)"))
        }
        return DialDetail(id: .mark(.medication, at: e.at), tone: .ink, kicker: "MEDICATION · \(s.hm(e.at))",
                          title: e.label ?? "Medication", visuals: visuals, rows: rows,
                          actions: [action("log", "Medication log ›", .openLogItem(.medication))],
                          legacyIntent: .openLogItem(.medication))
    }

    /// A drink (`e` set) and the body curve (`e` nil) open the same facts about caffeine in you.
    private static func caffeine(_ s: PresenterSnapshot, _ e: RimEvent?, _ dial: DialState) -> DialDetail {
        let now = s.caffeineCurve.last { $0.at <= s.now }
        let inYou: DisplayValue = now.map { est(s, MGFormat.number($0.value, decimals: 0), unit: "mg", method: "ALG-060") }
            ?? .blank(reason: "No caffeine logged today.", receipt: nil)
        let cut = DialPresenter.callout(s, .topRight, .cutoff)
        let rows = [
            LabeledValue(id: "now", label: "In you now", value: inYou),
            LabeledValue(id: "bed", label: "At bedtime", value: s.display(.caffeineBedtime, missing: "No caffeine logged today."),
                         caption: s.caffeineLimitMg.map { "your limit \(MGFormat.number($0, decimals: 0)) mg" }),
            LabeledValue(id: "cutoff", label: cut.caption.capitalizedFirst,
                         value: cut.value ?? .blank(reason: "No caffeine cut-off computed yet.", receipt: nil)),
            LabeledValue(id: "halflife", label: "Half-life used", value: plain(s, CaffeineHalfLife.from(s.metrics).words))]
        let marks = dial.ticks.filter { $0.kind == .caffeineCutoff }.map(\.at)
        return DialDetail(
            id: e.map { .mark(.caffeine, at: $0.at) } ?? .caffeine, tone: .caffeine,
            kicker: e.map { "CAFFEINE · \(s.hm($0.at))" } ?? "CAFFEINE · IN YOU",
            title: e?.label ?? now.map { "\(MGFormat.number($0.value, decimals: 0)) mg now" } ?? "None logged today",
            value: inYou, sentence: e.map { d in d.end.map { "Sipped \(s.range(d.at, $0))." } ?? "Started \(s.hm(d.at))." },
            visuals: s.caffeineCurve.isEmpty ? [] : [.curve(s.caffeineCurve, window: nil, marks: marks, unit: "mg")],
            rows: rows, actions: [action("log", "Caffeine log ›", .openLogItem(.caffeine))],
            legacyIntent: .openLogItem(.caffeine))
    }

    /// Food and supplements: what was logged and when.
    private static func logged(_ s: PresenterSnapshot, _ e: RimEvent) -> DialDetail {
        let food = e.kind == .food
        var rows: [LabeledValue] = []
        if case let .food(f)? = s.events.first(where: { DialPresenter.id($0) == e.eventID })?.payload {
            if let k = f.kcal, k.isFinite {
                rows.append(LabeledValue(id: "kcal", label: "Calories", value: plain(s, MGFormat.grouped(Int(k.rounded())), unit: "kcal")))
            }
            for (id, label, grams) in [("protein", "Protein", f.proteinG), ("carbs", "Carbs", f.carbG), ("fat", "Fat", f.fatG)] {
                if let g = grams, g.isFinite {
                    rows.append(LabeledValue(id: id, label: label, value: plain(s, MGFormat.number(g, decimals: 0), unit: "g")))
                }
            }
        }
        let item: LogItemID = food ? .food : .supplements
        return DialDetail(id: .mark(e.kind, at: e.at), tone: food ? .ink2 : .focus,
                          kicker: "\(food ? "FOOD" : "SUPPLEMENTS") · \(s.hm(e.at))", title: e.label ?? (food ? "Food" : "Supplements"),
                          rows: rows, actions: [action("log", food ? "Food log ›" : "Supplements log ›", .openLogItem(item))],
                          legacyIntent: .openLogItem(item))
    }

    // MARK: Focus, plan, arcs

    private static func tonight(_ s: PresenterSnapshot, _ t: TonightState) -> DialDetail {
        let w = t.smartWake
        let wake: DisplayValue = w.windowStart.flatMap { a in w.windowEnd.map { est(s, s.range(a, $0), method: "smart wake window") } }
            ?? .blank(reason: w.noPlanReason ?? "No wake plan yet.", receipt: nil)
        return DialDetail(
            id: .tonight, tone: .sleep, kicker: "TONIGHT", title: "Bed \(s.hm(t.bedtime))", sentence: t.summaryLine,
            rows: [LabeledValue(id: "bed", label: "Bedtime", value: DialPresenter.bedtimeValue(s)),
                   LabeledValue(id: "need", label: "Sleep need", value: t.needTotal),
                   LabeledValue(id: "wake", label: "Smart wake window", value: wake)],
            actions: [action("tonight", "Tonight ›", .openTonight)], legacyIntent: .openTonight)
    }

    private static func workout(_ s: PresenterSnapshot, _ arc: DialArc) -> DialDetail {
        let e = s.eventsOf(.workout).first { abs($0.at.timeIntervalSince(arc.start)) < 60 }
        let summary = e.flatMap { e in s.workoutHistory.first { $0.event.id == e.id } }
            .map { WorkoutSummaryPresenter.make(s, $0, openPrefix: "dial") }
        return DialDetail(id: .workout(start: arc.start), tone: .body, kicker: "WORKOUT",
                          title: s.range(arc.start, arc.end), rows: summary?.headline ?? [duration(s, arc)],
                          actions: [action("open", "Workout ›", .openWorkout(id: e?.id))],
                          legacyIntent: .openWorkout(id: nil))
    }

    private static func nap(_ s: PresenterSnapshot, _ arc: DialArc) -> DialDetail {
        let asked = arc.kind == .napUnconfirmed
        return DialDetail(id: .nap(start: arc.start), tone: .sleep, kicker: asked ? "NAP · NOT CONFIRMED" : "NAP",
                          title: s.range(arc.start, arc.end), sentence: asked ? "Not confirmed yet." : nil,
                          rows: [duration(s, arc)])
    }

    private static func strapOff(_ s: PresenterSnapshot, _ arc: DialArc) -> DialDetail {
        DialDetail(id: .strapOff(start: arc.start), tone: .mute, kicker: "STRAP OFF", title: s.range(arc.start, arc.end),
                   sentence: "Nothing recorded while the strap was off.", rows: [duration(s, arc)])
    }

    // MARK: Sleep sheet: which night, and what it adds (T10023, §1 #19)

    /// "LAST NIGHT" when the night's wake day is today; else the day it belongs to ("NIGHT TO MON 12 OCT"), so a sheet
    /// built from another day never claims to be last night.
    static func nightWord(_ s: PresenterSnapshot) -> String {
        if s.day == LocalDay(date: s.now, calendar: s.calendar) { return "LAST NIGHT" }
        return "NIGHT TO " + MGFormat.kickerDate(s.day.start(in: s.calendar.timeZone).addingTimeInterval(12 * 3600),
                                                  calendar: s.calendar)
    }

    /// "THIS MORNING" until noon of the wake day, "TODAY" after it; another day's date when the readings are not today's.
    static func recoveryWord(_ s: PresenterSnapshot) -> String {
        guard s.day == LocalDay(date: s.now, calendar: s.calendar) else {
            return MGFormat.kickerDate(s.day.start(in: s.calendar.timeZone).addingTimeInterval(12 * 3600), calendar: s.calendar)
        }
        return s.calendar.component(.hour, from: s.now) < 12 ? "THIS MORNING" : "TODAY"
    }

    private static func joinedOrNil(_ parts: [String?]) -> String? {
        let said = parts.compactMap { $0 }.joined(separator: " · ")
        return said.isEmpty ? nil : said
    }

    private static func strapReceipt(_ at: Date) -> Receipt {
        Receipt(computedOn: .strap, tier: .strap, at: at, method: "strap sleep flag (ALG-150)")
    }

    /// Sleep onset, wake time, time to fall asleep, resting heart rate and the strap's SpO₂ byte. None of it while the night
    /// is not processed. The latency is blank with its reason under ALG-150 (no bed time to count from); the SpO₂ byte is a
    /// raw strap byte and carries CLAUDE.md rule 4's label until the per-strap check passes.
    private static func sleepRows(_ s: PresenterSnapshot, _ n: NightState) -> [LabeledValue] {
        if n.fill == .notProcessed {
            let waiting = DisplayValue.blank(reason: n.blankReason ?? PresenterSnapshot.notProcessedWords, receipt: nil)
            return [("onset", "Went to sleep"), ("wake", "Woke"), ("latency", "Time to fall asleep"),
                    ("rhr", "Resting heart rate"), ("spo2", "SpO₂ (strap byte)")]
                .map { LabeledValue(id: $0.0, label: $0.1, value: waiting) }
        }
        let span = s.strapAsleepSpan()
        func clock(_ key: MetricKey, strap: Date?) -> DisplayValue {
            if let d = strap { return s.worded(s.hm(d), receipt: strapReceipt(d)) }
            if let m = s.metric(key), let t = MetricText.instant(m) { return s.worded(s.hm(t), receipt: MetricText.receipt(m)) }
            return s.display(s.metric(key), missing: "Not computed yet.")
        }
        var spo2Row = LabeledValue(id: "spo2", label: "SpO₂ (strap byte)",
                                   value: s.display(.spo2StrapMean, window: "night", missing: "No SpO₂ byte for this night."))
        spo2Row.caption = spo2Row.value.isBlank || s.spo2Gate.passed ? nil : SpO2Gate.preGateLabel
        // Mo, Oct 28 2026: no strap byte -> the SpO₂ Apple Health holds for the day, labelled by who wrote it. WHOOP writes
        // only its sleep SpO₂ (one value at wake), so a WHOOP row reads "during sleep", as on WHOOP's own sleep page.
        if spo2Row.value.isBlank, let pct = s.metric(.spo2Pct, window: "night"), pct.value != nil, ImportedHistory.isAppleHealth(pct) {
            let whoop = ImportedHistory.shortSource(pct.source).hasPrefix("WHOOP")
            spo2Row = LabeledValue(id: "spo2", label: whoop ? "SpO₂ during sleep" : "SpO₂", value: s.display(pct),
                                   caption: s.importCaption(pct))
        }
        let rhr = s.metric(.rhr, window: "night")
        return [
            LabeledValue(id: "onset", label: "Went to sleep", value: clock(.sleepOnset, strap: span?.start)),
            LabeledValue(id: "wake", label: "Woke", value: clock(.wakeTime, strap: span?.end)),
            LabeledValue(id: "latency", label: "Time to fall asleep",
                         value: s.display(.sleepLatency, missing: "Not available: the strap sleep flag has no bed time, "
                                          + "so ALG-150 cannot time the fall asleep.")),
            LabeledValue(id: "rhr", label: "Resting heart rate",
                         value: s.display(rhr, missing: "No resting heart rate for this night yet."),
                         caption: s.importCaption(rhr)),
            spo2Row,
        ] + s.sleepHrvRows()
    }

    // MARK: Pieces

    private static func plain(_ s: PresenterSnapshot, _ text: String, unit: String? = nil) -> DisplayValue {
        s.worded(text, unit: unit, receipt: s.phoneReceipt())
    }

    /// A value the phone worked out or modelled: marked as an estimate.
    fileprivate static func est(_ s: PresenterSnapshot, _ text: String, unit: String? = nil, method: String) -> DisplayValue {
        s.worded(text, unit: unit, receipt: s.phoneReceipt(.estimate, method: method), style: .estimate(nil))
    }

    private static func text(_ v: DisplayValue?) -> String {
        guard case let .value(text, unit, _, _, _)? = v else { return "—" }
        return unit.map { "\(text) \($0)" } ?? text
    }

    private static func action(_ id: String, _ title: String, _ intent: UIIntent) -> ActionState {
        ActionState(id: id, title: title, intent: intent)
    }

    private static func ring(_ r: DialRing) -> DialDetailVisual { .ring(fraction: r.fraction, target: r.target) }

    private static func week(_ s: PresenterSnapshot, _ key: String, max: Double?, unit: String? = nil) -> [DialDetailVisual] {
        s.dialWeek[key].flatMap { $0.isEmpty ? nil : [.week($0, max: max, unit: unit)] } ?? []
    }

    private static func duration(_ s: PresenterSnapshot, _ arc: DialArc) -> LabeledValue {
        LabeledValue(id: "duration", label: "Duration", value: plain(s, MGFormat.duration(arc.end.timeIntervalSince(arc.start))))
    }

    private static func hrRow(_ s: PresenterSnapshot, _ r: EventHRResponse.Result) -> LabeledValue {
        let value: DisplayValue = r.change.map { est(s, MetricText.signed($0, decimals: 1), unit: "bpm", method: "per-minute HR") }
            ?? .blank(reason: r.reason ?? "Not enough readings.", receipt: nil)
        var caption: String?
        if let b = r.before, let a = r.after {
            caption = "\(MGFormat.number(b, decimals: 0)) → \(MGFormat.number(a, decimals: 0)) bpm"
        }
        return LabeledValue(id: "hr", label: r.label, value: value, caption: caption)
    }

    fileprivate static func unconfirmed(_ e: EventRecord) -> Bool {
        if case let .substance(f) = e.payload { return f.vape?.detectedStatus == .unconfirmed }
        return false
    }

    /// Today's workouts as list rows; the strain is the workout's own, when the app has loaded its detail.
    private static func workoutItems(_ s: PresenterSnapshot) -> [DialDetailItem] {
        s.eventsOf(.workout).filter { s.calendar.isDate($0.at, inSameDayAs: s.now) }.compactMap { e -> DialDetailItem? in
            guard case let .workout(f) = e.payload else { return nil }
            var trailing: String?
            if let d = s.workoutHistory.first(where: { $0.event.id == e.id }),
               let m = s.metric(MetricKey.strain.rawValue, window: "workout", in: d.metrics), let v = m.value, v.isFinite {
                let t = MetricText.format(v, unit: m.unit, name: m.name)
                trailing = t.0 + (t.1 ?? "")
            }
            return DialDetailItem(id: e.id.uuidString, title: LivePresenter.workoutTitle(
                type: f.activityTypeUser ?? f.activityTypeAuto, place: e.location?.label),
                                  detail: s.range(e.at, f.end), trailing: trailing, intent: .openWorkout(id: e.id))
        }
    }

    /// The VoiceOver sentence for the visuals that are not already read out by their own values.
    private static func describe(_ v: DialDetailVisual) -> String? {
        switch v {
        case let .week(points, _, _):
            let said = points.map { p in p.value.map { MGFormat.number($0, decimals: abs($0) < 100 ? 1 : 0) } ?? "no value" }
            return "Last \(points.count) days, oldest first: \(said.joined(separator: ", "))."
        case let .hrAround(_, _, before, after):
            guard let b = before, let a = after else { return nil }
            return "Heart rate \(MGFormat.number(b, decimals: 0)) bpm before and \(MGFormat.number(a, decimals: 0)) after (estimate)."
        default:
            return nil
        }
    }
}
