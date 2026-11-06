import Foundation
import MGDomain

/// Today's cards in Mo's order (Settings › Front page, tracker #34), the "Today so far" block (tracker #75) and the
/// Settings page itself. Every card's contents come from the presenter that already built it (TodayPresenter,
/// DialPresenter); this file only picks, orders and adds the four small row cards and today's strap values.
public enum FrontPagePresenter {
    /// A heart rate older than this is not "now" (the strap sends one a second while connected).
    public static let currentWithin: TimeInterval = 120

    // MARK: Today's cards

    static func cards(_ s: PresenterSnapshot) -> [TodayCard] {
        let layout = s.settings.frontPage
        let shown = layout.visible
        // A row with its own card is left out of the Now list (it would show twice); the list refills to 3.
        var own: Set<String> = []
        if shown.contains(.recovery) { own.insert(TodayPresenter.RowID.recovery) }
        let page = shown.compactMap { item -> TodayCard? in
            switch item {
            case .verdict: return .verdict
            case .dial: return .dial
            case .now: return .now(TodayPresenter.nowRows(s, excluding: own))
            case .todaySoFar: return .strip(todaySoFar(s, collapsed: collapsed(s, .todaySoFar, default: false)))
            case .lastNight:
                // At Night and Late night the last night is a day old: the strip leaves (as before customisation).
                guard s.context.phase != .night, s.context.phase != .lateNight else { return nil }
                let late = s.context.phase == .lateAfternoon || s.context.phase == .sundown
                return .strip(TodayPresenter.lastNight(s, withRecovery: s.context.phase != .morning,
                                                       collapsed: collapsed(s, .lastNight, default: late)))
            case .recovery: return .row(TodayPresenter.recoveryRow(s))
            case .alarm: return .row(alarmRow(s))
            case .battery: return .row(batteryRow(s))
            case .quickLog: return .quickLog
            case .wornTime: return .row(wornRow(s))
            case .vitaminD: return .row(vitaminDRow(s))
            }
        }
        // T96: the metrics Mo picked, above the quick-log bar when it is on the page.
        let picks = layout.picks.map { TodayCard.metric(metricCard(s, $0)) }
        guard !picks.isEmpty else { return page }
        let at = page.firstIndex { $0.id == FrontPageItem.quickLog.rawValue } ?? page.count
        return Array(page[..<at]) + picks + Array(page[at...])
    }

    /// One picked metric: its newest value (a blank with its reason when none), and its recent days for the graph.
    static func metricCard(_ s: PresenterSnapshot, _ pick: MetricPick) -> MetricCardState {
        let a = s.explore.todayPicks.first { $0.key == pick.key }
        let value: DisplayValue
        var caption: String?
        if LabDraws.isStatic(pick.key), let lab = LabDraws.newest(s, key: pick.key), let shown = LabDraws.display(lab, s) {
            // T9838 (e-4 static): a lab holds until its next draw: the newest draw with its units, date, age and source.
            value = shown
            caption = LabDraws.caption(lab, s)
        } else if let a {
            value = a.latest == nil ? .blank(reason: a.missingReason ?? "No value stored yet.", receipt: nil)
                : s.display(a.latest)
            // e-4 daily: a value that is not from today says which day it is from.
            if let at = a.latest?.at, a.latest?.value?.isFinite == true, !s.calendar.isDate(at, inSameDayAs: s.now) {
                caption = "last value \(MGFormat.shortDate(at, calendar: s.calendar))"
            }
        } else {
            value = .blank(reason: "Not read yet — pull down to refresh.", receipt: nil)
        }
        return MetricCardState(key: pick.key, name: ExploreCatalogue.name(pick.key), form: pick.form, value: value,
                               series: pick.form == .graph ? (a?.points.map(\.value) ?? []) : [],
                               intent: .openMetric(key: pick.key, variant: nil), caption: caption)
    }

