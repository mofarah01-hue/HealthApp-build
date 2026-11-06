import Foundation
import MGDomain

// WP-23b. Helpers every presenter shares: finding the metric to show, turning a Metric into a DisplayValue with its
// receipt (blank + the Metric's own note when missing, R6), times and durations in the snapshot's calendar.
// Pure: nothing here reads a clock or computes a statistic.

enum PresenterKit {
    /// Shown when no Metric at all is stored for a value (the Metric itself would carry a better reason).
    static let notStored = "Not computed yet — nothing stored for this."
    /// UX rule: a Metric with no value and no note still never shows a number.
    static let noReason = "No value, and no reason recorded."
    static let hrRecoveryNotBuilt = "No 60-second HR recovery was stored for this workout."
    static let hrRecoveryName = MetricKey.hrRecovery60.rawValue
}

// MARK: - Snapshot lookups

extension PresenterSnapshot {
    /// Times and dates in the snapshot's calendar.
    func hm(_ date: Date) -> String { MGFormat.time(date, calendar: calendar) }
    func range(_ a: Date, _ b: Date) -> String { MGFormat.timeRange(a, b, calendar: calendar) }

    /// Every stored metric named `name` (all variants, all windows).
    func all(_ name: String) -> [Metric] { metrics.filter { $0.name == name } }

    /// The variant Mo reads for a group: his choice, else the catalogue default (UX §11 / §12), else the first member
    /// present.
    func readVariant(group gid: String, among present: [Metric] = [], window: String? = nil,
                     honourMap: Bool = true) -> String? {
        if let v = groupChoices[gid]?.readVariant { return v }
        // T9809: the PC's map decides through the one resolver (`primaryPick`); the group is read in the window its rows
        // share (or the `window` given). The resolver's answer is final: its variant if the group has it, else none.
        if honourMap, let name = present.first?.name {
            let windows = Set(present.map { $0.window ?? "" })
            let w = window ?? (windows.count == 1 ? present.first?.window : nil)
            if let pick = primaryPick(name, among: present, window: w) {
                guard pick.metric.value != nil, let v = pick.metric.variant,
                      present.contains(where: { $0.variant == v && $0.computedOn == pick.metric.computedOn }) else { return nil }
                return v
            }
        }
        if let d = GroupCatalogue.group(gid)?.defaultRead {
            // T13: a rank-derived default with nothing to read yields to the best-ranked member that has a value (never a
            // research one: raw ticks are not steps). A default the UX names stays, blank or not.
            if GroupCatalogue.group(gid)?.explicitDefault == nil, present.first(where: { $0.variant == d })?.value == nil,
               let alt = present.filter({ $0.value?.isFinite == true && $0.tier != .research }).min(by: {
                   (GroupCatalogue.rank(gid, $0.variant), ImportedHistory.rank($0))
                       < (GroupCatalogue.rank(gid, $1.variant), ImportedHistory.rank($1))
               }) {
                return alt.variant
            }
            return d
        }
        return present.first(where: { $0.primary == true })?.variant ?? present.first?.variant
    }

    /// The metric to show for `name`: an exact `variant` when given; for a group member, the read variant (a missing
    /// read member falls back to the best-ranked one present — a blank read member stays blank, never swapped);
    /// else the primary one, else the first. `window` narrows to "night", "day", "workout", "morning" when set.
    /// Imported history (`ImportedHistory`, past days) is shown only when the app has no value of its own that day.
    func metric(_ name: String, variant: String? = nil, window: String? = nil, in source: [Metric]? = nil) -> Metric? {
        // D-SLEEP-PRIORITY-1 (Mo, Nov 5 2026): the night's total and stages come from the ONE sleep resolver (`sleepFill()`),
        // the same one the ring, Night page and sheet read. It supersedes the primary map's PC pick for these names (D1) and the
        // PC-first rule of Round 5 (D-9806-R5b); the map's `sleep_total` only chooses which of our stagers leads.
        if variant == nil, source == nil, PresenterSnapshot.sleepNames.contains(name) { return resolvedSleepMetric(name) }
        // T10011 (r8g): while the strap is still sending the night, no night figure is shown (a half-night total keeps rising).
        if variant == nil, source == nil, PresenterSnapshot.nightAccountingNames.contains(name), sleepDownloadPending() {
            return notProcessedMetric(name)
        }
        let named = (source ?? metrics).filter { $0.name == name }
        if let variant { return narrow(named, window).first { $0.variant == variant } }
        // T9809: the PC's primary map decides first (a PC result, or a phone method compiled in); without a usable
        // pick the usual rule below applies and `primaryLabel` says the PC result is pending.
        if source == nil, let pick = primaryPick(name, among: named, window: window) { return pick.metric }
        let own = shown(narrow(named.filter { !ImportedHistory.isImported($0) }, window))
        if let own, own.value != nil { return own }
        let imported = named.filter { ImportedHistory.isImported($0) && $0.value != nil }
            .sorted { ImportedHistory.rank($0) < ImportedHistory.rank($1) }
        return narrow(imported, window).first ?? own
    }

