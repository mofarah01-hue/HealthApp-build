import Foundation
import MGDomain

// Sleep expanded (Mo, Nov 5 2026): "the primary is always shown first. On the main dashboard in the quick looks, if you click to
// expand a card, whether in Explore or the sleep thing, we get a full breakdown of sleep." Spec: sleep-expanded-layouts-CHATGPT-2026-11-05.md
// §"Recommended design" (A. dashboard card, B. expanded breakdown 1-10, source-fusion rules) and stager-comparison-2026-11-05.md.
//
// Rules this file keeps (each has a test in SleepBreakdownTests):
//   * Everything starts from `sleepFill()` (D-SLEEP-PRIORITY-1): the card and the breakdown use the same pill, the same "also:" line
//     and the same headline; nothing here picks a source again.
//   * No efficiency, awake-after-onset, awakenings or latency for a night made from our own raw data: the strap's sleep flag reports
//     no short wakes, so they would read better than the night was. They show only for a source that measures them (Apple Watch,
//     WHOOP's own rows) and only when that source is the headline.
//   * Deep and REM are estimates (ALG-151, kappa about 0.5 against sleep-lab staging) and carry the label.
//   * Nothing is merged: Apple Watch stages are an overlay beside the headline's, R-R / HRV / temperature are never pooled across
//     devices, a baseline made of another device's nights is flagged.
//   * CLAUDE.md rule 4: skin temperature only as the labelled deviation from your baseline (decoded, untested), SpO2 only from a
//     named source, a breathing rate we derive labelled estimate. No raw count carries a unit.
//   * A missing figure is a grey cell with the reason, never an invented number.
public enum SleepBreakdownPresenter {
    /// The other sources differ from the headline by more than this: "N sources · review" (spec §A: > 30 min total).
    static let reviewMinutes = 30.0
    /// A personal baseline needs this many earlier nights.
    static let baselineNights = 5
    /// The metrics the card's baselines and the trends read (`ExploreInput.sleepTrends`).
    public static let trendKeys: [MetricKey] = [.sleepTotal, .rhr, .hrvRmssd, .respRate, .skinTempDev]
    /// The story mentions a deviation only when it is this large.
    static let hrvStoryPercent = 5.0
    static let rhrStoryBpm = 3.0
    static let binSeconds: TimeInterval = 300

    // MARK: Entry points

    /// §A: the dashboard card.
    public static func card(_ s: PresenterSnapshot) -> SleepCardState { Build(s).card() }

    // MARK: Small formatting helpers

    /// "7 h 18" for minutes; nil for nothing.
    static func dur(_ m: Double?) -> String? { m.flatMap { $0.isFinite ? MetricText.minutes($0) : nil } }

    /// A DisplayValue's text with its unit; nil for a blank.
    static func plain(_ d: DisplayValue) -> String? {
        if case let .value(text, unit, _, _, _) = d { return [text, unit].compactMap { $0 }.joined(separator: " ") }
        return nil
    }

    static func ms(_ v: Double) -> String { MGFormat.number(v, decimals: 0) + " ms" }
    static func bpm(_ v: Double) -> String { MGFormat.number(v, decimals: 0) + " bpm" }

    static func median(_ xs: [Double]) -> Double? {
        let v = xs.filter { $0.isFinite }
        return v.isEmpty ? nil : NightPresenter.median(v)
    }

    /// One personal baseline: the median of earlier nights, how many, and whether another device's nights are in it.
    struct Baseline: Equatable {
        var median: Double
        var nights: Int
        var mixed: Bool
    }

    // MARK: The build

    /// One pass over the snapshot: the resolver's decision, the night window and the series are worked out once.
    struct Build {
        let s: PresenterSnapshot
        let fill: SleepFillResult
        let runs: [StageSegment]
        let window: DateInterval?
        let hr: [LaneMark]
        let hrCoverage: Double?
        let isOwn: Bool
        let label: String?
        let status: SleepNightStatus

