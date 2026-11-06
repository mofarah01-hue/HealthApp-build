import Foundation
import MGDomain

/// T10011 (r8g, 2026-10-17): how far the night has got, decided once here so the Night hero, the Today ring, the hub, the
/// corner and the accessibility label all say the same thing. Presentation only: no sleep algorithm or number changes.
///
/// Order Mo asked for: "not processed yet" (no minutes at all) -> the strap sleep flag's time asleep (purple) -> the
/// phone's staging -> the PC's staging, each labelled with where it came from. A total from a half-downloaded night is
/// never shown as final.
public enum NightFill: String, Equatable, Sendable {
    /// No strap-flag night yet, or the history download has not passed the last asleep epoch.
    case notProcessed
    /// Time asleep counted from the strap's own sleep flag ("S" epochs x step).
    case strapFlag
    /// The phone's staging inside the strap-asleep minutes.
    case phone
    /// A PC stager's night that passed the V3 gate.
    case pc
    /// WHOOP cloud / Apple history for a past day (never today's strap).
    case imported
}

/// The decision, with what each surface needs.
struct SleepFillResult: Equatable {
    var fill: NightFill
    /// Minutes asleep to show; nil for `notProcessed` and when nothing finite is stored.
    var minutes: Double?
    /// The stored metric the figure came from (nil for the strap-flag count and for `notProcessed`).
    var metric: Metric?
    /// Under the Night hero: "strap data . from the strap sleep flag", "ours on the phone", "ours on the PC (wav2sleep)".
    var sourceLine: String
    /// Why there is no figure (`notProcessed`).
    var reason: String?
    /// The value as the screens show it.
    var display: DisplayValue
    /// Where the stage minutes come from: always the total's own source (D-SLEEP-PRIORITY-1).
    var stages: SleepStages = .none
    /// The other sources' totals for the same night, shown beside the headline.
    var also: [SleepAlso] = []
    /// The night's own window when the source gave one (Apple read on the phone); nil = the strap span decides.
    var window: DateInterval?
    /// Fallback 2 came from Apple Health read on the phone (the PC's row is missing), not from the PC's pc.history row.
    var appleOnPhone = false
}

extension PresenterSnapshot {
    /// The history download is considered past the night once the newest stored record is this far beyond the last
    /// asleep epoch (a wake is then in the data).
    static let nightWakeConfirmSeconds: TimeInterval = 20 * 60
    /// No chunk for this long = the download has stalled (WorkingBadgePresenter waits 10 min before it warns; the card
    /// must fall back sooner, since the night is wanted now).
    public static let downloadStallSeconds: TimeInterval = 5 * 60
    static let notProcessedWords = "Not processed yet"
    /// What an empty hero says while the strap is still sending the night.
    static let notProcessedDownloading = "Not processed yet — the night is still coming down from the strap."
    static let notProcessedNoFlag = "Not processed yet — no strap sleep flag is stored for this night."

    /// Minutes asleep from the strap-flag hypnogram: the count of "S" epochs x the epoch length. nil without a strap
    /// hypnogram or without an asleep epoch. `strapAsleepSpan()` is the same hypnogram's first-to-last span.
    func strapSleepMinutes() -> Double? {
        guard let h = DialPresenter.strapHypnogram(self), let st = h.state, h.stepS > 0 else { return nil }
        var n = 0
        for code in st where code?.uppercased() == "S" { n += 1 }
        return n == 0 ? nil : Double(n) * h.stepS / 60
    }

