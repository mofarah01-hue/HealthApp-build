import Foundation
import MGDomain

// TodayState / DialState / MethodsStripState previews: the ten prototype scenarios (UX §4.1, §4.2), all SAMPLE.

extension TodayState {
    /// Mid-morning (the UX's default scenario).
    public static let preview: TodayState = preview(for: .morning)

    /// One TodayState per prototype scenario, phase and theme from the real phase arithmetic.
    public static func preview(for scenario: PreviewScenario) -> TodayState {
        TodayPreviewBuilder(scenario).build()
    }
}

extension DialState {
    public static let preview: DialState = TodayPreviewBuilder(.morning).dial()

    public static func preview(for scenario: PreviewScenario) -> DialState { TodayPreviewBuilder(scenario).dial() }
}

extension MethodsStripState {
    /// G-READY as the prototype shows it (ALGORITHM-COMPARISON ranks).
    public static let preview: MethodsStripState = TodayPreviewBuilder.recoveryStrip()
    /// G-LOAD after the workout.
    public static let previewLoad: MethodsStripState = TodayPreviewBuilder.loadStrip()
}

extension StatusChipState {
    public static let preview = StatusChipState(strapTone: .good, strapText: "MG 79 %", syncTone: .good,
                                                syncText: "synced 09:00")
}

struct TodayPreviewBuilder {
    let s: PreviewScenario
    let now: Date
    let ctx: DayContext
    let cal = SampleDay.calendar

    init(_ s: PreviewScenario) {
        self.s = s
        self.now = s.now
        self.ctx = SampleDay.context(at: s.now)
    }

    static func t(_ h: Int, _ m: Int, _ d: Int = 0) -> Date { SampleDay.at(h, m, dayOffset: d) }
    static func r(_ on: ComputedOn, _ tier: Tier, _ h: Int, _ m: Int, _ method: String? = nil,
                  _ d: Int = 0) -> Receipt {
        SampleDay.receipt(on, tier, h, m, dayOffset: d, method: method)
    }
    static func v(_ text: String, _ unit: String? = nil, _ r: Receipt,
                  _ style: DisplayValue.Style = .plain) -> DisplayValue {
        SampleDay.value(text, unit, r, style)
    }

    // Per-scenario numbers from the prototype (battery, last sync, strain, steps) and its caffeine model (node run).
    var battery: Int { [82, 79, 74, 72, 71, 66, 64, 61, 58, 55][index] }
    var lastSync: String { ["06:58", "09:00", "13:00", "14:00", "15:00", "17:00", "18:00", "20:00", "22:00", "00:00"][index] }
    var strain: Double { [0.2, 1.4, 3.1, 3.4, 4.0, 6.2, 11.4, 11.6, 11.7, 11.8][index] }
    var steps: Int { [120, 1840, 2940, 3020, 3300, 4050, 4600, 5210, 5600, 5820][index] }
    var mgNow: Int { [0, 156, 134, 117, 99, 70, 63, 48, 34, 22][index] }
    var vapes: Int { [1, 5, 9, 9, 10, 12, 12, 14, 17, 19][index] }
    var index: Int { PreviewScenario.allCases.firstIndex(of: s) ?? 0 }
    /// "A coffee (95 mg) is fine until …" — nil = no more caffeine today.
    var cutoff: Date? {
        switch s {
        case .woke: return Self.t(15, 35)
        case .morning: return Self.t(10, 24)
        default: return nil
        }
    }

    func build() -> TodayState {
        TodayState(sample: true, theme: ctx.theme, header: header(), moment: moment(), verdict: verdict(),
                   methods: methods(), dial: dial(), nowRows: nowRows(), primaryStrip: primaryStrip(),
                   secondaryStrip: secondaryStrip(), quickLog: quickLog(), peek: peek(), footer: FooterState())
    }

    // MARK: Header

    func header() -> HeaderState {
        let status: StatusChipState = s == .off
            ? StatusChipState(strapTone: .bad, strapText: "MG off wrist", syncTone: .good, syncText: "synced \(lastSync)")
            : StatusChipState(strapTone: .good, strapText: "MG \(battery) %", syncTone: .good,
                              syncText: "synced \(lastSync)")
        return HeaderState(kicker: MGFormat.kicker(ctx, now: now, calendar: cal),
                           title: MGFormat.weekdayTitle(now, calendar: cal), status: status, questionChip: nil)
    }

    // MARK: Moment

