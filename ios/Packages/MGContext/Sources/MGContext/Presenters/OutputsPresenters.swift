import Foundation
import MGDomain

// Wave 2 (2026-10-11): every computed output on a screen, each labelled with where it came from. Explore gets "Every
// measure" (all registry metrics, newest value + source / algorithm), "Computed on PC" (every PC model's newest result)
// and "Today's other outputs" (pipeline outputs that are not metrics); a metric's detail lists every source's value; a
// group lists all its measures (G-HRV: 13); the root shows a "Working on…" line. Pure: no clock, no I/O, no statistics.

enum Outputs {
    // MARK: Origin and labels

    /// "phone" · "strap" · "computed on PC" · "past data · WHOOP export" · "past data · ours on imported history (PC)".
    static func origin(_ m: Metric) -> String {
        if let src = ImportedHistory.sourceLabel(m) { return "past data · " + src }
        switch m.computedOn {
        case .pc: return "computed on PC"
        case .phone: return "phone"
        case .strap: return "strap"
        }
    }

    /// The algorithm a value came from: the group member's label and id ("Plews lnRMSSD · ALG-101"), else the variant,
    /// else the method.
    static func algorithm(_ m: Metric) -> String {
        let v = m.variant ?? ""
        if let gid = m.group {
            let base = ImportedHistory.baseVariant(v) ?? v
            if let info = GroupCatalogue.member(gid, base) {
                let past = ImportedHistory.baseVariant(v) != nil ? " on past data" : ""
                return info.label == base ? base + past : "\(info.label) · \(base)\(past)"
            }
        }
        if let label = ImportedHistory.memberLabel(v), ImportedHistory.isImported(m) { return label }
        if !v.isEmpty { return v }
        return m.method ?? m.source
    }

    /// A dated row's origin: a value fetched from the PC for an older period (tracker #7) says so first.
    static func origin(_ r: DatedMetric) -> String {
        r.fromPC ? "from the PC · " + (ImportedHistory.sourceLabel(r.metric) ?? "computed on PC") : origin(r.metric)
    }

    /// Own first (phone, strap, then PC), then imported history by `ImportedHistory.rank`; newest first within a kind.
    static func ordered(_ rows: [DatedMetric]) -> [DatedMetric] {
        func kind(_ m: Metric) -> Int {
            if ImportedHistory.isImported(m) { return 10 + ImportedHistory.rank(m) }
            switch m.computedOn {
            case .phone: return 0
            case .strap: return 1
            case .pc: return 2
            }
        }
        return rows.sorted { a, b in
            let ka = kind(a.metric), kb = kind(b.metric)
            if ka != kb { return ka < kb }
            let va = a.metric.value != nil, vb = b.metric.value != nil
            if va != vb { return va }
            if a.day != b.day { return a.day > b.day }
            return (a.metric.variant ?? "") < (b.metric.variant ?? "")
        }
    }

    /// A source row as shown (T1 / T2, 2026-10-12): the newest value of one source, with the other route that carried
    /// the same number ("also via Apple Health").
    struct Shown {
        var row: DatedMetric
        var also: String?
    }

    /// The origin line of a shown row.
    static func origin(_ x: Shown) -> String {
        origin(x.row) + (x.also.map { " (also via \($0))" } ?? "")
    }

    /// The rows Explore shows for `key`, from `explore.latest`:
    /// - T1: a value from the PC (fetched, imported or a PC model) older than the period's first day is not part of the
    ///   period; it is hidden unless the period reaches back that far.
    /// - T1: one row per source (variant, computed on, window): the newest value only. A stored row and a PC copy of
    ///   the same source are one row (the stored one on a tie); a value beats a blank.
    /// - T2: WHOOP's export and WHOOP through Apple Health with the same number on the same day are one row.
    /// Ordered as `ordered`.
    static func shown(_ s: PresenterSnapshot, key: String) -> [Shown] {
        let today = LocalDay(date: s.now, calendar: s.calendar)
        let start = PCHistoryPlan.periodStart(s.explore.period, today: today)
        // T9822: a custom range ending before today: a row after its last day is not part of the period (a static lab
        // draw keeps showing, below).
        let end = PCHistoryPlan.periodEnd(s.explore.period, today: today)
        let isCustom = s.explore.period.isCustom
        let all = (s.explore.latest[key] ?? []).filter { !isCustom || ($0.day >= start && $0.day <= end) || LabDraws.isStatic(key) }
        var best: [String: DatedMetric] = [:]
        var order: [String] = []
        // Bug 9 (M-169): a lab is a static value (drawn once, valid until the next draw): its newest draw shows with its
        // date whatever the period, never "No value in this period".
        let isStatic = LabDraws.isStatic(key)
        for r in all where isStatic || !((r.fromPC || r.metric.computedOn == .pc) && r.day < start) {
            let k = "\(r.metric.variant ?? "")|\(r.metric.computedOn.rawValue)|\(r.metric.window ?? "")"
            guard let held = best[k] else {
                best[k] = r
                order.append(k)
                continue
            }
            let rv = r.metric.value != nil, hv = held.metric.value != nil
            if rv != hv { if rv { best[k] = r }; continue }
            if r.day != held.day { if r.day > held.day { best[k] = r }; continue }
            if held.fromPC && !r.fromPC { best[k] = r }
        }
        var rows = order.compactMap { best[$0] }
        var also: [String: String] = [:]               // export row id -> the other route
        let whoopAppLabel = "WHOOP"                    // Apple Health's source-app label, not a strap name
        for e in rows where e.metric.variant == ImportedHistory.whoopExport && e.metric.value != nil {
            let twins = rows.filter { a in
                a.metric.variant == ImportedHistory.appleHealth && a.metric.name == e.metric.name && a.day == e.day
                    && a.metric.source.localizedCaseInsensitiveContains(whoopAppLabel) && sameNumber(a.metric.value, e.metric.value)
            }
            guard !twins.isEmpty else { continue }
            let id = "\(e.metric.variant ?? "")|\(e.metric.window ?? "")"
            also[id] = "Apple Health"
            rows.removeAll { a in twins.contains { $0.metric.variant == a.metric.variant && $0.metric.window == a.metric.window
                && $0.metric.computedOn == a.metric.computedOn && $0.day == a.day } }
        }
        return ordered(rows).map { r in
            Shown(row: r, also: also["\(r.metric.variant ?? "")|\(r.metric.window ?? "")"])
        }
    }

