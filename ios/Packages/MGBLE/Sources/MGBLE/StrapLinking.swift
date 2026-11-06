import Foundation
import MGDomain

/// Where the strap link is (ARCHITECTURE §4.4.6, frozen). `HistoryProgress` is MGDomain's.
public enum StrapLinkState: Equatable, Sendable {
    case bluetoothOff, unauthorized, idle, scanning, connecting, bonding, handshaking, ready
    case downloadingHistory(HistoryProgress)
    case disconnected(reason: String?)
}

public struct StrapInfo: Equatable, Sendable {
    public var strapId: StrapID
    public var firmware: String?
    public var batteryPercent: Double?
    public var bonded: Bool
    /// Strap clock minus phone clock, from the last readback; nil when no readback succeeded.
    public var clockOffsetSeconds: Double?
    public var model: String?

    public init(strapId: StrapID, firmware: String?, batteryPercent: Double?, bonded: Bool,
                clockOffsetSeconds: Double?, model: String?) {
        self.strapId = strapId
        self.firmware = firmware
        self.batteryPercent = batteryPercent
        self.bonded = bonded
        self.clockOffsetSeconds = clockOffsetSeconds
        self.model = model
    }
}

public struct LiveBeat: Sendable {
    public var at: Date
    public var bpm: Double?
    public var rrMs: [Double]

    public init(at: Date, bpm: Double?, rrMs: [Double]) {
        self.at = at
        self.bpm = bpm
        self.rrMs = rrMs
    }
}

/// One second of live wrist orientation for the smart-wake stager (WP-11): the mean of the 100 accelerometer samples
/// in one 5/MG raw-IMU buffer (noop Whoop5RawImu: 1244-byte buffer, strap unix seconds @15, accel 1/4096 g per LSB,
/// 100 Hz). `gx`/`gy`/`gz` are GRAVITY components in g (not gyro), the same meaning as `R18Second.gx…gz`; `ts` is the
/// strap's own unix second. Added 2026-10-11 with main's approval.
public struct StrapMotionSecond: Equatable, Sendable {
    public var ts: Int64
    public var gx: Double
    public var gy: Double
    public var gz: Double

    public init(ts: Int64, gx: Double, gy: Double, gz: Double) {
        self.ts = ts
        self.gx = gx
        self.gy = gy
        self.gz = gz
    }
}

/// The strap link the app and smart wake use (ARCHITECTURE §4.4.6, frozen; `liveMotion` added 2026-10-11 with
/// main's approval for WP-11).
@MainActor
public protocol StrapLinking: AnyObject {
    var state: StrapLinkState { get }
    var info: StrapInfo? { get }
    var liveBeats: AsyncStream<LiveBeat> { get }
    var strapEvents: AsyncStream<StrapEvent> { get }
    /// Live 1-second gravity vectors. The strap sends raw IMU only after START_RAW_DATA (81) + TOGGLE_IMU_MODE (106)
    /// (noop Whoop5RawImu header), which are policy-gated and never sent in B1 — so in B1 this stream is usually
    /// EMPTY. A consumer must treat silence as "no motion data", never as "still".
    var liveMotion: AsyncStream<StrapMotionSecond> { get }
    func start()
    func disconnect()
    /// T141 (added 2026-10-12): look at the radio again when the app returns to the foreground.
    func reevaluate()
    func setRealtime(hr: Bool, motion: Bool) async throws
    func downloadHistory() async throws -> HistorySummary
    func prepareUnlock() async throws -> StrapWritePlan
    func runUnlock(_ plan: StrapWritePlan) async throws -> UnlockReport
    func restoreUnlock() async throws -> UnlockReport
}

/// Raw optical (108 live R20) as the link sees it (added 2026-10-11, strap-raw-optical phase C).
public struct RawOpticalStatus: Equatable, Sendable {
    /// The app switch "Raw optical (uses strap battery)".
    public var wanted: Bool = false
    /// 108 [01 01] was written on this connection and not yet switched off.
    public var on: Bool = false
    /// Live R20 records decoded since the switch was last turned on.
    public var frames: Int = 0
    public var lastFrameAt: Date?
    /// Why raw optical was stopped without Mo turning the switch off (the offload watchdog, a refusal); cleared when
    /// the switch is turned on again.
    public var stoppedReason: String?
    /// Wave 4: the last `recentSeconds` of both slots in every block, with the latest stored head for labels.
    /// Raw counts; no wavelength is implied by the block or slot.
    public var recent: [R20Block] = []
    public static let recentSeconds = 5
    /// Bug 3 (2026-10-14): the last `recordsKept` whole live R20 records, newest last, so the Live pulse wave can find a
    /// pulse the way the night path does (OpticalPulse needs an unbroken run of at least 8 s; `recent` holds 5 s).
    public var recentRecords: [R20Record] = []
    public static let recordsKept = 12

