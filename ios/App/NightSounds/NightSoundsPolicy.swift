import Foundation

// When night sounds may listen (WP-26): the Tonight toggle, bedtime -> wake window, the strap's awake/asleep reading
// and the phone battery. Pure Foundation, stateless apart from the small strap tracker, so the decision is a
// function of its inputs and is mirrored in the Python check.
//
// Rules (BRIEF WP-26, PLAN 8, ARCHITECTURE 4.11 "night sounds while recording (opt-in only)"):
//   * nothing runs unless the Tonight switch is on, and the microphone is granted;
//   * never before bedtime (the evening has other people and a TV in it): start = max(bedtime, moment it was armed);
//   * stops at the end of the window (wake plan) and at most `maxWindowHours` after bedtime;
//   * battery-aware: once the strap has said ASLEEP at least once tonight, a continuous AWAKE stretch of
//     `awakeStopMinutes` (30) stops it - Mo is up, nothing left to hear. It listens again if the strap says asleep
//     again inside the window. Before the first asleep reading, being awake never stops it (falling asleep can
//     take a while and the snoring comes later);
//   * low phone battery (< `lowBatteryLevel`, not charging) stops it.
//
// WRITTEN, NOT COMPILED.

enum NightSoundsPermission: String, Sendable {
    case undetermined = "undetermined"
    case denied = "denied"
    case granted = "granted"
}

/// What the strap's live stager (WP-11) or R18 sleep state says right now. `unknown` = off wrist, disconnected or no
/// output yet: it changes nothing (the last known state stays).
enum NightSoundsStrapReading: String, Sendable {
    case asleep = "asleep"
    case awake = "awake"
    case unknown = "unknown"
}

struct NightSoundsPolicyParams: Equatable, Sendable {
    /// BRIEF: "stop when the strap says awake for 30 min".
    var awakeStopMinutes: Double = 30
    /// PLACEHOLDER: Mo sets.
    var lowBatteryLevel: Double = 0.15
    /// Hard ceiling on a night's window, whatever the wake plan says.
    var maxWindowHours: Double = 14
    /// Window length when no wake plan exists (blank "must be up by"): bedtime + this.
    var defaultWindowHours: Double = 10
    /// Re-evaluate at least this often while listening (heartbeat for the session log, retry of a failed start).
    var tickSeconds: Double = 30
}

/// Tracks "has the strap said asleep tonight" and "since when has it said awake, without a break".
struct NightSoundsStrapTracker: Equatable, Sendable {
    private(set) var sleptSeen = false
    private(set) var awakeSince: Date?

    init() {}

    mutating func feed(_ reading: NightSoundsStrapReading, at: Date) {
        switch reading {
        case .asleep:
            sleptSeen = true
            awakeSince = nil
        case .awake:
            if awakeSince == nil { awakeSince = at }
        case .unknown:
            break
        }
    }

    mutating func reset() {
        sleptSeen = false
        awakeSince = nil
    }

    /// Minutes of continuous awake, or nil if not awake (or never reported).
    func awakeMinutes(now: Date) -> Double? {
        guard let since = awakeSince else { return nil }
        return max(0, now.timeIntervalSince(since)) / 60
    }
}

enum NightSoundsIdleReason: Equatable, Sendable {
    case off
    case noMicrophone
    case beforeBedtime(startsAt: Date)
    case windowOver
    case strapAwake(since: Date)
    case lowBattery
}

enum NightSoundsDecision: Equatable, Sendable {
    case listen
    case idle(NightSoundsIdleReason)
}

struct NightSoundsPolicyInput: Sendable {
    var now: Date
    /// The Tonight "Listen tonight" switch.
    var enabled: Bool
    /// When the switch went on; nil = unknown (treated as before bedtime).
    var armedAt: Date?
    var bedtime: Date
    /// End of the listening window (wake plan). nil = bedtime + `defaultWindowHours`.
    var windowEnd: Date?
    var microphone: NightSoundsPermission
    var strap: NightSoundsStrapTracker
    /// 0...1, nil = unknown.
    var batteryLevel: Double?
    var charging: Bool?
}

enum NightSoundsPolicy {
    /// First moment listening may start: never before bedtime, and not before the switch went on.
    static func listeningStart(bedtime: Date, armedAt: Date?) -> Date {
        guard let armed = armedAt else { return bedtime }
        return max(bedtime, armed)
    }

    static func listeningEnd(bedtime: Date, windowEnd: Date?, params: NightSoundsPolicyParams) -> Date {
        let ceiling = bedtime.addingTimeInterval(params.maxWindowHours * 3600)
        let planned = windowEnd ?? bedtime.addingTimeInterval(params.defaultWindowHours * 3600)
        return min(planned, ceiling)
    }

    static func decide(_ i: NightSoundsPolicyInput, params: NightSoundsPolicyParams = NightSoundsPolicyParams())
        -> NightSoundsDecision {
        guard i.enabled else { return .idle(.off) }
        guard i.microphone == .granted else { return .idle(.noMicrophone) }

        let start = listeningStart(bedtime: i.bedtime, armedAt: i.armedAt)
        let end = listeningEnd(bedtime: i.bedtime, windowEnd: i.windowEnd, params: params)
        if i.now < start { return .idle(.beforeBedtime(startsAt: start)) }
        if i.now >= end { return .idle(.windowOver) }

        if i.strap.sleptSeen, let since = i.strap.awakeSince,
           i.now.timeIntervalSince(since) >= params.awakeStopMinutes * 60 {
            return .idle(.strapAwake(since: since))
        }
        if let level = i.batteryLevel, level < params.lowBatteryLevel, i.charging != true {
            return .idle(.lowBattery)
        }
        return .listen
    }
}
