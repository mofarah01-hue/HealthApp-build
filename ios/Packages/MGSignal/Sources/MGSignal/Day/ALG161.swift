import Foundation
import MGDomain

/// ALG-161 v1 — warning signs: "worth noting" against YOUR OWN normal, never a diagnosis. Python reference:
/// pclab/mglab/ref/readiness.py `warning_signs`; goldens shared/golden/readiness/ALG-161.json. Every threshold is stated
/// next to its source; the sentences are calm and say what the number is and is not.
///
/// - rhr: nightly resting HR, one-sided CUSUM (ALG-036 illness CUSUM) — illness onset shows as a raised resting HR before
///   symptoms (Mishra et al., Nat Biomed Eng 2020;4:1208; population view Radin et al., Lancet Digit Health 2020).
/// - temp: the night's RAW skin-temperature median (strap counts, not °C), two-sided robust z — a fever, or a cold
///   night, are both a change from your normal (Smarr et al., Sci Rep 2020; feasibility study, accuracy not established).
/// - resp: our breathing-rate estimate, only listed beside rhr or temp (WHOOP-sponsored Miller 2020: sensitivity 36 %).
/// - alcohol: first 3 h of sleep, HR up AND lnRMSSD down by ≥ 2 robust SD (Pietila et al., JMIR Ment Health 2018;5:e23:
///   within-person HR +1.4 to +8.7 bpm, RMSSD −2 to −13 ms by dose; our 2 SD rule only catches moderate and high).
/// - rhythm: the ALG-013 irregular-pulse screen; a 60 s ECG confirms (2) or clears it.
/// - cvhr: cyclic variation of heart rate ≥ 15 per hour over ≥ 4 h (Hayano et al.: PLoS ONE 2020, Fcv 19.6 vs 6.4 per hour
///   for AHI ≥ 15 vs < 15; night to night it misses many nights, Ann Noninvasive Electrocardiol 2022) — a screen.
public enum ALG161 {
    public static let id = "ALG-161"
    public static let citation = "Mishra 2020; Radin 2020; Smarr 2020; Miller 2020; Pietila 2018; Hayano 2011/2020 (thresholds ours)"
    public static let codes = ["rhr", "temp", "resp", "alcohol", "rhythm", "cvhr"]
    public static let tempNote = 2.0
    public static let tempStrong = 3.0
    public static let respZ = 2.0
    public static let alcoholHRZ = 2.0
    public static let alcoholRMSSDZ = -2.0
    public static let cvhrPerHour = 15.0
    public static let cvhrMinHours = 4.0
    /// Nights of history the caller hands over (the robust z reads the last 28).
    public static let historyNights = 29

    public struct Input: Sendable {
        public var days: [Int]
        public var rhr: [Double?]
        public var tempRaw: [Double?]
        public var resp: [Double?]
        public var first3Hr: [Double?]
        public var first3LnRmssd: [Double?]
        public var afFlag: Bool?
        public var ecgIrregular: Bool?
        public var cvhrPerHourValue: Double?
        public var cvhrHours: Double?

        public init(days: [Int] = [], rhr: [Double?] = [], tempRaw: [Double?] = [], resp: [Double?] = [],
                    first3Hr: [Double?] = [], first3LnRmssd: [Double?] = [], afFlag: Bool? = nil,
                    ecgIrregular: Bool? = nil, cvhrPerHour: Double? = nil, cvhrHours: Double? = nil) {
            self.days = days
            self.rhr = rhr
            self.tempRaw = tempRaw
            self.resp = resp
            self.first3Hr = first3Hr
            self.first3LnRmssd = first3LnRmssd
            self.afFlag = afFlag
            self.ecgIrregular = ecgIrregular
            self.cvhrPerHourValue = cvhrPerHour
            self.cvhrHours = cvhrHours
        }
    }

    public struct Sign: Sendable, Equatable {
        public var code: String
        public var severity: Int
        public var z: Double?
        public var direction: String?

        public init(code: String, severity: Int, z: Double? = nil, direction: String? = nil) {
            self.code = code
            self.severity = severity
            self.z = z
            self.direction = direction
        }
    }

    /// What a night leaves for the morning stage besides its metrics: the first-3-h values and the CVHR hours; r9s: the
    /// night's AF flagged-window share, rest-to-walk rise and perfusion index (the relative trends, ALG-170).
    public struct NightExtras: Sendable, Equatable {
        public var first3Hr: Double?
        public var first3LnRmssd: Double?
        public var cvhrHours: Double?
        public var afShare: Double?
        public var orthoRise: Double?
        public var perfusion: Double?

