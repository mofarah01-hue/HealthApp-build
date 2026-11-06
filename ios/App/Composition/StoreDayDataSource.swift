import Foundation
import MGContext
import MGDomain
import MGStore

// WP-23a — `DayDataSource` over MGStore (ARCHITECTURE §4.2), plus the few extra reads the snapshot builder needs
// (`SnapshotReading`). What the store can't know (strap link, sync state, running sessions, settings, the question
// ledger) arrives through `ContextLiveBox`, which AppModel keeps current.
//
// WRITTEN, NOT COMPILED.

/// The live half of `ContextInputs`, pushed by AppModel (main actor) and read by the data source (any actor).
struct ContextLive: Sendable {
    var strap: StrapStatus = .notPaired
    var history: HistoryProgress?
    var sync: SyncStatus = .notSetUp
    var settings = AppSettings()
    var ledger = PeekLedger()
    var sessions = LiveSessions()
    /// The system appearance, for Settings › Theme › Follow iOS.
    var systemIsDark = false
    var alerts: [AlertInfo] = []
}

actor ContextLiveBox {
    private(set) var value = ContextLive()

    func set(_ new: ContextLive) { value = new }
    func get() -> ContextLive { value }
    var sampleData: Bool { value.settings.sampleData }
}

/// Reads beyond `DayDataSource` (series, marks, strap write log, ack journal, outbox) — the snapshot builder takes this.
protocol SnapshotReading: DayDataSource {
    func series(for day: LocalDay) async throws -> [Series]
    func groupMarks() async throws -> [GroupMarkEntry]
    func strapWrites(limit: Int) async throws -> [StrapWriteEntry]
    func lastAck() async throws -> Date?
    func pendingOutboxBytes() async throws -> Int?
    /// One workout event: by id, or the latest within 30 days (`id` nil); nil = none.
    func workout(id: UUID?, now: Date) async throws -> EventRecord?
    func hrSamples(from: Date, to: Date) async throws -> [HRPoint]
    /// One metric name across days with the day each row belongs to (D13), ordered by day.
    func metricDays(name: String, from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)]
    /// R7 / T23: every metric row of every name in [from, to], imports included (Model status).
    func metricsAllNames(from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)]
    /// Wave 2: the newest row of every (name, variant, computed_on) in [from, to], imports included
    /// (AppModel+Outputs.swift; SAMPLE: the sample day's rows).
    func latestMetrics(from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)]
    /// Wave 2: stored PC results from `from` on, newest first, leaving out `excluding`; plus unreadable rows.
    func labResults(from: LocalDay, excluding: [String]) async throws -> ([LabResult], [String])
    /// Tracker #7: the oldest day with a stored row of `name` (nil = of any metric); nil = none. SAMPLE: nil.
    func oldestDay(name: String?) async throws -> LocalDay?
    /// Tracker #42: every health record and scan event (injuries, body composition) for Settings › Profile. SAMPLE: [].
    func profileRecords() async throws -> [EventRecord]
}

extension SnapshotReading {
    /// The sample source (and anything else without a single-read path): one read per known metric key.
    func metricsAllNames(from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        var out: [(day: LocalDay, metric: Metric)] = []
        for key in MetricKey.allCases { out += try await metricDays(name: key.rawValue, from: from, to: to) }
        return out
    }
}

struct StoreDayDataSource: SnapshotReading {
    let store: MGStore
    let live: ContextLiveBox
    let calendar: Calendar

    var isSample: Bool { false }

    // MARK: DayDataSource

