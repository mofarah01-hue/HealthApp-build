import Foundation
import MGDomain

/// Tonight sheet (UX §8.1): bedtime → asleep → up, need breakdown, latest wake, smart wake, caffeine at bed, toggles.
public enum TonightPresenter {
    /// Tonight's plan: predicted onset and recommended wake (UX §8.1).
    struct Plan {
        var bedtime: Date
        /// Predicted onset: B + last night's onset latency (blank since ALG-150: no bed time); B when unknown.
        var asleep: Date
        var asleepKnown: Bool
        /// Recommended wake = onset + need, clamped to the window that ends at L; nil without L and without a need.
        var wake: Date?
        /// The recommendation lands before the window (UX §8.1 "the recommendation says so").
        var beforeWindow: Bool
    }

    static func needMinutes(_ s: PresenterSnapshot) -> Double? {
        if let v = s.number(.sleepNeed) { return v }
        return s.settings.needOverrideMinutes.map(Double.init)
    }

    /// §0.B-3 (r8g): the sleep ring needs a figure to fill against. Until ALG-115 writes the need (it is written by the
    /// morning compute) and with no Settings override, the ring uses this, and says so ("default need"). A display
    /// default only: it is never stored and never reaches an algorithm.
    static let defaultNeedMinutes: Double = 8 * 60

    /// ALG-115 v2 learns the need from 7 free nights (what 'learning' means for it).
    static let needWait = "Sleep need appears after 7 free nights (nights with no 'must be up by'), or set it in Preferences › Sleep & wake."

    static func plan(_ s: PresenterSnapshot) -> Plan? {
        let b = s.context.anchors.bedtime
        let latency = s.number(.sleepLatency)
        let asleep = b.addingTimeInterval((latency ?? 0) * 60)
        let window = s.wakeWindow(narrowed: false)
        var wake: Date?
        var before = false
        if let need = needMinutes(s) {
            var w = asleep.addingTimeInterval(need * 60)
            if let win = window {
                if w > win.end { w = win.end }
                if w < win.start { before = true }
            }
            wake = w
        } else {
            wake = window?.end
        }
        return Plan(bedtime: b, asleep: asleep, asleepKnown: latency != nil, wake: wake, beforeWindow: before)
    }

    /// Late night: "Asleep by {01:00} still gives about {6 h 10} before {07:10}" (UX §4.1).
    struct LatePlan {
        var asleepBy: Date
        var sleepSeconds: TimeInterval
        var wakeBy: Date
    }

    /// Asleep-by = now + last night's onset latency, rounded up to the quarter hour (ours v0: the UX example reads
    /// 00:40 → "01:00"); wake-by = L. nil without L.
    static func lateNightPlan(_ s: PresenterSnapshot) -> LatePlan? {
        guard let l = s.context.anchors.latestWake else { return nil }
        let t = s.now.addingTimeInterval((s.number(.sleepLatency) ?? 0) * 60)
        let q = 15.0 * 60
        let asleepBy = Date(timeIntervalSince1970: (t.timeIntervalSince1970 / q).rounded(.up) * q)
        return LatePlan(asleepBy: asleepBy, sleepSeconds: max(0, l.timeIntervalSince(asleepBy)), wakeBy: l)
    }

