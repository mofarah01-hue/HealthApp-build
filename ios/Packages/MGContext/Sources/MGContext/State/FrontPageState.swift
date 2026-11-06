import Foundation
import MGDomain

// Front page customisation (tracker #34, Mo 2026-10-11: "customization … main page … dial ring … settings … i can
// customize add remove hide"; build-log 11:07: "front page = snapshot of common useful things; Settings to
// add/remove/hide/reorder front-page items and what the dial ring shows"). Mockups P1b / P1c
// (app/prototype/mockups-2026-10-11). Customisation decides order and visibility only; each card's contents stay its
// presenter's (the verdict rule "a missing model never headlines" is untouched).

/// One card Today can show between the header (fixed) and the footer (fixed). Raw values are what Settings stores.
public enum FrontPageItem: String, CaseIterable, Sendable, Codable {
    /// Headline + one sentence; the methods strip and the "N models not running" line ride with it.
    case verdict
    /// Tracker #75: what today already has — time worn, heart rate, step ticks, strain, the log.
    case todaySoFar
    case dial
    /// Recovery this morning (ALG-036 in band) or why it's blank.
    case recovery
    /// Up to three phase-ranked rows (UX §4.1); rows that have their own card here are left out of it.
    case now
    /// Last night's vitals (UX §3.2 row 7).
    case lastNight
    /// The next alarm within 24 h.
    case alarm
    /// Strap battery and time left.
    case battery
    /// The four quick-log pills (BRIEF default 9).
    case quickLog
    /// Time worn today and the average heart rate of those minutes (W10, Mo 2026-10-11: "I don't care how long I
    /// wore it for"): its own card, hidden by default; it used to lead "Today so far".
    case wornTime
    /// Wave 12 (#82): the PC's sun vitamin D estimate from Apple's daylight minutes. Hidden until Mo shows it.
    case vitaminD

    /// The default front page: a snapshot of common useful things, top to bottom.
    public static let defaultOrder: [FrontPageItem] = [
        .verdict, .todaySoFar, .dial, .recovery, .now, .lastNight, .alarm, .battery, .quickLog, .wornTime,
        .vitaminD,
    ]

    /// Listed in Settings › Front page but hidden until Mo shows it, also when a later build adds it to a stored page.
    public static let hiddenByDefault: Set<FrontPageItem> = [.wornTime, .vitaminD]

    public var title: String {
        switch self {
        case .verdict: return "Verdict"
        case .todaySoFar: return "Today so far"
        case .dial: return "Sundial"
        case .recovery: return "Recovery"
        case .now: return "Now list"
        case .lastNight: return "Last night"
        case .alarm: return "Next alarm"
        case .battery: return "Strap battery"
        case .quickLog: return "Quick-log bar"
        case .wornTime: return "Time worn"
        case .vitaminD: return "Sun vitamin D (estimate)"
        }
    }

    public var detail: String {
        switch self {
        case .verdict: return "headline + one sentence"
        case .todaySoFar: return "strain, heart rate, step ticks, your log"
        case .dial: return "the 24-hour ring — what it draws is under Dial ring"
        case .recovery: return "this morning's recovery, or why it's blank"
        case .now: return "up to 3 rows for this time of day"
        case .lastNight: return "resting HR, HRV, breathing, SpO₂ byte, skin temp"
        case .alarm: return "the next alarm in 24 h"
        case .battery: return "percent and time left"
        case .quickLog: return "four one-tap logs"
        case .wornTime: return "minutes on the wrist today and their average heart rate"
        case .vitaminD: return "estimate from Apple's daylight minutes and the UV index, worked out on the PC"
        }
    }
}

