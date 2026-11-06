import Foundation
import MGContext
import MGDomain
import MGStore

// WP-23a — SAMPLE mode (ARCHITECTURE §4.12, BRIEF hard rule): off by default; while on, every screen is built from the
// UX prototype's sample day (MGContext `SampleDay`: woke 06:52, bedtime 22:30, up by 07:10) moved to TODAY's date so the
// dial and the phases read right; `isSample` makes every state carry `sample: true` and every screen shows the SAMPLE
// banner. Nothing here touches the store, and AppModel refuses every write and every sync while it is on.
//
// The numbers are the prototype's (app/prototype/index.html via MGContext's TodayPreviews): resting HR 64, HRV 52 ms,
// breathing 14.8 /min (estimate), SpO₂ byte 96 (a raw count, no % sign), skin temp "in range", slept 7 h 08 of 8 h 10.
// Earlier days are a smooth deterministic wave around those values — labelled SAMPLE like everything else here, so
// Explore's graphs and bands have something to draw in the preview. None of it is Mo's.
//
// WRITTEN, NOT COMPILED.

struct SampleDayDataSource: SnapshotReading {
    let live: ContextLiveBox
    let calendar: Calendar

    var isSample: Bool { true }

    /// Whole days between the prototype's day (Sun 11 Oct 2026) and the day of `now`.
    private func shift(_ now: Date) -> Int {
        SampleDay.day.days(to: LocalDay(date: now, calendar: calendar))
    }

    /// The prototype's hh:mm moved to the day of `now` (dayOffset −1 = the evening before).
    private func t(_ h: Int, _ m: Int, _ dayOffset: Int = 0, now: Date) -> Date {
        let base = SampleDay.at(h, m, dayOffset: dayOffset)
        return calendar.date(byAdding: .day, value: shift(now), to: base) ?? base
    }

    // MARK: DayDataSource

    func contextInputs(now: Date) async throws -> ContextInputs {
        let l = await live.get()
        let wake = t(6, 52, now: now)
        let woke = now >= wake
        let detected = woke ? wake : t(6, 52, -1, now: now)
        let bed = woke ? t(22, 30, now: now) : t(22, 30, -1, now: now)
        return ContextInputs(
            now: now, calendar: calendar, detectedWake: detected, medianWake14: t(6, 55, now: now),
            latestWakeSetting: DateComponents(hour: 7, minute: 10), recommendedBedtime: bed,
            medianOnset14: t(22, 44, now: now),
            strap: StrapStatus(link: .connected, batteryPercent: 79, charging: false, offWristSince: nil,
                               wearLocation: .leftWrist, lastRecordAt: now.addingTimeInterval(-60)),
            workout: nil, nap: nil, history: nil,
            sync: SyncStatus(state: .online, pcName: "Sample PC", lastSynced: min(now, t(9, 40, now: now))),
            alerts: [], pending: [], peeksShownToday: 0, morningCheckinAnswered: false, swipeAwayStreak: [:],
            themePreference: l.settings.theme.preference(systemIsDark: l.systemIsDark))
    }

    func summary(for day: LocalDay) async throws -> DaySummary? {
        let now = Date()
        let wakeDay = LocalDay(date: t(12, 0, now: now), calendar: calendar)
        let offset = wakeDay.days(to: day)
        guard offset <= 0, offset > -90 else { return nil }
        let at = calendar.date(byAdding: .day, value: offset, to: t(6, 58, now: now)) ?? now
        var metrics = SampleCatalogue.rows.map { $0.metric(day: day, offset: offset, at: at) }
        if offset == 0 {
            // Last night's clock values and the day so far.
            let onset = t(23, 2, -1, now: now)
            let wake = t(6, 52, now: now)
            metrics.append(SampleCatalogue.unix(.sleepOnset, onset, at: at))
            metrics.append(SampleCatalogue.unix(.wakeTime, wake, at: at))
            metrics.append(SampleCatalogue.unix(.bedtimeRecommended, t(22, 30, now: now), at: at))
        }
        return DaySummary(date: day, strapId: "sample", metrics: metrics)
    }

    func events(from: Date, to: Date) async throws -> [EventRecord] {
        let now = Date()
        var out: [EventRecord] = []
        for dayOffset in [-1, 0] {
            out += SampleCatalogue.events { h, m in t(h, m, dayOffset, now: now) }
        }
        return out.filter { $0.at >= from && $0.at < to && $0.at <= now }.sorted { $0.at < $1.at }
    }