        init(_ s: PresenterSnapshot) {
            self.s = s
            let f = s.sleepFill()
            fill = f
            status = s.sleepNightStatus(f)
            let r = f.fill == .notProcessed ? [] : DialPresenter.stageRuns(s)
            runs = r
            let asleep = r.filter { $0.stage != .awake }
            if let a = asleep.map(\.start).min(), let b = asleep.map(\.end).max(), b > a {
                window = DateInterval(start: a, end: b)
            } else {
                window = f.fill == .notProcessed ? nil : (f.window ?? s.strapAsleepSpan())
            }
            switch f.fill {
            case .strapFlag, .phone, .pc: isOwn = true
            default: isOwn = false
            }
            label = f.fill == .imported ? f.metric.map { PresenterSnapshot.alsoLabel($0.source) } : nil
            let w = window
            hr = w.map { Build.binned(Build.hrSeries(s), in: $0, reduce: { NightPresenter.median($0) }) } ?? []
            hrCoverage = w.flatMap { Build.coverage(Build.hrSeries(s), in: $0) }
        }

        // MARK: Series

        static func hrSeries(_ s: PresenterSnapshot) -> [Series] {
            (s.dialSeries + s.series).filter { $0.name == DialSeries.hrName }
        }

        /// One mark per `binSeconds` bin of the window: `reduce` over the bin's finite values, optionally mapped first.
        static func binned(_ series: [Series], in w: DateInterval, map: (Double) -> Double = { $0 },
                           reduce: ([Double]) -> Double) -> [LaneMark] {
            var bins: [Int: [Double]] = [:]
            for x in series where x.stepS > 0 {
                for (i, v) in x.values.enumerated() {
                    guard let v, v.isFinite else { continue }
                    let t = x.start.addingTimeInterval(Double(i) * x.stepS)
                    guard t >= w.start, t < w.end else { continue }
                    bins[Int(t.timeIntervalSince(w.start) / SleepBreakdownPresenter.binSeconds), default: []].append(map(v))
                }
            }
            return bins.keys.sorted().compactMap { k in
                let v = reduce(bins[k] ?? [])
                return v.isFinite
                    ? LaneMark(at: w.start.addingTimeInterval(Double(k) * SleepBreakdownPresenter.binSeconds), value: v) : nil
            }
        }

        /// The share of the window's 5-minute bins that hold a value; nil with no series at all.
        static func coverage(_ series: [Series], in w: DateInterval) -> Double? {
            guard !series.isEmpty, w.duration >= SleepBreakdownPresenter.binSeconds else { return nil }
            let total = Int((w.duration / SleepBreakdownPresenter.binSeconds).rounded(.up))
            let hit = Set(binned(series, in: w, reduce: { $0.first ?? .nan }).map {
                Int($0.at.timeIntervalSince(w.start) / SleepBreakdownPresenter.binSeconds)
            })
            return min(1, Double(hit.count) / Double(total))
        }

        func pct(_ v: Double?) -> String? { v.map { MGFormat.number($0 * 100, decimals: 0) + "%" } }

        // MARK: Baselines

        /// The median of the up-to-28 nights before this one, from the stored trend; nil with fewer than `baselineNights`.
        func baseline(_ key: MetricKey, nightIsImported: Bool) -> Baseline? {
            guard let a = s.explore.sleepTrends.first(where: { $0.key == key.rawValue }) else { return nil }
            let prior = a.points.filter { $0.day < s.day }.suffix(28).compactMap { $0.value }.filter { $0.isFinite }
            guard prior.count >= SleepBreakdownPresenter.baselineNights, let m = SleepBreakdownPresenter.median(prior) else { return nil }
            return Baseline(median: m, nights: prior.count, mixed: !a.importedDays.isEmpty != nightIsImported)
        }

        // MARK: Pieces shared by the card and the breakdown

        /// Source word for a value: "ours" or the importing source's short name.
        func writer(_ m: Metric) -> String {
            ImportedHistory.isImported(m) ? PresenterSnapshot.alsoLabel(m.source) : "ours"
        }

