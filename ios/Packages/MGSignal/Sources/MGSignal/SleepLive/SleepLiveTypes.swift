import Foundation
import MGDomain

// Smart wake, signal side (WP-11). Python reference: app/pclab/mglab/ref/sleep_live.py; goldens
// app/shared/golden/sleep_live/ (ALG-031-live.json, ALG-035.json) written by app/pclab/golden/gen_sleep_live.py.

/// One 30-s epoch's hypnogram character — WP-10's representation (ref/sleep.py docstring): W wake, L light, D deep,
/// R REM, S asleep with the stage unknown (no usable R-R / HR), "." no data.
public enum SleepLiveStage: String, Sendable, Codable, CaseIterable {
    case wake = "W"
    case light = "L"
    case deep = "D"
    case rem = "R"
    case asleep = "S"
    case noData = "."

    /// L, D, R or S (the asleep set).
    public var isAsleep: Bool { self == .light || self == .deep || self == .rem || self == .asleep }
    /// W, L, D or R: a stage two hypnograms can be compared on.
    public var isStaged: Bool { self == .wake || self == .light || self == .deep || self == .rem }
}

/// Constants of the live stager and the smart-wake rule. Values equal ref/sleep.py (ALG-120, WP-10: the live stager is
/// its causal twin and shares them) and ref/sleep_live.py ("ours v0", research tier, `version`). Golden parity holds
/// them equal; change them in Python first.
public enum SleepLiveParams {
    public static let version = "live-stager@0"
    public static let epochSeconds: Int64 = 30
    /// van Hees 2015: z-angle on 5-s blocks; a block needs >= 3 worn seconds (sleep.ANGLE_MIN_WORN_S, ours v1).
    static let blockSeconds: Int64 = 5
    static let blocksPerMinute = 12
    static let blockMinWorn = 3
    /// Minute activity needs >= 10 of its 12 angle changes (sleep.MINUTE_MIN_VALID_DELTAS).
    static let minuteMinValidDeltas = 10
    /// Minute HR needs >= 30 on-skin seconds, epoch HR >= 15 (sleep.MINUTE_MIN_HR_S, EPOCH_MIN_HR_S).
    static let minuteMinHR = 30
    static let epochMinHR = 15
    /// Cole et al. 1992 (Sleep 15:461): D = P · Σ W·A, D >= 1 → wake. Past terms only: A(t) 230, A(t−1) 76, A(t−2) 58,
    /// A(t−3) 54, A(t−4) 106; A(t+1) 74 and A(t+2) 67 are dropped (they are the future).
    static let ckP = 0.001
    static let ckPast: [(lag: Int, weight: Double)] = [(0, 230.0), (1, 76.0), (2, 58.0), (3, 54.0), (4, 106.0)]
    /// Degrees of z-angle change per minute → Cole–Kripke "count" (sleep.CK_ACT_SCALE, ours v1, uncalibrated).
    static let ckActScale = 0.1
    /// HR fusion: trailing-minute HR >= tonight's median minute HR + 10 bpm (sleep.HR_WAKE_DELTA), needs 30 minutes.
    static let hrWakeDelta = 10.0
    static let hrRefMinMinutes = 30
    /// Webster 1982 rules a–c (as listed by Cole 1992) in 30-s epochs: after >= 15 / 10 / 4 min of wake, the next
    /// 4 / 3 / 1 min of sleep are wake. Rules d–e need the future and are not applied live.
    static let websterAfterEpochs: [(need: Int, take: Int)] = [(30, 8), (20, 6), (8, 2)]
    /// Trailing 5 min of beats (ALG-010 window length); >= 30 corrected beats covering >= 180 s (sleep.RMSSD_*).
    static let trailingRMSSDSeconds: Int64 = 300
    static let rmssdMinBeats = 30
    static let rmssdMinCoverSeconds = 180.0
    /// Robust z (median, 1.4826·MAD) floors and the |z| cut for deep / REM; REM atonia gate (sleep.Z_*, REM_STILL_DEG).
    static let zFloorLn = 0.1
    static let zFloorHR = 1.0
    static let zStage = 0.5
    static let remStillDeg = 5.0
    /// Ours v0: z-scores need 20 min of asleep epochs with features so far tonight.
    static let stageMinHistory = 40
    /// Ours v0: logistic steepness per z unit for the soft output.
    static let pSteep = 4.0
    /// ARCHITECTURE 4.11: 2 consecutive epochs with P(light or wake) >= 0.6 ring now.
    public static let fireP = 0.6
    public static let fireEpochs = 2
    /// UX-SPEC 8.1 / BRIEF default 3: window 10–45 min, default 30; a short night keeps only its last 15 min.
    public static let windowDefaultMinutes = 30
    public static let windowMinMinutes = 10
    public static let windowMaxMinutes = 45
    public static let narrowMinutes = 15
    /// Live onset: the first 10-min run of asleep epochs (sleep.ONSET_RUN_EPOCHS).
    static let onsetRunEpochs = 20
    /// A live stager ignores seconds more than this far after its start (a corrupt timestamp must not allocate GBs).
    static let maxSpanSeconds: Int64 = 36 * 3600
}

