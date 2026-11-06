import Foundation
import MGDomain

/// The Live tab (UX §6). While a workout runs, `workout` is set and replaces rows 2–4 (Workout mode, in place).
/// T148: the master button on the Streams card. `text` = how many switches are on ("Streams: 2 of 3 on"), `title` = what
/// a tap does, `intents` = exactly the per-switch intents a tap sends (the same ones the switches send, so the same
/// already-allowed strap paths): the switches that are off when some or none are on, all of them when all are on.
public struct StreamsMasterState: Equatable, Sendable {
    public var text: String
    public var title: String
    public var intents: [UIIntent]
    public var enabled: Bool
    public var disabledReason: String?

    public init(text: String = "Streams: 0 of 0 on", title: String = "Turn all on", intents: [UIIntent] = [],
                enabled: Bool = false, disabledReason: String? = nil) {
        self.text = text
        self.title = title
        self.intents = intents
        self.enabled = enabled
        self.disabledReason = disabledReason
    }
}

/// One live raw-optical waveform on the Live tab (wave 4).
public struct OpticalWave: Equatable, Sendable, Identifiable {
    public var id: Int
    /// "Green · block 0" / "Red? · block 1 (unconfirmed)".
    public var label: String
    public var samples: [Double]

    public init(id: Int, label: String, samples: [Double]) {
        self.id = id
        self.label = label
        self.samples = samples
    }
}