    /// The strip's phase default flipped by `.toggleRow(id: "strip.<kind>")` (UX §3.2 row 7).
    static func collapsed(_ s: PresenterSnapshot, _ kind: StripState.Kind, default closed: Bool) -> Bool {
        closed != s.ui.openRows.contains("strip.\(kind.rawValue)")
    }

    static func alarmRow(_ s: PresenterSnapshot) -> NowRowState {
        let open = ActionState(id: "alarms", title: "Alarms ›", intent: .alarms(.open))
        guard let chip = s.alarmChip else {
            return NowRowState(id: "alarm", badge: "A", tone: .sleep, title: "No alarm in the next 24 h",
                               detail: "Fajr, wake and your own alarms are on the Alarms page", receipt: nil,
                               button: open)
        }
        return NowRowState(id: "alarm", badge: "A", tone: .sleep, title: "Next alarm: \(chip)",
                           detail: "within 24 h", receipt: nil, receiptNote: "alarm plan", button: open)
    }

    /// T10004: "MG not connected" only when it is; while the link searches or connects it says so.
    /// T141 (r9d): with a reason, "MG not connected - out of range" (the real cause, never a bare "not connected").
    static func linkWords(_ link: StrapStatus.Link, reason: String? = nil, device: String = "MG") -> String {
        switch link {
        case .searching: return "\(device) searching…"
        case .connecting: return "\(device) connecting…"
        default: return "\(device) not connected" + (reason.map { " - " + $0 } ?? "")
        }
    }

    static func batteryRow(_ s: PresenterSnapshot) -> NowRowState {
        let strap = s.inputs.strap
        let open = ActionState(id: "strap", title: "Strap ›", intent: .openStrapSync)
        if strap.link == .notPaired {
            return NowRowState(id: "battery", badge: "B", tone: .ink2, title: "No strap paired",
                               detail: "pair your \(s.pairName) in Strap & sync to see its battery", receipt: nil, button: open)
        }
        guard let p = strap.batteryPercent, p.isFinite else {
            return NowRowState(id: "battery", badge: "B", tone: .ink2, title: "Strap battery",
                               detail: strap.link == .connected ? "no battery reading yet"
                                   : "\(linkWords(strap.link, reason: strap.notConnectedReason, device: strap.device)) — no battery reading yet",
                               receipt: nil, button: open)
        }
        var detail: [String] = []
        if strap.link != .connected { detail.append("\(linkWords(strap.link, reason: strap.notConnectedReason, device: strap.device)) — percent from the last connection") }
        if let e = strap.batteryEstimate { detail.append(e.words) } else if strap.charging == true { detail.append("charging") }
        let estimated = strap.batteryEstimate?.short != nil
        return NowRowState(id: "battery", badge: "B", tone: p < 15 ? .caffeine : .ink2,
                           title: "Strap battery \(MGFormat.number(p, decimals: 0)) %",
                           detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                           receipt: estimated
                               ? Receipt(computedOn: .phone, tier: .estimate, at: s.now, method: "BatteryEstimator, 72 h")
                               : Receipt(computedOn: .strap, tier: .strap, at: s.now, method: "0x2A19 battery level"),
                           button: open)
    }

    // MARK: Today so far (tracker #75)

