import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSignal

// WP-23a — the live side: the last minutes of beats from the strap (`StrapLinking.liveBeats`, ~1 Hz), turned into the
// Live tab's inputs and the Breathe / HRV-check results. Every number comes from MGSignal (ALG-004 artefacts, ALG-010
// RMSSD, ALG-104 coherence, ALG-121 breathing rate, ALG-106 zones); the presenters only word and format them
// (main's split, 2026-10-11 03:58). Missing input → a blank metric carrying the reason (R6).
//
// WRITTEN, NOT COMPILED.

/// One R-R interval with the time its beat ended.
struct TimedRR: Equatable, Sendable {
    var at: Date
    var rrMs: Double
}

/// The last 10 minutes of live beats, plus the HR trace of a running workout.
struct LiveBeatBuffer {
    static let keep: TimeInterval = 600
    /// Nothing for this long = nothing streaming (the Live tab blanks with the reason).
    static let staleAfter: TimeInterval = 15

    private(set) var rr: [TimedRR] = []
    private(set) var hr: [(at: Date, bpm: Double)] = []
    /// A running workout's HR, one value per 5 s (UX §6 HR map), oldest first.
    private(set) var workoutTrace: [(at: Date, bpm: Double)] = []
    private var workoutStart: Date?

    var lastBeatAt: Date? {
        switch (rr.last?.at, hr.last?.at) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    mutating func append(_ beat: LiveBeat) {
        // A beat's R-R list covers the second before `at`: the last interval ends at `at`, earlier ones before it.
        var end = beat.at
        var timed: [TimedRR] = []
        for ms in beat.rrMs.reversed() where ms.isFinite && ms > 0 {
            timed.append(TimedRR(at: end, rrMs: ms))
            end = end.addingTimeInterval(-ms / 1000)
        }
        rr.append(contentsOf: timed.reversed())
        if let bpm = beat.bpm, bpm.isFinite, bpm > 0 {
            hr.append((beat.at, bpm))
            if let start = workoutStart, beat.at >= start,
               (workoutTrace.last.map { beat.at.timeIntervalSince($0.at) >= 5 } ?? true) {
                workoutTrace.append((beat.at, bpm))
            }
        }
        let cutoff = beat.at.addingTimeInterval(-Self.keep)
        rr.removeAll { $0.at < cutoff }
        hr.removeAll { $0.at < cutoff }
        updateHRV(now: beat.at)
    }

    // MARK: 0.6.0.12 — live RMSSD in judged 5-minute windows (MGSignal LiveHRV)

    /// Today's finished 5-minute windows (each judged once, when it ends and its beats are still held). Only filled while the
    /// app receives beats or seeds them; a window that ended while the app was not running is not reconstructed here.
    private(set) var hrvTracker = LiveHRV.Tracker()

    private var hrvBeats: [LiveHRV.Beat] { rr.map { LiveHRV.Beat(at: $0.at, ms: $0.rrMs) } }

    /// Judges every 5-minute window that has just finished. A window that began before the oldest beat held is skipped
    /// (not judged on part of its beats). A running workout makes its windows grey ("movement or a workout").
    mutating func updateHRV(now: Date, calendar: Calendar = .current) {
        guard let first = rr.first else { return }
        let bufferStart = first.at.addingTimeInterval(-first.rrMs / 1000)
        hrvTracker.update(beats: hrvBeats, now: now, dayStart: calendar.startOfDay(for: now), bufferStart: bufferStart,
                          moving: workoutStart != nil)
    }

    mutating func startWorkout(at start: Date) {
        workoutStart = start
        workoutTrace = hr.filter { $0.at >= start }
    }

    mutating func endWorkout() {
        workoutStart = nil
        workoutTrace = []
    }

    /// #35: the Live tab opens full. Stored HR / R-R of the last `keep` seconds (one bounded read, `AppModel.seedLive`)
    /// go under the live beats already held — LiveSeed's rules: no second twice, heart order kept, nothing outside the
    /// window — so the charts, RMSSD and the tachogram start filled and live beats continue the same series. A running
    /// workout's 5-s trace is rebuilt from stored HR since its start too (`storedHR` reaches back that far).
    mutating func seed(storedHR: [HRPoint], storedRR: [RRPoint], now: Date) {
        let merged = LiveSeed.merge(bufferHR: hr.map { LiveSeed.Point(at: $0.at, value: $0.bpm) },
                                    bufferRR: rr.map { LiveSeed.Point(at: $0.at, value: $0.rrMs) },
                                    storedHR: storedHR, storedRR: storedRR, now: now, keep: Self.keep)
        if let start = workoutStart {
            var seen = Set<Int64>()
            var points: [LiveSeed.Point] = []
            for row in storedHR where row.bpm.isFinite && row.bpm > 0 && seen.insert(row.ts).inserted {
                let at = Date(timeIntervalSince1970: TimeInterval(row.ts))
                if at >= start && at <= now { points.append(LiveSeed.Point(at: at, value: row.bpm)) }
            }
            points += (workoutTrace + hr.filter { $0.at >= start }).map { LiveSeed.Point(at: $0.at, value: $0.bpm) }
            workoutTrace = LiveSeed.thin(points, spacing: 5).map { (at: $0.at, bpm: $0.value) }
        }
        hr = merged.hr.map { (at: $0.at, bpm: $0.value) }
        rr = merged.rr.map { TimedRR(at: $0.at, rrMs: $0.value) }
        updateHRV(now: now)
    }

    /// The Live tab's HR line: the last `window` seconds, oldest first (#35). Wave W11: when `plan` shows the stored
    /// stretch, that stretch instead.
    func hrTrace(now: Date, window: TimeInterval, plan: LiveBackfill.Plan? = nil) -> [LiveHRPoint] {
        if let plan, plan.usesStoredTail, let tail = storedTail {
            return tail.hr.map { LiveHRPoint(at: $0.at, bpm: $0.bpm) }
        }
        let from = now.addingTimeInterval(-window)
        return hr.filter { $0.at >= from && $0.at <= now }.map { LiveHRPoint(at: $0.at, bpm: $0.bpm) }
    }

    // MARK: Wave W11 — back-fill from the newest stored data (MGContext LiveBackfill)

    /// The newest stored stretch (HR and R-R in heart order, one value per second) when the minutes before now hold
    /// nothing stored; `end` = its newest second. nil when the window before now has stored data.
    private(set) var storedTail: (hr: [(at: Date, bpm: Double)], rr: [TimedRR], end: Date)?

    mutating func setStoredTail(hr storedHR: [HRPoint], rr storedRR: [RRPoint], end: Date, window: TimeInterval) {
        let m = LiveSeed.merge(bufferHR: [], bufferRR: [], storedHR: storedHR, storedRR: storedRR, now: end, keep: window)
        guard !m.hr.isEmpty else {
            storedTail = nil
            return
        }
        let tailHR: [(at: Date, bpm: Double)] = m.hr.map { p in (at: p.at, bpm: p.value) }
        let tailRR: [TimedRR] = m.rr.map { p in TimedRR(at: p.at, rrMs: p.value) }
        storedTail = (hr: tailHR, rr: tailRR, end: end)
    }

    mutating func clearStoredTail() { storedTail = nil }

    func backfillPlan(now: Date, window: TimeInterval, calendar: Calendar) -> LiveBackfill.Plan {
        let from = now.addingTimeInterval(-window)
        let n = hr.filter { $0.at >= from && $0.at <= now }.count
        return LiveBackfill.plan(now: now, window: window, pointsInWindow: n, newestStored: storedTail?.end,
                                 calendar: calendar)
    }

    func rrSince(_ since: Date) -> [TimedRR] { rr.filter { $0.at >= since } }
    func hrSince(_ since: Date) -> [Double] { hr.filter { $0.at >= since }.map(\.bpm) }

    /// The Live tab's inputs (UX §6), or nil when nothing streams.
    func liveInput(now: Date, workout: LiveWorkoutInput?) -> LiveInput? {
        guard let last = lastBeatAt, now.timeIntervalSince(last) < Self.staleAfter else { return nil }
        let lastHR = hr.last

        // Tachogram: last 60 s, ALG-004 classified over the last 5 min so the 91-beat window has context. Wave W11: the
        // stored stretch's beats when the HR line shows it (too few live beats, nothing stored before now).
        let tail = backfillPlan(now: now, window: 300, calendar: .current).usesStoredTail ? storedTail : nil
        let five = tail?.rr ?? rrSince(now.addingTimeInterval(-300))
        let flags = ALG004.classify(rrMs: five.map(\.rrMs))
        let minuteAgo = (tail?.end ?? now).addingTimeInterval(-60)
        var points: [TachogramPoint] = []
        var clean: [Double] = []
        for (i, b) in five.enumerated() where b.at >= minuteAgo {
            let artefact = i < flags.count && flags[i] != ArtefactFlag.ok.rawValue
            points.append(TachogramPoint(at: b.at, rrMs: b.rrMs, artefact: artefact))
            if !artefact { clean.append(b.rrMs) }
        }
        let median = clean.isEmpty ? nil : SignalMath.median(clean)
        // 0.6.0.12: the RMSSD tile rests on judged 5-minute windows (>= 20 clean successive intervals, >= 80 % covered, no pair
        // across a gap > 3 s, no overlapping beats), not on 3 beats. The metric below keeps its old shape for other readers.
        let latestWindow = LiveHRV.evaluate(beats: five.map { LiveHRV.Beat(at: $0.at, ms: $0.rrMs) },
                                            windowEnd: tail?.end ?? now, moving: workoutStart != nil)
        let hrv = LiveHRVReading(latest: latestWindow, today: hrvTracker.windows, source: tail == nil ? "live" : "stored")

        var input = LiveInput(heartRate: lastHR?.bpm, heartRateAt: lastHR?.at,
                         beatInterval: rr.last.map { $0.rrMs / 1000 },
                         rmssd5min: Self.rmssd(latestWindow, at: now, window: tail == nil ? "live_5min" : "stored_5min"),
                         autonomicLoad: ALG054.spec.blank(
                            "Needs your hour-by-hour baseline from stored days (ALG-054); not computed live yet.",
                            at: now),
                         // Bug 3: beats carry no pulse samples; AppModel.liveInput() fills the wave from live raw optical.
                         pulseWave: [], pulseHz: nil, pulseQuality: nil, rr: points, rrMedianMs: median,
                         fiftyHzFlag: nil, workout: workout)
        input.hrv = hrv
        return input
    }

    /// ALG-010 RMSSD of one judged 5-minute window (MGSignal `LiveHRV`). Blank with the window's reason unless the window
    /// is ideal; before 0.6.0.12 this needed only 3 beats (`ALG010.minBeats`) and flashed a number from a few seconds.
    static func rmssd(_ w: LiveHRVWindow, at: Date, window: String = "live_5min") -> Metric {
        var spec = ALG010.rmssdSpec
        spec.window = window
        guard w.ideal, let v = w.rmssd else {
            return spec.blank("Needs a clean 5-minute window: " + (w.why?.text ?? "not enough beats") + ".", at: at)
        }
        return spec.metric(.success(v), at: at)
    }

    /// Zones and the 5-s HR trace of a running workout (UX §6 Workout mode; ALG-106).
    func workoutInput(_ w: LiveSessions.Workout, profile: Profile, now: Date, calendar: Calendar) -> LiveWorkoutInput {
        let session = WorkoutSession(id: w.id, start: w.start, end: nil, trigger: .manual, confirmed: true,
                                     activityType: w.activityType, place: w.place)
        let zones = WorkoutZones.make(profile: profile, now: now, calendar: calendar)
        var minutes: [Double] = []
        if let z = zones.edges {
            let ts = workoutTrace.map { Int($0.at.timeIntervalSince1970) }
            if case .success(let t) = ALG106.timeInZones(ts: ts, bpm: workoutTrace.map(\.bpm), floor: z.floor,
                                                         edges: z.edges) {
                minutes = t.minutes
            }
        }
        var windows = w.windows
        if var open = windows.last, open.end <= open.start {
            open.end = now
            windows[windows.count - 1] = open
        }
        return LiveWorkoutInput(session: session, hrTrace: workoutTrace.map(\.bpm), zoneMinutes: minutes,
                                zoneEdgesBpm: zones.edges?.edges, zoneBasis: zones.basis, windows: windows,
                                breathing: GuidedMath.respSpec(window: "workout_1min").blank(
                                    "Shown only where two breathing estimators agree (APP-031); one runs live today.",
                                    at: now),
                                strain: [], setsDone: w.setsDone, lastSetAt: w.lastSetAt)
    }
}

/// HRmax and zone edges for Workout mode and Workout detail (ALG-106: measured max wins, else Tanaka; T82: resting HR makes them %HRR).
enum WorkoutZones {
    struct Result {
        var edges: ALG106.ZoneEdges?
        var basis: String?
        var hrmax: Double?
    }