    /// Rows with `window` (or none); all of them when none has it.
    private func narrow(_ list: [Metric], _ window: String?) -> [Metric] {
        guard let window else { return list }
        let narrowed = list.filter { $0.window == nil || $0.window == window }
        return narrowed.isEmpty ? list : narrowed
    }

    /// The read / ranked / primary / first rule of `metric(_:)` over one list.
    func shown(_ list: [Metric], honourMap: Bool = true) -> Metric? {
        guard !list.isEmpty else { return nil }
        if let gid = list.first(where: { $0.group != nil })?.group {
            if let read = readVariant(group: gid, among: list, honourMap: honourMap), let m = list.first(where: { $0.variant == read }) {
                return m
            }
            let ranked = list.sorted { GroupCatalogue.rank(gid, $0.variant) < GroupCatalogue.rank(gid, $1.variant) }
            return ranked.first
        }
        return list.first { $0.primary == true } ?? list.first
    }

    /// The PC stagers (tier L), best first.
    static let pcSleepVariants = ["pc.fused-stager", "pc.wav2sleep", "pc.sleep-ecg"]   // D-SLEEP-WALK-1 item 3: fused stager is the PC primary
    static let sleepNames = [MetricKey.sleepTotal, .sleepLight, .sleepDeep, .sleepRem, .sleepWake].map(\.rawValue)

    /// The PC stager that has a night for this snapshot's day (a finite total or stage minute), else nil. Mo's rule: when
    /// it exists, it is what Today and the Sleep screens show; the phone's M result is only a placeholder before it.
    func pcSleepVariant() -> String? {
        PresenterSnapshot.pcSleepVariants.first { v in pcSleepHasValue(v) && !pcSleepRejects(v) }
    }

    /// The stager has a finite total or stage minute for the night (before any plausibility check).
    func pcSleepHasValue(_ v: String) -> Bool {
        PresenterSnapshot.sleepNames.contains { n in
            metrics.contains { $0.name == n && $0.variant == v && ($0.value?.isFinite ?? false) }
        }
    }

    /// V3 (2026-10-15) PC sleep gate. The PC SleepECG once said 0 min over a 69 min window for a night the strap flag
    /// put at 6 h; Today must never show that. A PC result is shown only when it is plausible against the strap's night:
    /// its window covers at least 80 % of the strap-flag asleep span, and its total is within the strap total +- 50 %.
    /// A zero or negative total never passes. With no strap night (no strap total / no strap span) or no window in the
    /// PC result, that one check cannot be made and is skipped (the total check still applies where it can).
    static let pcCoverageMin = 0.8
    static let pcTotalTolerance = 0.5
    public static let pcRejectedLabel = "PC result didn't match the strap night"

    /// True when the stager has values for the night and they fail the gate.
    func pcSleepRejects(_ v: String) -> Bool {
        guard pcSleepHasValue(v) else { return false }
        return pcSleepGateFails(total: pcRawTotal(v), window: pcWindow(v))
    }

    /// The gate itself, on a PC total (minutes) and window.
    func pcSleepGateFails(total: Double?, window: DateInterval?) -> Bool {
        if let total {
            if total <= 0 { return true }
            // D4: when the PC's window runs past the strap-flag night, the phone's total is provisional (it was computed
            // before the night was over) and is no yardstick; the coverage check below still applies.
            if !pcWindowRunsPastStrapNight(window), let strap = phoneSleepTotal()?.value, strap.isFinite, strap > 0 {
                let r = total / strap
                if r < 1 - Self.pcTotalTolerance || r > 1 + Self.pcTotalTolerance { return true }
            }
        }
        if let span = strapAsleepSpan(), let w = window, span.duration > 0 {
            let overlap = max(0, min(span.end, w.end).timeIntervalSince(max(span.start, w.start)))
            if overlap < Self.pcCoverageMin * span.duration { return true }
        }
        return false
    }

    /// Some stager has values for the night and every one of them failed the gate.
    var pcSleepWasRejected: Bool {
        PresenterSnapshot.pcSleepVariants.contains { pcSleepHasValue($0) && pcSleepRejects($0) }
            && pcSleepVariant() == nil
    }