    func moment() -> MomentViewState? {
        switch s {
        case .off:
            return MomentViewState(kind: .strapOff, title: "Strap off · since 15:12", trailing: "28 min",
                                   line: "Nothing records while it's off.",
                                   detail: "History, live heart rate and the dial pause. Your log still works.",
                                   actionTitle: "Remind me in 30 min", action: .remindStrapOff(minutes: 30),
                                   tone: .body, extraCount: 0)
        case .wlive:
            let trace: [Double] = (0..<60).map { (i: Int) -> Double in
                let spike: Double = i % 6 == 0 ? 1.6 : 1.0
                return 0.5 + 0.4 * sin(Double(i) * 0.9) * spike
            }
            return MomentViewState(kind: .workoutLive, title: "Workout · live · gym, strength", trailing: "13:10",
                                   line: "zone 3 · 72 % of max", detail: nil, actionTitle: "Open in Live",
                                   action: .openLive,
                                   liveValue: Self.v("138", "bpm", Self.r(.strap, .strap, 17, 45)), trace: trace,
                                   receipt: Self.r(.strap, .strap, 17, 45), tone: .body, extraCount: 0)
        case .wend:
            return MomentViewState(kind: .workoutJustEnded, title: "Workout ended · 17:32–18:20", trailing: "48 min",
                                   line: "Gym, strength · avg 131 · peak 168 bpm",
                                   detail: "Strain 11.4 (ours) · HR fell 28 bpm in the first minute.",
                                   actionTitle: "Open workout", action: .openWorkout(id: nil),
                                   receipt: Self.r(.phone, .high, 18, 21), tone: .body, extraCount: 0)
        default:
            return nil
        }
    }

    // MARK: Verdict

    func verdict() -> VerdictState {
        let rec = Self.r(.phone, .relative, 6, 58, "ALG-160 readiness")
        switch s {
        case .woke:
            return VerdictState(headline: "Recovered, mostly.",
                                sentence: "Slept 7 h 08 of 8 h 10 needed. HRV steady against your month; two breathing pauses at 03:40, noted.",
                                receipt: rec, receiptNote: "readiness 82 of 100 (ALG-160), HRV in your range")
        case .morning:
            return VerdictState(headline: "Recovered, mostly.",
                                sentence: "In your focus window until 12:00. A coffee is fine until 10:24.",
                                receipt: rec, receiptNote: "readiness 82 of 100 (ALG-160), HRV in your range")
        case .lunch:
            return VerdictState(headline: "Dip ahead, probably.",
                                sentence: "Your alertness usually drops 14:00–15:30. No more caffeine today — bedtime would pass 33 mg.",
                                receipt: Self.r(.phone, .estimate, 13, 50, "ALG-051/052"))
        case .nap:
            return VerdictState(headline: "A short nap, probably.",
                                sentence: "26 min from 14:05, HR 58, very still. Tell me and the detector learns.",
                                receipt: Self.r(.phone, .estimate, 14, 32, "ALG-033 nap detector v0.4"))
        case .off:
            return VerdictState(headline: "Steady afternoon.",
                                sentence: "Strain 4.0 so far. Nothing recorded since 15:12 — the strap is off.",
                                receipt: Self.r(.phone, .relative, 15, 12, "G-LOAD vs your 28 days"))
        case .wlive:
            return VerdictState(headline: "Training now.", sentence: "13 min in, mostly zone 3. Day strain 6.2 so far.",
                                receipt: Self.r(.phone, .high, 17, 45, "ALG-036"))
        case .wend:
            return VerdictState(headline: "Session done.",
                                sentence: "48 min, peak 168. Day strain 11.4 — above your median gym day.",
                                receipt: Self.r(.phone, .high, 18, 21, "ALG-036"))
        case .sundown:
            return VerdictState(headline: "Wind down from 21:30.",
                                sentence: "Bed by 22:30 gets you 7 h 30 — your usual 7 h 30 (the mean of your free nights).",
                                receipt: Self.r(.phone, .estimate, 20, 5, "ALG-115"))
        case .night:
            return VerdictState(headline: "Bed in 20 minutes.",
                                sentence: "Smart wake watches for light sleep between 06:40 and 07:10.",
                                receipt: Self.r(.phone, .estimate, 22, 10, "ALG-115"))
        case .late:
            return VerdictState(headline: "Past your bedtime.",
                                sentence: "Asleep by 01:00 still gives about 6 h 10 before 07:10. You need 8 h 10.",
                                receipt: Self.r(.phone, .estimate, 0, 40, "ALG-115", 1))
        }
    }

    func methods() -> MethodsStripState? {
        switch s {
        case .woke, .morning: return Self.recoveryStrip()
        case .wend: return Self.loadStrip()
        default: return nil
        }
    }

