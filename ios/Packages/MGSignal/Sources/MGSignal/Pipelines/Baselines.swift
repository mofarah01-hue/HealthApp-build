import Foundation
import MGDomain

// WP-22 Baselines — the stored history every rolling-window rule reads. Each family keeps its own window rule (ALG-101:
// 28 nights, ≥ 14; ALG-123:daily: 30 days, ≥ 14; ALG-110: 28 nights, ≥ 14; ALG-036 / ALG-075 components: 28, ≥ 14;
// ALG-112: 28, ≥ 10; ALG-036 quiet level: 28 days, ≥ 3; CTL/ATL: calendar days, unobserved skipped; Mo's script members:
// the PC's ceil(0.7 × window) rule, ms_inputs.min_days). This file only hands each one its calendar-dense input.
// Python mirror: gen_pipelines.py `hval`, `dense`, `hseries0`, `dense_series0`. WRITTEN, NOT COMPILED.

/// Metrics, series and events of earlier days, as stored. "First matching metric" = the PC's
/// `ms_inputs.DayData.metric` choice, so phone and PC read the same history value.
public struct MetricHistory: Sendable {
    public var metrics: [LocalDay: [Metric]]
    public var series: [LocalDay: [Series]]
    /// Events per local day of `at` (D13); a day with no key was not loaded.
    public var events: [LocalDay: [EventRecord]]
    /// Imported WHOOP / Apple Health values per day (`ImportedHistory.variants`, pc.history rows): what the learners and
    /// baselines read when the app has no value of its own that day (W10, 2026-10-11, Mo: "most of the empty cells is
    /// shit we can compute or have" — 12 months of imported nights were ignored). Inputs only: an output computed from
    /// them is still ours, and `importedDays` lets its note say how many inputs were imported.
    public var imported: [LocalDay: [Metric]] = [:]

    /// The names a learner may take from an import, with the only unit accepted (a value is never converted).
    public static let importFallback: [String: String] = [
        "sleep_onset": "unix_s", "wake_time": "unix_s", "sleep_total": "min", "sleep_efficiency": "fraction",
        "sleep_latency": "min", "sleep_deep": "min", "sleep_rem": "min", "sleep_light": "min", "sleep_need": "min",
        "sleep_debt": "min", "rhr": "bpm", "hrv_rmssd": "ms", "resp_rate": "br_min", "strain": "score_0_21",
        "vo2max": "ml_kg_min",
    ]

    public init(metrics: [LocalDay: [Metric]] = [:], series: [LocalDay: [Series]] = [:],
                events: [LocalDay: [EventRecord]] = [:]) {
        self.metrics = metrics
        self.series = series
        self.events = events
    }

    public static let empty = MetricHistory()

    /// The first stored metric of `day` matching (name, variant?, window?): its value; when the app's own row is absent
    /// or blank, the imported value of the same name and window (`importedValue`); nil when neither has one.
    public func value(_ name: String, variant: String? = nil, window: String? = nil, on day: LocalDay) -> Double? {
        if let rows = metrics[day] {
            for m in rows {
                guard m.name == name else { continue }
                if let variant, m.variant != variant { continue }
                if let window, m.window != window { continue }
                if let v = m.value, v.isFinite { return v }
                break
            }
        }
        return importedValue(name, variant: variant, window: window, on: day)
    }

    /// The imported value (WHOOP's export first, then Apple Health) of `name` on `day`, for a learner reading `variant`:
    /// only names in `importFallback`, in that unit, same window. `strain` only for ALG-036 (WHOOP's 0–21 scale; the
    /// MS-01 / MS-02 TRIMP strain is another unit). `hrv_ln_rmssd` is ln of the imported RMSSD.
    public func importedValue(_ name: String, variant: String? = nil, window: String? = nil,
                              on day: LocalDay) -> Double? {
        guard let rows = imported[day], !rows.isEmpty else { return nil }
        if name == "hrv_ln_rmssd" {
            return importedValue("hrv_rmssd", variant: nil, window: window, on: day).flatMap { $0 > 0 ? Foundation.log($0) : nil }
        }
        guard let unit = Self.importFallback[name] else { return nil }
        if name == "strain", let variant, variant != "ALG-036" { return nil }
        for v in ImportedHistory.variants {
            for m in rows where m.name == name && m.variant == v && m.unit == unit {
                if let window, (m.window ?? window) != window { continue }
                if let x = m.value, x.isFinite { return x }
            }
        }
        return nil
    }

    /// r9h (audit 6.6): the app's OWN stored value only. No import fallback, so a baseline built from it never mixes in
    /// WHOOP's or Apple's number (another algorithm and window). nil when the day has no finite own value.
    public func ownValue(_ name: String, variant: String? = nil, window: String? = nil, on day: LocalDay) -> Double? {
        guard let rows = metrics[day] else { return nil }
        for m in rows {
            guard m.name == name else { continue }
            if let variant, m.variant != variant { continue }
            if let window, m.window != window { continue }
            if let v = m.value, v.isFinite { return v }
            break
        }
        return nil
    }

    /// `days` own values ending the day before `day`, oldest first (`dense` without the import fallback).
    public func ownDense(_ name: String, variant: String?, window: String?, before day: LocalDay, days: Int) -> [Double?] {
        guard days > 0 else { return [] }
        return (1...days).reversed().map { ownValue(name, variant: variant, window: window, on: day.adding(days: -$0)) }
    }