    public static func make(_ s: PresenterSnapshot) -> TonightState {
        let a = s.context.anchors
        let p = plan(s)
        let narrowed = s.context.phase == .lateNight
        let window = s.wakeWindow(narrowed: narrowed)
        var summary = "Bed \(s.hm(a.bedtime))"
        if let p, p.asleepKnown { summary += " → asleep ≈ \(s.hm(p.asleep))" }
        if let w = window { summary += " → up \(s.range(w.start, w.end))" } else { summary += " · no wake time set" }

        let bedNote: String?
        switch a.bedtimeSource {
        case .model: bedNote = nil
        case .usual: bedNote = "From your usual bedtime (14-day median) — no sleep-need model yet."
        case .fallback2300: bedNote = "23:00 default — no sleep model and no usual bedtime yet."
        }

        let needTotal: DisplayValue
        if let m = s.metric(.sleepNeed), m.value != nil {
            needTotal = s.display(m)
        } else if let o = s.settings.needOverrideMinutes {
            needTotal = s.worded(MGFormat.duration(minutes: o), receipt: s.phoneReceipt(.high, method: "your override"))
        } else {
            needTotal = s.display(s.metric(.sleepNeed), missing: TonightPresenter.needWait)
        }
        // Tonight 4 (r8g): ALG-115 reports only the total need and the sleep debt. The three parts it does not report were
        // blank rows with the same long sentence; one line says it once.
        let debt = s.metric(.sleepDebt)
        let need: [NeedPart] = [
            NeedPart(label: "sleep debt", minutes: debt?.value.map { Int($0.rounded()) }, value: s.display(debt)),
        ]
        let needNote = "Your need is the mean of your free nights, less today's naps. Sleep debt is shown on its own: it is not added to tonight's need."

        let weekdays = (1...7).map { WeekdayWake(weekday: $0, time: s.settings.latestWake[$0]) }
        let on = s.settings.smartWakeOn
        let toggle = ToggleState(id: "sw", title: "Smart wake",
                                 detail: window.map { "light sleep inside \(s.range($0.start, $0.end)), else \(s.hm($0.end))" },
                                 isOn: on, enabled: window != nil,
                                 disabledReason: window == nil ? "Set “must be up by” for tomorrow first." : nil,
                                 intent: .setSmartWake(!on))
        let endText = window.map { s.hm($0.end) } ?? "your wake time"
        let block = s.smartWake ?? SmartWakeBlockState(
            toggle: toggle, windowMinutes: s.settings.wakeWindowMinutes, windowStart: window?.start, windowEnd: window?.end,
            sentence: "Wakes you in light sleep inside the window (strap stager, live); otherwise at \(endText).",
            ringer: s.settings.ringer,
            silentWarning: s.settings.ringer == .notification ? "A notification may not wake you on Silent." : nil,
            noPlanReason: window == nil ? "No “must be up by” time for tomorrow — no wake plan until you set one." : nil)

        let bedCaff = s.metric(.caffeineBedtime)
        var caffSentence: String?
        if let v = bedCaff?.value, v.isFinite {
            caffSentence = "\(MGFormat.number(v, decimals: 0)) mg at \(s.hm(a.bedtime))"
            if let lim = s.caffeineLimitMg {
                caffSentence! += v <= lim ? " — under your \(MGFormat.number(lim, decimals: 0))"
                    : " — over your \(MGFormat.number(lim, decimals: 0))"
            }
        }
        let windDownAt = a.bedtime.addingTimeInterval(-3600)
        var state = TonightState(
            sample: s.sample, bedtime: a.bedtime, bedtimeNote: bedNote, asleepAround: (p?.asleepKnown ?? false) ? p?.asleep : nil,
            summaryLine: summary, need: need, needTotal: needTotal, latestWake: weekdays, smartWake: block,
            caffeineAtBedtime: s.display(bedCaff, missing: "No caffeine logged today."), caffeineSentence: caffSentence,
            nightSounds: ToggleState(id: "ns", title: "Listen tonight", detail: "cough, snore, groan · audio stays on the phone",
                                     isOn: s.settings.nightSoundsOn, intent: .setNightSounds(!s.settings.nightSoundsOn)),
            windDown: ToggleState(id: "wd", title: "Wind-down reminder", detail: "\(s.hm(windDownAt)), one notification",
                                  isOn: s.settings.windDownOn, intent: .setWindDown(!s.settings.windDownOn)))
        state.needNote = needNote
        return state
    }
}

/// Night (push, UX §8.2): hero, hypnogram + methods, lanes, details grid, regularity, naps.
public enum NightPresenter {
    /// Bug 16 (M-031): ALG-030's gate is 5 days of paired observed minutes (ALG030.sriMinPairedDays), not 14.
    static let regularityWait = "Regularity (ALG-030) needs 5 days in a row with the strap worn, so each minute can be "
        + "compared with the same minute the next day; nothing stored yet."