    static func make(profile: Profile, now: Date, calendar: Calendar) -> Result {
        let age = profile.birthDate.flatMap { b -> Double? in
            let start = b.start(in: calendar.timeZone)
            let years = calendar.dateComponents([.year], from: start, to: now).year
            return years.map(Double.init)
        }
        let z = ALG106.livingZones(age: age, profileMeasured: profile.hrMaxMeasured, rhr: profile.hrRestBaseline)
        return Result(edges: z.edges, basis: z.basis, hrmax: z.hrmax)
    }
}

// MARK: - Guided flows (WP-29: Breathe, HRV check)

/// A Breathe session (APP-024). R-R is collected from the live buffer while it runs.
struct BreatheSession: Equatable, Sendable {
    var phase: BreatheState.Phase = .ready
    var perMinute: Double = BreatheState.defaultBreathsPerMinute
    var minutes: Int = BreatheState.defaultMinutes
    var startedAt: Date?
    var endsAt: Date?
    var result: BreatheMeasured?
}

/// An HRV spot check (APP-025).
struct HRVCheckSession: Equatable, Sendable {
    var phase: HRVCheckState.Phase = .ready
    var minutes: Int = 3
    var startedAt: Date?
    var endsAt: Date?
    var blockedReason: String?
    var result: HRVMeasured?
}

enum GuidedMath {
    static let coherenceCitation = "McCraty R, Zayas MA. Front Psychol 2014;5:1090"