    static func recoveryStrip() -> MethodsStripState {
        let ph = r(.phone, .high, 6, 58)
        let pc = r(.pc, .research, 7, 30)
        let members = [
            MethodMember(variant: "orchard", label: "Orchard · readiness", codename: "ALG-160",
                         value: v("82", "/100", r(.phone, .relative, 6, 58)), scaleNote: "1–100, our estimate",
                         bandIndex: 2, position: 0.82, isRead: true, isResearch: false, rank: 1),
            MethodMember(variant: "plews", label: "Plews lnRMSSD", codename: "ALG-101", value: v("3.95", "ln ms", ph),
                         scaleNote: "within your SWC", bandIndex: 2, position: 0.74, isRead: false, isResearch: false,
                         rank: 2),
            MethodMember(variant: "loop", label: "Loop", codename: "MS-18 recovery_loop",
                         value: v("51", "/100", pc, .research), scaleNote: "green ≥ 67", bandIndex: 1, position: 0.5,
                         isRead: false, isResearch: true, rank: 3),
            MethodMember(variant: "aurora", label: "Aurora", codename: "MS-20 readiness_aura",
                         value: v("74", "/100", pc, .research), scaleNote: nil, bandIndex: 1, position: 0.56,
                         isRead: false, isResearch: true, rank: 3),
        ]
        return MethodsStripState(sample: true, groupId: "G-READY", title: "Recovery · 5 methods", members: members,
                                 caption: "3 in the top band, 2 in the middle. Reading ours until you choose.",
                                 agreement: "Agreement, 30 days: Loop sits 9 under Aurora and moves with it (ρ 0.91). Ours disagreed on 4 days, all after late caffeine.",
                                 droppedCount: 0, valuesLineOnly: false)
    }

    static func loadStrip() -> MethodsStripState {
        let ph = r(.phone, .high, 18, 21)
        let members = [
            MethodMember(variant: "ours", label: "Ours, 0–21", codename: "ALG-036", value: v("11.4", "/21", ph),
                         scaleNote: "day", bandIndex: 2, position: 0.72, isRead: true, isResearch: false, rank: 2),
            MethodMember(variant: "banister", label: "Banister TRIMP", codename: "MS-01", value: v("74", nil, ph),
                         scaleNote: "session", bandIndex: 2, position: 0.7, isRead: false, isResearch: false, rank: 1),
            MethodMember(variant: "edwards", label: "Edwards zones", codename: "MS-02", value: v("96", nil, ph),
                         scaleNote: "session", bandIndex: 1, position: 0.66, isRead: false, isResearch: false, rank: 2),
            MethodMember(variant: "acwr", label: "Acute:chronic", codename: "MS-03",
                         value: v("1.08", nil, r(.pc, .research, 18, 30), .research),
                         scaleNote: "7:28 · descriptive only", bandIndex: 1, position: 0.5, isRead: false,
                         isResearch: true, rank: 3),
        ]
        return MethodsStripState(sample: true, groupId: "G-LOAD", title: "Strain · 4 methods", members: members,
                                 caption: "All put today above your median gym day.",
                                 agreement: "Agreement, 30 days: Banister and ours ρ 0.94; Edwards runs 18 % higher on interval days.",
                                 droppedCount: 0, valuesLineOnly: false)
    }

    // MARK: Dial