    public static func make(_ s: PresenterSnapshot) -> NightState {
        // T10011: one decision for the whole page (and, through `SleepFill`, for the ring, hub, corner and Today).
        let fill = s.sleepFill()
        let need = s.metric(.sleepNeed)
        var short: String?
        // Only when both come from the same place (never the app's sleep against an imported need, or the reverse).
        if let a = fill.minutes, let nm = need, let b = nm.value, a.isFinite, b.isFinite,
           (fill.metric.map(ImportedHistory.rank) ?? 0) == ImportedHistory.rank(nm) {
            short = b > a ? "\(MetricText.minutes(b - a)) short" : "need met"
        }
        let pending = fill.fill == .notProcessed
        // Nothing is drawn or counted from a night that is still arriving (Night 1, 12); the reason says so instead.
        let stages = pending ? [] : DialPresenter.stageRuns(s)
        let compare = pending ? [] : stageCompare(s)
        let laneList = lanes(s, fill: fill)
        let blank: String? = pending ? fill.reason : nil
        var state = NightState(
            sample: s.sample, day: s.day, slept: fill.display,
            needed: s.display(need, missing: TonightPresenter.needWait),
            shortBy: short, stages: stages, stageMethods: pending ? nil : stageStrip(s), lanes: laneList,
            details: details(s, fill: fill), regularity: s.display(.sri, missing: NightPresenter.regularityWait),
            naps: naps(s), blankReason: blank)
        state.fill = fill.fill
        state.sourceLine = fill.sourceLine
        state.alsoLine = PresenterSnapshot.alsoLine(fill.also) ?? ""
        state.stagesNote = stages.isEmpty ? (fill.reason ?? "No stages for this night.") : nil
        state.stageCompare = compare
        // 0.C-5: the charts' shared window is worked out here, not in the view body from every lane mark.
        var times: [Date] = stages.flatMap { [$0.start, $0.end] }
        for row in compare { for seg in row.segments { times += [seg.start, seg.end] } }
        for lane in laneList { for mark in lane.marks { times.append(mark.at); if let e = mark.end { times.append(e) } } }
        state.clockWindow = NightClockWindow(times: times)
        // T100: the dropdown's pick is the G-STAGE "read this one" choice, like the Strain panel's G-LOAD one.
        state.algorithmPanel = SleepPanelPresenter.make(s, selectedID: s.groupChoices["G-STAGE"]?.readVariant)
        state.breakdown = SleepBreakdownPresenter.make(s)
        return state
    }

    /// Night 4: the strap flag, the phone's stager and the PC's stager for the same night, one row each, on the same
    /// clock. Rows with no night say why. Empty when none of the three has a night.
    static func stageCompare(_ s: PresenterSnapshot) -> [StageCompareRow] {
        let hyp = DialPresenter.hypnograms(s)
        var rows: [StageCompareRow] = []
        let strapRuns = DialPresenter.strapHypnogram(s).map { DialPresenter.runs($0) } ?? []
        rows.append(StageCompareRow(
            id: "strap", label: "Strap flag", segments: strapRuns,
            total: s.strapSleepMinutes().map { MetricText.minutes($0) },
            blankReason: strapRuns.isEmpty ? "No strap sleep flag is stored for this night." : nil))
        // The phone's stager: the read G-STAGE method when it drew a night, else the best-ranked one that did.
        let phone = hyp.filter { $0.variant != "strap" && !PresenterSnapshot.pcSleepVariants.contains($0.variant ?? "") }
        let read = s.readVariant(group: "G-STAGE")
        let phonePick = phone.first(where: { $0.variant == read && !DialPresenter.runs($0.series).isEmpty })
            ?? phone.sorted { GroupCatalogue.rank("G-STAGE", $0.variant) < GroupCatalogue.rank("G-STAGE", $1.variant) }
                .first { !DialPresenter.runs($0.series).isEmpty }
        let ownPhone = s.phoneSleepTotal().flatMap { m in
            (!ImportedHistory.isImported(m) && (m.value?.isFinite ?? false)) ? m.value : nil
        }
        rows.append(StageCompareRow(
            id: "phone", label: "Phone", segments: phonePick.map { DialPresenter.runs($0.series) } ?? [],
            total: ownPhone.map { MetricText.minutes($0) },
            blankReason: phonePick == nil ? "The phone's stager has no night stored yet." : nil))
        // The PC's stager: the first that passed the V3 gate and drew a night.
        var pcRow: StageCompareRow?
        for v in PresenterSnapshot.pcSleepVariants where !s.pcSleepRejects(v) {
            if let x = hyp.first(where: { $0.variant == v }), !DialPresenter.runs(x.series).isEmpty {
                pcRow = StageCompareRow(id: "pc", label: "PC (\(PresenterSnapshot.pcLabel(v)))",
                                        segments: DialPresenter.runs(x.series),
                                        total: s.pcRawTotal(v).map { MetricText.minutes($0) }, blankReason: nil)
                break
            }
        }
        rows.append(pcRow ?? StageCompareRow(
            id: "pc", label: "PC", segments: [], total: nil,
            blankReason: s.pcSleepWasRejected ? PresenterSnapshot.pcRejectedLabel + "."
                : (s.pcReachable ? "The PC's result for this night is not back yet."
                                 : "The PC isn't reachable, so there is no PC staging yet.")))
        return rows.contains { !$0.segments.isEmpty } ? rows : []
    }

