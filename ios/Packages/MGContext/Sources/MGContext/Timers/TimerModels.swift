import Foundation

// Timers (T153, 2026-10-12). Mo: "if I say Siri set a time for 10 min it sets a phone timer AND a whoop buzz timer
// (just buzzes 4 times in timers I can change that)".
//
// A timer is: an iPhone alert at its end (a local notification, so it rings even when the app is dead) plus ONE
// strap buzz of 1-8 pulses (RUN_HAPTIC_PATTERN_MAVERICK, CLAUDE.md rule 5) sent by the app while it is alive and the
// strap is connected. The strap alarm slot is not used here. Since D-029a (2026-10-12) each timer has a stop choice:
// `.buzzes(n)` = that one buzz and done; `.doubleTap` = the SAME allowed command 19 (4 pulses) re-sent every 8 s until a
// double tap or Silence, with no time limit (D-029a UPDATE 10:05 PM). No other strap command is ever involved.
//
// Everything in this file is pure data + rules, so it is tested without a phone or a strap. `reconcile` is the one
// entry point the app calls (on every action, every few seconds and on connection events): it returns the things the
// app must DO (schedule / cancel a phone alert, send a buzz); the app reports back what happened.

/// The strap alarm record holds at most this long (repeat 7, 120 s: MGBLE `TimerAlarmPattern.longestSeconds`).
public enum TimerAlarmSpan {
    public static let longestSeconds = 120
}

public enum TimerPulses {
    public static let range = 1...8
    /// Mo: "just buzzes 4 times".
    public static let standard = 4
    public static func clamp(_ n: Int) -> Int { min(range.upperBound, max(range.lowerBound, n)) }
}

public enum TimerState: String, Codable, Equatable, Sendable {
    case running, finished, cancelled
}

/// How a timer's strap buzz ends (D-029a: "double tap to stop or x amount of buzzes, for now 4").
public enum TimerStop: Equatable, Sendable, Codable {
    /// Buzz (4 pulses) every `TimerRing.repeatEvery` until a double tap or Silence. No time limit.
    case doubleTap
    /// One buzz of n pulses (1-8), nothing more.
    case buzzes(Int)

    public static let standard = TimerStop.buzzes(TimerPulses.standard)

    /// Pulses of each buzz.
    public var pulses: Int {
        switch self {
        case .doubleTap: return TimerRing.pulses
        case .buzzes(let n): return TimerPulses.clamp(n)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, n }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "doubleTap": self = .doubleTap
        case "buzzes": self = .buzzes(TimerPulses.clamp((try? c.decode(Int.self, forKey: .n)) ?? TimerPulses.standard))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown stop kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .doubleTap: try c.encode("doubleTap", forKey: .kind)
        case .buzzes(let n): try c.encode("buzzes", forKey: .kind); try c.encode(TimerPulses.clamp(n), forKey: .n)
        }
    }
}

/// The "buzz until double-tapped" rule, pure so it is tested. The strap only ever gets command 19 (one-shot haptic,
/// rule 5) - this decides WHEN to send it again, never a different command. There is NO time limit (Mo, D-029a UPDATE
/// 10:05 PM: "i want to make it annoying so i have to wake up"). It ends only by a tap / Silence, by the timer being
/// cancelled or deleted, or by the app being told to stop; a lost strap pauses it and it resumes on reconnect.
public enum TimerRing {
    /// Pulses of each buzz of a double-tap timer (Mo: "for now 4 is fine").
    public static let pulses = 4
    /// Seconds between the buzzes (the 4-pulse pattern lasts a few seconds; the rest is the gap to tap in).
    public static let repeatEvery: TimeInterval = 8

    public enum Step: Equatable, Sendable {
        /// Nothing now: too soon after the last buzz, or the strap is away (it resumes when the strap is back).
        case wait
        /// Send command 19 again.
        case buzz
        /// The ring is over: silenced by a tap / phone Silence, cancelled, deleted, or the app was told to stop.
        case stop
    }

    /// `lastBuzzAt`: the last send attempt (nil = none yet). `ended`: silenced, cancelled, deleted or told to stop.
    public static func step(lastBuzzAt: Date?, now: Date, strapReady: Bool, ended: Bool) -> Step {
        if ended { return .stop }
        guard strapReady else { return .wait }
        guard let last = lastBuzzAt else { return .buzz }
        return now.timeIntervalSince(last) >= repeatEvery ? .buzz : .wait
    }
}

/// What happened to the strap buzz of one timer.
public enum TimerBuzz: String, Codable, Equatable, Sendable {
    /// Not sent yet (the timer is still running, or the strap was not reachable yet).
    case pending
    /// The command went out; nothing else may send it (a second send would be a duplicate buzz).
    case sending
    /// The strap acknowledged the buzz.
    case sent
    /// Not sent: `lateBuzzGrace` passed (app was not running / strap not connected), or the send failed for good.
    case missed
    /// Cancelled before the buzz.
    case cancelled
    /// Double-tap timer: buzzing now and re-buzzing every `TimerRing.repeatEvery` until tapped / silenced.
    case ringing
    /// Double-tap timer: stopped (a double tap, or Stop / Silence in the app).
    case stopped
}