        struct Night {
            var hrv: Metric?
            var hrvBase: Baseline?
            var rhr: Metric?
            var rhrBase: Baseline?
            var resp: Metric?
            var respBase: Baseline?
            var temp: Double?
            var tempMetric: Metric?
        }

        func night() -> Night {
            var n = Night()
            n.hrv = s.nightRmssd() ?? s.nightSdnn()
            n.hrvBase = n.hrv.flatMap { m in
                HRVLabel.kind(m) == .rmssd ? baseline(.hrvRmssd, nightIsImported: ImportedHistory.isImported(m)) : nil
            }
            if let r = s.metric(.rhr), r.value?.isFinite ?? false {
                n.rhr = r
                n.rhrBase = baseline(.rhr, nightIsImported: ImportedHistory.isImported(r))
            }
            if let r = s.metric(.respRate, window: "night"), r.value?.isFinite ?? false {
                n.resp = r
                n.respBase = baseline(.respRate, nightIsImported: ImportedHistory.isImported(r))
            }
            if let d = s.metric(.skinTempDev, variant: SkinTemperature.decodedVariant, window: "night"), let v = d.value, v.isFinite {
                n.temp = v
                n.tempMetric = d
            }
            return n
        }

        /// Imported rows of the headline's own source for a metric (efficiency, WASO, awakenings, latency): never another source's.
        func ownSourceRow(_ key: MetricKey) -> Metric? {
            guard !isOwn, fill.fill == .imported, let label else { return nil }
            return s.metrics.first {
                $0.name == key.rawValue && ImportedHistory.isImported($0) && ($0.value?.isFinite ?? false)
                    && ($0.window == nil || $0.window == "night") && PresenterSnapshot.alsoLabel($0.source) == label
            }
        }

        /// Where the headline's figure sits in the pill: "Strap · primary · 96% HR coverage" or "WHOOP via Apple Health · fallback".
        func pill() -> (text: String, fallback: Bool) {
            switch fill.fill {
            case .notProcessed:
                return (status.phase == .downloading ? "coming down" : "not processed", false)
            case .imported where fill.appleOnPhone:
                let who = fill.metric.map { ImportedHistory.shortSource($0.source) } ?? "Apple Health"
                return ("Apple Health (on phone) · \(who) · fallback", true)
            case .imported:
                let m = fill.metric
                var src = "Apple Health"
                if let m {
                    if ImportedHistory.isAppleHealth(m) {
                        src = PresenterSnapshot.alsoLabel(m.source) == "WHOOP" ? "WHOOP via Apple Health"
                            : ImportedHistory.shortSource(m.source)
                    } else {
                        src = ImportedHistory.sourceLabel(m) ?? "Imported history"
                    }
                }
                return ("\(src) · fallback", true)
            case .strapFlag, .phone, .pc:
                return (["Strap · primary", pct(hrCoverage).map { "\($0) HR coverage" }].compactMap { $0 }.joined(separator: " · "), false)
            }
        }

        func review() -> String? {
            guard let mine = fill.minutes, !fill.also.isEmpty else { return nil }
            let widest = fill.also.map { abs($0.minutes - mine) }.max() ?? 0
            return widest > SleepBreakdownPresenter.reviewMinutes ? "\(fill.also.count + 1) sources · review" : nil
        }

        func needMinutes() -> (minutes: Double, caption: String)? {
            if let nm = s.metric(.sleepNeed), let v = nm.value, v.isFinite,
               (fill.metric.map(ImportedHistory.rank) ?? 0) == ImportedHistory.rank(nm) {
                return (v, ImportedHistory.isImported(nm) ? "need from \(writer(nm))" : "your need (ALG-115)")
            }
            if let o = s.settings.needOverrideMinutes { return (Double(o), "your set need (Preferences)") }
            return nil
        }

