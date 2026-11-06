import Foundation
import MGDomain

// Inputs and outputs of the context engine that ARCHITECTURE §4.7 names but does not spell out.
// Timings come from UX-SPEC §4.2 and §5 (cited per item).

// MARK: - Strap, sessions, alerts

/// What the context engine needs to know about the strap (ALG-007 wear state, link, battery).
public struct StrapStatus: Equatable, Sendable {
    public enum Link: String, Sendable, CaseIterable {
        /// `bluetoothNotAllowed` (T141, 2026-10-12): the phone's Bluetooth may be on, but iOS has not allowed this app to use it.
        case notPaired, bluetoothOff, bluetoothNotAllowed, searching, connecting, connected, disconnected

        /// T141 (2026-10-13): the only two causes an iOS Settings toggle fixes — Today and Live show the pairing
        /// sheet's "Open Settings" button for both, and only both.
        public var needsOpenSettings: Bool { self == .bluetoothOff || self == .bluetoothNotAllowed }
    }

    public var link: Link
    /// T141 (r9d): why the link is down, in a few words ("out of range", "handed back to WHOOP"). nil = not known / not down.
    public var notConnectedReason: String?
    public var batteryPercent: Double?
    public var charging: Bool?
    /// WRIST_OFF (event 10) with no WRIST_ON after it; `nil` = on the wrist or unknown (ALG-007).
    public var offWristSince: Date?
    /// T110: `offWristSince` was restored from storage and nothing (strap event or good beats) has confirmed it yet.
    public var offWristMayBeStale: Bool
    public var wearLocation: WearLocation?
    public var lastRecordAt: Date?

    /// T9999: the strap sheet's "Last record" is the newer of the last live beat and the newest stored record. It used to be
    /// the live beat alone, which is nil during a history download and right after launch ("Nothing recorded yet").
    public static func newestRecord(live: Date?, stored: Date?) -> Date? {
        switch (live, stored) {
        case let (l?, s?): return max(l, s)
        case let (l?, nil): return l
        case let (nil, s?): return s
        case (nil, nil): return nil
        }
    }
    /// Percent + estimated time left from the stored battery history (BatteryEstimator; added 2026-10-11).
    public var batteryEstimate: BatteryEstimate?
    /// 0.6.0.11 (Mo, Nov 5: "should only call out the device i set"): the strap the status words name, "MG" or "WHOOP 4.0"
    /// (Settings › Strap & sync › Device). Set by the app after init; every "MG …" chip and row uses it.
    public var device: String = "MG"

    public init(link: Link, batteryPercent: Double? = nil, charging: Bool? = nil, offWristSince: Date? = nil,
                offWristMayBeStale: Bool = false, wearLocation: WearLocation? = nil, lastRecordAt: Date? = nil,
                batteryEstimate: BatteryEstimate? = nil, notConnectedReason: String? = nil) {
        self.link = link
        self.notConnectedReason = notConnectedReason
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.offWristSince = offWristSince
        self.offWristMayBeStale = offWristMayBeStale
        self.wearLocation = wearLocation
        self.lastRecordAt = lastRecordAt
        self.batteryEstimate = batteryEstimate
    }

    public static let notPaired = StrapStatus(link: .notPaired)

    /// T141 (r9d): the link layer's raw reason for a lost link (`StrapLinkState.disconnected(reason:)`) in a few words.
    /// `handedBack`: "Hand the strap back to WHOOP" is on, so the app does not connect at all. nil when there is nothing to say.
    public static func notConnectedWords(raw: String?, handedBack: Bool) -> String? {
        if handedBack { return "handed back to WHOOP" }
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let t = raw.lowercased()
        if t.contains("disconnected by you") { return "disconnected by you" }
        if t.contains("bluetooth is off") { return "Bluetooth is off" }
        if t.contains("refus") || t.contains("insufficient authentication") || t.contains("pairing") {
            return "pairing refused - close the WHOOP app first"
        }
        if t.contains("no notification") || t.contains("no data") || t.contains("keep-alive") {
            return "the link went quiet, reconnecting"
        }
        if t.contains("strap disconnected") || t.contains("disconnected from us") || t.contains("timed out")
            || t.contains("not connected") || t.contains("connection") {
            return "out of range or link lost, reconnecting when it is back"
        }
        return "link lost: " + String(raw.prefix(60))
    }
}

/// A workout: live while `end` is nil (ALG-041 or a manual start).
public struct WorkoutSession: Equatable, Sendable, Identifiable {
    public enum Trigger: String, Sendable { case detected, manual }

    public var id: UUID
    public var start: Date
    public var end: Date?
    public var trigger: Trigger
    /// nil until Mo answers the workout-confirm question; true = yes, false = "Not a workout". Manual workouts need no answer.
    public var confirmed: Bool?
    public var activityType: String?
    public var place: String?