public struct StrapTimer: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var startedAt: Date
    public var endsAt: Date
    /// How the buzz ends (D-029a). `pulses` below is derived from it and still written to disk for older builds.
    public var stop: TimerStop
    public var state: TimerState
    public var finishedAt: Date?
    public var cancelledAt: Date?
    public var buzz: TimerBuzz
    public var buzzAt: Date?
    /// Why the buzz was missed / the last send failed, in words for the page.
    public var buzzNote: String?
    /// Double-tap timer: when the first buzz of the ring went out.
    public var ringStartedAt: Date?
    /// Double-tap timer: when a tap (or Stop / Silence) ended the ring.
    public var stoppedAt: Date?
    /// The end time the iPhone alert is currently scheduled for (nil = none).
    public var phoneScheduledFor: Date?
    /// The end time the iPhone alert could not be scheduled for, and why (retried only when the end time changes).
    public var phoneFailedFor: Date?
    public var phoneNote: String?
    /// Bug 2 (2026-10-14): the strap alarm slot (2-6, `TimerStrapSlots`) this timer holds, so the strap itself buzzes at the
    /// end with the app in the background. nil = none (no free slot, strap away, or older file).
    public var strapSlot: Int?
    /// The end time + stop choice the slot was last written for (a change of either re-writes it).
    public var strapArmedFor: Date?
    public var strapArmedStop: TimerStop?
    /// An arm is in flight for this end time (no second write until it answers).
    public var strapPendingFor: Date?
    /// The end time the strap refused / failed for, and why (retried on reconnect or when the end changes).
    public var strapFailedFor: Date?
    public var strapNote: String?
    /// The strap reported its own alarm firing near this timer's end (event 57 / 60), so the app records it.
    public var strapFiredAt: Date?
    /// T9816 (C9): when GET_ALARM_TIME read the slot back holding this timer's end ("armed on strap at <time>"). nil = the
    /// strap has not been shown to hold it (a blank with a reason in `strapNote`, never a guess).
    public var strapVerifiedAt: Date?
    /// T9816: the last events of this timer's strap alarm (arm, read-back, failure, retry, fired), newest last, for the next
    /// strap test. Capped at `TimerStrapSlots.logKeep`.
    public var strapLog: [String] = []
    /// When the last arm failed (memory only: after a restart a retry is allowed at once).
    public var strapFailedAt: Date?
    /// Review fix 2/6: true once ANY strap write (SET) was attempted for this slot, even one that failed or could not be read
    /// back: the slot is then "possibly armed" and cancel always sends DISABLE. Persisted.
    public var strapSetAttempted = false
    /// When the last DISABLE failed (or was unconfirmed): the next one waits `retryEvery`. Persisted.
    public var strapClearFailedAt: Date?
    /// Review fix 6: when the last SET was started. Persisted so a relaunch cannot bypass the `retryEvery` throttle.
    public var strapAttemptAt: Date?
    /// Round 5 review: when the last DISABLE was DISPATCHED (not when it failed), persisted, so an app death mid-write cannot
    /// bypass the `retryEvery` throttle.
    public var strapClearAttemptAt: Date?
    /// Round 5 review: bumped on every change that makes an in-flight strap write stale (cancel, extend, stop choice). Memory
    /// only; the app checks it right before dispatching an effect and again when the effect completes.
    public var strapGen = 0

    mutating func addStrapLog(_ line: String, at: Date) {
        strapLog.append(MGFormat.time(at, calendar: .current) + " " + line)
        if strapLog.count > TimerStrapSlots.logKeep { strapLog.removeFirst(strapLog.count - TimerStrapSlots.logKeep) }
    }

    public init(id: UUID = UUID(), label: String, startedAt: Date, endsAt: Date, pulses: Int = TimerPulses.standard,
                stop: TimerStop? = nil) {
        self.id = id
        self.label = label
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.stop = stop ?? .buzzes(TimerPulses.clamp(pulses))
        self.state = .running
        self.buzz = .pending
    }

    /// Pulses of each buzz (1-8).
    public var pulses: Int { stop.pulses }

    enum CodingKeys: String, CodingKey {
        case id, label, startedAt, endsAt, pulses, stop, state, finishedAt, cancelledAt, buzz, buzzAt, buzzNote
        case ringStartedAt, stoppedAt, phoneScheduledFor, phoneFailedFor, phoneNote
        case strapSlot, strapArmedFor, strapArmedStop, strapPendingFor, strapFailedFor, strapNote, strapFiredAt, strapVerifiedAt, strapLog, strapFailedAt, strapSetAttempted, strapAttemptAt, strapClearFailedAt, strapClearAttemptAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endsAt, forKey: .endsAt)
        try c.encode(pulses, forKey: .pulses)          // older builds read this
        try c.encode(stop, forKey: .stop)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encodeIfPresent(cancelledAt, forKey: .cancelledAt)
        try c.encode(buzz, forKey: .buzz)
        try c.encodeIfPresent(buzzAt, forKey: .buzzAt)
        try c.encodeIfPresent(buzzNote, forKey: .buzzNote)
        try c.encodeIfPresent(ringStartedAt, forKey: .ringStartedAt)
        try c.encodeIfPresent(stoppedAt, forKey: .stoppedAt)
        try c.encodeIfPresent(phoneScheduledFor, forKey: .phoneScheduledFor)
        try c.encodeIfPresent(phoneFailedFor, forKey: .phoneFailedFor)
        try c.encodeIfPresent(phoneNote, forKey: .phoneNote)
        try c.encodeIfPresent(strapSlot, forKey: .strapSlot)
        try c.encodeIfPresent(strapArmedFor, forKey: .strapArmedFor)
        try c.encodeIfPresent(strapArmedStop, forKey: .strapArmedStop)
        try c.encodeIfPresent(strapPendingFor, forKey: .strapPendingFor)
        try c.encodeIfPresent(strapFailedFor, forKey: .strapFailedFor)
        try c.encodeIfPresent(strapNote, forKey: .strapNote)
        try c.encodeIfPresent(strapFiredAt, forKey: .strapFiredAt)
        try c.encodeIfPresent(strapVerifiedAt, forKey: .strapVerifiedAt)
        if !strapLog.isEmpty { try c.encode(strapLog, forKey: .strapLog) }
        try c.encodeIfPresent(strapFailedAt, forKey: .strapFailedAt)
        if strapSetAttempted { try c.encode(true, forKey: .strapSetAttempted) }
        try c.encodeIfPresent(strapAttemptAt, forKey: .strapAttemptAt)
        try c.encodeIfPresent(strapClearFailedAt, forKey: .strapClearFailedAt)
        try c.encodeIfPresent(strapClearAttemptAt, forKey: .strapClearAttemptAt)
    }

    /// Field-by-field tolerant, like the alarm settings: a later build can add fields without losing running timers.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        label = c.tolerant(.label, "")
        // An older file has no `stop`: it keeps its pulse count as "x buzzes". An unreadable `stop` does the same.
        let oldPulses = TimerPulses.clamp(c.tolerant(.pulses, TimerPulses.standard))
        stop = ((try? c.decodeIfPresent(TimerStop.self, forKey: .stop)) ?? nil) ?? .buzzes(oldPulses)
        ringStartedAt = (try? c.decodeIfPresent(Date.self, forKey: .ringStartedAt)) ?? nil
        stoppedAt = (try? c.decodeIfPresent(Date.self, forKey: .stoppedAt)) ?? nil
        state = c.tolerant(.state, TimerState.running)
        finishedAt = (try? c.decodeIfPresent(Date.self, forKey: .finishedAt)) ?? nil
        cancelledAt = (try? c.decodeIfPresent(Date.self, forKey: .cancelledAt)) ?? nil
        buzz = c.tolerant(.buzz, TimerBuzz.pending)
        buzzAt = (try? c.decodeIfPresent(Date.self, forKey: .buzzAt)) ?? nil
        buzzNote = (try? c.decodeIfPresent(String.self, forKey: .buzzNote)) ?? nil
        phoneScheduledFor = (try? c.decodeIfPresent(Date.self, forKey: .phoneScheduledFor)) ?? nil
        phoneFailedFor = (try? c.decodeIfPresent(Date.self, forKey: .phoneFailedFor)) ?? nil
        phoneNote = (try? c.decodeIfPresent(String.self, forKey: .phoneNote)) ?? nil
        // Older files have none of the strap-slot fields: no slot held, nothing armed.
        let slot = (try? c.decodeIfPresent(Int.self, forKey: .strapSlot)) ?? nil
        strapSlot = slot.flatMap { TimerStrapSlots.range.contains($0) ? $0 : nil }
        strapArmedFor = (try? c.decodeIfPresent(Date.self, forKey: .strapArmedFor)) ?? nil
        strapArmedStop = (try? c.decodeIfPresent(TimerStop.self, forKey: .strapArmedStop)) ?? nil
        strapPendingFor = nil          // an arm that was in flight when the app died is unknown: try again
        strapFailedFor = (try? c.decodeIfPresent(Date.self, forKey: .strapFailedFor)) ?? nil
        strapNote = (try? c.decodeIfPresent(String.self, forKey: .strapNote)) ?? nil
        strapFiredAt = (try? c.decodeIfPresent(Date.self, forKey: .strapFiredAt)) ?? nil
        strapVerifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .strapVerifiedAt)) ?? nil
        strapLog = (try? c.decodeIfPresent([String].self, forKey: .strapLog)) ?? []
        strapFailedAt = (try? c.decodeIfPresent(Date.self, forKey: .strapFailedAt)) ?? nil
        strapSetAttempted = (try? c.decodeIfPresent(Bool.self, forKey: .strapSetAttempted)) ?? (slot != nil && strapArmedFor != nil)
        strapAttemptAt = (try? c.decodeIfPresent(Date.self, forKey: .strapAttemptAt)) ?? nil
        strapClearFailedAt = (try? c.decodeIfPresent(Date.self, forKey: .strapClearFailedAt)) ?? nil
        strapClearAttemptAt = (try? c.decodeIfPresent(Date.self, forKey: .strapClearAttemptAt)) ?? nil
    }

    public var duration: TimeInterval { endsAt.timeIntervalSince(startedAt) }
    public func remaining(at now: Date) -> TimeInterval { max(0, endsAt.timeIntervalSince(now)) }
}

