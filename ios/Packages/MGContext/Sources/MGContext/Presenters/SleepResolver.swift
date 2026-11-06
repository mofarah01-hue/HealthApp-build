import Foundation
import MGDomain

// D-SLEEP-PRIORITY-1 (Mo, Thu Nov 5 2026 about 11:10 PM). THE one sleep resolver. `sleepFill()` (SleepFill.swift) decides the
// night once; the Today ring, hub, corner callout, verdict, Last-night strip, Night page, sleep sheet and every
// `metric(sleep_*)` lookup read that decision, so no surface picks again.
//
// Order:
//   1. Our own raw-data night from any bonded device (MG, WHOOP 4.0, a ring): the strap-flag hypnogram, the phone's
//      ALG-150 / ALG-151, or a PC stager that passed the V3 gate. Which of OUR stagers is the headline is a setting:
//      `primary["sleep_total"]` in versions/primary.json ("phone:ALG-150" by default, "pc.<model>@<ver>" to switch).
//   2. Apple Health's complete night. pc.history already picked one source a day (WHOOP first because it is worn 24/7, the
//      Watch when WHOOP has no complete night: history.py `source_rank`, one constant); the phone shows that pick.
//   3. Else blank, with the real reason (partial night, unfinished night, no data).
// The total's stage minutes come from the same source (`SleepStages`), never another one's. The other sources' totals
// are listed beside it (`SleepAlso`).

/// Where the headline night's stage minutes come from: always the headline's own source.
enum SleepStages: Equatable {
    /// A PC stager's rows (variant such as "pc.fused-stager").
    case pc(String)
    /// The phone's stager (ALG-151 and the other G-STAGE members).
    case phone
    /// Only the strap's sleep flag (asleep / awake): no stage minutes exist.
    case strap
    /// An imported source's own stage rows, by its short label ("Apple Watch"); WHOOP via Apple Health writes none.
    case imported(String)
    /// None for this night.
    case none
}

/// One other source's total for the same night, shown beside the headline ("Watch 7 h 44").
struct SleepAlso: Equatable {
    var label: String
    var minutes: Double
}

extension PresenterSnapshot {
    /// The phone stager kept out of the headline path (still listed in the compare rows and the method picker).
    static let rejectedStager = "ALG-120"

    /// The headline setting for a night made from our own raw data.
    enum OwnHeadline: Equatable {
        case phone
        case pc(String)
    }

    /// `versions/primary.json` `sleep_total`: "phone:<variant>" (default) or "pc.<model>@<version>" naming a PC stager.
    func ownSleepHeadline() -> OwnHeadline {
        guard let text = primary[MetricKey.sleepTotal.rawValue], let spec = PrimaryPick.Spec(text) else { return .phone }
        switch spec {
        case .phone: return .phone
        case .pc(let model, _, _): return Self.pcSleepVariants.contains(model) ? .pc(model) : .phone
        }
    }

    /// D4: the PC's window runs well past where the strap-flag night (and so the phone's ALG-150) ended: the phone computed
    /// the night before it was over, so its total is provisional and cannot veto the PC's.
    func pcWindowRunsPastStrapNight(_ window: DateInterval?) -> Bool {
        guard let w = window, let span = strapAsleepSpan() else { return false }
        return w.end > span.end.addingTimeInterval(Self.nightWakeConfirmSeconds)
    }

    /// The label under which a source is listed beside the headline: "Watch", "WHOOP", "iPhone", else its short name.
    static func alsoLabel(_ source: String) -> String {
        let s = ImportedHistory.shortSource(source)
        if s.hasPrefix("WHOOP") { return "WHOOP" }
        if s == "Apple Watch" { return "Watch" }
        return s
    }

    /// "Apple Watch 463.7 min" (an entry of pc.history's "not used" list) as (label, minutes).
    private static func parseOther(_ entry: String) -> SleepAlso? {
        let words = entry.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let i = words.firstIndex(where: { Double($0.replacingOccurrences(of: ",", with: "")) != nil }), i > 0,
              let v = Double(words[i].replacingOccurrences(of: ",", with: "")) else { return nil }
        return SleepAlso(label: alsoLabel(words[..<i].joined(separator: " ")), minutes: v)
    }

    /// The other imported sources' totals for the night (the day's pick and the ones pc.history listed as "not used"),
    /// without `headline`'s own label. Imported rows only: our own stagers have their rows in the Night page compare.
    func sleepAlso(excluding headline: String?) -> [SleepAlso] {
        let rows = metrics.filter {
            $0.name == MetricKey.sleepTotal.rawValue && ImportedHistory.isImported($0) && ImportedHistory.baseVariant($0.variant) == nil
                && ($0.window == nil || $0.window == "night")
        }.sorted { ImportedHistory.rank($0) < ImportedHistory.rank($1) }
        var out: [SleepAlso] = []
        func add(_ a: SleepAlso) {
            guard a.minutes.isFinite, a.minutes > 0, a.label != headline, !out.contains(where: { $0.label == a.label }) else { return }
            out.append(a)
        }
        for r in rows {
            if let v = r.value, v.isFinite { add(SleepAlso(label: Self.alsoLabel(r.source), minutes: v)) }
            for e in ImportedHistory.otherSources(note: r.note) { if let a = Self.parseOther(e) { add(a) } }
        }
        return out
    }

