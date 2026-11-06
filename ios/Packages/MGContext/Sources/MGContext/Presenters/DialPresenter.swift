import Foundation
import MGDomain

/// The Sundial (UX §3.3): what to draw, by phase (§4.1) and context (§4.2). Geometry is WP-12's.
/// Until Sundown the night arc shows last night (solid stages); from Sundown tonight's plan (pale).
public enum DialPresenter {
    /// Draws only the layers Settings › Front page › Dial ring leaves on (tracker #34); the awake track, the hand and
    /// the hub always draw.
    /// `night` and `tonight` are the screens' already-built states: the detail sheets read them instead of building
    /// Night and Tonight again (audit 0.C-2). nil builds them here, as before.
    public static func make(_ s: PresenterSnapshot, night: NightState? = nil, tonight: TonightState? = nil) -> DialState {
        let on = s.settings.frontPage.shows
        let overnight = isTonight(s.context.phase)
        let wake = s.context.anchors.wake
        var arcs: [DialArc] = on(.sleep) ? (overnight ? plannedSleep(s) : lastNightArcs(s)) : []
        if s.now > wake {
            arcs.append(DialArc(kind: .awakeElapsed, start: wake, end: min(s.now, wake.addingTimeInterval(24 * 3600))))
        }
        if on(.naps) { arcs += napArcs(s) }
        if on(.workouts) { arcs += workoutArcs(s) }
        if on(.strapOff) { arcs += strapOffArcs(s) }
        var dial = DialState(sample: s.sample, now: s.now, wake: s.inputs.strap.link == .notPaired ? nil : wake,
                         nightArc: overnight ? .tonight : .lastNight, arcs: arcs,
                         caffeineCurve: on(.caffeineCurve) ? caffeinePoints(s) : [],
                         rimEvents: rimEvents(s).filter { on(layer($0.kind)) }, ticks: on(.ticks) ? ticks(s) : [],
                         hub: hub(s),
                         callouts: on(.corners) ? callouts(s)
                             : DialCallout.Corner.allCases.map { callout(s, $0, .empty) },
                         legend: legend(s, shows: on), accessibilityLabel: accessibility(s, shows: on),
                         rings: DialRingsPresenter.make(s))
        dial.details = DialDetailPresenter.make(s, dial: dial, night: night, tonight: tonight)
        dial.legendItems = DialDetailPresenter.legendItems(s, dial: dial)
        dial.series = DialSeries.make(s, dial: dial)     // round 8 (T10023): last, it reads the finished state
        return dial
    }

    /// The Settings switch a rim mark belongs to.
    static func layer(_ kind: RimEvent.Kind) -> DialLayer {
        switch kind {
        case .vape: return .vape
        case .medication: return .medication
        case .caffeine: return .caffeine
        case .food: return .food
        case .supplement: return .supplements
        }
    }

    static func isTonight(_ p: DayPhase) -> Bool { p == .sundown || p == .night || p == .lateNight }

    // MARK: Arcs

    /// Last night's stages from the read G-STAGE method's hypnogram (WP-10 codes W L D R S .).
    static func lastNightArcs(_ s: PresenterSnapshot) -> [DialArc] {
        stageRuns(s).map { DialArc(kind: dialKind($0.stage), start: $0.start, end: $0.end) }
    }

    static func dialKind(_ st: StageSegment.Stage) -> DialArc.Kind {
        switch st {
        case .deep: return .deep
        case .light: return .light
        case .rem: return .rem
        case .awake: return .awake
        case .unstaged: return .unstaged
        }
    }

    /// Every stored hypnogram with its variant. WP-22 writes name "hypnogram" + `variant`; "hypnogram|<variant>" as a
    /// name is read the same way. The strap's raw codes (`strap_sleep_state`) are not a hypnogram and never drawn.
    static func hypnograms(_ s: PresenterSnapshot) -> [(variant: String?, series: Series)] {
        s.series.compactMap { x -> (variant: String?, series: Series)? in
            if x.name == "hypnogram" { return (x.variant, x) }
            if x.name.hasPrefix("hypnogram|") { return (x.variant ?? String(x.name.dropFirst("hypnogram|".count)), x) }
            return nil
        }
    }

