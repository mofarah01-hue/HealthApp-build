import Foundation
import MGDomain

/// ALG-010 spot60 — the 60 s morning check (r9l, D-HRV-WALK-1, 2026-10-17). The 60 s morning ECG becomes a standard morning
/// check: its R-R intervals go through ALG-004 and ALG-010 and the result is the ENHANCED input of the readiness score
/// (ALG-160: variant `ALG160.morningVariant` = "ALG-010:spot60", key hrv_ln_rmssd, window "morning", one per day). With no
/// ECG that morning the same reading from the PPG pulse intervals (ALG-144 accepted intervals on R20) is written under
/// "ALG-010:spot60ppg"; the two are different series and are never mixed (`chooseSeries`).
///
/// Python reference: app/pclab/mglab/ref/morning.py; goldens app/shared/golden/hrv/ALG-010-spot60.json.
/// Sources: a 1-minute lnRMSSD taken after a short settling period tracks the 5-minute one — Esco MR, Flatt AA, J Sports
/// Sci Med 2014;13:535-541; Flatt AA, Esco MR, J Strength Cond Res 2016;30:378-385 (athlete studies on chest-strap or
/// phone-camera data, not on this strap: the reading stays 'decoded, untested' until compared with a chest-strap ECG).
/// RMSSD/SDNN: Task Force of the ESC and NASPE, Circulation 1996;93:1043-1065. Artefacts: Lipponen & Tarvainen, J Med Eng
/// Technol 2019;43:173-181 (ALG-004). The acceptance rule is ours (the same as one 5-min window in ALG-004 B).
public enum MorningCheck {
    public static let ecgVariant = "ALG-010:spot60"
    public static let ppgVariant = "ALG-010:spot60ppg"
    public static let window = "morning"
    public static let citation = "Esco & Flatt, J Sports Sci Med 2014;13:535-541; Flatt & Esco, J Strength Cond Res 2016;30:378-385 "
        + "(1-minute lnRMSSD as a morning reading); Task Force 1996 (RMSSD); Lipponen & Tarvainen 2019 (artefacts)"

    public static let seconds = 60.0
    /// A reading counts as the morning check when it starts before this local hour (ours; a later ECG is a spot reading, not
    /// today's morning value, and must not replace it).
    public static let latestMorningHour = 12
    public static let minBeats = 30
    public static let minCoverage = 0.8
    public static let maxArtefactFraction = 0.05
    /// An ECG reading needs this many seconds of signal after the settling zeros (the recorder takes 60 s).
    public static let minEcgSeconds = 50.0
    public static let rrRangeMs = 300.0...2000.0
    public static let ppgWindowStepSeconds = 15.0
    /// Successive pulse intervals must follow each other within ±30 % of the interval's own length (ours).
    public static let ppgContiguity = 0.3

    public struct Reading: Sendable, Equatable {
        public var rmssd: Double
        public var lnRmssd: Double
        public var sdnn: Double
        public var meanRR: Double
        public var beats: Int
        public var artefactFraction: Double
        public var coverage: Double
    }

    /// RMSSD, lnRMSSD, SDNN of one 60 s reading after ALG-004 correction, or missing with the reason.
    public static func reading(rrMs: [Double], seconds s: Double = seconds) -> Computed<Reading> {
        let art = ALG004.correct(rrMs: rrMs)
        let r = art.rrMs
        guard r.count >= minBeats else {
            return .missing("needs \(minBeats) beats in the 60 s reading (have \(r.count))")
        }
        let coverage = min(1.0, r.reduce(0, +) / 1000.0 / s)
        guard coverage >= minCoverage else {
            return .missing(String(format: "the beats cover %.0f %% of the minute (needs %.0f %%)", coverage * 100,
                                   minCoverage * 100))
        }
        let bad = art.flags.filter { $0 != ArtefactFlag.ok.rawValue }.count
        let afrac = Double(bad) / Double(art.flags.count)
        guard afrac <= maxArtefactFraction else {
            return .missing(String(format: "%.1f %% of the beats needed correction (limit %.0f %%)", afrac * 100,
                                   maxArtefactFraction * 100))
        }
        switch ALG010.time(rrMs: r) {
        case .failure(let m): return .failure(m)
        case .success(let t):
            return .success(Reading(rmssd: t.rmssd, lnRmssd: t.lnRmssd, sdnn: t.sdnn, meanRR: t.meanRR, beats: r.count,
                                    artefactFraction: afrac, coverage: coverage))
        }
    }

    /// True when `start` falls before 12:00 in `calendar`'s time zone.
    public static func isMorning(_ start: Date, calendar: Calendar) -> Bool {
        calendar.component(.hour, from: start) < latestMorningHour
    }

