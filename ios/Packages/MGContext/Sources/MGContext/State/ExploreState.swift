import Foundation
import MGDomain

/// The Explore tab (UX §9): search, period, shelf, catalogue, matrix card.
public struct ExploreState: Equatable, Sendable {
    public var sample: Bool
    public var query: String
    public var period: ExplorePeriod
    /// Mo's pinned metrics.
    public var shelf: [ShelfItem]
    public var catalogue: [CatalogueSection]
    /// "Correlation matrix — pick up to 8" (APP-104, in B1 by BRIEF default 6).
    public var matrixTitle: String
    public var matrixSubtitle: String
    /// Wave 2: every PC model's newest result, labelled "computed on PC".
    public var pcLab: [PCModelRow] = []
    /// Wave 2: today's other outputs (movement, medication level, nicotine response, social jetlag, habits, ticks).
    public var extras: [ExtraRow] = []
    /// Tracker #7: what the PC part of the period is doing ("Before 12 Oct 2025: 1,204 days from the PC …", or "… isn't
    /// reachable … Showing 12 Oct 2025 – today from the phone only."); nil = the phone holds the whole period.
    public var pcHistory: String?
    public var pcHistoryShown = false
    /// T116: Explore › Workouts, the recent finished workouts; each opens in place.
    public var workoutHistory = WorkoutHistoryState()
    /// r9s (D-TRENDS-1): the six relative trends as cards (what each tracks, its backing, base/enhanced tiers, population vs
    /// yours, where it stands); empty while searching.
    public var trends: [TrendCard] = []

    public init(sample: Bool, query: String, period: ExplorePeriod, shelf: [ShelfItem], catalogue: [CatalogueSection],
                matrixTitle: String = "Correlation matrix", matrixSubtitle: String) {
        self.sample = sample
        self.query = query
        self.period = period
        self.shelf = shelf
        self.catalogue = catalogue
        self.matrixTitle = matrixTitle
        self.matrixSubtitle = matrixSubtitle
    }
}

public struct ShelfItem: Equatable, Sendable, Identifiable {
    /// Metric name from the registry (`MetricKey`).
    public var key: String
    public var name: String
    /// Number for the period.
    public var value: DisplayValue
    /// One value per day, oldest first; nil = no data that day.
    public var sparkline: [Double?]

    public init(key: String, name: String, value: DisplayValue, sparkline: [Double?]) {
        self.key = key
        self.name = name
        self.value = value
        self.sparkline = sparkline
    }

    public var id: String { key }
}

public struct CatalogueSection: Equatable, Sendable, Identifiable {
    /// "Heart & lungs".
    public var title: String
    public var isOpen: Bool
    public var entries: [CatalogueEntry]

    public init(title: String, isOpen: Bool, entries: [CatalogueEntry]) {
        self.title = title
        self.isOpen = isOpen
        self.entries = entries
    }

    public var id: String { title }
}

public struct CatalogueEntry: Equatable, Sendable, Identifiable {
    public var key: String
    public var name: String
    /// "G-HRV" when it has a comparison group.
    public var groupId: String?
    public var isResearch: Bool
    public var intent: UIIntent
    /// Wave 2 ("Every measure"): the newest value, labelled with its source / algorithm; nil = a plain row.
    public var value: DisplayValue?
    public var detail: String?

    public init(key: String, name: String, groupId: String?, isResearch: Bool, intent: UIIntent) {
        self.key = key
        self.name = name
        self.groupId = groupId
        self.isResearch = isResearch
        self.intent = intent
    }

    public var id: String { key }
}

/// Metric detail (UX §9): title + receipt, Number · Graph · Trend, methods strip, Compare with…, About.
public struct MetricDetailState: Equatable, Sendable {
    public var sample: Bool
    public var key: String
    public var title: String
    public var receipt: Receipt?
    public var view: MetricViewMode
    public var number: MetricNumberSummary
    public var graph: MetricGraph
    public var trend: MetricTrend
    public var methods: MethodsStripState?
    public var about: MetricAbout
    /// The period the numbers cover (Explore's picker). Added for WP-19 with main's OK, 2026-10-11.
    public var period: ExplorePeriod
    /// Wave 2 (Mo: "I should be able to see all outputs on screen"): every source's newest value — ours, the PC's,
    /// imported history — each labelled.
    public var sources: [SourceRow] = []
    /// Wave 4: a short block of plain lines under the numbers (the SpO₂ screen: checked against WHOOP?, and why there
    /// is no reading on demand; optical research status). nil title = no block.
    public var infoTitle: String?
    public var infoLines: [String] = []
    /// Wave 4 (#77): one action under those lines (the SpO₂ screen: "Measure now (experimental, 60 s)").
    public var infoAction: ActionState?
    /// Tracker #7: the sentence about the PC part of the period (see ExploreState.pcHistory); `pcHistoryShown` false =
    /// the PC part is missing (asking, unreachable, not paired) and the numbers cover the phone's days only.
    public var pcHistory: String?
    public var pcHistoryShown = false
    /// T99: the Strain screen's tap-to-open panel with the algorithm dropdown; nil on every other metric.
    public var algorithmPanel: AlgorithmPanelState?
    /// T56: the Workout average HR screen's one line per activity; empty on every other metric.
    public var workoutTrends: [WorkoutActivityTrend] = []

