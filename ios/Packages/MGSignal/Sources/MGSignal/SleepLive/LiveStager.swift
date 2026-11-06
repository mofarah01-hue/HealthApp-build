import Foundation
import MGDomain

/// ALG-031 live v0 — the causal sleep stager for smart wake (ARCHITECTURE 8.1 "ALG-031 live", 4.11 "Watch"; research
/// tier, `SleepLiveParams.version`). Python reference: `stage_live` in app/pclab/mglab/ref/sleep_live.py.
///
/// The causal twin of WP-10's ALG-120 (Cole–Kripke / Webster + HRV fusion, ref/sleep.py `stage_night`): same inputs
/// and constants, but every 30-s epoch is decided at its END from data with ts < end (past epochs only):
///   • Cole–Kripke with past weights only (A(t)…A(t−4)); minute activity = the trailing 60 s of van Hees 5-s z-angle
///     changes (equal to ALG-120's clock-minute activity at whole minutes);
///   • HR wake rule: trailing-minute HR >= median of tonight's completed clock-minute HRs so far + 10 bpm (needs 30);
///   • Webster rules a–c (look back); d–e need the future and are skipped;
///   • lnRMSSD of the trailing 5 min [end − 300, end) after ALG-004 correction of that window only;
///   • robust z against tonight's asleep epochs so far, once 40 exist; REM if z_ln <= −0.5, z_hr >= 0.5 and the
///     trailing minute moved <= 5° (atonia; with no motion data the gate passes); deep if z_ln >= 0.5 and z_hr <= 0;
///   • soft output P(light or wake) = 1 − s(min(z_ln − 0.5, −z_hr)) − s(min(−z_ln − 0.5, z_hr − 0.5)),
///     s(x) = 1 / (1 + e^(−4x)); wake = 1; S and "." = nil. P(deep) >= 0.5 exactly when the hard rule says deep.
/// No bout consolidation (it needs the next bout): the fire rule's "2 epochs in a row" is the live smoothing.
/// Motion is optional (cardiac-only when `liveMotion` is silent — the B1 normal case, MGBLE `StrapMotionSecond`).
///
/// Live use: `add…` as data arrives (any order), `close(through: now − grace)` to emit finished epochs. The batch
/// `stage(seconds:rr:start:end:)` runs the same code with everything present — the reference path the goldens check.
public final class LiveStager {
    public let epoch0: Int64
    public private(set) var epochs: [SleepLiveEpoch] = []
    public private(set) var motionEpochs = 0
    /// Newest second with HR > 0 or an R-R point at or after `epoch0` (live: "when did data stop").
    public private(set) var lastDataTs: Int64?

    private let core: any SignalCore
    // per second, index = ts − epoch0
    private var hr: [Double?] = []
    private var gravity: [(Double, Double, Double)?] = []
    private var seenHR: [Bool] = []
    private var seenGravity: [Bool] = []
    // beats (all points, also before epoch0: BeatClock anchors on the first point, as the reference does)
    private var points: [RRPoint] = []
    private var pointsDirty = false
    private var sortedPoints: [RRPoint] = []
    private var beatT: [Double] = []
    private var ordTs: Int64 = .min
    private var ordNext = 0
    // 5-s blocks
    private var z: [Double?] = []
    private var d: [Double?] = []
    // running state
    private var acts: [Double?] = []
    private var minuteHRs: [Double] = []
    private var histLn: [Double] = []
    private var histHR: [Double] = []
    private var wakeRun = 0
    private var budget = 0

    /// - Parameters:
    ///   - start: the first epoch starts at floor(start / 30) · 30 (WP-10's clock-aligned epochs).
    ///   - core: `Signal.core` by default (ALG-004 may run in Rust).
    public init(start: Int64, core: any SignalCore = Signal.core) {
        self.epoch0 = LiveStager.floorTo(start, SleepLiveParams.epochSeconds)
        self.core = core
    }

    // MARK: input