    /// First to last asleep ("S") epoch of the strap member's hypnogram.
    func strapAsleepSpan() -> DateInterval? {
        guard let h = DialPresenter.strapHypnogram(self), let st = h.state, h.stepS > 0 else { return nil }
        guard let first = st.firstIndex(where: { $0 == "S" }), let last = st.lastIndex(where: { $0 == "S" }) else { return nil }
        return DateInterval(start: h.start.addingTimeInterval(Double(first) * h.stepS),
                            end: h.start.addingTimeInterval(Double(last + 1) * h.stepS))
    }

    /// The window the PC staged, from its lab result (detail.sleep_window ISO pair, else staging.window_start / _end in
    /// unix seconds); nil when the result does not say.
    func pcWindow(_ v: String) -> DateInterval? {
        for r in pcResults where r.modelId == v && r.date == day {
            if case .object(let d)? = r.extra["detail"], case .array(let w)? = d["sleep_window"], w.count == 2,
               case .string(let a) = w[0], case .string(let b) = w[1], let x = Self.iso(a), let y = Self.iso(b), y > x {
                return DateInterval(start: x, end: y)
            }
            if case .object(let d)? = r.extra["staging"], case .number(let a)? = d["window_start"],
               case .number(let b)? = d["window_end"], b > a {
                return DateInterval(start: Date(timeIntervalSince1970: a), end: Date(timeIntervalSince1970: b))
            }
        }
        return nil
    }

