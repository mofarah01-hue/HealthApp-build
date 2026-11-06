import Foundation
import MGDomain

/// Today (UX §3.2), front and centre by phase (§4.1) and context (§4.2); verdict rules §12; peeks §5.
public enum TodayPresenter {
    /// Now-row ids (stable: views send `.toggleRow(id:)` with them).
    public enum RowID {
        public static let smartWake = "smartWake"
        public static let medication = "medication"
        public static let caffeine = "caffeine"
        public static let lastNightFlag = "lastNightFlag"
        public static let firstVape = "firstVape"
        public static let dip = "dip"
        public static let strain = "strain"
        public static let caffeineBedtime = "caffeineBedtime"
        public static let recovery = "recovery"
        public static let tonight = "tonight"
        public static let recap = "recap"
        public static let breathe = "breathe"
        public static let smartWakeLate = "smartWakeLate"
        public static let zones = "zones"
        public static let workoutBreathing = "workoutBreathing"
        public static let doubleTap = "doubleTap"
        public static let hrRecovery = "hrRecovery"
        public static let calories = "calories"
        public static let nap = "nap"
        public static let workout = "workout"
        public static let guidance = "guidance"
        /// r9h (ALG-161): the calm "Worth noting" row; absent when no sign is past your normal.
        public static let warnings = "warnings"
    }

    /// r8g (0.C-2): `night` / `tonight` are the already-built Night and Tonight states, handed to the dial's detail sheets
    /// so they are not built again; nil builds them inside, as before.
    public static func make(_ s: PresenterSnapshot, night: NightState? = nil, tonight: TonightState? = nil) -> TodayState {
        let strip = strips(s)
        return TodayState(sample: s.sample, theme: s.context.theme, header: header(s), moment: moment(s),
                          verdict: verdict(s), methods: methods(s), dial: DialPresenter.make(s, night: night, tonight: tonight), nowRows: nowRows(s),
                          primaryStrip: strip.primary, secondaryStrip: strip.secondary,
                          quickLog: quickLog(s), peek: peek(s), footer: FooterState(),
                          modelStatus: ModelStatusPresenter.todayLine(s), cards: FrontPagePresenter.cards(s))
    }

    // MARK: Header (UX §3.2 row 1)

    static func header(_ s: PresenterSnapshot) -> HeaderState {
        let n = s.context.deferredQuestions.count
        return HeaderState(kicker: MGFormat.kicker(s.context, now: s.now, calendar: s.calendar),
                           title: MGFormat.weekdayTitle(s.now, calendar: s.calendar), status: statusChip(s),
                           questionChip: n == 0 ? nil : (n == 1 ? "1 question" : "\(n) questions"),
                           alarmChip: s.alarmChip)
    }

    static func statusChip(_ s: PresenterSnapshot) -> StatusChipState {
        let strap = strapChip(s)
        let sync = syncChip(s)
        return StatusChipState(strapTone: strap.0, strapText: strap.1, syncTone: sync.0, syncText: sync.1,
                               showOpenSettings: s.inputs.strap.link.needsOpenSettings)
    }

    /// Strap dot + text: "MG 79 %" · "MG off wrist" · "No strap".
    static func strapChip(_ s: PresenterSnapshot) -> (StatusTone, String) {
        let strap = s.inputs.strap
        switch strap.link {
        case .notPaired: return (.neutral, "No strap")
        case .bluetoothOff: return (.warn, "Bluetooth off")
        case .bluetoothNotAllowed: return (.warn, "Bluetooth not allowed")
        // T10004: "not connected" only when it really is; while the link is searching or connecting the chip says so.
        case .searching: return (.neutral, "\(strap.device) searching…")
        case .connecting: return (.neutral, "\(strap.device) connecting…")
        case .disconnected: return (.warn, FrontPagePresenter.linkWords(.disconnected, reason: strap.notConnectedReason, device: strap.device))
        case .connected:
            if strap.offWristSince != nil {
                return strap.offWristMayBeStale ? (.warn, "\(strap.device) may be off wrist") : (.bad, "\(strap.device) off wrist")
            }
            if let b = strap.batteryPercent, b.isFinite {
                // Percent + estimated time left (2026-10-11, Mo: "battery estimated remaining with percentage").
                // T29: a bare "8 d" reads as nothing; a plain duration says "left". "full in 1 h" / "charging" already say it.
                let left = strap.batteryEstimate?.short.map { short in
                    let isDuration = short.hasSuffix(" d") || short.hasSuffix(" h") || short.hasSuffix(" min")
                    return isDuration && !short.hasPrefix("full") ? " · \(short) left" : " · \(short)"
                } ?? ""
                return (b < 15 ? .warn : .good, "\(strap.device) \(MGFormat.number(b, decimals: 0)) %\(left)")
            }
            return (.good, strap.device)
        }
    }

    /// Sync: green "synced 09:40" / amber "7 h unsynced" / grey "PC not set up" (UX §3.2 row 1).
    static func syncChip(_ s: PresenterSnapshot) -> (StatusTone, String) {
        let sync = s.inputs.sync
        switch sync.state {
        case .notSetUp: return (.neutral, "PC not set up")
        case .pairing: return (.neutral, "pairing…")
        case .error: return (.bad, "sync error")
        case .online, .offline:
            // T25: "synced 12:08 AM" must not show while a fetch or upload is still running.
            if s.working.sync != nil { return (.neutral, "syncing…") }
            // T10004: at app open the PC's real state (last sync time) is not read yet; "not synced yet" would be a guess.
            if s.ui.settling, sync.lastSynced == nil { return (.neutral, "PC connecting…") }
            guard let last = sync.lastSynced else { return (.warn, "not synced yet") }
            let hours = Int(s.now.timeIntervalSince(last) / 3600)
            if sync.state == .online || hours < 1 { return (.good, "synced \(s.hm(last))") }
            return (.warn, "\(hours) h unsynced")
        }
    }

    // MARK: Moment card (UX §4.2)

    static func moment(_ s: PresenterSnapshot) -> MomentViewState? {
        guard let m = s.context.moments.first else { return nil }
        let extra = s.context.moments.count - 1
        switch m {
        case let .alert(a):
            let title: String
            switch a.kind {
            case .breathingDisturbance: title = "Breathing screen flagged"
            case .possibleAF: title = "Possible AF"
            case .anomaly: title = "Unusual night"
            }
            let ecg = a.kind == .possibleAF
            return MomentViewState(kind: .alert, title: title, trailing: s.hm(a.raisedAt), line: a.sentence,
                                   detail: a.evidence, actionTitle: ecg ? "Take a 30-s ECG" : "Seen",
                                   action: ecg ? .startECG : .dismissMoment(.alert), tone: .body, extraCount: extra)
        case let .workoutLive(w):
            let hr = s.live?.heartRate
            let zone = LivePresenter.zone(of: hr, edges: s.live?.workout?.zoneEdgesBpm)
            var line = zone.map { "zone \($0)" } ?? "heart rate"
            if zone != nil, let basis = s.live?.workout?.zoneBasis { line += " · \(basis)" }
            let value: DisplayValue? = hr.map {
                s.worded(MGFormat.number($0, decimals: 0), unit: "bpm",
                         receipt: Receipt(computedOn: .strap, tier: .strap, at: s.live?.heartRateAt ?? s.now))
            }
            return MomentViewState(kind: .workoutLive,
                                   title: "Workout · live · " + LivePresenter.workoutTitle(type: w.activityType, place: w.place).lowercased(),
                                   trailing: LivePresenter.elapsed(s.now.timeIntervalSince(w.start)), line: line,
                                   detail: nil, actionTitle: "Open in Live", action: .openLive, liveValue: value,
                                   trace: s.live?.pulseWave ?? [],
                                   receipt: Receipt(computedOn: .strap, tier: .strap, at: s.live?.heartRateAt ?? s.now),
                                   tone: .body, extraCount: extra)
        case let .napTimer(n):
            let el = MGFormat.duration(s.now.timeIntervalSince(n.start))
            let of = n.plannedMinutes.map { " of \($0) min" } ?? ""
            return MomentViewState(kind: .napTimer, title: "Nap · \(el)\(of)", trailing: nil,
                                   line: n.smartWake ? "smart wake on" : "timer only", detail: nil,
                                   actionTitle: "End nap", action: .endNap, tone: .sleep, extraCount: extra)
        case let .strapOff(since):
            return MomentViewState(kind: .strapOff, title: "Strap off · since \(s.hm(since))",
                                   trailing: MGFormat.duration(s.now.timeIntervalSince(since)),
                                   line: "Nothing records while it's off.",
                                   detail: "History, live heart rate and the dial pause. Your log still works.",
                                   actionTitle: "Remind me in 30 min", action: .remindStrapOff(minutes: 30), tone: .body,
                                   extraCount: extra)
        case let .historyDownloading(h):
            // T10013 (r8b): near "now" or caught up, words instead of a stuck percent.
            let words = HistoryProgressWords.state(h, now: s.now)
            var pct = h.fraction.map { "\(Int(($0 * 100).rounded(.down))) %" }
            var line = "\(h.chunksStored) chunk\(h.chunksStored == 1 ? "" : "s") stored"
            if let c = h.coveredSeconds, let t = h.totalSeconds {
                line = "\(MGFormat.duration(Double(c))) of \(MGFormat.duration(Double(t)))"
            }
            switch words {
            case .catchingUp:
                pct = nil
                line = "catching up to now · " + line
            case .caughtUp:
                pct = nil
                line = HistoryProgressWords.tail(h, now: s.now, hm: s.hm) ?? line
            default:
                break
            }
            return MomentViewState(kind: .historyDownloading, title: "Fetching strap history", trailing: pct, line: line,
                                   detail: nil, actionTitle: nil, action: nil,
                                   progress: HistoryProgressWords.barFraction(h, now: s.now), tone: .sleep,
                                   extraCount: extra)
        case let .workoutJustEnded(w):
            let end = w.end ?? s.now
            let type = LivePresenter.workoutTitle(type: w.activityType, place: w.place)
            var line = type
            if let peak = peakHR(s, w.id) { line += " · peak \(MGFormat.number(peak, decimals: 0)) bpm" }
            let strain = s.dayStrain()
            let detail = strain?.value.map { _ in "Day strain \(DialPresenter.strainHeadline(s)) (\(DialPresenter.readName(s, "G-LOAD")))" }
                .map { $0 + "." }
            return MomentViewState(kind: .workoutJustEnded, title: "Workout ended · \(s.range(w.start, end))",
                                   trailing: MGFormat.duration(end.timeIntervalSince(w.start)), line: line, detail: detail,
                                   actionTitle: "Open workout", action: .openWorkout(id: w.id),
                                   receipt: strain.map(MetricText.receipt), tone: .body, extraCount: extra)
        case let .dataWaiting(since):
            let h = Int(s.now.timeIntervalSince(since) / 3600)
            let kb = s.strapSync.unsyncedBytes.map { " · " + bytes($0) } ?? ""
            return MomentViewState(kind: .dataWaiting, title: "Waiting for the PC", trailing: "\(h) h\(kb)",
                                   line: "Tailscale is off or the PC is asleep.",
                                   detail: "Everything is safe on the phone; PC results show their date until it syncs.",
                                   actionTitle: "Open Tailscale", action: .openTailscale, secondaryActionTitle: "Later",
                                   secondaryAction: .dismissMoment(.dataWaiting), tone: .caffeine, extraCount: extra)
        }
    }

