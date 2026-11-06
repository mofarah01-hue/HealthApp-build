import Foundation
import MGDomain

// SAMPLE previews for every other state type (ARCHITECTURE §4.7: "each state type ships a static let preview built
// from UX prototype values with sample: true"). Values from app/prototype/index.html.

extension Receipt {
    public static let preview = SampleDay.receipt(.phone, .high, 6, 52)
}

extension DisplayValue {
    /// "52 ms" HRV, plain (high tier).
    public static let preview = SampleDay.value("52", "ms", SampleDay.receipt(.phone, .high, 6, 58))
    /// The UX §13 blank.
    public static let previewBlank = DisplayValue.blank(reason: "38 % of beats were noisy; nothing reliable.",
                                                        receipt: SampleDay.receipt(.phone, .high, 6, 58))
}

extension MomentViewState {
    public static let preview: MomentViewState = TodayState.preview(for: .off).moment
        ?? MomentViewState(kind: .strapOff, title: "Strap off", trailing: nil, line: "", detail: nil,
                           actionTitle: nil, action: nil, tone: .body, extraCount: 0)
    /// "Waiting for the PC" (UX §4.2 data waiting).
    public static let previewDataWaiting = MomentViewState(
        kind: .dataWaiting, title: "Waiting for the PC", trailing: "7 h · 2.1 MB",
        line: "Tailscale is off or the PC is asleep.",
        detail: "Everything is safe on the phone; PC results show their date until it syncs.",
        actionTitle: "Open Tailscale", action: .openTailscale, secondaryActionTitle: "Later",
        secondaryAction: .dismissMoment(.dataWaiting), tone: .caffeine, extraCount: 0)
    /// "Fetching strap history · 62 % · 3 h 10 of 5 h".
    public static let previewHistory = MomentViewState(
        kind: .historyDownloading, title: "Fetching strap history", trailing: "62 %", line: "3 h 10 of 5 h",
        detail: nil, actionTitle: nil, action: nil, progress: 0.62, tone: .sleep, extraCount: 1)
}

extension PeekState {
    public static let preview: PeekState = TodayState.preview(for: .woke).peek
        ?? PeekState(kind: .morningCheckin, question: "How did you wake up?", answers: [])
}

extension LiveState {
    public static let preview: LiveState = {
        let now = SampleDay.at(9, 40)
        let live = Receipt(computedOn: .strap, tier: .strap, at: now)
        let rr: [TachogramPoint] = (0..<70).map { i in
            let base = 820.0 + 40 * sin(Double(i) / 3)
            return TachogramPoint(at: now.addingTimeInterval(Double(i) * 0.85 - 60), rrMs: i == 23 ? 1410 : base,
                                  artefact: i == 23)
        }
        let wave: [Double] = (0..<200).map { i in
            let p = Double(i % 25) / 25
            return p < 0.2 ? p * 5 : max(0, 1 - (p - 0.2) * 1.4)
        }
        var state = LiveState(
            sample: true, streamChip: StreamChipState(text: "R26 · 25 Hz · quality good", tone: .good),
            heartRate: SampleDay.value("71", "bpm", live), beatInterval: 0.85,
            rmssd: SampleDay.value("48", "ms", Receipt(computedOn: .phone, tier: .high, at: now, method: "ALG-010")),
            autonomicLoad: SampleDay.value("calm", nil, Receipt(computedOn: .phone, tier: .relative, at: now,
                                                                method: "ALG-054"), .estimate(nil)),
            autonomicLevel: 0.3, pulseWave: wave, pulseQuality: "quality good", tachogram: rr,
            tachogramMedian: SampleDay.value("832", "ms", Receipt(computedOn: .phone, tier: .high, at: now)),
            streams: [
                StreamLine(id: "r26", text: "R26 pulse, 25 Hz, flowing", tone: .good),
                StreamLine(id: "50hz", text: "50 Hz mode flag off", tone: .neutral),
                StreamLine(id: "r20", text: "R20 raw optical off", tone: .neutral, note: "Strap & sync › Raw optical"),
            ],
            actions: [
                ActionState(id: "breathe", title: "Breathe", intent: .startBreathe),
                ActionState(id: "hrv", title: "HRV check", intent: .startHRVCheck(minutes: 3)),
                ActionState(id: "ecg", title: "ECG, 30 s", intent: .startECG, enabled: false,
                            disabledReason: "Turn ECG on in Strap & sync first."),
                ActionState(id: "workout", title: "Workout", intent: .startWorkout),
                ActionState(id: "spo2", title: "SpO₂ now", intent: nil, enabled: false,
                            disabledReason: "No known command starts an awake reading."),
            ],
            broadcast: ToggleState(id: "broadcast", title: "Share heart rate with gym kit and other apps", isOn: false,
                                   enabled: false, disabledReason: "Heart-rate sharing isn't available yet.",
                                   intent: .setBroadcast(true)),
            researchLinks: [
                ActionState(id: "inspector", title: "Record inspector", intent: .openResearch("inspector")),
                ActionState(id: "capture", title: "Capture session", intent: .openResearch("capture")),
                ActionState(id: "retention", title: "Raw retention", intent: .openResearch("retention")),
            ],
            workout: nil, blankReason: nil)
        state.rmssdTile = LiveTileState(kind: .solid, text: "48", unit: "ms", note: "average of 4 clean 5-min windows today",
                                        receipt: Receipt(computedOn: .phone, tier: .high, at: now, method: "ALG-010"))
        state.loadTile = LiveTileState(kind: .solid, text: "about usual", note: "this 5-min window against your usual for this hour")
        return state
    }()