    /// The strap member's hypnogram (S / W letters), if stored.
    static func strapHypnogram(_ s: PresenterSnapshot) -> Series? {
        hypnograms(s).first { $0.variant == "strap" }?.series
    }

    /// The hypnogram of the read G-STAGE variant; when that one has no series (ALG-031:A until trained), the
    /// best-ranked variant that has one. As runs of one stage.
    static func stageRuns(_ s: PresenterSnapshot) -> [StageSegment] {
        let hyp = hypnograms(s)
        guard !hyp.isEmpty else { return [] }
        // D-SLEEP-PRIORITY-1: the stage bar is drawn from the SAME source as the headline total (the resolver's `stages`);
        // a PC stager's bar only under a PC total, never under another source's total (D6).
        switch s.sleepFill().stages {
        case .pc(let v):
            if let x = hyp.first(where: { $0.variant == v }), !runs(x.series).isEmpty { return runs(x.series) }
            return []
        case .imported:
            return []
        case .phone, .strap, .none:
            break
        }
        let ours = hyp.filter { !PresenterSnapshot.pcSleepVariants.contains($0.variant ?? "") && $0.variant != PresenterSnapshot.rejectedStager }
        let read = s.readVariant(group: "G-STAGE")
        if let x = ours.first(where: { $0.variant == read }), !runs(x.series).isEmpty { return runs(x.series) }
        let ranked = ours.sorted { GroupCatalogue.rank("G-STAGE", $0.variant) < GroupCatalogue.rank("G-STAGE", $1.variant) }
        return ranked.lazy.map { runs($0.series) }.first { !$0.isEmpty } ?? []
    }

    /// Consecutive epochs with the same code → one segment; "." (no data) breaks a run. Codes are WP-10's
    /// `SleepStageCode` letters (W L D R S); the strap member only has S (asleep, unstaged) and W.
    static func runs(_ series: Series) -> [StageSegment] {
        guard let codes = series.state, series.stepS > 0 else { return [] }
        var out: [StageSegment] = []
        var current: (StageSegment.Stage, Int)?
        func close(_ end: Int) {
            guard let c = current else { return }
            out.append(StageSegment(stage: c.0, start: series.start.addingTimeInterval(Double(c.1) * series.stepS),
                                    end: series.start.addingTimeInterval(Double(end) * series.stepS)))
            current = nil
        }
        for (i, code) in codes.enumerated() {
            let st: StageSegment.Stage?
            switch code?.uppercased() {
            case "W": st = .awake
            case "L": st = .light
            case "D": st = .deep
            case "R": st = .rem
            case "S": st = .unstaged
            default: st = nil
            }
            if let c = current, c.0 == st { continue }
            close(i)
            if let st { current = (st, i) }
        }
        close(codes.count)
        return out
    }

    /// Tonight's plan, pale: predicted onset → recommended wake (UX §8.1).
    static func plannedSleep(_ s: PresenterSnapshot) -> [DialArc] {
        guard let plan = TonightPresenter.plan(s), let up = plan.wake else { return [] }
        return [DialArc(kind: .plannedSleep, start: plan.asleep, end: up, pale: true)]
    }