    func contextInputs(now: Date) async throws -> ContextInputs {
        let l = await live.get()
        let today = LocalDay(date: now, calendar: calendar)

        // Wake / onset history (ALG-030 metrics, unix seconds; D13 day = wake day).
        let wakes = try await instants(named: MetricKey.wakeTime.rawValue, from: today.adding(days: -15), to: today)
        let onsets = try await instants(named: MetricKey.sleepOnset.rawValue, from: today.adding(days: -15), to: today)
        let detectedWake = wakes.last(where: { $0 <= now && now.timeIntervalSince($0) < 36 * 3600 })
        let medianWake = ContextMath.medianTimeOfDay(wakes.filter { $0 < calendar.startOfDay(for: now) }.suffix(14),
                                                     calendar: calendar, onDayOf: now)
        let medianOnset = ContextMath.medianTimeOfDay(onsets.suffix(14), calendar: calendar, onDayOf: now)
        let bedtimes = try await instants(named: MetricKey.bedtimeRecommended.rawValue, from: today.adding(days: -1),
                                          to: today.adding(days: 1))
        let recommended = bedtimes.last(where: { $0 > now.addingTimeInterval(-18 * 3600)
            && $0 < now.addingTimeInterval(30 * 3600) })

        let latest = ContextMath.latestWakeSetting(l.settings.latestWake, now: now, detectedWake: detectedWake,
                                                   calendar: calendar)

        // Sessions: a running manual workout, else the latest one that ended within 2 h.
        var workout: WorkoutSession?
        if let w = l.sessions.workout {
            workout = WorkoutSession(id: w.id, start: w.start, end: nil, trigger: .manual, confirmed: true,
                                     activityType: w.activityType, place: w.place)
        } else if let e = try await store.events(from: now.addingTimeInterval(-6 * 3600), to: now,
                                                 types: [.workout]).last,
                  case .workout(let f) = e.payload, f.end <= now,
                  now.timeIntervalSince(f.end) < ContextEngine.workoutJustEndedFor {
            let detected = e.source == .detected
            let answer = l.ledger.workoutAnswers[e.id.uuidString.lowercased()]
            workout = WorkoutSession(id: e.id, start: e.at, end: f.end, trigger: detected ? .detected : .manual,
                                     confirmed: detected ? answer : true,
                                     activityType: f.activityTypeUser ?? f.activityTypeAuto, place: e.location?.label)
        }
        var nap: NapSession?
        if let n = l.sessions.nap {
            nap = NapSession(start: n.start, plannedMinutes: n.plannedMinutes, end: nil, trigger: .manual)
        }

        let pending = try await pendingQuestions(now: now, live: l)
        let checkinDone = l.ledger.checkinDone
            && (l.ledger.checkinWake.map { now.timeIntervalSince($0) < 20 * 3600 } ?? false)

        return ContextInputs(
            now: now, calendar: calendar, detectedWake: detectedWake, medianWake14: medianWake,
            latestWakeSetting: latest, recommendedBedtime: recommended, medianOnset14: medianOnset,
            strap: l.strap, workout: workout, nap: nap, history: l.history, sync: l.sync, alerts: l.alerts,
            pending: pending, peeksShownToday: l.ledger.shownCount(day: today), morningCheckinAnswered: checkinDone,
            swipeAwayStreak: l.ledger.streakByKind,
            themePreference: l.settings.theme.preference(systemIsDark: l.systemIsDark))
    }

    /// Imported history (`ImportedHistory`) included: presenters show it where the app has no value of its own.
    func summary(for day: LocalDay) async throws -> DaySummary? {
        let metrics = try await store.metrics(on: day, includingImported: true)
        guard !metrics.isEmpty else { return nil }
        let strap = try await store.primaryStrapId()?.raw ?? "unknown"
        return DaySummary(date: day, strapId: strap, metrics: metrics)
    }

    func events(from: Date, to: Date) async throws -> [EventRecord] {
        // MGStore's range is closed; the protocol's is [from, to).
        try await store.events(from: from, to: to).filter { $0.at < to }
    }

    func metricHistory(name: String, variant: String?, from: LocalDay, to: LocalDay) async throws -> [Metric] {
        try await store.metrics(named: name, from: from, to: to, includingImported: true)
            .map(\.metric)
            .filter { variant == nil || $0.variant == variant }
    }

    // MARK: SnapshotReading

    func series(for day: LocalDay) async throws -> [Series] { try await store.series(on: day) }

    func groupMarks() async throws -> [GroupMarkEntry] { try await store.groupMarks() }