    static func sameNumber(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return false }
        return abs(a - b) <= 1e-6 + 0.005 * max(abs(a), abs(b))
    }

    /// What a metric with nothing stored waits for (Mo: "or waiting for first night").
    static func waiting(_ key: String) -> String {
        let reg = ModelCatalogue.registry.first { $0.name == key }
        if reg?.computedOnPC == true || key.hasPrefix("ms_") { return "No PC result yet" }
        let windows = Set(reg?.windows ?? [])
        if !windows.isDisjoint(with: ModelStatusPresenter.nightWindows) || ModelStatusPresenter.nightNamed.contains(key) {
            return "Waiting for first night"
        }
        return "No value yet"
    }

    // MARK: Every measure

    static func measureEntries(_ s: PresenterSnapshot, _ list: [ExploreCatalogue.Entry]) -> [CatalogueEntry] {
        list.map { e in
            let rows = shown(s, key: e.key)
            var entry = CatalogueEntry(key: e.key, name: e.name, groupId: e.group, isResearch: false,
                                       intent: .openMetric(key: e.key, variant: nil))
            if let n = WhoopTerms.Number.forEntry(e.key), let w = whoopTermsEntry(s, n, entry) { return w }
            guard let pick = rows.first(where: { $0.row.metric.value != nil }) ?? rows.first else {
                // T1: older PC values exist but the period does not reach them: say so, not "waiting".
                entry.detail = (s.explore.latest[e.key] ?? []).isEmpty ? waiting(e.key) : "No value in this period"
                return entry
            }
            let best = pick.row
            entry.value = s.display(best.metric)
            entry.isResearch = best.metric.tier == .research
            var line = "\(algorithm(best.metric)) · \(origin(pick)) · \(dayText(best.day, s))"
            let others = rows.count - 1
            if others > 0 { line += " · +\(others) more source\(others == 1 ? "" : "s")" }
            // Bugs 6 / 27 (M-144, M-146): drivers and key points carry their words in the note; the row shows them.
            if MetricText.noteIsContent.contains(e.key), best.metric.value != nil,
               let note = best.metric.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                line = note + "\n" + line
            }
            entry.detail = line
            return entry
        }
    }

    /// T9813: the four WHOOP-terms numbers read by one rule (`WhoopTerms`): today ours, a past day WHOOP's where imported,
    /// both where both exist. nil = no row at all (the caller's usual "waiting" line applies).
    static func whoopTermsEntry(_ s: PresenterSnapshot, _ n: WhoopTerms.Number, _ base: CatalogueEntry) -> CatalogueEntry? {
        // Round 5 review 3: through `shown` (period filter + one row per source), not the raw `latest` rows.
        let all = (shown(s, key: n.oursKey) + (n.whoopKey.map { shown(s, key: $0) } ?? [])).map(\.row)
        // Review 2 / round 8: the day policy uses the app's calendar (the phone's zone), not a fixed zone. Night numbers are keyed by their wake date (D13: the local date of the final wake,
        // `ALG030.wakeDay`), so a night that crosses midnight belongs to the day it ended on.
        let today = LocalDay(date: s.now, calendar: s.calendar)
        guard let day = WhoopTerms.latestDay(n, rows: all) else { return nil }
        let p = WhoopTerms.pick(n, rows: all, day: day, today: today)
        var entry = base
        guard let h = p.headline else { entry.detail = p.reason; return entry }
        if let (t, u) = WhoopTerms.parts(h, n) {
            entry.value = .value(text: t, unit: u, receipt: MetricText.receipt(h.metric), style: DisplayValue.style(for: h.metric),
                                 sample: s.sample)
        } else {
            entry.value = s.display(h.metric)
        }
        entry.isResearch = h.metric.tier == .research
        entry.detail = [p.caption ?? algorithm(h.metric), origin(h),
                         day == today ? "today" : day == today.adding(days: -1) ? "yesterday" : dayText(day, s)].joined(separator: " · ")
        return entry
    }

    static func dayText(_ d: LocalDay, _ s: PresenterSnapshot) -> String {
        let today = LocalDay(date: s.now, calendar: s.calendar)
        if d == today { return "today" }
        if d == today.adding(days: -1) { return "yesterday" }
        return MGFormat.shortDate(d.start(in: s.calendar.timeZone).addingTimeInterval(12 * 3600), calendar: s.calendar)
    }

    // MARK: Metric sources

    static func sources(_ s: PresenterSnapshot, key: String) -> [SourceRow] {
        shown(s, key: key).map { x in
            let m = x.row.metric
            return SourceRow(id: "\(m.variant ?? "")|\(m.computedOn.rawValue)|\(m.window ?? "")",
                             label: algorithm(m), origin: origin(x), value: s.display(m), day: x.row.day)
        }
    }

    // MARK: Group measures (GroupPipeline + PC + imports)

    /// True unless a custom range ended before today (today's live values are then not part of the period).
    static func todayInPeriod(_ s: PresenterSnapshot) -> Bool {
        let today = LocalDay(date: s.now, calendar: s.calendar)
        return PCHistoryPlan.periodEnd(s.explore.period, today: today) >= today
    }

    static func groupMeasures(_ s: PresenterSnapshot, gid: String) -> [GroupMeasureRow] {
        let names = ExploreCatalogue.allMeasures.flatMap { $0.1 }.filter { $0.group == gid }
        return names.map { e in
            var values: [LabeledValue] = []
            var seen = Set<String>()
            // T9822: today's group metrics belong to the period only when today is inside it.
            for g in s.groupMeasures where g.groupId == gid && g.metric == e.key && todayInPeriod(s) {
                for mb in g.members where !mb.hidden {
                    let id = "\(mb.variant)|\(mb.metric?.computedOn.rawValue ?? "phone")"
                    seen.insert(id)
                    let label = GroupCatalogue.member(gid, mb.variant)?.label ?? mb.variant
                    let value = mb.metric.map { s.display($0) } ?? .blank(reason: waiting(e.key), receipt: nil)
                    values.append(LabeledValue(id: id, label: label == mb.variant ? label : "\(label) · \(mb.variant)",
                                               value: value, caption: mb.variant == g.primaryVariant ? "read" : nil,
                                               intent: .openMetric(key: e.key, variant: mb.variant)))
                }
            }
            for x in shown(s, key: e.key) {
                let r = x.row
                let id = "\(r.metric.variant ?? "")|\(r.metric.computedOn.rawValue)"
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                values.append(LabeledValue(id: id, label: algorithm(r.metric), value: s.display(r.metric),
                                           caption: "\(origin(r.metric))\(x.also.map { " (also via \($0))" } ?? "") · \(dayText(r.day, s))",
                                           intent: .openMetric(key: e.key, variant: r.metric.variant)))
            }
            if values.isEmpty {
                values = [LabeledValue(id: "none", label: e.name, value: .blank(reason: waiting(e.key), receipt: nil))]
            }
            return GroupMeasureRow(key: e.key, name: e.name, values: values)
        }
    }

    // MARK: Computed on PC

    static let modelTitles: [String: String] = [
        "pc.ms-script": "Mo's script (MS-01…31) on the PC",
        "pc.hrv-rescore": "HRV re-score: LF / HF power (ALG-011)",
        "pc.rollups": "Week & month roll-ups, change points (ALG-075, ALG-131)",
        "pc.group-agreement": "Method agreement (ALG-079)",
        "pc.whoop-agreement": "Ours vs WHOOP on past data (ALG-079)",
        "pc.phenoage": "PhenoAge from your labs (ALG-070)",
        "pc.labs": "Your measured labs, every draw (ALG-071 / 072 and the rest)",
        "pc.cause-finder": "Cause finder (ALG-124, Python)",
        "r.case-crossover": "Cause finder (ALG-124, R)",
        "r.distributed-lag": "Lag effects 0–7 days (ALG-064, R)",
        "pc.bp-fit": "BP from cuff readings (ALG-017)",
        "pc.coach": "Coach briefing",
        "pc.receipt-check": "Receipt check: what the PC stored",
        "pc.checkin-model": "Energy / focus / mood / KSS / reaction-time model (ALG-053)",
        "pc.crash-finder": "Crash finder (ALG-055)",
        "pc.caffeine-personal": "Your caffeine half-life and sleep sensitivity (ALG-062)",
        "pc.bioage": "Biological age, KDM + dysregulation (ALG-077)",
        // wave 4 (2026-10-11)
        "pc.spo2-gate": "Strap SpO₂ checked against WHOOP (noop's gate)",
        "pc.led-identity": "Which optical blocks are the SpO₂ LEDs? (research)",
    ]
    /// Result keys that say nothing to Mo (bookkeeping), left out of the notes.
    static let quietExtras: Set<String> = ["computed_on", "produced_at", "imports", "briefing_sha256", "path",
                                           // wave 4: the structured copies of what `text` / `points` already say
                                           "gate", "devices", "experiment"]

    static func pcRows(_ s: PresenterSnapshot) -> [PCModelRow] {
        var newest: [String: LabResult] = [:]
        var order: [String] = []
        for r in s.pcResults where newest[r.modelId] == nil {     // newest seq first
            newest[r.modelId] = r
            order.append(r.modelId)
        }
        var rows: [PCModelRow] = order.compactMap { id in
            guard let r = newest[id] else { return nil }
            let status = r.status ?? "ok"
            let tone: StatusTone = status == "ok" ? .good : (status == "error" ? .bad : .warn)
            let when = MGFormat.shortDate(r.date.start(in: s.calendar.timeZone).addingTimeInterval(12 * 3600),
                                          calendar: s.calendar)
            let values = r.metrics.enumerated().map { i, m -> LabeledValue in
                let registered = MetricKey(rawValue: m.name) != nil
                let name = registered ? ExploreCatalogue.name(m.name) : m.name
                let label = m.variant.map { "\(name) · \($0)" } ?? name
                return LabeledValue(id: "\(i)|\(m.name)|\(m.variant ?? "")|\(m.window ?? "")", label: label,
                                    value: s.display(m), caption: m.window.map { "computed on PC · \($0)" }
                                        ?? "computed on PC",
                                    intent: registered ? .openMetric(key: m.name, variant: m.variant) : nil)
            }
            // Mo's own drop-in algorithms (pclab/plugins/, model ids mo.<plugin>) keep their own name
            let title = modelTitles[id] ?? (id.hasPrefix("mo.") ? "Your algorithm: " + id.dropFirst(3) : id)
            return PCModelRow(id: id, title: title,
                              status: "\(status) · \(when) · \(id)@\(r.modelVersion)", tone: tone,
                              reason: status == "ok" ? nil : r.reason, values: values, notes: notes(r),
                              isOpen: s.ui.openRows.contains("pc:" + id))
        }
        if !s.pcResultsUnreadable.isEmpty {
            rows.append(PCModelRow(id: "unreadable", title: "Results the app could not read", status: "error",
                                   tone: .bad, reason: s.pcResultsUnreadable.prefix(10).joined(separator: "; "),
                                   values: [], notes: [], isOpen: s.ui.openRows.contains("pc:unreadable")))
        }
        return rows
    }

    /// The PC's own words from a result's extra keys: roll-up key points, the coach's text and points, then every
    /// other key, generically (lists of objects as "k v, k v" lines, at most 8 per key).
    static func notes(_ r: LabResult) -> [String] {
        var out: [String] = []
        if case .array(let rollups)? = r.extra["rollups"] {
            for case .object(let o) in rollups {
                let label = o["label"].flatMap(text) ?? "roll-up"
                if case .array(let kp)? = o["key_points"] {
                    out += kp.compactMap(text).map { "\(label): \($0)" }
                }
            }
        }
        if let t = r.extra["text"].flatMap(text) { out.append(t) }
        if case .array(let pts)? = r.extra["points"] { out += pts.compactMap(text).map { "• " + $0 } }
        for (k, v) in r.extra.sorted(by: { $0.key < $1.key })
        where !["rollups", "text", "points"].contains(k) && !quietExtras.contains(k) {
            switch v {
            case .array(let items):
                for item in items.prefix(8) { out.append("\(k): \(flat(item))") }
                if items.count > 8 { out.append("\(k): … \(items.count - 8) more") }
            case .null:
                continue
            default:
                out.append("\(k): \(flat(v))")
            }
        }
        return out
    }

    static func text(_ v: JSONValue) -> String? {
        if case .string(let s) = v { return s }
        return nil
    }

    /// One JSON value as a short line (140 characters at most).
    static func flat(_ v: JSONValue) -> String {
        let s: String
        switch v {
        case .null: s = "—"
        case .bool(let b): s = b ? "yes" : "no"
        case .number(let d): s = d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : MGFormat.number(d, decimals: 3)
        case .string(let t): s = t
        case .array(let a): s = a.map(flat).joined(separator: ", ")
        case .object(let o): s = o.sorted { $0.key < $1.key }.map { "\($0.key) \(flat($0.value))" }.joined(separator: ", ")
        }
        return s.count > 140 ? String(s.prefix(139)) + "…" : s
    }

    // MARK: Today's other outputs

    static func extras(_ s: PresenterSnapshot) -> [ExtraRow] {
        guard let x = s.dayExtras else {
            return [ExtraRow(id: "none", title: "Today's other outputs",
                             value: .blank(reason: "Not computed yet: the next compute fills these in.", receipt: nil),
                             detail: nil)]
        }
        func r(_ method: String, _ tier: Tier = .estimate) -> Receipt {
            Receipt(computedOn: .phone, tier: tier, at: x.at, method: method)
        }
        var out: [ExtraRow] = []
        if let m = x.movement {
            out.append(ExtraRow(id: "movement", title: "Movement today",
                                value: s.worded("walk \(m.walkMin) · run \(m.runMin) min", receipt: r("ALG-044@1")),
                                detail: "ALG-044 · strap activity class · active \(m.activeMin), still \(m.stillMin) "
                                    + "of \(m.knownMin) min known"))
        } else {
            out.append(ExtraRow(id: "movement", title: "Movement today",
                                value: .blank(reason: "No classed strap seconds today yet.", receipt: nil), detail: "ALG-044"))
        }
        if let t = x.stepTicks {
            out.append(ExtraRow(id: "ticks", title: "Strap step ticks (uncalibrated)",
                                value: s.worded(MGFormat.grouped(Int(t.rounded())), unit: "ticks",
                                                receipt: r("ALG-040@1 raw ticks", .research), style: .research),
                                detail: "ALG-040 · ticks are not steps: calibration needs 7 days with iPhone or "
                                    + "imported Apple Health steps"))
        }
        if let med = x.medication {
            let level = med.levelNow.map { "\(MGFormat.number($0 * 100, decimals: 0)) % of peak" }
            let peak = med.peakAt.map { "peak \(MGFormat.time($0, calendar: s.calendar))" }
            out.append(ExtraRow(id: "medication", title: "\(med.name) level",
                                value: level.map { s.worded($0, receipt: r("ALG-143@1")) }
                                    ?? .blank(reason: "No level at this time.", receipt: r("ALG-143@1")),
                                detail: (["ALG-143 · label PK curve, not dosing advice"] + [peak].compactMap { $0 })
                                    .joined(separator: " · ")))
        } else {
            out.append(ExtraRow(id: "medication", title: "Medication level",
                                value: .blank(reason: x.medicationReason ?? "No dose logged today.", receipt: nil),
                                detail: "ALG-143"))
        }
        if let n = x.nicotine {
            let hr = n.hrDeltaBpm.map { MetricText.signed($0, decimals: 0) + " bpm HR" }
            let rm = n.rmssdDeltaMs.map { MetricText.signed($0, decimals: 0) + " ms RMSSD" }
            let words = [hr, rm].compactMap { $0 }.joined(separator: ", ")
            out.append(ExtraRow(id: "nicotine", title: "Nicotine response",
                                value: words.isEmpty ? .blank(reason: "No change measured.", receipt: r("ALG-063@1"))
                                    : s.worded(words, receipt: r("ALG-063@1")),
                                detail: "ALG-063 · after vs before \(n.sessions) vape session\(n.sessions == 1 ? "" : "s")"))
        } else {
            out.append(ExtraRow(id: "nicotine", title: "Nicotine response",
                                value: .blank(reason: x.nicotineReason ?? "No vape session today.", receipt: nil),
                                detail: "ALG-063"))
        }
        for a in x.adherence {
            out.append(ExtraRow(id: "adherence:" + a.name, title: "\(a.name) taken",
                                value: a.due > 0 ? s.worded("\(a.taken) of \(a.due)", receipt: r("ALG-069@1", .high))
                                    : .blank(reason: a.reason ?? "Nothing due yet today.", receipt: nil),
                                detail: "ALG-069 · scheduled times so far today"))
        }
        if let h = x.socialJetlagHours {
            out.append(ExtraRow(id: "sjl", title: "Social jetlag",
                                value: s.worded(MGFormat.duration(h * 3600), receipt: r("ALG-116@1")),
                                detail: "ALG-116 · mid-sleep on free vs work nights, last 28"))
        } else {
            out.append(ExtraRow(id: "sjl", title: "Social jetlag",
                                value: .blank(reason: x.socialJetlagReason ?? "Waiting for first night", receipt: nil),
                                detail: "ALG-116"))
        }
        if x.habits.isEmpty {
            out.append(ExtraRow(id: "habits", title: "Habits vs next night",
                                value: .blank(reason: "Needs logged days with and without a habit.", receipt: nil),
                                detail: "G-HABIT · ALG-067 / ALG-125"))
        }
        for h in x.habits {
            let habit = h.habit.hasPrefix("medication:") ? String(h.habit.dropFirst(11)) : h.habit
            let outcome = ExploreCatalogue.name(h.outcome)
            let value: DisplayValue = h.cohensD.map {
                s.worded("d " + MetricText.signed($0, decimals: 2), receipt: r("ALG-067@1", .research), style: .research)
            } ?? .blank(reason: h.reason ?? "Too few days.", receipt: nil)
            out.append(ExtraRow(id: "habit:\(h.habit)|\(h.outcome)", title: "\(habit.capitalized) → next night \(outcome)",
                                value: value, detail: "G-HABIT · \(h.nWith) days with, \(h.nWithout) without · "
                                    + "correlation, not cause"))
        }
        return out
    }
}

