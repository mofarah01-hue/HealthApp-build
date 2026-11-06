import Foundation
import MGDomain

/// ALG-023 v1 — breathing-disturbance screen from R-R (G-APNEA): cyclic variation of heart rate (CVHR) per observed hour of
/// the sleep period, the cyclic runs written as `breathing_event` events (kind cvhr) for the Night lane and Today's
/// last-night row, and a 30-night view against your own usual. Python reference: app/pclab/mglab/ref/screens.py
/// `cvhr_screen`, `cvhr_distribution`; goldens app/shared/golden/resp/ALG-023.json.
///
/// Dips: port of OpenStrap/analytics respiration/cvhr_apnea.dart @ 458ba36 (Hayano 2011 ACAT-style): split at > 30 s
/// gaps (a segment counts with ≥ 60 beats and ≥ 60 s, hours = observed time only), 1 Hz linear resample, quadratic
/// Savitzky–Golay ±7 s, 130-s sliding-median baseline, positive (bradycardic) excursions, runs above max(0.5 × p75, 5 ms),
/// width 10–120 s and depth/width > 0.7 ms/s. Cyclicity (ours v0, after Hayano's ACAT as described in PLoS ONE 2020,
/// PMC7652322: cycle length 25–130 s; its morphology and cycle-equivalence tests are not applied): a dip is CVHR when it
/// sits in a run of ≥ 3 consecutive dips whose peak-to-peak intervals are all 25–130 s; each run is one event.
/// The 30-night view ports OpenStrap's RESP-01 `cvhrPersonalDistribution` (AF-flagged and < 4-h nights out, ≥ 5 nights,
/// newest third vs your own p75).
///
/// A SCREEN, never an AHI or a diagnosis: CVHR also fires on AF, periodic breathing and fragmented nights, and is blunted
/// by beta-blockers. Respiratory pauses need a breathing waveform (raw optical or the 100 Hz IMU) and the desaturation
/// index needs continuous SpO₂ in % — both stay blank with that reason.
public enum ALG023 {
    public static let citation = "Hayano J et al. 2011 (ACAT CVHR); OpenStrap cvhr_apnea.dart @ 458ba36"
    public static let detector = "ALG-023@1 cvhr-acat"
    public static let minBeats = 60
    public static let maxArtefact = 0.30
    public static let maxGapS = 30.0
    public static let minSegmentS = 60.0
    public static let minWidthS = 10.0
    public static let maxWidthS = 120.0
    public static let depthWidth = 0.7
    public static let envS = 130.0
    public static let sgHalf = 7
    public static let promFloorMs = 5.0
    public static let cycleMinS = 25.0
    public static let cycleMaxS = 130.0
    public static let minRun = 3
    /// One-value carry series per night: the observed hours behind the night's index (the 30-night view weights by it).
    public static let hoursSeries = "cvhr_hours"

