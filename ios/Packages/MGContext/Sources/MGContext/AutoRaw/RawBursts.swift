import Foundation

// r9q (Oct 17 2026, T9823, D-LOAD-WALK-2, refined by D-TRENDS-1): short raw-PPG bursts at CHOSEN MOMENTS (deep sleep, the
// morning rest after waking, still moments in the day), default ON (Mo's decision), each judged by a strict quality gate, so
// the enhanced tier (HRV / SpO2 baselines, pulse-shape trends from ensemble-averaged beats) has clean raw seconds without Mo
// switching anything on. Pure: which moment is it, whether the app must stay awake for it, and the verdict on what came back.
//
// The strap's raw R20 / R21 frames of a burst are stored like every raw frame (nothing is thrown away). The verdict decides
// whether the burst is USABLE for the enhanced tier, and is recorded in `burstLog` for the algorithms to read.

public struct BurstLogEntry: Codable, Equatable, Sendable {
    public var start: Date
    /// BurstKind raw value.
    public var kind: String
    /// R20 seconds that arrived for it.
    public var seconds: Int
    public var windows: Int
    public var cleanWindows: Int
    public var usable: Bool
    public var reason: String

    public init(start: Date, kind: String = "", seconds: Int, windows: Int, cleanWindows: Int, usable: Bool, reason: String) {
        self.start = start
        self.kind = kind
        self.seconds = seconds
        self.windows = windows
        self.cleanWindows = cleanWindows
        self.usable = usable
        self.reason = reason
    }
}

/// D-TRENDS-1: the strap sent optical windows flagged 50 Hz (flags bit 7 clear). No known command sets the rate, so each
/// occurrence is logged to learn when the strap does it. `at` is the strap's own time of the first window.
public struct FiftyHzEvent: Codable, Equatable, Sendable {
    public var at: Date
    public var count: Int

    public init(at: Date, count: Int) {
        self.at = at
        self.count = count
    }

    public var line: String {
        "50 Hz optical: \(count) window\(count == 1 ? "" : "s") at strap time \(Int(at.timeIntervalSince1970))"
    }

    /// Adds the event unless the same one is already there (a re-served chunk reports itself again).
    public static func record(_ e: FiftyHzEvent, settings s: inout AutoRawSettings) {
        guard !s.fiftyHzLog.contains(where: { $0.at == e.at && $0.count == e.count }) else { return }
        s.fiftyHzLog.append(e)
        if s.fiftyHzLog.count > AutoRawSettings.maxFiftyHzLog {
            s.fiftyHzLog.removeFirst(s.fiftyHzLog.count - AutoRawSettings.maxFiftyHzLog)
        }
    }
}

/// The moments a burst may start at (D-TRENDS-1: dynamic bursts at chosen moments, not a clock).
public enum BurstKind: String, Codable, CaseIterable, Sendable {
    case deepSleep = "deep_sleep"
    case morningRest = "morning_rest"
    case still = "still"

    public var title: String {
        switch self {
        case .deepSleep: return "Deep sleep"
        case .morningRest: return "Morning rest"
        case .still: return "Still moments in the day"
        }
    }

    public var perDay: Int { self == .still ? 2 : 1 }
}

/// What the burst chooser knows now.
public struct BurstContext: Sendable {
    public var now: Date
    /// The planned sleep window around now (bedtime, latest wake), nil when unknown.
    public var sleepStart: Date?
    public var sleepEnd: Date?
    /// Whole minutes in a row the heart rate stayed within `RawBursts.calmSpreadBpm` (HRMinuteRing.calmMinutes).
    public var calmMinutes: Int
    public var motion: MotionState
    /// An automatic workout episode is on, or a workout session runs.
    public var workoutBusy: Bool

    public init(now: Date, sleepStart: Date?, sleepEnd: Date?, calmMinutes: Int, motion: MotionState, workoutBusy: Bool) {
        self.now = now
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.calmMinutes = calmMinutes
        self.motion = motion
        self.workoutBusy = workoutBusy
    }
}