    /// G-STAGE as one values line of total sleep per stager (UX §11: "Ours A 7 h 08 · … · Strap flag 7 h 21").
    static func stageStrip(_ s: PresenterSnapshot) -> MethodsStripState? {
        guard var strip = s.methodsStrip("G-STAGE") else { return nil }
        strip.members = strip.members.map { member in
            var m = member
            let parts = [MetricKey.sleepDeep, .sleepLight, .sleepRem].compactMap {
                s.metric($0.rawValue, variant: member.variant)
            }
            let values = parts.compactMap { $0.value }.filter { $0.isFinite }
            if let first = parts.first, !values.isEmpty {
                m.value = s.worded(MetricText.minutes(values.reduce(0, +)), receipt: MetricText.receipt(first))
            }
            return m
        }
        return strip
    }

    static func lanes(_ s: PresenterSnapshot, fill: SleepFillResult) -> [NightLane] {
        var out: [NightLane] = []
        // Strap sleep flag (sleep tint, id "strapFlag" — WP-12).
        if let flag = DialPresenter.strapHypnogram(s) {
            let marks = DialPresenter.runs(flag).filter { $0.stage != .awake }.map {
                LaneMark(at: $0.start, end: $0.end, label: "asleep")
            }
            out.append(NightLane(id: "strapFlag", title: "Strap sleep flag", marks: marks, blankReason: nil))
        } else {
            out.append(NightLane(id: "strapFlag", title: "Strap sleep flag", marks: [],
                                 blankReason: fill.reason ?? "No strap sleep flag stored for this night."))
        }
        // Breathing events (body tint, id "breathing" — ALG-023).
        let br = s.eventsYesterdayOrLastNight(.breathingEvent).compactMap { e -> LaneMark? in
            guard case let .breathing(f) = e.payload, f.retracted != true else { return nil }
            return LaneMark(at: e.at, end: f.end, label: f.kind.rawValue)
        }
        out.append(NightLane(id: "breathing", title: "Breathing events", marks: br,
                             blankReason: br.isEmpty ? "None found last night (ALG-023 screen)." : nil))
        // Sounds (only if listening was on).
        let sounds = s.eventsYesterdayOrLastNight(.audio).map { e -> LaneMark in
            var label: String?
            var end: Date?
            if case let .audio(f) = e.payload { label = f.kind.rawValue; end = f.end }
            return LaneMark(at: e.at, end: end, label: label)
        }
        out.append(NightLane(id: "sounds", title: "Sounds", marks: sounds,
                             blankReason: sounds.isEmpty ? "Not listening last night — switch on in Tonight" : nil))
        // SpO₂ byte dots (raw, never %).
        if let sp = s.series.first(where: { $0.name == "spo2_strap" }) {
            let marks = perMinute(sp, keepZero: true, reduce: median)       // Night 6: one dot a minute, the median
            out.append(NightLane(id: "spo2", title: "SpO₂ byte", marks: marks,
                                 blankReason: marks.isEmpty ? "No SpO₂ byte readings last night." : nil))
        } else {
            out.append(NightLane(id: "spo2", title: "SpO₂ byte", marks: [], blankReason: "No SpO₂ byte readings last night."))
        }
        if let mv = s.series.first(where: { $0.name == "movement" }) {
            let marks = perMinute(mv, keepZero: false, reduce: { $0.max() ?? 0 })      // one mark a minute, the largest
            out.append(NightLane(id: "movement", title: "Movement", marks: marks, blankReason: nil))
        }
        return out
    }