    private static func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The stager's total: its total row, else light + deep + REM; nil when it has neither.
    func pcRawTotal(_ v: String) -> Double? {
        if let m = metrics.first(where: { $0.name == MetricKey.sleepTotal.rawValue && $0.variant == v && ($0.value?.isFinite ?? false) }) {
            return m.value
        }
        let parts = [MetricKey.sleepLight, .sleepDeep, .sleepRem].compactMap { k in
            metrics.first { $0.name == k.rawValue && $0.variant == v && ($0.value?.isFinite ?? false) }?.value
        }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// The PC value for a sleep metric name, or nil (not a sleep name, or no PC result). A PC stager with stages but no
    /// total gets a total summed from its light + deep + REM minutes, noted as such.
    func pcSleepMetric(_ name: String) -> Metric? {
        guard PresenterSnapshot.sleepNames.contains(name), let v = pcSleepVariant() else { return nil }
        let named = metrics.filter { $0.name == name && $0.variant == v }
        if let m = named.first(where: { $0.value?.isFinite ?? false }) { return m }
        guard name == MetricKey.sleepTotal.rawValue else { return named.first }
        let parts = [MetricKey.sleepLight, .sleepDeep, .sleepRem].compactMap { k in
            metrics.first { $0.name == k.rawValue && $0.variant == v && ($0.value?.isFinite ?? false) }
        }
        guard let first = parts.first else { return nil }
        var m = first
        m.name = name
        m.value = parts.compactMap(\.value).reduce(0, +)
        m.note = "light + deep + REM from \(v)"
        return m
    }

    /// The phone's own (tier M) total, ignoring any PC result: for the "is M available" test only.
    func phoneSleepTotal() -> Metric? {
        let named = metrics.filter { $0.name == MetricKey.sleepTotal.rawValue && PresenterSnapshot.pcSleepVariants.contains($0.variant ?? "") == false }
        return metric(MetricKey.sleepTotal.rawValue, in: named)
    }

    func metric(_ key: MetricKey, variant: String? = nil, window: String? = nil) -> Metric? {
        metric(key.rawValue, variant: variant, window: window)
    }

    /// "WHOOP · last night" / "Apple Watch" when `m` is imported history shown where the app has no value of its own
    /// (W10, 2026-10-11: Today shows the import, labelled, instead of an empty cell); nil for the app's own values.
    /// 0.6.0.7: an Apple Health row names who wrote it ("Apple Watch", "WHOOP via Apple Health") and, side by side, the
    /// sources the PC did not pick that day ("also Apple Watch 108.5 bpm"); nothing is merged (Mo, Oct 28: his call later).
    func importCaption(_ m: Metric?) -> String? {
        // The sleep names are labelled by the one sleep resolver (never by the primary map's PC pick or "PC result pending").
        if let m, PresenterSnapshot.sleepNames.contains(m.name) {
            if m.name == MetricKey.sleepTotal.rawValue { return sleepCaption(m) }
        } else if let l = primaryLabel(m) { return l }
        guard let m, ImportedHistory.isImported(m), m.value != nil else { return nil }
        var src: String
        switch m.variant {
        case _ where ImportedHistory.isAppleHealth(m): src = ImportedHistory.shortSource(m.source)
        case ImportedHistory.whoopExport?: src = "WHOOP"
        default: src = ImportedHistory.sourceLabel(m) ?? "imported"
        }
        if m.window == "night" { src += " · last night" }
        let also = ImportedHistory.isAppleHealth(m) ? ImportedHistory.otherSources(note: m.note) : []
        return also.isEmpty ? src : src + " · also " + also.joined(separator: ", ")
    }

    /// Today's day strain (W10, Mo 2026-10-11 21:30: "there is no strain number showed in my today"): the method Mo
    /// chose to read when it has a value; else ALG-036's 0–21 day strain (the all-day number); else the all-day fit to
    /// the exported WHOOP days (T19: needs no sex, quiet history or workout); else the best-ranked
    /// G-LOAD member with a value (MS-01 / MS-02 TRIMP, workouts only); else WHOOP's / Apple's imported strain; else
    /// ALG-036's blank with its reason.
    func dayStrain() -> Metric? {
        let own = metrics.filter { $0.name == MetricKey.strain.rawValue && ($0.window ?? "day") == "day"
            && !ImportedHistory.isImported($0) && $0.variant != "ALG-036:trimp" }
        func valued(_ m: Metric?) -> Metric? { (m?.value?.isFinite ?? false) ? m : nil }
        if let m = primaryPick(MetricKey.strain.rawValue, among: own, window: "day", defaultWindow: "day")?.metric { return m }
        if let chosen = groupChoices["G-LOAD"]?.readVariant, let m = valued(own.first(where: { $0.variant == chosen })) {
            return m
        }
        // D-LOAD-WALK-1 item 1: the 0-21 number is the fitted "WHOOP-style strain (estimate)", ahead of our own net-load map
        if let m = valued(own.first(where: { $0.variant == "ALG-036:fit" })) { return m }
        if let m = valued(own.first(where: { $0.variant == "ALG-036" })) { return m }
        let ranked = own.filter { $0.value?.isFinite ?? false }
            .sorted { GroupCatalogue.rank("G-LOAD", $0.variant) < GroupCatalogue.rank("G-LOAD", $1.variant) }
        if let m = ranked.first { return m }
        if let m = metrics.filter({ $0.name == MetricKey.strain.rawValue && ImportedHistory.isImported($0)
            && ($0.value?.isFinite ?? false) && ($0.window ?? "day") == "day" })
            .sorted(by: { ImportedHistory.rank($0) < ImportedHistory.rank($1) }).first { return m }
        return own.first { $0.variant == "ALG-036" } ?? own.first
    }

    /// The strain HEADLINE (D-LOAD-WALK-1 item 1): today's plain Banister TRIMP (ALG-036:trimp), in TRIMP units; nil without a value.
    func dayTrimp() -> Metric? {
        let m = metrics.first { $0.name == MetricKey.strain.rawValue && $0.variant == "ALG-036:trimp"
            && ($0.window ?? "day") == "day" && !ImportedHistory.isImported($0) }
        return (m?.value?.isFinite ?? false) ? m : nil
    }

    /// Today's body arousal (T98; "stress" until D-HRV-WALK-1): the 0–3 daytime score (ALG-123:daytime); a blank one
    /// (with its note) when it has no value. R9m: the noop daily score (ALG-123:daily) is gone, so there is no fallback
    /// to a number taken from last night; older stored daily rows are ignored.
    func dayStress() -> Metric? {
        let all = metrics.filter { $0.name == MetricKey.stress.rawValue && ($0.window ?? "day") == "day" }
        let day = all.filter { ($0.variant ?? "") == "ALG-123:daytime" }
        func valued(_ m: Metric) -> Bool { m.value?.isFinite ?? false }
        if let m = primaryPick(MetricKey.stress.rawValue, among: day, window: "day", defaultWindow: "day")?.metric { return m }
        return day.first { !ImportedHistory.isImported($0) && valued($0) }
            ?? day.filter { ImportedHistory.isImported($0) && valued($0) }
                .sorted { ImportedHistory.rank($0) < ImportedHistory.rank($1) }.first
            ?? day.first
    }

    /// A finite value of `key`, or nil.
    func number(_ key: MetricKey, window: String? = nil) -> Double? {
        guard let v = metric(key, window: window)?.value, v.isFinite else { return nil }
        return v
    }

    /// The metric shown as a DisplayValue (blank + its note when missing; blank + `missing` when nothing is stored).
    /// Wave 4: the strap's SpO₂ byte reads as a % only after the PC's gate passed (`SpO2Gate`); before, a raw count.
    func display(_ m: Metric?, missing: String = PresenterKit.notStored) -> DisplayValue {
        if let m, SpO2Gate.names.contains(m.name), let pct = SpO2Gate.percent(m, status: spo2Gate, sample: sample) {
            return pct
        }
        return MetricText.display(m, sample: sample, missing: missing)
    }

    /// The newest SpO₂ gate result from the PC (wave 4, #25); "no result" when there is none.
    var spo2Gate: SpO2Gate.Status { SpO2Gate.status(pcResults) }

    func display(_ key: MetricKey, window: String? = nil, missing: String = PresenterKit.notStored) -> DisplayValue {
        display(metric(key, window: window), missing: missing)
    }

    /// A value the presenter worded itself, with the receipt of the metric it came from.
    func worded(_ text: String, unit: String? = nil, receipt: Receipt, style: DisplayValue.Style = .plain) -> DisplayValue {
        .value(text: text, unit: unit, receipt: receipt, style: style, sample: sample)
    }

    /// Receipt for something the phone worked out now from the log or settings ("phone · high · 09:40").
    func phoneReceipt(_ tier: Tier = .high, at: Date? = nil, method: String? = nil) -> Receipt {
        Receipt(computedOn: .phone, tier: tier, at: at ?? now, method: method)
    }

    // MARK: Events

    /// Events of one type, oldest first.
    func eventsOf(_ type: EventType, in source: [EventRecord]? = nil) -> [EventRecord] {
        (source ?? events).filter { $0.type == type && !$0.removed }.sorted { $0.at < $1.at }
    }

    /// Events since today's wake (the dial and "today so far").
    func eventsSinceWake(_ type: EventType) -> [EventRecord] {
        eventsOf(type).filter { $0.at >= context.anchors.wake && $0.at <= now }
    }

    /// Events on the wake day before `day` (morning check-in: "Yesterday from your log").
    func eventsYesterday(_ type: EventType) -> [EventRecord] {
        let start = day.adding(days: -1).start(in: calendar.timeZone)
        let end = day.start(in: calendar.timeZone)
        return eventsOf(type).filter { $0.at >= start && $0.at < end }
    }

    /// Vape hits since wake that count (rejected detections excluded).
    func vapeHitsSinceWake() -> [EventRecord] {
        eventsSinceWake(.substance).filter { e in
            guard case let .substance(f) = e.payload,
                  f.kind == .vapeTick || f.kind == .vape else { return false }
            return f.vape?.detectedStatus != .rejected
        }
    }

    /// Detected vape hits waiting for a yes / no (ALG-046), today only (they expire at midnight, UX §4.2).
    func unconfirmedVapeHits() -> [EventRecord] {
        let midnight = calendar.startOfDay(for: now)
        return eventsOf(.substance).filter { e in
            guard e.at >= midnight, case let .substance(f) = e.payload,
                  f.kind == .vapeTick || f.kind == .vape else { return false }
            return f.vape?.detectedStatus == .unconfirmed
        }
    }

    /// Caffeine doses since wake.
    func caffeineSinceWake() -> [(event: EventRecord, fields: SubstanceFields)] {
        eventsSinceWake(.substance).compactMap { e -> (event: EventRecord, fields: SubstanceFields)? in
            guard case let .substance(f) = e.payload, f.kind == .caffeine else { return nil }
            return (e, f)
        }
    }

    /// Medication / supplement events since wake.
    func medicationsSinceWake() -> [(event: EventRecord, fields: MedicationFields)] {
        eventsSinceWake(.medication).compactMap { e -> (event: EventRecord, fields: MedicationFields)? in
            guard case let .medication(f) = e.payload else { return nil }
            return (e, f)
        }
    }

    /// Prescription schedules (not supplements) with a time today, by the first time.
    func prescriptionSchedules() -> [MedSchedule] {
        settings.schedules.filter { $0.kind != .supplement }
    }

    /// The display name of a schedule: "MedA 20 mg".
    static func scheduleTitle(_ s: MedSchedule) -> String {
        guard let dose = s.dose, dose.isFinite else { return s.name }
        let d = dose == dose.rounded() ? String(Int(dose)) : MGFormat.number(dose, decimals: 1)
        return "\(s.name) \(d) \(s.unit ?? "mg")"
    }

    /// "07:15" from a schedule's first "HH:MM" today.
    func scheduleTime(_ s: MedSchedule) -> Date? {
        guard let first = s.times?.first else { return nil }
        let parts = first.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return PhaseClock.instant(TimeOfDay(hour: parts[0], minute: parts[1]), onDayOf: context.anchors.wake,
                                  calendar: calendar)
    }

    /// Whether a schedule's medication was logged as taken since wake.
    func taken(_ s: MedSchedule) -> EventRecord? {
        medicationsSinceWake().first { pair in
            (pair.fields.scheduleId == s.id || pair.fields.name == s.name) && pair.fields.status != .skipped
        }?.event
    }

    /// The smart-wake window for the coming morning: [L − window, L]; narrowed to its last 15 min in Late night
    /// (UX §8.1 "going to bed late shortens the window to its last 15 min").
    func wakeWindow(narrowed: Bool) -> DialSpan? {
        guard let l = context.anchors.latestWake else { return nil }
        let minutes = narrowed ? min(15, settings.wakeWindowMinutes) : settings.wakeWindowMinutes
        return DialSpan(start: l.addingTimeInterval(-Double(minutes) * 60), end: l)
    }
}

// MARK: - Metric → text

/// How each registry unit reads on screen (ARCHITECTURE §8.3 units; UX §1.3 formats; raw counts are not units).
enum MetricText {
    /// Registry units that are raw strap counts: no unit sign, `.strapRaw` style (BRIEF "raw counts are not units").
    static let rawUnits: Set<String> = ["count", "raw_div_100", "raw_div_128"]
    /// Metric names whose `count` unit is a raw strap byte (SpO₂), never %.
    static let rawNames: Set<String> = ["spo2_strap_mean", "spo2_strap_min", "skin_temp_dev"]