    func metricHistory(name: String, variant: String?, from: LocalDay, to: LocalDay) async throws -> [Metric] {
        guard let row = SampleCatalogue.rows.first(where: { $0.key.rawValue == name && (variant == nil || $0.variant == variant) })
        else { return [] }
        let now = Date()
        let today = LocalDay(date: now, calendar: calendar)
        var out: [Metric] = []
        var day = from
        while day <= to {
            let offset = today.days(to: day)
            if offset <= 0, offset > -90 {
                let at = calendar.date(byAdding: .day, value: offset, to: t(6, 58, now: now)) ?? now
                out.append(row.metric(day: day, offset: offset, at: at))
            }
            day = day.adding(days: 1)
        }
        return out
    }

    // MARK: SnapshotReading

    func series(for day: LocalDay) async throws -> [Series] {
        let now = Date()
        guard day == LocalDay(date: now, calendar: calendar) else { return [] }
        return [SampleCatalogue.hypnogram(onset: t(23, 2, -1, now: now), wake: t(6, 52, now: now))]
    }

    func groupMarks() async throws -> [GroupMarkEntry] { [] }

    func strapWrites(limit: Int) async throws -> [StrapWriteEntry] {
        let now = Date()
        return [StrapWriteEntry(command: 146, name: "SET_CLOCK", payloadHex: "01", priorValue: nil, readback: "ok",
                                confirmedAt: t(6, 53, now: now), result: "ok", standingConsent: true)]
    }

    func lastAck() async throws -> Date? { min(Date(), t(9, 40, now: Date())) }

    func pendingOutboxBytes() async throws -> Int? { nil }

    func workout(id: UUID?, now: Date) async throws -> EventRecord? {
        try await events(from: now.addingTimeInterval(-86400), to: now).last { $0.type == .workout }
    }

    /// No heart-rate stream in SAMPLE mode: the workout HR map is blank with the reason the presenter gives.
    func hrSamples(from: Date, to: Date) async throws -> [HRPoint] { [] }

    func metricDays(name: String, from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        try await metricHistory(name: name, variant: nil, from: from, to: to).map {
            (day: LocalDay(date: $0.at, calendar: calendar), metric: $0)
        }
    }

    /// SAMPLE: the PC is never asked for older years (tracker #7).
    func oldestDay(name: String?) async throws -> LocalDay? { nil }

    /// SAMPLE: no records listed (tracker #42).
    func profileRecords() async throws -> [EventRecord] { [] }
}

/// The sample rows. One value per day: today = the prototype's number, earlier days = a smooth wave around a centre.
enum SampleCatalogue {
    struct SampleMetricRow {
        var key: MetricKey
        var unit: String
        var tier: Tier
        var group: String?
        var variant: String
        var method: String
        var window: String
        var today: Double
        var centre: Double
        var swing: Double
        var uncertainty: Double?

        func value(offset: Int) -> Double {
            if offset == 0 { return today }
            let d = Double(offset)
            return centre + swing * sin(d * 0.9) + 0.5 * swing * sin(d * 0.37 + 1.3)
        }

        func metric(day: LocalDay, offset: Int, at: Date) -> Metric {
            let v = value(offset: offset)
            return Metric(name: key.rawValue, value: v, unit: unit, tier: tier, source: "sample", method: method,
                          window: window, computedOn: tier == .strap ? .strap : .phone, at: at,
                          note: "SAMPLE — prototype value, not yours", group: group, variant: variant,
                          producer: .ours, primary: true,
                          uncertainty: uncertainty.map { Uncertainty(low: v - $0, high: v + $0) })
        }
    }