    /// Strap off: everything blank with the reason (UX §13).
    public static let previewStrapOff: LiveState = {
        var s = LiveState.preview
        let reason = "Strap's off your wrist — nothing to show live. Off since 15:12."
        s.heartRate = .blank(reason: reason, receipt: nil)
        s.rmssd = .blank(reason: reason, receipt: nil)
        s.autonomicLoad = .blank(reason: reason, receipt: nil)
        s.rmssdTile = .blank(reason)
        s.loadTile = .blank(reason)
        s.tachogramMedian = .blank(reason: reason, receipt: nil)
        s.pulseWave = []
        s.tachogram = []
        s.beatInterval = nil
        s.blankReason = reason
        return s
    }()

    /// Workout mode in place.
    public static let previewWorkout: LiveState = {
        var s = LiveState.preview
        s.workout = WorkoutModeState.preview
        return s
    }()
}

extension WorkoutModeState {
    public static let preview: WorkoutModeState = {
        let now = SampleDay.at(17, 45)
        let strap = Receipt(computedOn: .strap, tier: .strap, at: now)
        let ph = Receipt(computedOn: .phone, tier: .high, at: now)
        // Explicit types: Xcode's type-checker timed out on the untyped closure (first CI run, 2026-10-11).
        let trace: [Double] = (0..<156).map { (i: Int) -> Double in
            let x = Double(i)
            return 95.0 + x * 0.3 + 12.0 * sin(x / 9.0)
        }
        return WorkoutModeState(
            sample: true, title: "Gym, strength", start: SampleDay.at(17, 32), elapsed: "13:10",
            heartRate: SampleDay.value("138", "bpm", strap), zone: 3, zoneMinutes: [2, 4, 6, 1, 0], hrTrace: trace,
            windows: [
                WorkoutWindowRow(kind: "warmup", label: "Warm-up", start: SampleDay.at(17, 32), end: SampleDay.at(17, 38),
                                 avgHR: SampleDay.value("112", "bpm", strap)),
                WorkoutWindowRow(kind: "work", label: "Set 1–4", start: SampleDay.at(17, 38), end: nil,
                                 avgHR: SampleDay.value("134", "bpm", strap)),
            ],
            breathing: SampleDay.value("27", "/min", Receipt(computedOn: .phone, tier: .estimate, at: now,
                                                             method: "ALG-020"), .estimate(nil)),
            strain: SampleDay.value("6.2", "/21", ph), strainGroup: MethodsStripState.previewLoad,
            doubleTapHint: "Double-tap the strap = set done · 4 sets so far · last 17:43",
            actions: [ActionState(id: "next", title: "Next window", intent: .nextWorkoutWindow),
                      ActionState(id: "end", title: "End workout", intent: .endWorkout)],
            zoneEdgesBpm: [114, 133, 152, 171], zoneBasis: "measured max 190")
    }()
}

