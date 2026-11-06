import Foundation

/// ALG-063 v1 — nicotine response: mean heart rate and RMSSD in a window before vs after each logged vape session.
/// Basis: Moheimani et al. 2017 (J Am Heart Assoc 6:e006579) — a nicotine e-cigarette moved cardiac sympathovagal
/// balance toward sympathetic (HF down, LF/HF up); the nicotine-free device and sham did not. This reports YOUR
/// before/after numbers; it does not say why they moved (caffeine, standing up and talking all do too).
///
/// Windows and rules are OURS (PLAN §4.3: "the hour after a logged vape vs before it"), flagged for Mo:
///   * session  = hits closer together than 10 min; start = first hit, end = last hit;
///   * before   = [start − 30 min, start), and it must hold no hit (a baseline still carrying the last session's
///                nicotine is not a baseline) → otherwise the session is listed in `excluded`;
///   * after    = (end, min(end + 60 min, next hit)]  (sessions are > 10 min apart, so this is always ≥ 10 min);
///   * HR needs ≥ 30 on-skin samples (bpm > 0) per window; RMSSD needs ≥ 60 R-R intervals per window and goes through
///     `ALG010.time` (the shared Task Force RMSSD). R-R must already be sorted by (ts, ord) and artefact-corrected
///     (ALG-004); beat times come from the shared `BeatClock`.
/// A missing half blanks only that half (with its reason); the session's other half still answers.
/// Python reference: app/pclab/mglab/ref/behaviour.py `nicotine_response`; goldens
/// app/shared/golden/behaviour/ALG-063.json.
public enum ALG063 {
    public static let method = "ALG-063@1 before-after-hr-rmssd"
    public static let citation = "Moheimani RS et al. J Am Heart Assoc 2017;6:e006579"
    public static let sessionGapSeconds = 600.0
    public static let preSeconds = 1800.0
    public static let postSeconds = 3600.0
    public static let minHRSamples = 30
    public static let minBeats = 60

    /// A vape session in unix seconds: start = first hit, end = last hit.
    public struct Session: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var hits: Int