        /// The sleep score, if any exists for this night's source: (percent, metric).
        func performance() -> (percent: Double, metric: Metric)? {
            guard fill.fill != .notProcessed, let m = s.metric(.sleepPerformance), var v = m.value, v.isFinite else { return nil }
            if ImportedHistory.isImported(m) != (fill.fill == .imported) { return nil }       // never another source's score
            if m.unit == "fraction" { v *= 100 }
            return (v, m)
        }

        // MARK: Facts, physiology, story

        /// What the card and the facts say about continuity: only for a source that measures short wakes.
        func continuityRows() -> (eff: Metric?, waso: Metric?, awk: Metric?, latency: Metric?) {
            (ownSourceRow(.sleepEfficiency), ownSourceRow(.waso), ownSourceRow(.awakenings), ownSourceRow(.sleepLatency))
        }

        /// The headline's stages are our own stager's (phone or PC): deep and REM are estimates.
        var ownStaged: Bool {
            switch fill.stages {
            case .phone, .pc: return true
            default: return false
            }
        }

        func lowestHR() -> (value: Double, at: Date)? {
            hr.compactMap { m in m.value.map { ($0, m.at) } }.min { $0.0 < $1.0 }.map { (value: $0.0, at: $0.1) }
        }

        func stageMinutes(_ key: MetricKey) -> Double? {
            guard fill.fill != .notProcessed else { return nil }
            let m = s.metric(key.rawValue)
            guard let v = m?.value, v.isFinite else { return nil }
            return v
        }

        func facts() -> [SleepCell] {
            var out: [SleepCell] = []
            let c = continuityRows()
            if let e = c.eff?.value {
                out.append(SleepCell(id: "eff", label: "Efficiency", text: MGFormat.number(e <= 1 ? e * 100 : e, decimals: 0) + "%",
                                     caption: writer(c.eff!)))
            }
            if let w = c.waso?.value {
                var t = "\(MetricText.minutes(w))"
                if let k = c.awk?.value { t += " · \(Int(k.rounded())) awakenings" }
                out.append(SleepCell(id: "waso", label: "Awake after onset", text: t, caption: writer(c.waso!)))
            }
            if let l = c.latency?.value, l.isFinite {
                out.append(SleepCell(id: "latency", label: "Fell asleep in", text: MetricText.minutes(l), caption: writer(c.latency!)))
            }
            if ownStaged, let d = stageMinutes(.sleepDeep) {
                out.append(SleepCell(id: "deep", label: "Deep", text: MetricText.minutes(d), caption: "estimate", isEstimate: true))
            }
            if ownStaged, let r = stageMinutes(.sleepRem) {
                out.append(SleepCell(id: "rem", label: "REM", text: MetricText.minutes(r), caption: "estimate", isEstimate: true))
            }
            if let low = lowestHR() {
                out.append(SleepCell(id: "lowhr", label: "Lowest HR", text: "\(SleepBreakdownPresenter.bpm(low.value)) at \(s.hm(low.at))",
                                     caption: "5-minute averages"))
            }
            return Array(out.prefix(3))
        }

        func physiologyStrip(_ n: Night) -> [SleepCell] {
            var out: [SleepCell] = []
            if let m = n.hrv, let v = m.value {
                let kind = HRVLabel.kind(m).rawValue
                var cap = [HRVLabel.kind(m) == .rmssd ? nil : "not comparable with RMSSD"].compactMap { $0 }
                if let b = n.hrvBase, b.median > 0 {
                    let d = (v - b.median) / b.median * 100
                    cap.append("\(d >= 0 ? "↑" : "↓")\(MGFormat.number(abs(d), decimals: 0))% vs your median")
                    if b.mixed { cap.append("baseline includes another device") }
                } else if HRVLabel.kind(m) == .rmssd {
                    cap.append("no baseline yet")
                }
                cap.append(writer(m))
                out.append(SleepCell(id: "hrv", label: "HRV · \(kind)", text: SleepBreakdownPresenter.ms(v), caption: cap.joined(separator: " · ")))
            } else {
                out.append(.grey("hrv", "HRV", "No sleep HRV for this night yet."))
            }
            if let m = n.rhr, let v = m.value {
                var cap: [String] = []
                if let b = n.rhrBase {
                    let d = v - b.median
                    cap.append("\(MetricText.signed(d, decimals: 0)) vs your median")
                    if b.mixed { cap.append("baseline includes another device") }
                } else {
                    cap.append("no baseline yet")
                }
                cap.append(writer(m))
                out.append(SleepCell(id: "rhr", label: "Resting HR", text: SleepBreakdownPresenter.bpm(v), caption: cap.joined(separator: " · ")))
            } else {
                out.append(.grey("rhr", "Resting HR", "No resting heart rate for this night yet."))
            }
            if let t = n.temp {
                out.append(SleepCell(id: "temp", label: "Skin temp", text: MetricText.signed(t, decimals: 1) + " °C",
                                     caption: "vs your baseline · decoded, untested"))
            } else {
                out.append(.grey("temp", "Skin temp", "Learning your baseline: the deviation needs your own earlier nights."))
            }
            return out
        }