    func dial() -> DialState {
        let tonight = ctx.phase == .sundown || ctx.phase == .night || ctx.phase == .lateNight
        var arcs: [DialArc] = []
        if !tonight {
            // Last night's stages (prototype D.stages, hours from 00:00 on 11 Oct).
            let st: [(Double, Double, DialArc.Kind)] = [
                (-0.97, -0.67, .light), (-0.67, 0.08, .deep), (0.08, 0.5, .light), (0.5, 0.8, .rem), (0.8, 0.95, .awake),
                (0.95, 1.4, .light), (1.4, 1.9, .deep), (1.9, 2.3, .light), (2.3, 2.75, .rem), (2.75, 3.6, .light),
                (3.6, 3.7, .awake), (3.7, 4.05, .deep), (4.05, 4.6, .light), (4.6, 5.2, .rem), (5.2, 5.8, .light),
                (5.8, 6.3, .rem), (6.3, 6.87, .light),
            ]
            arcs += st.map { DialArc(kind: $0.2, start: SampleDay.hours($0.0), end: SampleDay.hours($0.1)) }
        } else {
            arcs.append(DialArc(kind: .plannedSleep, start: Self.t(22, 44), end: Self.t(6, 55, 1), pale: true))
        }
        arcs.append(DialArc(kind: .awakeElapsed, start: SampleDay.wake, end: min(now, Self.t(22, 44))))
        if now >= Self.t(14, 5) {
            arcs.append(DialArc(kind: s == .nap ? .napUnconfirmed : .nap, start: Self.t(14, 5),
                                end: min(now, Self.t(14, 31))))
        }
        if now >= Self.t(15, 12) {
            arcs.append(DialArc(kind: .strapOff, start: Self.t(15, 12), end: min(now, Self.t(15, 58))))
        }
        if now >= Self.t(17, 32) {
            arcs.append(DialArc(kind: .workout, start: Self.t(17, 32), end: min(now, Self.t(18, 20))))
        }

        let vapeHours: [Double] = [7.07, 7.67, 8.25, 9.03, 9.5, 11.33, 12.1, 12.75, 13.5, 14.85, 16.3, 16.83, 18.67, 19.5,
                                   20.25, 21.08, 21.9, 23.95, 24.4]
        var rim: [RimEvent] = vapeHours.map(SampleDay.hours).filter { $0 <= now }.map {
            RimEvent(kind: .vape, at: $0, hollow: s == .morning && $0 == SampleDay.hours(9.5))
        }
        let others: [RimEvent] = [
            RimEvent(kind: .medication, at: Self.t(7, 15), label: "MedA 20 mg"),
            RimEvent(kind: .supplement, at: Self.t(8, 0), label: "Mg glycinate · D3 · fish oil ×2"),
            RimEvent(kind: .caffeine, at: Self.t(7, 30), end: Self.t(8, 15), label: "DrinkA 200 mg"),
            RimEvent(kind: .caffeine, at: Self.t(10, 0), end: Self.t(10, 20), label: "Coffee 95 mg"),
            RimEvent(kind: .food, at: Self.t(8, 30), label: "Breakfast"),
            RimEvent(kind: .food, at: Self.t(12, 30), label: "Lunch"),
            RimEvent(kind: .food, at: Self.t(19, 15), label: "Dinner"),
        ]
        rim += others.filter { $0.at <= now }

        var ticks: [DialTick] = [DialTick(kind: .bedtime, at: SampleDay.bedtime, hollow: s == .late)]
        if let c = cutoff { ticks.append(DialTick(kind: .caffeineCutoff, at: c)) }
        if tonight {
            ticks.append(DialTick(kind: .smartWakeWindow, at: s == .late ? Self.t(6, 55, 1) : Self.t(6, 40, 1),
                                  end: SampleDay.latestWake))
        }

        return DialState(sample: true, now: now, wake: SampleDay.wake, nightArc: tonight ? .tonight : .lastNight,
                         arcs: arcs,
                         caffeineCurve: caffeineCurve(), rimEvents: rim, ticks: ticks, hub: hub(),
                         callouts: callouts(),
                         legend: "● vape ×\(vapes) · first 12 min after waking   ◆ MedA 20 mg",
                         accessibilityLabel: "24-hour dial. Slept 23:02 to 06:52, 7 h 08. Now \(MGFormat.time(now, calendar: cal)). Bed tonight 22:30.")
    }

    /// Prototype caffeine model (one compartment, first-order absorption, sips spread over the drink; t½ 4.2 h SAMPLE).
    func caffeineCurve() -> [CaffeinePoint] {
        let ke = log(2.0) / 4.2, ka = 3.0
        let doses: [(Double, Double, Double)] = [(7.5, 8.25, 200), (10.0, 10.0 + 20.0 / 60.0, 95)]
        let nowH = now.timeIntervalSince(SampleDay.at(0, 0)) / 3600
        func amount(_ t: Double) -> Double {
            var a = 0.0
            for d in doses where d.0 < nowH {
                let dd = max(d.1 - d.0, 0.01)
                for i in 0..<12 {
                    let ti = d.0 + dd * (Double(i) + 0.5) / 12, tau = t - ti
                    if tau > 0 { a += d.2 / 12 * ka / (ka - ke) * (exp(-ke * tau) - exp(-ka * tau)) }
                }
            }
            return a
        }
        return stride(from: 7.5, through: 22.5, by: 1.0 / 6.0).map { h in
            let mg = amount(h)
            return CaffeinePoint(at: SampleDay.hours(h), mg: mg, opacity: min(1, max(0, (mg - 33) / 167)))
        }
    }

    func hub() -> DialHub {
        switch s {
        case .woke: return DialHub(kicker: "SLEPT", big: "7 h 08", detail: "of 8 h 10 needed")
        case .morning: return DialHub(kicker: "BED", big: "22:30", detail: "in 12 h")
        case .lunch: return DialHub(kicker: "DIP LIKELY", big: "14:00–15:30", detail: "alertness 58 now")
        case .nap: return DialHub(kicker: "NAP?", big: "26 min", detail: "14:05–14:31")
        case .off: return DialHub(kicker: "STRAP OFF", big: "28 min", detail: "since 15:12")
        case .wlive: return DialHub(kicker: "LIVE", big: "138", detail: "bpm · zone 3 · 13 min")
        case .wend: return DialHub(kicker: "STRAIN", big: "11.4", detail: "day so far · ours")
        case .sundown: return DialHub(kicker: "BED", big: "22:30", detail: "in 2 h 25")
        case .night: return DialHub(kicker: "BED", big: "22:30", detail: "in 20 min")
        case .late: return DialHub(kicker: "IF ASLEEP BY 01:00", big: "6 h 10", detail: "before 07:10")
        }
    }