    static func bytes(_ n: Int) -> String {
        if n >= 1_000_000 { return MGFormat.number(Double(n) / 1_000_000, decimals: 1) + " MB" }
        return MGFormat.number(Double(n) / 1000, decimals: 0) + " KB"
    }

    /// Peak HR of a workout from its HR map (the highest reading — no statistic beyond a max).
    static func peakHR(_ s: PresenterSnapshot, _ id: UUID) -> Double? {
        guard let d = s.workoutDetail, d.event.id == id, let map = d.hrMap else { return nil }
        return map.values.compactMap { $0 }.filter { $0.isFinite }.max()
    }

    // MARK: Verdict (UX §12, §4.1, §4.2)

    static func verdict(_ s: PresenterSnapshot) -> VerdictState {
        let ctx = s.context
        if s.inputs.strap.link == .notPaired {
            return VerdictState(headline: "Let's find your strap.",
                                sentence: "Pair your \(s.pairName) to start — everything stays on this phone.", receipt: nil,
                                action: ActionState(id: "pairStrap", title: "Pair strap", intent: .pairStrap))
        }
        var v = contextVerdict(s) ?? phaseVerdict(s)
        if let off = s.inputs.strap.offWristSince, ctx.moments.contains(where: { $0.kind == .strapOff }) {
            let extra = "Nothing recorded since \(s.hm(off))."
            v.sentence = v.sentence.map { $0 + " " + extra } ?? extra
        }
        return v
    }

    /// §4.2 overrides: nap timer, nap detected, workout live, workout just ended.
    static func contextVerdict(_ s: PresenterSnapshot) -> VerdictState? {
        for m in s.context.moments {
            switch m {
            case let .workoutLive(w):
                var sentence = "\(MGFormat.duration(s.now.timeIntervalSince(w.start))) in"
                if let z = mostZone(s.live?.workout?.zoneMinutes) { sentence += ", mostly zone \(z)" }
                sentence += "."
                if let st = s.dayStrain(), st.value != nil {
                    sentence += " Day strain \(DialPresenter.strainHeadline(s)) so far."
                }
                return VerdictState(headline: "Training now.", sentence: sentence,
                                    receipt: s.phoneReceipt(.high, method: "ALG-036"))
            case let .napTimer(n):
                let of = n.plannedMinutes.map { " of \($0) min" } ?? ""
                return VerdictState(headline: "Napping.",
                                    sentence: "\(MGFormat.duration(s.now.timeIntervalSince(n.start)))\(of)" + (n.smartWake ? ", smart wake on." : "."),
                                    receipt: nil)
            case let .workoutJustEnded(w):
                let end = w.end ?? s.now
                var sentence = MGFormat.duration(end.timeIntervalSince(w.start))
                if let peak = peakHR(s, w.id) { sentence += ", peak \(MGFormat.number(peak, decimals: 0))" }
                sentence += "."
                let st = s.dayStrain()
                if let v = st?.value, v.isFinite {
                    sentence += " Day strain \(DialPresenter.strainHeadline(s))"
                    if let q = s.strainQuartiles { sentence += v > q.p75 ? " — more than usual." : " — about usual." } else { sentence += "." }
                }
                return VerdictState(headline: "Session done.", sentence: sentence,
                                    receipt: st.map(MetricText.receipt) ?? s.phoneReceipt(.high, method: "ALG-036"))
            default:
                continue
            }
        }
        if case let .nap(start, end)? = s.context.peek ?? s.context.deferredQuestions.first(where: {
            if case .nap = $0 { return true }
            return false
        }) {
            return VerdictState(headline: "A short nap, probably.",
                                sentence: "\(MGFormat.duration(end.timeIntervalSince(start))) from \(s.hm(start)). Tell me and the detector learns.",
                                receipt: s.phoneReceipt(.estimate, at: end, method: "ALG-033 nap detector"))
        }
        return nil
    }

    static func mostZone(_ minutes: [Double]?) -> Int? {
        guard let m = minutes, let best = m.indices.max(by: { m[$0] < m[$1] }), m[best] > 0 else { return nil }
        return best + 1
    }

    static func phaseVerdict(_ s: PresenterSnapshot) -> VerdictState {
        let ctx = s.context
        let a = ctx.anchors
        // Round 4 item 1 (tier S): once the live detector says Mo is asleep, the evening / night phases say so instead of
        // "Bed in ..." / "Bedtime." / "Past your bedtime." (that line stayed ~30 min after his 3:16 AM onset).
        if let since = s.asleepSince, since <= s.now, [DayPhase.sundown, .night, .lateNight].contains(ctx.phase) {
            return VerdictState(headline: "Asleep since \(s.hm(since)).",
                                sentence: "A live read from the strap's sleep flag. Your night appears here after you wake.",
                                receipt: s.phoneReceipt(.estimate, method: "Tier S live sleep detector"))
        }
        // Round 5: right after waking (strap flag), or after an awakening long enough to count as a wake, the evening /
        // night phases must not say "Bedtime." / "Past your bedtime." either, for an hour.
        if let woke = s.awakeSince, woke <= s.now, s.now.timeIntervalSince(woke) <= SleepOnsetDetector.afterWakeQuiet,
           [DayPhase.sundown, .night, .lateNight].contains(ctx.phase) {
            return VerdictState(headline: "Awake since \(s.hm(woke)).",
                                sentence: "A live read from the strap's sleep flag. Your night appears here once it is processed.",
                                receipt: s.phoneReceipt(.estimate, method: "Tier S live sleep detector"))
        }
        switch ctx.phase {
        case .morning:
            return firstReal(s, [morningRecovery, sleptVerdict, caffeineVerdict])
        case .earlyAfternoon:
            return firstReal(s, [dipVerdict, strainVerdict, recoveryReal, caffeineVerdict])
        case .lateAfternoon:
            return firstReal(s, [strainVerdict, recoveryReal, dipVerdict, caffeineVerdict])
        case .sundown:
            let wind = a.bedtime.addingTimeInterval(-3600)
            var sentence = "Bed by \(s.hm(a.bedtime))"
            if a.bedtimeSource != .model {
                // T9710: a usual / default bedtime was not planned from the need, so it must not claim to meet it.
                sentence += a.bedtimeSource == .usual ? " — your usual bedtime" : " — the 11:00 PM default"
                if let need = TonightPresenter.needMinutes(s) {
                    sentence += "; you need \(MetricText.minutes(need)) tonight."
                } else {
                    sentence += "."
                }
            } else if let need = TonightPresenter.needMinutes(s) {
                sentence += " gets you \(MetricText.minutes(need))"
                if let debt = s.number(.sleepDebt), debt >= 1 {
                    sentence += " — your need, with \(MetricText.minutes(debt)) of debt."
                } else {
                    sentence += " — your need."
                }
            } else {
                sentence += "; your sleep need appears after 7 free nights."
            }
            return VerdictState(headline: "Wind down from \(s.hm(wind)).", sentence: sentence,
                                receipt: s.metric(.sleepNeed).map(MetricText.receipt))
        case .night:
            let headline = s.now < a.bedtime ? "Bed \(MGFormat.countdown(to: a.bedtime, from: s.now))." : "Bedtime."
            let sentence: String
            if let w = s.wakeWindow(narrowed: false) {
                sentence = s.settings.smartWakeOn
                    ? "Smart wake watches \(s.range(w.start, w.end))."
                    : "Smart wake is off; the alarm is yours to set."
            } else {
                sentence = "No wake time set for tomorrow."
            }
            return VerdictState(headline: headline, sentence: sentence, receipt: s.metric(.bedtimeRecommended).map(MetricText.receipt))
        case .lateNight:
            guard let late = TonightPresenter.lateNightPlan(s) else {
                return VerdictState(headline: "Past your bedtime.", sentence: "No wake time set for tomorrow.", receipt: nil)
            }
            var sentence = "Asleep by \(s.hm(late.asleepBy)) still gives about \(MGFormat.duration(late.sleepSeconds)) before \(s.hm(late.wakeBy))."
            if let need = TonightPresenter.needMinutes(s) { sentence += " You need \(MetricText.minutes(need))." }
            return VerdictState(headline: "Past your bedtime.", sentence: sentence,
                                receipt: s.phoneReceipt(.estimate, method: "ALG-115"))
        }
    }

    // MARK: Real verdicts only (Mo, 2026-10-11)

    /// A verdict candidate's answer: a real verdict, or why its model / input has nothing today.
    enum Pick {
        case real(VerdictState)
        case notShown(String)
    }

    typealias Candidate = (PresenterSnapshot) -> Pick