    static func receipt(_ m: Metric) -> Receipt {
        Receipt(computedOn: m.computedOn, tier: m.tier, at: m.at, method: methodText(m), citation: m.citation,
                source: ImportedHistory.sourceLabel(m))
    }

    /// Bug 33 (M-055, M-199): metrics worked out from the raw optical (PPG) stream exist only while Settings › Strap & sync
    /// › Raw optical was on. The blank reason already said so; a filled value now carries the same sentence in its receipt.
    static let rawOpticalNames: Set<String> = [
        "ppg_hr", "ppg_hrv_rmssd", "pulse_rise_time", "pulse_width_half", "pulse_notch_time", "pulse_reflection_index",
        "pulse_notch_rate",
    ]
    static let needsRawOpticalNote = "needs the Raw optical switch (Strap & sync, uses strap battery)"

    static func needsRawOptical(_ m: Metric) -> Bool {
        if ImportedHistory.isImported(m) { return false }
        if rawOpticalNames.contains(m.name) { return true }
        let v = m.variant ?? ""
        return m.name == "resp_rate" && (v.hasSuffix(":ppg") || v.hasSuffix(":r20pulse")) || m.name == "spo2_pct" && m.source.hasPrefix("r20")
    }

    static func methodText(_ m: Metric) -> String? {
        guard needsRawOptical(m), m.value?.isFinite == true else { return m.method }
        guard let method = m.method, !method.isEmpty else { return needsRawOpticalNote }
        return method.contains(needsRawOpticalNote) ? method : method + " · " + needsRawOpticalNote
    }