    static func napArcs(_ s: PresenterSnapshot) -> [DialArc] {
        var out: [DialArc] = []
        for e in s.eventsSinceWake(.nap) {
            guard case let .nap(f) = e.payload else { continue }
            if f.confirmed == false || f.label == .quietRestNotAsleep || f.label == .other { continue }
            let unconfirmed = f.confirmed == nil && f.trigger == .detected
            out.append(DialArc(kind: unconfirmed ? .napUnconfirmed : .nap, start: e.at, end: min(f.end, s.now)))
        }
        if let n = s.inputs.nap, n.start >= s.context.anchors.wake {
            let already = out.contains { abs($0.start.timeIntervalSince(n.start)) < 60 }
            if !already {
                if n.end == nil, n.trigger == .manual {
                    out.append(DialArc(kind: .nap, start: n.start, end: s.now, pale: true))
                } else if let end = n.end, n.trigger == .detected {
                    out.append(DialArc(kind: .napUnconfirmed, start: n.start, end: end))
                }
            }
        }
        return out
    }

    static func workoutArcs(_ s: PresenterSnapshot) -> [DialArc] {
        var out: [DialArc] = []
        for e in s.eventsSinceWake(.workout) {
            guard case let .workout(f) = e.payload else { continue }
            out.append(DialArc(kind: .workout, start: e.at, end: min(f.end, s.now)))
        }
        if let w = s.inputs.workout, w.start >= s.context.anchors.wake,
           !out.contains(where: { abs($0.start.timeIntervalSince(w.start)) < 60 }) {
            out.append(DialArc(kind: .workout, start: w.start, end: min(w.end ?? s.now, s.now)))
        }
        return out
    }

    /// Strap-off gaps since wake: wear off → on pairs, plus the gap still open now.
    static func strapOffArcs(_ s: PresenterSnapshot) -> [DialArc] {
        var out: [DialArc] = []
        var offAt: Date?
        for e in s.eventsSinceWake(.wear) {
            guard case let .wear(f) = e.payload else { continue }
            if f.state == .off {
                offAt = offAt ?? e.at
            } else if let o = offAt {
                out.append(DialArc(kind: .strapOff, start: o, end: e.at))
                offAt = nil
            }
        }
        if let since = s.inputs.strap.offWristSince ?? offAt, since <= s.now {
            let start = max(since, s.context.anchors.wake)
            if !out.contains(where: { $0.start == start }) {
                out.append(DialArc(kind: .strapOff, start: start, end: s.now))
            }
        }
        return out
    }

    /// ALG-060 curve; opacity ∝ mg above the bedtime limit, 0 at the limit (UX §3.3).
    static func caffeinePoints(_ s: PresenterSnapshot) -> [CaffeinePoint] {
        let peak = s.caffeineCurve.map(\.value).max() ?? 0
        let limit = s.caffeineLimitMg ?? 0
        return s.caffeineCurve.map { p in
            let span = peak - limit
            let o = span > 0 ? (p.value - limit) / span : 0
            return CaffeinePoint(at: p.at, mg: p.value, opacity: min(1, max(0, o)))
        }
    }

    static func rimEvents(_ s: PresenterSnapshot) -> [RimEvent] {
        var out: [RimEvent] = []
        for e in s.vapeHitsSinceWake() {
            guard case let .substance(f) = e.payload else { continue }
            out.append(RimEvent(kind: .vape, at: e.at, hollow: f.vape?.detectedStatus == .unconfirmed, eventID: id(e)))
        }
        for pair in s.medicationsSinceWake() where pair.fields.status != .skipped {
            let supp = pair.fields.category == .supplement
            out.append(RimEvent(kind: supp ? .supplement : .medication, at: pair.event.at,
                                label: medicationLabel(pair.fields), eventID: id(pair.event)))
        }
        for pair in s.caffeineSinceWake() {
            let mg = pair.fields.caffeineMg.map { " \(MGFormat.number($0, decimals: 0)) mg" } ?? ""
            out.append(RimEvent(kind: .caffeine, at: pair.event.at, end: pair.fields.finishedAt,
                                label: (pair.fields.product ?? "Caffeine") + mg, eventID: id(pair.event)))
        }
        for e in s.eventsSinceWake(.food) {
            guard case let .food(f) = e.payload else { continue }
            out.append(RimEvent(kind: .food, at: e.at, label: f.text ?? "Food", eventID: id(e)))
        }
        return out.sorted { $0.at < $1.at }
    }