    /// Mo 2026-10-11: "No dip forecast yet. The alertness model hasn't run." must never be the big headline. A missing
    /// model or input (no dip forecast, "Too little to say.", no strain yet) is skipped: the first real verdict of the
    /// phase's list wins, and what was skipped goes one tap deeper, into the receipt note. When nothing in the list is
    /// real, tonight's bedtime (from settings, always known) is the headline.
    static func firstReal(_ s: PresenterSnapshot, _ candidates: [Candidate]) -> VerdictState {
        var skipped: [String] = []
        for c in candidates {
            switch c(s) {
            case .real(var v):
                if !skipped.isEmpty {
                    let note = "Not shown: " + skipped.joined(separator: "; ")
                    v.receiptNote = v.receiptNote.map { $0 + " · " + note } ?? note
                }
                return v
            case .notShown(let reason):
                skipped.append(reason)
            }
        }
        var v = bedVerdict(s)
        if !skipped.isEmpty { v.receiptNote = "Not shown: " + skipped.joined(separator: "; ") }
        return v
    }

    /// Morning: the recovery verdict with the just-woke / morning sentence; "Too little to say." is not real.
    static func morningRecovery(_ s: PresenterSnapshot) -> Pick {
        guard case .real(var v) = recoveryReal(s) else { return recoveryReal(s) }
        if v.sentence == nil { v.sentence = s.context.justWoke ? sleptSentence(s) : morningSentence(s) }
        return .real(v)
    }

    /// The recovery verdict, unless it is "Too little to say." (a missing input, not a verdict).
    static func recoveryReal(_ s: PresenterSnapshot) -> Pick {
        let v = recoveryVerdict(s)
        guard v.headline != VerdictRules.tooLittleHeadline else {
            return .notShown("recovery — " + (v.sentence ?? PresenterKit.noReason))
        }
        return .real(v)
    }

    /// "Slept 7 h 08 of 8 h 10 needed." from last night's total sleep.
    static func sleptVerdict(_ s: PresenterSnapshot) -> Pick {
        let m = s.metric(.sleepTotal)
        guard let slept = m?.value, slept.isFinite else {
            return .notShown("sleep total — " + (m?.note ?? "no night recorded"))
        }
        var headline = "Slept \(MetricText.minutes(slept))"
        if let need = TonightPresenter.needMinutes(s) { headline += " of \(MetricText.minutes(need)) needed" }
        return .real(VerdictState(headline: headline + ".", sentence: morningSentence(s),
                                  receipt: m.map(MetricText.receipt), receiptNote: sleepTierChoice(s).label))
    }

    /// Which sleep tier the night shows (round 4 item 2). L = a PC stager's stage row with a value for the night;
    /// M = ALG-150 on the strap flag with ALG-151 stages (the primary). Confirmed wake = a detected (not assumed) wake.
    static func sleepTierChoice(_ s: PresenterSnapshot) -> SleepTiering.Choice {
        var pcShown: String?
        if case .pc(let v) = s.sleepFill().stages { pcShown = v }       // the PC tier only when the PC's night is the headline
        let l = pcShown != nil
        let a = s.context.anchors
        var c = SleepTiering.choose(mAvailable: s.phoneSleepTotal()?.value?.isFinite ?? false, lArrived: l,
                                    confirmedWake: a.wakeAssumed ? nil : a.wake, now: s.now, pcReachable: s.pcReachable)
        if c.tier == .l, let v = pcShown { c.label = "Tier L: PC model (\(v))" }
        if c.tier != .l, s.pcSleepWasRejected { c.label += " — " + PresenterSnapshot.pcRejectedLabel }
        return c
    }

    /// "Caffeine is fine until 15:00." / "No more caffeine today." (G-CAFF read method).
    static func caffeineVerdict(_ s: PresenterSnapshot) -> Pick {
        guard let c = caffeineClause(s) else {
            return .notShown("caffeine cut-off — " + (s.metric(.caffeineCutoff)?.note ?? "not computed"))
        }
        return .real(VerdictState(headline: c, sentence: nil,
                                  receipt: s.metric(.caffeineCutoff).map(MetricText.receipt)))
    }

    /// Last resort, always real: "Bed by 23:00 tonight." from the anchors.
    static func bedVerdict(_ s: PresenterSnapshot) -> VerdictState {
        VerdictState(headline: "Bed by \(s.hm(s.context.anchors.bedtime)) tonight.", sentence: nil,
                     receipt: s.metric(.bedtimeRecommended).map(MetricText.receipt))
    }

    /// Recovery headline from the read G-READY method (UX §12).
    static func recoveryVerdict(_ s: PresenterSnapshot) -> VerdictState {
        let read = ownReadVariant(s)
        // Bug 14 (round 2, 2026-10-14, M-022): a chosen method with no row this morning used to fall back to ALG-036
        // silently, so Today showed a method Mo had not picked. Now it says the chosen one has nothing yet.
        // Round 5: an imported (WHOOP / Apple) variant is never today's recovery, even if it was picked as the read one.
        let chosen = s.metric(MetricKey.readiness.rawValue, variant: read).flatMap { ImportedHistory.isImported($0) ? nil : $0 }
        if read != ownRecoveryVariant, chosen == nil {
            let label = GroupCatalogue.member("G-READY", read)?.label ?? read
            return VerdictState(headline: VerdictRules.tooLittleHeadline,
                                sentence: "\(label) (\(read)), the recovery method you chose, has no result for this "
                                    + "morning yet. Pick another under Recovery methods to read it instead.",
                                receipt: nil)
        }
        if read != ownRecoveryVariant, let m = chosen {
            let info = GroupCatalogue.member("G-READY", read)
            let label = info?.label ?? read
            guard let v = m.value, v.isFinite else {
                return VerdictState(headline: VerdictRules.tooLittleHeadline,
                                    sentence: m.note ?? PresenterKit.noReason, receipt: MetricText.receipt(m))
            }
            let (text, unit) = MetricText.format(v, unit: m.unit, name: m.name)
            let shown = "\(label) \(text)\(unit.map { " \($0)" } ?? "")"
            if let bands = info?.bands, let h = VerdictRules.bandHeadline(bands.index(v)) {
                return VerdictState(headline: h, sentence: nil, receipt: MetricText.receipt(m), receiptNote: shown)
            }
            return VerdictState(headline: shown + ".", sentence: "This method has no published bands, so no verdict word.",
                                receipt: MetricText.receipt(m))
        }
        let rule = VerdictRules.recovery(s.recovery)
        // Mo 2026-10-14 (round 4, item 10): Today's recovery never falls back to WHOOP's or Apple's number for today.
        // Imported recovery is for past days and for days before our primary recovery algorithm was chosen (averages);
        // with no night of our own this is "Too little to say." and its reason (the W10 / T9733 fallback is gone).
        let m = s.metric(MetricKey.readiness.rawValue, variant: ownRecoveryVariant)
        // r9h: an estimate on a baseline under 28 nights carries its own receipt, so it is never shown as a full-length one.
        let estimating = s.recovery?.isEstimate == true
        let receipt = (estimating ? nil : m.map(MetricText.receipt))
            ?? s.recovery.map { Receipt(computedOn: .phone, tier: .estimate, at: $0.at, method: "ALG-160 readiness") }
        var note: String?
        if let r = s.recovery, r.status == .ok, let score = r.score {
            note = "readiness \(score) of 100 (ALG-160)" + (VerdictRules.hrvWord(r).map { ", \($0)" } ?? "")
                + (VerdictRules.shortBaselineLabel(r).map { ", \($0)" } ?? "")
        }
        return VerdictState(headline: rule.headline, sentence: rule.sentence, receipt: receipt, receiptNote: note)
    }

