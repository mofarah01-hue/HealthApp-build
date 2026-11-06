import Foundation
import MGDomain

/// Why a wake window was narrowed to its last 15 min.
public enum SmartWakeNarrowReason: String, Sendable, Codable {
    /// Tonight's need is not met by the time the window opens (ALG-115 need known).
    case shortNight = "short_night"
    /// Armed after bedtime B with the need unknown (the Late-night phase).
    case pastBedtime = "past_bedtime"
}

/// T9841 (R-097, decision e-17): the optional smart-wake modes. `.window` is the original rule and stays the default; the
/// others widen the window up to `capMinutes` (90) before L, but only when tonight's sleep need is known, and never let
/// the ring come before `minRestFraction` of that need could have been slept (e-17: "minimum rest % plus a 90-minute cap";
/// 75 % unless Mo changes it). With the need unknown a widened mode falls back to the standard window, because a ring that
/// could not tell how much rest he had must not come early. The fire rule inside the window is unchanged (ours, v0).
/// Python twin: `plan_wake` in pclab/mglab/ref/sleep_live.py takes the same three extra arguments before the goldens
/// cover these modes (default arguments reproduce the goldens exactly).
public struct SmartWakeOptions: Equatable, Sendable, Codable {
    public enum Mode: String, Sendable, Codable, CaseIterable {
        /// L minus the 10-45 min setting (the original rule).
        case window
        /// Not before a clock time (`gateAt`), up to `capMinutes` before L. No gate set = `.open`.
        case timeGate
        /// Open from `capMinutes` before L (the cap), once the minimum rest could be slept.
        case open
        /// Only once tonight's whole sleep need could be slept (fraction 1), up to `capMinutes` before L.
        case needMet
    }

    public static let capMinutes = 90
    public static let minRestRange = 0.5...1.0

    public var mode: Mode
    /// Unix seconds; `.timeGate` only.
    public var gateAt: Int64?
    /// Share of tonight's need that must be slept before a widened window may open (0.5...1).
    public var minRestFraction: Double

    public init(mode: Mode = .window, gateAt: Int64? = nil, minRestFraction: Double = 0.75) {
        self.mode = mode
        self.gateAt = gateAt
        self.minRestFraction = minRestFraction
    }

    public static let standard = SmartWakeOptions()
}

/// Tonight's wake plan (ALG-035 v0, UX-SPEC 8.1, ARCHITECTURE 4.11). Times are unix seconds.
public struct SmartWakePlan: Equatable, Sendable, Codable {
    public var windowStart: Int64
    /// L, the "must be up by" time.
    public var windowEnd: Int64
    /// Always L: rings even if the app is killed.
    public var backstopAt: Int64
    /// The setting after the 10–45 clamp.
    public var setWindowMinutes: Int
    public var windowMinutes: Double
    public var narrowed: Bool
    public var narrowReason: SmartWakeNarrowReason?
    /// Armed inside the window: watching starts at the next epoch boundary.
    public var armedLate: Bool
    public var expectedOnset: Int64

    public init(windowStart: Int64, windowEnd: Int64, backstopAt: Int64, setWindowMinutes: Int, windowMinutes: Double,
                narrowed: Bool, narrowReason: SmartWakeNarrowReason?, armedLate: Bool, expectedOnset: Int64) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.backstopAt = backstopAt
        self.setWindowMinutes = setWindowMinutes
        self.windowMinutes = windowMinutes
        self.narrowed = narrowed
        self.narrowReason = narrowReason
        self.armedLate = armedLate
        self.expectedOnset = expectedOnset
    }
}

