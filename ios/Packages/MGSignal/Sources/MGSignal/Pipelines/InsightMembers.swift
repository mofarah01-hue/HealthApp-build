import Foundation
import MGDomain

// Wave 1 (2026-10-11) — the members that read stored days rather than one span's streams, wired into the pipelines:
//   night (after the morning stage and Mo's script members): ALG-023 30-night view, ALG-138 percentile of you,
//   ALG-102 behaviour effects on next-morning HRV;
//   day: ALG-132 key points (7 d, 30 d), ALG-134 CosinorAge, ALG-136 activity cost.
// Each family file holds the maths and its Python reference; this file only picks the inputs out of the day table and
// the history (calendar-dense, nil = no value that day, never imputed).

public enum InsightMembers {
    static func todayValue(_ table: [Metric], _ day: LocalDay, _ name: String, _ variant: String?,
                           _ window: String?) -> Double? {
        MetricHistory(metrics: [day: table]).value(name, variant: variant, window: window, on: day)
    }

    // MARK: night

    /// `d` = the wake day's ScriptDay with every night member merged in; `cvhr` = tonight's ALG-023 screen.
    public static func night(_ d: ScriptDay, at: Date, tempRawTonight: Double?, cvhr: Computed<ALG023.Screen>,
                             core: any SignalCore = Signal.core) -> [Metric] {
        let h = d.history
        let day = d.day
        func tv(_ n: String, _ v: String?, _ w: String?) -> Double? { todayValue(d.today, day, n, v, w) }
        var out: [Metric] = []

        // ALG-023 30-night view: tonight first, then the stored nights (AF-flagged nights left out)
        var nights: [ALG023.Night] = []
        let afTonight = tv("af_screen", "ALG-013", "night").map { Int($0.rounded()) == 1 } ?? false
        nights.append(ALG023.Night(cvhrPerHour: cvhr.value?.cvhrPerHour, hours: cvhr.value?.hours, irregular: afTonight))
        for k in 1..<ALG023.windowNights {
            let dd = day.adding(days: -k)
            let af = h.value("af_screen", variant: "ALG-013", window: "night", on: dd).map { Int($0.rounded()) == 1 } ?? false
            nights.append(ALG023.Night(cvhrPerHour: h.value("breathing_disturbance", variant: "ALG-023:cvhr", window: "night",
                                                            on: dd),
                                       hours: h.series0(ALG023.hoursSeries, on: dd), irregular: af))
        }
        out.append(ALG023.distributionMetric(ALG023.distribution(nights: nights), at: at))

        // ALG-138: today in your own last 90 days
        for m in ALG138.metricsRead {
            let r = ALG138.rank(value: tv(m.name, m.variant, m.window),
                                history: h.dense(m.name, variant: m.variant, window: m.window, before: day,
                                                 days: PipelineConstants.historyDays),
                                better: m.better)
            out.append(ALG138.metric(name: m.name, label: m.label, r, at: at))
        }

        // ALG-102 v2 (D-RECOV-WALK-2): what each logged behaviour does to your next-morning ln RMSSD (regression, AR(1), 95 % CI,
        // gated at 10 exposed / 20 unexposed nights). Night t's ln RMSSD against the exposure of day t - 1; a day whose events
        // are not loaded is unknown, not unexposed.
        var lnByDay: [Int: Double] = [:]
        let lnDense = h.dense("hrv_ln_rmssd", variant: nil, window: "night", before: day, days: PipelineConstants.historyDays)
        for (i, v) in lnDense.enumerated() {
            if let v { lnByDay[DayCalendar.dayNumber(day.adding(days: -(PipelineConstants.historyDays - i)))] = v }
        }
        if let l = tv("hrv_ln_rmssd", nil, "night") ?? d.nightValue(true, d.sleepWindow(), core: core).value {
            lnByDay[DayCalendar.dayNumber(day)] = l
        }
        var known = Set<Int>()
        var exposure: [ALG102.Behaviour: Set<Int>] = [:]
        for k in 1...PipelineConstants.historyDays {
            let dd = day.adding(days: -k)
            guard let evs = h.events[dd] else { continue }
            let num = DayCalendar.dayNumber(dd)
            known.insert(num)
            let cafeCut = Double(d.clock.dayStart(dd)) + 14 * 3600
            for e in evs where !e.removed {
                switch e.payload {
                case .substance(let f):
                    if f.kind == .alcohol { exposure[.alcohol, default: []].insert(num) }
                    if f.kind == .caffeine && e.at.timeIntervalSince1970 >= cafeCut { exposure[.lateCaffeine, default: []].insert(num) }
                    if f.kind == .vape || f.kind == .vapeTick { exposure[.vape, default: []].insert(num) }
                case .workout:
                    exposure[.workout, default: []].insert(num)
                default:
                    break
                }
            }
        }
        for b in ALG102.Behaviour.allCases {
            let r = ALG102.behaviourEffect(rows: ALG102.rows(lnByDay: lnByDay, exposed: exposure[b] ?? [], known: known))
            out.append(ALG102.metric(b, r, at: at))
        }
        return out
    }