    /// T98 (Mo: strain total and stress total instead of per-field clutter): the day's strain and the day's stress,
    /// each blank with its reason until it can be scored. Per-source notes (method, estimate, imported) live in the
    /// tap-through (the receipt, and the T99 / T126 panels); the caption stays short so it never wraps word by word.
    /// Heart rate, ticks and time worn are still built by `strapItems` / `wornRow` for their own cards.
    static func todaySoFar(_ s: PresenterSnapshot, collapsed: Bool) -> StripState {
        let strain = strainTotal(s)
        let cal = caloriesToday(s)
        let items = [
            LabeledValue(id: "strain", label: "Strain", value: strain.value, caption: strain.caption,
                         intent: .openMetric(key: MetricKey.strain.rawValue, variant: nil)),
            // D-LOAD-WALK-1 item 4: active + total calories burned shown plainly on the front page, not buried in Explore.
            LabeledValue(id: "calories", label: "Calories burned", value: cal.value, caption: cal.caption,
                         intent: .openMetric(key: MetricKey.caloriesActive.rawValue, variant: nil)),
            LabeledValue(id: "stress", label: "Body arousal", value: stressTotal(s), caption: "day so far",
                         intent: .openMetric(key: MetricKey.stress.rawValue, variant: nil)),
        ]
        let from = s.todaySoFar.map { s.hm($0.from) } ?? "12:00 AM"
        var stale = ""
        if let t = s.todaySoFar, t.problem != nil, t.hrSeconds > 0 {
            stale = " · strap numbers from \(s.hm(t.at)): the last read failed"
        }
        return StripState(kind: .todaySoFar, title: "Today so far", summary: "since \(from)" + stale,
                          items: items, isCollapsed: collapsed)
    }

    /// D-LOAD-WALK-1 item 4: calories burned so far today as TOTAL (headline, kcal) with the ACTIVE part in the caption: active =
    /// our ALG-048 Keytel above the person's flex HR (Spurr 1988), total = active + Mifflin resting energy for the share of the day
    /// gone (`DialRingsPresenter.ownBurn`, the same number as the Burned ring). Blank with the reason when either part is blank.
    static func caloriesToday(_ s: PresenterSnapshot) -> (value: DisplayValue, caption: String) {
        let own = DialRingsPresenter.ownBurn(s)
        guard let total = own.kcal else {
            return (.blank(reason: own.reason ?? DialRingsPresenter.burnNeeds, receipt: nil), "total · day so far")
        }
        let activeVariant = (s.groupChoices["G-CAL"]?.readVariant).flatMap { DialRingsPresenter.activeVariants.contains($0) ? $0 : nil }
            ?? DialRingsPresenter.activeVariants[0]
        let active = s.metric(.caloriesActive, variant: activeVariant, window: "day")?.value
        var caption = "total · day so far"
        // D-LOAD-WALK-2: active is a RANGE, low = heart rate AND motion agree, high = heart rate alone (only for the plain Keytel
        // member the range is defined on; the VO2max member shows its own single number).
        let low = activeVariant == "ALG-048:keytel"
            ? s.metric(.caloriesActive, variant: "ALG-048:keytel_motion", window: "day")?.value : nil
        if let a = active, a.isFinite {
            if let l = low, l.isFinite, Int(l.rounded()) < Int(a.rounded()) {
                caption += " · active \(MGFormat.grouped(Int(l.rounded())))–\(MGFormat.grouped(Int(a.rounded()))) kcal"
            } else {
                caption += " · active \(MGFormat.grouped(Int(a.rounded()))) kcal"
            }
        }
        let fromScan = (DialRingsPresenter.restingBasal(s)?.variant) == "ALG-048:cunningham"
        if fromScan { caption += " · resting from scan" }
        let value = s.worded(MGFormat.grouped(Int(total.rounded())), unit: "kcal",
                             receipt: s.phoneReceipt(.estimate, at: own.at, method: "ALG-048 HR-flex (Spurr 1988) + "
                                                     + (fromScan ? "Cunningham (from scan)" : "Mifflin")))
        return (value, caption)
    }

