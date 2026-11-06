import Foundation

// Contract models (contract/whoop-data.schema.json v0.4 + the v0.5 proposals of ARCHITECTURE.md 5.8).
// Swift names are camelCase; CodingKeys carry the contract's snake_case names exactly. Enum raw values are checked
// against the schema by Scripts/gen_event_payloads.py --check and by app/pclab/tests/test_swift_parity.py.

public enum ContractInfo {
    public static let version = "0.4"
    public static let proposedVersion = "0.5"
    public static let syncAPI = "1"
}

/// Contract `$defs/tier`: how much to trust a value.
public enum Tier: String, Codable, Sendable, CaseIterable {
    case verified = "verified"
    case strap = "strap"
    case high = "high"
    case estimate = "estimate"
    case relative = "relative"
    case research = "research"
}

/// Contract `metric.computed_on`.
public enum ComputedOn: String, Codable, Sendable, CaseIterable {
    case strap = "strap"
    case phone = "phone"
    case pc = "pc"
}

/// Contract `metric.producer`: who made this comparison-group member.
public enum Producer: String, Codable, Sendable, CaseIterable {
    case strap = "strap"
    case ours = "ours"
    case olderMethod = "older_method"
    case script = "script"
    case apple = "apple"
    case lab = "lab"
    case vendorImport = "vendor_import"
    case recreation = "recreation"
}

/// Contract `$defs/origin`: who wrote a sample (HealthKit source app and device are kept apart, never merged).
public struct Origin: Codable, Hashable, Sendable {
    public var app: String?
    public var device: String?

    public init(app: String? = nil, device: String? = nil) {
        self.app = app
        self.device = device
    }
}

/// Contract `metric.uncertainty`.
public struct Uncertainty: Codable, Hashable, Sendable {
    public var low: Double?
    public var high: Double?
    public var sd: Double?

    public init(low: Double? = nil, high: Double? = nil, sd: Double? = nil) {
        self.low = low
        self.high = high
        self.sd = sd
    }
}