// MARK: - Working on…

public enum WorkingPresenter {
    /// T25: a job younger than this is not shown in the top strip.
    public static let shortTaskSeconds: TimeInterval = 10

    /// T25: the strip is one compact line. One job reads as itself; several read as the first plus "+N more"
    /// (the others are one tap away in Settings › Working on). nil when nothing shows.
    public static func compactLine(_ state: WorkingState) -> String? {
        guard let first = state.lines.first else { return nil }
        let more = state.lines.count - 1
        return more > 0 ? first.text + " · +\(more) more" : first.text
    }

    public static func make(_ s: PresenterSnapshot) -> WorkingState {
        // T142: Mo can hide the strip (Settings › Top bar). The presenter has no failure line, so nothing urgent hides here.
        if s.settings.hideWorkingBars { return WorkingState(lines: []) }
        var lines: [WorkingState.Line] = []
        // T25: a download or compute that has run for under `shortTaskSeconds` is not worth a line (it would flash on
        // and off); anything longer shows. Jobs with no start time (uploads, Health) are always shown.
        if let h = s.inputs.history, s.now.timeIntervalSince(h.startedAt) >= shortTaskSeconds {
            var text = "Strap history: \(h.chunksStored) chunk\(h.chunksStored == 1 ? "" : "s"), "
                + "\(MGFormat.grouped(h.recordsStored)) records"
            if let t = HistoryProgressWords.tail(h, now: s.now, hm: s.hm) { text += " · " + t }
            lines.append(.init(id: "history", text: text, fraction: HistoryProgressWords.barFraction(h, now: s.now)))
        }
        if let c = s.working.compute, s.now.timeIntervalSince(c.since) >= shortTaskSeconds {
            lines.append(.init(id: "compute", text: "Computing \(c.days) day\(c.days == 1 ? "" : "s") (\(c.reason))",
                               fraction: nil))
        }
        if let y = s.working.sync {
            let frac = y.total > 0 ? min(1, Double(y.done) / Double(y.total)) : nil
            switch y.phase {
            case .uploading:
                lines.append(.init(id: "upload", text: "Sending to the PC: \(y.done) of \(y.total)", fraction: frac))
            case .profile:
                lines.append(.init(id: "profile", text: "Sending your profile to the PC", fraction: nil))
            case .fetchingResults:
                lines.append(.init(id: "results", text: "PC results: \(MGFormat.grouped(y.done)) of "
                                   + "\(MGFormat.grouped(y.total)) (past days and models)", fraction: frac))
            }
        }
        if let h = s.working.healthImport {
            lines.append(.init(id: "health", text: h, fraction: nil))
        }
        return WorkingState(lines: lines)
    }
}