    func callouts() -> [DialCallout] {
        let est = Self.r(.phone, .estimate, 6, 58)
        func c(_ corner: DialCallout.Corner, _ id: String?) -> DialCallout {
            switch id ?? "" {
            case "cutoff":
                if let cut = cutoff {
                    return DialCallout(corner: corner,
                                       value: Self.v(MGFormat.time(cut, calendar: cal), nil, est, .estimate(nil)),
                                       caption: "caffeine OK until", tone: .caffeine, intent: .openLogItem(.caffeine))
                }
                return DialCallout(corner: corner, value: Self.v("none today", nil, est, .estimate(nil)),
                                   caption: "no more caffeine", tone: .caffeine, intent: .openLogItem(.caffeine))
            case "slept":
                return DialCallout(corner: corner, value: Self.v("7 h 08", nil, Self.r(.phone, .high, 6, 58)),
                                   caption: "slept", tone: .sleep, intent: .openNight(nil))
            case "bed":
                return DialCallout(corner: corner, value: Self.v("22:30", nil, est, .estimate(nil)),
                                   caption: "bed tonight", tone: .sleep, intent: .openTonight)
            case "bedMiss":
                return DialCallout(corner: corner, value: Self.v("22:30", nil, est, .estimate(nil)),
                                   caption: "bed (missed)", tone: .sleep, intent: .openTonight)
            case "strain":
                return DialCallout(corner: corner,
                                   value: Self.v(MGFormat.number(strain, decimals: 1), nil, Self.r(.phone, .high, 6, 58)),
                                   caption: "strain so far", tone: .body, intent: .openMetric(key: "strain", variant: nil))
            case "bedcaff":
                return DialCallout(corner: corner, value: Self.v("32", "mg", est, .estimate(nil)),
                                   caption: "caffeine at bed", tone: .caffeine, intent: .openLogItem(.caffeine))
            case "wake":
                return DialCallout(corner: corner, value: Self.v("06:40–07:10", nil, est, .estimate(nil)),
                                   caption: "wake window", tone: .sleep, intent: .openTonight)
            case "wakeN":
                return DialCallout(corner: corner, value: Self.v("06:55–07:10", nil, est, .estimate(nil)),
                                   caption: "wake window, narrowed", tone: .sleep, intent: .openTonight)
            default:
                return DialCallout(corner: corner, value: nil, caption: "", tone: .mute, intent: nil)
            }
        }
        let ids: [String?]
        switch s {
        case .woke, .morning: ids = ["strain", "cutoff", "slept", "bed"]
        case .lunch, .nap: ids = ["strain", "cutoff", "slept", "bed"]
        case .off, .wlive, .wend: ids = ["strain", "bedcaff", "slept", "bed"]
        case .sundown: ids = ["strain", "bedcaff", "wake", "bed"]
        case .night: ids = [nil, "bedcaff", "wake", "bed"]
        case .late: ids = [nil, nil, "wakeN", "bedMiss"]
        }
        return zip(DialCallout.Corner.allCases, ids).map { c($0.0, $0.1) }
    }

    // MARK: Now rows

    func nowRows() -> [NowRowState] {
        let ids: [String]
        switch s {
        case .woke: ids = ["wake", "med", "caff"]
        case .morning: ids = ["caff", "night"]
        case .lunch: ids = ["dip", "caff", "strain"]
        case .nap: ids = ["napr", "dip", "caff"]
        case .off: ids = ["strain", "bedcaff", "recov"]
        case .wlive: ids = ["zones", "wbreath", "dtap"]
        case .wend: ids = ["hrr", "cal", "bedcaff"]
        case .sundown: ids = ["tonight", "bedcaff", "recap"]
        case .night: ids = ["tonight", "breathe"]
        case .late: ids = ["swlate", "breathe"]
        }
        return ids.compactMap(row)
    }

