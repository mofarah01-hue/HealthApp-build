import Foundation
import MGDomain

/// The 24-hour Sundial (UX §3.3). Geometry (θ = (h − 12)/24 × 360°, noon at the top) belongs to WP-12's view;
/// this is only what to draw. Each layer has its own radius and mark, so colour is never the only code.
public struct DialState: Equatable, Sendable {
    public var sample: Bool
    /// The hand.
    public var now: Date
    public var wake: Date?
    /// Until Sundown the night arc shows last night (solid); from Sundown tonight's plan (pale).
    public var nightArc: NightArcMode
    /// Main track: stages, naps, workouts, strap-off gaps, elapsed awake time.
    public var arcs: [DialArc]
    /// Caffeine in body (ALG-060), every 10 min from the first dose to B; opacity ∝ mg.
    public var caffeineCurve: [CaffeinePoint]
    public var rimEvents: [RimEvent]
    /// Caffeine cut-off, bedtime, smart-wake window.
    public var ticks: [DialTick]
    public var hub: DialHub
    /// Exactly the four corners, in order top-left, top-right, bottom-left, bottom-right; a corner may be empty.
    public var callouts: [DialCallout]
    /// One line naming only the marks present today ("● vape ×9 · first 12 min after waking   ◆ MedA 20 mg").
    public var legend: String
    /// One VoiceOver sentence (UX §3.3).
    public var accessibilityLabel: String
    /// The rings Settings turned on, outside to inside (strain, recovery, sleep, stress, burn, eaten). T104; four on by default (P01).
    public var rings: [DialRing]
    /// One detail sheet per tappable thing on the dial (P01); empty until the presenter fills it.
    public var details: [DialDetail]
    /// The key under the dial: one chip per ring and mark kind present.
    public var legendItems: [DialLegendItem]
    /// Round 8 (T10023): the day in 5-minute buckets over the dial's 24 h window, for the time scrub; nil until the
    /// presenter fills it (previews, older states).
    public var series: DialSeries?

    public init(sample: Bool, now: Date, wake: Date?, nightArc: NightArcMode, arcs: [DialArc],
                caffeineCurve: [CaffeinePoint], rimEvents: [RimEvent], ticks: [DialTick], hub: DialHub,
                callouts: [DialCallout], legend: String, accessibilityLabel: String, rings: [DialRing] = [],
                details: [DialDetail] = [], legendItems: [DialLegendItem] = []) {
        self.rings = rings
        self.details = details
        self.legendItems = legendItems
        self.sample = sample
        self.now = now
        self.wake = wake
        self.nightArc = nightArc
        self.arcs = arcs
        self.caffeineCurve = caffeineCurve
        self.rimEvents = rimEvents
        self.ticks = ticks
        self.hub = hub
        self.callouts = callouts
        self.legend = legend
        self.accessibilityLabel = accessibilityLabel
    }
}

/// One ring (T104). `fraction` is 0…1 of the ring to fill; nil = no scale to fill against (no goal set, or a
/// unit with no fixed maximum): the view draws the track only and the number says the rest. `target` is the part of the
/// ring (0…1) to aim for, drawn as a band; nil = none.
public struct DialRing: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case burn, eaten, stress, strain, recovery, sleep }

    public var kind: Kind
    public var title: String
    public var value: DisplayValue
    public var fraction: Double?
    public var detail: String?
    public var target: ClosedRange<Double>?

    public init(kind: Kind, title: String, value: DisplayValue, fraction: Double?, detail: String? = nil,
                target: ClosedRange<Double>? = nil) {
        self.kind = kind
        self.title = title
        self.value = value
        self.fraction = fraction
        self.detail = detail
        self.target = target
    }
}

public enum NightArcMode: String, Sendable { case lastNight, tonight }

/// One arc on the main track.
public struct DialArc: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case deep, light, rem, awake
        /// Asleep but no stage known (strap member, or epochs without R-R; WP-10 hypnogram code "S").
        /// Never draw it as light (added with main's OK, 2026-10-11).
        case unstaged
        /// Tonight's predicted sleep (pale `sleep`).
        case plannedSleep
        /// `sleep` light; dashed with "?" until confirmed.
        case nap, napUnconfirmed
        /// `body`, hatched.
        case workout
        /// Cross-hatch, `mute`.
        case strapOff
        /// Elapsed awake time (`rule` darker).
        case awakeElapsed
    }

    public var kind: Kind
    public var start: Date
    public var end: Date
    /// Predicted rather than happened (UX: solid = happened, pale = predicted).
    public var pale: Bool

    public init(kind: Kind, start: Date, end: Date, pale: Bool = false) {
        self.kind = kind
        self.start = start
        self.end = end
        self.pale = pale
    }
}

public struct DialSpan: Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct CaffeinePoint: Equatable, Sendable {
    public var at: Date
    public var mg: Double
    /// 0…1, fading to 0 at the bedtime limit.
    public var opacity: Double

    public init(at: Date, mg: Double, opacity: Double) {
        self.at = at
        self.mg = mg
        self.opacity = opacity
    }
}

/// A mark on the rim (UX §3.3): vape dot (hollow if detected and unconfirmed), medication diamond, caffeine circle with a
/// short arc for the sip time, food triangle, supplement square.
public struct RimEvent: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case vape, medication, caffeine, food, supplement }

    public var kind: Kind
    public var at: Date
    /// Sip end for a drink.
    public var end: Date?
    public var hollow: Bool
    public var label: String?
    /// The `EventRecord` (or detected hit) this mark is, so its sheet can find it.
    public var eventID: String?

    public init(kind: Kind, at: Date, end: Date? = nil, hollow: Bool = false, label: String? = nil,
                eventID: String? = nil) {
        self.kind = kind
        self.at = at
        self.end = end
        self.hollow = hollow
        self.label = label
        self.eventID = eventID
    }
}