    /// Just woke: "Slept {7 h 08} of {8 h 10} needed. {top driver}."
    static func sleptSentence(_ s: PresenterSnapshot) -> String? {
        var parts: [String] = []
        if let slept = s.number(.sleepTotal) {
            var t = "Slept \(MetricText.minutes(slept))"
            if let need = TonightPresenter.needMinutes(s) { t += " of \(MetricText.minutes(need)) needed" }
            parts.append(t + ".")
        }
        if let r = s.recovery, r.status == .ok, let hrv = VerdictRules.hrvWord(r) {
            parts.append("\(hrv.capitalizedFirst).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Morning: "{caffeine clause}." (the focus window was removed 2026-10-17, D-HRV-WALK-1).
    static func morningSentence(_ s: PresenterSnapshot) -> String? {
        caffeineClause(s)
    }

    static func caffeineClause(_ s: PresenterSnapshot) -> String? {
        guard let cut = MetricText.instant(s.metric(.caffeineCutoff)) else { return nil }
        return cut > s.now ? "Caffeine is fine until \(s.hm(cut))." : "No more caffeine today."
    }

    /// The dip verdict (UX §12); no forecast = not real (the alertness model's blank reason goes to the receipt).
    static func dipVerdict(_ s: PresenterSnapshot) -> Pick {
        guard let dip = s.dip else {
            return .notShown("dip forecast — "
                             + (s.metric(.alertness)?.note ?? "the alertness model (ALG-051) hasn't run"))
        }
        var parts: [String] = []
        if let w = dip.window, w.end > s.now { parts.append("Alertness predicted to drop \(s.range(w.start, w.end)).") }
        if let c = caffeineClause(s) { parts.append(c) }
        return .real(VerdictState(headline: VerdictRules.dipHeadline(now: s.now, dip: dip.window),
                                  sentence: parts.isEmpty ? nil : parts.joined(separator: " "),
                                  receipt: Receipt(computedOn: .phone, tier: .estimate, at: dip.at, method: "ALG-051/052"),
                                  receiptNote: dip.reactionTests < VerdictRules.reactionTestsForPersonalCurve
                                      ? "population, not yours yet" : nil))
    }

    /// The strain verdict (UX §12); no strain today = not real.
    static func strainVerdict(_ s: PresenterSnapshot) -> Pick {
        let st = s.dayStrain()
        guard let v = st?.value, v.isFinite, let st else {
            return .notShown("strain — " + (st?.note ?? "no strain computed yet today"))
        }
        var sentence = "Strain \(DialPresenter.strainHeadline(s)) so far"
        if let steps = s.number(.steps) { sentence += "; \(MGFormat.grouped(Int(steps.rounded()))) steps." } else { sentence += "." }
        guard let q = s.strainQuartiles else {
            return .real(VerdictState(headline: VerdictRules.learningHeadline, sentence: sentence,
                                      receipt: MetricText.receipt(st), receiptNote: "your 28-day range isn't ready yet"))
        }
        return .real(VerdictState(headline: VerdictRules.strainHeadline(value: v, quartiles: q), sentence: sentence,
                                  receipt: MetricText.receipt(st), receiptNote: "G-LOAD vs your 28 days"))
    }

    /// The verdict's methods strip (UX §11): G-READY in the morning, G-LOAD after a workout.
    static func methods(_ s: PresenterSnapshot) -> MethodsStripState? {
        if s.context.moments.contains(where: { $0.kind == .workoutJustEnded }) {
            return s.methodsStrip("G-LOAD", window: "day")
        }
        if s.context.phase == .morning, s.inputs.strap.link != .notPaired { return s.methodsStrip("G-READY") }
        return nil
    }

    // MARK: Now rows (UX §4.1 ranked, §4.2 context rows)

    /// Ranked candidate ids for the phase and context; `nowRows` drops the ones that don't apply and keeps 3.
    static func rowIDs(_ s: PresenterSnapshot) -> [String] {
        let ctx = s.context
        let phase: [String]
        if ctx.justWoke {
            phase = [RowID.smartWake, RowID.medication, RowID.caffeine]
        } else {
            switch ctx.phase {
            case .morning: phase = [RowID.warnings, RowID.caffeine, RowID.lastNightFlag, RowID.guidance, RowID.firstVape]
            case .earlyAfternoon: phase = [RowID.warnings, RowID.dip, RowID.caffeine, RowID.guidance, RowID.strain]
            case .lateAfternoon: phase = [RowID.strain, RowID.guidance, RowID.caffeineBedtime, RowID.recovery]
            case .sundown: phase = [RowID.tonight, RowID.caffeineBedtime, RowID.recap]
            case .night: phase = [RowID.tonight, RowID.breathe]
            case .lateNight: phase = [RowID.smartWakeLate, RowID.breathe]
            }
        }
        var lead: [String] = []
        if ctx.moments.contains(where: { $0.kind == .workoutLive }) {
            lead = [RowID.zones, RowID.workoutBreathing, RowID.doubleTap]
        } else if ctx.moments.contains(where: { $0.kind == .workoutJustEnded }) {
            lead = [RowID.hrRecovery, RowID.calories]
        } else if case .nap? = ctx.peek {
            lead = [RowID.nap]
        } else if workoutEarlierToday(s) != nil {
            lead = [RowID.workout]
        }
        var seen = Set<String>()
        return (lead + phase).filter { seen.insert($0).inserted }
    }

    /// `excluding`: rows that have their own front-page card (Settings › Front page); the list refills to 3.
    static func nowRows(_ s: PresenterSnapshot, excluding: Set<String> = []) -> [NowRowState] {
        var rows: [NowRowState] = []
        var flagShown = false
        for id in rowIDs(s) where !excluding.contains(id) {
            if id == RowID.firstVape && flagShown { continue }
            // Round 5: no "Tonight: bed ..." / "Wind down: breathe" row while asleep or in the hour after waking.
            if s.sleepStateHidesBedtime && (id == RowID.breathe || id == RowID.tonight) { continue }
            guard let r = row(s, id) else { continue }
            if id == RowID.lastNightFlag { flagShown = true }
            rows.append(r)
            if rows.count == 3 { break }
        }
        return rows
    }

    /// Open state: the row's default (Tonight opens by default at Night) flipped by `.toggleRow(id:)`.
    static func isOpen(_ s: PresenterSnapshot, _ id: String, default open: Bool = false) -> Bool {
        open != s.ui.openRows.contains(id)
    }

    static func row(_ s: PresenterSnapshot, _ id: String) -> NowRowState? {
        switch id {
        case RowID.smartWake: return smartWakeRow(s)
        case RowID.medication: return medicationRow(s)
        case RowID.caffeine: return caffeineRow(s)
        case RowID.lastNightFlag: return lastNightFlagRow(s)
        case RowID.firstVape: return firstVapeRow(s)
        case RowID.dip: return dipRow(s)
        case RowID.strain: return strainRow(s)
        case RowID.caffeineBedtime: return caffeineBedtimeRow(s)
        case RowID.recovery: return recoveryRow(s)
        case RowID.tonight: return tonightRow(s)
        case RowID.recap: return recapRow(s)
        case RowID.breathe: return breatheRow(s)
        case RowID.smartWakeLate: return smartWakeLateRow(s)
        case RowID.zones: return zonesRow(s)
        case RowID.workoutBreathing: return workoutBreathingRow(s)
        case RowID.doubleTap: return doubleTapRow(s)
        case RowID.hrRecovery: return hrRecoveryRow(s)
        case RowID.calories: return caloriesRow(s)
        case RowID.nap: return napRow(s)
        case RowID.workout: return workoutRow(s)
        case RowID.guidance: return guidanceRow(s)
        case RowID.warnings: return warningsRow(s)
        default: return nil
        }
    }

    static func exploreAction(_ key: String) -> ActionState {
        ActionState(id: "explore", title: "Open in Explore", intent: .openMetric(key: key, variant: nil))
    }

    /// Just-woke row 1: the smart-wake result as WP-23a words it from WP-11's controller (main, 2026-10-11).
    static func smartWakeRow(_ s: PresenterSnapshot) -> NowRowState {
        let id = RowID.smartWake
        let exp = NowRowExpansion(lines: ["Rate how you feel in the check-in — that's how smart wake learns."],
                                  actions: [ActionState(id: "tonight", title: "Tonight's window ›", intent: .openTonight)])
        guard let sw = s.smartWakeResult else {
            return NowRowState(id: id, badge: "W", tone: .sleep, title: "No smart wake last night",
                               detail: s.context.anchors.wakeAssumed ? "wake assumed — no night detected"
                                   : "no wake plan was set (“must be up by” in Tonight)",
                               receipt: nil, isOpen: isOpen(s, id), expansion: exp)
        }
        return NowRowState(id: id, badge: "W", tone: .sleep, title: sw.title, detail: sw.detail,
                           receipt: Receipt(computedOn: .phone, tier: .research, at: sw.at, method: sw.receiptMethod),
                           isOpen: isOpen(s, id), expansion: exp)
    }

    /// "Medication due (only if a schedule exists and it isn't logged)" (UX §4.1).
    static func medicationRow(_ s: PresenterSnapshot) -> NowRowState? {
        guard let due = s.prescriptionSchedules().first(where: { s.taken($0) == nil }) else { return nil }
        let title = PresenterSnapshot.scheduleTitle(due)
        return NowRowState(id: RowID.medication, badge: "Rx", tone: .ink, title: "\(title) — not logged yet",
                           detail: s.scheduleTime(due).map { "your schedule says about \(s.hm($0))" } ?? "on your schedule today",
                           receipt: nil, receiptNote: "schedule · APP-075",
                           button: ActionState(id: "took", title: "Took it", intent: .quickLog(.medication(name: title))),
                           isOpen: isOpen(s, RowID.medication),
                           expansion: NowRowExpansion(lines: ["Reminder only — no dosing advice."]))
    }

    static func caffeineDetail(_ s: PresenterSnapshot) -> String {
        var parts: [String] = []
        if let n = s.number(.caffeineNow) { parts.append("\(MGFormat.number(n, decimals: 0)) mg in you now") }
        if let b = s.number(.caffeineBedtime) { parts.append("\(MGFormat.number(b, decimals: 0)) mg at bedtime") }
        if let l = s.caffeineLimitMg { parts.append("limit \(MGFormat.number(l, decimals: 0))") }
        return parts.isEmpty ? "nothing logged yet" : parts.joined(separator: " · ")
    }

    static func caffeineRow(_ s: PresenterSnapshot) -> NowRowState {
        let m = s.metric(.caffeineCutoff)
        let title: String
        var detail = caffeineDetail(s)
        if let cut = MetricText.instant(m) {
            title = cut > s.now ? "Caffeine is fine until \(s.hm(cut))" : "No more caffeine today"
        } else {
            title = "Caffeine cut-off"
            detail = s.display(m, missing: "No cut-off computed yet.").blankReason ?? detail
        }
        let exp = NowRowExpansion(chart: s.caffeineCurve.map { Optional($0.value) }, chartCaption: "mg in you → bedtime",
                                  actions: [exploreAction(MetricKey.caffeineCutoff.rawValue)],
                                  methods: s.methodsStrip("G-CAFF"))
        return NowRowState(id: RowID.caffeine, badge: "C", tone: .caffeine, title: title, detail: detail,
                           receipt: m.map(MetricText.receipt), isOpen: isOpen(s, RowID.caffeine), expansion: exp)
    }

    /// Last-night flag (breathing, AF screen, anomaly) — nil when nothing was flagged.
    static func lastNightFlagRow(_ s: PresenterSnapshot) -> NowRowState? {
        let id = RowID.lastNightFlag
        let exp = NowRowExpansion(actions: [ActionState(id: "night", title: "Last night ›", intent: .openNight(nil))])
        let since = s.day.adding(days: -1).start(in: s.calendar.timeZone)
        if let a = s.inputs.alerts.filter({ $0.raisedAt >= since }).sorted(by: { $0.raisedAt > $1.raisedAt }).first {
            return NowRowState(id: id, badge: "N", tone: .body, title: a.sentence, detail: a.evidence,
                               receipt: Receipt(computedOn: .phone, tier: .research, at: a.raisedAt), isOpen: isOpen(s, id),
                               expansion: exp)
        }
        if let af = s.metric(.afScreen, window: "night"), let v = af.value, Int(v.rounded()) == 1 {
            return NowRowState(id: id, badge: "N", tone: .body, title: "Rhythm screen: possible AF last night",
                               detail: "an ECG reading can check it",
                               receipt: MetricText.receipt(af), isOpen: isOpen(s, id), expansion: exp)
        }
        let events = s.eventsYesterdayOrLastNight(.breathingEvent).filter { e in
            if case let .breathing(f) = e.payload { return f.retracted != true }
            return false
        }
        if let first = events.first {
            let n = events.count
            return NowRowState(id: id, badge: "N", tone: .body,
                               title: "\(n) breathing event\(n == 1 ? "" : "s") from \(s.hm(first.at))",
                               detail: "noted, not an alert · ALG-023 screen",
                               receipt: Receipt(computedOn: .phone, tier: .research, at: first.at, method: "ALG-023 screen"),
                               isOpen: isOpen(s, id), expansion: exp)
        }
        return nil
    }

    static func firstVapeRow(_ s: PresenterSnapshot) -> NowRowState {
        let id = RowID.firstVape
        let m = s.metric(.vapeFirstAfterWake)
        let title: String
        var detail: String?
        if let v = m?.value, v.isFinite {
            title = "First vape \(MGFormat.number(v, decimals: 0)) min after waking"
            detail = "\(s.vapeHitsSinceWake().count) today"
        } else if s.vapeHitsSinceWake().isEmpty {
            title = "No vape yet today"
            detail = "\(MGFormat.duration(s.now.timeIntervalSince(s.context.anchors.wake))) since waking"
        } else {
            title = "Time to first vape"
            detail = s.display(m).blankReason
        }
        return NowRowState(id: id, badge: "V", tone: .body, title: title, detail: detail,
                           receipt: m.map(MetricText.receipt), isOpen: isOpen(s, id),
                           expansion: NowRowExpansion(actions: [ActionState(id: "vape", title: "Log › Vape",
                                                                            intent: .openLogItem(.vape))]))
    }

    static func dipRow(_ s: PresenterSnapshot) -> NowRowState {
        let id = RowID.dip
        let alert = s.number(.alertness).map { "alertness \(MGFormat.number($0, decimals: 0)) now" }
        guard let dip = s.dip else {
            return NowRowState(id: id, badge: "D", tone: .caffeine, title: "Dip forecast",
                               detail: s.display(.alertness, missing: "The alertness model hasn't run yet.").blankReason,
                               receipt: s.metric(.alertness).map(MetricText.receipt), isOpen: isOpen(s, id))
        }
        let title: String
        if let w = dip.window, w.end > s.now {
            title = w.start <= s.now ? "In the dip until \(s.hm(w.end))" : "Dip likely \(s.range(w.start, w.end))"
        } else if let w = dip.window {
            title = "Dip passed (\(s.range(w.start, w.end)))"
        } else {
            title = "No dip predicted this afternoon"
        }
        var detail = [alert].compactMap { $0 }
        if dip.reactionTests < VerdictRules.reactionTestsForPersonalCurve { detail.append("population curve, not yours yet") }
        return NowRowState(id: id, badge: "D", tone: .caffeine, title: title,
                           detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                           receipt: Receipt(computedOn: .phone, tier: .estimate, at: dip.at, method: "ALG-051/052"),
                           isOpen: isOpen(s, id))
    }

    static func strainRow(_ s: PresenterSnapshot) -> NowRowState {
        let id = RowID.strain
        let st = s.dayStrain()
        var title = "Strain \(DialPresenter.strainHeadline(s)) so far"
        if let steps = s.number(.steps) { title += " · \(MGFormat.grouped(Int(steps.rounded()))) steps" }
        var detail: String?
        if let v = st?.value, v.isFinite {
            if let q = s.strainQuartiles {
                detail = v < q.p25 ? "light so far" : (v > q.p75 ? "a big day so far" : "a steady day so far")
                detail! += " · against your 28 days"
            } else {
                detail = "your 28-day range isn't ready yet"
            }
        } else {
            detail = s.display(st, missing: "No strain computed yet today.").blankReason
        }
        return NowRowState(id: id, badge: "S", tone: .body, title: title, detail: detail,
                           receipt: st.map(MetricText.receipt), isOpen: isOpen(s, id),
                           expansion: NowRowExpansion(actions: [exploreAction(MetricKey.strain.rawValue)],
                                                      methods: s.methodsStrip("G-LOAD", window: "day")))
    }

    /// T128 + T129: "push or relax" (PushOrRelax, rule-based) with the day's workout guidance (WorkoutGuidance) under it.
    /// Both are estimates and say so. nil when neither has anything to say, so the other rows keep their places.
    static func guidanceRow(_ s: PresenterSnapshot) -> NowRowState? {
        let id = RowID.guidance
        let advice = PushOrRelax.make(s, labels: ActivityLabels.from(events: s.events))
        let guidance = WorkoutGuidance.make(s)
        guard advice.advice != nil || guidance.band != nil else { return nil }
        let title: String
        switch advice.advice {
        case .push?: title = "Push (estimate)"
        case .relax?: title = "Relax (estimate)"
        case nil: title = "Push or relax: no advice yet (estimate)"
        }
        return NowRowState(id: id, badge: "P", tone: .body, title: title, detail: guidance.text, receipt: nil,
                           receiptNote: "estimate · rule-based", isOpen: isOpen(s, id),
                           expansion: NowRowExpansion(lines: [advice.text]))
    }

    static func caffeineBedtimeRow(_ s: PresenterSnapshot) -> NowRowState {
        let id = RowID.caffeineBedtime
        let m = s.metric(.caffeineBedtime)
        let doses = s.caffeineSinceWake()
        let title: String
        var detail: [String] = []
        if let v = m?.value, v.isFinite {
            title = "\(MGFormat.number(v, decimals: 0)) mg caffeine at bedtime"
            if let l = s.caffeineLimitMg {
                detail.append(v <= l ? "under your \(MGFormat.number(l, decimals: 0))" : "over your \(MGFormat.number(l, decimals: 0))")
            }
        } else if doses.isEmpty {
            title = "No caffeine logged today"
        } else {
            title = "Caffeine at bedtime"
            if let r = s.display(m).blankReason { detail.append(r) }
        }
        if let last = doses.last {
            detail.append("last dose \(s.hm(last.fields.finishedAt ?? last.event.at))")
        }
        return NowRowState(id: id, badge: "C", tone: .caffeine, title: title,
                           detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                           receipt: m.map(MetricText.receipt), isOpen: isOpen(s, id),
                           expansion: NowRowExpansion(chart: s.caffeineCurve.map { Optional($0.value) },
                                                      chartCaption: "mg in you → bedtime",
                                                      methods: s.methodsStrip("G-CAFF")))
    }

    /// r9h: the variant that carries our own recovery. Orchard (MS-19) rebuilt as ALG-160 readiness 1-100; before the rebuild
    /// the default was the ALG-036 "n of 5" count, and a saved choice of "ALG-036" still means "ours".
    static let ownRecoveryVariant = "MS-19"

    static func ownReadVariant(_ s: PresenterSnapshot) -> String {
        guard let read = s.readVariant(group: "G-READY"), read != "ALG-036" else { return ownRecoveryVariant }
        return read
    }

    /// Bug 14 (round 2, 2026-10-14, M-022): true when the recovery read is our ALG-160 readiness (the default); false when Mo
    /// picked another G-READY method, whose value then leads the row instead of the readiness score.
    static func recoveryReadsOurs(_ s: PresenterSnapshot) -> Bool {
        ownReadVariant(s) == ownRecoveryVariant
    }

    /// The word after "Recovery this morning:". A chosen method with bands gives the band word; one with no published
    /// bands gives its own value ("Aurora 72 /100"), never "too little to say" for a value that is there.
    static func recoveryWord(_ s: PresenterSnapshot, _ v: VerdictState) -> String {
        let word = VerdictRules.recoveryWord(v.headline)
        guard !recoveryReadsOurs(s), v.headline != VerdictRules.tooLittleHeadline,
              word == VerdictRules.recoveryWord(VerdictRules.tooLittleHeadline) else { return word }
        return v.headline.hasSuffix(".") ? String(v.headline.dropLast()) : v.headline
    }

    /// The row / strip detail for the recovery read: our readiness ("82 of 100 · HRV in your range") when it is the read
    /// method; else the chosen method's own value ("Loop 72 /100") from the verdict's receipt note.
    static func recoveryReadDetail(_ s: PresenterSnapshot, _ v: VerdictState) -> String? {
        if recoveryReadsOurs(s) {
            if let r = s.recovery, r.status == .ok, let score = r.score {
                return ["\(score) of 100", VerdictRules.hrvWord(r), VerdictRules.shortBaselineLabel(r)].compactMap { $0 }
                    .joined(separator: " · ")
            }
            return nil
        }
        return v.receiptNote
    }

    static func recoveryRow(_ s: PresenterSnapshot) -> NowRowState {
        let v = recoveryVerdict(s)
        let strip = s.methodsStrip("G-READY")
        var detail: [String] = []
        if let d = recoveryReadDetail(s, v) { detail.append(d) }
        if let strip { detail.append("\(strip.members.count) methods") }
        return NowRowState(id: RowID.recovery, badge: "R", tone: .focus,
                           title: "Recovery this morning: \(recoveryWord(s, v))",
                           detail: detail.isEmpty ? v.sentence : Optional(detail.joined(separator: " · ")),
                           receipt: v.receipt,
                           isOpen: isOpen(s, RowID.recovery), expansion: NowRowExpansion(methods: strip))
    }

    static func tonightToggles(_ s: PresenterSnapshot) -> [ToggleState] {
        let w = s.wakeWindow(narrowed: s.context.phase == .lateNight)
        return [
            ToggleState(id: "sw", title: "Smart wake",
                        detail: w.map { "light sleep inside \(s.range($0.start, $0.end)), else \(s.hm($0.end))" },
                        isOn: s.settings.smartWakeOn, enabled: w != nil,
                        disabledReason: w == nil ? "Set “must be up by” for tomorrow first." : nil,
                        intent: .setSmartWake(!s.settings.smartWakeOn)),
            ToggleState(id: "ns", title: "Listen tonight", detail: "cough, snore, groan · audio stays on the phone",
                        isOn: s.settings.nightSoundsOn, intent: .setNightSounds(!s.settings.nightSoundsOn)),
            ToggleState(id: "wd", title: "Wind-down reminder",
                        detail: "\(s.hm(s.context.anchors.bedtime.addingTimeInterval(-3600))), one notification",
                        isOn: s.settings.windDownOn, intent: .setWindDown(!s.settings.windDownOn)),
        ]
    }

    static func tonightRow(_ s: PresenterSnapshot) -> NowRowState {
        let id = RowID.tonight
        let b = s.context.anchors.bedtime
        var title = "Tonight: bed \(s.hm(b))"
        if let w = s.wakeWindow(narrowed: false) { title += ", up \(s.range(w.start, w.end))" }
        var detail: [String] = []
        if let need = TonightPresenter.needMinutes(s) { detail.append("need \(MetricText.minutes(need))") }
        detail.append(s.settings.smartWakeOn && s.wakeWindow(narrowed: false) != nil ? "smart wake on" : "smart wake off")
        return NowRowState(id: id, badge: "T", tone: .sleep, title: title, detail: detail.joined(separator: " · "),
                           receipt: s.metric(.sleepNeed).map(MetricText.receipt),
                           isOpen: isOpen(s, id, default: s.context.phase == .night),
                           expansion: NowRowExpansion(toggles: tonightToggles(s),
                                                      actions: [ActionState(id: "open", title: "Open Tonight ›",
                                                                            intent: .openTonight)]))
    }

    static func recapRow(_ s: PresenterSnapshot) -> NowRowState {
        let st = s.dayStrain()
        var title = "Today: strain \(DialPresenter.strainHeadline(s))"
        if let steps = s.number(.steps) { title += " · \(MGFormat.grouped(Int(steps.rounded()))) steps" }
        var parts = ["vape \(s.vapeHitsSinceWake().count)"]
        let mg = s.caffeineSinceWake().compactMap { $0.fields.caffeineMg }.reduce(0, +)
        parts.append("caffeine \(MGFormat.number(mg, decimals: 0)) mg")
        for sched in s.prescriptionSchedules() {
            parts.append("\(sched.name) \(s.taken(sched) == nil ? "not logged" : "✓")")
        }
        if s.medicationsSinceWake().contains(where: { $0.fields.category == .supplement }) { parts.append("supplements ✓") }
        return NowRowState(id: RowID.recap, badge: "D", tone: .ink2, title: title, detail: parts.joined(separator: " · "),
                           receipt: nil, receiptNote: "log + strap · \(s.hm(s.now))", isOpen: isOpen(s, RowID.recap))
    }

    static func breatheRow(_ s: PresenterSnapshot) -> NowRowState {
        NowRowState(id: RowID.breathe, badge: "~", tone: .focus,
                    title: "Wind down: breathe \(BreatheState.defaultMinutes) min",
                    detail: "pacer at \(MGFormat.number(BreatheState.defaultBreathsPerMinute, decimals: 0)) /min · coherence shown after",
                    receipt: nil, receiptNote: "ALG-104",
                    button: ActionState(id: "start", title: "Start", intent: .startBreathe), isOpen: isOpen(s, RowID.breathe))
    }

    static func smartWakeLateRow(_ s: PresenterSnapshot) -> NowRowState {
        let id = RowID.smartWakeLate
        let toggles = [tonightToggles(s)[0]]
        guard let w = s.wakeWindow(narrowed: true) else {
            return NowRowState(id: id, badge: "W", tone: .sleep, title: "No wake plan for tomorrow",
                               detail: "set “must be up by” in Tonight", receipt: nil, isOpen: isOpen(s, id),
                               expansion: NowRowExpansion(actions: [ActionState(id: "open", title: "Open Tonight ›",
                                                                                intent: .openTonight)]))
        }
        guard s.settings.smartWakeOn else {
            return NowRowState(id: id, badge: "W", tone: .sleep, title: "Smart wake is off",
                               detail: "nothing rings early", receipt: nil, isOpen: isOpen(s, id),
                               expansion: NowRowExpansion(toggles: toggles))
        }
        return NowRowState(id: id, badge: "W", tone: .sleep, title: "Smart wake narrowed to \(s.range(w.start, w.end))",
                           detail: "you're short on sleep, so it waits for the last 15 min",
                           receipt: s.phoneReceipt(.estimate, method: "ALG-115"), isOpen: isOpen(s, id),
                           expansion: NowRowExpansion(toggles: toggles))
    }

    static func zonesRow(_ s: PresenterSnapshot) -> NowRowState {
        let w = s.live?.workout
        let mins = w?.zoneMinutes ?? []
        let title = mostZone(mins).map { "Mostly zone \($0)" } ?? "Zones"
        let detail: String? = mins.isEmpty
            ? (w?.zoneBasis == nil ? "zones need a max heart rate (Preferences › Profile)" : nil)
            : mins.enumerated().map { "Z\($0.offset + 1) \(MGFormat.number($0.element, decimals: 0))" }.joined(separator: " · ")
        return NowRowState(id: RowID.zones, badge: "Z", tone: .body, title: title, detail: detail,
                           receipt: Receipt(computedOn: .strap, tier: .strap, at: s.now),
                           receiptNote: w?.zoneBasis.map { "zones from your \($0)" }, isOpen: isOpen(s, RowID.zones))
    }

    static func workoutBreathingRow(_ s: PresenterSnapshot) -> NowRowState {
        let m = s.live?.workout?.breathing
        let title: String
        if let v = m?.value, v.isFinite { title = "Breathing \(MGFormat.number(v, decimals: 0)) /min" } else { title = "Breathing" }
        return NowRowState(id: RowID.workoutBreathing, badge: "B", tone: .live, title: title,
                           detail: m?.value != nil ? Optional("last minute · two estimators agree")
                               : s.display(m, missing: "Shown only where two breathing estimators agree (APP-031).").blankReason,
                           receipt: m.map(MetricText.receipt), isOpen: isOpen(s, RowID.workoutBreathing))
    }

    static func doubleTapRow(_ s: PresenterSnapshot) -> NowRowState {
        let w = s.live?.workout
        var detail = "\(w?.setsDone ?? 0) sets so far"
        if let last = w?.lastSetAt { detail += " · last \(s.hm(last))" }
        return NowRowState(id: RowID.doubleTap, badge: "2×", tone: .ink2, title: "Double-tap the strap = set done",
                           detail: detail, receipt: nil, receiptNote: "strap event · APP-007",
                           isOpen: isOpen(s, RowID.doubleTap))
    }

    /// Workout metrics: the detail input's own list first, then the day's.
    static func workoutMetric(_ s: PresenterSnapshot, _ name: String) -> Metric? {
        if let d = s.workoutDetail, let m = s.metric(name, window: "workout", in: d.metrics) { return m }
        return s.metric(name, window: "workout")
    }

    static func hrRecoveryRow(_ s: PresenterSnapshot) -> NowRowState {
        let m = workoutMetric(s, PresenterKit.hrRecoveryName)
        let title: String
        if let v = m?.value, v.isFinite { title = "Heart rate fell \(MGFormat.number(v, decimals: 0)) bpm in 1 min" } else { title = "HR recovery, 1 min" }
        return NowRowState(id: RowID.hrRecovery, badge: "H", tone: .body, title: title,
                           detail: m?.value != nil ? Optional("HR recovery after the session")
                               : s.display(m, missing: PresenterKit.hrRecoveryNotBuilt).blankReason,
                           receipt: m.map(MetricText.receipt), isOpen: isOpen(s, RowID.hrRecovery))
    }

    static func caloriesRow(_ s: PresenterSnapshot) -> NowRowState {
        let m = workoutMetric(s, MetricKey.caloriesActive.rawValue)
        let title: String
        if let v = m?.value, v.isFinite { title = "\(MGFormat.grouped(Int(v.rounded()))) kcal burned in the session" } else { title = "Calories in the session" }
        let strip = s.methodsStrip("G-CAL", window: "workout", source: s.workoutDetail?.metrics)
        return NowRowState(id: RowID.calories, badge: "K", tone: .caffeine, title: title,
                           detail: m?.value != nil ? strip.map { "\($0.members.count) methods" }
                               : s.display(m, missing: "No calorie estimate stored for this workout.").blankReason,
                           receipt: m.map(MetricText.receipt), isOpen: isOpen(s, RowID.calories),
                           expansion: NowRowExpansion(methods: strip))
    }

    static func napRow(_ s: PresenterSnapshot) -> NowRowState? {
        guard case let .nap(start, end)? = s.context.peek else { return nil }
        return NowRowState(id: RowID.nap, badge: "N", tone: .sleep, title: "Nap \(s.range(start, end)), probably",
                           detail: MGFormat.duration(end.timeIntervalSince(start)),
                           receipt: s.phoneReceipt(.estimate, at: end, method: "ALG-033 nap detector"),
                           isOpen: isOpen(s, RowID.nap))
    }

    /// A workout that ended today and no longer has its card (confirmed, or 2 h passed): a Now row until midnight.
    static func workoutEarlierToday(_ s: PresenterSnapshot) -> EventRecord? {
        let midnight = s.calendar.startOfDay(for: s.now)
        return s.eventsOf(.workout).last { e in
            guard case let .workout(f) = e.payload else { return false }
            return f.end <= s.now && f.end >= midnight
        }
    }

    static func workoutRow(_ s: PresenterSnapshot) -> NowRowState? {
        guard let e = workoutEarlierToday(s), case let .workout(f) = e.payload else { return nil }
        let type = LivePresenter.workoutTitle(type: f.activityTypeUser ?? f.activityTypeAuto, place: e.location?.label)
        return NowRowState(id: RowID.workout, badge: "W", tone: .body, title: "Workout \(s.range(e.at, f.end))",
                           detail: "\(type) · \(MGFormat.duration(f.end.timeIntervalSince(e.at)))", receipt: nil,
                           isOpen: isOpen(s, RowID.workout),
                           expansion: NowRowExpansion(actions: [ActionState(id: "open", title: "Open workout ›",
                                                                            intent: .openWorkout(id: e.id))]))
    }

    // MARK: Strips (UX §3.2 row 7)

    static func strips(_ s: PresenterSnapshot) -> (primary: StripState, secondary: StripState?) {
        func flip(_ kind: StripState.Kind, _ collapsed: Bool) -> Bool {
            collapsed != s.ui.openRows.contains("strip.\(kind.rawValue)")
        }
        switch s.context.phase {
        case .morning:
            return (lastNight(s, withRecovery: false, collapsed: flip(.lastNight, false)),
                    todaySoFar(s, collapsed: flip(.todaySoFar, true)))
        case .earlyAfternoon:
            return (lastNight(s, withRecovery: true, collapsed: flip(.lastNight, false)),
                    todaySoFar(s, collapsed: flip(.todaySoFar, true)))
        case .lateAfternoon, .sundown:
            return (todaySoFar(s, collapsed: flip(.todaySoFar, false)),
                    lastNight(s, withRecovery: true, collapsed: flip(.lastNight, true)))
        case .night, .lateNight:
            return (todaySoFar(s, collapsed: flip(.todaySoFar, true)), nil)
        }
    }

    /// Skin temperature as words against your range (UX §0: raw counts are not units; APP-237).
    static func skinTempWords(_ s: PresenterSnapshot) -> DisplayValue {
        // r9h: temperature left the readiness score (D-RECOV-WALK-2); its range check is the ALG-161 warning sign.
        let m = s.metric(.skinTempDev)
        let sign = s.metric(MetricKey.warningSign.rawValue, variant: "temp", window: "night")
        guard let sign, let level = sign.value, level.isFinite, let m else {
            let reason = sign?.note ?? s.display(m, missing: "No skin temperature stored for last night.").blankReason
            return .blank(reason: reason ?? "Learning your range.", receipt: m.map(MetricText.receipt))
        }
        let word = level < 1 ? "in range" : ((m.value ?? 0) > 0 ? "above your range" : "below your range")
        return s.worded(word, receipt: MetricText.receipt(m))
    }

    static func lastNight(_ s: PresenterSnapshot, withRecovery: Bool, collapsed: Bool) -> StripState {
        // W10 (2026-10-11): a night the strap did not record shows WHOOP's / Apple's own values, labelled — the
        // generic metric() fallback for the same names, and their own % / °C names for SpO₂ and skin temperature
        // (never relabelled as the strap's raw byte or counts).
        func item(_ id: String, _ label: String, _ key: MetricKey, window: String? = nil) -> LabeledValue {
            let m = s.metric(key, window: window)
            return LabeledValue(id: id, label: label, value: s.display(m), caption: s.importCaption(m),
                                intent: .openMetric(key: key.rawValue, variant: nil))
        }
        var spo2 = LabeledValue(id: "spo2", label: s.spo2Gate.passed ? "SpO₂" : "SpO₂ byte",
                                value: s.display(SpO2Gate.shown(s, MetricKey.spo2StrapMean.rawValue)),
                                caption: SpO2Gate.caption(s.spo2Gate),
                                intent: .openMetric(key: MetricKey.spo2StrapMean.rawValue, variant: nil))
        // R9m (D-ALG-TIERS, audit item 10): ENHANCED tier first when raw optical measured the night: our red / IR estimate,
        // always with its label. Then the base reading above (the strap's byte). Only when that is blank, WHOOP's or
        // Apple's own % - never a number of ours without its estimate label.
        // Brain, before merge: only once the LED identity is confirmed (LEDIdentity.confirmed, pc.led-identity);
        // until then the value lives in Explore / the metric detail under its research label.
        if LEDIdentity.confirmed, let e = s.metrics.first(where: { $0.name == MetricKey.spo2Pct.rawValue && $0.variant == "ALG-022:night"
            && $0.window == "night" && ($0.value?.isFinite ?? false) }), let v = e.value {
            spo2 = LabeledValue(id: "spo2", label: "SpO₂ (red / IR)",
                                value: s.worded(MGFormat.number(v, decimals: 0), unit: "% estimate",
                                                receipt: MetricText.receipt(e), style: .estimate(nil)),
                                caption: "estimate — not checked against WHOOP · raw optical",
                                intent: .openMetric(key: MetricKey.spo2Pct.rawValue, variant: nil))
        } else if spo2.value.isBlank, let pct = s.metric(.spo2Pct, window: "night"), pct.value != nil,
                  ImportedHistory.isImported(pct) {
            spo2 = LabeledValue(id: "spo2", label: "SpO₂", value: s.display(pct), caption: s.importCaption(pct),
                                intent: .openMetric(key: MetricKey.spo2Pct.rawValue, variant: nil))
        }
        var temp = LabeledValue(id: "temp", label: "Skin temp", value: skinTempWords(s),
                                intent: .openMetric(key: MetricKey.skinTempDev.rawValue, variant: nil))
        // T35: the main view is the change from your own baseline in °C (R18 byte 73 ÷ 100, decoded, untested).
        if let d = s.metric(.skinTempDev, variant: SkinTemperature.decodedVariant, window: "night"),
           let v = d.value, v.isFinite {
            temp = LabeledValue(id: "temp", label: "Skin temp",
                                value: s.worded(MetricText.signed(v, decimals: 1), unit: "°C",
                                                receipt: MetricText.receipt(d), style: .research),
                                caption: "from your baseline · decoded, untested",
                                intent: .openMetric(key: MetricKey.skinTempDev.rawValue, variant: nil))
        }
        if temp.value.isBlank, let c = s.metric(.skinTempC, window: "night"), c.value != nil {
            temp = LabeledValue(id: "temp", label: "Skin temp", value: s.display(c), caption: s.importCaption(c),
                                intent: .openMetric(key: MetricKey.skinTempC.rawValue, variant: nil))
        }
        // D-SLEEP-PRIORITY-1 item 3 (Mo, Nov 5 2026): every HRV carries its kind, who measured it and what it covers. The RMSSD cell
        // is ours (night), else WHOOP's sleep HRV (a WHOOP-written value is RMSSD even in Apple's SDNN-named type), else Apple's own
        // RMSSD; an SDNN (the Watch's spot readings) has its own cell named SDNN, never standing in for an RMSSD (Oct 28 rule 5).
        var hrv = item("hrv", "HRV", .hrvRmssd)
        if let r = s.nightRmssd() {
            hrv = LabeledValue(id: "hrv", label: "HRV", value: s.display(r), caption: HRVLabel.text(r),
                               intent: .openMetric(key: MetricKey.hrvRmssd.rawValue, variant: nil))
        }
        let sdnnMetric = s.nightSdnn()
        var sdnn: [LabeledValue] = []
        if let sd = sdnnMetric {
            let cell = LabeledValue(id: "hrv_sdnn", label: "HRV (SDNN)", value: s.display(sd), caption: HRVLabel.text(sd),
                                    intent: .openMetric(key: MetricKey.hrvSdnn.rawValue, variant: nil))
            if hrv.value.isBlank {
                hrv = LabeledValue(id: "hrv", label: "HRV (SDNN)", value: cell.value, caption: cell.caption, intent: cell.intent)
            } else {
                sdnn = [cell]
            }
        }
        let items = [
            item("slept", "Slept", .sleepTotal, window: "night"),
            item("rhr", "Resting HR", .rhr),
            hrv,
        ] + sdnn + [
            item("resp", "Breathing", .respRate, window: "night"),
            spo2,
            temp,
        ]
        var summary: String?
        if let r = s.recovery {
            switch r.status {
            case .ok:
                summary = r.score.map { "readiness \($0) of 100" + (VerdictRules.shortBaselineLabel(r).map { " · \($0)" } ?? "") }
            case .learning: summary = "Learning your normal — \(r.hrvNights) of \(VerdictRules.baselineNights) nights"
            case .tooLittle: summary = nil
            }
        }
        if collapsed, let slept = s.number(.sleepTotal) {
            summary = [MetricText.minutes(slept), summary].compactMap { $0 }.joined(separator: " · ")
        }
        var line: String?
        if withRecovery {
            let v = recoveryVerdict(s)
            line = "Recovery this morning: \(recoveryWord(s, v))"
            if let d = recoveryReadDetail(s, v) { line! += " · \(d)" }
        }
        // r9v (UI-SCRUB T6): when the night is not today's wake day, the strip says which night it is.
        let nightTitle = s.day == LocalDay(date: s.now, calendar: s.calendar)
            ? "Last night" : "Night ending \(MGFormat.shortDate(s.day.start(in: s.calendar.timeZone), calendar: s.calendar))"
        return StripState(kind: .lastNight, title: nightTitle, summary: summary, items: items, recoveryLine: line,
                          isCollapsed: collapsed, sleepCard: SleepBreakdownPresenter.card(s))
    }

    /// Tracker #75 (2026-10-11): time worn, heart rate, step ticks and strain from today's strap data, then the log —
    /// built in FrontPagePresenter. Before: strain, steps, caffeine, vape, medication since wake.
    static func todaySoFar(_ s: PresenterSnapshot, collapsed: Bool) -> StripState {
        FrontPagePresenter.todaySoFar(s, collapsed: collapsed)
    }

    // MARK: Quick log (UX §3.2 row 8; BRIEF default 9: the same four all day)

    static func quickLog(_ s: PresenterSnapshot) -> QuickLogState {
        var pills = [QuickLogPill(id: "vape", title: "Vape", systemImage: "wind", intent: .quickLog(.vapeHit))]
        if let sched = s.prescriptionSchedules().first {
            pills.append(QuickLogPill(id: "med", title: sched.name, systemImage: "pills",
                                      intent: .quickLog(.medication(name: PresenterSnapshot.scheduleTitle(sched)))))
        } else {
            pills.append(QuickLogPill(id: "med", title: "Supplements", systemImage: "pills",
                                      intent: .quickLog(.supplementsStack)))
        }
        let drink = s.settings.usualDrink ?? s.settings.drinkPresets.first?.name ?? "Coffee"
        let open = s.caffeineSinceWake().last { $0.fields.finishedAt == nil }
        if let open {
            pills.append(QuickLogPill(id: "drink", title: "Finish \(open.fields.product ?? drink)",
                                      systemImage: "cup.and.saucer", intent: .quickLog(.drinkFinish)))
        } else {
            pills.append(QuickLogPill(id: "drink", title: drink, systemImage: "cup.and.saucer",
                                      intent: .quickLog(.drinkStart(preset: drink))))
        }
        pills.append(QuickLogPill(id: "food", title: "Food", systemImage: "fork.knife", intent: .quickLog(.food)))
        return QuickLogState(pills: pills, confirmCount: s.unconfirmedVapeHits().count)
    }

    // MARK: Peek (UX §5)

    static let feel = ["Groggy", "Slow", "OK", "Clear", "Sharp"]

    static func peek(_ s: PresenterSnapshot) -> PeekState? {
        guard let kind = s.context.peek else { return nil }
        switch kind {
        case let .wearLocation(_, previous):
            var answers: [PeekAnswer] = []
            if let p = previous {
                answers.append(PeekAnswer(id: "same", title: "\(wearName(p)) — same as before", isDefault: true,
                                          intent: .answerPeek(.wearLocation, answer: p.rawValue)))
            }
            for loc in WearLocation.allCases where loc != previous && loc != .unknown {
                answers.append(PeekAnswer(id: loc.rawValue, title: wearName(loc),
                                          intent: .answerPeek(.wearLocation, answer: loc.rawValue)))
            }
            return PeekState(kind: .wearLocation, question: "Where's the strap now?", answers: answers)
        case let .workoutConfirm(start, end):
            // r9p (D-LOAD-WALK-2): step 3 = the session RPE on the CR-10 scale (Foster 2001), asked once the workout is confirmed
            if s.ui.workoutPeekStep >= 3 {
                let answers = LoadReadouts.rpeScale.map { n in
                    PeekAnswer(id: "rpe:\(n)", title: LoadReadouts.rpeTitle(n),
                               intent: .answerPeek(.workoutConfirm, answer: "rpe:\(n)"))
                } + [PeekAnswer(id: "rpe:skip", title: "Skip", intent: .answerPeek(.workoutConfirm, answer: "rpe:skip"))]
                return PeekState(kind: .workoutConfirm, question: "How hard was it overall? 0 rest, 10 maximal",
                                 answers: answers, step: 3, stepCount: 3)
            }
            if s.ui.workoutPeekStep >= 2 {
                let types = [("strength", "Strength"), ("run", "Run"), ("cycle", "Cycle"), ("walk", "Walk"),
                             ("soccer", "Soccer"), ("other", "Other")]
                // #41: Mo's saved places first (by name), then the fixed ones he has no saved place for.
                let saved = s.places.places.map { ($0.name, $0.name) }
                let names = Set(saved.map { $0.1.lowercased() })
                let places = saved + [("gym", "Gym"), ("home", "Home"), ("outdoors", "Outdoors")]
                    .filter { !names.contains($0.1.lowercased()) }
                let answers = types.map { PeekAnswer(id: "type:\($0.0)", title: $0.1,
                                                     intent: .answerPeek(.workoutConfirm, answer: "type:\($0.0)")) }
                    + places.map { PeekAnswer(id: "place:\($0.0)", title: $0.1,
                                              intent: .answerPeek(.workoutConfirm, answer: "place:\($0.0)")) }
                return PeekState(kind: .workoutConfirm, question: "What and where?", answers: answers, step: 2, stepCount: 3)
            }
            // #41: at a saved place the question names it and uses its prior (Home / Work: "not a workout" first).
            if let tag = s.placeTag(start, end) {
                return PeekState(kind: .workoutConfirm,
                                 question: PlaceQuestion.question(tag, range: s.range(start, end)),
                                 answers: PlaceQuestion.answers(tag).map {
                                     PeekAnswer(id: $0.id, title: $0.title, isDefault: $0.isDefault,
                                                intent: .answerPeek(.workoutConfirm, answer: $0.id))
                                 },
                                 step: 1, stepCount: 3, secondaryTitle: "Edit times",
                                 secondaryIntent: .editPeekTimes(.workoutConfirm))
            }
            return PeekState(kind: .workoutConfirm, question: "Workout \(s.range(start, end)) — right?",
                             answers: [PeekAnswer(id: "yes", title: "Yes", isDefault: true,
                                                  intent: .answerPeek(.workoutConfirm, answer: "yes")),
                                       PeekAnswer(id: "not_workout", title: "Not a workout",
                                                  intent: .answerPeek(.workoutConfirm, answer: "not_workout"))],
                             step: 1, stepCount: 3, secondaryTitle: "Edit times",
                             secondaryIntent: .editPeekTimes(.workoutConfirm))
        case let .nap(start, end):
            if s.ui.napPeekStep >= 2 {
                return PeekState(kind: .nap, question: "How do you feel after it?", answers: ratingAnswers(.nap),
                                 step: 2, stepCount: 2)
            }
            let a = [("nap", "Nap"), ("dozed", "Dozed"), ("quiet_rest_not_asleep", "Rest, awake"), ("no", "No")]
            return PeekState(kind: .nap, question: "Nap \(s.range(start, end))?",
                             answers: a.map { PeekAnswer(id: $0.0, title: $0.1, isDefault: $0.0 == "nap",
                                                         intent: .answerPeek(.nap, answer: $0.0)) },
                             step: 1, stepCount: 2, secondaryTitle: "Edit times", secondaryIntent: .editPeekTimes(.nap))
        case .napPlus30:
            return PeekState(kind: .napPlus30, question: "30 min after your nap — how now?", answers: ratingAnswers(.napPlus30))
        case .morningCheckin:
            if s.ui.checkinStep >= 2 {
                return PeekState(kind: .morningCheckin, question: "Yesterday from your log: \(yesterdaySummary(s)).",
                                 answers: [PeekAnswer(id: PeekAnswerID.looksRight, title: "Looks right", isDefault: true,
                                                      intent: .answerPeek(.morningCheckin, answer: PeekAnswerID.looksRight)),
                                           PeekAnswer(id: PeekAnswerID.addSomething, title: "Add something",
                                                      intent: .answerPeek(.morningCheckin, answer: PeekAnswerID.addSomething))],
                                 step: 2, stepCount: 2)
            }
            // UX §5.1: "Smart wake got you up at 06:52, in light sleep. How do you feel?"; no smart wake → "How did you
            // wake up?"
            let q = s.smartWakeResult.map { "\($0.title). How do you feel?" } ?? "How did you wake up?"
            return PeekState(kind: .morningCheckin, question: q,
                             answers: feel.map { PeekAnswer(id: $0.lowercased(), title: $0,
                                                            intent: .answerPeek(.morningCheckin, answer: $0.lowercased())) },
                             step: 1, stepCount: 2)
        case let .mealCheckin(mealAt, _):
            let meaning = [1: "extremely alert", 3: "alert", 5: "neither", 7: "sleepy", 9: "fighting sleep"]
            let ago = MGFormat.duration(s.now.timeIntervalSince(mealAt))
            return PeekState(kind: .mealCheckin, question: "\(mealName(s, mealAt)) was \(ago) ago — how sleepy?",
                             answers: (1...9).map { k in
                                 PeekAnswer(id: "kss\(k)", title: "\(k)", detail: meaning[k],
                                            intent: .answerPeek(.mealCheckin, answer: "kss\(k)"))
                             })
        }
    }

    /// Groggy ↔ refreshed, 5 steps (APP-045; NapFields rating 1 groggy … 5 refreshed); answers "1"…"5" (main).
    static func ratingAnswers(_ kind: PeekKindKey) -> [PeekAnswer] {
        let titles = ["Groggy", "A bit groggy", "OK", "Fresh", "Refreshed"]
        return zip(PeekAnswerID.napRatings, titles).map { pair in
            PeekAnswer(id: pair.0, title: pair.1, intent: .answerPeek(kind, answer: pair.0))
        }
    }

    static func wearName(_ w: WearLocation) -> String {
        switch w {
        case .leftWrist: return "Left wrist"
        case .rightWrist: return "Right wrist"
        case .leftBicep: return "Left bicep"
        case .rightBicep: return "Right bicep"
        case .bodyTorso: return "Torso"
        case .bodyWaist: return "Waist"
        case .tailboneUnderwear: return "Underwear / tailbone"
        case .other: return "Somewhere else"
        case .unknown: return "Not sure"
        }
    }

    static func mealName(_ s: PresenterSnapshot, _ at: Date) -> String {
        if let e = s.eventsOf(.food).first(where: { abs($0.at.timeIntervalSince(at)) < 60 }), case let .food(f) = e.payload,
           let t = f.text, !t.isEmpty {
            return t.prefix(1).uppercased() + t.dropFirst()
        }
        return "Your meal"
    }

    /// "2 caffeine · 16 vape hits · MedA ✓ · no alcohol" from yesterday's log (UX §5.1 step 2).
    static func yesterdaySummary(_ s: PresenterSnapshot) -> String {
        let subs = s.eventsYesterday(.substance).compactMap { e -> SubstanceFields? in
            if case let .substance(f) = e.payload { return f }
            return nil
        }
        let caffeine = subs.filter { $0.kind == .caffeine }.count
        let vape = subs.filter {
            ($0.kind == .vapeTick || $0.kind == .vape) && $0.vape?.detectedStatus != .rejected
        }.count
        let alcohol = subs.filter { $0.kind == .alcohol }.count
        var parts = ["\(caffeine) caffeine", "\(vape) vape hit\(vape == 1 ? "" : "s")"]
        let meds = s.eventsYesterday(.medication).compactMap { e -> MedicationFields? in
            if case let .medication(f) = e.payload { return f }
            return nil
        }
        for sched in s.prescriptionSchedules() {
            let took = meds.contains { ($0.scheduleId == sched.id || $0.name == sched.name) && $0.status != .skipped }
            parts.append("\(sched.name) \(took ? "✓" : "not logged")")
        }
        parts.append(alcohol == 0 ? "no alcohol" : "\(alcohol) alcohol")
        return parts.joined(separator: " · ")
    }
}

extension DisplayValue {
    /// The reason of a blank; nil for a value.
    var blankReason: String? {
        if case let .blank(reason, _) = self { return reason }
        return nil
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