    /// The id a mark carries: the Log's own form (lower case), so `.confirmDetected(id:accepted:)` finds the event.
    static func id(_ e: EventRecord) -> String { e.id.uuidString.lowercased() }

    static func medicationLabel(_ f: MedicationFields) -> String {
        let name = f.name ?? (f.category == .supplement ? "Supplements" : "Medication")
        guard let d = f.dose, d.isFinite else { return name }
        return "\(name) \(MGFormat.number(d, decimals: d == d.rounded() ? 0 : 1)) \(f.doseUnit ?? "mg")"
    }

    static func ticks(_ s: PresenterSnapshot) -> [DialTick] {
        let phase = s.context.phase
        var out: [DialTick] = [DialTick(kind: .bedtime, at: s.context.anchors.bedtime,
                                        hollow: phase == .lateNight && s.now > s.context.anchors.bedtime)]
        if let cut = MetricText.instant(s.metric(.caffeineCutoff)), cut > s.context.anchors.wake {
            out.append(DialTick(kind: .caffeineCutoff, at: cut))
        }
        if isTonight(phase), let w = s.wakeWindow(narrowed: phase == .lateNight), s.settings.smartWakeOn {
            out.append(DialTick(kind: .smartWakeWindow, at: w.start, end: w.end))
        }
        if !isTonight(phase), let sw = s.smartWakeResult {
            out.append(DialTick(kind: .wakeMarker, at: sw.at))
        }
        return out
    }

    // MARK: Hub (UX §4.1 "Dial hub", §4.2 overrides)