    func strapWrites(limit: Int) async throws -> [StrapWriteEntry] { try await store.strapWriteEntries(limit: limit) }

    func lastAck() async throws -> Date? {
        try await store.historyJournal(limit: 50).compactMap(\.ackedAt).max()
    }

    func pendingOutboxBytes() async throws -> Int? {
        let drops = try await store.pending()
        guard !drops.isEmpty else { return nil }
        return drops.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.bytes } }
    }

    func workout(id: UUID?, now: Date) async throws -> EventRecord? {
        if let id {
            let e = try await store.event(id: id)
            return e?.type == .workout && e?.removed == false ? e : nil
        }
        return try await store.events(from: now.addingTimeInterval(-30 * 86400), to: now, types: [.workout]).last
    }

    func hrSamples(from: Date, to: Date) async throws -> [HRPoint] {
        try await store.hrSamples(from: Int64(from.timeIntervalSince1970), to: Int64(to.timeIntervalSince1970))
    }

    /// Imported history included (trends); callers that compute from the rows filter it out (`ImportedHistory`).
    func metricDays(name: String, from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        try await store.metrics(named: name, from: from, to: to, includingImported: true)
    }

    func metricsAllNames(from: LocalDay, to: LocalDay) async throws -> [(day: LocalDay, metric: Metric)] {
        try await store.metricsAllNames(from: from, to: to)
    }

    func oldestDay(name: String?) async throws -> LocalDay? { try await store.oldestMetricDay(named: name) }

    func profileRecords() async throws -> [EventRecord] { try await store.events(ofTypes: [.record, .scan]) }

    // MARK: Helpers

    /// Values of a unix-seconds metric (wake_time, sleep_onset, bedtime_recommended), one per day (primary member,
    /// else the first stored), oldest first.
    /// One instant per night: own row, else WHOOP's / Apple's imported one (MGContext NightInstants; W10, 2026-10-11).
    private func instants(named name: String, from: LocalDay, to: LocalDay) async throws -> [Date] {
        NightInstants.instants(try await store.metrics(named: name, from: from, to: to, includingImported: true))
    }

    /// The questions waiting (UX §5), built with MGContext's factories so the timings live in one place.
    private func pendingQuestions(now: Date, live l: ContextLive) async throws -> [PendingQuestion] {
        var out: [PendingQuestion] = []
        let ledger = l.ledger

        // Wear location after WRIST_ON (UX §4.2 "Strap back on").
        if let on = ledger.wristOnAt, now.timeIntervalSince(on) < 3600 {
            out.append(.wearLocation(wristOnAt: on, previous: ledger.wearBefore,
                                     occurrence: ledger.answeredCount(prefix: "wear:")))
        }
        let recent = try await store.events(from: now.addingTimeInterval(-6 * 3600), to: now,
                                            types: [.workout, .nap, .food])
        for e in recent {
            switch e.payload {
            case .workout(let f) where e.source == .detected:
                // Kept while step 2 (type + place) is open; the ledger's answered ids end it (or the 2 h expiry).
                out.append(.workoutConfirm(start: e.at, end: f.end, occurrence: ledger.answeredCount(prefix: "workout:")))
            case .nap(let f) where f.trigger == .detected || e.source == .detected:
                // Unanswered, or labelled nap / dozed with no groggy ↔ refreshed rating yet (step 2).
                let stepTwoOpen = f.ratingWake == nil && (f.label == .nap || f.label == .dozed)
                if f.confirmed == nil || stepTwoOpen {
                    out.append(.nap(start: e.at, end: f.end, occurrence: ledger.answeredCount(prefix: "nap:")))
                }
            case .food:
                for minutes in [60, 120] {
                    out.append(.mealCheckin(mealAt: e.at, minutesAfter: minutes,
                                            occurrence: ledger.answeredCount(prefix: "meal")))
                }
            default:
                break
            }
        }
        // WP-22 suggestions not (yet) stored as events: asked about unless a stored event already covers them.
        func covered(_ s: PeekLedger.SuggestionSpan, _ type: EventType) -> Bool {
            recent.contains { e in
                guard e.type == type else { return false }
                let end: Date
                switch e.payload {
                case .workout(let f): end = f.end
                case .nap(let f): end = f.end
                default: return false
                }
                return e.at < s.end && end > s.start
            }
        }
        for s in ledger.suggestedWorkouts where !covered(s, .workout) {
            out.append(.workoutConfirm(start: s.start, end: s.end, occurrence: ledger.answeredCount(prefix: "workout:")))
        }
        for s in ledger.suggestedNaps where !covered(s, .nap) {
            out.append(.nap(start: s.start, end: s.end, occurrence: ledger.answeredCount(prefix: "nap:")))
        }
        for end in ledger.napEnds where now.timeIntervalSince(end) < 2 * 3600 {
            out.append(.napPlus30(napEnd: end, occurrence: ledger.answeredCount(prefix: "nap30:")))
        }
        // The engine owns the morning check-in; a copy here only carries a swipe-away (MGContext doc).
        if let wake = ledger.checkinWake, !ledger.checkinDone,
           let deferredAt = ledger.deferred[PendingQuestion.morningCheckin(wake: wake).id] {
            var q = PendingQuestion.morningCheckin(wake: wake)
            q.deferredAt = deferredAt
            out.append(q)
        }

        return out.compactMap { q in
            guard !ledger.isAnswered(q.id), now < q.expiresAt else { return nil }
            var held = q
            held.deferredAt = ledger.deferred[q.id] ?? q.deferredAt
            return held
        }
    }
}