    /// True while the strap is still sending the night: a history download is running and its newest stored record has
    /// not passed the last asleep epoch by `nightWakeConfirmSeconds`. With no asleep epoch yet, any running download
    /// counts. A download that started after the night ended (its first record is past the last asleep epoch) is not
    /// about this night.
    func sleepDownloadPending() -> Bool {
        guard let h = inputs.history, !h.caughtUp else { return false }
        // Nov 6 2026: a download that stopped moving is not "coming down": it must not block the fallbacks forever.
        guard historyIsMoving(h) else { return false }
        guard let span = strapAsleepSpan() else { return true }
        if let f = h.firstTs, span.end < Date(timeIntervalSince1970: TimeInterval(f)) { return false }
        guard let n = h.newestTs else { return true }
        return Date(timeIntervalSince1970: TimeInterval(n)) < span.end.addingTimeInterval(Self.nightWakeConfirmSeconds)
    }

    /// The download stored or acked a chunk within `downloadStallSeconds` (a normal chunk takes seconds).
    func historyIsMoving(_ h: HistoryProgress) -> Bool {
        now.timeIntervalSince(h.lastAckAt ?? h.startedAt) < Self.downloadStallSeconds
    }

    /// A history run that exists, is not finished and has stopped moving: the night (or the rest of it) is still on the strap.
    func historyStalled() -> HistoryProgress? {
        guard let h = inputs.history, !h.caughtUp, !historyIsMoving(h) else { return nil }
        return h
    }

    /// A non-strap, non-PC hypnogram (the phone's stager) with at least one staged (deep / light / REM) run.
    func hasPhoneStaging() -> Bool {
        DialPresenter.hypnograms(self).contains { h in
            guard let v = h.variant, v != "strap", !PresenterSnapshot.pcSleepVariants.contains(v) else { return false }
            return DialPresenter.runs(h.series).contains { [.deep, .light, .rem].contains($0.stage) }
        }
    }

    static func pcLabel(_ variant: String) -> String {
        switch variant {
        case "pc.wav2sleep": return "wav2sleep"
        case "pc.sleep-ecg": return "SleepECG"
        case "pc.fused-stager": return "fused stager"
        default: return variant
        }
    }