/// The strap's timer alarm slots (MGBLE `TimerAlarmSlot`: 2-6; slot 1 stays the wake alarm's, Mo e-7 / R-075). Kept as plain
/// numbers here so this package needs nothing from MGBLE.
public enum TimerStrapSlots {
    public static let range = 2...6
    /// A strap alarm lasts at most `TimerAlarmPattern.longestSeconds` (120 s) after its end; the slot is held a little
    /// longer so a new timer can't overwrite one that is still buzzing.
    public static let holdAfterEnd: TimeInterval = 130
    /// How close to a timer's end a strap alarm event (57 / 60) must be to count as that timer's (inclusive: exactly +-180 s counts).
    public static let eventWindow: TimeInterval = 180
    /// T9816: after an armed timer's end the app waits this long for the strap's own "alarm fired" event (57 / 60). None by
    /// then = the strap stayed silent (the Oct 15 test: slot armed and read back, no buzz), and the app buzzes itself.
    public static let fireWait: TimeInterval = 8
    /// An alarm event counts as this timer's firing only from this many seconds before the end (an earlier haptic is not it).
    public static let firedSlack: TimeInterval = 5
    /// Lines kept in a timer's `strapLog`.
    public static let logKeep = 16
    /// Minimum seconds between two retries of a failed arm.
    public static let retryEvery: TimeInterval = 20
}