extension LogState {
    public static let preview: LogState = {
        let rows: [LogItemRow] = [
            LogItemRow(item: .vape, title: "Vape", collapsedText: "5 today · last 09:30",
                       primaryButton: ActionState(id: "hit", title: "+ Hit", intent: .quickLog(.vapeHit))),
            LogItemRow(item: .medication, title: "MedA 20 mg", collapsedText: "taken 07:15 ✓", primaryButton: nil),
            LogItemRow(item: .caffeine, title: "Caffeine", collapsedText: "156 mg in you",
                       primaryButton: ActionState(id: "start", title: "Start",
                                                  intent: .quickLog(.drinkStart(preset: "Coffee")))),
            LogItemRow(item: .supplements, title: "Supplements", collapsedText: "morning stack ✓", primaryButton: nil),
            LogItemRow(item: .food, title: "Food", collapsedText: "breakfast 08:30",
                       primaryButton: ActionState(id: "food", title: "+ Food", intent: .addEntry(.food))),
            LogItemRow(item: .symptom, title: "Symptom", collapsedText: "1 today",
                       primaryButton: ActionState(id: "sym", title: "+", intent: .addEntry(.symptom))),
            LogItemRow(item: .sleepy, title: "Sleepy & check-in", collapsedText: "none yet",
                       primaryButton: ActionState(id: "kss", title: "+", intent: .addEntry(.sleepy))),
            LogItemRow(item: .alcohol, title: "Alcohol", collapsedText: "none today",
                       primaryButton: ActionState(id: "alc", title: "+", intent: .addEntry(.alcohol))),
            LogItemRow(item: .note, title: "Note", collapsedText: "",
                       primaryButton: ActionState(id: "note", title: "+", intent: .addEntry(.note))),
            LogItemRow(item: .more, title: "More ›", collapsedText: "Health record, scan, BP cuff, reaction tests",
                       primaryButton: nil),
        ]
        let spine: [SpineEntry] = [
            SpineEntry(id: UUID(), mark: .vapeStroke, at: SampleDay.at(7, 4), title: "Vape hit"),
            SpineEntry(id: UUID(), mark: .logged, at: SampleDay.at(7, 15), title: "MedA 20 mg"),
            SpineEntry(id: UUID(), mark: .drinkBar, at: SampleDay.at(7, 30), end: SampleDay.at(8, 15),
                       title: "DrinkA · 200 mg"),
            SpineEntry(id: UUID(), mark: .logged, at: SampleDay.at(8, 0), title: "Mg glycinate · D3 · fish oil ×2"),
            SpineEntry(id: UUID(), mark: .logged, at: SampleDay.at(8, 30), title: "Breakfast · eggs, toast"),
            SpineEntry(id: UUID(), mark: .vapeStroke, at: SampleDay.at(9, 30), title: "Vape hit", unconfirmed: true),
            SpineEntry(id: UUID(), mark: .logged, at: SampleDay.at(9, 35), title: "Stool · soft",
                       timing: "happened 09:35 · logged 09:49"),
        ]
        let days = (1...31).compactMap { LocalDay(iso: String(format: "2026-10-%02d", $0)) }
        let marks: [Bool?] = days.indices.map { $0 < 10 ? ($0 == 4 ? false : true) : nil }
        return LogState(
            sample: true, confirmCount: 1,
            confirmList: [ConfirmItem(id: "vape-0930", title: "Vape hit 09:30?",
                                      yes: .confirmDetected(id: "vape-0930", accepted: true),
                                      no: .confirmDetected(id: "vape-0930", accepted: false))],
            items: rows, spine: spine,
            monthGrid: MonthGridState(title: "October", days: days,
                                      rows: [MonthGridRow(item: .medication, title: "MedA 20 mg", marks: marks)]))
    }()
}