/// "YYYY-MM-DD" in the phone's current time zone (D13: nightly metrics belong to the wake day; events to the local
/// date of `at`). Always the Gregorian calendar, whatever calendar the user picked in Settings.
public struct LocalDay: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let iso: String

    /// nil unless `iso` is exactly `YYYY-MM-DD` and a real date (no Feb 30).
    public init?(iso: String) {
        let b = Array(iso.utf8)
        guard b.count == 10, b[4] == 0x2D, b[7] == 0x2D else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for k in r { guard b[k] >= 0x30, b[k] <= 0x39 else { return nil }; v = v * 10 + Int(b[k] - 0x30) }
            return v
        }
        guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10),
              (1...12).contains(m), d >= 1, d <= CivilDate.daysIn(year: y, month: m) else { return nil }
        self.iso = iso
    }

    /// The local date of `date` in `calendar.timeZone`. Only the time zone is used: a Buddhist or Japanese calendar
    /// setting must not change the year written to files.
    public init(date: Date, calendar: Calendar) {
        let offset = calendar.timeZone.secondsFromGMT(for: date)
        let t = Int(date.timeIntervalSince1970.rounded(.down)) + offset
        self.init(daysSince1970: CivilDate.floorDiv(t, 86_400))
    }

    init(daysSince1970 days: Int) {
        let (y, m, d) = CivilDate.civilFromDays(days)
        iso = CivilDate.pad(y, 4) + "-" + CivilDate.pad(m, 2) + "-" + CivilDate.pad(d, 2)
    }

    public var year: Int { Int(iso.prefix(4))! }
    public var month: Int { Int(iso.dropFirst(5).prefix(2))! }
    public var day: Int { Int(iso.suffix(2))! }
    var daysSince1970: Int { CivilDate.daysFromCivil(year: year, month: month, day: day) }

    public func adding(days n: Int) -> LocalDay { LocalDay(daysSince1970: daysSince1970 + n) }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(to other: LocalDay) -> Int { other.daysSince1970 - daysSince1970 }

    /// The first instant of this day in `timeZone` (midnight, or the first valid time when DST skips midnight).
    public func start(in timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: year, month: month, day: day))
            ?? cal.startOfDay(for: Date(timeIntervalSince1970: Double(daysSince1970) * 86_400))
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool { a.iso < b.iso }
    public var description: String { iso }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let d = LocalDay(iso: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a YYYY-MM-DD date: \(s)")
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

/// Contract `$defs/metric`. `value == nil` must carry its reason in `note` (R6). `value` is always written, as `null`
/// when missing (the contract requires the key).
public struct Metric: Codable, Hashable, Sendable {
    public var name: String
    public var value: Double?
    public var unit: String
    public var tier: Tier
    public var source: String
    public var method: String?
    public var citation: String?
    public var window: String?
    public var computedOn: ComputedOn
    public var at: Date
    public var origin: Origin?
    public var note: String?
    public var group: String?
    public var variant: String?
    public var producer: Producer?
    public var primary: Bool?
    public var paramsVersion: String?
    public var uncertainty: Uncertainty?
    public var coverage: Double?

    public init(
        name: String,
        value: Double?,
        unit: String,
        tier: Tier,
        source: String,
        method: String? = nil,
        citation: String? = nil,
        window: String? = nil,
        computedOn: ComputedOn,
        at: Date,
        origin: Origin? = nil,
        note: String? = nil,
        group: String? = nil,
        variant: String? = nil,
        producer: Producer? = nil,
        primary: Bool? = nil,
        paramsVersion: String? = nil,
        uncertainty: Uncertainty? = nil,
        coverage: Double? = nil
    ) {
        self.name = name
        self.value = value
        self.unit = unit
        self.tier = tier
        self.source = source
        self.method = method
        self.citation = citation
        self.window = window
        self.computedOn = computedOn
        self.at = at
        self.origin = origin
        self.note = note
        self.group = group
        self.variant = variant
        self.producer = producer
        self.primary = primary
        self.paramsVersion = paramsVersion
        self.uncertainty = uncertainty
        self.coverage = coverage
    }

    /// Rule violations; empty = valid. Each message names the metric.
    public func validate() -> [String] {
        var v: [String] = []
        let label = name.isEmpty ? "metric" : "metric \(name)"
        if name.isEmpty { v.append("\(label): name is empty") }
        if unit.isEmpty { v.append("\(label): unit is empty") }
        if source.isEmpty { v.append("\(label): source is empty") }
        if let value {
            if !value.isFinite { v.append("\(label): value is not finite (\(value))") }
        } else if (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            v.append("\(label): value is null without a reason in note (R6)")
        }
        if let coverage, !(coverage.isFinite && (0...1).contains(coverage)) {
            v.append("\(label): coverage \(coverage) outside 0...1")
        }
        if let u = uncertainty, let lo = u.low, let hi = u.high, lo > hi {
            v.append("\(label): uncertainty low \(lo) > high \(hi)")
        }
        if let g = group, (variant ?? "").isEmpty {
            v.append("\(label): member of group \(g) without a variant (ARCHITECTURE.md 8.3)")
        }
        return v
    }

    /// A missing value with its reason (R6): never a default that looks like data.
    public static func blank(name: String, unit: String, tier: Tier, source: String, computedOn: ComputedOn,
                             at: Date, reason: String, group: String?, variant: String?) -> Metric {
        Metric(name: name, value: nil, unit: unit, tier: tier, source: source, computedOn: computedOn, at: at,
               note: reason, group: group, variant: variant)
    }

    enum CodingKeys: String, CodingKey {
        case name = "name"
        case value = "value"
        case unit = "unit"
        case tier = "tier"
        case source = "source"
        case method = "method"
        case citation = "citation"
        case window = "window"
        case computedOn = "computed_on"
        case at = "at"
        case origin = "origin"
        case note = "note"
        case group = "group"
        case variant = "variant"
        case producer = "producer"
        case primary = "primary"
        case paramsVersion = "params_version"
        case uncertainty = "uncertainty"
        case coverage = "coverage"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        unit = try c.decode(String.self, forKey: .unit)
        tier = try c.decode(Tier.self, forKey: .tier)
        source = try c.decode(String.self, forKey: .source)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        citation = try c.decodeIfPresent(String.self, forKey: .citation)
        window = try c.decodeIfPresent(String.self, forKey: .window)
        computedOn = try c.decode(ComputedOn.self, forKey: .computedOn)
        at = try c.decode(Date.self, forKey: .at)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
        producer = try c.decodeIfPresent(Producer.self, forKey: .producer)
        primary = try c.decodeIfPresent(Bool.self, forKey: .primary)
        paramsVersion = try c.decodeIfPresent(String.self, forKey: .paramsVersion)
        uncertainty = try c.decodeIfPresent(Uncertainty.self, forKey: .uncertainty)
        coverage = try c.decodeIfPresent(Double.self, forKey: .coverage)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        if let value { try c.encode(value, forKey: .value) } else { try c.encodeNil(forKey: .value) }
        try c.encode(unit, forKey: .unit)
        try c.encode(tier, forKey: .tier)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(method, forKey: .method)
        try c.encodeIfPresent(citation, forKey: .citation)
        try c.encodeIfPresent(window, forKey: .window)
        try c.encode(computedOn, forKey: .computedOn)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(variant, forKey: .variant)
        try c.encodeIfPresent(producer, forKey: .producer)
        try c.encodeIfPresent(primary, forKey: .primary)
        try c.encodeIfPresent(paramsVersion, forKey: .paramsVersion)
        try c.encodeIfPresent(uncertainty, forKey: .uncertainty)
        try c.encodeIfPresent(coverage, forKey: .coverage)
    }
}

/// The store key of a metric (ARCHITECTURE.md 4.5 `metric` table); `variant` and `window` are "" when absent.
public struct MetricKeyID: Hashable, Sendable {
    public let day: LocalDay
    public let name: String
    public let variant: String
    public let window: String
    public let computedOn: ComputedOn

    public init(day: LocalDay, name: String, variant: String, window: String, computedOn: ComputedOn) {
        self.day = day
        self.name = name
        self.variant = variant
        self.window = window
        self.computedOn = computedOn
    }

    public init(metric: Metric, day: LocalDay) {
        self.init(day: day, name: metric.name, variant: metric.variant ?? "", window: metric.window ?? "",
                  computedOn: metric.computedOn)
    }
}

/// History the PC imported from another app's export (`pc.history@1`, app/pclab/mglab/history.py): Apple's and WHOOP's
/// values, shown with where they came from and never used as the app's own (registry variants `apple_health`,
/// `whoop_export`; added 2026-10-11).
public enum ImportedHistory {
    public static let modelId = "pc.history"
    public static let appleHealth = "apple_health"
    public static let whoopExport = "whoop_export"
    /// The Apple Watch's own steps, next to whichever source won the day (T13; `steps` only).
    public static let appleWatch = "apple_watch"
    /// In order of preference when more than one has a value: WHOOP's own export before WHOOP-via-Apple-Health, then
    /// the Watch's own steps.
    /// `calories_active` from Apple Health predates the `apple_health` label and is registered as `apple` in the shared
    /// registry and the phone catalogue (PC history.py APPLE_VARIANTS). The phone refused it, which stalled the whole
    /// results pull from 2026-10-14 (0.5.7 V3 fix).
    public static let appleLegacy = "apple"
    public static let variants = [whoopExport, appleHealth, appleWatch, appleLegacy]
    /// Our algorithms run on the PC over the imported backlog (`pc.history-derived@1`, app/pclab/mglab/history_derived.py;
    /// wave 2, 2026-10-11): variants `<id>:import` (ALG-101:import, MS-18:import, noop-recovery:import …). Past days
    /// only, never the app's own values; a `pc.history` result never removes them, nor they it (`owner`).
    public static let derivedModelId = "pc.history-derived"
    public static let derivedSuffix = ":import"
    /// The PC models whose ok results become imported rows.
    public static let modelIds = [modelId, derivedModelId]
    /// What the receipt names as the source of a derived value.
    public static let derivedSource = "ours on imported history (PC)"

    public static func isImportVariant(_ v: String?) -> Bool {
        guard let v else { return false }
        return variants.contains(v) || (v.hasSuffix(derivedSuffix) && v.count > derivedSuffix.count)
    }

    public static func isImported(_ m: Metric) -> Bool {
        m.computedOn == .pc && isImportVariant(m.variant)
    }

    /// An imported Apple Health row (`apple_health`, `apple_watch`, `apple`), whoever wrote it into Apple Health: the Watch,
    /// the iPhone or WHOOP. 0.6.0.7 (Mo, Oct 28 2026: "show whatever Apple Health has, from the Watch or from WHOOP's
    /// writes, each labelled by its source name"): these fill the live day where we have no value, labelled by `shortSource`.
    /// [Was 0.6.0.6 `isApples`, Oct 28 10:45 PM PT: WHOOP-written rows were kept out of the live day.]
    public static func isAppleHealth(_ m: Metric) -> Bool {
        isImported(m) && [appleHealth, appleWatch, appleLegacy].contains(m.variant ?? "")
    }

    /// Who wrote an Apple Health value, short: "WHOOP via Apple Health", "Apple Watch", "iPhone", else the source as the PC
    /// wrote it without " via Apple Health".
    public static func shortSource(_ name: String) -> String {
        let low = name.lowercased()
        if low.contains("whoop") { return "WHOOP via Apple Health" }
        if low.contains("watch") { return "Apple Watch" }
        if low.contains("iphone") { return "iPhone" }
        let s = name.replacingOccurrences(of: " via Apple Health", with: "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Apple Health" : s
    }

    /// The other sources pc.history did not use that day, from its note ("… Other sources that day, not used: <owner>’s
    /// Apple Watch 108.5 bpm (n 2), Mo’s Iphone 1,234 count (n 9)."), as "Apple Watch 108.5 bpm". Empty when none.
    public static func otherSources(note: String?) -> [String] {
        guard let note, let r = note.range(of: "not used:") else { return [] }
        var list = String(note[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        // The list ends at ")." ; later sentences of the note ("No sleep stages from: ...") are not part of it.
        if let end = list.range(of: ").") { list = String(list[..<end.upperBound]) }
        if list.hasSuffix(".") { list.removeLast() }
        // entries end with "(n K)"; split there, never on the comma inside "1,234"
        return list.components(separatedBy: "), ").compactMap { raw in
            var e = raw.trimmingCharacters(in: .whitespaces)
            if let n = e.range(of: " (n ", options: .backwards) { e = String(e[..<n.lowerBound]) }
            if e.hasSuffix(")") { e.removeLast() }
            guard !e.isEmpty else { return nil }
            let words = e.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let i = words.firstIndex(where: { $0.first.map { $0.isNumber || $0 == "-" } ?? false }), i > 0 else { return e }
            return ([shortSource(words[..<i].joined(separator: " "))] + words[i...]).joined(separator: " ")
        }
    }

    /// The PC model whose results own the imported rows of this variant (`pc.history` the vendors' values,
    /// `pc.history-derived` the `:import` ones); nil for any other variant.
    public static func owner(ofVariant v: String?) -> String? {
        guard let v, isImportVariant(v) else { return nil }
        return variants.contains(v) ? modelId : derivedModelId
    }

    /// `ALG-101:import` → `ALG-101`; nil for any other variant.
    public static func baseVariant(_ v: String?) -> String? {
        guard let v, v.hasSuffix(derivedSuffix), v.count > derivedSuffix.count else { return nil }
        return String(v.dropLast(derivedSuffix.count))
    }

    /// Own values 0, then the vendors' imports in `variants` order, then ours on imported history.
    public static func rank(_ m: Metric) -> Int {
        guard isImported(m) else { return 0 }
        if let i = variants.firstIndex(of: m.variant ?? "") { return 1 + i }
        return 1 + variants.count
    }

    /// Where an imported value came from, as the PC wrote it ("WHOOP via Apple Health", "WHOOP export"; ours on the
    /// backlog: `derivedSource`); nil for the app's own values.
    public static func sourceLabel(_ m: Metric) -> String? {
        guard isImported(m) else { return nil }
        if baseVariant(m.variant) != nil { return derivedSource }
        let s = m.source.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? memberLabel(m.variant) : s
    }

    /// A comparison-group member's name for an import variant ("WHOOP export", "ALG-101 on past data"); nil for any
    /// other variant.
    public static func memberLabel(_ variant: String?) -> String? {
        switch variant {
        case whoopExport: return "WHOOP export"
        case appleHealth: return "Apple Health"
        case appleWatch: return "Apple Watch"
        default: return baseVariant(variant).map { "\($0) on past data" }
        }
    }
}

/// Contract `$defs/daySummary` (`days/<date>/summary.json`).
public struct DaySummary: Codable, Hashable, Sendable {
    public var date: LocalDay
    public var strapId: String
    public var metrics: [Metric]
    public var firmware: String?
    public var appVersion: String?

    public init(date: LocalDay, strapId: String, metrics: [Metric], firmware: String? = nil, appVersion: String? = nil) {
        self.date = date
        self.strapId = strapId
        self.metrics = metrics
        self.firmware = firmware
        self.appVersion = appVersion
    }

    enum CodingKeys: String, CodingKey {
        case date = "date"
        case strapId = "strap_id"
        case metrics = "metrics"
        case firmware = "firmware"
        case appVersion = "app_version"
    }
}

/// Contract `$defs/series`: a regular series (hourly respiratory rate, hypnogram, workout HR map). `values` keeps
/// `null` entries (no data in that step).
public struct Series: Codable, Hashable, Sendable {
    public var name: String
    public var unit: String
    public var start: Date
    public var stepS: Double
    public var values: [Double?]
    public var n: [Int]?
    public var quality: [Double?]?
    public var state: [String?]?
    public var group: String?
    public var variant: String?
    public var tier: Tier?
    public var computedOn: ComputedOn?
    public var origin: Origin?

    public init(
        name: String,
        unit: String,
        start: Date,
        stepS: Double,
        values: [Double?],
        n: [Int]? = nil,
        quality: [Double?]? = nil,
        state: [String?]? = nil,
        group: String? = nil,
        variant: String? = nil,
        tier: Tier? = nil,
        computedOn: ComputedOn? = nil,
        origin: Origin? = nil
    ) {
        self.name = name
        self.unit = unit
        self.start = start
        self.stepS = stepS
        self.values = values
        self.n = n
        self.quality = quality
        self.state = state
        self.group = group
        self.variant = variant
        self.tier = tier
        self.computedOn = computedOn
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey {
        case name = "name"
        case unit = "unit"
        case start = "start"
        case stepS = "step_s"
        case values = "values"
        case n = "n"
        case quality = "quality"
        case state = "state"
        case group = "group"
        case variant = "variant"
        case tier = "tier"
        case computedOn = "computed_on"
        case origin = "origin"
    }
}

/// `days/<date>/series.json`: `{"date": D, "series": [...]}` (ARCHITECTURE.md 5.4; v0.5 `seriesFile`).
public struct SeriesFile: Codable, Hashable, Sendable {
    public var date: LocalDay
    public var series: [Series]

    public init(date: LocalDay, series: [Series]) {
        self.date = date
        self.series = series
    }
}

/// Contract `$defs/labResult` (PC Lab `results/<date>/<model_id>@<model_version>.json`). `status` / `reason` are a
/// proposed addition (approved by main 2026-10-11): ARCHITECTURE.md 6 has failed models write `status: "error"` and
/// R models `status: "skipped"`, each with a reason. Absent status = a normal result.
public struct LabResult: Codable, Hashable, Sendable {
    public var modelId: String
    public var modelVersion: String
    public var citation: String?
    public var date: LocalDay
    public var metrics: [Metric]
    public var inputsHash: String?
    public var status: String?
    public var reason: String?
    /// Every other key the PC wrote (roll-up key points, cause-finder tests, agreement rows, coach text …), kept as
    /// JSON so the phone can show them (wave 2, 2026-10-11: before this they were dropped on decode and never seen).
    /// `inputs` and `traceback` are left out (`droppedExtras`): long, and the inputs hash already stands for them.
    public var extra: [String: JSONValue]

    public static let droppedExtras: Set<String> = ["inputs", "traceback"]

    public init(
        modelId: String,
        modelVersion: String,
        citation: String? = nil,
        date: LocalDay,
        metrics: [Metric],
        inputsHash: String? = nil,
        status: String? = nil,
        reason: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.modelId = modelId
        self.modelVersion = modelVersion
        self.citation = citation
        self.date = date
        self.metrics = metrics
        self.inputsHash = inputsHash
        self.status = status
        self.reason = reason
        self.extra = extra
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case modelId = "model_id"
        case modelVersion = "model_version"
        case citation = "citation"
        case date = "date"
        case metrics = "metrics"
        case inputsHash = "inputs_hash"
        case status = "status"
        case reason = "reason"
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try c.decode(String.self, forKey: .modelId)
        modelVersion = try c.decode(String.self, forKey: .modelVersion)
        citation = try c.decodeIfPresent(String.self, forKey: .citation)
        date = try c.decode(LocalDay.self, forKey: .date)
        metrics = try c.decode([Metric].self, forKey: .metrics)
        inputsHash = try c.decodeIfPresent(String.self, forKey: .inputsHash)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        let known = Set(CodingKeys.allCases.map(\.rawValue)).union(LabResult.droppedExtras)
        let all = try decoder.container(keyedBy: AnyKey.self)
        var extra: [String: JSONValue] = [:]
        for k in all.allKeys where !known.contains(k.stringValue) {
            if let v = try? all.decode(JSONValue.self, forKey: k) { extra[k.stringValue] = v }
        }
        self.extra = extra
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelId, forKey: .modelId)
        try c.encode(modelVersion, forKey: .modelVersion)
        try c.encodeIfPresent(citation, forKey: .citation)
        try c.encode(date, forKey: .date)
        try c.encode(metrics, forKey: .metrics)
        try c.encodeIfPresent(inputsHash, forKey: .inputsHash)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(reason, forKey: .reason)
        var x = encoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        for (k, v) in extra where !known.contains(k) {
            try x.encode(v, forKey: AnyKey(stringValue: k))
        }
    }
}

/// Contract `$defs/syncReceipt` plus the v0.5 per-file fields `drop_id`, `name`, `duplicate` (ARCHITECTURE.md 5.5).
public struct SyncReceipt: Codable, Hashable, Sendable {
    public var rangeStart: Date
    public var rangeEnd: Date
    public var records: Int
    public var bytes: Int
    public var sha256: String
    public var receivedAt: Date
    public var pcName: String?
    public var dropId: String?
    public var name: String?
    public var duplicate: Bool?

    public init(
        rangeStart: Date,
        rangeEnd: Date,
        records: Int,
        bytes: Int,
        sha256: String,
        receivedAt: Date,
        pcName: String? = nil,
        dropId: String? = nil,
        name: String? = nil,
        duplicate: Bool? = nil
    ) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.records = records
        self.bytes = bytes
        self.sha256 = sha256
        self.receivedAt = receivedAt
        self.pcName = pcName
        self.dropId = dropId
        self.name = name
        self.duplicate = duplicate
    }

    enum CodingKeys: String, CodingKey {
        case rangeStart = "range_start"
        case rangeEnd = "range_end"
        case records = "records"
        case bytes = "bytes"
        case sha256 = "sha256"
        case receivedAt = "received_at"
        case pcName = "pc_name"
        case dropId = "drop_id"
        case name = "name"
        case duplicate = "duplicate"
    }
}

/// Contract `syncState.state`.
public enum SyncState: String, Codable, Sendable, CaseIterable {
    case notSetUp = "not_set_up"
    case pairing = "pairing"
    case offline = "offline"
    case online = "online"
    case error = "error"
}

/// Contract `$defs/syncState`: what the phone knows about the PC Lab. Shared by MGSync (`SyncEngine.status`) and
/// MGContext (`ContextInputs.sync`); added to MGDomain with main's approval 2026-10-11.
public struct SyncStatus: Codable, Hashable, Sendable {
    public var state: SyncState
    public var pcName: String?
    public var lastSynced: Date?
    public var unsyncedDays: Int?
    public var contractVersion: String
    public var error: String?
    public var lastReceipt: SyncReceipt?

    public init(
        state: SyncState,
        pcName: String? = nil,
        lastSynced: Date? = nil,
        unsyncedDays: Int? = nil,
        contractVersion: String = ContractInfo.version,
        error: String? = nil,
        lastReceipt: SyncReceipt? = nil
    ) {
        self.state = state
        self.pcName = pcName
        self.lastSynced = lastSynced
        self.unsyncedDays = unsyncedDays
        self.contractVersion = contractVersion
        self.error = error
        self.lastReceipt = lastReceipt
    }

    public static let notSetUp = SyncStatus(state: .notSetUp)

    enum CodingKeys: String, CodingKey {
        case state = "state"
        case pcName = "pc_name"
        case lastSynced = "last_synced"
        case unsyncedDays = "unsynced_days"
        case contractVersion = "contract_version"
        case error = "error"
        case lastReceipt = "last_receipt"
    }
}

/// Contract `$defs/profile`.
public struct Profile: Codable, Hashable, Sendable {
    public var birthDate: LocalDay?
    public var sex: Sex?
    public var heightCm: Double?
    public var weightKg: Double?
    public var hrMaxMeasured: Double?
    public var hrRestBaseline: Double?
    /// The medications list as the PC receives it (tracker #42, 2026-10-11; contract v0.5 `profileV05`): filled from
    /// Settings › Medications & supplements (the schedules) when the profile is sent — not edited here, not stored
    /// with the profile on the phone.
    public var medications: [MedSchedule]?
    /// Settings â€º Sun vitamin D: the Fitzpatrick quiz result and hand-entered rough location sent to the PC estimate.
    public var fitzpatrickSkinType: Int?
    public var vitaminDLocation: VitaminDRoughLocation?
    /// T9918 (2026-10-17): the newest tape size of each kind (waist, hip, neck ...) from the Log scan entries, sent with the
    /// profile so the PC profile holds the Me sizes. Filled when the profile is sent, never stored with the profile.
    public var bodySizes: [String: BodySize]?
    /// D-LOAD-WALK-2 (2026-10-17): fat-free mass in kg from the PC's body-composition scan (InBody), already adjusted to the
    /// current weight. NOT a contract field and never sent: filled from the PC profile snapshot by `EffectiveProfile.merged`
    /// (resting calories use Cunningham 1980 on it, flagged 'from scan').
    public var fatFreeMassKg: Double? = nil

    public enum Sex: String, Codable, Hashable, Sendable, CaseIterable {
        case male = "male"
        case female = "female"
        case other = "other"
    }

    public init(
        birthDate: LocalDay? = nil,
        sex: Sex? = nil,
        heightCm: Double? = nil,
        weightKg: Double? = nil,
        hrMaxMeasured: Double? = nil,
        hrRestBaseline: Double? = nil,
        medications: [MedSchedule]? = nil,
        fitzpatrickSkinType: Int? = nil,
        vitaminDLocation: VitaminDRoughLocation? = nil,
        bodySizes: [String: BodySize]? = nil,
        fatFreeMassKg: Double? = nil
    ) {
        self.birthDate = birthDate
        self.sex = sex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.hrMaxMeasured = hrMaxMeasured
        self.hrRestBaseline = hrRestBaseline
        self.medications = medications
        self.fitzpatrickSkinType = fitzpatrickSkinType
        self.vitaminDLocation = vitaminDLocation
        self.bodySizes = bodySizes
        self.fatFreeMassKg = fatFreeMassKg
    }

    enum CodingKeys: String, CodingKey {
        case birthDate = "birth_date"
        case sex = "sex"
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case hrMaxMeasured = "hr_max_measured"
        case hrRestBaseline = "hr_rest_baseline"
        case medications = "medications"
        case fitzpatrickSkinType = "fitzpatrick_skin_type"
        case vitaminDLocation = "vitamin_d_location"
        case bodySizes = "body_sizes"
    }
}

/// One tape size: the value in cm and the local day it was measured (`yyyy-MM-dd`).
public struct BodySize: Codable, Hashable, Sendable {
    public var cm: Double
    public var on: String

    public init(cm: Double, on: String) {
        self.cm = cm
        self.on = on
    }
}

/// A place typed by the user for the sunlight vitamin D estimate. Coordinates are intentionally only one decimal.
public struct VitaminDRoughLocation: Codable, Hashable, Sendable {
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    enum CodingKeys: String, CodingKey {
        case name
        case latitude = "lat"
        case longitude = "lon"
    }
}

/// Contract `$defs/schedule` (medication / supplement schedule). `times` are local "HH:MM".
/// It doubles as the medications list (tracker #42, 2026-10-11; contract v0.5 `scheduleFieldsV05`, additive):
/// `purpose`, `started`, `stopped`, `asNeeded`. A stopped or as-needed entry has no reminders by itself.
public struct MedSchedule: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: Kind?
    public var dose: Double?
    public var unit: String?
    public var times: [String]?
    public var days: [Weekday]?
    public var reminder: Bool?
    public var buzz: Bool?
    /// What it is for, in Mo's words (v0.5).
    public var purpose: String?
    public var started: LocalDay?
    public var stopped: LocalDay?
    /// Taken when needed, not on a schedule (v0.5).
    public var asNeeded: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, dose, unit, times, days, reminder, buzz, purpose, started, stopped
        case asNeeded = "as_needed"
    }

    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case prescription = "prescription"
        case supplement = "supplement"
        case otc = "otc"
    }

    public enum Weekday: String, Codable, Hashable, Sendable, CaseIterable {
        case mon = "mon"
        case tue = "tue"
        case wed = "wed"
        case thu = "thu"
        case fri = "fri"
        case sat = "sat"
        case sun = "sun"
    }

    public init(
        id: String,
        name: String,
        kind: Kind? = nil,
        dose: Double? = nil,
        unit: String? = nil,
        times: [String]? = nil,
        days: [Weekday]? = nil,
        reminder: Bool? = nil,
        buzz: Bool? = nil,
        purpose: String? = nil,
        started: LocalDay? = nil,
        stopped: LocalDay? = nil,
        asNeeded: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.dose = dose
        self.unit = unit
        self.times = times
        self.days = days
        self.reminder = reminder
        self.buzz = buzz
        self.purpose = purpose
        self.started = started
        self.stopped = stopped
        self.asNeeded = asNeeded
    }

    /// Taken now: started (or no start given) and not stopped on or before `day`.
    public func isCurrent(on day: LocalDay) -> Bool {
        (started.map { $0 <= day } ?? true) && (stopped.map { $0 > day } ?? true)
    }
}