    /// "also: Watch 7 h 44 · WHOOP 7 h 18"; nil when there is no other source.
    static func alsoLine(_ also: [SleepAlso]) -> String? {
        guard !also.isEmpty else { return nil }
        return "also: " + also.map { "\($0.label) \(MetricText.minutes($0.minutes))" }.joined(separator: " · ")
    }

    /// D7: why Apple Health has no complete night, from the blank row pc.history stored ("WHOOP: partial night: ...").
    func importedSleepBlankReason() -> String? {
        let notes = metrics.filter {
            $0.name == MetricKey.sleepTotal.rawValue && ImportedHistory.isImported($0) && !($0.value?.isFinite ?? false)
        }.compactMap { $0.note?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// The phone has a stage minute of its own for the night (any phone stager but ALG-120).
    func hasOwnStageRows() -> Bool {
        metrics.contains {
            PresenterSnapshot.sleepNames.contains($0.name) && $0.name != MetricKey.sleepTotal.rawValue
                && !ImportedHistory.isImported($0) && !PresenterSnapshot.pcSleepVariants.contains($0.variant ?? "")
                && $0.variant != Self.rejectedStager && ($0.value?.isFinite ?? false)
        }
    }

    /// Imported stage rows exist for this source (same writer as the total).
    func importedStageRows(label: String) -> [Metric] {
        metrics.filter {
            PresenterSnapshot.sleepNames.contains($0.name) && $0.name != MetricKey.sleepTotal.rawValue
                && ImportedHistory.isImported($0) && ($0.value?.isFinite ?? false) && Self.alsoLabel($0.source) == label
        }
    }

    // MARK: One metric lookup for the sleep names

    /// `metric(sleep_*)` for the headline night: the resolver's figure for the total, and for a stage name the row of the
    /// SAME source (blank with the reason when that source has none). Never a different source's stage under the total.
    func resolvedSleepMetric(_ name: String) -> Metric {
        let f = sleepFill()
        func blank(_ why: String) -> Metric {
            Metric(name: name, value: nil, unit: "min", tier: .estimate, source: "sleep-resolver", window: "night",
                   computedOn: .phone, at: now, note: why, group: nil, variant: nil)
        }
        if f.fill == .notProcessed { return blank(f.reason ?? Self.notProcessedNoFlag) }
        if name == MetricKey.sleepTotal.rawValue {
            if let m = f.metric, m.value?.isFinite ?? false { return m }
            if let mins = f.minutes {
                var m = blank("")
                m.value = mins; m.note = nil; m.tier = .strap; m.computedOn = .strap; m.source = "strap sleep flag"
                m.method = "strap sleep flag (ALG-150)"; m.variant = "strap"; m.at = strapAsleepSpan()?.end ?? now
                return m
            }
            return blank(f.reason ?? Self.notProcessedNoFlag)
        }
        let rows = metrics.filter { $0.name == name }
        switch f.stages {
        case .pc(let v):
            return rows.first { $0.variant == v && ($0.value?.isFinite ?? false) } ?? blank("\(v) has no \(name) for this night.")
        case .phone:
            // ALG-120 is never a headline stager (stager comparison Nov 5 2026: 4-class kappa 0.12, 62 min low on TST).
            let own = rows.filter {
                !ImportedHistory.isImported($0) && !PresenterSnapshot.pcSleepVariants.contains($0.variant ?? "")
                    && $0.variant != PresenterSnapshot.rejectedStager
            }
            return metric(name, in: own) ?? blank("The phone's stager has no \(name) for this night.")
        case .strap:
            return blank("Only the strap's sleep flag counts this night (asleep / awake); stage minutes come from a stager.")
        case .imported(let label):
            return importedStageRows(label: label).first { $0.name == name } ?? blank("\(label) wrote no \(name) for this night.")
        case .none:
            let who = f.fill == .imported ? (ImportedHistory.shortSource(f.metric?.source ?? "")) : "this source"
            return blank("No stage minutes from \(who) for this night.")
        }
    }

    /// The caption under a sleep figure: the source in words (or "WHOOP · last night" for imported history), then the
    /// other sources beside it.
    func sleepCaption(_ m: Metric) -> String? {
        let f = sleepFill()
        guard f.fill != .notProcessed else { return nil }
        var base: String
        if f.fill == .imported, ImportedHistory.isImported(m) {
            switch m.variant {
            case _ where ImportedHistory.isAppleHealth(m): base = ImportedHistory.shortSource(m.source)
            case ImportedHistory.whoopExport?: base = "WHOOP"
            default: base = ImportedHistory.sourceLabel(m) ?? "imported"
            }
            if m.window == "night" { base += " · last night" }
        } else {
            base = f.sourceLine
        }
        return [base.isEmpty ? nil : base, Self.alsoLine(f.also)].compactMap { $0 }.joined(separator: " · ")
    }
}