    static func hub(_ s: PresenterSnapshot) -> DialHub {
        let ctx = s.context
        if s.inputs.strap.link == .notPaired {
            return DialHub(kicker: "NO STRAP", big: "—", detail: "pair your \(s.pairName) to start")
        }
        if let m = ctx.moments.first {
            switch m {
            case let .workoutLive(w):
                let hr = s.live?.heartRate.map { MGFormat.number($0, decimals: 0) } ?? "—"
                let zone = LivePresenter.zone(of: s.live?.heartRate, edges: s.live?.workout?.zoneEdgesBpm)
                let parts = ["bpm", zone.map { "zone \($0)" }, MGFormat.duration(s.now.timeIntervalSince(w.start))]
                return DialHub(kicker: "LIVE", big: hr, detail: parts.compactMap { $0 }.joined(separator: " · "))
            case let .napTimer(n):
                let el = MGFormat.duration(s.now.timeIntervalSince(n.start))
                return DialHub(kicker: "NAP", big: el, detail: n.plannedMinutes.map { "of \($0) min" })
            case let .strapOff(since):
                return DialHub(kicker: "STRAP OFF", big: MGFormat.duration(s.now.timeIntervalSince(since)),
                               detail: "since \(s.hm(since))")
            case .workoutJustEnded:
                let strain = s.dayTrimp() ?? s.dayStrain()
                return DialHub(kicker: "STRAIN", big: strainText(strain), detail: "day so far · \(readName(s, "G-LOAD"))")
            default: break
            }
        }
        if case let .nap(start, end)? = ctx.peek {
            return DialHub(kicker: "NAP?", big: MGFormat.duration(end.timeIntervalSince(start)),
                           detail: s.range(start, end))
        }
        if ctx.justWoke {
            let f = s.sleepFill()          // T10011: no minutes until the strap-flag night is in
            let need = s.metric(.sleepNeed)
            if f.fill == .notProcessed {
                let st = s.sleepNightStatus(f)
                var hub = DialHub(kicker: "SLEPT", big: "—",
                                  detail: st.phase == .downloading ? "coming down from the strap" : "not processed yet")
                if st.phase != .downloading { hub.intent = .processSleepNow }
                return hub
            }
            return DialHub(kicker: "SLEPT", big: f.minutes.map { MetricText.minutes($0) } ?? "—",
                           detail: need?.value.map { "of \(MetricText.minutes($0)) needed" } ?? need?.note)
        }
        // Round 5: asleep (strap flag) or in the hour after waking, the evening / night hub says so, not "BED" / "PAST BEDTIME".
        if s.sleepStateHidesBedtime, [DayPhase.sundown, .night, .lateNight].contains(ctx.phase) {
            if let a = s.asleepSince { return DialHub(kicker: "ASLEEP SINCE", big: s.hm(a), detail: "strap sleep flag") }
            if let w = s.awakeSince { return DialHub(kicker: "AWAKE SINCE", big: s.hm(w), detail: "strap sleep flag") }
        }
        switch ctx.phase {
        case .morning, .sundown, .night:
            let b = ctx.anchors.bedtime
            return DialHub(kicker: "BED", big: s.hm(b), detail: MGFormat.countdown(to: b, from: s.now))
        case .earlyAfternoon:
            let alert = s.number(.alertness).map { "alertness \(MGFormat.number($0, decimals: 0)) now" }
            guard let dip = s.dip else {
                return DialHub(kicker: "DIP", big: "—", detail: s.metric(.alertness)?.note ?? "no forecast yet")
            }
            guard let w = dip.window, w.end > s.now else {
                return DialHub(kicker: "AFTERNOON", big: "clear", detail: alert)
            }
            return DialHub(kicker: "DIP LIKELY", big: s.range(w.start, w.end), detail: alert)
        case .lateAfternoon:
            return DialHub(kicker: "STRAIN", big: strainText(s.dayTrimp() ?? s.dayStrain()),
                           detail: s.dayTrimp() == nil ? "day so far" : "TRIMP · day so far")
        case .lateNight:
            guard let late = TonightPresenter.lateNightPlan(s) else {
                return DialHub(kicker: "PAST BEDTIME", big: s.hm(ctx.anchors.bedtime), detail: "no wake time set")
            }
            return DialHub(kicker: "IF ASLEEP BY \(s.hm(late.asleepBy))", big: MGFormat.duration(late.sleepSeconds),
                           detail: "before \(s.hm(late.wakeBy))")
        }
    }

    /// The strain HEADLINE as one phrase (D-LOAD-WALK-1 item 1): "TRIMP 142 (WHOOP-style strain 11.4, estimate)"; with no TRIMP,
    /// the 0-21 number alone (as `strainText`); "—" with neither.
    static func strainHeadline(_ s: PresenterSnapshot) -> String {
        let fit = s.dayStrain()
        guard let t = s.dayTrimp(), let v = t.value, v.isFinite else { return strainText(fit) }
        var out = "TRIMP \(MGFormat.number(v, decimals: 0))"
        if let x = fit?.value, x.isFinite, fit?.unit == "score_0_21" {
            out += " (WHOOP-style strain \(MGFormat.number(x, decimals: 1)), estimate)"
        }
        return out
    }

    static func strainText(_ m: Metric?) -> String {
        guard let v = m?.value, v.isFinite else { return "—" }
        return MGFormat.number(v, decimals: m?.unit == "score_0_21" ? 1 : 0)
    }

    static func minutesText(_ m: Metric?) -> String {
        guard let v = m?.value, v.isFinite else { return "—" }
        return MetricText.minutes(v)
    }

    static func readName(_ s: PresenterSnapshot, _ gid: String) -> String {
        let v = s.readVariant(group: gid)
        guard let label = GroupCatalogue.member(gid, v)?.label else { return v ?? "—" }
        return label.hasPrefix("Ours") ? "ours" : label
    }

    // MARK: Callouts (UX §4.1 "Callouts TL · TR · BL · BR")

