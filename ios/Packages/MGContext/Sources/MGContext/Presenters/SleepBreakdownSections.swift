import Foundation
import MGDomain

// Sleep expanded, spec §B 1-10 (see SleepBreakdownPresenter.swift for the rules). Builds `SleepBreakdownState` from the same `Build`
// the card uses, so the pill, headline, story and "also:" line on the card and in the detail cannot differ.

extension SleepBreakdownPresenter {
    /// §A + §B: the card and the full breakdown, built from one pass.
    public static func make(_ s: PresenterSnapshot) -> SleepBreakdownState { Build(s).breakdown() }
}

extension SleepBreakdownPresenter.Build {
    private var pending: Bool { fill.fill == .notProcessed }

    private var noNight: String { fill.reason ?? "No night to show yet." }

    func breakdown() -> SleepBreakdownState {
        let n = night()
        let card = self.card()
        let (equation, continuity) = continuitySection()
        return SleepBreakdownState(
            card: card, summary: summarySection(card), sourceRows: sourceSection(), interpretation: card.story,
            equation: equation, continuity: continuity, explorer: explorer(n), stages: stageSection(),
            physiology: physiologySections(n), score: scoreSection(), need: needSection(), naps: napRows(), napsNote: napsNote(),
            trends: trendRows(n), versionLine: versionLine())
    }

    // MARK: 1. Summary and source rows

    private func summarySection(_ card: SleepCardState) -> SleepGroup {
        guard !pending else { return SleepGroup(id: "summary", title: "Summary", cells: [.grey("night", "Night", noNight)]) }
        var cells: [SleepCell] = []
        let dayDate = window?.end ?? s.day.start(in: s.calendar.timeZone).addingTimeInterval(12 * 3600)
        cells.append(SleepCell(id: "night", label: "Night ending", text: MGFormat.kickerDate(dayDate, calendar: s.calendar)))
        cells.append(SleepCell(id: "asleep", label: "Asleep", text: card.durationText, caption: card.pill,
                               reason: card.durationText == nil ? noNight : nil))
        if let w = card.windowText {
            cells.append(SleepCell(id: "window", label: "Window", text: w, caption: "first to last asleep minute"))
        } else {
            cells.append(.grey("window", "Window", "This source gave no start and end for the night."))
        }
        if let mins = fill.minutes, let b = s.explore.sleepTrends.first(where: { $0.key == MetricKey.sleepTotal.rawValue }) {
            let prior = b.points.filter { $0.day < s.day }.suffix(30).compactMap { $0.value }.filter { $0.isFinite }
            if prior.count >= SleepBreakdownPresenter.baselineNights, let m = SleepBreakdownPresenter.median(prior) {
                let d = mins - m
                cells.append(SleepCell(id: "vs30", label: "Against your usual",
                                       text: (d >= 0 ? "+" : "−") + MetricText.minutes(abs(d)),
                                       caption: "median of \(prior.count) earlier nights is \(MetricText.minutes(m))"))
            } else {
                cells.append(.grey("vs30", "Against your usual", "Needs \(SleepBreakdownPresenter.baselineNights) earlier nights; have \(prior.count)."))
            }
        } else {
            cells.append(.grey("vs30", "Against your usual", "Night history is not loaded yet."))
        }
        if let sc = card.scoreText {
            cells.append(SleepCell(id: "score", label: "Score", text: sc))
        } else {
            cells.append(.grey("score", "Score", "No sleep score exists for this night's source."))
        }
        return SleepGroup(id: "summary", title: "Summary", cells: cells)
    }