// MARK: - Settings › Working on (T149, 2026-10-12)

/// One running or waiting job, in words, for Settings › Working on. Unlike `WorkingPresenter` this is never emptied by
/// the "hide the bars" switch: with the bars hidden, this list is the only place the jobs show.
public struct WorkingJob: Equatable, Sendable, Identifiable {
    public var id: String
    /// What is being done: "Sending days to the PC".
    public var title: String
    /// Where it is going: "This phone → PC".
    public var destination: String
    /// How far along, in words: "120 of 366".
    public var progress: String
    /// 0…1 when the end is known.
    public var fraction: Double?
    /// Why it is not moving; nil while it runs.
    public var waitingBecause: String?
    /// "since 9:24 AM" (12-hour), when the start is known.
    public var since: String?
    /// True when the Strap & sync screen shows more about it; false means the detail is only this row.
    public var opensStrapSync: Bool

    public init(id: String, title: String, destination: String, progress: String, fraction: Double? = nil,
                waitingBecause: String? = nil, since: String? = nil, opensStrapSync: Bool = false) {
        self.id = id
        self.title = title
        self.destination = destination
        self.progress = progress
        self.fraction = fraction
        self.waitingBecause = waitingBecause
        self.since = since
        self.opensStrapSync = opensStrapSync
    }
}