extension ExploreState {
    public static let preview: ExploreState = {
        let r = SampleDay.receipt(.phone, .high, 6, 58)
        func spark(_ base: Double, _ amp: Double) -> [Double?] {
            (0..<30).map { (i: Int) -> Double? in i == 11 ? nil : base + amp * sin(Double(i) / 4.0) }
        }
        func entry(_ key: String, _ name: String, _ group: String? = nil, research: Bool = false) -> CatalogueEntry {
            CatalogueEntry(key: key, name: name, groupId: group, isResearch: research,
                           intent: .openMetric(key: key, variant: nil))
        }
        return ExploreState(
            sample: true, query: "", period: .days30,
            shelf: [
                ShelfItem(key: "hrv_rmssd", name: "HRV", value: SampleDay.value("52", "ms", r), sparkline: spark(50, 6)),
                ShelfItem(key: "sleep_total", name: "Total sleep", value: SampleDay.value("7 h 08", nil, r),
                          sparkline: spark(7.2, 0.5)),
                ShelfItem(key: "vape_hits", name: "Vape hits", value: SampleDay.value("16", "/day", r),
                          sparkline: spark(17, 3)),
            ],
            catalogue: [
                CatalogueSection(title: "Heart & lungs", isOpen: true, entries: [
                    entry("resting_hr", "Resting HR"), entry("hrv_rmssd", "HRV", "G-HRV"),
                    entry("resp_rate", "Breathing rate", "G-RESP"), entry("spo2_byte", "SpO₂", "G-SPO2"),
                    entry("skin_temp", "Skin temperature", "G-TEMP"),
                ]),
                CatalogueSection(title: "Sleep", isOpen: false, entries: [
                    entry("sleep_total", "Total sleep"), entry("sleep_stages", "Stages", "G-STAGE"),
                ]),
                CatalogueSection(title: "Activity", isOpen: false, entries: [
                    entry("strain", "Strain", "G-LOAD"), entry("steps", "Steps", "G-STEPS"),
                ]),
                CatalogueSection(title: "Research", isOpen: false, entries: [
                    entry("record_inspector", "Record inspector", research: true),
                ]),
            ],
            matrixSubtitle: "pick up to 8 metrics · 30 d")
    }()
}

extension MetricDetailState {
    public static let preview: MetricDetailState = {
        let r = SampleDay.receipt(.phone, .high, 6, 58, method: "ALG-010 RMSSD")
        let days = (0..<30).compactMap { LocalDay(iso: String(format: "2026-%02d-%02d", $0 < 19 ? 9 : 10,
                                                               $0 < 19 ? $0 + 12 : $0 - 18)) }
        let points = days.enumerated().map { DayPoint(day: $0.element, value: $0.offset == 11 ? nil
                                                          : 50 + 6 * sin(Double($0.offset) / 4)) }
        let ewma = days.enumerated().map { DayPoint(day: $0.element, value: 50 + 3 * sin(Double($0.offset) / 6)) }
        return MetricDetailState(
            sample: true, key: "hrv_rmssd", title: "HRV", receipt: r, view: .graph,
            number: MetricNumberSummary(median: SampleDay.value("51", "ms", r), iqr: "46–55 ms",
                                        coverage: "29 of 30 days", versusPrevious: "about the same as the 30 days before"),
            graph: MetricGraph(unit: "ms", points: points, bandLow: 43, bandHigh: 59,
                               markers: days.count > 20 ? [GraphMarker(kind: .firmware, day: days[20], label: "firmware 50.36")] : []),
            trend: MetricTrend(ewma: ewma, changeDays: days.count > 24 ? [days[24]] : []),
            methods: nil,
            about: MetricAbout(method: "RMSSD over the night's clean R-R", algorithmId: "ALG-010",
                               citation: "Task Force 1996", tier: .high))
    }()
}