    /// One value a minute from a finer series: `reduce` over the finite values of each minute. `keepZero` false drops
    /// minutes whose result is not above 0 (movement). Marks sit at the minute's start.
    static func perMinute(_ series: Series, keepZero: Bool, reduce: ([Double]) -> Double) -> [LaneMark] {
        guard series.stepS > 0 else { return [] }
        var out: [LaneMark] = []
        var bucket = Int.min
        var vals: [Double] = []
        func flush() {
            guard bucket != Int.min, !vals.isEmpty else { return }
            let v = reduce(vals)
            if v.isFinite, keepZero || v > 0 {
                out.append(LaneMark(at: series.start.addingTimeInterval(Double(bucket) * 60), value: v))
            }
        }
        for (i, v) in series.values.enumerated() {
            let b = Int((Double(i) * series.stepS / 60).rounded(.down))
            if b != bucket { flush(); bucket = b; vals = [] }
            if let v, v.isFinite { vals.append(v) }
        }
        flush()
        return out
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return .nan }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Night 7: tiles that can never fill are left out; time in bed comes from the strap-flag span.
    static func details(_ s: PresenterSnapshot, fill: SleepFillResult) -> [LabeledValue] {
        var out: [LabeledValue] = []
        if fill.fill != .notProcessed, let span = s.strapAsleepSpan() {
            let r = Receipt(computedOn: .strap, tier: .strap, at: span.end, method: "strap sleep flag (ALG-150)")
            out.append(LabeledValue(id: "tib", label: "Time in bed",
                                    value: .value(text: MetricText.minutes(span.duration / 60), unit: nil, receipt: r,
                                                  style: .plain, sample: s.sample),
                                    caption: "first to last asleep minute · strap flag"))
        }
        out += [
            LabeledValue(id: "tst", label: "Total sleep", value: fill.display,
                         caption: fill.sourceLine.isEmpty ? nil : fill.sourceLine,
                         intent: .openMetric(key: MetricKey.sleepTotal.rawValue, variant: nil)),
            LabeledValue(id: "sol", label: "Onset latency", value: s.display(.sleepLatency)),
            LabeledValue(id: "waso", label: "WASO", value: s.display(.waso)),
            LabeledValue(id: "reml", label: "REM latency", value: s.display(.remLatency)),
            LabeledValue(id: "awk", label: "Awakenings", value: s.display(.awakenings)),
        ]
        if fill.fill != .notProcessed { out += s.sleepHrvRows() }       // D-SLEEP-PRIORITY-1 item 3: this night's HRV, with its kind
        for (id, label, key) in [("eff", "Efficiency", MetricKey.sleepEfficiency),
                                 ("perf", "Performance", MetricKey.sleepPerformance)] {
            // Stager comparison, Nov 5 2026: the strap flag reports no short wakes, so a strap night's efficiency is
            // not shown (it would read higher than the night was).
            if key == .sleepEfficiency, s.strapSleepMinutes() != nil { continue }
            let v = s.display(key)
            if !v.isBlank { out.append(LabeledValue(id: id, label: label, value: v)) }
        }
        return out
    }

    static func naps(_ s: PresenterSnapshot) -> [LabeledValue] {
        s.eventsSinceWake(.nap).compactMap { e in
            guard case let .nap(f) = e.payload, f.confirmed != false else { return nil }
            let label = s.range(e.at, f.end) + (f.confirmed == nil ? " ?" : "")
            return LabeledValue(id: e.id.uuidString, label: label,
                                value: s.worded(MGFormat.duration(f.end.timeIntervalSince(e.at)),
                                                receipt: s.phoneReceipt(.estimate, at: f.end, method: f.detector ?? "ALG-033"),
                                                style: .estimate(nil)),
                                caption: f.label?.rawValue.replacingOccurrences(of: "_", with: " "))
        }
    }
}

extension PresenterSnapshot {
    /// Events from the start of the day before the wake day up to the wake (last night's lanes).
    func eventsYesterdayOrLastNight(_ type: EventType) -> [EventRecord] {
        let start = day.adding(days: -1).start(in: calendar.timeZone)
        return eventsOf(type).filter { $0.at >= start && $0.at <= context.anchors.wake }
    }
}
