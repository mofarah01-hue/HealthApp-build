import Foundation
import MGDomain

/// Workout detail (push, UX §14 "Workout"): header with type and place chips Mo sets (APP-058) · summary
/// (time, avg / peak HR, HR recovery 1 min — APP-231) · HR map with zone bands across the time windows (APP-051,
/// ALG-106) · per-window table (ALG-047: per-window HR, zones, TRIMP) · breathing where two estimators agree (APP-031)
/// · training-load group G-LOAD (ALG-036, MS-01/02/03; APP-284) · calories group G-CAL (ALG-048; APP-057) · notes.
///
/// Opened by `.openWorkout(id:)` (nil = latest). Edits go out as `.editWorkout(id:edit:)` (`WorkoutEdit`); window
/// rows and the times editor open in place by `.toggleRow(id:)` (state-driven). Every number is the presenter's
/// (MGSignal / MGContext rules); views only draw. Built by WP-23.
public struct WorkoutDetailState: Equatable, Sendable {
    /// `.toggleRow(id:)` id of the "Edit times" row.
    public static let timesRowId = "workout-times"

    public var sample: Bool
    /// The workoutEvent / WorkoutSession id that `.editWorkout(id:edit:)` carries.
    public var id: UUID
    /// "SUN 17:32–18:20 · GYM · STRENGTH" (live: "SUN 17:32 → NOW · GYM").
    public var kicker: String
    /// "Workout".
    public var title: String
    public var start: Date
    /// nil = still running (opened during a live workout).
    public var end: Date?
    /// "What" — Mo's activity label (`activity_type_user`).
    public var typeRow: WorkoutChoiceRow
    /// "Where" — eventBase `location.label`.
    public var placeRow: WorkoutChoiceRow
    /// "Worn on" — left / right wrist, left / right bicep (eventBase `wear_location`); r9o, D-LOAD-WALK-1 item 12.
    public var wearRow: WorkoutChoiceRow
    /// What that place changes in the algorithms, one line each (`WearPolicy.effects`): "Steps from the strap: off. Why …".
    public var wearLines: [String]
    /// What the detector thought, kept beside Mo's label (ALG-041): "Detector: no type yet — needs the motion stream."
    public var autoTypeNote: String?
    /// Time · Avg HR · Peak · HR rec. 1 min (APP-231, ALG-012).
    public var summary: [LabeledValue]
    public var hrMap: WorkoutHRMapState
    /// In time order; they tile the workout.
    public var windows: [WorkoutDetailWindow]
    /// "Your confirmed window is the detector's label (ALG-041 / 047)."
    public var windowNote: String?
    /// Live only: "Double-tap the strap = set done" (APP-007).
    public var doubleTapHint: String?
    /// One-minute breathing only where two estimators agree and the motion gate passes (APP-031); blank otherwise.
    public var breathing: DisplayValue
    /// G-LOAD: ours 0–21 (ALG-036) · Banister TRIMP (MS-01) · Edwards (MS-02) · acute:chronic (MS-03).
    public var load: MethodsStripState?
    /// G-CAL: Keytel 2005 · Brage 2004 · cadence METs (Tudor-Locke 2019); Apple active energy joins when present.
    public var calories: MethodsStripState?
    /// Mo's note (eventBase `note`).
    public var note: String?
    /// The "Edit times" row is open (`.toggleRow(id: timesRowId)`).
    public var timesOpen: Bool
    /// false → chips, note and editors are shown but disabled, with `editDisabledReason`.
    public var editable: Bool
    /// "Sample data — edits are off." / "Still running — end it to edit the times."
    public var editDisabledReason: String?
    /// r9p: Mo's rating and weights for this session, and the readouts built on them (nil while the workout is running).
    public var effort: WorkoutEffortState?