    /// THE sleep resolver (D-SLEEP-PRIORITY-1, see SleepResolver.swift): decides the night once, for every surface. Cheap (one pass
    /// over the strap hypnogram), but call it once per presenter and pass the result on.
    func sleepFill() -> SleepFillResult {
        let totalKey = MetricKey.sleepTotal.rawValue
        func notProcessed(_ reason: String) -> SleepFillResult {
            SleepFillResult(fill: .notProcessed, minutes: nil, metric: nil, sourceLine: "", reason: reason,
                            display: .blank(reason: reason, receipt: nil))
        }
        let strapMin = strapSleepMinutes()
        let span = strapAsleepSpan()
        if sleepDownloadPending() { return notProcessed(Self.notProcessedDownloading) }
        let phone = phoneSleepTotal()      // source given, so the gate in `metric(_:)` is not applied here
        let ownPhone: Metric? = phone.flatMap { m in
            (!ImportedHistory.isImported(m) && (m.value?.isFinite ?? false)) ? m : nil
        }
        let pcV = pcSleepVariant()
        let pcM: Metric? = pcV.flatMap { _ in pcSleepMetric(totalKey) }.flatMap { ($0.value?.isFinite ?? false) ? $0 : nil }

        // Priority 1: a night from our own raw data, from any bonded device.
        if strapMin != nil || ownPhone != nil || pcM != nil {
            let also = sleepAlso(excluding: nil)
            if let v = pcV, let m = pcM, let mins = m.value {
                // The setting names the PC stager, or the phone has no night / a night that ended before the PC's (D4).
                let outran = pcWindowRunsPastStrapNight(pcWindow(v))
                let setting = ownSleepHeadline()
                let usePC: Bool
                switch setting {
                case .pc: usePC = true
                case .phone: usePC = (ownPhone == nil && strapMin == nil) || outran
                }
                if usePC {
                    let late = outran && setting == .phone ? " · the phone's night ended earlier" : ""
                    return SleepFillResult(fill: .pc, minutes: mins, metric: m,
                                           sourceLine: "ours on the PC · \(Self.pcLabel(v)) staging" + late,
                                           reason: nil, display: MetricText.display(m, sample: sample), stages: .pc(v), also: also)
                }
            }
            if let strapMin {
                if hasPhoneStaging() {
                    let m = ownPhone
                    let mins = m?.value ?? strapMin
                    let display = m.map { MetricText.display($0, sample: sample) }
                        ?? strapFlagDisplay(minutes: strapMin, span: span)
                    return SleepFillResult(fill: .phone, minutes: mins, metric: m,
                                           sourceLine: "ours on the phone · phone staging", reason: nil, display: display,
                                           stages: .phone, also: also)
                }
                return SleepFillResult(fill: .strapFlag, minutes: strapMin, metric: nil,
                                       sourceLine: "strap data · from the strap sleep flag", reason: nil,
                                       display: strapFlagDisplay(minutes: strapMin, span: span),
                                       stages: hasOwnStageRows() ? .phone : .strap, also: also)
            }
            // No strap-flag hypnogram. A phone figure stored by an earlier pipeline is still labelled and shown.
            if let m = ownPhone, let mins = m.value {
                return SleepFillResult(fill: .phone, minutes: mins, metric: m, sourceLine: "ours on the phone", reason: nil,
                                       display: MetricText.display(m, sample: sample),
                                       stages: hasPhoneStaging() || hasOwnStageRows() ? .phone : .none, also: also)
            }
        }
        // Priority 2: Apple Health's complete night (the day's one pick, WHOOP first, the Watch when WHOOP has none).
        if let m = phone, ImportedHistory.isImported(m), let mins = m.value, mins.isFinite {
            let src = ImportedHistory.isAppleHealth(m) ? ImportedHistory.shortSource(m.source) : ImportedHistory.sourceLabel(m) ?? "imported history"
            let label = Self.alsoLabel(m.source)
            return SleepFillResult(fill: .imported, minutes: mins, metric: m,
                                   sourceLine: "\(src) · not the strap", reason: nil,
                                   display: MetricText.display(m, sample: sample),
                                   stages: importedStageRows(label: label).isEmpty ? .none : .imported(label),
                                   also: sleepAlso(excluding: label))
        }
        // Priority 2b (Nov 6 2026): Apple Health read on the phone when the PC's row is not here (a full upload queue
        // used to block it). The PC row above wins when present: it is the same data.
        if let a = phoneAppleSleep, a.minutes.isFinite, a.minutes > 0 {
            let label = Self.alsoLabel(a.source)
            let m = Metric(name: totalKey, value: a.minutes, unit: "min", tier: .estimate, source: a.source,
                           window: "night", computedOn: .pc, at: a.end, note: nil, group: nil,
                           variant: ImportedHistory.appleHealth)
            let others = a.others.map { SleepAlso(label: Self.alsoLabel($0.source), minutes: $0.minutes) }
                .filter { $0.label != label }
            var r = SleepFillResult(fill: .imported, minutes: a.minutes, metric: m,
                                    sourceLine: "\(ImportedHistory.shortSource(a.source)) · on the phone · not the strap",
                                    reason: nil, display: MetricText.display(m, sample: sample), stages: .none, also: others)
            r.window = DateInterval(start: a.start, end: a.end)
            r.appleOnPhone = true
            return r
        }
        // Priority 3: blank, with the real reason (D7: the PC's partial-night reason is kept, not dropped).
        let note = (phone?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let why = importedSleepBlankReason()
        let reason = [note.isEmpty ? (why == nil ? Self.notProcessedNoFlag : nil) : note, why].compactMap { $0 }
            .joined(separator: " — ")
        return notProcessed(reason)
    }

    /// The strap-flag figure as a value: plain style (the strap's own flag counted, not an estimate), strap receipt.
    func strapFlagDisplay(minutes: Double, span: DateInterval?) -> DisplayValue {
        let r = Receipt(computedOn: .strap, tier: .strap, at: span?.end ?? now, method: "strap sleep flag (ALG-150)")
        return .value(text: MetricText.minutes(minutes), unit: nil, receipt: r, style: .plain, sample: sample)
    }

    /// A figure pinned blank while the night is incomplete: used by `metric(_:)` for every night total.
    static let nightAccountingNames: Set<String> = Set(
        PresenterSnapshot.sleepNames + [MetricKey.waso, .awakenings, .remLatency, .sleepEfficiency, .sleepPerformance,
                                        .sleepLatency].map(\.rawValue))

    /// The blank a night figure becomes while the strap is still sending the night (T10011): carries the reason, no value.
    func notProcessedMetric(_ name: String) -> Metric {
        Metric(name: name, value: nil, unit: "min", tier: .estimate, source: "night-gate", window: "night",
               computedOn: .phone, at: now, note: Self.notProcessedDownloading, group: nil, variant: nil)
    }
}

/// §0.B-1 (r8g): until the morning compute writes the ALG-030 wake row, the wake anchor is only the usual wake time, so
/// before that time the "wake day" is yesterday and after it the day is today but empty. When the anchor is assumed, the
/// last wake the strap's own sleep flag gave is used instead.
public enum StrapFlagWake {
    /// A real wake is taken only within this of the assumed wake time (or the same time a day later): a long awakening at
    /// 3 AM is not the morning.
    public static let plausibleSeconds: TimeInterval = 3 * 3600
    /// The asleep stretch before a stored-hypnogram wake must be at least this long (not a nap).
    public static let minAsleepSeconds: TimeInterval = 3 * 3600