/// One second of input: strap HR (bpm, > 0 when on skin) and the gravity vector (g). R18 history rows carry both;
/// live, realtime HR and `StrapLinking.liveMotion` gravity are merged by timestamp (gravity nil = no motion data).
public struct SleepLiveSecond: Equatable, Sendable {
    public var ts: Int64
    public var hr: Double?
    public var gx: Double?
    public var gy: Double?
    public var gz: Double?

    public init(ts: Int64, hr: Double?, gx: Double?, gy: Double?, gz: Double?) {
        self.ts = ts
        self.hr = hr
        self.gx = gx
        self.gy = gy
        self.gz = gz
    }

    /// From a stored R18 record (the morning replay uses history, which has gravity).
    public init(_ r: R18Second) {
        self.init(ts: r.ts, hr: r.hr, gx: r.gx, gy: r.gy, gz: r.gz)
    }
}

/// One closed 30-s epoch of the live stager.
public struct SleepLiveEpoch: Equatable, Sendable, Codable {
    public var start: Int64
    public var stage: SleepLiveStage
    /// P(light or wake): 1 for wake, the soft margin for L/D/R, nil for S and "." (no probability).
    public var pLightOrWake: Double?
    /// The trailing minute had motion data (false all night = cardiac-only).
    public var hasMotion: Bool

    public init(start: Int64, stage: SleepLiveStage, pLightOrWake: Double?, hasMotion: Bool) {
        self.start = start
        self.stage = stage
        self.pLightOrWake = pLightOrWake
        self.hasMotion = hasMotion
    }

    public var end: Int64 { start + SleepLiveParams.epochSeconds }
}

/// A staged span (batch replay, or the live run so far).
public struct SleepLiveNight: Equatable, Sendable {
    public var epoch0: Int64
    public var epochs: [SleepLiveEpoch]
    /// Epochs whose trailing minute had motion; 0 = the night ran cardiac-only.
    public var motionEpochs: Int
    /// Newest second with HR or R-R point before the span's end; nil = no data at all.
    public var lastDataTs: Int64?
    public var paramsVersion: String

    public init(epoch0: Int64, epochs: [SleepLiveEpoch], motionEpochs: Int, lastDataTs: Int64?,
                paramsVersion: String = SleepLiveParams.version) {
        self.epoch0 = epoch0
        self.epochs = epochs
        self.motionEpochs = motionEpochs
        self.lastDataTs = lastDataTs
        self.paramsVersion = paramsVersion
    }

    /// One character per epoch (W L D R S .), WP-10's hypnogram string.
    public var classes: String { String(epochs.map { Character($0.stage.rawValue) }) }
}