        /// One sentence: duration against need, continuity when measured, then the physiology that moved.
        func story(_ n: Night) -> String {
            guard let mins = fill.minutes else { return fill.reason ?? "No night to describe yet." }
            var head = "Slept \(MetricText.minutes(mins))"
            if let need = needMinutes() {
                let gap = need.minutes - mins
                head += gap > 0 ? ", \(MetricText.minutes(gap)) short of your \(MetricText.minutes(need.minutes)) need"
                    : ", meeting your \(MetricText.minutes(need.minutes)) need"
            }
            var parts: [String] = []
            if let w = continuityRows().waso?.value, w >= 1 { parts.append("\(MetricText.minutes(w)) awake after falling asleep") }
            if let v = n.hrv?.value, let b = n.hrvBase, b.median > 0, !b.mixed {
                let d = (v - b.median) / b.median * 100
                if abs(d) >= SleepBreakdownPresenter.hrvStoryPercent {
                    parts.append("HRV \(MGFormat.number(abs(d), decimals: 0))% \(d > 0 ? "above" : "below") your usual")
                }
            }
            if let v = n.rhr?.value, let b = n.rhrBase, !b.mixed, abs(v - b.median) >= SleepBreakdownPresenter.rhrStoryBpm {
                parts.append("resting HR \(MGFormat.number(abs(v - b.median), decimals: 0)) bpm \(v > b.median ? "above" : "below") your usual")
            }
            return head + (parts.isEmpty ? "." : "; " + parts.joined(separator: ", ") + ".")
        }

        // MARK: The card

        func card() -> SleepCardState {
            let p = pill()
            let n = night()
            let pending = fill.fill == .notProcessed
            let score = performance().map { "Sleep performance \(MGFormat.number($0.percent, decimals: 0))%" }
            let need = needMinutes()
            var hypnoNote: String?
            if runs.isEmpty {
                hypnoNote = pending ? nil : (fill.fill == .imported ? "\(label ?? "This source") gave no stage timeline for this night."
                                                                    : "No stage timeline is stored for this night.")
            }
            var out = SleepCardState(
                pill: p.text, isFallback: p.fallback, reviewBadge: review(),
                durationText: SleepBreakdownPresenter.dur(fill.minutes), blankReason: pending ? fill.reason : nil,
                windowText: window.map { s.range($0.start, $0.end) },
                needText: need.map { "of \(MetricText.minutes($0.minutes)) need" },
                scoreText: score, hypnogram: runs, hypnogramNote: hypnoNote,
                facts: pending ? [] : facts(), story: pending ? (fill.reason ?? "") : story(n),
                physiology: pending ? [] : physiologyStrip(n),
                alsoLine: PresenterSnapshot.alsoLine(fill.also))
            out.phase = status.phase
            out.progress = status.progress
            out.haveLine = status.have
            out.fallbackNote = status.fallbackNote
            if pending, let why = status.headline { out.blankReason = why; out.story = why }
            if status.phase == .notProcessed { out.processIntent = .processSleepNow }
            return out
        }
    }
}