    static func respSpec(window: String) -> MetricSpec {
        MetricSpec(key: .respRate, unit: "br_min", group: "G-RESP", variant: "ALG-121", method: "ALG-121@1 rsa",
                   tier: .estimate, source: "rr", window: window, citation: ALG121.citation)
    }

    /// ALG-104 coherence as a metric-shaped value (no registry name: a live readout, never stored).
    static func coherenceMetric(_ c: Computed<ALG104.Coherence>, at: Date) -> Metric {
        switch c {
        case .success(let v) where v.ratio.isFinite:
            return Metric(name: "coherence", value: v.ratio, unit: "ratio", tier: .estimate, source: "rr",
                          method: "ALG-104@1 coherence-ratio", citation: coherenceCitation, window: "session",
                          computedOn: .phone, at: at, producer: .ours)
        case .success:
            return blankCoherence("the coherence ratio is not finite", at: at)
        case .failure(let m):
            return blankCoherence(m.reason, at: at)
        }
    }

    private static func blankCoherence(_ reason: String, at: Date) -> Metric {
        var m = Metric.blank(name: "coherence", unit: "ratio", tier: .estimate, source: "rr", computedOn: .phone, at: at,
                             reason: reason, group: nil, variant: "ALG-104")
        m.method = "ALG-104@1 coherence-ratio"
        m.citation = coherenceCitation
        return m
    }

