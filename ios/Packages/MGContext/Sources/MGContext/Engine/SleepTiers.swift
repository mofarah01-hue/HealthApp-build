import Foundation

// Sleep tiers (Mo 2026-10-14, round 4 items 1-4; DECISIONS D-9745).
//   S  tiny, live, DISPLAY STATE ONLY: flips Today to "asleep" within minutes. Never stored, never reported as sleep.
//   M  on-phone fused stager ALG-151 (MGSignal FusedStager, base tier): strap sleep / wake flag for asleep / awake / totals, PSG-trained stages
//      inside the strap's asleep epochs, stages labelled low confidence. The primary sleep result.
//   L  the PC model(s) (wav2sleep, SleepECG, ...) when they arrive.
// Pure functions over plain values, so they are tested without a strap.

/// Tier S. One live reading per strap record: the band's sleep state (R18 byte 81, (b >> 4) & 3: 0 wake, 1 still,
/// 2 asleep, 3 up; nil on a WHOOP 4.0 or a record without the byte), heart rate, and whether the wrist was still.
public struct LiveSleepSample: Equatable, Sendable {
    public var at: Date
    public var bandState: Int?
    public var hr: Double?
    public var still: Bool?

    public init(at: Date, bandState: Int?, hr: Double? = nil, still: Bool? = nil) {
        self.at = at
        self.bandState = bandState
        self.hr = hr
        self.still = still
    }
}

public enum SleepOnsetDetector {
    /// Asleep is declared once the last `confirmSeconds` agree (at least `coverage` of the window has samples).
    public static let confirmSeconds: TimeInterval = 5 * 60
    public static let coverage = 0.5
    /// Flag rule: this share of the window's samples say "asleep" (state 2) and none say up / awake (0, 3).
    public static let asleepShare = 0.8
    /// No-flag fallback (no byte 81): still the whole window AND median HR of the window at least this far under the
    /// median of the 30 min before it. 5 bpm is my choice, not a source's; it only changes a display line.
    public static let hrDropBpm = 5.0