extension GroupState {
    public static let preview: GroupState = {
        let strip = MethodsStripState.preview
        return GroupState(sample: true, groupId: strip.groupId, name: "Recovery", members: strip.members, dropped: [],
                          showDropped: false, agreement: strip.agreement)
    }()
}

extension MatrixState {
    public static let preview: MatrixState = {
        let metrics = [MatrixMetric(key: "hrv_rmssd", name: "HRV"), MatrixMetric(key: "sleep_total", name: "Sleep"),
                       MatrixMetric(key: "caffeine_mg", name: "Caffeine"), MatrixMetric(key: "vape_hits", name: "Vape")]
        let rho: [[Double]] = [[1, 0.42, -0.31, -0.22], [0.42, 1, -0.38, -0.1], [-0.31, -0.38, 1, 0.27],
                               [-0.22, -0.1, 0.27, 1]]
        let n = [[30, 29, 26, 9], [29, 30, 26, 9], [26, 26, 26, 9], [9, 9, 9, 9]]
        let cells = (0..<4).map { i in (0..<4).map { j in MatrixCell.make(rho: rho[i][j], n: n[i][j], qValue: 0.2) } }
        return MatrixState(sample: true, metrics: metrics, period: .days30, cells: cells)
    }()
}

extension CompareState {
    /// HRV vs caffeine, lag 0, 26 paired days (SAMPLE).
    public static let preview: CompareState = {
        let days = (0..<26).compactMap { LocalDay(iso: String(format: "2026-09-%02d", $0 + 16)) }
        let pairs: [ComparePair] = days.enumerated().map { i, d in
            // x = first metric (HRV, ms), y = second (caffeine, mg).
            let caffeineMg = 150 + 12 * Double(i % 7)
            return ComparePair(day: d, x: 55 - 0.04 * caffeineMg + sin(Double(i)), y: caffeineMg)
        }
        return CompareState(sample: true, first: MatrixMetric(key: "hrv_rmssd", name: "HRV"),
                            second: MatrixMetric(key: "caffeine_mg", name: "Caffeine"),
                            candidates: [MatrixMetric(key: "caffeine_mg", name: "Caffeine"),
                                         MatrixMetric(key: "vape_hits", name: "Vape"),
                                         MatrixMetric(key: "sleep_total", name: "Sleep")],
                            period: .days30, lagDays: 0, xUnit: "ms", yUnit: "mg", pairs: pairs,
                            cell: MatrixCell.make(rho: -0.31, n: pairs.count, qValue: 0.12))
    }()
}

extension TonightState {
    public static let preview: TonightState = {
        let est = SampleDay.receipt(.phone, .estimate, 20, 5, method: "ALG-115")
        return TonightState(
            sample: true, bedtime: SampleDay.bedtime, bedtimeNote: nil, asleepAround: SampleDay.at(22, 44),
            summaryLine: "Bed 22:30 → asleep ≈ 22:44 → up 06:40–07:10",
            need: [NeedPart(label: "your baseline need", minutes: 450, value: SampleDay.value("7 h 30", nil, est)),
                   NeedPart(label: "sleep debt", minutes: 31, value: SampleDay.value("31 min", nil, est)),
                   NeedPart(label: "nap credit", minutes: 0, value: SampleDay.value("0 min", nil, est))],
            needTotal: SampleDay.value("7 h 30", nil, est, .estimate(nil)),
            latestWake: (1...7).map { WeekdayWake(weekday: $0, time: TimeOfDay(hour: 7, minute: 10)) },
            smartWake: SmartWakeBlockState(
                toggle: ToggleState(id: "sw", title: "Smart wake", isOn: true, intent: .setSmartWake(false)),
                windowMinutes: 30, windowStart: SampleDay.at(6, 40, dayOffset: 1), windowEnd: SampleDay.latestWake,
                sentence: "Wakes you in light sleep inside the window (strap stager, live); otherwise at 07:10.",
                ringer: .notification, silentWarning: "A notification may not wake you on Silent.",
                noPlanReason: nil),
            caffeineAtBedtime: SampleDay.value("32", "mg", est, .estimate(nil)),
            caffeineSentence: "32 mg at 22:30 — under your 33",
            nightSounds: ToggleState(id: "ns", title: "Listen tonight", detail: "audio stays on the phone",
                                     isOn: false, intent: .setNightSounds(true)),
            windDown: ToggleState(id: "wd", title: "Wind-down reminder", detail: "21:30, one notification",
                                  isOn: true, intent: .setWindDown(false)))
    }()
}