    public init(sample: Bool, key: String, title: String, receipt: Receipt?, view: MetricViewMode,
                number: MetricNumberSummary, graph: MetricGraph, trend: MetricTrend, methods: MethodsStripState?,
                about: MetricAbout, period: ExplorePeriod = .days30) {
        self.sample = sample
        self.key = key
        self.title = title
        self.receipt = receipt
        self.view = view
        self.number = number
        self.graph = graph
        self.trend = trend
        self.methods = methods
        self.about = about
        self.period = period
    }
}

/// Number view: period median, IQR, days with a value "26 of 30 days", vs previous period and vs your normal in words.
public struct MetricNumberSummary: Equatable, Sendable {
    public var median: DisplayValue
    public var iqr: String?
    /// "26 of 30 days": how many days of the period had a value (T9913: this is days, not data quality).
    public var coverage: String
    public var versusPrevious: String?
    /// T9896 (e-6): the value against "your normal" (the band of the 28 days before), in words.
    public var versusNormal: String?
    /// T9896: one plain sentence saying what the two "against" rows compare.
    public var compareNote: String?
    /// T9913: the data-quality share of the newest value ("82 % of its 30-second slices had clean inputs"); nil = none recorded.
    public var cleanShare: String?
    /// T9894 (e-5) / T9890 (e-4): when the period has no value, the newest earlier value with its date, and the median of
    /// the last 7 days. nil = there is no earlier value.
    public var lastSeen: String?
    public var medianSevenDay: String?

    public init(median: DisplayValue, iqr: String?, coverage: String, versusPrevious: String?) {
        self.median = median
        self.iqr = iqr
        self.coverage = coverage
        self.versusPrevious = versusPrevious
    }
}

public struct DayPoint: Equatable, Sendable {
    public var day: LocalDay
    public var value: Double?

    public init(day: LocalDay, value: Double?) {
        self.day = day
        self.value = value
    }
}

/// Graph view: one y-axis; normal band = median ± 1.4826·MAD over 28 d (ALG-075); markers on the x-axis.
public struct MetricGraph: Equatable, Sendable {
    public var unit: String?
    public var points: [DayPoint]
    public var bandLow: Double?
    public var bandHigh: Double?
    public var markers: [GraphMarker]

    public init(unit: String?, points: [DayPoint], bandLow: Double?, bandHigh: Double?, markers: [GraphMarker]) {
        self.unit = unit
        self.points = points
        self.bandLow = bandLow
        self.bandHigh = bandHigh
        self.markers = markers
    }
}

/// Device change (APP-101: firmware, wear location, scale) or Health-vault marker (APP-102).
public struct GraphMarker: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case firmware, wearLocation, scale, healthVault }

    public var kind: Kind
    public var day: LocalDay
    public var label: String

    public init(kind: Kind, day: LocalDay, label: String) {
        self.kind = kind
        self.day = day
        self.label = label
    }
}

/// Trend view: EWMA line + CUSUM change marks (ALG-075).
public struct MetricTrend: Equatable, Sendable {
    public var ewma: [DayPoint]
    public var changeDays: [LocalDay]

    public init(ewma: [DayPoint], changeDays: [LocalDay]) {
        self.ewma = ewma
        self.changeDays = changeDays
    }
}

public struct MetricAbout: Equatable, Sendable {
    public var method: String
    public var algorithmId: String?
    public var citation: String?
    public var tier: Tier
    /// The newest valued row's own words (wave 1, 2026-10-11): score drivers, key points, ranks, rough-night signs and
    /// the activity-cost list live in the note, not in the number. nil when the newest row has no value or no note.
    public var latestNote: String?

    public init(method: String, algorithmId: String?, citation: String?, tier: Tier, latestNote: String? = nil) {
        self.method = method
        self.algorithmId = algorithmId
        self.citation = citation
        self.tier = tier
        self.latestNote = latestNote
    }
}

/// All members of one group, open (UX §11), pushed from "all methods".
public struct GroupState: Equatable, Sendable {
    public var sample: Bool
    public var groupId: String
    public var name: String
    public var members: [MethodMember]
    public var dropped: [MethodMember]
    public var showDropped: Bool
    public var agreement: String?
    /// The period "Agreement, 30 days" covers. Added for WP-19 with main's OK, 2026-10-11.
    public var period: ExplorePeriod
    /// Wave 2: every metric name of the group (G-HRV: all 13) with each member's value (GroupPipeline + PC results).
    public var measures: [GroupMeasureRow] = []
    /// Tracker #7: older years from the PC — the sentence, then one row per (metric, variant): its median, days and
    /// span, labelled with algorithm and source.
    public var pcHistory: String?
    public var pcRows: [LabeledValue] = []
    /// T9976: the PC's HRV suite (method x window) with Apple's SDNN and WHOOP's history apart; the HRV group only.
    public var hrvSuite: HRVSuiteState?