    private func sourceSection() -> SleepGroup {
        var cells: [SleepCell] = []
        if pending {
            cells.append(.grey("headline", "Headline", noNight))
        } else {
            let p = pill()
            cells.append(SleepCell(id: "headline", label: p.text.components(separatedBy: " · ").first ?? p.text,
                                   text: SleepBreakdownPresenter.dur(fill.minutes), caption: "headline · \(fill.sourceLine)"))
            for a in fill.also {
                let staged = !s.importedStageRows(label: a.label).isEmpty
                cells.append(SleepCell(id: "also.\(a.label)", label: a.label, text: MetricText.minutes(a.minutes),
                                       caption: staged ? "total and stages" : "total only"))
            }
        }
        let w = window
        func cov(_ id: String, _ label: String, _ name: String, _ why: String) {
            let series = (s.dialSeries + s.series).filter { $0.name == name }
            if let w, let c = Self.coverage(series, in: w) {
                cells.append(SleepCell(id: id, label: label, text: pct(c), caption: "share of the night with a value"))
            } else {
                cells.append(.grey(id, label, why))
            }
        }
        cov("cov_hr", "Heart rate coverage", DialSeries.hrName, "No 5-minute heart rate for this night.")
        cells.append(.grey("cov_rr", "R-R coverage", "No overnight R-R series is stored on the phone (only the night's summary)."))
        cov("cov_motion", "Motion coverage", "movement", "No motion series stored for this night.")
        cov("cov_temp", "Temperature coverage", "skin_temp_night_raw", "No skin-temperature series stored for this night.")
        return SleepGroup(id: "sources", title: "Sources", cells: cells,
                          note: "Sources are never averaged or merged. The headline is our own raw-data night when there is one, "
                              + "else Apple Health's complete night; every figure below names who measured it.")
    }

    // MARK: 3. Continuity

    private func continuitySection() -> (String?, SleepGroup) {
        guard !pending else { return (nil, SleepGroup(id: "continuity", title: "Sleep opportunity and continuity",
                                                      cells: [.grey("continuity", "Continuity", noNight)])) }
        let c = continuityRows()
        var cells: [SleepCell] = []
        var equation: String?
        if isOwn {
            if let w = window {
                cells.append(SleepCell(id: "first", label: "First asleep", text: s.hm(w.start), caption: "from the sleep flag / stager"))
                cells.append(SleepCell(id: "last", label: "Last asleep", text: s.hm(w.end), caption: "from the sleep flag / stager"))
            }
            let why = "Not shown: the strap's sleep flag reports no short wakes, so this would read better than the night was."
            cells.append(.grey("eff", "Efficiency", why))
            cells.append(.grey("waso", "Awake after onset", why))
            cells.append(.grey("awk", "Awakenings", why))
            return (nil, SleepGroup(id: "continuity", title: "Sleep opportunity and continuity", cells: cells,
                                    note: "These appear for a source that measures short wakes (Apple Watch); they are never estimated from the strap flag."))
        }
        let src = label ?? "this source"
        func add(_ id: String, _ label: String, _ m: Metric?, _ text: (Double) -> String, _ why: String) {
            if let m, let v = m.value { cells.append(SleepCell(id: id, label: label, text: text(v), caption: "measured by \(src)")) }
            else { cells.append(.grey(id, label, why)) }
        }
        add("eff", "Efficiency", c.eff, { MGFormat.number($0 <= 1 ? $0 * 100 : $0, decimals: 0) + "%" }, "\(src) wrote no efficiency for this night.")
        add("waso", "Awake after onset", c.waso, { MetricText.minutes($0) }, "\(src) wrote no awake-after-onset for this night.")
        add("awk", "Awakenings", c.awk, { "\(Int($0.rounded()))" }, "\(src) wrote no awakening count for this night.")
        add("latency", "Fell asleep in", c.latency, { MetricText.minutes($0) }, "\(src) wrote no onset latency for this night.")
        if let w = c.waso?.value, let l = c.latency?.value, let t = fill.minutes {
            equation = "In bed \(MetricText.minutes(t + w + l)) − latency \(MetricText.minutes(l)) − awake \(MetricText.minutes(w)) = asleep \(MetricText.minutes(t))"
        }
        let note = equation == nil
            ? "The equation needs both onset latency and awake-after-onset from the same source."
            : "Awake after onset = awake after first falling asleep. Time in bed is derived (asleep + awake + latency); the rest is measured."
        return (equation, SleepGroup(id: "continuity", title: "Sleep opportunity and continuity", cells: cells, note: note))
    }

    // MARK: 4. Night explorer