/// A layer of the Sundial Mo can switch off (mockup P1c). The awake track, the hand and the hub always draw.
public enum DialLayer: String, CaseIterable, Sendable, Codable {
    /// Last night's stages until Sundown, then tonight's pale plan.
    case sleep
    case naps
    case workouts
    case strapOff
    /// ALG-060 caffeine in the body.
    case caffeineCurve
    /// Rim marks.
    case vape, medication, caffeine, food, supplements
    /// Bedtime, caffeine cut-off, smart-wake window and wake marker.
    case ticks
    /// The four corner numbers.
    case corners
    /// T104: rings inside the track. Strain, recovery, sleep and stress start on, burn and eaten off (`FrontPageLayout.defaultRings`).
    case ringBurn, ringEaten, ringStress, ringStrain, ringRecovery, ringSleep

    /// Outside to inside.
    public static let rings: [DialLayer] = [.ringStrain, .ringRecovery, .ringSleep, .ringStress, .ringBurn, .ringEaten]
    public var isRing: Bool { Self.rings.contains(self) }

    public var title: String {
        switch self {
        case .sleep: return "Sleep stages and tonight's plan"
        case .naps: return "Naps"
        case .workouts: return "Workouts"
        case .strapOff: return "Strap-off gaps"
        case .caffeineCurve: return "Caffeine in body"
        case .vape: return "Vape marks"
        case .medication: return "Medication marks"
        case .caffeine: return "Drink marks"
        case .food: return "Food marks"
        case .supplements: return "Supplement marks"
        case .ticks: return "Bedtime, cut-off and wake ticks"
        case .corners: return "Corner numbers"
        case .ringBurn: return "Ring: calories burned vs goal"
        case .ringEaten: return "Ring: calories eaten"
        case .ringStress: return "Ring: body arousal"
        case .ringStrain: return "Ring: strain"
        case .ringRecovery: return "Ring: recovery"
        case .ringSleep: return "Ring: sleep"
        }
    }
}

/// How a picked metric is drawn on Today (T96): a small tile, a graph of its recent days, or the bare number.
public enum MetricPickForm: String, CaseIterable, Sendable, Codable {
    case tile, graph, number

    public var title: String { rawValue.capitalized }
}

/// One metric Mo put on Today (T96): a registry name (`MetricKey` raw value) and the form he chose.
public struct MetricPick: Codable, Equatable, Sendable {
    public var key: String
    public var form: MetricPickForm

    public init(key: String, form: MetricPickForm) {
        self.key = key
        self.form = form
    }
}

