import Foundation
import MGDomain

// WP-22 Pipelines — shared pieces: constants, local-time helpers, stream de-duplication, the metric specs no family
// owns, and the output checks. Python mirror: app/pclab/golden/gen_pipelines.py (same names, same order).
// WRITTEN, NOT COMPILED.

/// Pipeline constants. Each one is a choice of this package (ours v0) or a family rule, cited.
public enum PipelineConstants {
    /// Night search span: 18:00 the evening before → 18:00 on the wake day (Sleep README "recommended span").
    public static let nightSpanStartHour: Int64 = 18
    /// Heart rate is loaded this far before the night search span (12 h) for the `hr_dip` day side. Since ALG-012 v2 the day
    /// side is the awake heart rate 10:00-20:00 local on the day before the night, else all awake heart rate before the sleep
    /// period (NightPipeline.dipMetric); this is only how much history is read.
    public static let dipDaySideSeconds: Int64 = 12 * 3600
    /// Longest baseline any member reads (MS-20 rmssd_3mo = 90 nights).
    public static let historyDays = 90
    /// ALG-036 in band / ALG-075 robust z / ALG-101 / ALG-110 / ALG-112 baseline length.
    public static let readyComponentDays = 28
    /// ALG-054 / ALG-123:daytime baseline length (days).
    public static let stressDailyDays = 30
    /// ALG-030 SRI / IS / IV span.
    public static let regularityDays = 14
    /// ALG-116 chronotype span; ALG-115 free-night span.
    public static let chronoDays = 28
    /// A sleep period ending within 5 min of the last strap record may still be running: the result is provisional
    /// and WP-23 re-runs the night after the next history download (ours v0).
    public static let provisionalSeconds: Int64 = 300
    /// APP-104 / WP-19: fewer paired days → blank "too few days".
    public static let matrixMinPairs = 14
    /// ALG-020 hourly series step.
    public static let hourSeconds: Int64 = 3600
    public static let daySeconds: Int64 = 86_400
}

/// Local-time arithmetic for one run (D13: nights belong to the wake day, events to the local date of `at`).
public struct PipelineClock: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Unix seconds of local midnight starting `day`.
    public func dayStart(_ day: LocalDay) -> Int64 {
        Int64(day.start(in: timeZone).timeIntervalSince1970.rounded(.down))
    }

    /// [18:00 on day − 1, 18:00 on day): the span searched for the night that ends on `day`.
    public func nightSpan(_ day: LocalDay) -> (start: Int64, end: Int64) {
        (dayStart(day.adding(days: -1)) + PipelineConstants.nightSpanStartHour * 3600,
         dayStart(day) + PipelineConstants.nightSpanStartHour * 3600)
    }

    public func localDay(_ unix: Double) -> LocalDay {
        LocalDay(date: Date(timeIntervalSince1970: unix.rounded(.down)), calendar: calendar)
    }

    public func offsetSeconds(at unix: Double) -> Int {
        timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: unix))
    }

    /// Local hour of day 0…23.
    public func hourOfDay(_ unix: Int64) -> Int {
        let off = Int64(offsetSeconds(at: Double(unix)))
        let s = ((unix + off) % 86_400 + 86_400) % 86_400
        return Int(s / 3600)
    }

    /// Monday-first weekday of `day` (1970-01-01 was a Thursday).
    public static func weekday(_ day: LocalDay) -> MedSchedule.Weekday {
        let n = DayCalendar.dayNumber(day)
        let order: [MedSchedule.Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]
        return order[((n % 7) + 7 + 3) % 7]
    }

    /// "Must be up by" for the morning of `day` as unix s, nil when that weekday has none (a free morning).
    public func mustBeUp(_ settings: PipelineSettings, on day: LocalDay) -> Int64? {
        guard let hm = settings.mustBeUpBy[PipelineClock.weekday(day)] else { return nil }
        let parts = hm.split(separator: ":")
        guard parts.count == 2, let h = Int64(parts[0]), let m = Int64(parts[1]), (0..<24).contains(h),
              (0..<60).contains(m) else { return nil }
        return dayStart(day) + h * 3600 + m * 60
    }
}

/// Stream helpers. MGStore returns one row per (strap, source); a beat seen live and again in the history download is
/// two rows, so every pipeline de-duplicates first (HRVWindows: "caller removes duplicate sources").
public enum PipelineStreams {
    static func sourceRank(_ s: StreamSource) -> Int {
        switch s {
        case .history: return 0
        case .live: return 1
        case .std2A37: return 2
        }
    }