    private func explorer(_ n: Night) -> SleepExplorerState {
        let hyps = DialPresenter.hypnograms(s)
        let importedRuns = hyps.first(where: { ImportedHistory.isImportVariant($0.variant) }).map { DialPresenter.runs($0.series) } ?? []
        var drawn = runs
        var source: String
        switch fill.stages {
        case .strap: source = "strap flag · asleep / awake only"
        case .phone: source = "phone stager · deep and REM are estimates"
        case .pc(let v): source = "PC \(PresenterSnapshot.pcLabel(v)) · deep and REM are estimates"
        case .imported(let l):
            source = "\(l)'s own staging"
            drawn = importedRuns
        case .none: source = "no stages for this night"
        }
        if pending { source = "" }
        var note: String?
        if drawn.isEmpty { note = pending ? noNight : (fill.reason ?? "No stage timeline is stored for this night.") }
        var overlay: [StageSegment]?
        var overlayWhy: String?
        if case .imported = fill.stages {
            overlayWhy = "The headline already is that source's staging."
        } else if importedRuns.isEmpty {
            overlayWhy = "No Apple Watch stage timeline is stored for this night (only its stage minutes, if any)."
        } else {
            overlay = importedRuns
        }

        var tracks: [SleepTrack] = []
        tracks.append(SleepTrack(id: "hr", title: "Heart rate", unit: "bpm", caption: "5-minute averages", points: hr,
                                 reason: hr.isEmpty ? "No 5-minute heart rate is stored for this night." : nil))
        tracks.append(SleepTrack(id: "rr", title: "R-R / HRV", unit: "ms", caption: nil, points: [],
                                 reason: "No overnight R-R or HRV series is stored on the phone; the night's HRV is in the cards below."))
        let motion = window.map { w in
            Self.binned((s.dialSeries + s.series).filter { $0.name == "movement" }, in: w, reduce: { $0.max() ?? .nan })
        } ?? []
        tracks.append(SleepTrack(id: "motion", title: "Motion", unit: "", caption: "strap accelerometer · relative, no unit", points: motion,
                                 reason: motion.isEmpty ? "No motion series is stored for this night." : nil))
        tracks.append(tempTrack(n))

        var times: [Date] = drawn.flatMap { [$0.start, $0.end] }
        if let w = window { times += [w.start, w.end] }
        for t in tracks { times += t.points.map(\.at) }
        return SleepExplorerState(window: NightClockWindow(times: times), hypnogram: drawn, hypnogramNote: note,
                                  hypnogramSource: source, watchOverlay: overlay, watchOverlayReason: overlayWhy, tracks: tracks)
    }

    /// Skin-temperature deviation curve: the raw series is never drawn as a unit; it is shifted by the night's baseline (tonight's
    /// median minus the labelled deviation) so the track reads as °C from your baseline, decoded, untested (CLAUDE.md rule 4).
    private func tempTrack(_ n: Night) -> SleepTrack {
        let cap = "from your baseline · decoded, untested"
        let series = s.series.filter { $0.name == "skin_temp_night_raw" }
        guard let w = window, let dev = n.temp, !series.isEmpty else {
            return SleepTrack(id: "temp", title: "Skin temp vs baseline", unit: "°C", caption: cap, points: [],
                              reason: "No deviation curve: it needs your own baseline and this night's temperature series. Raw counts are not shown.")
        }
        let all = Self.binned(series, in: w, map: { $0 / 100 }, reduce: { NightPresenter.median($0) })
        guard let m = SleepBreakdownPresenter.median(all.compactMap(\.value)) else {
            return SleepTrack(id: "temp", title: "Skin temp vs baseline", unit: "°C", caption: cap, points: [],
                              reason: "No temperature values inside the night window.")
        }
        let base = m - dev
        return SleepTrack(id: "temp", title: "Skin temp vs baseline", unit: "°C", caption: cap,
                          points: all.compactMap { p in p.value.map { LaneMark(at: p.at, value: $0 - base) } }, reason: nil)
    }

    // MARK: Stage rows