    /// A whole second (R18 replay). Each field keeps the first value seen for its second.
    public func add(second s: SleepLiveSecond) {
        addHeartRate(ts: s.ts, bpm: s.hr)
        if let x = s.gx, let y = s.gy, let zz = s.gz { addGravity(ts: s.ts, gx: x, gy: y, gz: zz) } else {
            markGravitySeen(ts: s.ts)
        }
    }

    /// Strap HR for one second (live: `LiveBeat.bpm` at `LiveBeat.at`). bpm <= 0 or nil = not on skin.
    public func addHeartRate(ts: Int64, bpm: Double?) {
        guard let k = slot(ts), !seenHR[k] else { return }
        seenHR[k] = true
        if let b = bpm, b > 0 {
            hr[k] = b
            noteData(ts)
        }
    }

    /// Gravity for one second (g; live: `StrapMotionSecond`). (0, 0, 0) is not a measurement.
    public func addGravity(ts: Int64, gx: Double, gy: Double, gz: Double) {
        guard let k = slot(ts), !seenGravity[k] else { return }
        seenGravity[k] = true
        if !(gx == 0 && gy == 0 && gz == 0) { gravity[k] = (gx, gy, gz) }
    }

    /// One R-R point (ts + emission order inside the second).
    public func add(point p: RRPoint) {
        points.append(p)
        pointsDirty = true
        if p.ts >= epoch0 { noteData(p.ts) }
    }

    /// A live burst: R-R values stamped with one strap second; `ord` continues inside that second (MGDomain RRPoint).
    public func addBeats(ts: Int64, rrMs: [Double], source: StreamSource = .live) {
        if ts != ordTs {
            ordTs = ts
            ordNext = 0
        }
        for v in rrMs {
            add(point: RRPoint(ts: ts, ord: ordNext, rrMs: v, source: source))
            ordNext += 1
        }
    }

    // MARK: output

    /// Closes every epoch whose end <= `t` and returns the newly closed ones. Live: call with now − a few seconds of
    /// grace, so the epoch's last beats have arrived; data for a closed epoch that arrives later is not re-applied.
    @discardableResult
    public func close(through t: Int64) -> [SleepLiveEpoch] {
        var out: [SleepLiveEpoch] = []
        while epoch0 + Int64(epochs.count + 1) * SleepLiveParams.epochSeconds <= t {
            out.append(closeNext())
        }
        return out
    }

    /// The span closed so far.
    public var night: SleepLiveNight {
        SleepLiveNight(epoch0: epoch0, epochs: epochs, motionEpochs: motionEpochs, lastDataTs: lastDataTs)
    }

    /// Batch run over [floor30(start), end): every epoch whose end <= end (the reference path; morning replay).
    /// `lastDataTs` counts only data inside that span, as the reference does.
    public static func stage(seconds: [SleepLiveSecond], rr: [RRPoint], start: Int64, end: Int64,
                             core: any SignalCore = Signal.core) -> SleepLiveNight {
        let st = LiveStager(start: start, core: core)
        let e0 = st.epoch0
        let n = end > e0 ? (end - e0) / SleepLiveParams.epochSeconds : 0
        let tEnd = e0 + n * SleepLiveParams.epochSeconds
        var last: Int64?
        for s in seconds where s.ts >= e0 && s.ts < tEnd {
            st.add(second: s)
        }
        // first row wins per second (as the reference): data = a second whose first row has HR > 0
        var firstRow: [Int64: Bool] = [:]
        for s in seconds where s.ts >= e0 && s.ts < tEnd && firstRow[s.ts] == nil {
            firstRow[s.ts] = (s.hr ?? 0) > 0
        }
        for (ts, isData) in firstRow where isData { last = max(last ?? ts, ts) }
        for p in rr {
            st.add(point: p)
            if p.ts >= e0 && p.ts < tEnd { last = max(last ?? p.ts, p.ts) }
        }
        st.close(through: tEnd)
        return SleepLiveNight(epoch0: e0, epochs: st.epochs, motionEpochs: st.motionEpochs, lastDataTs: last)
    }

    // MARK: core

