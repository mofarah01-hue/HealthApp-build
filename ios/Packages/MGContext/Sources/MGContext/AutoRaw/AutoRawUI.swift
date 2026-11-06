import Foundation

// r9q (Oct 17 2026): the words and switches for the automatic raw streams (Strap & sync › "Automatic raw") and the in-app
// "Workout? Yes / No" card. States only; AppModel+AutoWorkout carries the actions out.

/// Payload of `UIIntent.autoRaw`.
public enum AutoRawAction: Equatable, Sendable {
    /// Switch on by themselves when a workout looks likely (and ask). Default on.
    case setWorkoutAuto(Bool)
    /// Daily bursts at chosen moments. Default on.
    case setBursts(Bool)
    /// One moment on / off (BurstKind raw value).
    case setBurstKind(String, Bool)
    /// Length of one burst in seconds (clamped 120...600).
    case setBurstSeconds(Int)
    /// The answer to "Workout?" (card or notification button).
    case answerWorkout(Bool)
}

/// What the Strap & sync screen needs from the app about the automatic raw streams.
public struct AutoRawInfo: Equatable, Sendable {
    public var settings = AutoRawSettings()
    /// Why the streams are on by themselves right now, nil = they are not.
    public var activeReason: String?
    public var calendar = Calendar(identifier: .gregorian)
    public init() {}
}

/// The in-app question, shown until answered or withdrawn.
public struct AutoWorkoutPrompt: Equatable, Sendable {
    public var title: String
    public var body: String
    public var since: Date

    public init(title: String, body: String, since: Date) {
        self.title = title
        self.body = body
        self.since = since
    }
}

public struct AutoRawSection: Equatable, Sendable {
    public var workout: ToggleState
    public var workoutLines: [String]
    public var bursts: ToggleState
    public var kindToggles: [ToggleState]
    public var lengthLabel: String
    public var lengthOptions: [ActionState]
    public var burstLines: [String]
    public var fiftyHzLines: [String]
}

public enum AutoRawPresenter {
    public static let lengthChoices = [180, 240, 300]

    public static func section(_ info: AutoRawInfo, sample: Bool, mgOnly: String? = nil) -> AutoRawSection {
        let s = info.settings
        let cal = info.calendar
        let why: String? = mgOnly ?? (sample ? "Sample data is on." : nil)
        let usedMin = Int((s.usedSeconds / 60).rounded(.down))

        var wl = ["When your heart rate stays in zone 1 or higher for \(LiveWorkoutDetector.sustainMinutes) minutes, raw PPG and "
                  + "100 Hz motion switch on for the workout and MG asks \"Workout?\". When it ends, or you say No, they go "
                  + "back to what you saved. They run at most \(s.dailyCapMinutes) min a day this way (used today: "
                  + "\(s.usedDay.isEmpty ? 0 : usedMin) min), and never start during a history download."]
        if let r = info.activeReason { wl.append("On now: \(r).") }
        wl.append("How readily MG asks: \(s.params.provenance) (\(s.params.yes) yes, \(s.params.no) no). It starts from the "
                  + "population values and moves toward yours as you answer.")
        if let last = s.switchLog.last {
            wl.append("Last automatic switch: \(last.on ? "on" : "off") at \(MGFormat.time(last.at, calendar: cal)) "
                      + "(\(last.source)): \(last.reason).")
        }

        var bl = ["Short raw-PPG bursts at quiet moments (\(RawBursts.kindsText(s.burstKinds))), \(s.burstSeconds / 60) min each, "
                  + "kept for HRV, SpO₂ and pulse-shape trends only when the signal passes a strict quality check "
                  + "(\(Int(RawBurstGate.minCleanShare * 100)) % of 8-s windows clean). Deep sleep and morning rest keep live "
                  + "heart rate on so the app can see a calm moment."]
        if let b = s.burstLog.last {
            bl.append("Last burst: \(BurstKind(rawValue: b.kind)?.title ?? "burst") at \(MGFormat.time(b.start, calendar: cal)): "
                      + "\(b.usable ? "usable" : "not used"), \(b.reason).")
        } else {
            bl.append("No burst has run yet.")
        }
        let usable = s.burstLog.filter { $0.usable }.count
        if !s.burstLog.isEmpty { bl.append("Of the last \(s.burstLog.count) bursts, \(usable) were usable.") }

        var hz: [String] = []
        if s.fiftyHzLog.isEmpty {
            hz.append("50 Hz optical records seen so far: none.")
        } else {
            let total = s.fiftyHzLog.reduce(0) { $0 + $1.count }
            hz.append("50 Hz optical records seen: \(total) in \(s.fiftyHzLog.count) place\(s.fiftyHzLog.count == 1 ? "" : "s"); "
                      + "latest at \(MGFormat.time(s.fiftyHzLog.last!.at, calendar: cal)) (\(s.fiftyHzLog.last!.count)).")
        }

        let kinds = BurstKind.allCases.map { k -> ToggleState in
            let on = s.burstKinds.contains(k.rawValue)
            return ToggleState(id: "burst_\(k.rawValue)", title: k.title, isOn: on, enabled: why == nil && s.burstsOn,
                               disabledReason: why ?? (s.burstsOn ? nil : "Switch bursts on first."),
                               intent: .autoRaw(.setBurstKind(k.rawValue, !on)))
        }
        return AutoRawSection(
            workout: ToggleState(id: "autoWorkout", title: "Raw streams for workouts, automatically",
                                 detail: "Asks \"Workout?\" and trains itself on your answers.", isOn: s.workoutAutoOn,
                                 enabled: why == nil, disabledReason: why, intent: .autoRaw(.setWorkoutAuto(!s.workoutAutoOn))),
            workoutLines: wl,
            bursts: ToggleState(id: "autoBursts", title: "Raw bursts at quiet moments",
                                detail: "Uses a little strap battery each day (about \(s.burstSeconds * 4 / 60) min on the busiest day).",
                                isOn: s.burstsOn, enabled: why == nil, disabledReason: why,
                                intent: .autoRaw(.setBursts(!s.burstsOn))),
            kindToggles: kinds,
            lengthLabel: "\(s.burstSeconds / 60) min",
            lengthOptions: lengthChoices.map {
                ActionState(id: "burstLen\($0)", title: "\($0 / 60) min", intent: .autoRaw(.setBurstSeconds($0)),
                            enabled: why == nil && s.burstsOn, disabledReason: why)
            },
            burstLines: bl, fiftyHzLines: hz)
    }

    /// The in-app card and the notification say the same thing.
    public static func prompt(onset: Date, now: Date, calendar: Calendar) -> AutoWorkoutPrompt {
        AutoWorkoutPrompt(title: "Workout?",
                          body: "Your heart rate has been up since \(MGFormat.time(onset, calendar: calendar)). Raw sensor streams are "
                              + "on for it. Say No and they go back to your setting.",
                          since: now)
    }
}