    func row(_ id: String) -> NowRowState? {
        let hm = MGFormat.time(now, calendar: cal)
        let nowH = cal.component(.hour, from: now), nowM = cal.component(.minute, from: now)
        let est = Self.r(.phone, .estimate, nowH, nowM)
        switch id {
        case "wake":
            return NowRowState(id: id, badge: "W", tone: .sleep, title: "Smart wake got you up at 06:52",
                               detail: "light sleep · 18 min before 07:10 · window 06:40–07:10",
                               receipt: Self.r(.phone, .research, 6, 52, "ALG-031 live stager"),
                               expansion: NowRowExpansion(lines: ["Rate how you feel in the check-in — that's how smart wake learns."],
                                                          actions: [ActionState(id: "tonight", title: "Tonight's window ›",
                                                                                intent: .openTonight)]))
        case "med":
            return NowRowState(id: id, badge: "Rx", tone: .ink, title: "MedA 20 mg — not logged yet",
                               detail: "your schedule says about 07:15", receipt: nil, receiptNote: "schedule · APP-075",
                               button: ActionState(id: "took", title: "Took it",
                                                   intent: .quickLog(.medication(name: "MedA 20 mg"))),
                               expansion: NowRowExpansion(lines: ["Reminder only — no dosing advice."]))
        case "caff":
            let title = cutoff.map { "A coffee (95 mg) is fine until \(MGFormat.time($0, calendar: cal))" }
                ?? "No more caffeine today"
            let detail: String
            if s == .woke {
                detail = "nothing in you yet · bedtime limit 33 mg"
            } else if cutoff != nil {
                detail = "\(mgNow) mg in you now · 19 mg at bedtime · limit 33"
            } else {
                detail = "\(mgNow) mg in you · 32 mg at bedtime — your limit is 33"
            }
            return NowRowState(id: id, badge: "C", tone: .caffeine, title: title, detail: detail, receipt: est,
                               receiptNote: "your t½ 4.2 h",
                               expansion: NowRowExpansion(chart: caffeineCurve().map { $0.mg }, chartCaption: "mg in you → bedtime",
                                                          actions: [ActionState(id: "explore", title: "Open in Explore",
                                                                                intent: .openMetric(key: "caffeine_mg", variant: nil))]))
        case "night":
            return NowRowState(id: id, badge: "N", tone: .body, title: "Two breathing pauses at 03:40",
                               detail: "no oxygen dips seen · 0.3 events/h · noted, not an alert",
                               receipt: Self.r(.phone, .research, 6, 58, "ALG-023 screen"),
                               expansion: NowRowExpansion(lines: ["Both under 15 s, during REM. Strap SpO₂ byte steady at 95–96 around them."],
                                                          actions: [ActionState(id: "night", title: "Last night ›",
                                                                                intent: .openNight(nil))]))
        case "dip":
            let passing = s == .nap
            return NowRowState(id: id, badge: "D", tone: .caffeine,
                               title: passing ? "Dip passing" : "Dip likely 14:00–15:30",
                               detail: passing ? "alertness 61 now, back up after the nap"
                                   : "alertness 58 now · your low is about 52 at 14:45",
                               receipt: Receipt(computedOn: .phone, tier: .estimate, at: now, method: "ALG-051"))
        case "strain":
            return NowRowState(id: id, badge: "S", tone: .body,
                               title: "Strain \(MGFormat.number(strain, decimals: 1)) so far · \(MGFormat.grouped(steps)) steps",
                               detail: "light so far · movement below your usual for this hour",
                               receipt: Receipt(computedOn: .phone, tier: .high, at: now, method: "ALG-036"))
        case "bedcaff":
            return NowRowState(id: id, badge: "C", tone: .caffeine, title: "32 mg caffeine at bedtime",
                               detail: "under your 33 · last dose 10:20", receipt: est, receiptNote: "your t½ 4.2 h")
        case "recov":
            return NowRowState(id: id, badge: "R", tone: .focus, title: "Recovery this morning: mostly",
                               detail: "82 of 100 · HRV in your range · 5 methods", receipt: Self.r(.phone, .relative, 6, 58),
                               expansion: NowRowExpansion(methods: Self.recoveryStrip()))
        case "napr":
            return NowRowState(id: id, badge: "N", tone: .sleep, title: "Nap 14:05–14:31, probably",
                               detail: "26 min · HR 58 · very still · no deep sleep seen",
                               receipt: Self.r(.phone, .estimate, 14, 32, "ALG-033 nap detector v0.4"),
                               receiptNote: "right on 20 of your 23 answers")
        case "zones":
            return NowRowState(id: id, badge: "Z", tone: .body, title: "Mostly zone 3",
                               detail: "Z1 2 min · Z2 4 · Z3 6 · Z4 1 · Z5 0",
                               receipt: Receipt(computedOn: .strap, tier: .strap, at: now),
                               receiptNote: "zones from your measured max 190")
        case "wbreath":
            return NowRowState(id: id, badge: "B", tone: .live, title: "Breathing 27 /min",
                               detail: "last minute · two estimators agree, motion gate passed",
                               receipt: Receipt(computedOn: .phone, tier: .estimate, at: now, method: "ALG-020"))
        case "dtap":
            return NowRowState(id: id, badge: "2×", tone: .ink2, title: "Double-tap the strap = set done",
                               detail: "4 sets so far · last 17:43", receipt: nil, receiptNote: "strap event · APP-007")
        case "hrr":
            return NowRowState(id: id, badge: "H", tone: .body, title: "Heart rate fell 28 bpm in 1 min",
                               detail: "HR recovery · your median 24", receipt: Self.r(.strap, .high, 18, 21, "ALG-012"))
        case "cal":
            return NowRowState(id: id, badge: "K", tone: .caffeine, title: "342 kcal burned in the session",
                               detail: "Keytel · Brage says 318 · 2 more methods couldn't run",
                               receipt: Self.r(.phone, .estimate, 18, 21, "ALG-048"), receiptNote: "± 60")
        case "tonight":
            let toggles = [
                ToggleState(id: "sw", title: "Smart wake", detail: "light sleep inside 06:40–07:10, else 07:10",
                            isOn: true, intent: .setSmartWake(false)),
                ToggleState(id: "ns", title: "Listen tonight", detail: "cough, snore, groan · audio stays on the phone",
                            isOn: false, intent: .setNightSounds(true)),
                ToggleState(id: "wd", title: "Wind-down reminder", detail: "21:30, one notification", isOn: true,
                            intent: .setWindDown(false)),
            ]
            return NowRowState(id: id, badge: "T", tone: .sleep, title: "Tonight: bed 22:30, up 06:40–07:10",
                               detail: "need 7 h 30 (mean of your free nights) · smart wake on",
                               receipt: Receipt(computedOn: .phone, tier: .estimate, at: now, method: "ALG-115"),
                               isOpen: s == .night,
                               expansion: NowRowExpansion(toggles: toggles,
                                                          actions: [ActionState(id: "open", title: "Open Tonight ›",
                                                                                intent: .openTonight)]))
        case "recap":
            return NowRowState(id: id, badge: "D", tone: .ink2,
                               title: "Today: strain \(MGFormat.number(strain, decimals: 1)) · \(MGFormat.grouped(steps)) steps",
                               detail: "vape \(vapes) · caffeine 295 mg · MedA ✓ · supplements ✓", receipt: nil,
                               receiptNote: "log + strap · \(hm)")
        case "breathe":
            return NowRowState(id: id, badge: "~", tone: .focus, title: "Wind down: breathe 5 min",
                               detail: "pacer at 6 /min · coherence shown after",
                               receipt: Receipt(computedOn: .phone, tier: .high, at: now, method: "ALG-104"),
                               button: ActionState(id: "start", title: "Start", intent: .startBreathe))
        case "swlate":
            return NowRowState(id: id, badge: "W", tone: .sleep, title: "Smart wake narrowed to 06:55–07:10",
                               detail: "you're short on sleep, so it waits for the last 15 min",
                               receipt: Self.r(.phone, .estimate, 0, 40, "ALG-115", 1),
                               expansion: NowRowExpansion(toggles: [ToggleState(id: "sw", title: "Smart wake",
                                                                                detail: "backstop rings at 07:10 either way",
                                                                                isOn: true, intent: .setSmartWake(false))]))
        default:
            return nil
        }
    }