    static func meanHR(_ bpm: [Double], at: Date) -> Metric? {
        var spec = ALG012.hrAvgSpec
        spec.window = "session"
        guard !bpm.isEmpty else { return nil }
        return spec.metric(.success(SignalMath.mean(bpm)), at: at)
    }

    /// Breathe result: ALG-104 coherence + ALG-010 RMSSD + ALG-121 rate against the pace (BRIEF WP-29 row).
    static func breathe(rr: [Double], hr: [Double], startedAt: Date, now: Date, endedEarly: Bool,
                        strapConnected: Bool) -> BreatheMeasured {
        let corrected = ALG004.correct(rrMs: rr).rrMs
        let coherence: Metric = strapConnected || !rr.isEmpty
            ? coherenceMetric(ALG104.coherence(rrMs: corrected), at: now)
            : blankCoherence("Strap not connected — the pacer ran without heart data.", at: now)
        var rmssdSpec = ALG010.rmssdSpec
        rmssdSpec.window = "session"
        let rmssd = rr.isEmpty ? nil : rmssdSpec.metric(ALG010.time(rrMs: corrected).map(\.rmssd), at: now)
        let resp = rr.isEmpty ? nil : respSpec(window: "session").metric(ALG121.estimate(rrMs: corrected).map(\.brPerMin),
                                                                          at: now)
        return BreatheMeasured(coherence: coherence, usualCoherence: nil,
                               peakHz: ALG104.coherence(rrMs: corrected).value?.peakHz,
                               meanHR: meanHR(hr, at: now), rmssd: rmssd, respRate: resp,
                               secondsPaced: max(0, now.timeIntervalSince(startedAt)), endedEarly: endedEarly,
                               saved: false)
    }