/// Plan ticks across the track (UX §3.3).
public struct DialTick: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case caffeineCutoff, bedtime, smartWakeWindow, wakeMarker }

    public var kind: Kind
    public var at: Date
    /// Window end (smart wake).
    public var end: Date?
    /// Bedtime once missed.
    public var hollow: Bool

    public init(kind: Kind, at: Date, end: Date? = nil, hollow: Bool = false) {
        self.kind = kind
        self.at = at
        self.end = end
        self.hollow = hollow
    }
}

/// Hub text by phase (UX §4.1): kicker + big number + one detail line.
public struct DialHub: Equatable, Sendable {
    public var kicker: String
    public var big: String
    public var detail: String?
    /// Nov 6 2026: "Process now" when the night is not processed (carried for a tap on the hub; the dial's look is unchanged).
    public var intent: UIIntent?

    public init(kicker: String, big: String, detail: String?) {
        self.kicker = kicker
        self.big = big
        self.detail = detail
    }
}

/// A corner callout: coloured value + mono caption; tappable (UX §10).
public struct DialCallout: Equatable, Sendable {
    public enum Corner: String, Sendable, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    public var corner: Corner
    /// nil = this corner is empty in this phase ("—" in the UX §4.1 table).
    public var value: DisplayValue?
    public var caption: String
    public var tone: InkTone
    public var intent: UIIntent?

    public init(corner: Corner, value: DisplayValue?, caption: String, tone: InkTone, intent: UIIntent?) {
        self.corner = corner
        self.value = value
        self.caption = caption
        self.tone = tone
        self.intent = intent
    }
}

/// What a tap on the dial lands on (P01). Each target has at most one `DialDetail`.
public enum DialTarget: Hashable, Sendable, Identifiable {
    case ring(DialRing.Kind)
    case mark(RimEvent.Kind, at: Date)
    /// Stage arcs, wake marker.
    case sleep
    /// Plan arc, bedtime, smart wake.
    case tonight
    /// Body curve, cut-off.
    case caffeine
    case workout(start: Date)
    case nap(start: Date)
    case strapOff(start: Date)

    public var id: Self { self }
}

/// One detail sheet: a kicker, a title, a value, a sentence, small charts, rows, a list of items and the actions that
/// already exist.
public struct DialDetail: Equatable, Sendable, Identifiable {
    public var id: DialTarget
    public var tone: InkTone
    /// "STRAIN · TODAY SO FAR".
    public var kicker: String
    /// "9.4 of 21".
    public var title: String
    public var value: DisplayValue?
    public var sentence: String?
    /// Top to bottom.
    public var visuals: [DialDetailVisual]
    /// One VoiceOver sentence for the visuals.
    public var visualSummary: String?
    public var rows: [LabeledValue]
    public var itemsTitle: String?
    public var items: [DialDetailItem]
    /// Why the sheet has nothing to show, when it has nothing.
    public var blankReason: String?
    /// Existing intents only.
    public var actions: [ActionState]
    /// What tapping this thing on the dial did before 0.6.
    public var legacyIntent: UIIntent?

    public init(id: DialTarget, tone: InkTone = .ink, kicker: String, title: String, value: DisplayValue? = nil,
                sentence: String? = nil, visuals: [DialDetailVisual] = [], visualSummary: String? = nil,
                rows: [LabeledValue] = [], itemsTitle: String? = nil, items: [DialDetailItem] = [],
                blankReason: String? = nil, actions: [ActionState] = [], legacyIntent: UIIntent? = nil) {
        self.id = id
        self.tone = tone
        self.kicker = kicker
        self.title = title
        self.value = value
        self.sentence = sentence
        self.visuals = visuals
        self.visualSummary = visualSummary
        self.rows = rows
        self.itemsTitle = itemsTitle
        self.items = items
        self.blankReason = blankReason
        self.actions = actions
        self.legacyIntent = legacyIntent
    }
}

public enum DialDetailVisual: Equatable, Sendable {
    case ring(fraction: Double?, target: ClosedRange<Double>?)
    case week([DayPoint], max: Double?, unit: String?)
    case curve([TimedValue], window: DialSpan?, marks: [Date], unit: String?)
    case stages([StageSegment])
    /// Heart rate around an event, with the mean before and after.
    case hrAround([TimedValue], at: Date, before: Double?, after: Double?)
}

public struct DialDetailItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String?
    public var trailing: String?
    public var isSelected: Bool
    public var intent: UIIntent?

    public init(id: String, title: String, detail: String? = nil, trailing: String? = nil, isSelected: Bool = false,
                intent: UIIntent? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.isSelected = isSelected
        self.intent = intent
    }
}

/// One chip in the key under the dial.
public struct DialLegendItem: Equatable, Sendable, Identifiable {
    public var id: String
    /// ● ○ ◆ ◉ ▲ ■
    public var glyph: String
    public var text: String
    public var tone: InkTone
    public var target: DialTarget

    public init(id: String, glyph: String, text: String, tone: InkTone, target: DialTarget) {
        self.id = id
        self.glyph = glyph
        self.text = text
        self.tone = tone
        self.target = target
    }
}
