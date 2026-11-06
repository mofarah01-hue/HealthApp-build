import Foundation
import MGDomain

// Wave 2 (2026-10-11): everything already computed made visible. Mo: "all models should be enabled — info from past data
// we have and their outputs if possible, or waiting for first night"; "I should be able to see all outputs on screen";
// "if stuff is processing I want to know about it". Inputs the app fills (computed upstream, never here) and the states
// the presenters word. Additive: every field elsewhere that uses these is defaulted.

// MARK: - Inputs (filled by the app composition)

/// Today's pipeline outputs that are not metrics (WP-22 `DayResult` mirrored, so MGContext needs no MGSignal), plus the
/// read-only pipelines the app runs on demand (HabitPipeline, ALG-116 social jetlag).
public struct DayExtrasInput: Equatable, Sendable {
    /// ALG-044 minutes by the strap's activity class; nil = no classed seconds today.
    public var movement: Movement?
    /// ALG-143 relative level of the lisdexamfetamine preset; nil + `medicationReason` when none was logged.
    public var medication: MedicationLevel?
    public var medicationReason: String?
    /// ALG-063 HR / RMSSD after vape sessions vs before; nil + `nicotineReason` when it could not run.
    public var nicotine: NicotineResponse?
    public var nicotineReason: String?
    /// ALG-069 per schedule: taken of due.
    public var adherence: [Adherence]
    /// ALG-116 social jetlag (hours) from the stored sleep timing; nil + the reason.
    public var socialJetlagHours: Double?
    public var socialJetlagReason: String?
    /// HabitPipeline (G-HABIT): each habit against the next night's outcome.
    public var habits: [HabitEffectInput]
    /// The strap's raw step-counter ticks today (ALG-040), shown labelled uncalibrated while steps are blank.
    public var stepTicks: Double?
    /// When the day pipeline produced these.
    public var at: Date

    public struct Movement: Equatable, Sendable {
        public var stillMin: Int
        public var activeMin: Int
        public var walkMin: Int
        public var runMin: Int
        public var knownMin: Int

        public init(stillMin: Int, activeMin: Int, walkMin: Int, runMin: Int, knownMin: Int) {
            self.stillMin = stillMin
            self.activeMin = activeMin
            self.walkMin = walkMin
            self.runMin = runMin
            self.knownMin = knownMin
        }
    }

    public struct MedicationLevel: Equatable, Sendable {
        public var name: String
        /// 0…1 of the curve's peak, at the newest sample at or before `at`.
        public var levelNow: Double?
        public var peakAt: Date?
        public var curve: [TimedValue]

        public init(name: String, levelNow: Double?, peakAt: Date?, curve: [TimedValue]) {
            self.name = name
            self.levelNow = levelNow
            self.peakAt = peakAt
            self.curve = curve
        }
    }

    public struct NicotineResponse: Equatable, Sendable {
        public var sessions: Int
        public var hrDeltaBpm: Double?
        public var rmssdDeltaMs: Double?

        public init(sessions: Int, hrDeltaBpm: Double?, rmssdDeltaMs: Double?) {
            self.sessions = sessions
            self.hrDeltaBpm = hrDeltaBpm
            self.rmssdDeltaMs = rmssdDeltaMs
        }
    }

    public struct Adherence: Equatable, Sendable {
        public var name: String
        public var taken: Int
        public var due: Int
        public var reason: String?

        public init(name: String, taken: Int, due: Int, reason: String? = nil) {
            self.name = name
            self.taken = taken
            self.due = due
            self.reason = reason
        }
    }

    public init(movement: Movement? = nil, medication: MedicationLevel? = nil, medicationReason: String? = nil,
                nicotine: NicotineResponse? = nil, nicotineReason: String? = nil, adherence: [Adherence] = [],
                socialJetlagHours: Double? = nil, socialJetlagReason: String? = nil, habits: [HabitEffectInput] = [],
                stepTicks: Double? = nil, at: Date) {
        self.movement = movement
        self.medication = medication
        self.medicationReason = medicationReason
        self.nicotine = nicotine
        self.nicotineReason = nicotineReason
        self.adherence = adherence
        self.socialJetlagHours = socialJetlagHours
        self.socialJetlagReason = socialJetlagReason
        self.habits = habits
        self.stepTicks = stepTicks
        self.at = at
    }
}

/// One habit's effect on one next-night outcome (MGSignal HabitEffect / ALG-125 group, mirrored).
public struct HabitEffectInput: Equatable, Sendable {
    /// "caffeine", "alcohol", "vape", "medication:<name>".
    public var habit: String
    /// "hrv_rmssd", "sleep_performance", "rhr".
    public var outcome: String
    /// ALG-067 Cohen's d, or nil + `reason`.
    public var cohensD: Double?
    public var nWith: Int
    public var nWithout: Int
    public var reason: String?

    public init(habit: String, outcome: String, cohensD: Double?, nWith: Int, nWithout: Int, reason: String? = nil) {
        self.habit = habit
        self.outcome = outcome
        self.cohensD = cohensD
        self.nWith = nWith
        self.nWithout = nWithout
        self.reason = reason
    }
}