        public init(start: Double, end: Double, hits: Int) {
            self.start = start
            self.end = end
            self.hits = hits
        }
    }

    /// One session's before/after. `d…` = after − before. A nil value has its reason in `reasons`.
    public struct Row: Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var hits: Int
        public var hrPre: Double?
        public var hrPost: Double?
        public var dHr: Double?
        public var rmssdPre: Double?
        public var rmssdPost: Double?
        public var dRmssd: Double?
        /// Keys `hr_pre`, `hr_post`, `rmssd_pre`, `rmssd_post`.
        public var reasons: [String: String]

        public init(start: Date, end: Date, hits: Int, hrPre: Double?, hrPost: Double?, dHr: Double?, rmssdPre: Double?,
                    rmssdPost: Double?, dRmssd: Double?, reasons: [String: String]) {
            self.start = start
            self.end = end
            self.hits = hits
            self.hrPre = hrPre
            self.hrPost = hrPost
            self.dHr = dHr
            self.rmssdPre = rmssdPre
            self.rmssdPost = rmssdPost
            self.dRmssd = dRmssd
            self.reasons = reasons
        }
    }

    public struct Exclusion: Sendable, Equatable {
        /// Index into the time-ordered sessions.
        public var session: Int
        public var reason: String

        public init(session: Int, reason: String) {
            self.session = session
            self.reason = reason
        }
    }

    public struct Summary: Sendable, Equatable {
        public var sessions: Int
        public var usedHR: Int
        public var usedRMSSD: Int
        public var meanDHr: Double?
        public var medianDHr: Double?
        public var meanDRmssd: Double?
        public var medianDRmssd: Double?
        /// Sessions where HR went up / RMSSD went down.
        public var nHrUp: Int
        public var nRmssdDown: Int

        public init(sessions: Int, usedHR: Int, usedRMSSD: Int, meanDHr: Double?, medianDHr: Double?, meanDRmssd: Double?,
                    medianDRmssd: Double?, nHrUp: Int, nRmssdDown: Int) {
            self.sessions = sessions
            self.usedHR = usedHR
            self.usedRMSSD = usedRMSSD
            self.meanDHr = meanDHr
            self.medianDHr = medianDHr
            self.meanDRmssd = meanDRmssd
            self.medianDRmssd = medianDRmssd
            self.nHrUp = nHrUp
            self.nRmssdDown = nRmssdDown
        }
    }

    public struct Response: Sendable, Equatable {
        public var rows: [Row]
        public var excluded: [Exclusion]
        public var summary: Summary

        public init(rows: [Row], excluded: [Exclusion], summary: Summary) {
            self.rows = rows
            self.excluded = excluded
            self.summary = summary
        }
    }

    /// Group hits (any order, unix seconds) into sessions: a hit within `gap` of the previous one joins its session.
    public static func sessions(hitTimes: [Double], gap: Double = ALG063.sessionGapSeconds) -> [Session] {
        var out: [Session] = []
        for t in hitTimes.sorted() {
            if let last = out.last, t - last.end <= gap {
                out[out.count - 1].end = t
                out[out.count - 1].hits += 1
            } else {
                out.append(Session(start: t, end: t, hits: 1))
            }
        }
        return out
    }

    private static func inWindow(_ t: Double, _ lo: Double, _ hi: Double, _ loIncl: Bool, _ hiIncl: Bool) -> Bool {
        (loIncl ? t >= lo : t > lo) && (hiIncl ? t <= hi : t < hi)
    }

    private static func windowHR(ts: [Double], bpm: [Double], lo: Double, hi: Double, loIncl: Bool,
                                 hiIncl: Bool) -> Computed<Double> {
        var vals: [Double] = []
        for i in 0..<min(ts.count, bpm.count) where inWindow(ts[i], lo, hi, loIncl, hiIncl) && bpm[i] > 0 {
            vals.append(bpm[i])
        }
        if vals.count < minHRSamples {
            return .missing("only \(vals.count) heart-rate samples (needs \(minHRSamples))")
        }
        return .success(SignalMath.mean(vals))
    }

    private static func windowRMSSD(beatTimes: [Double], rr: [Double], lo: Double, hi: Double, loIncl: Bool,
                                    hiIncl: Bool) -> Computed<Double> {
        var vals: [Double] = []
        for i in 0..<min(beatTimes.count, rr.count) where inWindow(beatTimes[i], lo, hi, loIncl, hiIncl) {
            vals.append(rr[i])
        }
        if vals.count < minBeats {
            return .missing("only \(vals.count) R-R intervals (needs \(minBeats))")
        }
        switch ALG010.time(rrMs: vals) {
        case .success(let t): return .success(t.rmssd)
        case .failure(let m): return .failure(m)
        }
    }

    /// ALG-063 v1 — `hits` are the logged hits (a session is derived from gaps); `hrTs`/`hrBpm` the 1 Hz heart rate
    /// (unix s, bpm; 0 = off-skin); `rrTs`/`rrMs` the corrected R-R sorted by (ts, ord). Missing without hits.
    public static func response(hits: [Date], hrTs: [Int64], hrBpm: [Double], rrTs: [Int64],
                                rrMs: [Double]) -> Computed<Response> {
        guard !hits.isEmpty else { return .missing("no vape hits logged") }
        let sess = sessions(hitTimes: hits.map { BehaviourClock.seconds($0) })
        let hrT = hrTs.map { Double($0) }
        let bt: [Double] = rrTs.isEmpty ? [] : BeatClock.times(ts: rrTs, rrMs: rrMs)
        var rows: [Row] = []
        var excluded: [Exclusion] = []
        for (i, s) in sess.enumerated() {
            let prevEnd: Double? = i > 0 ? sess[i - 1].end : nil
            let nextStart: Double? = i + 1 < sess.count ? sess[i + 1].start : nil
            let preLo = s.start - preSeconds
            if let pe = prevEnd, pe >= preLo {
                excluded.append(Exclusion(session: i, reason: "an earlier hit is inside the 30 min before this session"))
                continue
            }
            var postHi = s.end + postSeconds
            if let ns = nextStart { postHi = min(postHi, ns) }
            // a post window cut short by the next session ends just before it (that hit is not part of this window)
            let postHiIncl = !(nextStart != nil && postHi == nextStart!)
            let hrPre = windowHR(ts: hrT, bpm: hrBpm, lo: preLo, hi: s.start, loIncl: true, hiIncl: false)
            let hrPost = windowHR(ts: hrT, bpm: hrBpm, lo: s.end, hi: postHi, loIncl: false, hiIncl: postHiIncl)
            let rmPre = windowRMSSD(beatTimes: bt, rr: rrMs, lo: preLo, hi: s.start, loIncl: true, hiIncl: false)
            let rmPost = windowRMSSD(beatTimes: bt, rr: rrMs, lo: s.end, hi: postHi, loIncl: false, hiIncl: postHiIncl)
            var reasons: [String: String] = [:]
            if let r = hrPre.missingReason { reasons["hr_pre"] = r }
            if let r = hrPost.missingReason { reasons["hr_post"] = r }
            if let r = rmPre.missingReason { reasons["rmssd_pre"] = r }
            if let r = rmPost.missingReason { reasons["rmssd_post"] = r }
            var dHr: Double?
            if let a = hrPre.value, let b = hrPost.value { dHr = b - a }
            var dRm: Double?
            if let a = rmPre.value, let b = rmPost.value { dRm = b - a }
            rows.append(Row(start: BehaviourClock.date(s.start), end: BehaviourClock.date(s.end), hits: s.hits,
                            hrPre: hrPre.value, hrPost: hrPost.value, dHr: dHr, rmssdPre: rmPre.value,
                            rmssdPost: rmPost.value, dRmssd: dRm, reasons: reasons))
        }
        let dHrs = rows.compactMap { $0.dHr }
        let dRms = rows.compactMap { $0.dRmssd }
        let summary = Summary(
            sessions: sess.count, usedHR: dHrs.count, usedRMSSD: dRms.count,
            meanDHr: dHrs.isEmpty ? nil : SignalMath.mean(dHrs), medianDHr: dHrs.isEmpty ? nil : SignalMath.median(dHrs),
            meanDRmssd: dRms.isEmpty ? nil : SignalMath.mean(dRms),
            medianDRmssd: dRms.isEmpty ? nil : SignalMath.median(dRms),
            nHrUp: dHrs.filter { $0 > 0 }.count, nRmssdDown: dRms.filter { $0 < 0 }.count)
        return .success(Response(rows: rows, excluded: excluded, summary: summary))
    }
}