    private func closeNext() -> SleepLiveEpoch {
        let P = SleepLiveParams.self
        let e = epochs.count
        let eRel = Int64(e + 1) * P.epochSeconds
        let E = epoch0 + eRel
        computeBlocks(upTo: Int(eRel / P.blockSeconds))
        let a = trailingActivity(endRel: eRel)
        acts.append(a)
        if a != nil { motionEpochs += 1 }
        let h30 = hrMean(from: eRel - P.epochSeconds, to: eRel, need: P.epochMinHR)
        let hrm = hrMean(from: eRel - 60, to: eRel, need: P.minuteMinHR)
        if E % 60 == 0 && E - 60 >= epoch0, let m = hrm { minuteHRs.append(m) }   // a clock minute completed at E
        let hrRef: Double? = minuteHRs.count >= P.hrRefMinMinutes ? SignalMath.median(minuteHRs) : nil

        let raw: SleepLiveStage
        if a == nil && h30 == nil {
            raw = .noData
        } else {
            var ck = 0.0
            for (lag, w) in P.ckPast {
                let j = e - 2 * lag
                if j >= 0, let aj = acts[j] { ck += w * aj * P.ckActScale }
            }
            let ckWake = a != nil && P.ckP * ck >= 1.0
            var hrWake = false
            if let ref = hrRef, let m = hrm { hrWake = m - ref >= P.hrWakeDelta }
            raw = (ckWake || hrWake) ? .wake : .asleep
        }
        // Webster a–c, causal: after a raw wake run of >= 8 / 20 / 30 epochs, the next 2 / 6 / 8 asleep epochs are wake.
        var cls: SleepLiveStage
        switch raw {
        case .wake:
            wakeRun += 1
            budget = 0
            cls = .wake
        case .asleep:
            if wakeRun > 0 {
                budget = P.websterAfterEpochs.first(where: { wakeRun >= $0.need })?.take ?? 0
                wakeRun = 0
            }
            if budget > 0 {
                budget -= 1
                cls = .wake
            } else {
                cls = .asleep
            }
        default:
            wakeRun = 0
            budget = 0
            cls = .noData
        }
        var p: Double? = cls == .wake ? 1.0 : nil
        if cls == .asleep, let ln = trailingLnRMSSD(end: E), let h = h30 {
            histLn.append(ln)
            histHR.append(h)
            if histLn.count >= P.stageMinHistory {
                let (medLn, sdLn) = LiveStager.robust(histLn, floor: P.zFloorLn)
                let (medHR, sdHR) = LiveStager.robust(histHR, floor: P.zFloorHR)
                let zl = (ln - medLn) / sdLn
                let zh = (h - medHR) / sdHR
                let atonia = a == nil || a! <= P.remStillDeg   // cardiac-only: the gate cannot run and passes
                let mRem = min(-zl - P.zStage, zh - P.zStage)
                let mDeep = min(zl - P.zStage, -zh)
                if mRem >= 0 && atonia {
                    cls = .rem
                } else if mDeep >= 0 {
                    cls = .deep
                } else {
                    cls = .light
                }
                let pRem = atonia ? LiveStager.sig(mRem) : 0.0
                p = max(0.0, 1.0 - LiveStager.sig(mDeep) - pRem)
            }
        }
        let ep = SleepLiveEpoch(start: E - P.epochSeconds, stage: cls, pLightOrWake: p, hasMotion: a != nil)
        epochs.append(ep)
        return ep
    }

    private func computeBlocks(upTo nb: Int) {
        let P = SleepLiveParams.self
        while z.count < nb {
            let b = z.count
            let lo = b * Int(P.blockSeconds)
            var sum = 0.0
            var n = 0
            for k in lo..<(lo + Int(P.blockSeconds)) where k < gravity.count {
                guard hr[k] != nil, let g = gravity[k] else { continue }   // worn: HR > 0 and a gravity vector
                sum += LiveStager.zAngle(g.0, g.1, g.2)
                n += 1
            }
            z.append(n >= P.blockMinWorn ? sum / Double(n) : nil)
            if b > 0, let zb = z[b], let zp = z[b - 1] { d.append(abs(zb - zp)) } else { d.append(nil) }
        }
    }