/// What Settings › Front page stores (in `AppSettings`, the kv table). Ids are strings so an item a newer build added
/// survives an older build untouched. Hidden = still listed in its place, not drawn; removed = back in "Add".
public struct FrontPageLayout: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var hidden: Bool

        public init(id: String, hidden: Bool = false) {
            self.id = id
            self.hidden = hidden
        }
    }

    /// Mo's order, hidden ones included.
    public var entries: [Entry]
    /// Items Mo removed: they stay out when a later build adds new items.
    public var removed: [String]
    /// Dial layers switched off (`DialLayer` raw values). A layer a later build adds starts on.
    public var dialHidden: [String]
    /// T104: dial rings switched ON (`DialLayer` raw values); `defaultRings` start on.
    public var dialRingsOn: [String]
    /// The four default rings were switched on once for this layout (a layout saved before 0.6 has them off); after
    /// that Mo's switches stick.
    public var ringDefaultsV2: Bool
    /// T96: metrics Mo put on Today, in his order; drawn above the quick-log bar.
    public var picks: [MetricPick]

    /// On for a new layout, and switched on once for a saved one (`ringDefaultsV2`).
    public static let defaultRings: [String] = [DialLayer.ringStrain, .ringRecovery, .ringSleep, .ringStress].map(\.rawValue)

    public init(entries: [Entry] = FrontPageItem.defaultOrder.map {
                    Entry(id: $0.rawValue, hidden: FrontPageItem.hiddenByDefault.contains($0)) },
                removed: [String] = [],
                dialHidden: [String] = [],
                picks: [MetricPick] = [],
                dialRingsOn: [String] = FrontPageLayout.defaultRings) {
        self.entries = entries
        self.removed = removed
        self.dialHidden = dialHidden
        self.picks = picks
        self.dialRingsOn = dialRingsOn
        ringDefaultsV2 = true
        normalize()
    }

    public static let standard = FrontPageLayout()

    enum CodingKeys: String, CodingKey { case entries, removed, dialHidden, picks, dialRingsOn, ringDefaultsV2 }

    /// Field by field: one unreadable field falls back to its default, never the whole layout.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrontPageLayout.standard
        entries = (try? c.decodeIfPresent([Entry].self, forKey: .entries)) ?? d.entries
        removed = (try? c.decodeIfPresent([String].self, forKey: .removed)) ?? []
        dialHidden = (try? c.decodeIfPresent([String].self, forKey: .dialHidden)) ?? []
        picks = (try? c.decodeIfPresent([MetricPick].self, forKey: .picks)) ?? []
        dialRingsOn = (try? c.decodeIfPresent([String].self, forKey: .dialRingsOn)) ?? []
        ringDefaultsV2 = (try? c.decodeIfPresent(Bool.self, forKey: .ringDefaultsV2)) ?? false
        if !ringDefaultsV2 {
            dialRingsOn += FrontPageLayout.defaultRings.filter { !dialRingsOn.contains($0) }
            ringDefaultsV2 = true
        }
        normalize()
    }

    // MARK: Reading

    /// The known items in Mo's order, hidden ones included (the Settings list).
    public var items: [(item: FrontPageItem, hidden: Bool)] {
        entries.compactMap { e in FrontPageItem(rawValue: e.id).map { ($0, e.hidden) } }
    }

    /// What Today draws, in order.
    public var visible: [FrontPageItem] { items.filter { !$0.hidden }.map(\.item) }

    /// Items not on the page (removed), in the default order: Settings' "Add".
    public var addable: [FrontPageItem] {
        let listed = Set(entries.map(\.id))
        return FrontPageItem.defaultOrder.filter { !listed.contains($0.rawValue) }
    }

    public func shows(_ layer: DialLayer) -> Bool {
        layer.isRing ? dialRingsOn.contains(layer.rawValue) : !dialHidden.contains(layer.rawValue)
    }

    public var isDefaultPage: Bool { entries == FrontPageLayout.standard.entries && picks.isEmpty }

    // MARK: Editing (each keeps the layout normalised)

    /// Settings' list order (`items` indices, as SwiftUI's `onMove` gives them: `to` is an index in the list BEFORE the
    /// move). Items a newer build added (unknown here) keep their slots.
    public mutating func move(from offsets: [Int], to destination: Int) {
        var known = items.map(\.item)
        let picked = offsets.filter { known.indices.contains($0) }.sorted()
        guard !picked.isEmpty else { return }
        let moving = picked.map { known[$0] }
        let before = picked.filter { $0 < destination }.count
        for i in picked.reversed() { known.remove(at: i) }
        let at = min(max(0, destination - before), known.count)
        known.insert(contentsOf: moving, at: at)
        // Refill the known slots in the new order; unknown entries stay where they were.
        let hidden = Dictionary(entries.map { ($0.id, $0.hidden) }, uniquingKeysWith: { a, _ in a })
        var next = known.makeIterator()
        entries = entries.map { e in
            guard FrontPageItem(rawValue: e.id) != nil, let item = next.next() else { return e }
            return Entry(id: item.rawValue, hidden: hidden[item.rawValue] ?? false)
        }
    }

    public mutating func setHidden(_ item: FrontPageItem, _ hidden: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == item.rawValue }) else { return }
        entries[i].hidden = hidden
    }

    /// Back on the page, shown, at the end.
    public mutating func add(_ item: FrontPageItem) {
        removed.removeAll { $0 == item.rawValue }
        if let i = entries.firstIndex(where: { $0.id == item.rawValue }) {
            entries[i].hidden = false
        } else {
            entries.append(Entry(id: item.rawValue))
        }
    }

    public mutating func remove(_ item: FrontPageItem) {
        entries.removeAll { $0.id == item.rawValue }
        if !removed.contains(item.rawValue) { removed.append(item.rawValue) }
    }

    /// "Reset to default" (front page only; the dial has its own).
    public mutating func resetPage() {
        entries = FrontPageLayout.standard.entries
        removed = []
        picks = []
    }

    public mutating func setDialLayer(_ layer: DialLayer, shown: Bool) {
        if layer.isRing {
            dialRingsOn.removeAll { $0 == layer.rawValue }
            if shown { dialRingsOn.append(layer.rawValue) }
            return
        }
        dialHidden.removeAll { $0 == layer.rawValue }
        if !shown { dialHidden.append(layer.rawValue) }
    }

    public mutating func resetDial() {
        dialHidden = []
        dialRingsOn = FrontPageLayout.defaultRings
    }

    /// T96: put a metric on Today in `form`, or change the form of one already there (it keeps its place).
    public mutating func setPick(_ key: String, _ form: MetricPickForm) {
        if let i = picks.firstIndex(where: { $0.key == key }) { picks[i].form = form } else {
            picks.append(MetricPick(key: key, form: form))
        }
    }

    public mutating func removePick(_ key: String) { picks.removeAll { $0.key == key } }

    /// Duplicates dropped (first wins), an id both listed and removed stays listed, and an item this build knows but
    /// the stored layout has never seen (a newer catalogue) is added at the end, shown (hidden when it is in
    /// `FrontPageItem.hiddenByDefault`). Removed items stay removed.
    public mutating func normalize() {
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.id).inserted }
        var gone = Set<String>()
        removed = removed.filter { !seen.contains($0) && gone.insert($0).inserted }
        for item in FrontPageItem.defaultOrder where !seen.contains(item.rawValue) && !gone.contains(item.rawValue) {
            entries.append(Entry(id: item.rawValue, hidden: FrontPageItem.hiddenByDefault.contains(item)))
        }
        var layers = Set<String>()
        dialHidden = dialHidden.filter { layers.insert($0).inserted }
        var rings = Set<String>()
        dialRingsOn = dialRingsOn.filter { rings.insert($0).inserted }
        var picked = Set<String>()
        picks = picks.filter { picked.insert($0.key).inserted }
    }
}