/// Small time-of-day arithmetic for the context inputs.
enum ContextMath {
    /// Median time of day of `dates`, as an instant on the day of `onDayOf`. Times are taken relative to noon so a
    /// spread around midnight (sleep onsets 22:30–00:40) has a meaningful median. nil when empty.
    static func medianTimeOfDay<S: Sequence>(_ dates: S, calendar: Calendar, onDayOf day: Date) -> Date?
        where S.Element == Date {
        let secs: [Double] = dates.map { d in
            let t = TimeOfDay(of: d, calendar: calendar)
            let s = Double(t.secondsIntoDay)
            return s >= 12 * 3600 ? s - 12 * 3600 : s + 12 * 3600      // seconds after noon
        }
        guard !secs.isEmpty else { return nil }
        let sorted = secs.sorted()
        let n = sorted.count
        let mid = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        let seconds = Int(mid.rounded()) + 12 * 3600
        let tod = seconds % (24 * 3600)
        let t = TimeOfDay(hour: tod / 3600, minute: (tod % 3600) / 60, second: tod % 60)
        return PhaseClock.instant(t, onDayOf: day, calendar: calendar)
    }

    /// "Must be up by" for the coming morning (BRIEF WP-06 row: the caller picks the weekday). The coming morning is
    /// today's while Mo has not woken yet today and it is before noon, otherwise tomorrow's.
    static func latestWakeSetting(_ table: [Int: TimeOfDay], now: Date, detectedWake: Date?,
                                  calendar: Calendar) -> DateComponents? {
        let hour = calendar.component(.hour, from: now)
        let wokeToday = detectedWake.map { calendar.isDate($0, inSameDayAs: now) && $0 <= now } ?? false
        let morning = (hour < 12 && !wokeToday) ? now : (calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        let weekday = calendar.component(.weekday, from: morning)
        guard let t = table[weekday] else { return nil }
        return DateComponents(hour: t.hour, minute: t.minute)
    }

    /// L as an instant: the next occurrence of the coming morning's "must be up by" after `bedtime`.
    static func latestWakeInstant(_ table: [Int: TimeOfDay], after bedtime: Date, calendar: Calendar) -> Date? {
        let next = calendar.date(byAdding: .day, value: 1, to: bedtime) ?? bedtime
        for candidate in [bedtime, next] {
            let weekday = calendar.component(.weekday, from: candidate)
            guard let t = table[weekday] else { continue }
            let at = PhaseClock.instant(t, onDayOf: candidate, calendar: calendar)
            if at > bedtime { return at }
        }
        return nil
    }
}