public enum RawBursts {
    /// The heart rate is "calm" when the last closed minutes stay within this many bpm of each other.
    public static let calmSpreadBpm = 8.0
    public static let calmMinutesNeeded = 3
    public static let calmMinutesStill = 5
    /// Deep sleep is looked for from 2 h to 6 h after bedtime (slow-wave sleep is concentrated in the first third of the
    /// night) while the heart rate is calm. An engineering window, not a stage label: the stager's own labels arrive later.
    public static let deepFromBedS: TimeInterval = 2 * 3600
    public static let deepUntilBedS: TimeInterval = 6 * 3600
    /// Morning rest: the first 90 min after the planned wake time.
    public static let morningSpanS: TimeInterval = 90 * 60
    /// A still-moment burst only in these local hours, and at least this far apart.
    public static let stillHours: Range<Int> = 9..<21
    public static let stillGapS: TimeInterval = 3 * 3600
    public static let lengthRange: ClosedRange<Int> = 120...600
    /// Lead time: live heart rate comes on this long before a window opens.
    public static let keepAwakeLeadS: TimeInterval = 600
    /// Above this mean heart rate the two pulse-wave peaks merge (Millasseau), so a burst is not usable for pulse shape.
    public static let maxUsableBpm = 90.0

    private static func done(_ k: BurstKind, _ s: AutoRawSettings, dayKey: String) -> Int {
        s.burstDay == dayKey ? s.burstsDone.filter { $0 == k.rawValue }.count : 0
    }

    private static func free(_ k: BurstKind, _ s: AutoRawSettings, dayKey: String) -> Bool {
        s.burstKinds.contains(k.rawValue) && done(k, s, dayKey: dayKey) < k.perDay
    }

    /// Which burst to start now, or nil. Never while a workout is on or the wrist moves; each kind has its own window and
    /// needs a calm heart rate first.
    public static func pick(_ c: BurstContext, settings s: AutoRawSettings, calendar: Calendar) -> BurstKind? {
        guard s.burstsOn, !c.workoutBusy, c.motion != .moving, c.calmMinutes >= calmMinutesNeeded else { return nil }
        let key = AutoRawSettings.dayKey(c.now, calendar: calendar)
        if free(.deepSleep, s, dayKey: key), let bed = c.sleepStart, let wake = c.sleepEnd,
           c.now >= bed.addingTimeInterval(deepFromBedS), c.now <= bed.addingTimeInterval(deepUntilBedS), c.now < wake {
            return .deepSleep
        }
        if free(.morningRest, s, dayKey: key), let wake = c.sleepEnd,
           c.now >= wake, c.now <= wake.addingTimeInterval(morningSpanS) {
            return .morningRest
        }
        if free(.still, s, dayKey: key), stillHours.contains(calendar.component(.hour, from: c.now)),
           c.calmMinutes >= calmMinutesStill,
           s.lastStillBurstAt.map({ c.now.timeIntervalSince($0) >= stillGapS }) ?? true {
            return .still
        }
        return nil
    }

    /// Live heart rate should be on so the calm moment can be seen: inside the deep-sleep or morning windows while a burst
    /// of that kind is still owed today.
    public static func keepAwake(now: Date, sleepStart: Date?, sleepEnd: Date?, settings s: AutoRawSettings,
                                 calendar: Calendar) -> Bool {
        guard s.burstsOn else { return false }
        let key = AutoRawSettings.dayKey(now, calendar: calendar)
        if free(.deepSleep, s, dayKey: key), let bed = sleepStart, let wake = sleepEnd,
           now >= bed.addingTimeInterval(deepFromBedS - keepAwakeLeadS), now <= bed.addingTimeInterval(deepUntilBedS),
           now < wake {
            return true
        }
        if free(.morningRest, s, dayKey: key), let wake = sleepEnd,
           now >= wake.addingTimeInterval(-keepAwakeLeadS), now <= wake.addingTimeInterval(morningSpanS) {
            return true
        }
        return false
    }