    /// The day's strain: the all-day / 0–21 / imported number when there is one. A workouts-only value (MS-01 / MS-02
    /// TRIMP) shows only when it is above 0 and says so; 0 on a rest day is blank with the reason, never a 0.
    static func strainTotal(_ s: PresenterSnapshot) -> (value: DisplayValue, caption: String) {
        let fitNote = s.metrics.first { $0.name == MetricKey.strain.rawValue && $0.variant == "ALG-036:fit" }?.note
        let m = s.dayStrain()
        // D-LOAD-WALK-1 item 1: the headline is the day's TRIMP in its own units; the 0-21 number follows as the labelled estimate.
        if let t = s.dayTrimp(), let tv = t.value, tv.isFinite {
            var cap = "TRIMP so far"
            if let x = m?.value, x.isFinite, m?.unit == "score_0_21", !ImportedHistory.isImported(m!) {
                cap += " · WHOOP-style strain \(MGFormat.number(x, decimals: 1)) (estimate)"
            }
            return (s.display(t), cap)
        }
        guard let m, let v = m.value, v.isFinite else {
            if let fitNote, !fitNote.isEmpty {
                return (.blank(reason: sentence(fitNote), receipt: m.map(MetricText.receipt)), "day so far")
            }
            return (strainValue(s), "day so far")
        }
        let workoutsOnly = !ImportedHistory.isImported(m) && m.variant != "ALG-036" && m.variant != "ALG-036:fit"
        // T9987: our 0-21 number says it is a mapping, not a validated measure (full wording in the receipt and the panel).
        let ours = !ImportedHistory.isImported(m) && m.unit == "score_0_21"
        let oursCaption = m.variant == "ALG-036:fit" ? "day so far · \(StrainPanelPresenter.fitLabel.replacingOccurrences(of: " (estimate)", with: "")) (estimate)"
            : "day so far · scale not validated"
        guard workoutsOnly else { return (s.display(m), ours ? oursCaption : "day so far") }
        if v > 0 { return (s.display(m), "workouts only") }
        let base = sentence(fitNote ?? "Whole-day strain isn't computed yet")
        return (.blank(reason: base + " Workouts alone score 0 on a rest day, so no total is shown.",
                       receipt: MetricText.receipt(m)), "day so far")
    }

    /// The day's body arousal (0–3, ALG-123:daytime): blank with the reason until it is scored.
    static func stressTotal(_ s: PresenterSnapshot) -> DisplayValue {
        let m = s.dayStress()
        if let v = m?.value, v.isFinite { return s.display(m) }
        let why = m?.note.flatMap { $0.isEmpty ? nil : sentence($0) }
            ?? "Not scored yet — it needs 14 days of resting heart rate and HRV to compare with."
        return .blank(reason: why, receipt: m.map(MetricText.receipt))
    }

    private static func sentence(_ note: String) -> String { note.capitalizedFirst + (note.hasSuffix(".") ? "" : ".") }

    /// Time worn today (W10: its own card, hidden by default; Settings › Front page shows it).
    static func wornRow(_ s: PresenterSnapshot) -> NowRowState {
        let worn = strapItems(s).first { $0.id == "worn" }
        let title: String
        if case let .value(text, _, _, _, _)? = worn?.value { title = "Worn \(text) today" } else { title = "Time worn" }
        var detail = worn?.value.blankReason ?? worn?.caption ?? ""
        if let avg = strapItems(s).first(where: { $0.id == "hrAvg" }), case let .value(t, u, _, _, _) = avg.value {
            detail = "average \(t)\(u.map { " \($0)" } ?? "") while worn"
            // r9t (D-BODY-WALK-1): one readout, the live number first: "now 92 bpm · average 92 bpm while worn".
            if let now = strapItems(s).first(where: { $0.id == "hrNow" }), case let .value(nt, nu, _, _, _) = now.value {
                detail = "now \(nt)\(nu.map { " \($0)" } ?? "") · " + detail
            }
        }
        return NowRowState(id: "worn", badge: "W", tone: .ink2, title: title, detail: detail, receipt: nil)
    }

    /// Why no strap value can show at all, or nil when today's data is there.
    static func strapBlank(_ s: PresenterSnapshot) -> String? {
        if s.sample { return "Sample data is on — it has no strap seconds." }
        guard let t = s.todaySoFar else {
            return s.inputs.strap.link == .notPaired ? "Pair your strap to record today."
                : "Today's strap data hasn't been read yet — pull down to refresh."
        }
        guard t.hrSeconds > 0 else {
            if let p = t.problem { return p.capitalizedFirst + "." }
            return s.inputs.strap.link == .notPaired ? "Pair your strap to record today."
                : "No heart rate stored since \(s.hm(t.from)) — wear the strap with the app connected."
        }
        return nil
    }