    // MARK: Strips

    static func lastNightStrip(withRecovery: Bool, collapsed: Bool) -> StripState {
        let items = [
            LabeledValue(id: "rhr", label: "Resting HR", value: v("64", "bpm", r(.strap, .high, 6, 58)),
                         intent: .openMetric(key: "resting_hr", variant: nil)),
            LabeledValue(id: "hrv", label: "HRV", value: v("52", "ms", r(.phone, .high, 6, 58)),
                         intent: .openMetric(key: "hrv_rmssd", variant: nil)),
            LabeledValue(id: "resp", label: "Breathing",
                         value: v("14.8", "/min", r(.phone, .estimate, 6, 58), .estimate(Uncertainty(low: 13.7, high: 15.9, sd: nil))),
                         intent: .openMetric(key: "resp_rate", variant: nil)),
            LabeledValue(id: "spo2", label: "SpO₂ byte", value: v("96", nil, r(.strap, .strap, 6, 58), .strapRaw),
                         caption: "unchecked", intent: .openMetric(key: "spo2_byte", variant: nil)),
            LabeledValue(id: "temp", label: "Skin temp", value: v("in range", nil, r(.strap, .relative, 6, 58)),
                         intent: .openMetric(key: "skin_temp", variant: nil)),
        ]
        return StripState(kind: .lastNight, title: "Last night", summary: collapsed ? "7 h 08 · readiness 82" : "readiness 82 of 100",
                          items: items,
                          recoveryLine: withRecovery ? "Recovery this morning: mostly · 82 of 100 · HRV in your range" : nil,
                          isCollapsed: collapsed)
    }

    func dayStrip(collapsed: Bool) -> StripState {
        let ph = Receipt(computedOn: .phone, tier: .high, at: now)
        let items = [
            LabeledValue(id: "strain", label: "Strain", value: Self.v(MGFormat.number(strain, decimals: 1), "/21", ph),
                         intent: .openMetric(key: "strain", variant: nil)),
            LabeledValue(id: "steps", label: "Steps",
                         value: Self.v(MGFormat.number(Double(steps) / 1000, decimals: 1), "k",
                                       Receipt(computedOn: .strap, tier: .strap, at: now)),
                         intent: .openMetric(key: "steps", variant: nil)),
            LabeledValue(id: "caff", label: "Caffeine", value: Self.v("295", "mg", ph), caption: "log",
                         intent: .openLogItem(.caffeine)),
            LabeledValue(id: "vape", label: "Vape", value: Self.v("\(vapes)", nil, ph), caption: "log + tap",
                         intent: .openLogItem(.vape)),
            LabeledValue(id: "med", label: "MedA", value: Self.v("✓ 07:15", nil, Self.r(.phone, .high, 7, 15)),
                         caption: "log", intent: .openLogItem(.medication)),
        ]
        return StripState(kind: .todaySoFar, title: "Today so far", summary: "since 06:52", items: items,
                          isCollapsed: collapsed)
    }