    public init() {}
}

/// Why a history download ended.
public enum HistoryEndReason: Equatable, Sendable {
    /// HISTORY_COMPLETE with nothing new left to fetch.
    case complete
    /// 60 s without an offload frame; unacked data stays on the strap and is re-served next session.
    case stalled
    /// `HistorySink.store` threw: nothing more is acked on this connection (ARCHITECTURE §4.4.4).
    case persistStalled(String)
    /// The per-connection cap of SEND_HISTORICAL_DATA runs was reached with data still arriving (noop 24).
    case chunkCap
    case disconnected(String?)
    /// `StrapLink.abortHistory()`; ABORT_HISTORICAL_TRANSMITS (20) sent, nothing trimmed.
    case aborted
    /// T10003: the strap kept re-sending chunks the phone already holds (all acked again, none stored again); the run
    /// stopped asking. The text says how many and the strap's trim before and after.
    case reserved(String)
}

/// Result of one `downloadHistory()` (approved by `main`, 2026-10-11).
public struct HistorySummary: Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    /// Chunks `HistorySink.store` committed.
    public var chunksStored: Int
    /// Chunks whose HISTORICAL_DATA_RESULT write the strap acknowledged.
    public var chunksAcked: Int
    /// Chunks the store reported as already present (re-served by the strap).
    public var duplicateChunks: Int
    public var recordsInserted: Int
    public var endReason: HistoryEndReason
    public var firstTs: Int64?
    public var lastTs: Int64?
    /// R22 records (packet 47, layout byte 22) seen in this download (added 2026-10-11, for `R22Watch`).
    public var r22Records: Int

    public init(startedAt: Date, endedAt: Date, chunksStored: Int, chunksAcked: Int, duplicateChunks: Int,
                recordsInserted: Int, endReason: HistoryEndReason, firstTs: Int64?, lastTs: Int64?,
                r22Records: Int = 0) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.chunksStored = chunksStored
        self.chunksAcked = chunksAcked
        self.duplicateChunks = duplicateChunks
        self.recordsInserted = recordsInserted
        self.endReason = endReason
        self.firstTs = firstTs
        self.lastTs = lastTs
        self.r22Records = r22Records
    }
}

/// One flag of an unlock or restore run.
public struct UnlockItemResult: Equatable, Sendable {
    public var name: String
    public var command: Int
    public var payloadHex: String
    public var priorValue: String?
    public var readback: String?
    /// "ok", or what went wrong ("write failed: …", "strap answered FAILURE", "readback 0x32 ≠ written 0x30",
    /// "can't restore: no logged prior value").
    public var result: String

    public init(name: String, command: Int, payloadHex: String, priorValue: String?, readback: String?, result: String) {
        self.name = name
        self.command = command
        self.payloadHex = payloadHex
        self.priorValue = priorValue
        self.readback = readback
        self.result = result
    }
}

/// Result of `runUnlock` / `restoreUnlock` (approved by `main`, 2026-10-11).
public struct UnlockReport: Equatable, Sendable {
    public var planId: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var items: [UnlockItemResult]
    /// True when a flag failed (the run stops at the first failure) or the plan was declined.
    public var stoppedEarly: Bool
    public var note: String?

    public init(planId: UUID, startedAt: Date, endedAt: Date, items: [UnlockItemResult], stoppedEarly: Bool, note: String?) {
        self.planId = planId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.items = items
        self.stoppedEarly = stoppedEarly
        self.note = note
    }
}

public enum StrapLinkError: Error, Equatable, Sendable {
    case notReady(String)
    /// A policy-gated command or the unlock under a policy that does not allow it.
    case refusedByPolicy(reason: String)
    case historyInProgress
    /// The store failed earlier on this connection; no more history is downloaded or acked until reconnect.
    case persistStalled(String)
    case planMismatch(String)
    case bondRefused(String)
    case transport(String)
    /// A strap settings snapshot could not be stored (added 2026-10-11): nothing that depends on it was written.
    case notSaved(String)
    /// The R22 plan stopped before any write, with the reason in words (added 2026-10-11), e.g.
    /// "R22 also needs enable_r22_v9_packets = 1".
    case refused(String)
}