    /// The trailing minute's activity: van Hees deltas of the 12 blocks starting in [end − 60, end − 5], summed and
    /// scaled 12 / n when >= 10 are valid.
    private func trailingActivity(endRel: Int64) -> Double? {
        let P = SleepLiveParams.self
        let hi = Int(endRel / P.blockSeconds)
        var sum = 0.0
        var n = 0
        for b in max(0, hi - P.blocksPerMinute)..<hi {
            if let v = d[b] {
                sum += v
                n += 1
            }
        }
        guard n >= P.minuteMinValidDeltas else { return nil }
        return sum * Double(P.blocksPerMinute) / Double(n)
    }

    private func hrMean(from a: Int64, to b: Int64, need: Int) -> Double? {
        var sum = 0.0
        var n = 0
        var k = Int(max(0, a))
        let hiK = Int(b)
        while k < hiK && k < hr.count {
            if let v = hr[k] {
                sum += v
                n += 1
            }
            k += 1
        }
        return n >= need ? sum / Double(n) : nil
    }

    /// lnRMSSD of the beats ending in [E − 300, E) that arrived before E, after ALG-004 on that window only.
    private func trailingLnRMSSD(end E: Int64) -> Double? {
        let P = SleepLiveParams.self
        if pointsDirty {
            sortedPoints = BeatClock.sorted(points)
            beatT = BeatClock.times(points: sortedPoints)
            pointsDirty = false
        }
        let lo = LiveStager.lowerBound(beatT, Double(E - P.trailingRMSSDSeconds))
        let hi = LiveStager.lowerBound(beatT, Double(E))
        var rr: [Double] = []
        if lo < hi {
            for i in lo..<hi where sortedPoints[i].ts < E { rr.append(sortedPoints[i].rrMs) }
        }
        guard rr.count >= P.rmssdMinBeats else { return nil }
        let corrected = core.correctArtefacts(rrMs: rr).rrMs
        var total = 0.0
        for v in corrected { total += v }
        guard corrected.count >= P.rmssdMinBeats, total / 1000.0 >= P.rmssdMinCoverSeconds else { return nil }
        return ALG010.time(rrMs: corrected).value?.lnRmssd
    }

    private func slot(_ ts: Int64) -> Int? {
        guard ts >= epoch0, ts - epoch0 < SleepLiveParams.maxSpanSeconds else { return nil }
        let k = Int(ts - epoch0)
        if k >= hr.count {
            let grow = k + 1 - hr.count
            hr.append(contentsOf: repeatElement(nil, count: grow))
            gravity.append(contentsOf: repeatElement(nil, count: grow))
            seenHR.append(contentsOf: repeatElement(false, count: grow))
            seenGravity.append(contentsOf: repeatElement(false, count: grow))
        }
        return k
    }

    private func markGravitySeen(ts: Int64) {
        guard let k = slot(ts) else { return }
        seenGravity[k] = true
    }

    private func noteData(_ ts: Int64) {
        if ts >= epoch0 { lastDataTs = max(lastDataTs ?? ts, ts) }
    }

    // MARK: kernels (Python mirrors named)

    /// van Hees 2015 z-angle (degrees): atan2(z, √(x² + y²)) · 180 / π (sleep.z_angle).
    static func zAngle(_ x: Double, _ y: Double, _ zz: Double) -> Double {
        atan2(zz, (x * x + y * y).squareRoot()) * 180.0 / Double.pi
    }

    /// Median and 1.4826·MAD with a floor (sleep._robust).
    static func robust(_ v: [Double], floor: Double) -> (Double, Double) {
        let med = SignalMath.median(v)
        let mad = SignalMath.median(v.map { abs($0 - med) })
        return (med, max(1.4826 * mad, floor))
    }

    static func sig(_ x: Double) -> Double { 1.0 / (1.0 + exp(-SleepLiveParams.pSteep * x)) }

    /// First index whose value >= x (Python bisect_left).
    static func lowerBound(_ a: [Double], _ x: Double) -> Int {
        var lo = 0
        var hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func floorTo(_ t: Int64, _ step: Int64) -> Int64 {
        let q = t / step
        return (t % step != 0 && t < 0) ? (q - 1) * step : q * step
    }
}