extension NightState {
    public static let preview: NightState = {
        let ph = SampleDay.receipt(.phone, .high, 6, 58)
        let dial = DialState.preview(for: .woke)
        let segments: [StageSegment] = dial.arcs.compactMap { a in
            switch a.kind {
            case .deep: return StageSegment(stage: .deep, start: a.start, end: a.end)
            case .light: return StageSegment(stage: .light, start: a.start, end: a.end)
            case .rem: return StageSegment(stage: .rem, start: a.start, end: a.end)
            case .awake: return StageSegment(stage: .awake, start: a.start, end: a.end)
            default: return nil
            }
        }
        // SAMPLE confidence: most segments sure, a few REM/light ones below 0.5 so the low-confidence shading shows.
        let lowConfidence: Set<Int> = [3, 8, 13]
        let stages: [StageSegment] = segments.enumerated().map { i, s in
            var seg = s
            seg.confidence = lowConfidence.contains(i) ? 0.38 : 0.82
            return seg
        }
        let spo2 = stride(from: 0.0, to: 7.8, by: 1.0 / 3.0).map {
            LaneMark(at: SampleDay.hours(-0.97 + $0), value: 95 + ($0.truncatingRemainder(dividingBy: 2) < 1 ? 1 : 0))
        }
        return NightState(
            sample: true, day: SampleDay.day, slept: SampleDay.value("7 h 08", nil, ph),
            needed: SampleDay.value("8 h 10", nil, SampleDay.receipt(.phone, .estimate, 6, 58), .estimate(nil)),
            shortBy: "1 h 02 short", stages: stages, stageMethods: nil,
            lanes: [
                NightLane(id: "breathing", title: "Breathing events",
                          marks: [LaneMark(at: SampleDay.at(3, 40), label: "pause < 15 s"),
                                  LaneMark(at: SampleDay.at(3, 41), label: "pause < 15 s")], blankReason: nil),
                NightLane(id: "sounds", title: "Sounds", marks: [],
                          blankReason: "Not listening last night — switch on in Tonight"),
                NightLane(id: "spo2", title: "SpO₂ byte", marks: spo2, blankReason: nil),
            ],
            details: [
                LabeledValue(id: "tib", label: "Time in bed", value: SampleDay.value("7 h 50", nil, ph)),
                LabeledValue(id: "tst", label: "Total sleep", value: SampleDay.value("7 h 08", nil, ph)),
                LabeledValue(id: "sol", label: "Onset latency", value: SampleDay.value("14", "min", ph)),
                LabeledValue(id: "waso", label: "WASO", value: SampleDay.value("28", "min", ph)),
                LabeledValue(id: "reml", label: "REM latency", value: SampleDay.value("1 h 28", nil, ph)),
                LabeledValue(id: "awk", label: "Awakenings", value: SampleDay.value("2", nil, ph)),
                LabeledValue(id: "eff", label: "Efficiency", value: SampleDay.value("91", "%", ph)),
            ],
            regularity: SampleDay.value("82", "/100", ph),
            naps: [], blankReason: nil)
    }()
}