/// What happened at wake, for the morning row, the check-in and the G-INERTIA label (stage at wake).
public struct SmartWakeOutcome: Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case smart = "smart"
        case backstop = "backstop"
        case noPlan = "no_plan"
    }

    public enum Reason: String, Sendable, Codable {
        case lightSleep = "light_sleep"
        case awake = "awake"
        case noLightSleep = "no_light_sleep"
        case watchedPartly = "watched_partly"
        case couldntWatch = "couldnt_watch"
    }

    public var kind: Kind
    /// Ring time (unix s): the decision epoch's end for a smart ring, L for the backstop; nil with no plan.
    public var at: Int64?
    public var reason: Reason?
    /// Why there was no plan (kind == .noPlan).
    public var noPlanReason: String?
    public var windowStart: Int64?
    public var windowEnd: Int64?
    public var windowMinutes: Double?
    public var narrowed: Bool
    public var narrowReason: SmartWakeNarrowReason?
    public var stageAtWake: SleepLiveStage?
    public var pLightOrWakeAtWake: Double?
    public var watchedMinutes: Double?
    /// No epoch had motion data: the night ran heart-only (the morning row says so).
    public var cardiacOnly: Bool
    /// The second after the newest data (the "disconnected at" time); nil = no data at all.
    public var dataEndedAt: Int64?
    /// The live stager's onset (its own 10-min-run rule, not an accounting rule).
    public var onset: Int64?

    public init(kind: Kind, at: Int64?, reason: Reason?, noPlanReason: String?, windowStart: Int64?, windowEnd: Int64?,
                windowMinutes: Double?, narrowed: Bool, narrowReason: SmartWakeNarrowReason?, stageAtWake: SleepLiveStage?,
                pLightOrWakeAtWake: Double?, watchedMinutes: Double?, cardiacOnly: Bool, dataEndedAt: Int64?,
                onset: Int64?) {
        self.kind = kind
        self.at = at
        self.reason = reason
        self.noPlanReason = noPlanReason
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.windowMinutes = windowMinutes
        self.narrowed = narrowed
        self.narrowReason = narrowReason
        self.stageAtWake = stageAtWake
        self.pLightOrWakeAtWake = pLightOrWakeAtWake
        self.watchedMinutes = watchedMinutes
        self.cardiacOnly = cardiacOnly
        self.dataEndedAt = dataEndedAt
        self.onset = onset
    }

    public static func noPlan(_ reason: String) -> SmartWakeOutcome {
        SmartWakeOutcome(kind: .noPlan, at: nil, reason: nil, noPlanReason: reason, windowStart: nil, windowEnd: nil,
                         windowMinutes: nil, narrowed: false, narrowReason: nil, stageAtWake: nil,
                         pLightOrWakeAtWake: nil, watchedMinutes: nil, cardiacOnly: false, dataEndedAt: nil, onset: nil)
    }
}

/// ALG-035 v0 — smart alarm logic, live variant on the iPhone (the strap's own alarm is the app's Alarms layer since
/// CLAUDE.md rule 5 changed on 2026-10-11; previously "never the strap alarm: CLAUDE.md rule 5, BRIEF hard
/// rules"). Python reference: `plan_wake`, `run_session` in app/pclab/mglab/ref/sleep_live.py; goldens ALG-035.json.
public enum ALG035 {
    public static let citation = "OpenStrap v0.9.25 smart alarm (light sleep inside your window); UX-SPEC 8.1; "
        + "ARCHITECTURE 4.11 fire rule"