    static let rows: [SampleMetricRow] = [
        SampleMetricRow(key: .rhr, unit: "bpm", tier: .high, group: nil, variant: "ALG-012", method: "ALG-012@1 resting-hr",
            window: "night", today: 64, centre: 62, swing: 2.5, uncertainty: nil),
        SampleMetricRow(key: .hrvRmssd, unit: "ms", tier: .high, group: "G-HRV", variant: "ALG-010",
            method: "ALG-010@1 rmssd-task-force", window: "night", today: 52, centre: 50, swing: 7, uncertainty: nil),
        SampleMetricRow(key: .hrvLnRmssd, unit: "ln_ms", tier: .high, group: "G-HRV", variant: "ALG-010",
            method: "ALG-010@1 ln-rmssd-task-force", window: "night", today: 3.95, centre: 3.9, swing: 0.14,
            uncertainty: nil),
        SampleMetricRow(key: .respRate, unit: "br_min", tier: .estimate, group: "G-RESP", variant: "ALG-121",
            method: "ALG-121@1 rsa", window: "night", today: 14.8, centre: 14.6, swing: 0.5, uncertainty: 1.1),
        SampleMetricRow(key: .spo2StrapMean, unit: "byte", tier: .strap, group: "G-SPO2", variant: "strap",
            method: "ALG-021@1 strap-byte", window: "night", today: 96, centre: 95.5, swing: 0.8, uncertainty: nil),
        SampleMetricRow(key: .skinTempDev, unit: "raw_100", tier: .relative, group: "G-TEMP", variant: "ALG-110:/100",
            method: "ALG-110@1 skin-temp-dev", window: "night", today: 0.1, centre: 0, swing: 0.25, uncertainty: nil),
        SampleMetricRow(key: .sleepTotal, unit: "min", tier: .high, group: "G-STAGE", variant: "ALG-120",
            method: "ALG-150@1 sleep-account", window: "night", today: 428, centre: 432, swing: 30, uncertainty: nil),
        SampleMetricRow(key: .sleepNeed, unit: "min", tier: .estimate, group: nil, variant: "ALG-115",
            method: "ALG-115@1 sleep-need", window: "night", today: 490, centre: 485, swing: 10, uncertainty: nil),
        SampleMetricRow(key: .sleepDebt, unit: "min", tier: .estimate, group: nil, variant: "ALG-115",
            method: "ALG-115@1 sleep-debt", window: "night", today: 62, centre: 55, swing: 25, uncertainty: nil),
        SampleMetricRow(key: .sleepPerformance, unit: "fraction", tier: .high, group: nil, variant: "ALG-150",
            method: "ALG-150@1 performance", window: "night", today: 0.87, centre: 0.88, swing: 0.05, uncertainty: nil),
        SampleMetricRow(key: .sleepEfficiency, unit: "fraction", tier: .high, group: nil, variant: "ALG-150",
            method: "ALG-150@1 efficiency", window: "night", today: 0.91, centre: 0.9, swing: 0.03, uncertainty: nil),
        SampleMetricRow(key: .strain, unit: "score_0_21", tier: .high, group: "G-LOAD", variant: "ALG-036",
            method: "ALG-036@1 strain", window: "day", today: 6.1, centre: 9, swing: 3.5, uncertainty: nil),
        SampleMetricRow(key: .steps, unit: "count", tier: .verified, group: "G-STEPS", variant: "apple",
            method: "HealthKit steps", window: "day", today: 5210, centre: 7200, swing: 2200, uncertainty: nil),
        SampleMetricRow(key: .readiness, unit: "z", tier: .estimate, group: "G-READY", variant: "ALG-101",
            method: "ALG-101@1 plews-lnrmssd", window: "morning", today: 0.4, centre: 0.1, swing: 0.6, uncertainty: nil),
        SampleMetricRow(key: .vapeHits, unit: "count", tier: .high, group: nil, variant: "ALG-069",
            method: "ALG-069@1 hits", window: "day", today: 9, centre: 16, swing: 4, uncertainty: nil),
        SampleMetricRow(key: .caffeineBedtime, unit: "mg", tier: .estimate, group: "G-CAFF", variant: "ALG-060",
            method: "ALG-060@1 caffeine-two-compartment", window: "day", today: 31, centre: 30, swing: 12,
            uncertainty: nil),
    ]

    static func unix(_ key: MetricKey, _ date: Date, at: Date) -> Metric {
        Metric(name: key.rawValue, value: date.timeIntervalSince1970, unit: "unix_s", tier: .high, source: "sample",
               method: "ALG-030@1", window: "night", computedOn: .phone, at: at,
               note: "SAMPLE — prototype value, not yours", variant: "ALG-030", producer: .ours, primary: true)
    }