    private func stageSection() -> SleepGroup {
        let title = "Stages"
        guard !pending else { return SleepGroup(id: "stages", title: title, cells: [.grey("stages", title, noNight)]) }
        switch fill.stages {
        case .strap:
            return SleepGroup(id: "stages", title: title, cells: [.grey("stages", title,
                "Only asleep / awake from the strap's sleep flag this night; stage minutes come from a stager.")])
        case .none:
            return SleepGroup(id: "stages", title: title, cells: [.grey("stages", title, fill.reason ?? "No stage minutes for this night.")])
        case .phone, .pc, .imported:
            break
        }
        var cells: [SleepCell] = []
        let total = fill.minutes ?? 0
        let ours = ownStaged
        let parts: [(String, String, MetricKey)] = [("light", "Light", .sleepLight), ("deep", "Deep", .sleepDeep), ("rem", "REM", .sleepRem)]
        for (id, name, key) in parts {
            let m = s.metric(key.rawValue)
            if let v = m?.value, v.isFinite {
                let share = total > 0 ? " · \(MGFormat.number(v / total * 100, decimals: 0))% of asleep" : ""
                // Our stagers: every stage is an estimate (deep and REM the weakest). An imported source's own staging is its own.
                cells.append(SleepCell(id: id, label: name, text: MetricText.minutes(v) + share,
                                       caption: ours ? "estimate" : "\(label ?? "source")'s own staging", isEstimate: ours))
            } else {
                cells.append(.grey(id, name, m?.note ?? "No \(name.lowercased()) minutes for this night."))
            }
        }
        return SleepGroup(id: "stages", title: title, cells: cells,
                          note: ours ? "Deep and REM are estimates (the phone stager agrees with sleep-lab staging about half the time beyond chance); "
                              + "they are not scored against a population target."
                              : "These are the headline source's own stage minutes, not ours.")
    }

    // MARK: 5. Overnight physiology

    private func physiologySections(_ n: Night) -> [SleepGroup] {
        guard !pending else { return [SleepGroup(id: "physiology", title: "Overnight physiology", cells: [.grey("physiology", "Physiology", noNight)])] }
        return [hrGroup(n), hrvGroup(n), respGroup(n), tempGroup(n), spo2Group()]
    }

    private func hrGroup(_ n: Night) -> SleepGroup {
        var cells: [SleepCell] = []
        let vals = hr.compactMap(\.value)
        if let low = lowestHR(), let med = SleepBreakdownPresenter.median(vals) {
            cells.append(SleepCell(id: "min", label: "Lowest", text: "\(SleepBreakdownPresenter.bpm(low.value)) at \(s.hm(low.at))", caption: "5-minute average"))
            cells.append(SleepCell(id: "median", label: "Median", text: SleepBreakdownPresenter.bpm(med)))
            let half = vals.count / 2
            if half >= 3, let a = SleepBreakdownPresenter.median(Array(vals[..<half])), let b = SleepBreakdownPresenter.median(Array(vals[half...])) {
                cells.append(SleepCell(id: "slope", label: "Second half vs first", text: MetricText.signed(b - a, decimals: 0) + " bpm"))
            }
        } else {
            cells.append(.grey("min", "Lowest", "No 5-minute heart rate is stored for this night."))
        }
        if let m = n.rhr, let v = m.value {
            var cap = [writer(m)]
            if let b = n.rhrBase { cap.append("\(MetricText.signed(v - b.median, decimals: 0)) bpm vs your median of \(b.nights) nights") }
            cells.append(SleepCell(id: "rhr", label: "Resting HR", text: SleepBreakdownPresenter.bpm(v), caption: cap.joined(separator: " · ")))
        } else {
            cells.append(.grey("rhr", "Resting HR", "No resting heart rate for this night yet."))
        }
        return SleepGroup(id: "hr", title: "Heart rate", cells: cells,
                          note: hrCoverage.map { "Coverage \(pct($0) ?? "")" } ?? "No coverage: no heart-rate series.")
    }