public struct WorkingDetailState: Equatable, Sendable {
    public var jobs: [WorkingJob]
    public var idleLine: String

    public init(jobs: [WorkingJob], idleLine: String = "Nothing is running or waiting.") {
        self.jobs = jobs
        self.idleLine = idleLine
    }

    public var isEmpty: Bool { jobs.isEmpty }
    public static let empty = WorkingDetailState(jobs: [])
}

public enum WorkingDetailPresenter {
    public static func make(_ s: PresenterSnapshot) -> WorkingDetailState {
        var jobs: [WorkingJob] = []
        let pcWait = pcWaitReason(s)

        if let h = s.inputs.history {
            var progress = "\(h.chunksStored) chunk\(h.chunksStored == 1 ? "" : "s"), "
                + "\(MGFormat.grouped(h.recordsStored)) records"
            if let t = HistoryProgressWords.tail(h, now: s.now, hm: s.hm) { progress += " · " + t }
            jobs.append(WorkingJob(id: "history", title: "Downloading the strap's history", destination: "Strap → this phone",
                                   progress: progress, fraction: HistoryProgressWords.barFraction(h, now: s.now), waitingBecause: strapWaitReason(s),
                                   since: "since " + s.hm(h.startedAt), opensStrapSync: true))
        }
        if let c = s.working.compute {
            jobs.append(WorkingJob(id: "compute", title: "Computing \(c.days) day\(c.days == 1 ? "" : "s") (\(c.reason))",
                                   destination: "On this phone", progress: "Running the days with new or changed data — no progress figure for this one",
                                   since: "since " + s.hm(c.since)))
        }
        if let y = s.working.sync {
            let frac = y.total > 0 ? min(1, Double(y.done) / Double(y.total)) : nil
            switch y.phase {
            case .uploading:
                jobs.append(WorkingJob(id: "upload", title: "Sending days to the PC", destination: "This phone → PC",
                                       progress: "\(y.done) of \(y.total)", fraction: frac, waitingBecause: pcWait,
                                       opensStrapSync: true))
            case .profile:
                jobs.append(WorkingJob(id: "profile", title: "Sending your profile to the PC", destination: "This phone → PC",
                                       progress: "In progress", waitingBecause: pcWait, opensStrapSync: true))
            case .fetchingResults:
                jobs.append(WorkingJob(id: "results", title: "Fetching past days and models from the PC",
                                       destination: "PC → this phone",
                                       progress: "\(MGFormat.grouped(y.done)) of \(MGFormat.grouped(y.total))",
                                       fraction: frac, waitingBecause: pcWait, opensStrapSync: true))
            }
        }
        if let h = s.working.healthImport {
            jobs.append(WorkingJob(id: "health", title: "Apple Health", destination: "Apple Health (through a Shortcut)",
                                   progress: h, waitingBecause: "Waiting for the Shortcut to run."))
        }
        // Days queued for the PC with no send under way: say so, and say why, only when the PC is the reason.
        if !jobs.contains(where: { ["upload", "profile"].contains($0.id) }), let why = pcWait, !s.sample,
           s.inputs.sync.state != .notSetUp {
            var parts: [String] = []
            if let d = s.inputs.sync.unsyncedDays, d > 0 { parts.append("\(d) day\(d == 1 ? "" : "s")") }
            if let b = s.strapSync.unsyncedBytes, b > 0 { parts.append(TodayPresenter.bytes(b)) }
            if !parts.isEmpty {
                jobs.append(WorkingJob(id: "queued", title: "Days waiting for the PC", destination: "This phone → PC",
                                       progress: parts.joined(separator: " · "), waitingBecause: why, opensStrapSync: true))
            }
        }
        return WorkingDetailState(jobs: jobs)
    }