    public struct Dip: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var peak: Double
        public var depth: Double
        public var width: Double
    }

    public struct Episode: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var dips: Int
    }

    public struct Screen: Sendable, Equatable {
        /// Cyclic CVHR dips per observed hour — the night's value.
        public var cvhrPerHour: Double
        /// Every dip per observed hour (OpenStrap's index), in the note.
        public var dipsPerHour: Double
        public var cvhr: Int
        public var dips: Int
        public var hours: Double
        public var episodes: [Episode]
    }

    static func resampleLinear(_ t: [Double], _ y: [Double], _ grid: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: grid.count)
        var j = 0
        for (k, g) in grid.enumerated() {
            if g <= t[0] {
                out[k] = y[0]
                continue
            }
            if g >= t[t.count - 1] {
                out[k] = y[y.count - 1]
                continue
            }
            while j < t.count - 1 && t[j + 1] < g { j += 1 }
            let span = t[j + 1] - t[j]
            let frac = span == 0 ? 0.0 : (g - t[j]) / span
            out[k] = y[j] + (y[j + 1] - y[j]) * frac
        }
        return out
    }

    static func det3(_ a0: Double, _ a1: Double, _ a2: Double, _ a3: Double, _ a4: Double, _ a5: Double, _ a6: Double,
                     _ a7: Double, _ a8: Double) -> Double {
        a0 * (a4 * a8 - a5 * a7) - a1 * (a3 * a8 - a5 * a6) + a2 * (a3 * a7 - a4 * a6)
    }

    static func savgolQuadratic(_ x: [Double]) -> [Double] {
        let n = x.count
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - sgHalf)
            let hi = min(n - 1, i + sgHalf)
            if hi - lo + 1 < 3 {
                out[i] = x[i]
                continue
            }
            var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, sy = 0.0, suy = 0.0, su2y = 0.0
            for k in lo...hi {
                let u = Double(k - i)
                let u2 = u * u
                s0 += 1.0
                s1 += u
                s2 += u2
                s3 += u2 * u
                s4 += u2 * u2
                sy += x[k]
                suy += u * x[k]
                su2y += u2 * x[k]
            }
            let d = det3(s0, s1, s2, s1, s2, s3, s2, s3, s4)
            if d == 0 {
                out[i] = x[i]
                continue
            }
            out[i] = det3(sy, s1, s2, suy, s2, s3, su2y, s3, s4) / d
        }
        return out
    }

    static func scoreSegment(_ t: [Double], _ nn: [Double]) -> [Dip] {
        let t0 = t[0]
        let nGrid = Int((t[t.count - 1] - t0).rounded(.down)) + 1
        let grid = (0..<nGrid).map { t0 + Double($0) }
        let sm = savgolQuadratic(resampleLinear(t, nn, grid))
        let halfEnv = Int((envS / 2).rounded())
        var exc = [Double](repeating: 0, count: nGrid)
        for j in 0..<nGrid {
            let lo = max(0, j - halfEnv)
            let hi = min(nGrid - 1, j + halfEnv)
            exc[j] = max(0.0, sm[j] - SignalMath.median(Array(sm[lo...hi])))
        }
        let pos = exc.filter { $0 > 0 }
        let prom = max(0.5 * (pos.isEmpty ? 0.0 : SignalMath.quantile(pos, 0.75)), promFloorMs)
        var dips: [Dip] = []
        var i = 0
        while i < nGrid {
            if exc[i] <= prom {
                i += 1
                continue
            }
            let start = i
            var peak = 0.0
            var peakI = i
            while i < nGrid && exc[i] > prom {
                if exc[i] > peak {
                    peak = exc[i]
                    peakI = i
                }
                i += 1
            }
            let width = Double(i - start)
            if width < minWidthS || width > maxWidthS { continue }
            if peak / width < depthWidth { continue }
            dips.append(Dip(start: grid[start], end: grid[start] + width, peak: grid[peakI], depth: peak, width: width))
        }
        return dips
    }

    static func cyclicRuns(_ dips: [Dip]) -> [[Int]] {
        var runs: [[Int]] = []
        var cur: [Int] = dips.isEmpty ? [] : [0]
        if dips.count > 1 {
            for k in 1..<dips.count {
                let gap = dips[k].peak - dips[k - 1].peak
                if gap >= cycleMinS && gap <= cycleMaxS {
                    cur.append(k)
                } else {
                    if cur.count >= minRun { runs.append(cur) }
                    cur = [k]
                }
            }
        }
        if cur.count >= minRun { runs.append(cur) }
        return runs
    }

    /// The screen on the sleep period's ALG-004-corrected R-R (ms), beat times (s) and the corrected fraction.
    public static func screen(nnMs: [Double], times: [Double], artefactFraction: Double) -> Computed<Screen> {
        guard nnMs.count >= minBeats, times.count == nnMs.count else {
            return .missing("needs \(minBeats) beats in the sleep period (have \(nnMs.count))")
        }
        guard artefactFraction <= maxArtefact else {
            return .missing("artefact fraction \(String(format: "%.2f", artefactFraction)) is above \(maxArtefact): dips unreliable")
        }
        guard times[times.count - 1] - times[0] > 0 else { return .missing("beat times do not advance") }
        var segStart = [0]
        for i in 1..<times.count where times[i] - times[i - 1] > maxGapS { segStart.append(i) }
        var hours = 0.0
        var nDips = 0
        var nCyclic = 0
        var episodes: [Episode] = []
        for (s, lo) in segStart.enumerated() {
            let hi = (s + 1 < segStart.count ? segStart[s + 1] : times.count) - 1
            let st = Array(times[lo...hi])
            let sn = Array(nnMs[lo...hi])
            if st.count < minBeats || st[st.count - 1] - st[0] < minSegmentS { continue }
            hours += (st[st.count - 1] - st[0]) / 3600.0
            let dips = scoreSegment(st, sn)
            nDips += dips.count
            for run in cyclicRuns(dips) {
                nCyclic += run.count
                episodes.append(Episode(start: dips[run[0]].start, end: dips[run[run.count - 1]].end, dips: run.count))
            }
        }
        guard hours > 0 else { return .missing("no gap-free stretch of at least 60 s and 60 beats") }
        return .success(Screen(cvhrPerHour: Double(nCyclic) / hours, dipsPerHour: Double(nDips) / hours, cvhr: nCyclic,
                               dips: nDips, hours: hours, episodes: episodes))
    }

    // MARK: 30-night view (OpenStrap RESP-01)

    public static let minHoursPerNight = 4.0
    public static let minNights = 5
    public static let windowNights = 30

    public struct Night: Sendable, Equatable {
        public var cvhrPerHour: Double?
        public var hours: Double?
        public var irregular: Bool

        public init(cvhrPerHour: Double?, hours: Double?, irregular: Bool = false) {
            self.cvhrPerHour = cvhrPerHour
            self.hours = hours
            self.irregular = irregular
        }
    }

    public struct Distribution: Sendable, Equatable {
        public var recent: Double
        public var all: Double
        public var quartiles: [Double]
        public var aboveOwnUsual: Bool
        public var nights: Int
        public var recentNights: Int
        public var excludedIrregular: Int
        public var excludedThin: Int
    }

    /// Nights newest first.
    public static func distribution(nights: [Night]) -> Computed<Distribution> {
        var kept: [(v: Double, h: Double)] = []
        var irregular = 0
        var thin = 0
        for n in nights {
            if kept.count >= windowNights { break }
            guard let v = n.cvhrPerHour, let h = n.hours, v.isFinite, h.isFinite else { continue }
            if n.irregular {
                irregular += 1
                continue
            }
            if h < minHoursPerNight {
                thin += 1
                continue
            }
            kept.append((v, h))
        }
        guard kept.count >= minNights else {
            return .missing("needs \(minNights) nights with >= \(Int(minHoursPerNight)) observed hours (have \(kept.count); "
                            + "\(irregular) left out for a rhythm flag, \(thin) too thinly observed)")
        }
        func weighted(_ xs: ArraySlice<(v: Double, h: Double)>) -> Double {
            var num = 0.0
            var den = 0.0
            for x in xs {
                num += x.v * x.h
                den += x.h
            }
            return num / den
        }
        let recentN = max(2, Int((Double(kept.count) / 3.0 + 0.5).rounded(.down)))
        let vals = kept.map(\.v)
        let q = [SignalMath.quantile(vals, 0.25), SignalMath.quantile(vals, 0.5), SignalMath.quantile(vals, 0.75)]
        let rec = weighted(kept.prefix(recentN))
        return .success(Distribution(recent: rec, all: weighted(kept[...]), quartiles: q, aboveOwnUsual: rec > q[2],
                                     nights: kept.count, recentNights: recentN, excludedIrregular: irregular,
                                     excludedThin: thin))
    }

    // MARK: metrics and events

    public static let cvhrSpec = MetricSpec(
        key: .breathingDisturbance, unit: "events_per_h", group: "G-APNEA", variant: "ALG-023:cvhr",
        method: "ALG-023@1 cvhr-acat-screen", tier: .research, source: "rr", window: "night", citation: citation,
        paramsVersion: "w10-120 dw0.7 env130 sg7 cyc25-130 run3")
    public static let cvhr30Spec = MetricSpec(
        key: .breathingDisturbance, unit: "events_per_h", group: "G-APNEA", variant: "ALG-023:cvhr30",
        method: "ALG-023@1 cvhr-30-night-view", tier: .research, source: "breathing_disturbance", window: "30d",
        citation: "OpenStrap cvhr_apnea.dart cvhrPersonalDistribution (RESP-01) @ 458ba36",
        paramsVersion: "min4h min5 win30 recent-third")
    public static let odiSpec = MetricSpec(
        key: .breathingDisturbance, unit: "events_per_h", group: "G-APNEA", variant: "ALG-023:odi",
        method: "ALG-023@1 odi", tier: .research, source: "spo2", window: "night", citation: citation)
    public static let odiReason = "needs continuous SpO2 in %: the strap's 20-min SpO2 byte cannot count desaturation events"
    public static let screenNote = "a screen, never an AHI or a diagnosis; CVHR also fires on AF and fragmented nights"

    public static func metrics(_ s: Computed<Screen>, at: Date, rhythmFlag: Bool) -> [Metric] {
        var note: String?
        if let v = s.value {
            note = "\(v.cvhr) cyclic of \(v.dips) dips (\(String(format: "%.1f", v.dipsPerHour))/h any dip) over "
                + "\(String(format: "%.1f", v.hours)) observed h; \(screenNote)"
            if rhythmFlag { note! += "; the rhythm screen flagged this night, read with care" }
        }
        return [cvhrSpec.metric(s.map(\.cvhrPerHour), at: at, note: note), odiSpec.blank(odiReason, at: at)]
    }

    public static func distributionMetric(_ d: Computed<Distribution>, at: Date) -> Metric {
        let note = d.value.map {
            "newest \($0.recentNights) of \($0.nights) nights; your usual p25-p75 "
                + "\(String(format: "%.1f", $0.quartiles[0]))-\(String(format: "%.1f", $0.quartiles[2]))/h; "
                + ($0.aboveOwnUsual ? "above your own usual" : "within your own usual") + "; about you against you only"
        }
        return cvhr30Spec.metric(d.map(\.recent), at: at, note: note)
    }

    /// Stable id per episode start (whole seconds): a re-run that finds the same episode updates it, never duplicates.
    public static func eventID(start: Double) -> UUID {
        let s = UInt64(bitPattern: Int64(start.rounded(.down)))
        var b: [UInt8] = [0x41, 0x30, 0x32, 0x33, 0x63, 0x76, 0x80, 0x00]     // "A023cv" + version / variant bits below
        for k in 0..<8 { b.append(UInt8(truncatingIfNeeded: s >> (8 * UInt64(7 - k)))) }
        b[6] = (b[6] & 0x0F) | 0x80
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
                           b[14], b[15]))
    }

    public static func isOurs(_ e: EventRecord) -> Bool {
        guard case .breathing(let f) = e.payload else { return false }
        return (f.detector ?? "").hasPrefix("ALG-023")
    }

    /// The breathing_event upserts for one night: one event per cyclic episode (source detected, kind cvhr), and every
    /// earlier ALG-023 event inside [spanStart, spanEnd] that this run no longer finds marked `retracted` (kept, never
    /// deleted; the Night lane and Today skip retracted events). `existing` = the stored events around the night.
    public static func events(_ s: Computed<Screen>, spanStart: Double, spanEnd: Double,
                              existing: [EventRecord]) -> [EventRecord] {
        var out: [EventRecord] = []
        var ids = Set<UUID>()
        for ep in s.value?.episodes ?? [] {
            let id = eventID(start: ep.start)
            ids.insert(id)
            let f = BreathingFields(end: Date(timeIntervalSince1970: ep.end), kind: .cvhr, detector: detector,
                                    corroboration: "\(ep.dips) heart-rate dips in a row, 25-130 s apart")
            out.append(EventRecord(id: id, at: Date(timeIntervalSince1970: ep.start), source: .detected,
                                   note: "breathing-disturbance screen: " + screenNote, payload: .breathing(f)))
        }
        guard s.value != nil else { return out }       // no screen tonight: nothing to retract against
        for e in existing where !e.removed && isOurs(e) && !ids.contains(e.id) {
            let t = e.at.timeIntervalSince1970
            guard t >= spanStart && t <= spanEnd, case .breathing(var f) = e.payload, f.retracted != true else { continue }
            f.retracted = true
            var r = e
            r.payload = .breathing(f)
            out.append(r)
        }
        return out
    }
}