    public init(id: UUID = UUID(), start: Date, end: Date? = nil, trigger: Trigger, confirmed: Bool? = nil,
                activityType: String? = nil, place: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.trigger = trigger
        self.confirmed = confirmed
        self.activityType = activityType
        self.place = place
    }

    public var isLive: Bool { end == nil }
}

/// A nap: a manual nap timer, or a nap ALG-033 detected.
public struct NapSession: Equatable, Sendable {
    public enum Trigger: String, Sendable { case detected, manual }

    public var start: Date
    /// Timer length for a manual nap ("Nap · 12 of 25 min").
    public var plannedMinutes: Int?
    /// nil while the timer runs.
    public var end: Date?
    public var trigger: Trigger
    public var smartWake: Bool

    public init(start: Date, plannedMinutes: Int? = nil, end: Date? = nil, trigger: Trigger, smartWake: Bool = false) {
        self.start = start
        self.plannedMinutes = plannedMinutes
        self.end = end
        self.trigger = trigger
        self.smartWake = smartWake
    }
}

/// A health alert (UX §4.2 "Alert": breathing disturbance ALG-023, possible AF ALG-013, multivariate anomaly ALG-112).
public struct AlertInfo: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case breathingDisturbance, possibleAF, anomaly }

    /// Stable per pattern, so a seen alert does not repeat unless it worsens (APP-037).
    public var id: String
    public var kind: Kind
    public var raisedAt: Date
    /// The alert in one sentence.
    public var sentence: String
    public var evidence: String?
    public var seen: Bool

    public init(id: String, kind: Kind, raisedAt: Date, sentence: String, evidence: String? = nil, seen: Bool = false) {
        self.id = id
        self.kind = kind
        self.raisedAt = raisedAt
        self.sentence = sentence
        self.evidence = evidence
        self.seen = seen
    }
}

// MARK: - Peeks (UX §5)

/// The kind of a peek, without its details. Declared in priority order (UX §5):
/// wear location > workout confirm > nap > nap + 30 min > morning check-in > meal check-in.
public enum PeekKindKey: String, Sendable, CaseIterable, Codable, Comparable {
    case wearLocation, workoutConfirm, nap, napPlus30, morningCheckin, mealCheckin

    /// 0 = highest.
    public var priority: Int { PeekKindKey.allCases.firstIndex(of: self) ?? Int.max }

    public static func < (lhs: PeekKindKey, rhs: PeekKindKey) -> Bool { lhs.priority < rhs.priority }
}

/// One question, with what the presenter needs to word it.
public enum PeekKind: Equatable, Sendable {
    /// "Where's the strap now?" after WRIST_ON (APP-008).
    case wearLocation(wristOnAt: Date, previous: WearLocation?)
    /// "Workout 17:32–18:20 — right?" (APP-051/058, ALG-041).
    case workoutConfirm(start: Date, end: Date)
    /// "Nap 14:05–14:31?" (APP-042, ALG-033).
    case nap(start: Date, end: Date)
    /// "30 min after your nap — how now?" (APP-045, ALG-037).
    case napPlus30(napEnd: Date)
    /// The two-tap morning check-in (UX §5.1).
    case morningCheckin(wake: Date)
    /// KSS 60 or 120 min after a logged meal (APP-061).
    case mealCheckin(mealAt: Date, minutesAfter: Int)

    public var key: PeekKindKey {
        switch self {
        case .wearLocation: return .wearLocation
        case .workoutConfirm: return .workoutConfirm
        case .nap: return .nap
        case .napPlus30: return .napPlus30
        case .morningCheckin: return .morningCheckin
        case .mealCheckin: return .mealCheckin
        }
    }
}