    /// Why a send to the PC is not moving; nil when the PC is reachable. Phone-locked and charging-only reasons are not
    /// inputs the presenter has yet, so they are never claimed.
    static func pcWaitReason(_ s: PresenterSnapshot) -> String? {
        if s.sample { return "Sample data is on, so sync is off." }
        let sync = s.inputs.sync
        switch sync.state {
        case .online: return nil
        case .offline: return "The PC is offline. It goes when the PC is reachable again."
        case .notSetUp: return "PC Lab is not set up, so nothing is sent."
        case .pairing: return "Pairing with the PC is not finished."
        case .error: return "Sync error" + (sync.error.map { ": \($0)" } ?? ".")
        }
    }

    static func strapWaitReason(_ s: PresenterSnapshot) -> String? {
        switch s.inputs.strap.link {
        case .connected: return nil
        case .bluetoothOff: return "Bluetooth is off, so the download is paused."
        case .bluetoothNotAllowed: return "Bluetooth is not allowed for this app, so the download is paused."
        default: return "The strap is not connected, so the download is paused."
        }
    }
}

// MARK: - Progress wording (T25, 2026-10-12)

public enum HistoryProgressWords {
    /// T10013 (r8b, 2026-10-17): what the download is doing, in the terms Mo reads. The finish line is fixed when the run
    /// starts, so a percent used to stall at 98-99 while the strap's newest chunk trailed "now"; in the last stretch, and
    /// once the strap has nothing more, the words say so instead of a percent.
    public enum State: Equatable {
        case unknownEnd
        case percent(Double)
        /// The newest chunk is within `nearNowSeconds` of now.
        case catchingUp
        /// The strap has no more chunks; the date is the newest data's time.
        case caughtUp(Date)
    }

