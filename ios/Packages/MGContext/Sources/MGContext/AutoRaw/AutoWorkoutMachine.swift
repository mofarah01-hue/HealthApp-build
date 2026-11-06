import Foundation

// r9q (Oct 17 2026, D-LOAD-WALK-2, D-AUTO-WORKOUT-1): when a workout is likely the raw PPG (R20) and the 100 Hz motion
// (R21) switch on by themselves, the phone asks Mo "Workout? Yes / No", his answer trains the detector, and when the
// workout ends, or he says No, the streams go back to what he saved. This file is the pure state machine and the settings
// it keeps; the app (AppModel+AutoWorkout) feeds it and carries out the actions. Nothing here sends anything.

public struct WorkoutLabel: Codable, Equatable, Sendable {
    public var askedAt: Date
    public var answeredAt: Date
    public var features: WorkoutFeatures
    public var workout: Bool

    public init(askedAt: Date, answeredAt: Date, features: WorkoutFeatures, workout: Bool) {
        self.askedAt = askedAt
        self.answeredAt = answeredAt
        self.features = features
        self.workout = workout
    }
}

/// One automatic switch of the raw streams, for the log (Settings shows the newest).
public struct AutoSwitchEntry: Codable, Equatable, Sendable {
    public var at: Date
    public var on: Bool
    /// "workout" or "burst".
    public var source: String
    public var reason: String

    public init(at: Date, on: Bool, source: String, reason: String) {
        self.at = at
        self.on = on
        self.source = source
        self.reason = reason
    }
}

/// Everything r9q keeps in Mo's settings. Tolerant on decode: a settings file from an earlier build gives the defaults.
public struct AutoRawSettings: Codable, Equatable, Sendable {
    // Workouts.
    /// Default ON (Mo's priority, D-LOAD-WALK-2). Off = nothing switches by itself and no question is asked.
    public var workoutAutoOn: Bool = true
    /// The most automatic raw-stream time per day for workouts, in minutes. 120: a long training day (90 min session plus
    /// warm-up and a false start) fits; a day of false starts cannot drain the strap. Bursts have their own small budget.
    public var dailyCapMinutes: Int = 120
    public var params = LiveWorkoutParams()
    public var usedDay: String = ""
    public var usedSeconds: Double = 0
    public var asksDay: String = ""
    public var asksToday: Int = 0
    /// Mo's answers, newest last, at most 200: the training set (also exported with the settings).
    public var labels: [WorkoutLabel] = []
    public var switchLog: [AutoSwitchEntry] = []