    /// The HRV check's live gate (ALG-004 B: ≥ 60 s of beats and ≤ 5 % flagged); nil = too few beats to judge.
    static func gate(rr: [Double]) -> (beats: Int, flagged: Int, seconds: Double, passing: Bool?) {
        let flags = ALG004.classify(rrMs: rr)
        let flagged = flags.filter { $0 != ArtefactFlag.ok.rawValue }.count
        let seconds = rr.reduce(0, +) / 1000
        guard rr.count >= ALG104.minBeats else { return (rr.count, flagged, seconds, nil) }
        let fraction = rr.isEmpty ? 0 : Double(flagged) / Double(rr.count)
        let passing = seconds >= ALG104.minDurationSeconds && fraction <= ALG004.windowMaxArtefactFraction
        return (rr.count, flagged, seconds, passing)
    }

    /// HRV check result: ALG-010 on the ALG-004-corrected beats; a failed gate blanks the values with the reason.
    static func hrvCheck(rr: [Double], hr: [Double], now: Date) -> HRVMeasured {
        let g = gate(rr: rr)
        var rmssdSpec = ALG010.rmssdSpec
        rmssdSpec.window = "spot"
        var lnSpec = ALG010.lnRmssdSpec
        lnSpec.window = "spot"
        var sdnnSpec = ALG010.sdnnSpec
        sdnnSpec.window = "spot"
        guard g.passing == true else {
            let pct = g.beats == 0 ? 0 : Int((Double(g.flagged) / Double(g.beats) * 100).rounded())
            let reason = g.seconds < ALG104.minDurationSeconds
                ? "Needs at least 60 s of beats (have \(Int(g.seconds)) s)."
                : "\(pct) % of beats were noisy; nothing reliable."
            return HRVMeasured(rmssd: rmssdSpec.blank(reason, at: now), lnRmssd: lnSpec.blank(reason, at: now),
                               coherence: coherenceMetric(.missing(reason), at: now), meanHR: meanHR(hr, at: now),
                               sdnn: sdnnSpec.blank(reason, at: now), beatsUsed: 0, secondsMeasured: g.seconds,
                               saved: false)
        }
        let corrected = ALG004.correct(rrMs: rr).rrMs
        let time = ALG010.time(rrMs: corrected)
        return HRVMeasured(rmssd: rmssdSpec.metric(time.map(\.rmssd), at: now),
                           lnRmssd: lnSpec.metric(time.map(\.lnRmssd), at: now),
                           coherence: coherenceMetric(ALG104.coherence(rrMs: corrected), at: now),
                           meanHR: meanHR(hr, at: now), sdnn: sdnnSpec.metric(time.map(\.sdnn), at: now),
                           beatsUsed: corrected.count, secondsMeasured: g.seconds, saved: false)
    }
}