    enum CalloutID { case cutoff, slept, bed, bedMissed, strain, bedCaffeine, wake, wakeNarrowed, empty }

    static func calloutIDs(_ s: PresenterSnapshot) -> [CalloutID] {
        let ids = phaseCalloutIDs(s)
        // Round 5: no "bed tonight" / "bed (missed)" corner while asleep or in the hour after waking.
        return s.sleepStateHidesBedtime ? ids.map { $0 == .bed || $0 == .bedMissed ? .empty : $0 } : ids
    }

    private static func phaseCalloutIDs(_ s: PresenterSnapshot) -> [CalloutID] {
        switch s.context.phase {
        case .morning: return [.strain, .cutoff, .slept, .bed]
        case .earlyAfternoon: return [.strain, .cutoff, .slept, .bed]
        case .lateAfternoon: return [.strain, .bedCaffeine, .slept, .bed]
        case .sundown: return [.strain, .bedCaffeine, .wake, .bed]
        case .night: return [.empty, .bedCaffeine, .wake, .bed]
        case .lateNight: return [.empty, .empty, .wakeNarrowed, .bedMissed]
        }
    }

    static func callouts(_ s: PresenterSnapshot) -> [DialCallout] {
        zip(DialCallout.Corner.allCases, calloutIDs(s)).map { callout(s, $0.0, $0.1) }
    }

    static func callout(_ s: PresenterSnapshot, _ corner: DialCallout.Corner, _ id: CalloutID) -> DialCallout {
        switch id {
        case .cutoff:
            let m = s.metric(.caffeineCutoff)
            let value: DisplayValue
            var caption = "caffeine OK until"
            if let cut = MetricText.instant(m), let m {
                if cut <= s.now {
                    value = s.worded("none today", receipt: MetricText.receipt(m), style: .estimate(nil))
                    caption = "no more caffeine"
                } else {
                    value = s.worded(s.hm(cut), receipt: MetricText.receipt(m), style: .estimate(nil))
                }
            } else {
                value = s.display(m, missing: "No caffeine cut-off computed yet.")
            }
            return DialCallout(corner: corner, value: value, caption: caption, tone: .caffeine,
                               intent: .openLogItem(.caffeine))
        case .slept:
            return DialCallout(corner: corner, value: s.sleepFill().display,
                               caption: "slept", tone: .sleep, intent: .openNight(nil))
        case .bed, .bedMissed:
            return DialCallout(corner: corner, value: bedtimeValue(s), caption: id == .bed ? "bed tonight" : "bed (missed)",
                               tone: .sleep, intent: .openTonight)
        case .strain:
            return DialCallout(corner: corner, value: s.display(s.dayTrimp() ?? s.dayStrain()), caption: "strain so far",
                               tone: .body, intent: .openMetric(key: MetricKey.strain.rawValue, variant: nil))
        case .bedCaffeine:
            return DialCallout(corner: corner, value: s.display(.caffeineBedtime, missing: "No caffeine logged today."),
                               caption: "caffeine at bed", tone: .caffeine, intent: .openLogItem(.caffeine))
        case .wake, .wakeNarrowed:
            let narrowed = id == .wakeNarrowed
            let value: DisplayValue
            if let w = s.wakeWindow(narrowed: narrowed) {
                value = s.worded(s.range(w.start, w.end), receipt: s.phoneReceipt(.estimate, method: "smart wake window"),
                                 style: .estimate(nil))
            } else {
                value = .blank(reason: "No “must be up by” time for tomorrow — set it in Tonight.", receipt: nil)
            }
            return DialCallout(corner: corner, value: value, caption: narrowed ? "wake window, narrowed" : "wake window",
                               tone: .sleep, intent: .openTonight)
        case .empty:
            return DialCallout(corner: corner, value: nil, caption: "", tone: .mute, intent: nil)
        }
    }