/// The pending local-notification identifier of a timer (one per timer, so scheduling again replaces it).
public func timerPhoneId(_ id: UUID) -> String { "timers.end.\(id.uuidString)" }

/// What the app must do.
public enum TimerEffect: Equatable, Sendable {
    case schedulePhone(id: UUID, at: Date, title: String, body: String)
    case cancelPhone(id: UUID)
    case buzz(id: UUID, pulses: Int)
    /// Write the strap alarm `slot` for this timer's end (new, extended, or the stop choice changed).
    case armStrap(id: UUID, slot: Int, at: Date, stop: TimerStop)
    /// Clear the strap alarm `slot` (the timer was cancelled).
    case disableStrap(id: UUID, slot: Int)
}

public struct TimersBook: Codable, Equatable, Sendable {
    public static let minutesRange = 1...720
    public static let maxRunning = 8
    /// A strap buzz later than this after the end is not sent: the phone alert already rang and a buzz minutes later
    /// would read as a second, unexplained event.
    public static let lateBuzzGrace: TimeInterval = 120
    /// Finished / cancelled timers stay on the page this long.
    public static let keepFinished: TimeInterval = 86_400

    public var timers: [StrapTimer] = []

    public init(timers: [StrapTimer] = []) { self.timers = timers }

    public var running: [StrapTimer] { timers.filter { $0.state == .running } }

    public func timer(_ id: UUID) -> StrapTimer? { timers.first { $0.id == id } }

    private func index(_ id: UUID) -> Int? { timers.firstIndex { $0.id == id } }

    // MARK: Changes

    /// nil when the length is outside 1-720 minutes or 8 timers already run.
    @discardableResult
    public mutating func start(minutes: Int, pulses: Int = TimerPulses.standard, stop: TimerStop? = nil,
                               label: String = "", now: Date) -> StrapTimer? {
        guard Self.minutesRange.contains(minutes), running.count < Self.maxRunning else { return nil }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = StrapTimer(label: name, startedAt: now, endsAt: now.addingTimeInterval(TimeInterval(minutes) * 60),
                           pulses: pulses, stop: stop)
        timers.append(t)
        return t
    }

    /// Cancels a running timer, or one that finished but whose strap buzz has not gone out yet (so nothing buzzes after).
    public mutating func cancel(_ id: UUID, now: Date) {
        guard let i = index(id), timers[i].state != .cancelled else { return }
        if timers[i].buzz == .ringing { stopRinging(id, now: now); return }      // a ringing one is stopped, not "cancelled"
        timers[i].state = .cancelled
        timers[i].strapGen += 1
        timers[i].cancelledAt = now
        if timers[i].buzz == .pending { timers[i].buzz = .cancelled }
    }

    /// Adds time to a running timer. A timer that already finished starts again from now (the "+5 min" on a ringing
    /// timer); a cancelled one is left alone.
    public mutating func extend(_ id: UUID, minutes: Int, now: Date) {
        guard (1...Self.minutesRange.upperBound).contains(minutes), let i = index(id) else { return }
        switch timers[i].state {
        case .running:
            timers[i].endsAt = timers[i].endsAt.addingTimeInterval(TimeInterval(minutes) * 60)
        case .finished:
            guard running.count < Self.maxRunning else { return }
            timers[i].startedAt = now
            timers[i].endsAt = now.addingTimeInterval(TimeInterval(minutes) * 60)
            timers[i].state = .running
            timers[i].finishedAt = nil
        case .cancelled:
            return
        }
        timers[i].strapGen += 1
        timers[i].buzz = .pending
        timers[i].buzzAt = nil
        timers[i].buzzNote = nil
        timers[i].ringStartedAt = nil
        timers[i].stoppedAt = nil
        timers[i].strapFiredAt = nil
        timers[i].strapNote = nil
    }