    public static func markStarted(_ k: BurstKind, at: Date, settings s: inout AutoRawSettings, dayKey: String) {
        if s.burstDay != dayKey { s.burstDay = dayKey; s.burstsDone = [] }
        s.burstsDone.append(k.rawValue)
        if k == .still { s.lastStillBurstAt = at }
    }

    public static func record(_ e: BurstLogEntry, settings s: inout AutoRawSettings) {
        s.burstLog.append(e)
        if s.burstLog.count > AutoRawSettings.maxBurstLog { s.burstLog.removeFirst(s.burstLog.count - AutoRawSettings.maxBurstLog) }
    }

    /// "Deep sleep, Morning rest"
    public static func kindsText(_ kinds: [String]) -> String {
        let t = BurstKind.allCases.filter { kinds.contains($0.rawValue) }.map { $0.title }
        return t.isEmpty ? "none" : t.joined(separator: ", ")
    }
}

/// One 8-s ALG-144 window as the gate sees it (the app maps `ALG144.Window` to this: state raw value + gate raw values).
public struct BurstWindowQuality: Equatable, Sendable {
    public var state: String
    public var gates: [String]

    public init(state: String, gates: [String]) {
        self.state = state
        self.gates = gates
    }
}

/// The burst quality gate. The existing artefact gate (ALG-144 per window: measured / reduced / unavailable) is used on every
/// window; a burst is USABLE only when it is clearly stricter than "some windows passed":
///  - a window is clean only when it is `measured` with no gate at all (no MOTION, no ADC_CLIPPED, no LOW_SNR, no
///    PEAK_DISAGREEMENT, no RATE_AMBIGUITY, no gap); `reduced` windows do not count;
///  - at least `minWindows` windows (2 min of 8 s) and at least `minCleanShare` of ALL windows must be clean;
///  - a mean heart rate above 90 bpm fails it (pulse-shape peaks merge).
/// The numbers are engineering starting values, like ALG-144's own (not tuned against a reference). The trend research's
/// shared gate (skewness SQI, accelerometer RMS, beat-template correlation >= 0.9) belongs to r9l's SQI: when it lands,
/// replace `isClean` with it; the rest of the gate stands.
public enum RawBurstGate {
    public static let minWindows = 15
    public static let minCleanShare = 0.8

    public static func isClean(_ w: BurstWindowQuality) -> Bool { w.state == "measured" && w.gates.isEmpty }

    public static func judge(start: Date, kind: String = "", windows: [BurstWindowQuality], recordSeconds: Int,
                             meanBpm: Double? = nil) -> BurstLogEntry {
        let clean = windows.filter(isClean).count
        func entry(_ usable: Bool, _ why: String) -> BurstLogEntry {
            BurstLogEntry(start: start, kind: kind, seconds: recordSeconds, windows: windows.count, cleanWindows: clean,
                          usable: usable, reason: why)
        }
        if recordSeconds <= 0 {
            return entry(false, "no raw data arrived (strap off the wrist, link down, or the stream was refused)")
        }
        if windows.count < minWindows {
            return entry(false, "only \(windows.count) analysable windows (\(recordSeconds) s of data); need \(minWindows)")
        }
        if let bpm = meanBpm, bpm > RawBursts.maxUsableBpm {
            return entry(false, "heart rate \(Int(bpm.rounded())) bpm is above \(Int(RawBursts.maxUsableBpm)): pulse-wave peaks merge")
        }
        let share = Double(clean) / Double(windows.count)
        let pct = Int((share * 100).rounded())
        if share < minCleanShare {
            return entry(false, "\(clean) of \(windows.count) windows clean (\(pct) %); need \(Int(minCleanShare * 100)) %")
        }
        return entry(true, "\(clean) of \(windows.count) windows clean (\(pct) %)")
    }
}