    // MARK: day

    /// ALG-132, ALG-134 and ALG-136 for the local day. `table` = the day's stored metrics with today's merged in.
    static func day(day: LocalDay, at: Date, table: [Metric], history h: MetricHistory, dayEvents: [EventRecord],
                    profile: Profile?, age: Double?, rhr7: Double?, paIndex: Double?,
                    cosinor: Computed<RawMotion.CosinorFit>? = nil) -> [Metric] {
        func tv(_ n: String, _ v: String?, _ w: String?) -> Double? { todayValue(table, day, n, v, w) }
        var out: [Metric] = []

        // ALG-132: night metrics end today (last night), day metrics end yesterday (today's strain is still growing)
        for (period, spec) in [(7, ALG132.weekSpec), (30, ALG132.monthSpec)] {
            var series: [String: [Double?]] = [:]
            for m in ALG132.metricsRead {
                if m.window == "night" {
                    series[m.name] = h.dense(m.name, variant: m.variant, window: m.window, before: day,
                                             days: period + ALG132.baseDays - 1) + [tv(m.name, m.variant, m.window)]
                } else {
                    series[m.name] = h.dense(m.name, variant: m.variant, window: m.window, before: day,
                                             days: period + ALG132.baseDays)
                }
            }
            out.append(ALG132.metric(spec, ALG132.keyPoints(series: series, period: period), at: at))
        }

        // ALG-134 v2: the Body Age / vitality readout is removed (Mo, D-LOAD-WALK-1 item 9); CosinorAge is the only member.
        // CosinorAge (wave W8, 2026-10-11): from the cosinor of minute ENMO (RawMotion), when the raw motion covers enough
        // complete days; before W8 this was always the blank `cosinorBlankReason`.
        switch cosinor {
        case .some(.success(let fit)):
            if age != nil, profile?.sex == nil {
                // P9745: sex nil used to fall to an average-of-sexes coefficient set without a word.
                out.append(ALG134.cosinorSpec.blank("needs your sex (Preferences › Profile, or from Apple Health via your PC): "
                                                    + "CosinorAge uses sex-specific coefficients", at: at))
            } else if let age {
                out.append(ALG134.cosinorSpec.metric(
                    ALG134.cosinorAge(mesor: fit.mesor, amplitude: fit.amplitude, acrophase: fit.acrophase, age: age,
                                      sex: profile?.sex), at: at, note: ALG134.cosinorNote(fit)))
            } else {
                out.append(ALG134.cosinorSpec.blank("needs your age (Preferences › Profile)", at: at))
            }
        case .some(.failure(let m)):
            out.append(ALG134.cosinorSpec.blank(m.reason, at: at))
        case .none:
            out.append(ALG134.cosinorSpec.blank(ALG134.cosinorBlankReason, at: at))
        }

        // ALG-136 v2: activity cost over the stored days = the ALG-102 regression per activity on the nightly ln RMSSD
        var sportDays: [String: [Int]] = [:]
        var lnByDay: [Int: Double] = [:]
        for k in 0...ALG136.historyDays {
            let dd = day.adding(days: -k)
            let num = DayCalendar.dayNumber(dd)
            let evs = k == 0 ? dayEvents : h.eventsOn(dd)
            for e in evs where !e.removed {
                guard case .workout(let f) = e.payload else { continue }
                let label = (f.activityTypeUser ?? f.activityTypeAuto ?? "workout").trimmingCharacters(in: .whitespaces)
                sportDays[label.isEmpty ? "workout" : label, default: []].append(num)
            }
            let r = k == 0 ? tv("hrv_ln_rmssd", nil, "night") : h.value("hrv_ln_rmssd", variant: nil, window: "night", on: dd)
            if let r { lnByDay[num] = r }
        }
        out.append(ALG136.metric(ALG136.cost(sportDays: sportDays, lnByDay: lnByDay), at: at))
        return out
    }

    /// Waking [start, end) spans between `from` and `to` with the excluded spans (naps, workouts) cut out.
    static func wakingSpans(from: Double, to: Double, excluding ex: [(Double, Double)]) -> [(Double, Double)] {
        guard to > from else { return [] }
        var spans: [(Double, Double)] = [(from, to)]
        for (a, b) in ex.sorted(by: { $0.0 < $1.0 }) where b > a {
            var next: [(Double, Double)] = []
            for (s, e) in spans {
                if b <= s || a >= e {
                    next.append((s, e))
                    continue
                }
                if a > s { next.append((s, a)) }
                if b < e { next.append((b, e)) }
            }
            spans = next
        }
        return spans
    }

    /// "9:24 PM" local for a unix second (12-hour, ClockText; W10).
    static func hm(_ t: Int64, clock: PipelineClock) -> String {
        let off = Int64(clock.offsetSeconds(at: Double(t)))
        let s = ((t + off) % 86_400 + 86_400) % 86_400
        return ClockText.hm(hour: Int(s / 3600), minute: Int((s % 3600) / 60))
    }
}