    public init(sample: Bool, groupId: String, name: String, members: [MethodMember], dropped: [MethodMember],
                showDropped: Bool, agreement: String?, period: ExplorePeriod = .days30) {
        self.sample = sample
        self.groupId = groupId
        self.name = name
        self.members = members
        self.dropped = dropped
        self.showDropped = showDropped
        self.agreement = agreement
        self.period = period
    }
}

/// "Compare with…" (UX §9 step 4, APP-104): a second metric → scatter, ρ, n days, optional lag 0–2 days.
/// ρ comes from WP-09's functions through the presenter (`cell`), never computed in the view.
/// Added for WP-19 with main's OK, 2026-10-11.
public struct CompareState: Equatable, Sendable {
    public static let maxLagDays = 2

    public var sample: Bool
    public var first: MatrixMetric
    /// nil until Mo picks the second metric.
    public var second: MatrixMetric?
    /// What can be picked as the second metric.
    public var candidates: [MatrixMetric]
    public var period: ExplorePeriod
    /// 0…`maxLagDays`: the second metric is taken this many days after the first.
    public var lagDays: Int
    public var xUnit: String?
    public var yUnit: String?
    /// One point per day where both have a value (after the lag).
    public var pairs: [ComparePair]
    /// ρ, n, BH q — blank "too few days (n)" under 14 pairs (`MatrixCell.make`); nil until `second` is set.
    public var cell: MatrixCell?

    public init(sample: Bool, first: MatrixMetric, second: MatrixMetric?, candidates: [MatrixMetric],
                period: ExplorePeriod, lagDays: Int, xUnit: String?, yUnit: String?, pairs: [ComparePair],
                cell: MatrixCell?) {
        self.sample = sample
        self.first = first
        self.second = second
        self.candidates = candidates
        self.period = period
        self.lagDays = lagDays
        self.xUnit = xUnit
        self.yUnit = yUnit
        self.pairs = pairs
        self.cell = cell
    }
}

public struct ComparePair: Equatable, Sendable {
    /// The first metric's day.
    public var day: LocalDay
    public var x: Double
    public var y: Double

    public init(day: LocalDay, x: Double, y: Double) {
        self.day = day
        self.x = x
        self.y = y
    }
}

/// Correlation matrix (UX §9, APP-104): ≤ 8 metrics, Spearman ρ, diverging scale; values come from WP-09 functions
/// through the presenter, never computed in the view.
public struct MatrixState: Equatable, Sendable {
    public static let maxMetrics = 8
    /// Cells with fewer paired days are blank "too few days (n)".
    public static let minPairedDays = 14

    public var sample: Bool
    public var metrics: [MatrixMetric]
    public var period: ExplorePeriod
    /// Row-major, `metrics.count` × `metrics.count`.
    public var cells: [[MatrixCell]]
    public var footnote: String

    public init(sample: Bool, metrics: [MatrixMetric], period: ExplorePeriod, cells: [[MatrixCell]],
                footnote: String = "Correlation, not cause. Benjamini–Hochberg corrected across the grid.") {
        self.sample = sample
        self.metrics = metrics
        self.period = period
        self.cells = cells
        self.footnote = footnote
    }
}

public struct MatrixMetric: Equatable, Sendable, Identifiable {
    public var key: String
    public var name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    public var id: String { key }
}

public struct MatrixCell: Equatable, Sendable {
    /// Spearman ρ; nil = blank.
    public var rho: Double?
    /// Paired days.
    public var n: Int
    /// BH-adjusted p.
    public var qValue: Double?
    /// "too few days (9)" when blank.
    public var blankReason: String?

    public init(rho: Double?, n: Int, qValue: Double?, blankReason: String?) {
        self.rho = rho
        self.n = n
        self.qValue = qValue
        self.blankReason = blankReason
    }

    /// The UX §9 rule: fewer than 14 paired days → blank "too few days (n)".
    public static func make(rho: Double?, n: Int, qValue: Double?) -> MatrixCell {
        if n < MatrixState.minPairedDays {
            return MatrixCell(rho: nil, n: n, qValue: nil, blankReason: "too few days (\(n))")
        }
        guard let r = rho, r.isFinite else {
            return MatrixCell(rho: nil, n: n, qValue: nil, blankReason: "no variation")
        }
        return MatrixCell(rho: r, n: n, qValue: qValue, blankReason: nil)
    }
}