public struct LiveState: Equatable, Sendable {
    public var sample: Bool
    /// "R26 · 25 Hz · quality good".
    public var streamChip: StreamChipState
    /// HR hero (`heroNumber`) with receipt "strap · live · 1 s ago".
    public var heartRate: DisplayValue
    /// Seconds between beats for the pulse dot; nil = no beat (dot still).
    public var beatInterval: Double?
    /// Rolling RMSSD, 5 min.
    public var rmssd: DisplayValue
    /// Autonomic load vs your baseline: a word ("calm") + level 0…1.
    public var autonomicLoad: DisplayValue
    public var autonomicLevel: Double?
    /// 0.6.0.12: the two big tiles as the Live tab draws them (solid, grey with a reason, or blank); `rmssd` and
    /// `autonomicLoad` above stay for the other readers (widgets, debug dumps).
    public var rmssdTile: LiveTileState = .blank("Needs 5 minutes of clean beats.")
    public var loadTile: LiveTileState = .blank("Needs a clean 5-minute window.")
    /// 0.6.0.12: what opens when a tile is tapped (what it is, today's windows, the 7-night mean and normal band, what a change that matters is).
    public var rmssdCard: HRVExplainerState?
    /// 0.6.0.12: "Raw WHOOP 4.0 data" link, only while the 4.0 is the selected device (the 4.0's once-a-second history fields, raw counts).
    public var whoop4RawLink: ActionState?
    /// "MG" or "WHOOP 4.0": the chosen device, for the tab title.
    public var deviceName = "MG"
    /// 0.6.0.12: "Heart rate from the WHOOP 5.0 broadcast" while those beats feed Live; nil for the MG link.
    public var hrSourceNote: String?
    public var loadCard: HRVExplainerState?
    /// R26 PPG, last 8 s, oldest first.
    public var pulseWave: [Double]
    /// Wave 4: live raw optical waveforms (green block 0 labelled; red / IR "unconfirmed" until the LED experiment).
    public var opticalWaves: [OpticalWave] = []
    public var pulseQuality: String?
    /// Bug 3 (2026-10-14): the line under the pulse wave: the pulse rate found in it (research, decoded, untested) or
    /// why none was ("no pulse in the longest run of block 2 (5 s; at least 8 s needed)"); nil = nothing to add.
    public var pulseNote: String? = nil
    /// Bug 3: what the empty Pulse wave box says. Replaces the old fixed text that promised R26 packets which never
    /// arrive live (they come only with the history download).
    public var pulseBlank: String = "No pulse wave yet."
    /// P9729 (job 12): the ALG-144 cleaned trace beside the raw wave (band-passed raw counts, decoded, untested), its
    /// quality chip (state + named gates) and the line under it (pulse estimate, or why none). Empty / nil = raw optical
    /// is not flowing (the raw box already says why).
    public var cleanWave: [Double] = []
    public var cleanChip: StreamChipState? = nil
    public var cleanNote: String? = nil
    /// R8j (L1): `pulseWave` is raw optical (R20), not a real R26 wave. When the Raw PPG row draws waves its samples are
    /// left out of the state (the card draws them) and the Pulse wave box is hidden.
    public var pulseFromRaw: Bool = false
    /// R-R, last 60 s; artefacts hollow and excluded.
    public var tachogram: [TachogramPoint]
    public var tachogramMedian: DisplayValue
    /// "R26 pulse, 25 Hz, flowing" · "50 Hz mode flag off" · "R20 multi-LED needs the deep-data unlock (not sent)".
    public var streams: [StreamLine]
    /// Breathe · HRV check · ECG 30 s · Start workout · SpO₂ now (disabled with the reason).
    public var actions: [ActionState]
    /// "Share heart rate with gym kit and other apps" (policy-gated in B1).
    public var broadcast: ToggleState
    /// Record inspector · Capture session · Raw retention (dotted research tag).
    public var researchLinks: [ActionState]
    public var workout: WorkoutModeState?
    /// Strap off / not connected: everything is blank with this reason (UX §13).
    public var blankReason: String?
    /// T141: `blankReason` is Bluetooth off / not allowed — show the "Open Settings" button (the pairing sheet's
    /// camera-denied pattern); false for every other blank cause (no strap, searching, off wrist, …).
    public var blankReasonNeedsSettings: Bool = false
    /// HR, the last few minutes, oldest first: stored seconds first, then live (#35 — the chart opens full and scrolls).
    /// Also filled while connected and waiting for the first beat; empty when the strap is off or not connected.
    public var hrTrace: [LiveHRPoint]
    /// The right edge of the HR chart ("now"), so it scrolls every second even between beats.
    public var hrTraceEnd: Date?
    /// Wave W11: the HR line's / the beat-to-beat chart's label when they show the newest stored stretch instead of the
    /// minutes before now ("last 5 min of stored data, ending 9:12 PM"); nil = the usual live labels.
    public var hrTraceNote: String? = nil
    public var tachogramNote: String? = nil
    /// Wave W12b: the last read-without-deleting test, in words, under the Research links (empty = never run).
    public var historyReadTest: [String] = []
    /// Raw motion R21 (wave W8, 2026-10-11): the magnitude trace and the session buttons; nil while its switch is off.
    public var motion: LiveMotionState?
    /// T144 (Mo 2026-10-12): raw PPG, 100 Hz motion and ECG switches, always shown, so they can be turned on and off
    /// from the Live tab (same intents as Strap & sync).
    public var streamToggles: [ToggleState] = []
    /// T143: why the raw PPG wave is not showing (stopped by the watchdog, waiting for the strap, no records); nil = nothing to say.
    public var opticalNote: String? = nil
    /// T148 (Mo 2026-10-12): the master "Streams on / off" button above the three switches.
    public var streamsMaster = StreamsMasterState()
    /// T146 (Mo 2026-10-12): the raw PPG, 100 Hz motion and ECG waves under the HR graph, each with its own switch.
    public var waveRows: [LiveWaveRow] = []
    /// T127: today's stress score (0-3, ALG-123, an estimate) next to the live numbers; blank with the reason until scored.
    public var stressToday: DisplayValue = .blank(reason: "Not scored yet.", receipt: nil)
    /// r9t (D-BODY-WALK-1): the Today readout beside the live number: the average of today's worn minutes and the time worn
    /// since local midnight (a minute counts with 30 on-skin heart-rate seconds, ALG-036); blank with the reason.
    public var averageToday: DisplayValue = .blank(reason: "Not read yet.", receipt: nil)
    public var wornToday: DisplayValue = .blank(reason: "Not read yet.", receipt: nil)

    public init(sample: Bool, streamChip: StreamChipState, heartRate: DisplayValue, beatInterval: Double?,
                rmssd: DisplayValue, autonomicLoad: DisplayValue, autonomicLevel: Double?, pulseWave: [Double],
                pulseQuality: String?, tachogram: [TachogramPoint], tachogramMedian: DisplayValue,
                streams: [StreamLine], actions: [ActionState], broadcast: ToggleState, researchLinks: [ActionState],
                workout: WorkoutModeState?, blankReason: String?, hrTrace: [LiveHRPoint] = [],
                hrTraceEnd: Date? = nil) {
        self.sample = sample
        self.streamChip = streamChip
        self.heartRate = heartRate
        self.beatInterval = beatInterval
        self.rmssd = rmssd
        self.autonomicLoad = autonomicLoad
        self.autonomicLevel = autonomicLevel
        self.pulseWave = pulseWave
        self.pulseQuality = pulseQuality
        self.tachogram = tachogram
        self.tachogramMedian = tachogramMedian
        self.streams = streams
        self.actions = actions
        self.broadcast = broadcast
        self.researchLinks = researchLinks
        self.workout = workout
        self.blankReason = blankReason
        self.hrTrace = hrTrace
        self.hrTraceEnd = hrTraceEnd
    }
}