/// Timings, all in seconds. `production` values cite noop; tests use short ones.
public struct StrapTiming: Sendable {
    /// Wait for a COMMAND_RESPONSE (ARCHITECTURE §4.4.2: 3 s).
    public var responseTimeout: Double
    /// Idle time that ends a history session (noop BLEManager L2650 `backfillIdleTimeoutSeconds` = 60).
    public var historyIdleTimeout: Double
    /// Delay between the clock settling and the first SEND_HISTORICAL_DATA (noop BLEManager L6952-6958: 1.5 s).
    public var postClockHistoryDelay: Double
    /// Pause between SET_FF_VALUE writes (ARCHITECTURE §4.4.5: 80 ms, noop BLEManager L3487-3517).
    public var unlockWriteSpacing: Double
    /// Drop and reconnect when the realtime stream is on but nothing arrived for this long (noop L4821-4827: 600 s).
    public var noDataReconnect: Double
    /// How often buffered live records go to `LiveSink`.
    public var liveFlushInterval: Double
    /// Clock readback tolerance (D6: 2 s).
    public var clockTolerance: Double
    /// SEND_HISTORICAL_DATA runs per connection (noop BackfillContinuation.defaultMaxAutoContinues = 24, L370).
    public var maxHistoryRunsPerConnection: Int
    /// An EVENT is "live" (double-tap, wrist, RTC lost) only when its own timestamp is this close to now;
    /// older ones are history replays (noop FrameRouter `dispatchLiveGestureIfFresh`).
    public var freshEventWindow: Double
    /// T110: WRIST_ON (9) / WRIST_OFF (10) only. A slow reconnect replays the wrist change up to minutes
    /// after it happened, and dropping it left the off-wrist flag stuck; these two events stay live for this
    /// long. Every other event keeps the 30 s `freshEventWindow` gate.
    public var wearEventWindow: Double
    /// First reconnect delay after a dropped link; grows linearly to 60 s.
    public var reconnectDelay: Double
    /// Raw-optical offload watchdog (2026-10-11, Mo's brief): while raw optical is on, an offload session longer than
    /// this stops raw optical and the offload (noop #1992: offload loops cost ~1 h of radio per connection).
    public var rawOpticalOffloadLimit: Double
    /// … or this many chunk requests in a row that bring no new chunk (the strap re-serves what it already sent).
    public var rawOpticalNoProgressLimit: Int
    /// Read-without-deleting test (wave W12b): pause after an ABORT before reading the range again, so the strap has
    /// left its END wait. Ours, not from a source.
    public var probeSettle: Double = 1.0
    /// T9997: longest wait for `HistorySink.store` before the run gives up on that chunk (not acked; the strap re-serves it).
    /// Ours: an app suspended mid-write used to hold the whole download open for ever.
    public var historyStoreTimeout: Double = 120
    /// T9997: longest wait for a history command write (22, the ack 23, abort 20) to be answered.
    public var historyWriteTimeout: Double = 15
    /// T9997: a download with no frame and no ack for this long is treated as dead by the next `downloadHistory` call.
    public var historyRunMaxIdle: Double = 600
    /// T9997: … or one older than this, whatever it is doing.
    public var historyRunMaxAge: Double = 3600
    /// T10003: this many already-held chunks in a row ends the run (a 24 h backlog is ~150 chunks).
    public var maxDuplicateChunksPerRun: Int = 300
    /// r8a 2026-10-17 (audit §5a): while connected and idle this long (no notification, no keep-alive read), read the
    /// standard battery level (2A19, read-only, cheap) to see whether the link still answers. noop runs a 30 s timer
    /// (ARCHITECTURE.md L273); ours is 45 s, one read per 45 s idle, nothing while data flows.
    public var keepAliveInterval: Double = 45
    /// … and bounce the link after this long with no notification when the stream is wanted or the last keep-alive read
    /// failed (noop: 120 s, same source). A silent but answering strap with nothing wanted (off wrist) is not bounced.
    public var silenceBounce: Double = 120
    /// T9996 (r9d): raw optical or raw motion is on at the strap but nothing of it has arrived for this long (and no history
    /// download runs): the reason is shown on the switch and the start is sent again, at most once per `streamRearmGap`.
    public var streamStallSeconds: Double = 120
    public var streamRearmGap: Double = 300
    /// WHOOP 4.0 (2026-11-06): the unproductive-run budget (`maxHistoryRunsPerConnection`) is counted across reconnects and
    /// refilled this long after the last unproductive run, so a strap that keeps stalling cannot be re-kicked for ever and a
    /// spent budget cannot block downloads for good (noop's 15-minute floor).
    public var historyBudgetRefill: Double = 900
    /// WHOOP 4.0: how far ahead of our newest stored record the strap's newest (GET_DATA_RANGE) must be before "more to fetch" is
    /// real (noop BackfillContinuation.defaultBehindGapSeconds = 300).
    public var historyBehindGap: Int64 = 300
    /// WHOOP 4.0: a strap newest more than this far past the phone clock is a wandering RTC, not backlog (noop
    /// defaultFutureSkewSeconds = 48 h).
    public var historyFutureSkew: Int64 = 48 * 3600
    /// WHOOP 4.0: a re-kick with no new rows stored is allowed this many times in a row on the strength of the range gap alone
    /// (noop: a phantom gap must not spin to the cap).
    public var historyEmptyGapKicks: Int = 2
    /// WHOOP 4.0: longest an alarm / LED read / test command waits for a running (or about to start) history download before it is
    /// sent anyway.
    public var historyDeferMax: Double = 600