    public init(sample: Bool, id: UUID, kicker: String, title: String, start: Date, end: Date?,
                typeRow: WorkoutChoiceRow, placeRow: WorkoutChoiceRow, autoTypeNote: String?, summary: [LabeledValue],
                hrMap: WorkoutHRMapState, windows: [WorkoutDetailWindow], windowNote: String?, doubleTapHint: String?,
                breathing: DisplayValue, load: MethodsStripState?, calories: MethodsStripState?, note: String?,
                timesOpen: Bool, editable: Bool, editDisabledReason: String?,
                wearRow: WorkoutChoiceRow = WorkoutDetailState.wearChoices(selected: nil), wearLines: [String] = []) {
        self.sample = sample
        self.id = id
        self.kicker = kicker
        self.title = title
        self.start = start
        self.end = end
        self.typeRow = typeRow
        self.placeRow = placeRow
        self.autoTypeNote = autoTypeNote
        self.summary = summary
        self.hrMap = hrMap
        self.windows = windows
        self.windowNote = windowNote
        self.doubleTapHint = doubleTapHint
        self.breathing = breathing
        self.load = load
        self.calories = calories
        self.note = note
        self.timesOpen = timesOpen
        self.editable = editable
        self.editDisabledReason = editDisabledReason
        self.wearRow = wearRow
        self.wearLines = wearLines
    }

    public var isLive: Bool { end == nil }

    /// The four places a workout can be edited to (the other `WearLocation` cases are not wrist or arm and stay on the wear screen).
    public static let wearOptions = [WorkoutChoice(id: WearLocation.leftWrist.rawValue, label: "Left wrist"),
                                     WorkoutChoice(id: WearLocation.rightWrist.rawValue, label: "Right wrist"),
                                     WorkoutChoice(id: WearLocation.leftBicep.rawValue, label: "Left bicep"),
                                     WorkoutChoice(id: WearLocation.rightBicep.rawValue, label: "Right bicep")]

    public static func wearChoices(selected: WearLocation?) -> WorkoutChoiceRow {
        WorkoutChoiceRow(title: "Worn on", options: wearOptions, selected: selected?.rawValue, allowsOther: false)
    }
}

/// A row of choice chips ("What": Strength · Run · Cycle …; "Where": Gym · Home · Outdoors).
public struct WorkoutChoiceRow: Equatable, Sendable {
    /// "What" / "Where".
    public var title: String
    public var options: [WorkoutChoice]
    /// The stored value Mo chose (an option id, or his own words); nil = none yet.
    public var selected: String?
    /// Show an "Other…" field for his own words.
    public var allowsOther: Bool

    public init(title: String, options: [WorkoutChoice], selected: String?, allowsOther: Bool) {
        self.title = title
        self.options = options
        self.selected = selected
        self.allowsOther = allowsOther
    }

    /// Mo's own words when they match no option ("climbing").
    public var otherValue: String? {
        guard let s = selected, !options.contains(where: { $0.id == s }) else { return nil }
        return s
    }
}

public struct WorkoutChoice: Equatable, Sendable, Identifiable {
    /// The value stored ("strength", "gym").
    public var id: String
    /// "Strength".
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// The HR map: a regular series like the contract's `series` "workout HR map" (`start`, `step_s`, `values` with
/// nulls), plus the zone edges (ALG-106 / G-HRMAX) and time in zones.
public struct WorkoutHRMapState: Equatable, Sendable {
    public var start: Date
    public var stepSeconds: Double
    /// bpm per step; nil = no reading in that step (a gap, drawn as a break in the line).
    public var bpm: [Double?]
    /// Upper edges of zones 1–4 in bpm (zone 5 above the last), e.g. [114, 133, 152, 171]; nil = no max known.
    public var zoneEdgesBpm: [Double]?
    /// "measured max 190" / "Tanaka estimate 186".
    public var zoneBasis: String?
    /// Minutes in zones 1…5 over the whole workout.
    public var zoneMinutes: [Double]
    public var receipt: Receipt?
    /// Nothing to draw, and why ("No heart rate — the strap was off the whole session.").
    public var blankReason: String?

    public init(start: Date, stepSeconds: Double, bpm: [Double?], zoneEdgesBpm: [Double]?, zoneBasis: String?,
                zoneMinutes: [Double], receipt: Receipt?, blankReason: String?) {
        self.start = start
        self.stepSeconds = stepSeconds
        self.bpm = bpm
        self.zoneEdgesBpm = zoneEdgesBpm
        self.zoneBasis = zoneBasis
        self.zoneMinutes = zoneMinutes
        self.receipt = receipt
        self.blankReason = blankReason
    }