    func primaryStrip() -> StripState {
        switch s {
        case .woke, .morning: return Self.lastNightStrip(withRecovery: false, collapsed: false)
        case .lunch, .nap: return Self.lastNightStrip(withRecovery: true, collapsed: false)
        case .off, .wlive, .wend, .sundown: return dayStrip(collapsed: false)
        case .night, .late: return dayStrip(collapsed: true)
        }
    }

    func secondaryStrip() -> StripState? {
        switch s {
        case .woke, .morning, .lunch, .nap: return dayStrip(collapsed: true)
        case .off, .wlive, .wend, .sundown: return Self.lastNightStrip(withRecovery: true, collapsed: true)
        case .night, .late: return nil
        }
    }

    // MARK: Quick log and peek

    func quickLog() -> QuickLogState {
        // BRIEF default 9: the same four all day.
        QuickLogState(pills: [
            QuickLogPill(id: "vape", title: "Vape", systemImage: "wind", intent: .quickLog(.vapeHit)),
            QuickLogPill(id: "med", title: "MedA", systemImage: "pills",
                         intent: .quickLog(.medication(name: "MedA 20 mg"))),
            QuickLogPill(id: "drink", title: "DrinkA", systemImage: "cup.and.saucer",
                         intent: .quickLog(.drinkStart(preset: "DrinkA"))),
            QuickLogPill(id: "food", title: "Food", systemImage: "fork.knife", intent: .quickLog(.food)),
        ], confirmCount: s == .morning ? 1 : 0)
    }

    func peek() -> PeekState? {
        let feel = ["Groggy", "Slow", "OK", "Clear", "Sharp"]
        switch s {
        case .woke:
            return PeekState(kind: .morningCheckin,
                             question: "Smart wake got you up at 06:52, in light sleep. How do you feel?",
                             answers: feel.map { PeekAnswer(id: $0.lowercased(), title: $0,
                                                            intent: .answerPeek(.morningCheckin, answer: $0.lowercased())) },
                             step: 1, stepCount: 2)
        case .lunch:
            let meaning = [1: "extremely alert", 3: "alert", 5: "neither", 7: "sleepy", 9: "fighting sleep"]
            return PeekState(kind: .mealCheckin, question: "Lunch was 80 min ago — how sleepy?",
                             answers: (1...9).map { k in
                                 PeekAnswer(id: "kss\(k)", title: "\(k)", detail: meaning[k],
                                            intent: .answerPeek(.mealCheckin, answer: "kss\(k)"))
                             })
        case .nap:
            let a = [("nap", "Nap"), ("dozed", "Dozed"), ("quiet_rest_not_asleep", "Rest, awake"), ("no", "No")]
            return PeekState(kind: .nap, question: "Nap 14:05–14:31?",
                             answers: a.map { PeekAnswer(id: $0.0, title: $0.1, isDefault: $0.0 == "nap",
                                                         intent: .answerPeek(.nap, answer: $0.0)) },
                             step: 1, stepCount: 2, secondaryTitle: "Edit times", secondaryIntent: .editPeekTimes(.nap))
        case .wend:
            return PeekState(kind: .workoutConfirm, question: "Workout 17:32–18:20 — right?",
                             answers: [PeekAnswer(id: "yes", title: "Yes", isDefault: true,
                                                  intent: .answerPeek(.workoutConfirm, answer: "yes")),
                                       PeekAnswer(id: "no", title: "Not a workout",
                                                  intent: .answerPeek(.workoutConfirm, answer: "not_workout"))],
                             step: 1, stepCount: 2, secondaryTitle: "Edit times",
                             secondaryIntent: .editPeekTimes(.workoutConfirm))
        default:
            return nil
        }
    }
}

extension PeekState {
    /// The wear-location question after the strap goes back on (UX §4.2): "same as before" is the big default.
    public static let previewWearLocation = PeekState(
        kind: .wearLocation, question: "Where's the strap now?",
        answers: [PeekAnswer(id: "same", title: "Left wrist — same as before", isDefault: true,
                             intent: .answerPeek(.wearLocation, answer: WearLocation.leftWrist.rawValue))]
            + [WearLocation.rightWrist, .leftBicep, .rightBicep, .bodyTorso, .bodyWaist, .tailboneUnderwear].map {
                PeekAnswer(id: $0.rawValue, title: $0.rawValue.replacingOccurrences(of: "_", with: " ").capitalized,
                           intent: .answerPeek(.wearLocation, answer: $0.rawValue))
            })
}