    /// The wake to use instead of the assumed one, or nil to keep the assumed one.
    /// - Parameters:
    ///   - anchors: the context's anchors (only used when `wakeAssumed`).
    ///   - awakeSince: the live strap-flag state's "awake since" (held an hour after a real wake).
    ///   - hypnograms: the stored "strap" hypnogram series of the candidate wake days (today's and yesterday's).
    public static func pick(anchors: PhaseAnchors, awakeSince: Date?, hypnograms: [Series], now: Date) -> Date? {
        guard anchors.wakeAssumed else { return nil }
        var best: Date?
        for h in hypnograms {
            guard let w = lastWake(of: h), w <= now, now.timeIntervalSince(w) < 36 * 3600 else { continue }
            if best.map({ w > $0 }) ?? true { best = w }
        }
        if let a = awakeSince, a <= now, plausible(a, around: anchors.wake) {
            if best.map({ a > $0 }) ?? true { best = a }
        }
        return best
    }

    /// The strap member's hypnograms among stored series (name "hypnogram" with variant "strap", or "hypnogram|strap").
    public static func strapHypnograms(_ series: [Series]) -> [Series] {
        series.filter { ($0.name == "hypnogram" && $0.variant == "strap") || $0.name == "hypnogram|strap" }
    }

    /// End of the last asleep ("S") epoch of a strap hypnogram whose asleep run before it lasted `minAsleepSeconds`.
    public static func lastWake(of h: Series) -> Date? {
        guard let st = h.state, h.stepS > 0, let last = st.lastIndex(where: { $0?.uppercased() == "S" }) else { return nil }
        // Asleep stretch ending at `last`, allowing awake gaps under 30 min inside it.
        let gap = Int(30 * 60 / h.stepS)
        var first = last
        var i = last
        var misses = 0
        while i >= 0 {
            if st[i]?.uppercased() == "S" { first = i; misses = 0 } else { misses += 1; if misses > gap { break } }
            i -= 1
        }
        let asleep = Double(last + 1 - first) * h.stepS
        guard asleep >= minAsleepSeconds else { return nil }
        return h.start.addingTimeInterval(Double(last + 1) * h.stepS)
    }

    static func plausible(_ t: Date, around assumed: Date) -> Bool {
        let d = t.timeIntervalSince(assumed)
        for k in [-1.0, 0.0, 1.0] where abs(d - k * 24 * 3600) <= plausibleSeconds { return true }
        return false
    }
}