    public init(responseTimeout: Double, historyIdleTimeout: Double, postClockHistoryDelay: Double,
                unlockWriteSpacing: Double, noDataReconnect: Double, liveFlushInterval: Double, clockTolerance: Double,
                maxHistoryRunsPerConnection: Int, freshEventWindow: Double, wearEventWindow: Double = 600,
                reconnectDelay: Double,
                rawOpticalOffloadLimit: Double = 900, rawOpticalNoProgressLimit: Int = 3) {
        self.responseTimeout = responseTimeout
        self.historyIdleTimeout = historyIdleTimeout
        self.postClockHistoryDelay = postClockHistoryDelay
        self.unlockWriteSpacing = unlockWriteSpacing
        self.noDataReconnect = noDataReconnect
        self.liveFlushInterval = liveFlushInterval
        self.clockTolerance = clockTolerance
        self.maxHistoryRunsPerConnection = maxHistoryRunsPerConnection
        self.freshEventWindow = freshEventWindow
        self.wearEventWindow = wearEventWindow
        self.reconnectDelay = reconnectDelay
        self.rawOpticalOffloadLimit = rawOpticalOffloadLimit
        self.rawOpticalNoProgressLimit = rawOpticalNoProgressLimit
    }

    public static let production = StrapTiming(
        responseTimeout: 3, historyIdleTimeout: 60, postClockHistoryDelay: 1.5, unlockWriteSpacing: 0.08,
        noDataReconnect: 600, liveFlushInterval: 5, clockTolerance: 2, maxHistoryRunsPerConnection: 24,
        freshEventWindow: 30, wearEventWindow: 600, reconnectDelay: 3)
}

public struct StrapLinkConfig: Sendable {
    /// Per-install random salt; `StrapID` = "s_" + 16 hex of SHA256(salt + peripheral UUID). The app (WP-23)
    /// creates and persists it.
    public var installSalt: Data
    /// The paired strap. When set, only this peripheral is connected to.
    public var pinnedPeripheralID: UUID?
    /// When Mo gave the standing consent for the clock set at pairing (D6). nil → the clock is read, never set.
    public var clockConsentAt: Date?
    public var policy: StrapPolicy
    /// Start a history download `postClockHistoryDelay` after each handshake (ARCHITECTURE §4.4.2 step 8).
    public var autoDownloadHistoryOnConnect: Bool
    public var timing: StrapTiming
    /// WHOOP4-LINK (2026-11-05, D-WHOOP4-LINK-1): asked every time the link is about to scan or connect. false = do neither.
    /// The app passes `StrapConnectPolicy`'s answer for the saved device choice, so the 5/MG link stays silent while
    /// "WHOOP 4.0" is the selected device. nil = always allowed (the previous behaviour, and what every test uses).
    public var connectGate: (@Sendable () -> Bool)?

    public init(installSalt: Data, pinnedPeripheralID: UUID? = nil, clockConsentAt: Date? = nil,
                policy: StrapPolicy = .b1, autoDownloadHistoryOnConnect: Bool = true, timing: StrapTiming = .production,
                connectGate: (@Sendable () -> Bool)? = nil) {
        self.installSalt = installSalt
        self.pinnedPeripheralID = pinnedPeripheralID
        self.clockConsentAt = clockConsentAt
        self.policy = policy
        self.autoDownloadHistoryOnConnect = autoDownloadHistoryOnConnect
        self.timing = timing
        self.connectGate = connectGate
    }
}