        public init(first3Hr: Double? = nil, first3LnRmssd: Double? = nil, cvhrHours: Double? = nil, afShare: Double? = nil,
                    orthoRise: Double? = nil, perfusion: Double? = nil) {
            self.first3Hr = first3Hr
            self.first3LnRmssd = first3LnRmssd
            self.cvhrHours = cvhrHours
            self.afShare = afShare
            self.orthoRise = orthoRise
            self.perfusion = perfusion
        }

        /// From the night's carry series (a night's own output, or the stored series of the day).
        public init(series: [Series]) {
            func first(_ name: String) -> Double? {
                guard let s = series.first(where: { $0.name == name }), let v = s.values.first, let x = v, x.isFinite
                else { return nil }
                return x
            }
            self.init(first3Hr: first(ALG161.first3hHrSeries), first3LnRmssd: first(ALG161.first3hLnRmssdSeries),
                      cvhrHours: first(ALG023.hoursSeries), afShare: first(ALG170.afShareSeries),
                      orthoRise: first(ALG171.seriesName), perfusion: first(ALG172.seriesName))
        }
    }

    static func zOf(_ history: ArraySlice<Double?>, _ x: Double?) -> Double? {
        if case .success(let r) = ALG075.robustZ(history: Array(history), x: x) { return r.z }
        return nil
    }

    public static func evaluate(_ inp: Input) -> [Sign] {
        var out: [Sign] = []
        if !inp.days.isEmpty, inp.days.count == inp.rhr.count,
           let last = ALG036.illnessCUSUM(days: inp.days, rhr: inp.rhr).last, last.state != .green {
            out.append(Sign(code: "rhr", severity: last.state == .red ? 2 : 1, z: last.z))
        }
        if inp.tempRaw.count >= 2, let z = zOf(inp.tempRaw.dropLast(), inp.tempRaw.last ?? nil), abs(z) >= tempNote {
            out.append(Sign(code: "temp", severity: abs(z) >= tempStrong ? 2 : 1, z: z, direction: z > 0 ? "high" : "low"))
        }
        if inp.resp.count >= 2, !out.isEmpty, let z = zOf(inp.resp.dropLast(), inp.resp.last ?? nil), z >= respZ {
            out.append(Sign(code: "resp", severity: 1, z: z))
        }
        if inp.first3Hr.count >= 2, inp.first3LnRmssd.count >= 2,
           let zh = zOf(inp.first3Hr.dropLast(), inp.first3Hr.last ?? nil),
           let zr = zOf(inp.first3LnRmssd.dropLast(), inp.first3LnRmssd.last ?? nil),
           zh >= alcoholHRZ, zr <= alcoholRMSSDZ {
            out.append(Sign(code: "alcohol", severity: 1, z: zh))
        }
        if inp.afFlag == true {
            if let ecg = inp.ecgIrregular {
                if ecg { out.append(Sign(code: "rhythm", severity: 2)) }
            } else {
                out.append(Sign(code: "rhythm", severity: 1))
            }
        }
        if let cv = ALG160.ok(inp.cvhrPerHourValue), let h = ALG160.ok(inp.cvhrHours), h >= cvhrMinHours, cv >= cvhrPerHour {
            out.append(Sign(code: "cvhr", severity: 1, z: cv))
        }
        return out
    }

    /// The calm sentence for a sign (what it is, what it is not).
    public static func text(_ s: Sign) -> String {
        switch s.code {
        case "rhr":
            return s.severity >= 2
                ? "Your resting heart rate has been above your normal for several nights in a row. Worth noting how you feel."
                : "Your resting heart rate was above your normal last night. Worth noting how you feel."
        case "temp":
            return "Your skin temperature reading was \(s.direction == "low" ? "lower" : "higher") than your usual "
                + "(raw strap counts, decoded, untested). A change from your own normal, not a fever reading."
        case "resp":
            return "Your breathing rate (our estimate) was also above your normal. On its own this is a weak signal."
        case "alcohol":
            return "The first hours of sleep looked like a night after alcohol or a late heavy meal: heart rate up, HRV down. "
                + "A pattern, not a measurement."
        case "rhythm":
            return s.severity >= 2
                ? "Your pulse looked irregular overnight and a 60-second ECG check also looked irregular. Worth mentioning to a doctor."
                : "Your pulse looked irregular for part of the night. This is a screen, not a diagnosis; a 60-second ECG check can look closer."
        case "cvhr":
            return "Your heart rate rose and fell in repeated cycles through the night. This is a breathing-pattern screen, "
                + "not a diagnosis, and it misses many nights."
        default:
            return s.code
        }
    }