    static func strapItems(_ s: PresenterSnapshot) -> [LabeledValue] {
        let blank = strapBlank(s)
        let t = s.todaySoFar
        let worn: DisplayValue
        let avg: DisplayValue
        if let blank {
            worn = .blank(reason: blank, receipt: nil)
            avg = .blank(reason: blank, receipt: nil)
        } else if let t, t.wornMinutes > 0 {
            let receipt = Receipt(computedOn: .phone, tier: .high, at: t.at,
                                  method: "worn = minutes with ≥ 30 heart-rate seconds (ALG-036)")
            worn = s.worded(MGFormat.duration(minutes: t.wornMinutes), receipt: receipt)
            avg = t.averageHR.map { s.worded(MGFormat.number($0, decimals: 0), unit: "bpm", receipt: receipt) }
                ?? .blank(reason: "No worn minute to average yet.", receipt: receipt)
        } else {
            let why = "No full worn minute yet — a minute counts once it has 30 s of heart rate."
            worn = .blank(reason: why, receipt: nil)
            avg = .blank(reason: why, receipt: nil)
        }
        return [
            LabeledValue(id: "worn", label: "Worn", value: worn, caption: "since \(t.map { s.hm($0.from) } ?? "12:00 AM")",
                         intent: .openLive),
            LabeledValue(id: "hrNow", label: "Heart rate", value: currentHR(s, blank: blank), caption: "now",
                         intent: .openLive),
            LabeledValue(id: "hrAvg", label: "Average HR", value: avg, caption: "worn minutes",
                         intent: .openMetric(key: MetricKey.hrAvg.rawValue, variant: nil)),
            LabeledValue(id: "ticks", label: "Step ticks", value: ticksValue(s), caption: "uncalibrated, not steps",
                         intent: .openMetric(key: MetricKey.steps.rawValue, variant: nil)),
        ]
    }

    /// The live beat when it is fresh, else the newest stored second when it is fresh; an older one is never "now".
    static func currentHR(_ s: PresenterSnapshot, blank: String?) -> DisplayValue {
        if let off = s.inputs.strap.offWristSince, off <= s.now {
            return .blank(reason: "Strap off since \(s.hm(off)).", receipt: nil)
        }
        if let hr = s.live?.heartRate, hr.isFinite, hr > 0, let at = s.live?.heartRateAt,
           s.now.timeIntervalSince(at) <= currentWithin {
            return s.worded(MGFormat.number(hr, decimals: 0), unit: "bpm",
                            receipt: Receipt(computedOn: .strap, tier: .strap, at: at, method: "live heart rate"))
        }
        if let blank { return .blank(reason: blank, receipt: nil) }
        guard let t = s.todaySoFar, let hr = t.latestHR, let at = t.latestHRAt else {
            return .blank(reason: "No on-wrist heart rate stored today yet.", receipt: nil)
        }
        let receipt = Receipt(computedOn: .strap, tier: .strap, at: at, method: "stored heart rate")
        guard s.now.timeIntervalSince(at) <= currentWithin else {
            return .blank(reason: "Last heard at \(s.hm(at)) — strap off, out of range or not connected.", receipt: receipt)
        }
        return s.worded(MGFormat.number(hr, decimals: 0), unit: "bpm", receipt: receipt)
    }

    /// Raw ALG-040 ticks: no unit, marked raw (CLAUDE.md rule 4: raw counts are not units).
    static func ticksValue(_ s: PresenterSnapshot) -> DisplayValue {
        if s.sample { return .blank(reason: "Sample data is on — it has no strap seconds.", receipt: nil) }
        guard let t = s.todaySoFar else {
            return .blank(reason: strapBlank(s) ?? "Today's strap data hasn't been read yet.", receipt: nil)
        }
        let receipt = Receipt(computedOn: .strap, tier: .research, at: t.at, method: "ALG-040 raw step-counter ticks")
        guard let ticks = t.stepTicks else {
            let why = t.r18Seconds == 0
                ? "No step-counter readings (R18) stored since \(s.hm(t.from))."
                : (t.ticksMissing ?? "The step counter couldn't be read.").capitalizedFirst + "."
            return .blank(reason: why, receipt: receipt)
        }
        return s.worded(MGFormat.grouped(ticks), receipt: receipt, style: .strapRaw)
    }

