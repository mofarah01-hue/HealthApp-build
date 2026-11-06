import Foundation
import MGDomain

// T124 (2026-10-13): more reasons to run live raw optical (108 [01 01] / [01 00], already on CLAUDE.md rule 5's list,
// behind the raw-optical switch). Nothing new is sent to the strap: this only decides WHEN the existing on / off runs.
// Motion-rate changes and red/IR control have no mapped command and stay parked (docs/TODO-LATER.md, D-042-T124).
// Pure: the app passes the clock, the workout flag and the last seconds of accelerometer magnitude.

/// "SpO₂ on during X every X": raw optical on for the first `onS` seconds of every `everyS` seconds (phone clock,
/// counted from the Unix epoch, so it needs no stored start).
public struct SpO2Every: Codable, Equatable, Sendable {
    public var onS: Int
    public var everyS: Int

    public init(onS: Int, everyS: Int) {
        self.onS = onS
        self.everyS = everyS
    }

    /// A schedule that leaves gaps: `everyS == onS` would be "always on", which is the switch's job, not a schedule's.
    public var isValid: Bool { onS >= 1 && everyS > onS }
}

/// T124: the Strap & sync "every X" picker's fixed presets, all 30 s on (matching the night schedule's measured burst
/// length). `off` is "no periodic window" (nil), not a 0-length schedule.
enum SpO2EveryOption: CaseIterable {
    case off, min10, min20, min30

    var every: SpO2Every? {
        switch self {
        case .off: return nil
        case .min10: return SpO2Every(onS: 30, everyS: 600)
        case .min20: return SpO2Every(onS: 30, everyS: 1200)
        case .min30: return SpO2Every(onS: 30, everyS: 1800)
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .min10: return "Every 10 min"
        case .min20: return "Every 20 min"
        case .min30: return "Every 30 min"
        }
    }

    /// The preset matching a stored schedule, falling back to `.off` for nil or a value no preset produces (so a
    /// future hand-entered schedule still shows a label instead of crashing).
    static func matching(_ e: SpO2Every?) -> SpO2EveryOption {
        guard let e else { return .off }
        return allCases.first { $0.every == e } ?? .off
    }
}

public enum RawOpticalWindows {
    public enum Reason: String, Equatable, Sendable {
        case workout, periodic, still
    }

    /// Wrist counts as still when the accelerometer magnitude's spread over the trace is at most this (0.05 g;
    /// a DEFAULT, not tuned against recordings — T123 tunes it) ...
    public static let stillSdCounts = 0.05 * MotionAccelSummary.countsPerG
    /// ... and the trace holds at least this many samples (5 s at 100 Hz).
    public static let minSamples = 500
    /// A "still" window keeps optical on this long, so one quiet moment is not an on / off write every beat.
    public static let stillHoldS: TimeInterval = 60

    public static func isStill(_ magnitudes: [Double]) -> Bool {
        guard magnitudes.count >= minSamples else { return false }
        let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
        let sd = (magnitudes.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(magnitudes.count)).squareRoot()
        return sd <= stillSdCounts
    }

    /// Why optical should run now, nil = no extra reason. Order: a workout, the periodic window, a still wrist.
    public static func reason(now: Date, workout: Bool, every: SpO2Every?, stillGate: Bool,
                              motion: [Double]) -> Reason? {
        if workout { return .workout }
        if let e = every, e.isValid {
            let u = Int64(now.timeIntervalSince1970.rounded(.down))
            let r = u % Int64(e.everyS)
            if (r < 0 ? r + Int64(e.everyS) : r) < Int64(e.onS) { return .periodic }
        }
        if stillGate, isStill(motion) { return .still }
        return nil
    }
}