    private func hrvGroup(_ n: Night) -> SleepGroup {
        var cells: [SleepCell] = []
        if let r = s.nightRmssd(), let v = r.value {
            var cap = [HRVLabel.text(r)]
            if let b = n.hrvBase, b.median > 0 {
                let d = (v - b.median) / b.median * 100
                cap.append("\(MetricText.signed(d, decimals: 0))% vs your median of \(b.nights) nights")
                if b.mixed { cap.append("baseline includes another device: compare with care") }
            } else {
                cap.append("no baseline yet")
            }
            cells.append(SleepCell(id: "rmssd", label: "Sleep HRV (RMSSD)", text: SleepBreakdownPresenter.ms(v), caption: cap.joined(separator: " · ")))
            if let count = Self.sampleCount(r) {
                cells.append(SleepCell(id: "samples", label: "Samples", text: "\(count)"))
            } else {
                cells.append(.grey("samples", "Samples", "The sample count is not stored with this value."))
            }
            if let c = r.coverage, c.isFinite { cells.append(SleepCell(id: "cov", label: "Coverage", text: pct(c))) }
        } else {
            cells.append(.grey("rmssd", "Sleep HRV (RMSSD)", "No sleep HRV (RMSSD) for this night yet."))
        }
        if let sd = s.nightSdnn(), let v = sd.value {
            cells.append(SleepCell(id: "sdnn", label: "HRV (SDNN)", text: SleepBreakdownPresenter.ms(v), caption: HRVLabel.text(sd)))
        }
        return SleepGroup(id: "hrv", title: "HRV", cells: cells,
                          note: "RMSSD and SDNN are different measures and are never compared. R-R intervals from different devices are never pooled.")
    }

    /// "n=123" or "123 beats / windows / epochs" in a metric note; nil when the note says none.
    static func sampleCount(_ m: Metric) -> Int? {
        guard let note = m.note else { return nil }
        for pattern in [#"\bn\s*=\s*(\d+)"#, #"(\d+)\s+(?:beats|windows|epochs|samples|intervals)"#] {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let hit = re.firstMatch(in: note, range: NSRange(note.startIndex..., in: note)),
                  let r = Range(hit.range(at: 1), in: note) else { continue }
            return Int(note[r])
        }
        return nil
    }

    private func respGroup(_ n: Night) -> SleepGroup {
        guard let m = n.resp, let v = m.value else {
            return SleepGroup(id: "resp", title: "Breathing rate", cells: [.grey("resp", "Breathing rate", "No breathing rate was derived or imported for this night.")])
        }
        let imported = ImportedHistory.isImported(m)
        var cap = [imported ? "from \(writer(m))" : "estimate · derived from the strap"]
        if let b = n.respBase { cap.append("\(MetricText.signed(v - b.median, decimals: 1)) vs your median of \(b.nights) nights") }
        return SleepGroup(id: "resp", title: "Breathing rate", cells: [
            SleepCell(id: "resp", label: "Night median", text: MGFormat.number(v, decimals: 1) + " breaths/min", caption: cap.joined(separator: " · "),
                      isEstimate: !imported)])
    }

    private func tempGroup(_ n: Night) -> SleepGroup {
        if let t = n.temp {
            let basis = PersonalBasis.nights(inNote: n.tempMetric?.note).map { " · \(PersonalBasis.nightsWords($0))" } ?? ""
            return SleepGroup(id: "temp", title: "Skin temperature", cells: [
                SleepCell(id: "temp", label: "From your baseline", text: MetricText.signed(t, decimals: 1) + " °C",
                          caption: "decoded, untested · tonight's median minus your previous 28-night median" + basis)],
                              note: "Skin temperature is not core body temperature; sensor contact changes it.")
        }
        if let c = s.metric(.skinTempC, window: "night"), ImportedHistory.isImported(c), let v = c.value, v.isFinite {
            return SleepGroup(id: "temp", title: "Skin temperature", cells: [
                SleepCell(id: "temp", label: "Wrist temperature", text: MGFormat.number(v, decimals: 1) + " °C", caption: "from \(writer(c)), not the strap")])
        }
        return SleepGroup(id: "temp", title: "Skin temperature", cells: [
            .grey("temp", "From your baseline", "Learning your baseline: the deviation needs your own earlier nights. Raw counts are not shown.")])
    }