    // MARK: Night extras: the first 3 h of sleep (alcohol pattern) and the carry series the later nights read

    public static let first3hSeconds = 10_800.0
    /// 30 min of 1 Hz heart rate and 600 beats must sit in the first 3 h, or the night has no value for this check.
    public static let first3hMinHR = 1_800
    public static let first3hMinBeats = 600
    public static let first3hHrSeries = "first3h_hr"
    public static let first3hLnRmssdSeries = "first3h_ln_rmssd"

    /// Mean HR and lnRMSSD (on ALG-004-corrected R-R) over the first 3 h after `start`; nil where the window is too thin.
    /// Python mirror: readiness.first3h.
    public static func first3h(hr: [HRPoint], rr: [RRPoint], start: Double) -> (hr: Double?, lnRmssd: Double?) {
        let end = start + first3hSeconds
        let h = PipelineStreams.hr(hr, start, end)
        let meanHR: Double? = h.count >= first3hMinHR ? SignalMath.mean(h.map(\.bpm)) : nil
        let pts = BeatClock.sorted(PipelineStreams.rr(rr, start, end))
        var ln: Double?
        if pts.count >= first3hMinBeats {
            let art = ALG004.correct(rrMs: pts.map(\.rrMs), times: BeatClock.times(points: pts))
            if case .success(let t) = ALG010.time(rrMs: art.rrMs) { ln = t.lnRmssd }
        }
        return (meanHR, ln)
    }

    /// The two one-value carry series of a night (written next to `skin_temp_night_raw`).
    static func first3hSeries(_ x: (hr: Double?, lnRmssd: Double?), start: Int64, span: Int64) -> [Series] {
        var out: [Series] = []
        if let v = x.hr {
            out.append(PipelineOutput.carry(first3hHrSeries, variant: "ALG-161", start: start, stepS: span, value: v,
                                            unit: "bpm", tier: .research))
        }
        if let v = x.lnRmssd {
            out.append(PipelineOutput.carry(first3hLnRmssdSeries, variant: "ALG-161", start: start, stepS: span, value: v,
                                            unit: "ln_ms", tier: .research))
        }
        return out
    }

    public static func spec(_ code: String) -> MetricSpec {
        MetricSpec(key: .warningSign, unit: "level_0_2", group: "G-WARN", variant: code,
                   method: "ALG-161@1 own-normal-deviation", tier: .estimate, source: "night", window: "night",
                   producer: .ours, citation: citation, paramsVersion: "rhr-cusum temp|z|>=2 alcohol2sd cvhr15/h")
    }

    /// One metric per sign code: level 0 (nothing), 1 (worth noting), 2 (stronger) with the sentence as the note. A code
    /// whose input is not available is a blank with that reason, so a stale earlier row is overwritten.
    public static func metrics(_ inp: Input, at: Date) -> [Metric] {
        let signs = evaluate(inp)
        var out: [Metric] = []
        for code in codes {
            let s = spec(code)
            if let f = signs.first(where: { $0.code == code }) {
                out.append(s.metric(.success(Double(f.severity)), at: at, note: text(f)))
            } else if available(code, inp) {
                out.append(s.metric(.success(0), at: at))
            } else {
                out.append(s.blank("not enough of your own history or data for this check yet", at: at))
            }
        }
        return out
    }

    static func available(_ code: String, _ i: Input) -> Bool {
        func has(_ a: [Double?]) -> Bool {
            a.compactMap { $0 }.count >= ALG075.robustMinDays + 1 && a.last.map { $0 != nil } == true
        }
        switch code {
        case "rhr": return has(i.rhr)
        case "temp": return has(i.tempRaw)
        case "resp": return has(i.resp)
        case "alcohol": return has(i.first3Hr) && has(i.first3LnRmssd)
        case "rhythm": return i.afFlag != nil
        case "cvhr": return ALG160.ok(i.cvhrPerHourValue) != nil && ALG160.ok(i.cvhrHours) != nil
        default: return false
        }
    }
}