/// One card on Today, in Mo's order (`TodayState.cards`). The view draws each from `TodayState`'s own fields
/// (verdict, dial, quick log) or from the payload.
public enum TodayCard: Equatable, Sendable, Identifiable {
    /// VerdictBlock + methods strip + model-status line.
    case verdict
    case dial
    /// The Now list for this card (rows with their own card left out).
    case now([NowRowState])
    /// "Last night" or "Today so far".
    case strip(StripState)
    /// One row card (recovery, focus, alarm, battery).
    case row(NowRowState)
    case quickLog
    /// T96: a metric Mo picked, drawn in the form he chose.
    case metric(MetricCardState)

    public var id: String {
        switch self {
        case .verdict: return FrontPageItem.verdict.rawValue
        case .dial: return FrontPageItem.dial.rawValue
        case .now: return FrontPageItem.now.rawValue
        case .strip(let s): return s.kind == .lastNight ? FrontPageItem.lastNight.rawValue : FrontPageItem.todaySoFar.rawValue
        case .row(let r): return "row." + r.id
        case .quickLog: return FrontPageItem.quickLog.rawValue
        case .metric(let m): return "metric." + m.key
        }
    }
}

/// A picked metric on Today (T96). `series` is its recent days (oldest first, nil = no value that day) and is filled
/// for the graph form only.
public struct MetricCardState: Equatable, Sendable {
    public var key: String
    public var name: String
    public var form: MetricPickForm
    public var value: DisplayValue
    public var series: [Double?]
    public var intent: UIIntent
    /// T9838 / T9890: what the value is when it is not today's: a lab's draw date, units and source ("drawn Tue 14 Jul
    /// 2026 · 3 months ago · Function Health panel"), or a daily metric's last value date ("last value Tue 14 Oct").
    /// nil = today's own value, nothing to add.
    public var caption: String?