    /// Days in `days` whose value of `name` came from an import (for notes: "12 of 14 nights from WHOOP's export").
    public func importedDays(_ name: String, variant: String? = nil, window: String? = nil, among days: [LocalDay]) -> Int {
        days.filter { d in
            let own = (metrics[d] ?? []).contains { $0.name == name && (variant == nil || $0.variant == variant)
                && (window == nil || $0.window == window) && ($0.value?.isFinite ?? false) }
            return !own && importedValue(name, variant: variant, window: window, on: d) != nil
        }.count
    }

    /// Values of the `days` days BEFORE `day`, oldest first, nil = no value that day (never imputed).
    public func dense(_ name: String, variant: String?, window: String?, before day: LocalDay, days: Int) -> [Double?] {
        guard days > 0 else { return [] }
        return (1...days).reversed().map { value(name, variant: variant, window: window, on: day.adding(days: -$0)) }
    }

    /// First value of the day's carry series `name` (one-value series the pipelines write), nil when absent.
    public func series0(_ name: String, on day: LocalDay) -> Double? {
        guard let rows = series[day] else { return nil }
        for s in rows where s.name == name {
            guard let first = s.values.first else { continue }
            guard let v = first, v.isFinite else { return nil }
            return v
        }
        return nil
    }

    public func denseSeries0(_ name: String, before day: LocalDay, days: Int) -> [Double?] {
        guard days > 0 else { return [] }
        return (1...days).reversed().map { series0(name, on: day.adding(days: -$0)) }
    }

    /// Stored metrics of `day` (empty when none).
    public func day(_ day: LocalDay) -> [Metric] { metrics[day] ?? [] }

    public func eventsOn(_ day: LocalDay) -> [EventRecord] { events[day] ?? [] }
}

/// Loading the history for one run, and the carry-series names the pipelines write for later baselines.
public enum Baselines {
    /// Night: the night's raw skin-temperature median (ALG-110 baseline, ALG-036 temp component, ALG-112).
    public static let skinTempNightRaw = "skin_temp_night_raw"
    /// Day: the day's quiet-waking level (ALG-036 personal quiet level of later days).
    public static let quietHRRDay = "quiet_hrr_day"
    /// Day: net TRIMP above quiet (ALG-036 CTL / ATL daily load).
    public static let netTrimpDay = "net_trimp_day"
    /// Day: the day's two FLEX-HR ingredients (ALG-048 v2, Spurr 1988): 95th percentile HR of still minutes, 5th percentile HR of
    /// walk / run minutes. Later days take the median over 28 days.
    public static let flexRestHighDay = "flex_rest_high_day"
    public static let flexExerciseLowDay = "flex_exercise_low_day"
    /// Day: the day's plain Banister TRIMP over its worn waking minutes (ALG-036:week, r9p).
    public static let trimpDay = "trimp_day"
    /// Day: TRIMP of the day's sessions of one type, name = prefix + type slug (ALG-036:score history, r9p).
    public static let sessionTrimpPrefix = "session_trimp_"
    /// Day: sweat loss (ml) and minutes of the day's sessions with both weights logged (ALG-135 sweat rate, r9p).
    public static let sweatMlDay = "sweat_ml_day"
    public static let sweatMinDay = "sweat_min_day"
    /// Day: strap step-counter ticks (ALG-040 ticks-per-step calibration).
    public static let stepTicksDay = "step_ticks_day"
    /// Day: per-5-min HR and lnRMSSD of clean, non-exercise waking windows (ALG-054 hour-of-day baseline).
    public static let hr5min = "hr_5min"
    public static let lnRmssd5min = "hrv_ln_rmssd_5min"
    /// Day: ALG-030 minute activity (Σ |Δ z-angle| per minute; SRI / IS / IV over 14 days).
    public static let motionMinute = "motion_minute"

    /// Metrics, series and events of the `days` days before `day` (and the events of `day` itself).
    public static func load(source: any PipelineSource, before day: LocalDay, days: Int = PipelineConstants.historyDays,
                            clock: PipelineClock) async throws -> MetricHistory {
        var h = MetricHistory()
        guard days > 0 else { return h }
        for k in 1...days {
            let d = day.adding(days: -k)
            let ms = try await source.metrics(on: d)
            if !ms.isEmpty { h.metrics[d] = ms }
            let ss = try await source.series(on: d)
            if !ss.isEmpty { h.series[d] = ss }
        }
        let from = Date(timeIntervalSince1970: Double(clock.dayStart(day.adding(days: -days))))
        let to = Date(timeIntervalSince1970: Double(clock.dayStart(day.adding(days: 1)) - 1))
        let evs = try await source.events(from: from, to: to, types: nil, includeRemoved: false)
        for k in 0...days { h.events[day.adding(days: -k)] = [] }        // loaded: an empty day is "nothing logged"
        for e in evs {
            h.events[clock.localDay(e.at.timeIntervalSince1970), default: []].append(e)
        }
        h.imported = try await loadImported(source: source, from: day.adding(days: -days), to: day)
        return h
    }

    /// Imported rows (`ImportedHistory.variants`) of the `MetricHistory.importFallback` names, per day, `from`…`to`
    /// inclusive (the run's own day included: last night may exist only as an import).
    public static func loadImported(source: any PipelineSource, from: LocalDay,
                                   to: LocalDay) async throws -> [LocalDay: [Metric]] {
        var out: [LocalDay: [Metric]] = [:]
        for name in MetricHistory.importFallback.keys.sorted() {
            for row in try await source.importedMetrics(named: name, from: from, to: to)
            where ImportedHistory.isImported(row.metric) && ImportedHistory.variants.contains(row.metric.variant ?? "")
                && (row.metric.value?.isFinite ?? false) {
                out[row.day, default: []].append(row.metric)
            }
        }
        return out
    }
}