    public mutating func setPulses(_ id: UUID, _ pulses: Int) {
        guard let i = index(id), timers[i].state == .running else { return }
        timers[i].stop = .buzzes(TimerPulses.clamp(pulses))
        timers[i].strapGen += 1
    }

    public mutating func setStop(_ id: UUID, _ stop: TimerStop) {
        guard let i = index(id), timers[i].state == .running else { return }
        timers[i].stop = stop
        timers[i].strapGen += 1
    }

    /// Removes a finished / cancelled timer from the page; a running one is cancelled first (kept until its phone
    /// alert is cancelled). Removing a ringing one ends its ring (nothing is left to re-buzz).
    public mutating func clear(_ id: UUID, now: Date) {
        guard let i = index(id) else { return }
        if timers[i].state == .running { cancel(id, now: now) } else {
            // A cancelled timer whose strap alarm is not cleared yet stays until the strap confirms (else the slot would
            // stay armed and nobody would know to clear it).
            if timers[i].state == .cancelled, timers[i].strapSlot != nil { return }
            timers.remove(at: i)
        }
    }

    /// A double tap (event 14) or a buzz that ended by a tap (event 100, cause 2): every ringing timer stops.
    /// Returns false when nothing was ringing, so the tap stays an ordinary double tap.
    @discardableResult
    public mutating func tapped(now: Date) -> Bool {
        let ids = timers.filter { $0.buzz == .ringing }.map(\.id)
        for id in ids { stopRinging(id, now: now) }
        var stopped = !ids.isEmpty
        // Bug 2: a double-tap timer whose STRAP alarm is buzzing (slot 2-6, armed for this end) may not have been marked
        // ringing yet (the app was woken only for the tap). Within the alarm's span the tap stops it and the app records it.
        for i in timers.indices {
            let t = timers[i]
            guard t.stop == .doubleTap, let slot = t.strapSlot, t.strapArmedFor == t.endsAt, t.buzz == .pending,
                  t.state != .cancelled, now >= t.endsAt.addingTimeInterval(-1),
                  now <= t.endsAt.addingTimeInterval(TimerStrapSlots.holdAfterEnd) else { continue }
            if t.state == .running { timers[i].state = .finished; timers[i].finishedAt = t.endsAt }
            timers[i].buzz = .stopped
            timers[i].stoppedAt = now
            timers[i].strapNote = "stopped by a double tap while the strap's own alarm (slot \(slot)) was buzzing — "
                + "decoded, untested: whether the strap itself ends the buzz on a tap"
            stopped = true
        }
        return stopped
    }

    /// Strap events 57 / 60 (its own alarm fired / haptics fired) near a timer's end: the app records that the strap alarm
    /// of that timer went off. The events carry no slot number (decoded, untested), so the time decides.
    @discardableResult
    public mutating func strapAlarmFired(at: Date) -> Bool {
        var did = false
        for i in timers.indices where timers[i].strapSlot != nil
            && (timers[i].strapFiredAt.map { $0 < timers[i].endsAt.addingTimeInterval(-TimerStrapSlots.firedSlack) } ?? true)
            && abs(at.timeIntervalSince(timers[i].endsAt)) <= TimerStrapSlots.eventWindow {
            timers[i].strapFiredAt = at
            timers[i].addStrapLog("strap alarm fired (event 57/60), \(Int(at.timeIntervalSince(timers[i].endsAt))) s "
                                  + "after the timer's end", at: at)
            did = true
        }
        return did
    }

    /// Stop / Silence for one ringing timer (the phone's button, or a tap). No effect on a timer that is not ringing.
    public mutating func stopRinging(_ id: UUID, now: Date) {
        guard let i = index(id), timers[i].buzz == .ringing else { return }
        timers[i].buzz = .stopped
        timers[i].stoppedAt = now
        timers[i].buzzNote = nil
    }

    /// The phone's Silence button: every ringing timer stops. True when one did.
    @discardableResult
    public mutating func silenceAll(now: Date) -> Bool { tapped(now: now) }

    // MARK: Results the app reports back

    public mutating func phoneScheduled(_ id: UUID, at: Date) {
        guard let i = index(id) else { return }
        timers[i].phoneScheduledFor = at
        timers[i].phoneFailedFor = nil
        timers[i].phoneNote = nil
    }

    public mutating func phoneFailed(_ id: UUID, at: Date, note: String) {
        guard let i = index(id) else { return }
        timers[i].phoneFailedFor = at
        timers[i].phoneNote = note
    }

    public mutating func phoneCancelled(_ id: UUID) {
        guard let i = index(id) else { return }
        timers[i].phoneScheduledFor = nil
    }

    /// Event 56-60 / 100 seen near this timer's end: one log line (diagnostics for the next strap test).
    public mutating func noteStrapEvent(_ id: UUID, number: Int, at: Date) {
        guard let i = index(id) else { return }
        timers[i].addStrapLog("strap event \(number), \(Int(at.timeIntervalSince(timers[i].endsAt))) s from the end", at: at)
    }