    public static let nearNowSeconds: TimeInterval = 600

    public static func state(_ h: HistoryProgress, now: Date) -> State {
        if h.caughtUp {
            let t = h.newestTs.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? now
            return .caughtUp(t)
        }
        if let n = h.newestTs, now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(n))) <= nearNowSeconds {
            return .catchingUp
        }
        if let f = h.fraction { return .percent(f) }
        return .unknownEnd
    }

    /// The part after "·" on the working line: "98 %", "catching up to now", "caught up to 9:41 AM"; nil = no end known.
    public static func tail(_ h: HistoryProgress, now: Date, hm: (Date) -> String) -> String? {
        switch state(h, now: now) {
        case .unknownEnd: return nil
        case .percent(let f): return "\(MGFormat.number(f * 100, decimals: 0)) %"
        case .catchingUp: return "catching up to now"
        case .caughtUp(let t): return "caught up to \(hm(t))"
        }
    }

    /// The bar: a real fraction only while a percent is shown; full when caught up; none (indeterminate) near now.
    public static func barFraction(_ h: HistoryProgress, now: Date) -> Double? {
        switch state(h, now: now) {
        case .percent(let f): return f
        case .caughtUp: return 1
        case .unknownEnd, .catchingUp: return nil
        }
    }

    /// "98 % · 17 min of 18 min" for a download whose end is known; nil while it is not (the caller shows the chunk
    /// count). Durations are truncated whole minutes, so 17 min 40 s of 18 min 20 s used to read "18 min of 18 min · 98 %".
    /// When the two durations read the same but the download is not done, the words say so instead of repeating itself:
    /// "98 % · almost all of 18 min".
    public static func coveredOfTotal(_ h: HistoryProgress) -> String? {
        guard let f = h.fraction, let c = h.coveredSeconds, let t = h.totalSeconds else { return nil }
        let pct = "\(Int((f * 100).rounded(.down))) %"
        let covered = MGFormat.duration(Double(c))
        let total = MGFormat.duration(Double(t))
        if covered == total { return f < 1 ? "\(pct) · almost all of \(total)" : "\(pct) · \(total)" }
        return "\(pct) · \(covered) of \(total)"
    }
}