    /// ALG-035 v0 plan. No plan (Missing) when smart wake is off, when there is no "must be up by" L for tomorrow
    /// (BRIEF default 3), or when L has passed. Window = [L − length, L], length clamped 10–45 (default 30). A short
    /// night keeps only the last 15 min (UX 8.1: less sleep is worse than a little grogginess): need known → short when
    /// expected onset (max(armedAt, asleepAround)) + need > window start; need unknown → short when armed after bedtime.
    /// Narrowing never widens a window under 15 min. Armed inside the window → watching starts at the next 30-s boundary.
    public static func plan(enabled: Bool, mustBeUpBy: Int64?, windowMinutes: Int?, armedAt: Int64, bedtime: Int64,
                            asleepAround: Int64? = nil, needMinutes: Double? = nil,
                            options: SmartWakeOptions = .standard) -> Computed<SmartWakePlan> {
        let P = SleepLiveParams.self
        guard enabled else { return .missing("Smart wake is off") }
        guard let L = mustBeUpBy else {
            return .missing("No 'must be up by' for tomorrow, so no wake plan (set one in Tonight)")
        }
        guard L > armedAt else { return .missing("'Must be up by' has already passed") }
        let length = min(P.windowMaxMinutes, max(P.windowMinMinutes, windowMinutes ?? P.windowDefaultMinutes))
        var ws = L - Int64(length) * 60
        let onset = asleepAround.map { max(armedAt, $0) } ?? armedAt
        if options.mode != .window, let need = needMinutes {
            // T9841: a widened window. It opens no earlier than the cap, the gate (time-gate mode) and the moment the
            // minimum rest could have been slept; if that moment is later than the last 15 minutes, the window is the
            // last 15 minutes and says "short night" (same words as the standard narrowing).
            let fraction = options.mode == .needMet ? 1.0
                : min(SmartWakeOptions.minRestRange.upperBound, max(SmartWakeOptions.minRestRange.lowerBound, options.minRestFraction))
            var start = L - Int64(SmartWakeOptions.capMinutes) * 60
            if options.mode == .timeGate, let gate = options.gateAt { start = max(start, gate) }
            start = max(start, onset + Int64((need * 60.0 * fraction).rounded(.up)))
            let latest = L - Int64(P.narrowMinutes) * 60
            let short = start > latest
            var begin = short ? latest : start
            let late = armedAt > begin
            if late { begin = ceilTo(armedAt, P.epochSeconds) }
            return .success(SmartWakePlan(windowStart: begin, windowEnd: L, backstopAt: L,
                                          setWindowMinutes: Int((L - begin) / 60), windowMinutes: Double(L - begin) / 60.0,
                                          narrowed: short, narrowReason: short ? .shortNight : nil, armedLate: late,
                                          expectedOnset: onset))
        }
        let short: Bool
        let why: SmartWakeNarrowReason
        if let need = needMinutes {
            short = Double(onset) + need * 60.0 > Double(ws)
            why = .shortNight
        } else {
            short = armedAt > bedtime
            why = .pastBedtime
        }
        let narrowed = short && length > P.narrowMinutes
        if narrowed { ws = L - Int64(P.narrowMinutes) * 60 }
        let late = armedAt > ws
        if late { ws = ceilTo(armedAt, P.epochSeconds) }
        return .success(SmartWakePlan(windowStart: ws, windowEnd: L, backstopAt: L, setWindowMinutes: length,
                                      windowMinutes: Double(L - ws) / 60.0, narrowed: narrowed,
                                      narrowReason: narrowed ? why : nil, armedLate: late, expectedOnset: onset))
    }

    /// Batch decision for one staged night (the reference path; the live controller feeds `SmartWakeSession` epoch by
    /// epoch with the same result).
    public static func run(plan: Computed<SmartWakePlan>, night: SleepLiveNight, needMinutes: Double?) -> SmartWakeOutcome {
        switch plan {
        case .failure(let m):
            return .noPlan(m.reason)
        case .success(let p):
            var s = SmartWakeSession(plan: p, needMinutes: needMinutes)
            for ep in night.epochs {
                if ep.end > p.windowEnd { break }
                if s.observe(ep) { break }
            }
            return s.outcome(lastDataTs: night.lastDataTs, motionEpochs: night.motionEpochs)
        }
    }

    static func ceilTo(_ t: Int64, _ step: Int64) -> Int64 {
        let f = LiveStager.floorTo(t, step)
        return f == t ? t : f + step
    }
}

/// ALG-035 v0 fire rule, fed epoch by epoch as the live stager closes them (ARCHITECTURE 4.11 "Fire", "Disconnected").
///
/// An epoch takes part when it starts at or after the window start in force at its end and ends at or before L. The
/// first 2 consecutive taking-part epochs with P(light or wake) >= 0.6 ring at the second one's end, if that is before
/// L (a pair ending at L is the backstop's). S and "." epochs (no probability) break the run. When tonight's need is
/// known and the detected onset (the live 10-min-run rule, known 10 min after it) + need is after the window start, the window
/// narrows to its last 15 min from the moment the onset is known. Otherwise the backstop rings at L: couldn't watch
/// when no epoch in the window had data, watched partly when some had none, else no light sleep.
public struct SmartWakeSession: Sendable {
    public let plan: SmartWakePlan
    public let needMinutes: Double?
    public private(set) var windowStart: Int64
    public private(set) var narrowed: Bool
    public private(set) var narrowReason: SmartWakeNarrowReason?
    public private(set) var onset: Int64?
    /// The epoch that rang, once it has.
    public private(set) var ringEpoch: SleepLiveEpoch?