    /// The time Today should say Mo fell asleep, or nil while not detected. `samples` oldest first, up to `now`.
    /// Not sleep data: nothing here is stored or reported; the real night comes from the night pipeline later.
    public static func asleepSince(_ samples: [LiveSleepSample], now: Date) -> Date? {
        let win = samples.filter { $0.at <= now && $0.at > now.addingTimeInterval(-confirmSeconds) }
        guard let firstSeen = win.first?.at, now.timeIntervalSince(firstSeen) >= confirmSeconds * coverage else { return nil }
        let withFlag = win.compactMap(\.bandState)
        if !withFlag.isEmpty {
            guard withFlag.count >= win.count / 2, !withFlag.contains(where: { $0 == 0 || $0 == 3 }) else { return nil }
            guard Double(withFlag.filter { $0 == 2 }.count) / Double(withFlag.count) >= asleepShare else { return nil }
            // since = start of the unbroken run of asleep / still samples that ends now
            var since = win.first(where: { $0.bandState == 2 })?.at ?? firstSeen
            for s in samples.reversed() where s.at <= now {
                guard let b = s.bandState else { continue }
                if b == 2 || b == 1 { since = s.at } else { break }
            }
            return since
        }
        // no flag byte: motion + HR trend
        guard win.count >= 3, win.allSatisfy({ $0.still == true }) else { return nil }
        let hrNow = median(win.compactMap(\.hr))
        let before = samples.filter {
            $0.at <= now.addingTimeInterval(-confirmSeconds) && $0.at > now.addingTimeInterval(-confirmSeconds - 1800)
        }.compactMap(\.hr)
        guard let hn = hrNow, let hb = median(before), hb - hn >= hrDropBpm else { return nil }
        return firstSeen
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// What Today believes about Mo right now, from the strap's sleep flag (tier S, display only).
public enum LiveSleepState: Equatable, Sendable {
    case unknown
    /// Asleep since this time. Latched: a brief awakening or a gap in the data does not end it.
    case asleep(since: Date)
    /// Was asleep and has been awake for the confirm window; `at` = when the awake run began. Holds for one hour.
    case awake(since: Date)

    public var asleepSince: Date? { if case let .asleep(d) = self { return d }; return nil }
    public var awakeSince: Date? { if case let .awake(d) = self { return d }; return nil }
}

extension SleepOnsetDetector {
    /// Wake is declared after this much continuous awake / up flag, and Today stays out of "bedtime" talk for this long after.
    public static let wakeConfirmSeconds: TimeInterval = 5 * 60
    public static let afterWakeQuiet: TimeInterval = 3600
    /// Data older than this no longer holds a state (strap off / out of range for good).
    public static let staleSeconds: TimeInterval = 45 * 60
    static let step: TimeInterval = 30

    /// Hysteresis over `asleepSince`: asleep is declared by the onset rule and kept until the flag says awake / up for
    /// `wakeConfirmSeconds` straight (>= `asleepShare` of a window with enough samples); a window without enough
    /// samples (offload lag, gap) changes nothing. `samples` oldest first.
    public static func liveState(_ samples: [LiveSleepSample], now: Date) -> LiveSleepState {
        let all = samples.filter { $0.at <= now }.sorted { $0.at < $1.at }
        guard let first = all.first, let last = all.last else { return .unknown }
        if now.timeIntervalSince(last.at) > staleSeconds { return .unknown }
        var state = LiveSleepState.unknown
        var t = first.at.addingTimeInterval(confirmSeconds * coverage)
        var times: [Date] = []
        while t < now { times.append(t); t = t.addingTimeInterval(step) }
        times.append(now)
        for e in times {
            switch state {
            case .asleep:
                if let w = awakeRunStart(all, at: e) { state = .awake(since: w) }
            default:
                if let a = asleepSince(all, now: e) { state = .asleep(since: a) }
                else if case let .awake(w) = state, e.timeIntervalSince(w) > afterWakeQuiet { state = .unknown }
            }
        }
        if case let .awake(w) = state, now.timeIntervalSince(w) > afterWakeQuiet { return .unknown }
        return state
    }

    /// Start of the unbroken awake / up run ending at `e`, when the last `wakeConfirmSeconds` confirm it; else nil.
    static func awakeRunStart(_ all: [LiveSleepSample], at e: Date) -> Date? {
        let win = all.filter { $0.at <= e && $0.at > e.addingTimeInterval(-wakeConfirmSeconds) }
        guard let seen = win.first?.at, e.timeIntervalSince(seen) >= wakeConfirmSeconds * coverage else { return nil }
        let flagged = win.compactMap(\.bandState)
        guard flagged.count >= max(1, win.count / 2) else { return nil }
        let awake = flagged.filter { $0 == 0 || $0 == 3 }.count
        guard Double(awake) / Double(flagged.count) >= asleepShare else { return nil }
        var since = seen
        for s in all.reversed() where s.at <= e {
            guard let b = s.bandState else { continue }
            if b == 0 || b == 3 { since = s.at } else { break }
        }
        return since
    }
}

/// Which tier's sleep Today shows, and the label that says so (item 2).
public enum SleepTiering {
    public enum Tier: String, Sendable { case m = "M", l = "L" }

    public struct Choice: Equatable, Sendable {
        /// nil = neither tier has a night (the caller shows its own blank with its reason).
        public var tier: Tier?
        public var label: String
    }

    /// If the PC result is not back this long after a confirmed wake, say so while showing M.
    public static let lateAfterWake: TimeInterval = 30 * 60

    /// L replaces M the moment it arrives. Until then M is shown with its tier named; when the PC is unreachable
    /// (no Tailscale) or L is more than 30 min late after a confirmed wake, the label says why M is what is shown.
    public static func choose(mAvailable: Bool, lArrived: Bool, confirmedWake: Date?, now: Date,
                              pcReachable: Bool) -> Choice {
        if lArrived { return Choice(tier: .l, label: "Tier L: PC model") }
        guard mAvailable else { return Choice(tier: nil, label: "no sleep tier has a night yet") }
        let m = "Tier M: on-phone, stages low confidence"
        if !pcReachable { return Choice(tier: .m, label: m + " · PC not reachable, showing the phone's result") }
        if let w = confirmedWake, now.timeIntervalSince(w) > lateAfterWake {
            return Choice(tier: .m, label: m + " · PC model is more than 30 min late, showing the phone's result")
        }
        return Choice(tier: .m, label: m + " · PC model not back yet")
    }
}