    /// Day strain (G-LOAD read method), or why not in Mo's words: the profile first (ALG-036 checks sex first), then
    /// "after your first night" when the model is missing its resting heart rate, then the model's own note.
    static func strainValue(_ s: PresenterSnapshot) -> DisplayValue {
        let m = s.dayStrain()
        if let v = m?.value, v.isFinite { return s.display(m) }
        let receipt = m.map(MetricText.receipt)
        let p = s.settings.profile
        if p.sex == nil { return .blank(reason: "Needs your sex in Profile (Preferences › Profile).", receipt: receipt) }
        if let note = m?.note, note.contains("resting heart rate") {
            var needs: [String] = []
            if s.number(.rhr) == nil { needs.append("after your first night — it needs your resting heart rate") }
            if p.birthDate == nil && p.hrMaxMeasured == nil { needs.append("needs your birth date or max HR in Profile") }
            if !needs.isEmpty { return .blank(reason: needs.joined(separator: "; ").capitalizedFirst + ".", receipt: receipt) }
        }
        if let note = m?.note, !note.isEmpty {
            return .blank(reason: note.capitalizedFirst + (note.hasSuffix(".") ? "" : "."), receipt: receipt)
        }
        return .blank(reason: "Not computed yet today — day strain runs with the hourly compute.", receipt: receipt)
    }

    // MARK: Settings › Front page

    public static let sampleReason = "Sample data is on — the front page can't be changed until it's off."

    public static func settings(_ s: PresenterSnapshot) -> FrontPageSettingsState {
        settings(layout: s.settings.frontPage, sample: s.sample)
    }

    /// The page from the stored layout alone (the app publishes it straight after an edit).
    public static func settings(layout: FrontPageLayout, sample: Bool) -> FrontPageSettingsState {
        func row(_ item: FrontPageItem, hidden: Bool) -> FrontPageSettingsState.Row {
            FrontPageSettingsState.Row(item: item, title: item.title, detail: item.detail, hidden: hidden)
        }
        let layers = DialLayer.allCases.map { l in
            ToggleState(id: l.rawValue, title: l.title, isOn: layout.shows(l), enabled: !sample,
                        disabledReason: sample ? sampleReason : nil,
                        intent: .frontPage(.setDialLayer(l, shown: !layout.shows(l))))
        }
        // T96: any metric in the Explore catalogue, once.
        var seen = Set<String>()
        let choices = ExploreCatalogue.sections.flatMap(\.1).filter { seen.insert($0.key).inserted }
            .map { FrontPageSettingsState.PickChoice(key: $0.key, name: $0.name) }
        return FrontPageSettingsState(
            sample: sample, canEdit: !sample, disabledReason: sample ? sampleReason : nil,
            rows: layout.items.map { row($0.item, hidden: $0.hidden) },
            addable: layout.addable.map { row($0, hidden: false) }, dialLayers: layers,
            pageIsDefault: layout.isDefaultPage,
            dialIsDefault: layout.dialHidden.isEmpty && Set(layout.dialRingsOn) == Set(FrontPageLayout.defaultRings),
            note: "Drag to reorder. Hidden cards keep their place; removed ones wait under Add. Anything off the front "
                + "page is still in Explore.",
            picks: layout.picks.map { .init(key: $0.key, name: ExploreCatalogue.name($0.key), form: $0.form) },
            pickChoices: choices.filter { c in !layout.picks.contains { $0.key == c.key } })
    }
}