// MARK: - The one failure badge on Today (T108, 2026-10-12)

/// With the "Working on" bars hidden, a failure must still show: one badge, one line. Progress is never a badge; only
/// sync broken, a history download that stopped moving, or a compute that has run far too long.
public struct WorkingBadge: Equatable, Sendable {
    public var text: String
    public var tone: StatusTone
    /// Tapping it opens Strap & sync (sync and history problems); false = Settings › Working on has the detail.
    public var opensStrapSync: Bool

    public init(text: String, tone: StatusTone = .bad, opensStrapSync: Bool) {
        self.text = text
        self.tone = tone
        self.opensStrapSync = opensStrapSync
    }
}

public enum WorkingBadgePresenter {
    /// A history download with no chunk stored or acked for this long is stuck (a normal chunk takes seconds).
    public static let historyStuckSeconds: TimeInterval = 10 * 60
    /// The phone pipelines normally finish in a minute or two; this long is wrong.
    public static let computeStuckSeconds: TimeInterval = 20 * 60

    public static func make(_ s: PresenterSnapshot) -> WorkingBadge? {
        if s.sample { return nil }
        // P9734: the PC has not accepted an upload for hours while data waits ("PC not receiving since 2:21 AM").
        if let banner = s.strapSync.pcSync?.banner { return WorkingBadge(text: banner, opensStrapSync: true) }
        let sync = s.inputs.sync
        if sync.state == .error {
            return WorkingBadge(text: "Sync to the PC is failing" + (sync.error.map { ": \($0)" } ?? ""), opensStrapSync: true)
        }
        if let h = s.inputs.history, s.inputs.strap.link == .connected {
            let lastMove = h.lastAckAt ?? h.startedAt
            if s.now.timeIntervalSince(lastMove) >= historyStuckSeconds {
                return WorkingBadge(text: "Strap history has not moved since \(s.hm(lastMove))", tone: .warn,
                                    opensStrapSync: true)
            }
        }
        if let c = s.working.compute, s.now.timeIntervalSince(c.since) >= computeStuckSeconds {
            return WorkingBadge(text: "Computing has been running since \(s.hm(c.since))", tone: .warn, opensStrapSync: false)
        }
        return nil
    }
}