extension StrapSyncState {
    public static let preview: StrapSyncState = {
        let strap = SampleDay.receipt(.strap, .strap, 9, 40)
        return StrapSyncState(
            sample: true,
            strapRows: [
                LabeledValue(id: "bond", label: "Bond", value: SampleDay.value("bonded", nil, strap)),
                LabeledValue(id: "battery", label: "Battery", value: SampleDay.value("79", "%", strap)),
                LabeledValue(id: "firmware", label: "Firmware", value: .blank(reason: "read on connect", receipt: nil)),
                LabeledValue(id: "worn", label: "Worn", value: SampleDay.value("left wrist", nil, strap)),
                LabeledValue(id: "last", label: "Last record", value: SampleDay.value("09:40", nil, strap)),
            ],
            changeWearLocation: ActionState(id: "wear", title: "Change", intent: .changeWearLocation(.leftWrist)),
            historyLine: "up to date", historyProgress: nil,
            lastAckLine: "last chunk acked after it was stored", writeLogLine: "clock set ×1 today ›",
            unlock: ActionState(id: "unlock", title: "Turn on R22 (enable_r22_packets → 1)", intent: .openUnlock),
            unlockStatus: "off ('2') · read 09:40",
            broadcast: ToggleState(id: "broadcast", title: "HR broadcast", isOn: false, enabled: false,
                                   disabledReason: "Heart-rate sharing isn't available yet.",
                                   intent: .setBroadcast(true)),
            pcState: .online, pcLine: "PC got 3 h · 412 KB · 09:40", unsyncedLine: nil,
            pair: ActionState(id: "pair", title: "Pair PC Lab", intent: .pairPC),
            healthLines: ["Heart rate, resting HR, HRV, steps · read 09:30"])
    }()
}

extension SettingsState {
    public static let preview: SettingsState = {
        let r = SampleDay.receipt(.phone, .high, 9, 40)
        return SettingsState(
            sample: true,
            profile: [LabeledValue(id: "hrmax", label: "Max HR (measured)", value: SampleDay.value("190", "bpm", r))],
            latestWake: (1...7).map { WeekdayWake(weekday: $0, time: nil) }, wakeWindowMinutes: 30, needOverride: nil,
            schedules: [ScheduleRow(id: "meda", title: "MedA 20 mg", detail: "daily · 07:15", isSupplement: false),
                        ScheduleRow(id: "stack", title: "Morning stack", detail: "daily · 08:00", isSupplement: true)],
            drinkPresets: [DrinkPreset(name: "DrinkA", caffeineMg: 200), DrinkPreset(name: "DrinkB", caffeineMg: 160),
                           DrinkPreset(name: "Coffee", caffeineMg: 95), DrinkPreset(name: "Espresso", caffeineMg: 63),
                           DrinkPreset(name: "Tea", caffeineMg: 47)],
            quickLogSurfaces: [ToggleState(id: "dtap", title: "Double-tap the strap logs a vape hit", isOn: true,
                                           intent: .setQuickLogSurface(id: "dtap", enabled: false))],
            notificationRows: [
                LabeledValue(id: "quiet", label: "Quiet hours", value: SampleDay.value("bedtime − 30 min → wake", nil, r),
                             caption: "PLACEHOLDER — Mo sets"),
                LabeledValue(id: "cap", label: "Daily cap", value: SampleDay.value("6", nil, r),
                             caption: "PLACEHOLDER — Mo sets"),
            ],
            notificationToggles: [
                ToggleState(id: "stressSummary", title: "Body arousal summary at 5:00 PM", isOn: true,
                            intent: .setStressSummary(false)),
            ],
            notificationsArePlaceholders: true, theme: .followDay, researchRowsShown: true, droppedMethodsCount: 0,
            sampleData: true, privacyLines: ["Nothing leaves the phone except to your own PC over Tailscale."],
            export: ActionState(id: "export", title: "Export", intent: .export))
    }()
}