    /// The prototype day's log (UX prototype `D`): vape hits, MedA 07:15, supplements 08:00, DrinkA 07:30–08:15,
    /// coffee 10:00–10:20, meals, the 17:32–18:20 gym session. Ids are derived from the time so they stay stable.
    static func events(_ t: (Int, Int) -> Date) -> [EventRecord] {
        var out: [EventRecord] = []
        func id(_ tag: String, _ d: Date) -> UUID {
            let n = Int(d.timeIntervalSince1970)
            let raw = String(n & 0xffff_ffff, radix: 16)
            let hex = String(repeating: "0", count: max(0, 8 - raw.count)) + raw
            let tagHex = String(tag.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }, radix: 16)
            let padded = String(repeating: "0", count: max(0, 12 - tagHex.count)) + tagHex
            return UUID(uuidString: "\(hex)-5a3e-4000-8000-\(padded.prefix(12))") ?? UUID()
        }
        let vapeHours: [Double] = [7.07, 7.67, 8.25, 9.03, 9.5, 11.33, 12.1, 12.75, 13.5, 14.85, 16.3, 16.83, 18.67,
                                   19.5, 20.25, 21.08, 21.9]
        for h in vapeHours {
            let at = t(Int(h), Int((h - floor(h)) * 60))
            out.append(EventRecord(id: id("vape", at), at: at, loggedAt: at, source: .manual,
                                   payload: .substance(SubstanceFields(kind: .vape,
                                                                       vape: SubstanceFields.Vape(hits: 1, trigger: .button)))))
        }
        let med = t(7, 15)
        out.append(EventRecord(id: id("med", med), at: med, loggedAt: med, source: .manual,
                               payload: .medication(MedicationFields(name: "MedA", dose: 20, doseUnit: "mg",
                                                                     status: .taken, category: .prescription,
                                                                     units: 1, unitKind: .capsule))))
        let supp = t(8, 0)
        out.append(EventRecord(id: id("supp", supp), at: supp, loggedAt: supp, source: .manual,
                               payload: .medication(MedicationFields(name: "Magnesium glycinate", dose: 200,
                                                                     doseUnit: "mg", status: .taken,
                                                                     category: .supplement))))
        for (h, m, eh, em, product, mg) in [(7, 30, 8, 15, "DrinkA", 200.0), (10, 0, 10, 20, "Coffee", 95.0)] {
            let at = t(h, m)
            out.append(EventRecord(id: id("caf", at), at: at, loggedAt: at, source: .manual,
                                   payload: .substance(SubstanceFields(kind: .caffeine, product: product, caffeineMg: mg,
                                                                       finishedAt: t(eh, em)))))
        }
        for (h, m, text) in [(8, 30, "Breakfast"), (12, 30, "Lunch"), (19, 15, "Dinner")] {
            let at = t(h, m)
            out.append(EventRecord(id: id("food", at), at: at, loggedAt: at, source: .manual,
                                   payload: .food(FoodFields(text: text))))
        }
        let gym = t(17, 32)
        out.append(EventRecord(id: id("gym", gym), at: gym, loggedAt: t(18, 21), source: .manual,
                               location: EventLocation(label: "gym"),
                               payload: .workout(WorkoutFields(end: t(18, 20), activityTypeUser: "strength"))))
        let nap = t(14, 5)
        out.append(EventRecord(id: id("nap", nap), at: nap, loggedAt: t(14, 40), source: .manual,
                               payload: .nap(NapFields(end: t(14, 31), confirmed: true, trigger: .manual, label: .nap))))
        return out
    }

    /// A plausible hypnogram for the prototype night (30-s epochs: W L D R), cycles of ~90 min. SAMPLE only.
    static func hypnogram(onset: Date, wake: Date) -> Series {
        let epochs = max(0, Int(wake.timeIntervalSince(onset) / 30))
        var state: [String?] = []
        state.reserveCapacity(epochs)
        for i in 0..<epochs {
            let minute = Double(i) / 2
            let cycle = minute.truncatingRemainder(dividingBy: 90)
            let late = minute > 300
            let s: String
            switch cycle {
            case ..<10: s = "L"
            case ..<(late ? 30 : 45): s = "D"
            case ..<70: s = "L"
            case ..<88: s = "R"
            default: s = "W"
            }
            state.append(s)
        }
        return Series(name: "hypnogram", unit: "stage", start: onset, stepS: 30,
                      values: [Double?](repeating: nil, count: epochs), state: state, group: "G-STAGE",
                      variant: "ALG-120", tier: .estimate, computedOn: .phone)
    }
}