/// One comparison group for one metric name, as GroupPipeline (WP-22) lays it out for the day: members in rank order,
/// Mo's marks applied (dropped = hidden, never deleted), the primary hint.
public struct GroupMeasureInput: Equatable, Sendable {
    public var groupId: String
    public var metric: String
    public var members: [Member]
    public var primaryVariant: String?

    public struct Member: Equatable, Sendable {
        public var variant: String
        public var rank: Int?
        public var hidden: Bool
        public var metric: Metric?

        public init(variant: String, rank: Int?, hidden: Bool, metric: Metric?) {
            self.variant = variant
            self.rank = rank
            self.hidden = hidden
            self.metric = metric
        }
    }

    public init(groupId: String, metric: String, members: [Member], primaryVariant: String?) {
        self.groupId = groupId
        self.metric = metric
        self.members = members
        self.primaryVariant = primaryVariant
    }
}

/// What the app is busy with right now (the "Working on…" line).
public struct WorkingInput: Equatable, Sendable {
    /// A compute run: why, how many days, since when.
    public var compute: Compute?
    /// A sync step: what and how far.
    public var sync: Sync?
    /// The Apple Health bridge waiting on a Shortcut.
    public var healthImport: String?

    public struct Compute: Equatable, Sendable {
        public var reason: String
        public var days: Int
        public var since: Date

        public init(reason: String, days: Int, since: Date) {
            self.reason = reason
            self.days = days
            self.since = since
        }
    }

    public struct Sync: Equatable, Sendable {
        public enum Phase: String, Sendable { case uploading, profile, fetchingResults }
        public var phase: Phase
        public var done: Int
        public var total: Int

        public init(phase: Phase, done: Int, total: Int) {
            self.phase = phase
            self.done = done
            self.total = total
        }
    }

    public init(compute: Compute? = nil, sync: Sync? = nil, healthImport: String? = nil) {
        self.compute = compute
        self.sync = sync
        self.healthImport = healthImport
    }

    public static let idle = WorkingInput()
}

// MARK: - States (worded by the presenters)

/// One PC model on the Explore tab: its newest result, labelled "computed on PC".
public struct PCModelRow: Equatable, Sendable, Identifiable {
    /// The model id ("pc.ms-script").
    public var id: String
    /// "Mo's script on the PC".
    public var title: String
    /// "ok · Fri 10 Oct" / "skipped · Fri 10 Oct" / "error · …".
    public var status: String
    public var tone: StatusTone
    /// Why it did not run (skipped / error), from the PC.
    public var reason: String?
    /// Values with a registry name open their metric; the rest are plain lines.
    public var values: [LabeledValue]
    /// Key points, change points, coach text, agreement rows, cause-finder tests — the PC's own words.
    public var notes: [String]
    public var isOpen: Bool

    public init(id: String, title: String, status: String, tone: StatusTone, reason: String?, values: [LabeledValue],
                notes: [String], isOpen: Bool) {
        self.id = id
        self.title = title
        self.status = status
        self.tone = tone
        self.reason = reason
        self.values = values
        self.notes = notes
        self.isOpen = isOpen
    }

    /// `.toggleRow(id:)` id.
    public var rowId: String { "pc:" + id }
}

/// One line of "Today's other outputs" (movement, medication level, nicotine response, social jetlag, habits …).
public struct ExtraRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var value: DisplayValue
    public var detail: String?

    public init(id: String, title: String, value: DisplayValue, detail: String?) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
    }
}

/// One source of one metric on its detail screen: "Plews lnRMSSD · ALG-101 · computed on phone".
public struct SourceRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// "phone", "strap", "computed on PC", "past data · WHOOP export".
    public var origin: String
    public var value: DisplayValue
    /// The day the value belongs to (D13).
    public var day: LocalDay?

    public init(id: String, label: String, origin: String, value: DisplayValue, day: LocalDay?) {
        self.id = id
        self.label = label
        self.origin = origin
        self.value = value
        self.day = day
    }
}

/// One metric name inside a group (G-HRV has 13): its members with values.
public struct GroupMeasureRow: Equatable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var values: [LabeledValue]

    public init(key: String, name: String, values: [LabeledValue]) {
        self.key = key
        self.name = name
        self.values = values
    }

    public var id: String { key }
}

/// The "Working on…" line: one short line per thing in progress; empty = nothing running (the line hides).
public struct WorkingState: Equatable, Sendable {
    public struct Line: Equatable, Sendable, Identifiable {
        public var id: String
        public var text: String
        /// 0…1 when the end is known.
        public var fraction: Double?

        public init(id: String, text: String, fraction: Double?) {
            self.id = id
            self.text = text
            self.fraction = fraction
        }
    }

    public var lines: [Line]

    public init(lines: [Line]) {
        self.lines = lines
    }

    public var isEmpty: Bool { lines.isEmpty }
}

/// A metric with the day it belongs to (D13), for "Every measure" and a metric's sources.
public struct DatedMetric: Equatable, Codable, Sendable {
    public var day: LocalDay
    public var metric: Metric
    /// Fetched from the PC for an older period (tracker #7), never stored on the phone.
    public var fromPC: Bool

    public init(day: LocalDay, metric: Metric, fromPC: Bool = false) {
        self.day = day
        self.metric = metric
        self.fromPC = fromPC
    }
}