    private var asleepRun = 0
    private var streak = 0
    private var inWindow: [SleepLiveEpoch] = []

    public init(plan: SmartWakePlan, needMinutes: Double?) {
        self.plan = plan
        self.needMinutes = needMinutes
        self.windowStart = plan.windowStart
        self.narrowed = plan.narrowed
        self.narrowReason = plan.narrowReason
    }

    public var hasRung: Bool { ringEpoch != nil }

    /// Feed the next closed epoch (time order). Returns true when the fire rule rings at this epoch's end.
    public mutating func observe(_ ep: SleepLiveEpoch) -> Bool {
        let P = SleepLiveParams.self
        guard ringEpoch == nil, ep.end <= plan.windowEnd else { return false }
        if onset == nil {
            asleepRun = ep.stage.isAsleep ? asleepRun + 1 : 0
            if asleepRun == P.onsetRunEpochs {
                let first = ep.start - Int64(P.onsetRunEpochs - 1) * P.epochSeconds
                onset = first
                // known at ep.end: narrow now if the night is short (need known, plan not already narrowed)
                if let need = needMinutes, !narrowed, plan.windowEnd - plan.windowStart > Int64(P.narrowMinutes) * 60,
                   Double(first) + need * 60.0 > Double(plan.windowStart), ep.end < plan.windowEnd {
                    narrowed = true
                    narrowReason = .shortNight
                    windowStart = max(windowStart, plan.windowEnd - Int64(P.narrowMinutes) * 60)
                }
            }
        }
        if ep.start < windowStart {
            streak = 0
            return false
        }
        inWindow.append(ep)
        if let p = ep.pLightOrWake, p >= P.fireP { streak += 1 } else { streak = 0 }
        if streak >= P.fireEpochs && ep.end < plan.windowEnd {
            ringEpoch = ep
            return true
        }
        return false
    }

    /// The night's outcome: the smart ring if it rang, else the backstop at L. `motionEpochs` = 0 → heart-only night.
    public func outcome(lastDataTs: Int64?, motionEpochs: Int) -> SmartWakeOutcome {
        let L = plan.windowEnd
        let ended = lastDataTs.map { $0 + 1 }
        let winMin = Double(L - windowStart) / 60.0
        let half = Double(SleepLiveParams.epochSeconds) / 60.0
        if let r = ringEpoch {
            return SmartWakeOutcome(kind: .smart, at: r.end, reason: r.stage == .wake ? .awake : .lightSleep,
                                    noPlanReason: nil, windowStart: windowStart, windowEnd: L, windowMinutes: winMin,
                                    narrowed: narrowed, narrowReason: narrowed ? narrowReason : nil,
                                    stageAtWake: r.stage, pLightOrWakeAtWake: r.pLightOrWake,
                                    watchedMinutes: Double(inWindow.count) * half, cardiacOnly: motionEpochs == 0,
                                    dataEndedAt: ended, onset: onset)
        }
        let inFinal = inWindow.filter { $0.start >= windowStart }
        let watched = inFinal.filter { $0.stage != .noData }
        let total = Int((Double(L - windowStart) / Double(SleepLiveParams.epochSeconds)).rounded())
        let reason: SmartWakeOutcome.Reason
        if watched.isEmpty {
            reason = .couldntWatch
        } else if watched.count < total {
            reason = .watchedPartly
        } else {
            reason = .noLightSleep
        }
        return SmartWakeOutcome(kind: .backstop, at: L, reason: reason, noPlanReason: nil, windowStart: windowStart,
                                windowEnd: L, windowMinutes: winMin, narrowed: narrowed,
                                narrowReason: narrowed ? narrowReason : nil, stageAtWake: watched.last?.stage,
                                pLightOrWakeAtWake: watched.last?.pLightOrWake,
                                watchedMinutes: Double(watched.count) * half, cardiacOnly: motionEpochs == 0,
                                dataEndedAt: ended, onset: onset)
    }
}