    /// Review fix 9: an event 56-60 / 100 is logged on EVERY timer that is running or still holding / retrying a strap slot
    /// (no time window: a timer ending later is retried on that event too). True when any line was added.
    @discardableResult
    public mutating func noteStrapEventAll(number: Int, at: Date) -> Bool {
        var did = false
        for i in timers.indices where timers[i].state == .running || timers[i].strapSlot != nil || timers[i].strapFailedFor != nil {
            timers[i].addStrapLog("strap event \(number), \(Int(at.timeIntervalSince(timers[i].endsAt))) s from the end", at: at)
            did = true
        }
        return did
    }

    /// The strap took the arm for this end time and stop choice.
    /// The row then says "armed on strap at <time>".
    /// `verifiedAt` is required: a timer is only "armed" once the slot was read back (round 5 review 4). `gen`: the timer's
    /// `strapGen` when the effect was handed out; a different value means the timer changed meanwhile, so the result is stale.
    public mutating func strapArmed(_ id: UUID, at: Date, stop: TimerStop, verifiedAt: Date, gen: Int? = nil) {
        guard let i = index(id) else { return }
        if timers[i].strapPendingFor == at { timers[i].strapPendingFor = nil }
        timers[i].strapArmedFor = at
        timers[i].strapArmedStop = stop
        // Review fix 1: a completion for an end / state the timer no longer has is STALE. The slot holds that old alarm, so
        // it stays "possibly armed" (cancel disables it, an extension rewrites it) but is never shown as armed or verified.
        if timers[i].state != .running || timers[i].endsAt != at || timers[i].stop != stop || gen.map({ $0 != timers[i].strapGen }) == true {
            timers[i].strapSetAttempted = true
            timers[i].strapVerifiedAt = nil
            timers[i].addStrapLog("stale arm result for \(MGFormat.time(at, calendar: .current)) discarded (timer changed)",
                                  at: verifiedAt)
            return
        }
        timers[i].strapFailedFor = nil
        timers[i].strapNote = nil
        timers[i].strapVerifiedAt = verifiedAt
        timers[i].addStrapLog("armed on strap, slot \(timers[i].strapSlot.map(String.init) ?? "?"), read-back matches",
                              at: verifiedAt)
    }

    /// The strap said ok to the write but the slot did not read back holding this timer (or could not be read): NOT armed
    /// as far as anyone can prove. Shown loudly; retried like a failure.
    public mutating func strapArmUnverified(_ id: UUID, at: Date, note: String, now: Date) {
        strapArmFailed(id, at: at, note: note, now: now)
    }

    /// A foreground / BLE-woken / reconnect moment: running timers that failed to arm try again now (at most one try per
    /// `TimerStrapSlots.retryEvery`). Returns true when something was re-opened.
    @discardableResult
    public mutating func strapRetry(now: Date) -> Bool {
        var did = false
        for i in timers.indices where timers[i].state == .running && timers[i].strapFailedFor != nil
            && timers[i].strapPendingFor == nil
            && timers[i].strapFailedAt.map({ now.timeIntervalSince($0) >= TimerStrapSlots.retryEvery }) ?? true {
            timers[i].strapFailedFor = nil
            timers[i].addStrapLog("retrying the strap arm", at: now)
            did = true
        }
        return did
    }

    /// The arm failed (or was refused): phone alert + app buzz carry on; retried on reconnect or when the end changes.
    public mutating func strapArmFailed(_ id: UUID, at: Date, note: String, now: Date = Date()) {
        guard let i = index(id) else { return }
        if timers[i].strapPendingFor == at { timers[i].strapPendingFor = nil }
        timers[i].strapArmedFor = timers[i].strapArmedFor == at ? nil : timers[i].strapArmedFor
        timers[i].strapFailedFor = at
        timers[i].strapFailedAt = now
        timers[i].strapVerifiedAt = nil
        timers[i].strapNote = "not armed on strap: " + note
        timers[i].addStrapLog("NOT armed on strap: " + note, at: now)
    }

    /// The strap slot was cleared (cancel): the slot is free again.
    public mutating func strapDisabled(_ id: UUID) {
        guard let i = index(id) else { return }
        timers[i].strapPendingFor = nil
        timers[i].strapSlot = nil
        timers[i].strapArmedFor = nil
        timers[i].strapArmedStop = nil
        timers[i].strapVerifiedAt = nil
        timers[i].strapSetAttempted = false
        timers[i].strapClearFailedAt = nil
        timers[i].strapClearAttemptAt = nil
        timers[i].strapNote = nil
    }

    /// A failed / unconfirmed DISABLE: the slot stays held and `reconcile` sends DISABLE again `retryEvery` later.
    public mutating func strapDisableFailed(_ id: UUID, note: String, now: Date = Date()) {
        guard let i = index(id) else { return }
        timers[i].strapPendingFor = nil
        timers[i].strapClearFailedAt = now
        timers[i].strapVerifiedAt = nil
        timers[i].strapNote = "the strap alarm could not be cleared yet: " + note
    }

    /// A new strap connection: the strap may have lost or kept its slots, so every timer that still needs one is checked
    /// and written again (the link does not rewrite a slot that already holds the same time).
    public mutating func strapReconnected() {
        // Review fix 5: in-flight and failure state is KEPT (clearing it would duplicate writes and skip the retry gate).
        for i in timers.indices where timers[i].state == .running {
            timers[i].strapArmedFor = nil; timers[i].strapArmedStop = nil; timers[i].strapVerifiedAt = nil
        }
    }