    /// R-R by (ts, ord), the history copy first; result sorted by (ts, ord) (heart order).
    public static func dedupe(_ points: [RRPoint]) -> [RRPoint] {
        var best: [String: RRPoint] = [:]
        for p in points {
            let k = "\(p.ts):\(p.ord)"
            if let b = best[k], sourceRank(b.source) <= sourceRank(p.source) { continue }
            best[k] = p
        }
        return BeatClock.sorted(Array(best.values))
    }

    /// HR by ts, the history copy first; sorted by ts.
    public static func dedupe(_ points: [HRPoint]) -> [HRPoint] {
        var best: [Int64: HRPoint] = [:]
        for p in points {
            if let b = best[p.ts], sourceRank(b.source) <= sourceRank(p.source) { continue }
            best[p.ts] = p
        }
        return best.values.sorted { $0.ts < $1.ts }
    }

    /// R18 by ts (the first row of a second wins); sorted by ts.
    public static func dedupe(_ rows: [R18Second]) -> [R18Second] {
        var seen = Set<Int64>()
        var out: [R18Second] = []
        for r in rows.sorted(by: { $0.ts < $1.ts }) where !seen.contains(r.ts) {
            seen.insert(r.ts)
            out.append(r)
        }
        return out
    }

    /// Points with a ≤ ts ≤ b (both ends, as the PC's bisect_left / bisect_right).
    public static func rr(_ points: [RRPoint], _ a: Double, _ b: Double) -> [RRPoint] {
        points.filter { Double($0.ts) >= a && Double($0.ts) <= b }
    }

    public static func hr(_ points: [HRPoint], _ a: Double, _ b: Double) -> [HRPoint] {
        points.filter { Double($0.ts) >= a && Double($0.ts) <= b }
    }

    /// Rows with a ≤ ts < b.
    public static func r18(_ rows: [R18Second], _ a: Double, _ b: Double) -> [R18Second] {
        rows.filter { Double($0.ts) >= a && Double($0.ts) < b }
    }
}

/// Metric specs for the members no family file declares (registry names and variants, ARCHITECTURE 8.3).
public enum PipelineSpecs {
    static let methodPrefix = "WP-22@1"

    /// G-HRMAX member "MS-05:formula" — the HRmax term inside Mo's script (vo2max_orchard: 208 − 0.8 × age).
    public static let hrmaxScript = MetricSpec(
        key: .hrmax, unit: "bpm", group: "G-HRMAX", variant: "MS-05:formula",
        method: "MS-05 vo2max_orchard (Orchard) HRmax term 208 - 0.8 x age", tier: .estimate, source: "profile",
        window: "profile", producer: .script, citation: MSCatalogue.citation, paramsVersion: MSCatalogue.paramsVersion)
    /// G-STEPS member "apple": Apple Health step count, one device's day total (Apple de-duplicates across devices,
    /// the hourly events here do not, so sources are never summed).
    public static let stepsApple = MetricSpec(
        key: .steps, unit: "count", group: "G-STEPS", variant: "apple", method: "\(methodPrefix) health-steps-max-source",
        tier: .high, source: "apple health", window: "day", producer: .apple)
    /// G-STEPS member "apple_watch": the same Apple Health day total when the winning source is the Apple Watch (bug 19: the
    /// PC writes its Watch count under this variant, the phone now does too instead of labelling it "iPhone").
    public static let stepsAppleWatch = MetricSpec(
        key: .steps, unit: "count", group: "G-STEPS", variant: "apple_watch",
        method: "\(methodPrefix) health-steps-pc-source-rule", tier: .high, source: "apple health", window: "day",
        producer: .apple)
    /// G-STEPS member "merged" (r9o, D-LOAD-WALK-1 items 5 and 12): the day's steps per hour, the phone's where it was carried, the
    /// strap's (counter or wrist model) in the hours the phone missed; the note names the mix. Ours; the rule is labelled so.
    public static let stepsMerged = MetricSpec(
        key: .steps, unit: "count", group: "G-STEPS", variant: "merged", method: StepsMerge.method, tier: .estimate,
        source: "apple health + strap", window: "day", producer: .ours,
        citation: "ours (ALG-040:merged v2); the 100-step floor, the one-half ratio and the 5-step gap gate are not from a paper. Wrist model = the peak-detection family compared in Marcotte et al. 2024; Small et al. (OxWearables stepcount, UK Biobank) is the ML alternative, not ported",
        paramsVersion: StepsMerge.paramsVersion)
    /// G-CAL member "apple": Apple Health active energy, same one-source rule.
    public static let caloriesApple = MetricSpec(
        key: .caloriesActive, unit: "kcal", group: "G-CAL", variant: "apple",
        method: "\(methodPrefix) health-active-energy-max-source", tier: .high, source: "apple health", window: "day",
        producer: .apple)
    /// G-VO2 member "apple": the latest Apple Health VO2max sample of the day (Watch outdoor walks / runs).
    public static let vo2Apple = MetricSpec(
        key: .vo2max, unit: "ml_kg_min", group: "G-VO2", variant: "apple",
        method: "\(methodPrefix) health-vo2max-latest", tier: .high, source: "apple health", window: "day",
        producer: .apple)
    /// A copy of `spec` written for one workout (window "workout:<first 8 of the event id>", as the PC).
    public static func forWorkout(_ spec: MetricSpec, id8: String) -> MetricSpec {
        var s = spec
        s.window = "workout:\(id8)"
        return s
    }