/// One HR value on the Live tab's HR line (#35).
public struct LiveHRPoint: Equatable, Sendable {
    public var at: Date
    public var bpm: Double

    public init(at: Date, bpm: Double) {
        self.at = at
        self.bpm = bpm
    }
}

public struct StreamChipState: Equatable, Sendable {
    public var text: String
    public var tone: StatusTone

    public init(text: String, tone: StatusTone) {
        self.text = text
        self.tone = tone
    }
}

public struct StreamLine: Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var tone: StatusTone
    /// "not sent yet · phase L".
    public var note: String?

    public init(id: String, text: String, tone: StatusTone, note: String? = nil) {
        self.id = id
        self.text = text
        self.tone = tone
        self.note = note
    }
}

public struct TachogramPoint: Equatable, Sendable {
    public var at: Date
    public var rrMs: Double
    /// Hollow and excluded (ALG-004).
    public var artefact: Bool

    public init(at: Date, rrMs: Double, artefact: Bool) {
        self.at = at
        self.rrMs = rrMs
        self.artefact = artefact
    }
}

/// Workout mode (UX §6): header, HR + zone, zone bar, HR map, windows, breathing, strain group, End workout.
public struct WorkoutModeState: Equatable, Sendable {
    public var sample: Bool
    /// "Gym, strength".
    public var title: String
    public var start: Date
    /// "13:10".
    public var elapsed: String
    public var heartRate: DisplayValue
    /// 1…5; nil = no HR.
    public var zone: Int?
    /// Minutes in zones 1…5.
    public var zoneMinutes: [Double]
    /// HR so far, one value per 5 s, oldest first.
    public var hrTrace: [Double]
    public var windows: [WorkoutWindowRow]
    /// One-minute breathing, only where two estimators agree (APP-031); blank otherwise.
    public var breathing: DisplayValue
    public var strain: DisplayValue
    public var strainGroup: MethodsStripState?
    /// "Double-tap the strap = set done".
    public var doubleTapHint: String?
    public var actions: [ActionState]
    /// Upper edges of zones 1–4 in bpm (zone 5 is above the last), e.g. [114, 133, 152, 171] = 60/70/80/90 % of
    /// HRmax 190; nil = no max known. Added for WP-13 with main's OK, 2026-10-11.
    public var zoneEdgesBpm: [Double]?
    /// Where the max came from (ALG-106 / G-HRMAX): "measured max 190", "Tanaka estimate 186".
    public var zoneBasis: String?
    /// T116: the WHOOP-style summary card, once this workout's detail is loaded.
    public var summary: WorkoutSummaryState?

    public init(sample: Bool, title: String, start: Date, elapsed: String, heartRate: DisplayValue, zone: Int?,
                zoneMinutes: [Double], hrTrace: [Double], windows: [WorkoutWindowRow], breathing: DisplayValue,
                strain: DisplayValue, strainGroup: MethodsStripState?, doubleTapHint: String?, actions: [ActionState],
                zoneEdgesBpm: [Double]? = nil, zoneBasis: String? = nil) {
        self.sample = sample
        self.title = title
        self.start = start
        self.elapsed = elapsed
        self.heartRate = heartRate
        self.zone = zone
        self.zoneMinutes = zoneMinutes
        self.hrTrace = hrTrace
        self.windows = windows
        self.breathing = breathing
        self.strain = strain
        self.strainGroup = strainGroup
        self.doubleTapHint = doubleTapHint
        self.actions = actions
        self.zoneEdgesBpm = zoneEdgesBpm
        self.zoneBasis = zoneBasis
    }
}

public struct WorkoutWindowRow: Equatable, Sendable, Identifiable {
    /// warmup · work · rest · interval · cooldown · set (contract workoutEvent.windows.kind).
    public var kind: String
    public var label: String
    public var start: Date
    public var end: Date?
    public var avgHR: DisplayValue

    public init(kind: String, label: String, start: Date, end: Date?, avgHR: DisplayValue) {
        self.kind = kind
        self.label = label
        self.start = start
        self.end = end
        self.avgHR = avgHR
    }

    public var id: String { "\(kind):\(Int(start.timeIntervalSince1970))" }
}