    // Bursts at chosen moments (T9823, refined by D-TRENDS-1). Default ON (Mo's decision).
    public var burstsOn: Bool = true
    /// Which moments may start a burst (BurstKind raw values): deep sleep, morning rest, a still period in the day.
    public var burstKinds: [String] = BurstKind.allCases.map(\.rawValue)
    /// 4 minutes = 30 non-overlapping 8-s ALG-144 windows: enough for a resting HRV / SpO2 baseline and a 5-min-class ensemble
    /// template at the short end, and about 16 minutes of raw streaming on the busiest day.
    public var burstSeconds: Int = 240
    public var burstDay: String = ""
    /// Kinds already started on `burstDay` (a kind can appear `BurstKind.perDay` times).
    public var burstsDone: [String] = []
    public var lastStillBurstAt: Date?
    public var burstLog: [BurstLogEntry] = []
    /// D-TRENDS-1: every time the strap sends 50 Hz optical records (time, count), newest last.
    public var fiftyHzLog: [FiftyHzEvent] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AutoRawSettings()
        workoutAutoOn = ((try? c.decodeIfPresent(Bool.self, forKey: .workoutAutoOn)) ?? nil) ?? d.workoutAutoOn
        dailyCapMinutes = ((try? c.decodeIfPresent(Int.self, forKey: .dailyCapMinutes)) ?? nil) ?? d.dailyCapMinutes
        params = ((try? c.decodeIfPresent(LiveWorkoutParams.self, forKey: .params)) ?? nil) ?? d.params
        usedDay = ((try? c.decodeIfPresent(String.self, forKey: .usedDay)) ?? nil) ?? d.usedDay
        usedSeconds = ((try? c.decodeIfPresent(Double.self, forKey: .usedSeconds)) ?? nil) ?? d.usedSeconds
        asksDay = ((try? c.decodeIfPresent(String.self, forKey: .asksDay)) ?? nil) ?? d.asksDay
        asksToday = ((try? c.decodeIfPresent(Int.self, forKey: .asksToday)) ?? nil) ?? d.asksToday
        labels = ((try? c.decodeIfPresent([WorkoutLabel].self, forKey: .labels)) ?? nil) ?? d.labels
        switchLog = ((try? c.decodeIfPresent([AutoSwitchEntry].self, forKey: .switchLog)) ?? nil) ?? d.switchLog
        burstsOn = ((try? c.decodeIfPresent(Bool.self, forKey: .burstsOn)) ?? nil) ?? d.burstsOn
        burstKinds = ((try? c.decodeIfPresent([String].self, forKey: .burstKinds)) ?? nil) ?? d.burstKinds
        burstSeconds = ((try? c.decodeIfPresent(Int.self, forKey: .burstSeconds)) ?? nil) ?? d.burstSeconds
        burstDay = ((try? c.decodeIfPresent(String.self, forKey: .burstDay)) ?? nil) ?? d.burstDay
        burstsDone = ((try? c.decodeIfPresent([String].self, forKey: .burstsDone)) ?? nil) ?? d.burstsDone
        lastStillBurstAt = (try? c.decodeIfPresent(Date.self, forKey: .lastStillBurstAt)) ?? nil
        fiftyHzLog = ((try? c.decodeIfPresent([FiftyHzEvent].self, forKey: .fiftyHzLog)) ?? nil) ?? d.fiftyHzLog
        burstLog = ((try? c.decodeIfPresent([BurstLogEntry].self, forKey: .burstLog)) ?? nil) ?? d.burstLog
    }

    private enum CodingKeys: String, CodingKey {
        case workoutAutoOn, dailyCapMinutes, params, usedDay, usedSeconds, asksDay, asksToday, labels, switchLog
        case burstsOn, burstKinds, burstSeconds, burstDay, burstsDone, lastStillBurstAt, burstLog, fiftyHzLog
    }

    public static let maxLabels = 200
    public static let maxSwitchLog = 60
    public static let maxBurstLog = 30
    public static let maxFiftyHzLog = 60

    public mutating func log(_ e: AutoSwitchEntry) {
        switchLog.append(e)
        if switchLog.count > Self.maxSwitchLog { switchLog.removeFirst(switchLog.count - Self.maxSwitchLog) }
    }

    /// Local day key "2026-10-17" (the budget and the burst list reset when it changes).
    public static func dayKey(_ now: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

public struct AutoWorkoutMachine: Equatable, Sendable {
    /// How long a question stays open; then the streams go back and nothing is learned from the silence.
    public static let askTimeoutS: TimeInterval = 20 * 60
    /// No second question for this long after a No or an unanswered one, and after a confirmed workout ends.
    public static let cooldownAfterNoS: TimeInterval = 30 * 60
    public static let cooldownAfterWorkoutS: TimeInterval = 20 * 60
    /// At most this many questions a day (the notification adds nothing past it).
    public static let maxAsksPerDay = 4
    /// The workout is over when the heart rate has been below the zone-1 floor this many whole minutes.
    public static let endQuietMinutes = 8
    /// … or when no heart-rate beat has arrived for this long.
    public static let endSilentS: TimeInterval = 10 * 60
    /// One automatic episode never runs longer than this.
    public static let maxEpisodeS: TimeInterval = 3 * 3600
    /// A late answer (the notification was opened after the question timed out) still counts for this long.
    public static let lateAnswerS: TimeInterval = 2 * 3600

    public enum Phase: Equatable, Sendable {
        case idle
        case asking(since: Date, onset: Date)
        /// `sawSession`: the app's workout session has been seen running; it ending then ends this.
        case confirmed(since: Date, onset: Date, sawSession: Bool)
    }

    public struct LastAsk: Equatable, Sendable {
        public var features: WorkoutFeatures
        public var at: Date
        public var onset: Date
    }

    public struct Input: Sendable {
        public var now: Date
        public var dayKey: String
        /// nil = the gate is not met (see `LiveWorkoutDetector.features`).
        public var features: WorkoutFeatures?
        /// Whole minutes in a row below the zone-1 floor (HRMinuteRing.quietMinutes).
        public var quietMinutes: Int
        /// Seconds since the last heart-rate beat (a large number when none).
        public var silentSeconds: TimeInterval
        public var offloading: Bool
        public var connected: Bool
        /// A workout session is running in the app (started by hand, or by a Yes here).
        public var workoutRunning: Bool

        public init(now: Date, dayKey: String, features: WorkoutFeatures?, quietMinutes: Int, silentSeconds: TimeInterval,
                    offloading: Bool, connected: Bool, workoutRunning: Bool) {
            self.now = now
            self.dayKey = dayKey
            self.features = features
            self.quietMinutes = quietMinutes
            self.silentSeconds = silentSeconds
            self.offloading = offloading
            self.connected = connected
            self.workoutRunning = workoutRunning
        }
    }

    public enum Action: Equatable, Sendable {
        case streamsOn(reason: String)
        case streamsOff(reason: String)
        case ask(WorkoutFeatures, onset: Date)
        case withdrawAsk
        case startWorkout(onset: Date)
        case label(WorkoutLabel)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var lastAsk: LastAsk?
    public private(set) var cooldownUntil: Date?
    private var lastStepAt: Date?

    public init() {}

    /// True while this machine wants the raw streams on.
    public var streamsOn: Bool { phase != .idle }

    public mutating func step(_ i: Input, settings s: inout AutoRawSettings) -> [Action] {
        if s.usedDay != i.dayKey { s.usedDay = i.dayKey; s.usedSeconds = 0 }
        if s.asksDay != i.dayKey { s.asksDay = i.dayKey; s.asksToday = 0 }
        let dt = lastStepAt.map { min(max(i.now.timeIntervalSince($0), 0), 60) } ?? 0
        lastStepAt = i.now
        let cap = Double(max(0, s.dailyCapMinutes)) * 60

        switch phase {
        case .idle:
            guard s.workoutAutoOn, i.connected, !i.offloading else { return [] }
            guard s.usedSeconds < cap else { return [] }
            if let c = cooldownUntil, i.now < c { return [] }
            // Mo started a workout by hand: that is a workout, no question, no label.
            if i.workoutRunning {
                phase = .confirmed(since: i.now, onset: i.now, sawSession: true)
                return [.streamsOn(reason: "workout started by you")]
            }
            guard s.asksToday < Self.maxAsksPerDay, let f = i.features,
                  LiveWorkoutDetector.probability(s.params, f) >= LiveWorkoutDetector.askProbability else { return [] }
            let p = LiveWorkoutDetector.probability(s.params, f)
            phase = .asking(since: i.now, onset: f.onset)
            lastAsk = LastAsk(features: f, at: i.now, onset: f.onset)
            s.asksToday += 1
            return [.streamsOn(reason: "workout likely: heart rate in zone 1 or higher for \(LiveWorkoutDetector.sustainMinutes) min "
                               + "(score \(Int((p * 100).rounded())) %)"),
                    .ask(f, onset: f.onset)]

        case .asking(let since, let onset):
            s.usedSeconds += dt
            if i.workoutRunning {
                phase = .confirmed(since: since, onset: onset, sawSession: true)
                return [.withdrawAsk]
            }
            if let why = endReason(i, s, since: since, cap: cap, sawSession: false) {
                return finish(i.now, cooldown: Self.cooldownAfterNoS, why: why, withdraw: true)
            }
            if i.now.timeIntervalSince(since) >= Self.askTimeoutS {
                return finish(i.now, cooldown: Self.cooldownAfterNoS, why: "no answer in 20 min", withdraw: true)
            }
            return []

        case .confirmed(let since, let onset, let saw):
            s.usedSeconds += dt
            let sawNow = saw || i.workoutRunning
            if sawNow != saw { phase = .confirmed(since: since, onset: onset, sawSession: sawNow) }
            if let why = endReason(i, s, since: since, cap: cap, sawSession: sawNow) {
                return finish(i.now, cooldown: Self.cooldownAfterWorkoutS, why: why, withdraw: false)
            }
            return []
        }
    }

    /// Mo's answer to the question (notification button or the in-app card). A late answer still teaches the detector.
    public mutating func answer(workout yes: Bool, now: Date, settings s: inout AutoRawSettings) -> [Action] {
        guard let ask = lastAsk, now.timeIntervalSince(ask.at) <= Self.lateAnswerS else { return [] }
        lastAsk = nil
        let label = WorkoutLabel(askedAt: ask.at, answeredAt: now, features: ask.features, workout: yes)
        s.labels.append(label)
        if s.labels.count > AutoRawSettings.maxLabels { s.labels.removeFirst(s.labels.count - AutoRawSettings.maxLabels) }
        s.params = LiveWorkoutDetector.refit(labels: s.labels)
        var out: [Action] = [.label(label), .withdrawAsk]
        if yes {
            switch phase {
            case .idle:
                phase = .confirmed(since: now, onset: ask.onset, sawSession: false)
                out.append(.streamsOn(reason: "you said yes to a late question"))
            case .asking(let since, let onset):
                phase = .confirmed(since: since, onset: onset, sawSession: false)
            case .confirmed:
                break
            }
            out.append(.startWorkout(onset: ask.onset))
        } else {
            let wasOn = phase != .idle
            phase = .idle
            cooldownUntil = now.addingTimeInterval(Self.cooldownAfterNoS)
            if wasOn { out.append(.streamsOff(reason: "you said it is not a workout")) }
        }
        return out
    }

    /// Ends any automatic episode now (the switch was turned off, sample data came on, the app is shutting the link).
    public mutating func stop(now: Date, why: String) -> [Action] {
        guard phase != .idle else { return [] }
        return finish(now, cooldown: 0, why: why, withdraw: true)
    }

    private mutating func finish(_ now: Date, cooldown: TimeInterval, why: String, withdraw: Bool) -> [Action] {
        phase = .idle
        cooldownUntil = now.addingTimeInterval(cooldown)
        return (withdraw ? [Action.withdrawAsk] : []) + [.streamsOff(reason: why)]
    }

    private func endReason(_ i: Input, _ s: AutoRawSettings, since: Date, cap: Double, sawSession: Bool) -> String? {
        if sawSession && !i.workoutRunning { return "the workout ended" }
        if i.silentSeconds >= Self.endSilentS { return "no heart-rate data for 10 min" }
        if i.quietMinutes >= Self.endQuietMinutes { return "heart rate below zone 1 for \(Self.endQuietMinutes) min" }
        if s.usedSeconds >= cap { return "today's automatic limit of \(s.dailyCapMinutes) min is used up" }
        if i.now.timeIntervalSince(since) >= Self.maxEpisodeS { return "3 h limit for one automatic workout" }
        return nil
    }
}