    // MARK: sub-sample R-peaks (ECG, about 100 Hz)

    /// Offset (-0.5...0.5 samples) of a peak at the middle of three samples: 0.5 (y-1 - y+1) / (y-1 - 2 y0 + y+1);
    /// 0 when the middle sample is not a strict maximum of the parabola.
    public static func parabolicOffset(_ ym1: Double, _ y0: Double, _ yp1: Double) -> Double {
        let den = ym1 - 2.0 * y0 + yp1
        guard den < 0 else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (ym1 - yp1) / den))
    }

    /// Peak positions in (fractional) samples: each index plus the parabolic offset on `y` (peaks at the ends stay).
    public static func refinePeaks(_ y: [Double], _ peaks: [Int]) -> [Double] {
        peaks.map { p in
            p >= 1 && p < y.count - 1 ? Double(p) + parabolicOffset(y[p - 1], y[p], y[p + 1]) : Double(p)
        }
    }

    /// R-R intervals (ms) between successive peaks; 300-2000 ms only (as ALG-014).
    public static func rrFromPeaks(_ peaks: [Double], fs: Double) -> [Double] {
        zip(peaks.dropFirst(), peaks).map { ($0 - $1) / fs * 1000.0 }.filter { rrRangeMs.contains($0) }
    }

    /// The morning reading from an ECG recording (samples in arrival order and their packets, as ALG-014).
    public static func ecg(samples: [Int16], packets: [EcgTracePacket]) -> Computed<Reading> {
        let res: ALG014.Result
        switch ALG014.heartRate(samples: samples, packets: packets) {
        case .failure(let m): return .failure(m)
        case .success(let r): res = r
        }
        guard res.seconds >= minEcgSeconds else {
            return .missing(String(format: "%.0f s of ECG after settling; %.0f s needed for the morning check", res.seconds,
                                   minEcgSeconds))
        }
        let x = samples[res.settled...].map(Double.init)
        let rr = rrFromPeaks(refinePeaks(x, res.peaks), fs: res.rateHz)
        return reading(rrMs: rr, seconds: min(seconds, res.seconds))
    }

    // MARK: pin to Apple's ECG (D-BODY-WALK-1)

    public struct Pin: Sendable, Equatable {
        public var offsetBpm: Double
        public var rrScale: Double
        public var agreementPct: Double
    }

    /// Strap ECG against Apple's ECG from the same morning: offset = strap - Apple (bpm), R-R scale = strap mean R-R / Apple
    /// mean R-R, agreement = 100 (1 - |offset| / Apple). Missing outside 30-220 bpm.
    public static func pin(strapBpm: Double, appleBpm: Double) -> Computed<Pin> {
        for (name, v) in [("strap", strapBpm), ("Apple", appleBpm)] where !(30.0...220.0).contains(v) {
            return .missing(String(format: "%@ ECG mean heart rate %.0f bpm is outside 30-220", name, v))
        }
        let off = strapBpm - appleBpm
        return .success(Pin(offsetBpm: off, rrScale: appleBpm / strapBpm, agreementPct: 100.0 * (1.0 - abs(off) / appleBpm)))
    }

    /// The words on the morning check: pinned to the Apple ECG of that morning, or not yet.
    public static func pinNote(_ p: Computed<Pin>?, strapBpm: Double, appleBpm: Double?, on date: String) -> String {
        guard let appleBpm, let p else { return "not pinned yet: no Apple ECG from this morning" }
        switch p {
        case .success(let x):
            return String(format: "pinned to Apple ECG on %@: strap %.0f vs Apple %.0f bpm, offset %+.1f bpm, R-R scale %.3f, agreement %.0f %%",
                          date, strapBpm, appleBpm, x.offsetBpm, x.rrScale, x.agreementPct)
        case .failure(let m):
            return "not pinned yet: " + m.reason
        }
    }

    // MARK: PPG fallback (ALG-144 accepted pulse intervals on R20)

    public struct PPGStretch: Sendable, Equatable {
        public var start: Double
        public var n: Int
        public var ibiMs: [Double]
    }

    /// The 60 s stretch of accepted pulse intervals with the most intervals and no break (a hole where a successive
    /// interval does not follow within ±30 % of its own length). Windows start at the first interval and every 15 s after;
    /// the earliest wins a tie. Needs 30 intervals.
    public static func ppgWindow(tS: [Double], ibiMs: [Double]) -> Computed<PPGStretch> {
        let pairs = zip(tS, ibiMs).sorted { $0.0 < $1.0 }
        guard let first = pairs.first, let last = pairs.last else { return .missing("no accepted pulse intervals") }
        var best: PPGStretch?
        var a = first.0
        while a + seconds <= last.0 + 1e-9 {
            let inside = pairs.filter { $0.0 >= a && $0.0 < a + seconds }
            var broken = false
            for (p, q) in zip(inside, inside.dropFirst()) {
                let ratio = (q.0 - p.0) * 1000.0 / q.1
                if !(1.0 - ppgContiguity <= ratio && ratio <= 1.0 + ppgContiguity) { broken = true; break }
            }
            if !broken, inside.count >= minBeats, best == nil || inside.count > best!.n {
                best = PPGStretch(start: a, n: inside.count, ibiMs: inside.map { $0.1 })
            }
            a += ppgWindowStepSeconds
        }
        guard let b = best else { return .missing("no unbroken 60 s stretch of at least \(minBeats) pulse intervals") }
        return .success(b)
    }

    /// The morning reading from the R20 raw PPG of the minute after the user pressed Start (ALG-144 accepted intervals).
    public static func ppg(r20: [R20Record]) -> Computed<Reading> {
        let o = ALG144.analyse(r20: r20)
        switch ppgWindow(tS: o.ibiAccepted.map(\.t), ibiMs: o.ibiAccepted.map(\.ms)) {
        case .failure(let m): return .failure(m)
        case .success(let w): return reading(rrMs: w.ibiMs)
        }
    }

    // MARK: metrics

    static func spec(_ key: MetricKey, unit: String, variant: String, source: String, what: String) -> MetricSpec {
        MetricSpec(key: key, unit: unit, group: "G-HRV", variant: variant, method: "ALG-010@1 \(what)", tier: .research,
                   source: source, window: window, citation: citation,
                   paramsVersion: "60s min30beats cov0.8 art0.05" + (source == "ecg" ? " parabolic-peaks" : " alg144-ibi"))
    }

    public static let ecgRmssdSpec = spec(.hrvRmssd, unit: "ms", variant: ecgVariant, source: "ecg",
                                          what: "rmssd-60s-morning-ecg")
    public static let ecgLnRmssdSpec = spec(.hrvLnRmssd, unit: "ln_ms", variant: ecgVariant, source: "ecg",
                                            what: "ln-rmssd-60s-morning-ecg")
    public static let ppgRmssdSpec = spec(.hrvRmssd, unit: "ms", variant: ppgVariant, source: "ppg",
                                          what: "rmssd-60s-morning-ppg")
    public static let ppgLnRmssdSpec = spec(.hrvLnRmssd, unit: "ln_ms", variant: ppgVariant, source: "ppg",
                                            what: "ln-rmssd-60s-morning-ppg")
    public static var specs: [MetricSpec] { [ecgRmssdSpec, ecgLnRmssdSpec, ppgRmssdSpec, ppgLnRmssdSpec] }

    /// The two metrics of one reading (RMSSD, lnRMSSD), or blanks carrying the reason.
    public static func metrics(_ r: Computed<Reading>, fromEcg: Bool, at: Date, pinNote: String? = nil) -> [Metric] {
        let sRmssd = fromEcg ? ecgRmssdSpec : ppgRmssdSpec
        let sLn = fromEcg ? ecgLnRmssdSpec : ppgLnRmssdSpec
        let note = r.value.map {
            String(format: "60 s morning check from %@: %d beats, %.1f %% corrected, %.0f %% of the minute covered; "
                   + "feeds the readiness HRV part; decoded, untested", fromEcg ? "the ECG" : "the pulse (PPG)", $0.beats,
                   $0.artefactFraction * 100, $0.coverage * 100) + (pinNote.map { "; " + $0 } ?? "")
        }
        return [sRmssd.metric(r.map(\.rmssd), at: at, coverage: r.value?.coverage, note: note),
                sLn.metric(r.map(\.lnRmssd), at: at, coverage: r.value?.coverage, note: note)]
    }

    /// The series ALG-160 reads as its enhanced input: the ECG series when it alone passes the readiness HRV rule, else the PPG
    /// series when it alone does, else nil (the night R-R is then used). Series are never mixed.
    public static func readinessSeries(ecg: [Double?], ppg: [Double?]) -> [Double?]? {
        chooseSeries(ecg: ecg, ppg: ppg) { s in
            if case .success = ALG160.hrvStatus(s) { return true }
            return false
        }?.series
    }

    /// One morning series per call, never mixed: the ECG series when it alone is usable, else the PPG series, else nil
    /// (the caller then falls back to the night R-R). `isUsable` is the readiness rule (ALG160.hrvStatus succeeds).
    public static func chooseSeries(ecg: [Double?], ppg: [Double?], isUsable: ([Double?]) -> Bool) -> (variant: String, series: [Double?])? {
        if isUsable(ecg) { return (ecgVariant, ecg) }
        if isUsable(ppg) { return (ppgVariant, ppg) }
        return nil
    }
}