    private func spo2Group() -> SleepGroup {
        // Only from a named source: the strap's byte after the check against WHOOP passed, our red / IR estimate once the LED identity is
        // confirmed, or an imported value (Apple Health / WHOOP). The strap's raw byte is never shown as a %.
        if s.spo2Gate.passed, let m = SpO2Gate.shown(s, MetricKey.spo2StrapMean.rawValue),
           let d = SpO2Gate.percent(m, status: s.spo2Gate, sample: s.sample), let t = SleepBreakdownPresenter.plain(d) {
            return SleepGroup(id: "spo2", title: "Blood oxygen", cells: [
                SleepCell(id: "spo2", label: "Night mean", text: t, caption: "strap byte · checked against WHOOP")])
        }
        if LEDIdentity.confirmed, let e = s.metrics.first(where: { $0.name == MetricKey.spo2Pct.rawValue && $0.variant == "ALG-022:night"
            && $0.window == "night" && ($0.value?.isFinite ?? false) }), let v = e.value {
            return SleepGroup(id: "spo2", title: "Blood oxygen", cells: [
                SleepCell(id: "spo2", label: "Red / IR", text: MGFormat.number(v, decimals: 0) + " %", caption: "estimate — not checked against WHOOP · raw optical (ours)",
                          isEstimate: true)])
        }
        if let m = s.metric(.spo2Pct, window: "night"), ImportedHistory.isImported(m), let v = m.value, v.isFinite {
            return SleepGroup(id: "spo2", title: "Blood oxygen", cells: [
                SleepCell(id: "spo2", label: "Night mean", text: MGFormat.number(v, decimals: 0) + " %", caption: "from \(writer(m)), not the strap")])
        }
        return SleepGroup(id: "spo2", title: "Blood oxygen", cells: [
            .grey("spo2", "Night mean", "No SpO₂ from a named source for this night. The strap's own byte is not shown as a % until it matches WHOOP.")])
    }

    // MARK: 6. Score

    private func scoreSection() -> SleepGroup? {
        guard let p = performance() else { return nil }
        let value = MGFormat.number(p.percent, decimals: 0) + "%"
        var cells: [SleepCell] = []
        var note: String
        if ImportedHistory.isImported(p.metric) {
            let src = label ?? writer(p.metric)
            cells.append(SleepCell(id: "perf", label: "Sleep performance", text: value, caption: "\(src)'s own score"))
            let comps: [(String, String, MetricKey)] = [("eff", "Efficiency", .sleepEfficiency), ("cons", "Consistency", .sleepConsistency)]
            for (id, name, key) in comps {
                if let r = ownSourceRow(key), let v = r.value {
                    cells.append(SleepCell(id: id, label: name, text: MGFormat.number(v <= 1 ? v * 100 : v, decimals: 0) + "%", caption: "\(src)'s own value"))
                }
            }
            note = "\(src) does not publish how it weights these, so no points are shown."
        } else if let need = needMinutes(), let t = fill.minutes {
            cells.append(SleepCell(id: "perf", label: "Hours against need",
                                   text: "\(MetricText.minutes(t)) ÷ \(MetricText.minutes(need.minutes)) = \(value)",
                                   caption: "ALG-150: asleep ÷ need, capped at 100%"))
            note = "This score is only hours against need: continuity, timing and physiology are not mixed into it."
        } else {
            cells.append(SleepCell(id: "perf", label: "Sleep performance", text: value, caption: "ALG-150: asleep ÷ need"))
            note = "This score is only hours against need."
        }
        return SleepGroup(id: "score", title: "Score breakdown", cells: cells, note: note)
    }

    // MARK: 7. Need, debt, consistency

    private func needSection() -> SleepGroup {
        var cells: [SleepCell] = []
        if let need = needMinutes() {
            cells.append(SleepCell(id: "need", label: "Tonight's need", text: MetricText.minutes(need.minutes), caption: need.caption))
        } else {
            cells.append(.grey("need", "Tonight's need", TonightPresenter.needWait))
        }
        if let d = s.metric(.sleepDebt), let v = d.value, v.isFinite {
            cells.append(SleepCell(id: "debt", label: "Sleep debt", text: MetricText.minutes(v), caption: "ALG-115 · shown beside the need, not added to it"))
        } else {
            cells.append(.grey("debt", "Sleep debt", "No sleep debt yet (it needs your free nights)."))
        }
        let sri = s.display(.sri, missing: NightPresenter.regularityWait)
        if let t = SleepBreakdownPresenter.plain(sri) {
            cells.append(SleepCell(id: "consistency", label: "Regularity", text: t, caption: "ALG-030"))
        } else {
            cells.append(.grey("consistency", "Regularity", NightPresenter.regularityWait))
        }
        let plan = TonightPresenter.make(s)
        cells.append(SleepCell(id: "plan", label: "Tonight's plan", text: plan.summaryLine, caption: "from Tonight"))
        return SleepGroup(id: "need", title: "Need, debt and consistency", cells: cells,
                          note: "Your need is the mean of your free nights, less today's naps (ALG-115). Debt is shown on its own.")
    }