/// A question waiting to be asked. The caller keeps the list (and drops answered ones); the engine decides which one
/// peeks now. Build them with the factories below so the UX timings live in one place.
public struct PendingQuestion: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: PeekKind
    /// Not shown before this instant.
    public var availableFrom: Date
    /// Gone after this instant (expires silently, nothing stored).
    public var expiresAt: Date
    /// Swiped down ("later"): no longer peeks; shows as the header "1 question" chip until it expires.
    public var deferredAt: Date?
    /// Whether this kind's model is unsure about the answer (ALG-033 "asks more when unsure"). nil = the kind has no model.
    public var modelUnsure: Bool?
    /// The nth question of this kind; after two swipe-aways in a row only even occurrences ask ("half as often").
    public var occurrence: Int

    public init(id: String, kind: PeekKind, availableFrom: Date, expiresAt: Date, deferredAt: Date? = nil,
                modelUnsure: Bool? = nil, occurrence: Int = 0) {
        self.id = id
        self.kind = kind
        self.availableFrom = availableFrom
        self.expiresAt = expiresAt
        self.deferredAt = deferredAt
        self.modelUnsure = modelUnsure
        self.occurrence = occurrence
    }

    public func isActive(at now: Date) -> Bool { availableFrom <= now && now < expiresAt }

    // UX timings.
    static let minute: TimeInterval = 60

    /// UX §4.2 "Strap back on": answered, or unanswered after 1 h = "same as before", marked assumed.
    public static func wearLocation(wristOnAt: Date, previous: WearLocation?, occurrence: Int = 0) -> PendingQuestion {
        PendingQuestion(id: "wear:\(Int(wristOnAt.timeIntervalSince1970))",
                        kind: .wearLocation(wristOnAt: wristOnAt, previous: previous),
                        availableFrom: wristOnAt, expiresAt: wristOnAt.addingTimeInterval(60 * minute),
                        occurrence: occurrence)
    }

    /// UX §4.2 "Workout just ended": confirmed, or 2 h.
    public static func workoutConfirm(start: Date, end: Date, modelUnsure: Bool? = nil,
                                      occurrence: Int = 0) -> PendingQuestion {
        PendingQuestion(id: "workout:\(Int(start.timeIntervalSince1970))",
                        kind: .workoutConfirm(start: start, end: end),
                        availableFrom: end, expiresAt: end.addingTimeInterval(120 * minute),
                        modelUnsure: modelUnsure, occurrence: occurrence)
    }

    /// UX §4.2 "Nap detected": answered, or 3 h.
    public static func nap(start: Date, end: Date, modelUnsure: Bool? = nil, occurrence: Int = 0) -> PendingQuestion {
        PendingQuestion(id: "nap:\(Int(start.timeIntervalSince1970))", kind: .nap(start: start, end: end),
                        availableFrom: end, expiresAt: end.addingTimeInterval(180 * minute),
                        modelUnsure: modelUnsure, occurrence: occurrence)
    }

    /// UX §4.2 "30 min after a nap": opens at nap end + 30 min; "answered / 45 min" read as open for 45 min.
    public static func napPlus30(napEnd: Date, occurrence: Int = 0) -> PendingQuestion {
        let opens = napEnd.addingTimeInterval(30 * minute)
        return PendingQuestion(id: "nap30:\(Int(napEnd.timeIntervalSince1970))", kind: .napPlus30(napEnd: napEnd),
                               availableFrom: opens, expiresAt: opens.addingTimeInterval(45 * minute),
                               occurrence: occurrence)
    }

    /// UX §5.2 meal check-in at 60 and 120 min after a logged meal; open 30 min (prototype "lunch" scenario notes).
    public static func mealCheckin(mealAt: Date, minutesAfter: Int, occurrence: Int = 0) -> PendingQuestion {
        let opens = mealAt.addingTimeInterval(TimeInterval(minutesAfter) * minute)
        return PendingQuestion(id: "meal\(minutesAfter):\(Int(mealAt.timeIntervalSince1970))",
                               kind: .mealCheckin(mealAt: mealAt, minutesAfter: minutesAfter),
                               availableFrom: opens, expiresAt: opens.addingTimeInterval(30 * minute),
                               occurrence: occurrence)
    }

    /// UX §5.1: from W while unanswered, expires silently at W + 3 h. The engine builds this one itself; pass it in
    /// `pending` only to carry `deferredAt` after a swipe-away.
    public static func morningCheckin(wake: Date, occurrence: Int = 0) -> PendingQuestion {
        PendingQuestion(id: "checkin:\(Int(wake.timeIntervalSince1970))", kind: .morningCheckin(wake: wake),
                        availableFrom: wake, expiresAt: wake.addingTimeInterval(180 * minute),
                        occurrence: occurrence)
    }
}

// MARK: - Moments (UX §4.2)

/// Moment card kinds in priority order (UX §4.2): alert > workout live > nap timer > strap off > history downloading >
/// workout just ended > data waiting.
public enum MomentKind: Int, Sendable, CaseIterable, Comparable {
    case alert = 0, workoutLive, napTimer, strapOff, historyDownloading, workoutJustEnded, dataWaiting

    public static func < (lhs: MomentKind, rhs: MomentKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A live state for the Moment card. One shows; the rest fold into "+n more".
public enum Moment: Equatable, Sendable {
    case alert(AlertInfo)
    case workoutLive(WorkoutSession)
    case napTimer(NapSession)
    case strapOff(since: Date)
    case historyDownloading(HistoryProgress)
    case workoutJustEnded(WorkoutSession)
    /// Offline with data older than 6 h waiting; `since` = last successful sync.
    case dataWaiting(since: Date)

    public var kind: MomentKind {
        switch self {
        case .alert: return .alert
        case .workoutLive: return .workoutLive
        case .napTimer: return .napTimer
        case .strapOff: return .strapOff
        case .historyDownloading: return .historyDownloading
        case .workoutJustEnded: return .workoutJustEnded
        case .dataWaiting: return .dataWaiting
        }
    }
}