    static func isRaw(_ m: Metric) -> Bool { rawNames.contains(m.name) || m.unit.hasPrefix("raw_") }

    /// T35: skin temperature ÷ 100 reads as °C, tagged research ("decoded, untested"); every other raw count is `.strapRaw`.
    static func rawStyle(_ m: Metric) -> DisplayValue.Style { m.unit == "raw_div_100" ? .research : .strapRaw }

    /// Blank with the Metric's own note when it has no value (R6); a missing Metric is blank with `missing`.
    static func display(_ m: Metric?, sample: Bool, missing: String = PresenterKit.notStored,
                        style: DisplayValue.Style? = nil) -> DisplayValue {
        guard let m else { return .blank(reason: missing, receipt: nil) }
        let r = receipt(m)
        guard let v = m.value, v.isFinite else {
            let note = (m.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .blank(reason: note.isEmpty ? PresenterKit.noReason : note, receipt: r)
        }
        var (text, unit) = format(v, unit: m.unit, name: m.name)
        let st: DisplayValue.Style = style ?? (isRaw(m) ? rawStyle(m) : DisplayValue.style(for: m))
        return .value(text: text, unit: unit, receipt: r, style: st, sample: sample)
    }

    /// Text and display unit for a registry unit.
    static func format(_ v: Double, unit: String, name: String) -> (String, String?) {
        switch unit {
        case "bpm": return (MGFormat.number(v, decimals: 0), "bpm")
        case "ms": return (MGFormat.number(v, decimals: 0), "ms")
        case "ln_ms": return (MGFormat.number(v, decimals: 2), "ln ms")
        case "ms2": return (MGFormat.number(v, decimals: 0), "ms²")          // T9976: LF / HF power
        case "nu": return (MGFormat.number(v, decimals: 1), "n.u.")          // T9976: normalised units (Task Force 1996)
        case "%": return (MGFormat.number(v, decimals: name == "spo2_pct" || name.hasPrefix("lab_") ? 1 : 0), "%")
        case "degC": return (MGFormat.number(v, decimals: 1), "°C")      // #76: WHOOP's / Apple's own skin temperature
        case "db": return (MGFormat.number(v, decimals: 0), "dB")            // wave 4: the strap's pSNR
        case "fraction": return (MGFormat.number(v * 100, decimals: 0), "%")
        case "ratio", "unitless": return (MGFormat.number(v, decimals: 2), nil)
        case "z": return (signed(v, decimals: 1), "z")
        case "br_min": return (MGFormat.number(v, decimals: 1), "/min")
        case "count", "class":
            if name == "af_screen" { return (afWord(v), nil) }
            // bug 27 (M-146): the count of ALG-132 sentences says what it counts; the sentences are in the note
            if name == "key_points" { let n = Int(v.rounded()); return ("\(n) key point\(n == 1 ? "" : "s")", nil) }
            return (MGFormat.number(v, decimals: 0), nil)
        case "raw_div_100": return (signed(v, decimals: 1), "°C")     // T35: decoded, untested (CLAUDE.md rule 4, D3)
        case "raw_div_128": return (signed(v, decimals: 2), nil)
        case "count_of_5": return ("\(Int(v.rounded())) of 5", nil)
        case "score_0_100", "score_1_100": return (MGFormat.number(v, decimals: 0), "/100")
        case "level_0_2": return (v < 1 ? "nothing to note" : (v < 2 ? "worth noting" : "worth a closer look"), nil)
        case "score_0_10": return (MGFormat.number(v, decimals: 1), "/10")
        case "score_0_21": return (MGFormat.number(v, decimals: 1), "/21")
        case "score_0_5": return (MGFormat.number(v, decimals: 1), "/5")
        case "score_0_3": return (MGFormat.number(v, decimals: 1), "/3")
        case "min": return (MGFormat.duration(minutes: Int(v.rounded(.down))), nil)
        // chronotype MSFsc is a clock time; any other hours (caffeine half-life, Wave 3) are a duration
        case "hours": return name == "chronotype_msf_sc" ? (clock(hours: v), nil) : (MGFormat.number(v, decimals: 1), "h")
        case "score_1_5": return (MGFormat.number(v, decimals: 1), "/5")
        case "kss_1_9": return (MGFormat.number(v, decimals: 1), "KSS")
        case "min_per_100mg": return (MetricText.signed(v, decimals: 0), "min / 100 mg")
        // D-LOAD-WALK-1 item 1: the strain headline is a TRIMP in its own units; the unit is named plainly, never a bare number.
        case "au", "index", "score":
            return (MGFormat.number(v, decimals: 0), unit == "au" && name == MetricKey.strain.rawValue ? "TRIMP" : nil)
        case "ml_kg_min": return (MGFormat.number(v, decimals: 1), "ml/kg/min")
        case "years": return (MGFormat.number(v, decimals: 0), "y")
        case "mg": return (MGFormat.number(v, decimals: 0), "mg")
        case "kcal": return (MGFormat.grouped(Int(v.rounded())), "kcal")
        // T132: a whole count has no decimal point ("3,536 ticks", not "3536.0 ticks")
        case "ticks", "steps": return (MGFormat.grouped(Int(v.rounded())), unit)
        // W10 #96: measured lab units (registry tokens)
        case "ng_dl": return (MGFormat.number(v, decimals: 0), "ng/dL")
        case "pg_ml": return (MGFormat.number(v, decimals: 1), "pg/mL")
        case "ug_dl": return (MGFormat.number(v, decimals: 1), "µg/dL")
        case "nmol_l": return (MGFormat.number(v, decimals: 1), "nmol/L")
        case "mg_dl": return (MGFormat.number(v, decimals: name == "lab_crp" ? 2 : 1), "mg/dL")
        case "mmol_l": return (MGFormat.number(v, decimals: 2), "mmol/L")
        case "umol_l": return (MGFormat.number(v, decimals: 0), "µmol/L")
        case "g_l": return (MGFormat.number(v, decimals: 0), "g/L")
        case "u_l": return (MGFormat.number(v, decimals: 0), "U/L")
        case "fl": return (MGFormat.number(v, decimals: 1), "fL")
        case "k_per_ul": return (MGFormat.number(v, decimals: 1), "×10³/µL")
        case "IU": return (MGFormat.grouped(Int(v.rounded())), "IU")       // wave 12: vitamin_d_iu_est (an estimate)
        // T14: the units of the other Function Health panel markers (registry tokens, phenoage.LAB_EXTRA)
        case "ng_ml": return (MGFormat.number(v, decimals: 1), "ng/mL")
        case "ug_l": return (MGFormat.number(v, decimals: 1), "µg/L")
        case "miu_ml": return (MGFormat.number(v, decimals: 1), "mIU/mL")
        case "miu_l": return (MGFormat.number(v, decimals: 2), "mIU/L")
        case "uiu_ml": return (MGFormat.number(v, decimals: 1), "µIU/mL")
        case "iu_ml": return (MGFormat.number(v, decimals: 0), "IU/mL")
        case "g_dl": return (MGFormat.number(v, decimals: 1), "g/dL")
        case "pg": return (MGFormat.number(v, decimals: 1), "pg")
        case "pct_by_wt": return (MGFormat.number(v, decimals: 1), "% by wt")
        case "angstrom": return (MGFormat.number(v, decimals: 1), "Å")
        case "m_per_ul": return (MGFormat.number(v, decimals: 2), "×10⁶/µL")
        case "cells_per_ul": return (MGFormat.grouped(Int(v.rounded())), "cells/µL")
        case "ml_min_1_73m2": return (MGFormat.number(v, decimals: 0), "mL/min/1.73 m²")
        case "ph": return (MGFormat.number(v, decimals: 1), nil)
        case "sg": return (MGFormat.number(v, decimals: 3), nil)
        case "titer": return (MGFormat.number(v, decimals: 0), nil)
        // Bug 5 (M-151, M-152): an instant (focus window, caffeine cutoff, onset) reads "Oct 4, 8:39 PM", never the raw epoch
        case "unix_s": return (dateTime(v, timeZone: timeZone), nil)
        default: return (MGFormat.number(v, decimals: 1), unit.isEmpty ? nil : unit)
        }
    }

    /// A registry `unix_s` metric as an instant; nil when blank or another unit.
    static func instant(_ m: Metric?) -> Date? {
        guard let v = m?.value, v.isFinite, m?.unit == "unix_s" else { return nil }
        return Date(timeIntervalSince1970: v)
    }

    /// Metrics whose words live in the note, not the number (score drivers, key points): their rows show the note.
    static let noteIsContent: Set<String> = ["score_drivers", "key_points", "activity_cost"]

    /// The phone's zone (Mo is Pacific); tests pass their own.
    static var timeZone: TimeZone { .current }

    /// Unix seconds as "Oct 4, 8:39 PM" in `timeZone` (12-hour AM/PM, Mo's rule).
    static func dateTime(_ v: Double, timeZone: TimeZone) -> String {
        guard v.isFinite else { return "—" }
        let d = Date(timeIntervalSince1970: v)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.month, .day], from: d)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let mon = months[max(0, min(11, (c.month ?? 1) - 1))]
        return "\(mon) \(c.day ?? 1), " + ClockText.hm(d, timeZone: timeZone)
    }

    static func signed(_ v: Double, decimals: Int) -> String {
        (v > 0 ? "+" : "") + MGFormat.number(v, decimals: decimals)
    }

    /// Hours after midnight (chronotype MSFsc) as "3:42 AM".
    static func clock(hours: Double) -> String {
        let total = Int((hours * 60).rounded()) % (24 * 60)
        let m = total < 0 ? total + 24 * 60 : total
        return ClockText.hm(hour: m / 60, minute: m % 60)
    }

    /// G-AF classes (ARCHITECTURE §8.3): 0 regular, 1 possible AF, 2 other irregular, 3 poor quality.
    static func afWord(_ v: Double) -> String {
        switch Int(v.rounded()) {
        case 0: return "regular"
        case 1: return "possible AF"
        case 2: return "other irregular"
        case 3: return "poor quality"
        default: return "—"
        }
    }

    /// Minutes as "7 h 08" (whole minutes, truncated).
    static func minutes(_ v: Double) -> String { MGFormat.duration(minutes: Int(v.rounded(.down))) }
}