    public init(key: String, name: String, form: MetricPickForm, value: DisplayValue, series: [Double?], intent: UIIntent,
                caption: String? = nil) {
        self.key = key
        self.name = name
        self.form = form
        self.value = value
        self.series = series
        self.intent = intent
        self.caption = caption
    }
}

/// Settings › Front page (mockups P1b + P1c).
public struct FrontPageSettingsState: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var item: FrontPageItem
        public var title: String
        public var detail: String
        public var hidden: Bool

        public init(item: FrontPageItem, title: String, detail: String, hidden: Bool) {
            self.item = item
            self.title = title
            self.detail = detail
            self.hidden = hidden
        }

        public var id: String { item.rawValue }
    }

    public var sample: Bool
    /// SAMPLE mode: nothing changes (the settings rule); the reason shows instead.
    public var canEdit: Bool
    public var disabledReason: String?
    /// On the page, in order, hidden ones dimmed.
    public var rows: [Row]
    /// Removed: "Add".
    public var addable: [Row]
    /// One switch per dial layer; each carries `.frontPage(.setDialLayer(_, shown:))` with the new value.
    public var dialLayers: [ToggleState]
    public var pageIsDefault: Bool
    public var dialIsDefault: Bool
    public var note: String
    /// T96: metrics on Today, in order, and the metrics still to add (the Explore catalogue minus the picked ones).
    public var picks: [PickRow]
    public var pickChoices: [PickChoice]

    public struct PickRow: Equatable, Sendable, Identifiable {
        public var key: String
        public var name: String
        public var form: MetricPickForm
        public var id: String { key }
    }

    public struct PickChoice: Equatable, Sendable, Identifiable {
        public var key: String
        public var name: String
        public var id: String { key }
    }

    public init(sample: Bool, canEdit: Bool, disabledReason: String?, rows: [Row], addable: [Row],
                dialLayers: [ToggleState], pageIsDefault: Bool, dialIsDefault: Bool, note: String,
                picks: [PickRow] = [], pickChoices: [PickChoice] = []) {
        self.sample = sample
        self.canEdit = canEdit
        self.disabledReason = disabledReason
        self.rows = rows
        self.addable = addable
        self.dialLayers = dialLayers
        self.pageIsDefault = pageIsDefault
        self.dialIsDefault = dialIsDefault
        self.note = note
        self.picks = picks
        self.pickChoices = pickChoices
    }
}

/// Today's strap data so far (tracker #75), computed by the app with MGSignal's `TodayStrap` (ALG-036 worn minutes,
/// ALG-040 ticks) and copied here field by field, like `RecoveryReading`. nil in the snapshot = not read.
public struct TodaySoFarInput: Equatable, Sendable {
    /// Local midnight: the strap values count from here.
    public var from: Date
    /// When it was read (the receipts' time).
    public var at: Date
    public var hrSeconds: Int
    /// Minutes with ≥ 30 on-skin heart-rate seconds (ALG-036); time worn = × 60 s.
    public var wornMinutes: Int
    public var averageHR: Double?
    public var latestHR: Double?
    public var latestHRAt: Date?
    /// Raw ALG-040 step-counter ticks: not steps, no unit.
    public var stepTicks: Int?
    public var ticksMissing: String?
    public var r18Seconds: Int
    /// The last read failed (the numbers above are from the read before, or zero): shown, never swallowed.
    public var problem: String?

    public init(from: Date, at: Date, hrSeconds: Int, wornMinutes: Int, averageHR: Double?, latestHR: Double?,
                latestHRAt: Date?, stepTicks: Int?, ticksMissing: String?, r18Seconds: Int, problem: String? = nil) {
        self.from = from
        self.at = at
        self.hrSeconds = hrSeconds
        self.wornMinutes = wornMinutes
        self.averageHR = averageHR
        self.latestHR = latestHR
        self.latestHRAt = latestHRAt
        self.stepTicks = stepTicks
        self.ticksMissing = ticksMissing
        self.r18Seconds = r18Seconds
        self.problem = problem
    }
}