    /// True when `effect` (handed out under `gen`) still describes the timer: same generation, and the timer is still
    /// running (arm) or cancelled (disable). Checked right before the write is dispatched.
    public func strapEffectCurrent(_ effect: TimerEffect, gen: Int?) -> Bool {
        switch effect {
        case let .armStrap(id, _, at, stop):
            guard let t = timer(id) else { return false }
            return t.strapGen == gen && t.state == .running && t.endsAt == at && t.stop == stop
        case let .disableStrap(id, _):
            guard let t = timer(id) else { return false }
            return t.strapGen == gen && t.state == .cancelled
        default: return true
        }
    }

    /// A strap effect was dropped before it was sent (stale): release its reservation so the next tick decides again.
    public mutating func strapEffectDropped(_ effect: TimerEffect) {
        switch effect {
        case let .armStrap(id, _, _, _):
            guard let i = index(id) else { return }
            timers[i].strapPendingFor = nil
            timers[i].strapAttemptAt = nil
        case let .disableStrap(id, _):
            guard let i = index(id) else { return }
            timers[i].strapPendingFor = nil
            timers[i].strapClearAttemptAt = nil
        default: break
        }
    }

    public mutating func buzzSent(_ id: UUID, at: Date) {
        guard let i = index(id) else { return }
        // A ringing (double-tap) timer stays ringing: only a tap / Silence ends it. A late ack after the tap changes nothing.
        if timers[i].buzz != .ringing && timers[i].buzz != .stopped { timers[i].buzz = .sent }
        timers[i].buzzAt = at
        timers[i].buzzNote = nil
    }

    /// The send failed. Inside the grace window it is tried again (back to pending); after it, it is missed.
    /// A ringing timer just keeps the note: the next repeat (8 s later) tries again.
    public mutating func buzzFailed(_ id: UUID, now: Date, note: String) {
        guard let i = index(id) else { return }
        if timers[i].buzz == .ringing { timers[i].buzzNote = note; return }
        guard timers[i].buzz == .sending else { return }
        timers[i].buzzNote = note
        timers[i].buzz = now.timeIntervalSince(timers[i].endsAt) <= Self.lateBuzzGrace ? .pending : .missed
    }

    // MARK: The one rule engine

    /// Finishes due timers, gives up on late buzzes, forgets old rows, and returns what the app must do now.
    /// `strapReady`: the strap is connected and accepts commands. Call it often; it is cheap and repeatable (a buzz
    /// is returned once: the timer is marked `.sending` at that moment).
    public mutating func reconcile(now: Date, strapReady: Bool) -> [TimerEffect] {
        var out: [TimerEffect] = []
        for i in timers.indices {
            if timers[i].state == .running, timers[i].endsAt <= now {
                timers[i].state = .finished
                timers[i].finishedAt = timers[i].endsAt
            }
            let late = now.timeIntervalSince(timers[i].endsAt)
            switch timers[i].state {
            case .running:
                let t = timers[i]
                if t.phoneScheduledFor != t.endsAt, t.phoneFailedFor != t.endsAt {
                    out.append(.schedulePhone(id: t.id, at: t.endsAt, title: Self.title(t),
                                              body: "Timer finished."))
                }
                if let e = armEffect(i, now: now, strapReady: strapReady) { out.append(e) }
            case .cancelled:
                if timers[i].phoneScheduledFor != nil { out.append(.cancelPhone(id: timers[i].id)) }
                let t = timers[i]
                if let slot = t.strapSlot, t.strapPendingFor == nil {
                    if t.strapArmedFor == nil && !t.strapSetAttempted {
                        timers[i].strapSlot = nil                       // never written: nothing to clear
                    } else if strapReady, t.strapClearAttemptAt.map({ now.timeIntervalSince($0) >= TimerStrapSlots.retryEvery }) ?? true {
                        timers[i].strapPendingFor = t.endsAt
                        timers[i].strapClearAttemptAt = now
                        out.append(.disableStrap(id: t.id, slot: slot))
                    }
                }
            case .finished:
                // The strap's own alarm clears itself when it fires; its slot is held until it can no longer be buzzing.
                if timers[i].strapSlot != nil, timers[i].strapPendingFor == nil,
                   late > TimerStrapSlots.holdAfterEnd {
                    timers[i].strapSlot = nil
                    timers[i].strapArmedFor = nil
                    timers[i].strapArmedStop = nil
                }
                let armedSlot: Int? = timers[i].strapArmedFor == timers[i].endsAt && timers[i].strapVerifiedAt != nil ? timers[i].strapSlot : nil
                switch timers[i].buzz {
                case .pending:
                    if late > Self.lateBuzzGrace {
                        timers[i].buzz = .missed
                        timers[i].buzzNote = timers[i].buzzNote ?? (armedSlot.map {
                            "the strap's own alarm (slot \($0)) was set for the end; this app was not connected then and "
                                + "cannot confirm it buzzed"
                        } ?? "the strap could not be reached within \(Int(Self.lateBuzzGrace / 60)) min of the end")
                    } else if strapReady, let slot = armedSlot, !Self.strapSpoke(timers[i]) {
                        // T9816 (Oct 15: slot armed and read back, the strap never buzzed, and the app stayed silent because it
                        // trusted the slot). The strap gets `fireWait` seconds to report its own alarm firing (event 57 / 60);
                        // none by then and the app buzzes itself, and says so on the timer.
                        if late >= TimerStrapSlots.fireWait {
                            let note = "the strap's own alarm (slot \(slot)) reported no firing within "
                                + "\(Int(TimerStrapSlots.fireWait)) s of the end (no event 57 / 60); buzzed from the app instead"
                            timers[i].buzzNote = note
                            timers[i].addStrapLog(note, at: now)
                            out.append(startAppBuzz(i, now: now))
                        }
                    } else if strapReady, let slot = armedSlot {
                        // The strap's own alarm buzzes now: the app must not buzz on top of it. "x buzzes": done.
                        // "double tap": the app's 4 / pause / 4 loop takes over after the strap alarm's longest span (120 s)
                        // while the app is alive.
                        if timers[i].stop == .doubleTap {
                            timers[i].buzz = .ringing
                            timers[i].ringStartedAt = now
                            timers[i].buzzAt = timers[i].endsAt.addingTimeInterval(TimeInterval(TimerAlarmSpan.longestSeconds))
                        } else {
                            timers[i].buzz = .sent
                            timers[i].buzzAt = timers[i].endsAt
                            timers[i].buzzNote = "buzzed by the strap's own alarm (slot \(slot))"
                        }
                    } else if strapReady {
                        out.append(startAppBuzz(i, now: now))
                    }
                case .ringing:
                    switch TimerRing.step(lastBuzzAt: timers[i].buzzAt, now: now, strapReady: strapReady,
                                          ended: timers[i].stoppedAt != nil) {
                    case .buzz:
                        timers[i].buzzAt = now
                        out.append(.buzz(id: timers[i].id, pulses: timers[i].pulses))
                    case .wait, .stop: break
                    }
                case .sending:
                    // Still unanswered long after: assume nothing, never re-send (a duplicate buzz is worse).
                    if late > Self.lateBuzzGrace {
                        timers[i].buzz = .missed
                        timers[i].buzzNote = "no answer from the strap — not sent again"
                    }
                case .sent, .missed, .cancelled, .stopped: break
                }
            }
        }
        timers.removeAll { t in
            t.state != .running && t.phoneScheduledFor == nil && t.strapSlot == nil
                && now.timeIntervalSince(t.finishedAt ?? t.cancelledAt ?? t.endsAt) > Self.keepFinished
        }
        return out
    }