    // MARK: 8. Naps

    private func napRows() -> [SleepNapRow] {
        s.eventsSinceWake(.nap).compactMap { e in
            guard case let .nap(f) = e.payload, f.confirmed != false else { return nil }
            return SleepNapRow(id: e.id.uuidString, range: s.range(e.at, f.end), duration: MGFormat.duration(f.end.timeIntervalSince(e.at)),
                               caption: (f.detector ?? "ALG-033") + (f.confirmed == nil ? " · unconfirmed" : " · confirmed"),
                               effect: "Reduces tonight's need (ALG-115 takes today's naps off it); does not change last night's score.")
        }
    }

    private func napsNote() -> String? { napRows().isEmpty ? "No naps today." : nil }

    // MARK: 9. Trends

    private func trendRows(_ n: Night) -> [SleepTrendRow] {
        let loaded = !s.explore.sleepTrends.isEmpty
        func row(_ key: MetricKey, _ label: String, _ text: (Double) -> String, show: Bool = true, why: String = "") -> SleepTrendRow {
            guard loaded, let a = s.explore.sleepTrends.first(where: { $0.key == key.rawValue }) else {
                return SleepTrendRow(id: key.rawValue, label: label, d7: nil, d30: nil, d90: nil, note: "Night history is not loaded yet.")
            }
            guard show else { return SleepTrendRow(id: key.rawValue, label: label, d7: nil, d30: nil, d90: nil, note: why) }
            func med(_ count: Int, _ minimum: Int) -> String? {
                let v = a.points.suffix(count).compactMap { $0.value }.filter { $0.isFinite }
                guard v.count >= minimum, let m = SleepBreakdownPresenter.median(v) else { return nil }
                return text(m)
            }
            let have30 = a.points.suffix(30).compactMap { $0.value }.filter { $0.isFinite }.count
            let r = SleepTrendRow(id: key.rawValue, label: label, d7: med(7, 3), d30: med(30, 7), d90: med(90, 14),
                                  note: have30 == 0 ? "No \(label.lowercased()) stored for these nights." : "\(have30) of 30 nights have a value.")
            return r
        }
        let tempShown = s.explore.sleepTrends.first { $0.key == MetricKey.skinTempDev.rawValue }?.latest?.variant == SkinTemperature.decodedVariant
        return [
            row(.sleepTotal, "Time asleep", { MetricText.minutes($0) }),
            row(.rhr, "Resting HR", { SleepBreakdownPresenter.bpm($0) }),
            row(.hrvRmssd, "HRV (RMSSD)", { SleepBreakdownPresenter.ms($0) }),
            row(.respRate, "Breathing rate", { MGFormat.number($0, decimals: 1) + " /min" }),
            row(.skinTempDev, "Skin temp vs baseline (decoded, untested)", { MetricText.signed($0, decimals: 1) + " °C" }, show: tempShown,
                why: "Not shown: the stored deviation is not the decoded °C one."),
        ]
    }

    // MARK: 10. Version line

    private func versionLine() -> String {
        guard !pending else { return "No night yet, so nothing was computed." }
        let method = fill.metric?.method ?? fill.metric?.variant ?? "strap sleep flag (ALG-150)"
        var parts = ["Total: \(method)", fill.sourceLine]
        switch fill.stages {
        case .phone: parts.append("stages: phone stager (ALG-151), estimates")
        case .pc(let v): parts.append("stages: PC \(PresenterSnapshot.pcLabel(v)), estimates")
        case .imported(let l): parts.append("stages: \(l)")
        case .strap: parts.append("stages: none (strap flag only)")
        case .none: parts.append("stages: none")
        }
        parts.append("headline setting: \(s.primary[MetricKey.sleepTotal.rawValue] ?? "phone:ALG-150")")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