    /// First 8 characters of the event id, lowercase (contract ids are lowercase; UUID prints uppercase).
    public static func id8(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }
}

extension Optional where Wrapped == Double {
    /// The value, or `Missing(reason)` (R6: a blank carries its reason, never a default number).
    func orMissing(_ reason: String) -> Computed<Double> {
        if let v = self { return .success(v) }
        return .missing(reason)
    }
}

/// Output helpers shared by the pipelines.
public enum PipelineOutput {
    /// The store key of a metric, "name|variant|window" (MetricKeyID without the day).
    public static func key(_ m: Metric) -> String {
        "\(m.name)|\(m.variant ?? "")|\(m.window ?? "")"
    }

    /// `base` with every metric of `fresh` replacing the one with the same key; sorted (name, variant, window) like the
    /// stored day summary, so "first matching metric" reads the same row on the phone and on the PC.
    public static func merge(_ base: [Metric], _ fresh: [Metric]) -> [Metric] {
        var byKey: [String: Metric] = [:]
        for m in base { byKey[key(m)] = m }
        for m in fresh { byKey[key(m)] = m }
        return byKey.values.sorted { a, b in
            (a.name, a.variant ?? "", a.window ?? "") < (b.name, b.variant ?? "", b.window ?? "")
        }
    }

    /// Every metric passes `Metric.validate()` (R6) and no two share a store key; a failing metric is replaced by a
    /// blank naming the problem (never dropped, never written as a number). Returns the checked list and the problems.
    public static func checked(_ metrics: [Metric]) -> (metrics: [Metric], problems: [String]) {
        var out: [Metric] = []
        var problems: [String] = []
        var seen = Set<String>()
        for var m in metrics {
            let k = key(m)
            if seen.contains(k) {
                problems.append("duplicate store key \(k): the later one is left out")
                continue
            }
            seen.insert(k)
            let v = m.validate()
            if !v.isEmpty {
                problems.append(contentsOf: v)
                m.value = nil
                m.note = "not written: " + v.joined(separator: "; ")
                if m.group != nil, (m.variant ?? "").isEmpty { m.variant = "unknown" }
            }
            out.append(m)
        }
        return (out, problems)
    }

    /// Appends `text` to a metric's note (values keep their number; blanks keep their reason first).
    static func addNote(_ m: inout Metric, _ text: String) {
        if let n = m.note, !n.isEmpty { m.note = n + "; " + text } else { m.note = text }
    }

    /// A one-value carry series (pipeline state other days read back as a baseline, e.g. the night's raw skin-temp
    /// median): start = the span start, step = the span length.
    static func carry(_ name: String, variant: String?, start: Int64, stepS: Int64, value: Double, n: Int? = nil,
                      unit: String, tier: Tier?) -> Series {
        Series(name: name, unit: unit, start: Date(timeIntervalSince1970: Double(start)), stepS: Double(max(1, stepS)),
               values: [value], n: n.map { [$0] }, variant: variant, tier: tier, computedOn: .phone)
    }
}