    /// The finite readings with their times; `segment` goes up by one after every gap, so a chart can draw each
    /// unbroken run as its own line. Empty when the step is not a positive finite number.
    public func samples() -> [WorkoutHRSample] {
        guard stepSeconds.isFinite, stepSeconds > 0 else { return [] }
        var out: [WorkoutHRSample] = []
        out.reserveCapacity(bpm.count)
        var segment = 0
        var inGap = false
        for (i, reading) in bpm.enumerated() {
            guard let v = reading, v.isFinite else {
                if !out.isEmpty { inGap = true }
                continue
            }
            if inGap {
                segment += 1
                inGap = false
            }
            out.append(WorkoutHRSample(index: i, at: start.addingTimeInterval(Double(i) * stepSeconds), bpm: v,
                                       segment: segment))
        }
        return out
    }

    /// Four rising finite edges, or nil (then no zone bands are drawn, and the map says why).
    public var validZoneEdges: [Double]? {
        guard let e = zoneEdgesBpm, e.count == 4, e.allSatisfy({ $0.isFinite }), e == e.sorted() else { return nil }
        return e
    }
}

public struct WorkoutHRSample: Equatable, Sendable, Identifiable {
    /// Position in `WorkoutHRMapState.bpm`.
    public var index: Int
    public var at: Date
    public var bpm: Double
    /// Unbroken run number (a gap starts a new one).
    public var segment: Int

    public init(index: Int, at: Date, bpm: Double, segment: Int) {
        self.index = index
        self.at = at
        self.bpm = bpm
        self.segment = segment
    }

    public var id: Int { index }
}

/// One time window (ALG-047): warm-up / work / rest / interval / cool-down / set.
public struct WorkoutDetailWindow: Equatable, Sendable, Identifiable {
    /// `WorkoutWindowRow.id` convention "kind:epochSeconds" — what `WorkoutEdit` and `.toggleRow(id:)` carry.
    public var id: String
    /// Contract workoutEvent.windows.kind; nil = not set.
    public var kind: WorkoutFields.Window.Kind?
    /// "Work · 6 sets".
    public var label: String
    public var start: Date
    public var end: Date
    public var avgHR: DisplayValue
    public var peakHR: DisplayValue
    /// Banister TRIMP for the window (MS-01 form, ALG-047), or blank with why ("needs your resting HR").
    public var trimp: DisplayValue
    /// Minutes in zones 1…5 inside the window; nil = no zone edges.
    public var zoneMinutes: [Double]?
    /// "6 sets marked by double-tap · last 18:13" / exercise, reps, load when logged.
    public var detail: String?
    /// Opened in place (`.toggleRow(id: id)`).
    public var isOpen: Bool
    /// false for the last window.
    public var canMergeWithNext: Bool

    public init(id: String, kind: WorkoutFields.Window.Kind?, label: String, start: Date, end: Date,
                avgHR: DisplayValue, peakHR: DisplayValue, trimp: DisplayValue, zoneMinutes: [Double]?,
                detail: String?, isOpen: Bool, canMergeWithNext: Bool) {
        self.id = id
        self.kind = kind
        self.label = label
        self.start = start
        self.end = end
        self.avgHR = avgHR
        self.peakHR = peakHR
        self.trimp = trimp
        self.zoneMinutes = zoneMinutes
        self.detail = detail
        self.isOpen = isOpen
        self.canMergeWithNext = canMergeWithNext
    }

    /// The id the presenter gives a window: "kind:epochSeconds" (same as `WorkoutWindowRow.id`; no kind → "window").
    public static func makeID(kind: WorkoutFields.Window.Kind?, start: Date) -> String {
        "\(kind?.rawValue ?? "window"):\(Int(start.timeIntervalSince1970))"
    }

    /// Chip and row wording for a window kind.
    public static func title(for kind: WorkoutFields.Window.Kind) -> String {
        switch kind {
        case .warmup: return "Warm-up"
        case .work: return "Work"
        case .rest: return "Rest"
        case .interval: return "Interval"
        case .cooldown: return "Cool-down"
        case .set: return "Set"
        }
    }
}