    /// True when the strap reported its own alarm firing for this timer's end (event 57 / 60 from `firedSlack` before it).
    static func strapSpoke(_ t: StrapTimer) -> Bool {
        t.strapFiredAt.map { $0 >= t.endsAt.addingTimeInterval(-TimerStrapSlots.firedSlack) } ?? false
    }

    /// The app's own strap buzz for a finished timer: "x buzzes" is sent once; "double tap" rings (re-sent every 8 s) until
    /// tapped / silenced. Returns the effect to hand out.
    private mutating func startAppBuzz(_ i: Int, now: Date) -> TimerEffect {
        if timers[i].stop == .doubleTap {
            // Buzz until tapped: stays `.ringing`; `buzzAt` is the last attempt (reserved here).
            timers[i].buzz = .ringing
            timers[i].ringStartedAt = now
            timers[i].buzzAt = now
        } else {
            timers[i].buzz = .sending
        }
        return .buzz(id: timers[i].id, pulses: timers[i].pulses)
    }

    /// The strap alarm write this running timer needs now, if any (allocates the lowest free slot 2-6 and reserves it).
    private mutating func armEffect(_ i: Int, now: Date, strapReady: Bool) -> TimerEffect? {
        let t = timers[i]
        guard strapReady, t.strapPendingFor != t.endsAt, t.strapFailedFor != t.endsAt,
              t.strapArmedFor != t.endsAt || t.strapArmedStop != t.stop,
              t.endsAt.timeIntervalSince(now) >= Self.strapArmMinLead,
              t.strapAttemptAt.map({ now.timeIntervalSince($0) >= TimerStrapSlots.retryEvery }) ?? true else { return nil }
        let slot: Int
        if let held = t.strapSlot { slot = held } else {
            let used = Set(timers.compactMap(\.strapSlot))
            guard let free = TimerStrapSlots.range.first(where: { !used.contains($0) }) else {
                let note = "all \(TimerStrapSlots.range.count) strap timer slots are in use: this timer has the phone alert "
                    + "and the in-app buzz only"
                if timers[i].strapNote != note { timers[i].strapNote = note }
                return nil
            }
            slot = free
        }
        timers[i].strapSlot = slot
        timers[i].strapPendingFor = t.endsAt
        timers[i].strapAttemptAt = now
        timers[i].strapSetAttempted = true
        timers[i].strapNote = nil
        return .armStrap(id: t.id, slot: slot, at: t.endsAt, stop: t.stop)
    }

    /// The link refuses an alarm less than 10 s away; a little more here so the request is not turned down in flight.
    public static let strapArmMinLead: TimeInterval = 15

    static func title(_ t: StrapTimer) -> String { t.label.isEmpty ? "Timer" : t.label }
}