    /// B with its receipt: ALG-115's metric when the model set it, else the fallback named (UX §2).
    static func bedtimeValue(_ s: PresenterSnapshot) -> DisplayValue {
        let a = s.context.anchors
        switch a.bedtimeSource {
        case .model:
            let r = s.metric(.bedtimeRecommended).map(MetricText.receipt) ?? s.phoneReceipt(.estimate, method: "ALG-115")
            return s.worded(s.hm(a.bedtime), receipt: r, style: .estimate(nil))
        case .usual:
            return s.worded(s.hm(a.bedtime), receipt: s.phoneReceipt(.estimate, method: "median onset, 14 days"),
                            style: .estimate(nil))
        case .fallback2300:
            return s.worded(s.hm(a.bedtime), receipt: s.phoneReceipt(.estimate, method: "11:00 PM default — no sleep model yet"),
                            style: .estimate(nil))
        }
    }

    // MARK: Legend and VoiceOver

    static let legendGlyph: [RimEvent.Kind: String] = [.vape: "●", .medication: "◆", .caffeine: "○", .food: "▲", .supplement: "■"]

    /// One piece per mark kind present, without its glyph ("vape ×3 · first 5 min after waking"). A switched-off
    /// layer has none.
    static func legendPieces(_ s: PresenterSnapshot, shows on: (DialLayer) -> Bool = { _ in true }) -> [RimEvent.Kind: String] {
        var out: [RimEvent.Kind: String] = [:]
        let vapes = on(.vape) ? s.vapeHitsSinceWake().count : 0
        if vapes > 0 {
            var t = "vape ×\(vapes)"
            if let first = s.number(.vapeFirstAfterWake) { t += " · first \(MGFormat.number(first, decimals: 0)) min after waking" }
            out[.vape] = t
        }
        let meds = s.medicationsSinceWake().filter { $0.fields.status != .skipped }
        let drugs = on(.medication) ? meds.filter { $0.fields.category != .supplement } : []
        let names = Array(Set(drugs.map { medicationLabel($0.fields) })).sorted()
        if !names.isEmpty { out[.medication] = names.joined(separator: " · ") }
        let caf = on(.caffeine) ? s.caffeineSinceWake().count : 0
        if caf > 0 { out[.caffeine] = "caffeine ×\(caf)" }
        let food = on(.food) ? s.eventsSinceWake(.food).count : 0
        if food > 0 { out[.food] = "food ×\(food)" }
        let supps = on(.supplements) ? meds.filter { $0.fields.category == .supplement }.count : 0
        if supps > 0 { out[.supplement] = "supplements ×\(supps)" }
        return out
    }

    /// Names only the marks drawn: a switched-off layer leaves the legend too.
    static func legend(_ s: PresenterSnapshot, shows on: (DialLayer) -> Bool = { _ in true }) -> String {
        let pieces = legendPieces(s, shows: on)
        return [RimEvent.Kind.vape, .medication, .caffeine].compactMap { k in pieces[k].map { "\(legendGlyph[k] ?? "") \($0)" } }
            .joined(separator: "   ")
    }

    static func accessibility(_ s: PresenterSnapshot, shows on: (DialLayer) -> Bool = { _ in true }) -> String {
        var out = ["24-hour dial."]
        let fill = on(.sleep) ? s.sleepFill() : nil
        let runs = fill.map { $0.fill == .notProcessed ? [] : stageRuns(s) } ?? []
        if let first = runs.first, let last = runs.last, let total = fill?.minutes, total.isFinite {
            out.append("Slept \(s.hm(first.start)) to \(s.hm(last.end)), \(MetricText.minutes(total)).")
        } else if fill?.fill == .notProcessed {
            out.append("Last night not processed yet.")
        }
        out.append("Now \(s.hm(s.now)).")
        out.append("Bed tonight \(s.hm(s.context.anchors.bedtime)).")
        return out.joined(separator: " ")
    }
}
