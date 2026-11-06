import Foundation
import MGDomain

/// ALG-144 v1 (T9725, Oct 14, 2026) — PPG cleaning, signal quality and pulse heart rate, the pipeline Mo chose on Oct 14
/// at 10:20 AM (docs/DECISIONS.md D-069-T9725; structure from docs/research/OTHER-AI-PPG-PIPELINE-2026-10-14.txt, whose
/// claims about WHOOP were NOT taken as fact). The old ones stay as variants: ALG-108 (autocorrelation) and ALG-005
/// (skewness SQI + Orphanidou rules). Research tier, decoded, untested on Mo's strap; every number is raw counts.
///
/// What it does, in order:
/// 1. Raw stays untouched: `Output.ppgRaw` is a copy of every slot's raw counts with its time.
/// 2. Timing from the data: a run of one-second records is continuous only when each strap timestamp is the last + 1;
///    the sample rate is the samples counted over the strap seconds they cover (never an assumed 25 Hz). Anything
///    else (a hole, a repeat, a record whose rate flag disagrees with its timestamps) splits the run: TIMESTAMP_GAP.
/// 3. Cleaning: zero-phase band-pass 0.5–4 Hz (2nd-order Butterworth high-pass + low-pass biquads, run forward then
///    backward) on EACH optical slot on its own — slots are never averaged (they may be different emitters/detectors).
/// 4. Per 8-s window: hard gates, a quality score per slot (spectral peak prominence), the best slot, a heart rate from
///    its spectrum (after spectral subtraction of the accelerometer when there is motion), two beat detectors and their
///    agreement, and inter-beat intervals only from beats both detectors found, never across a gap.
///
/// Live hook (the Live view wiring belongs to another package): call `ALG144.analyse(r20:motion:events:)` on the
/// recent live R20 records (and R21 motion seconds) and show `Output.cleanSeries(for: window.slot)` or
/// `Output.bestClean` as the cleaned trace, `Output.hrEstimated` for the pulse number and each window's `state` /
/// `reasons` as its quality chip. The natural place is where `OpticalPulse.spot` is called for the Live tab today
/// (it feeds MGContext `LiveState.opticalWaves` / `OpticalWave`).
public enum ALG144 {
    public static let variant = "ALG-144"
    public static let version = "ALG-144@1"
    public static let citation = "Butterworth biquads: R. Bristow-Johnson, Audio EQ Cookbook; forward-backward (zero-phase) "
        + "filtering as MATLAB/SciPy filtfilt; spectral subtraction of the accelerometer: Zhang, Pi, Liu 2015 IEEE TBME 62:522 "
        + "(TROIKA); beats: Elgendi 2013 PLoS ONE 8:e76585 (two moving averages, via ALG-005) and Bishop & Ercole 2018 "
        + "Acta Neurochir Suppl 126:251 (MSPTD), scales limited as Charlton 2022 (MSPTDfast); gate names and gap policy: "
        + "docs/research/OTHER-AI-PPG-PIPELINE-2026-10-14.txt (a proposal, not WHOOP firmware enums)"

    // MARK: constants

    /// ENGINEERING STARTING VALUES (Oct 14, 2026). Not published WHOOP thresholds, not tuned against a reference ECG;
    /// to be tuned on Mo's strap with a time-aligned ECG before anything here is called accurate.
    public enum Constants {
        public static let windowSeconds = 8.0
        /// One-second records: continuous only when the next strap timestamp is the last + 1.
        public static let recordStepSeconds: Int64 = 1
        /// A record's rate flag and its timestamps must agree within this share, else its timing is not established.
        public static let rateTolerance = 0.05
        public static let bandLowHz = 0.5
        public static let bandHighHz = 4.0
        /// Heart rates searched (bpm).
        public static let hrRange: ClosedRange<Double> = 30...220
        public static let spectralStepHz = 0.02
        /// Half-width of a spectral peak's band (Hz) for SNR, overlap and ambiguity.
        public static let peakHalfWidthHz = 0.15
        /// LOW_SNR below this: power in the cardiac peak (+ its 2nd harmonic) over the rest of the 0.5–3.67 Hz band.
        public static let minSNR = 0.4
        /// RATE_AMBIGUITY when a second, non-harmonic peak holds at least this share of the top peak's power.
        public static let ambiguityRatio = 0.8
        /// Fundamental preference: the peak at half the top frequency wins when it holds this share of the top's power.
        public static let fundamentalRatio = 0.5
        /// R20 samples are signed 20-bit ADC counts (MGDomain R20Record): the converter limits.
        public static let adcMax: Int32 = 524_287
        public static let adcMin: Int32 = -524_288
        /// ADC_CLIPPED when a slot has at least this many samples at a limit in the window.
        public static let adcClipMinSamples = 3
        /// R26 adjacent differences are int16: a difference at ±32,767 is clipped (reconstruction lossy).
        public static let deltaClipLimit: Int32 = 32_767
        /// noop convention 4,096 counts = 1 g (Whoop5RawImu.swift L51), decoded, untested.
        public static let countsPerG = 4096.0
        /// MOTION when the accelerometer magnitude's SD in the window exceeds this (g).
        public static let motionSDg = 0.1
        /// Below this accelerometer SD (g) the accelerometer spectrum is noise: no overlap test, no subtraction.
        public static let motionFloorG = 0.02
        /// The accelerometer's dominant peak must hold this share of its 0.5–4 Hz power to count as a motion frequency.
        public static let motionPeakShare = 0.3
        /// Two detectors' beats within this many seconds are the same beat (Charlton's 150 ms beat tolerance).
        public static let beatMatchSeconds = 0.15
        /// PEAK_DISAGREEMENT below this share of matched beats.
        public static let minAgreement = 0.8
        /// An accepted interval lies within this share of the window's spectral period (a missed beat doubles it).
        public static let ibiPeriodRange: ClosedRange<Double> = 0.7...1.3
        /// Confidence multiplier for a window with a soft gate (MOTION, DELTA_CLIPPED, PEAK_DISAGREEMENT, RATE_AMBIGUITY).
        public static let reducedConfidence = 0.5
        /// MGDomain StrapEvent numbers from whoop_protocol.json: 9 WRIST_ON, 10 WRIST_OFF.
        public static let wristOnEvent = 9
        public static let wristOffEvent = 10
    }

    /// Gap policy (research file section 4, engineering starting rules, not WHOOP thresholds), and what ALG-144 does.
    public struct GapRule: Sendable, Equatable {
        public var upToSeconds: Double
        public var raw: String
        public var hr: String
        public var ibi: String
    }

    public static let gapPolicy: [GapRule] = [
        GapRule(upToSeconds: 0.5, raw: "kept as a gap; no display interpolation in ALG-144",
                hr: "from the clean windows around it", ibi: "no interval across it"),
        GapRule(upToSeconds: 3, raw: "invalid segment", hr: "blank for the gap (no temporal model yet)", ibi: "missing"),
        GapRule(upToSeconds: 10, raw: "missing", hr: "blank for the gap (no short-term prediction)", ibi: "missing"),
        GapRule(upToSeconds: .infinity, raw: "missing", hr: "blank until the signal returns", ibi: "missing"),
    ]

    public static func gapRule(seconds: Double) -> GapRule {
        gapPolicy.first { seconds <= $0.upToSeconds } ?? gapPolicy[gapPolicy.count - 1]
    }

    // MARK: types

    public enum Gate: String, Sendable, CaseIterable, Codable {
        case packetInvalid = "PACKET_INVALID"
        case noContact = "NO_CONTACT"
        case adcClipped = "ADC_CLIPPED"
        case deltaClipped = "DELTA_CLIPPED"
        case motion = "MOTION"
        case lowSNR = "LOW_SNR"
        case peakDisagreement = "PEAK_DISAGREEMENT"
        case rateAmbiguity = "RATE_AMBIGUITY"
        case timestampGap = "TIMESTAMP_GAP"
    }

    /// measured = no gate, HR and intervals; reduced = HR with reduced confidence, no intervals; unavailable = blank.
    public enum State: String, Sendable, Codable {
        case measured
        case reduced
        case unavailable
    }

    public struct Provenance: Sendable, Equatable {
        public var algorithm: String
        /// "r20 b0 A" (R20 block 0 slot A) or "v26".
        public var slot: String?
        public var sampleRateHz: Double?
        /// How the rate was established, e.g. "200 samples over 8 strap seconds".
        public var rateBasis: String
    }

    public struct Window: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var state: State
        public var gates: [Gate]
        /// Plain-English reason per gate or blank, never empty when `state` is not `.measured`.
        public var reasons: [String]
        /// The chosen slot and every usable slot's score (higher = cleaner), best first.
        public var slot: String?
        public var slotRanking: [SlotScore]
        public var hrBpm: Double?
        /// 0–1, an engineering score (SNR / (1 + SNR), halved by a soft gate), not a probability.
        public var confidence: Double
        /// Share of beats both detectors found; nil when no beats were looked for.
        public var beatAgreement: Double?
        public var provenance: Provenance
    }

    public struct SlotScore: Sendable, Equatable {
        public var slot: String
        public var score: Double
    }

    public struct TimedValue: Sendable, Equatable {
        public var t: Double
        public var value: Double
    }

    public struct SlotSeries: Sendable, Equatable {
        public var slot: String
        public var points: [TimedValue]
    }

    public struct HREstimate: Sendable, Equatable {
        /// Window middle (strap unix seconds).
        public var t: Double
        public var bpm: Double
        public var confidence: Double
        public var state: State
        public var slot: String
    }

    public struct IBI: Sendable, Equatable {
        /// Time of the second beat (strap unix seconds).
        public var t: Double
        public var ms: Double
        public var slot: String
    }

    /// The four series. `ppgRaw` is never changed; `ppgClean` is the band-passed copy (per slot, same times).
    public struct Output: Sendable, Equatable {
        public var ppgRaw: [SlotSeries]
        public var ppgClean: [SlotSeries]
        public var hrEstimated: [HREstimate]
        public var ibiAccepted: [IBI]
        public var windows: [Window]

        public func cleanSeries(for slot: String?) -> [TimedValue] {
            ppgClean.first { $0.slot == slot }?.points ?? []
        }

        /// The clean trace of each window's chosen slot, window after window (empty for blank windows).
        public var bestClean: [TimedValue] {
            var out: [TimedValue] = []
            for w in windows where w.state != .unavailable {
                out += cleanSeries(for: w.slot).filter { $0.t >= w.start && $0.t < w.end }
            }
            return out
        }
    }

    // MARK: prepared input

    /// One optical slot of one continuous segment: raw counts with their times and per-sample clip flags.
    public struct Slot: Sendable, Equatable {
        public var id: String
        public var t: [Double]
        public var x: [Double]
        public var adcClipped: [Bool]
        public var deltaClipped: [Bool]

        public init(id: String, t: [Double], x: [Double], adcClipped: [Bool]? = nil, deltaClipped: [Bool]? = nil) {
            self.id = id
            self.t = t
            self.x = x
            self.adcClipped = adcClipped ?? Array(repeating: false, count: x.count)
            self.deltaClipped = deltaClipped ?? Array(repeating: false, count: x.count)
        }
    }

    public struct Segment: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var fsHz: Double
        public var rateBasis: String
        public var slots: [Slot]
    }

    /// A span with no usable timing or no valid packet, and why.
    public struct Hole: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var gate: Gate
        public var reason: String
    }

    public struct Prepared: Sendable, Equatable {
        public var segments: [Segment]
        public var holes: [Hole]
    }

    public struct Accel: Sendable, Equatable {
        public var t: [Double]
        /// |a| in raw counts.
        public var mag: [Double]

        public init(t: [Double], mag: [Double]) {
            self.t = t
            self.mag = mag
        }
    }

    // MARK: adapters

    /// R20: every block's slot A and slot B is its own slot. A record is invalid (PACKET_INVALID) when a block's head is
    /// not 21 bytes, its two slots differ in length, the head's count byte disagrees, or it holds more than 50 samples.
    public static func prepare(r20 records: [R20Record]) -> Prepared {
        var holes: [Hole] = []
        var valid: [R20Record] = []
        for r in records.sorted(by: { $0.ts < $1.ts }) {
            let bad = r.blocks.isEmpty || r.blocks.contains {
                $0.head.count != 21 || $0.slotA.count != $0.slotB.count || Int($0.head[0]) != $0.slotA.count || $0.slotA.count > 50
            }
            if bad {
                holes.append(Hole(start: Double(r.ts), end: Double(r.ts + 1), gate: .packetInvalid,
                                  reason: "R20 record \(r.recordIndex) does not decode to its own layout"))
            } else {
                valid.append(r)
            }
        }
        var runs: [[R20Record]] = []
        for r in valid {
            let n = r.blocks.map(\.slotA.count).max() ?? 0
            if let last = runs.last?.last {
                let lastN = last.blocks.map(\.slotA.count).max() ?? 0
                if r.ts == last.ts + Constants.recordStepSeconds && n == lastN && r.blocks.count == last.blocks.count {
                    runs[runs.count - 1].append(r)
                    continue
                }
                holes.append(timingHole(after: last.ts, next: r.ts, what: n == lastN ? nil : "samples per record changed \(lastN) → \(n)"))
            }
            runs.append([r])
        }
        let segments = runs.compactMap { run -> Segment? in
            guard let first = run.first, let last = run.last else { return nil }
            let n = first.blocks.map(\.slotA.count).max() ?? 0
            guard n > 0 else { return nil }
            let seconds = Double(last.ts + 1 - first.ts)
            let fs = Double(n * run.count) / seconds
            var t: [Double] = []
            for r in run { for k in 0..<n { t.append(Double(r.ts) + Double(k) / Double(n)) } }
            var slots: [Slot] = []
            for b in first.blocks.indices {
                let picks: [(String, (R20Block) -> [Int32])] = [("A", { $0.slotA }), ("B", { $0.slotB })]
                for (name, pick) in picks {
                    let raw = run.flatMap { pick($0.blocks[b]) }
                    guard raw.count == t.count, raw.contains(where: { $0 != 0 }) else { continue }
                    slots.append(Slot(id: "r20 b\(b) \(name)", t: t, x: raw.map(Double.init),
                                      adcClipped: raw.map { $0 >= Constants.adcMax || $0 <= Constants.adcMin }))
                }
            }
            return Segment(start: Double(first.ts), end: Double(last.ts + 1), fsHz: fs,
                           rateBasis: "\(n * run.count) samples over \(Int(seconds)) strap seconds", slots: slots)
        }
        return Prepared(segments: segments, holes: holes)
    }

    /// R26 (v26 PPG): raw = base + offset; the difference into each sample is checked against ±32,767 (DELTA_CLIPPED).
    /// A record whose rate flag disagrees with what its timestamps give (e.g. flag 50 Hz with 25 samples per strap
    /// second: only half of each second is stored) has no established timing: TIMESTAMP_GAP.
    public static func prepare(ppg blocks: [PPGBlock]) -> Prepared {
        var holes: [Hole] = []
        var valid: [PPGBlock] = []
        for b in blocks.sorted(by: { $0.ts < $1.ts }) {
            if b.samples.isEmpty || b.samples.count > 50 {
                holes.append(Hole(start: Double(b.ts), end: Double(b.ts + 1), gate: .packetInvalid,
                                  reason: "v26 record with \(b.samples.count) samples"))
                continue
            }
            let fromTimestamps = Double(b.samples.count) / Double(Constants.recordStepSeconds)
            if b.rateHz <= 0 || abs(fromTimestamps - b.rateHz) / b.rateHz > Constants.rateTolerance {
                holes.append(Hole(start: Double(b.ts), end: Double(b.ts + 1), gate: .timestampGap,
                                  reason: "rate flag \(Int(b.rateHz)) Hz but \(b.samples.count) samples per strap second: "
                                    + "the sample timing cannot be established"))
                continue
            }
            valid.append(b)
        }
        var runs: [[PPGBlock]] = []
        for b in valid {
            if let last = runs.last?.last {
                if b.ts == last.ts + Constants.recordStepSeconds && b.samples.count == last.samples.count {
                    runs[runs.count - 1].append(b)
                    continue
                }
                holes.append(timingHole(after: last.ts, next: b.ts,
                                        what: b.samples.count == last.samples.count ? nil
                                            : "samples per record changed \(last.samples.count) → \(b.samples.count)"))
            }
            runs.append([b])
        }
        let segments = runs.compactMap { run -> Segment? in
            guard let first = run.first, let last = run.last else { return nil }
            let n = first.samples.count
            let seconds = Double(last.ts + 1 - first.ts)
            var t: [Double] = [], x: [Double] = [], dc: [Bool] = []
            for b in run {
                for (k, s) in b.samples.enumerated() {
                    t.append(Double(b.ts) + Double(k) / Double(n))
                    x.append(Double(b.base) + Double(s))
                    let d = k == 0 ? Int64(s) : Int64(s) - Int64(b.samples[k - 1])
                    dc.append(abs(d) >= Int64(Constants.deltaClipLimit))
                }
            }
            return Segment(start: Double(first.ts), end: Double(last.ts + 1), fsHz: Double(n * run.count) / seconds,
                           rateBasis: "\(n * run.count) samples over \(Int(seconds)) strap seconds",
                           slots: [Slot(id: "v26", t: t, x: x, deltaClipped: dc)])
        }
        return Prepared(segments: segments, holes: holes)
    }

    static func timingHole(after last: Int64, next: Int64, what: String?) -> Hole {
        if let what {
            return Hole(start: Double(last + 1), end: Double(max(next, last + 1)), gate: .timestampGap,
                        reason: "\(what): a new segment starts")
        }
        if next <= last {
            return Hole(start: Double(next), end: Double(last + 1), gate: .timestampGap,
                        reason: "repeated or backwards strap timestamp: the sample timing cannot be established")
        }
        let gap = Double(next - last - 1)
        let rule = gapRule(seconds: gap)
        return Hole(start: Double(last + 1), end: Double(next), gate: .timestampGap,
                    reason: "\(Int(gap)) s with no record: raw \(rule.raw); heart rate \(rule.hr); intervals \(rule.ibi)")
    }

    /// R21 seconds → accelerometer magnitude with each sample's time (strap second + fraction + k / count).
    public static func accel(_ motion: [MotionSecond]) -> Accel {
        var t: [Double] = [], m: [Double] = []
        for s in motion.sorted(by: { $0.ts < $1.ts }) {
            guard let c = s.columns, s.accelCount > 0 else { continue }
            let mags = MotionSecond.magnitudes(c)
            let t0 = Double(s.ts) + Double(s.fraction) / 32768
            for (k, v) in mags.enumerated() {
                t.append(t0 + Double(k) / Double(mags.count))
                m.append(v)
            }
        }
        return Accel(t: t, mag: m)
    }

    /// Off-wrist spans from strap events (WRIST_OFF → next WRIST_ON; open-ended when no WRIST_ON follows).
    public static func offWrist(_ events: [StrapEvent]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        var off: Int64?
        for e in events.sorted(by: { $0.ts < $1.ts }) {
            if e.number == Constants.wristOffEvent, off == nil { off = e.ts }
            if e.number == Constants.wristOnEvent, let o = off {
                out.append(Double(o)...Double(max(o, e.ts)))
                off = nil
            }
        }
        if let o = off { out.append(Double(o)...Double.greatestFiniteMagnitude) }
        return out
    }

    // MARK: entry points

    public static func analyse(r20: [R20Record], motion: [MotionSecond] = [], events: [StrapEvent] = []) -> Output {
        analyse(prepare(r20: r20), accel: motion.isEmpty ? nil : accel(motion), offWrist: offWrist(events))
    }

    public static func analyse(ppg: [PPGBlock], motion: [MotionSecond] = [], events: [StrapEvent] = []) -> Output {
        analyse(prepare(ppg: ppg), accel: motion.isEmpty ? nil : accel(motion), offWrist: offWrist(events))
    }

    public static func analyse(_ p: Prepared, accel: Accel?, offWrist: [ClosedRange<Double>] = []) -> Output {
        var out = Output(ppgRaw: [], ppgClean: [], hrEstimated: [], ibiAccepted: [], windows: [])
        for h in p.holes {
            out.windows.append(Window(start: h.start, end: h.end, state: .unavailable, gates: [h.gate], reasons: [h.reason],
                                      slot: nil, slotRanking: [], hrBpm: nil, confidence: 0, beatAgreement: nil,
                                      provenance: Provenance(algorithm: version, slot: nil, sampleRateHz: nil,
                                                             rateBasis: "no timing")))
        }
        for seg in p.segments { analyse(seg, accel: accel, offWrist: offWrist, into: &out) }
        out.windows.sort { $0.start < $1.start }
        return out
    }

    // MARK: per segment

    static func analyse(_ seg: Segment, accel: Accel?, offWrist: [ClosedRange<Double>], into out: inout Output) {
        let fs = seg.fsHz
        var clean: [String: [Double]] = [:]
        for s in seg.slots {
            out.ppgRaw.append(SlotSeries(slot: s.id, points: zip(s.t, s.x).map { TimedValue(t: $0, value: $1) }))
            if fs > 2.2 * Constants.bandHighHz {
                let y = bandPass(s.x, fs: fs)
                clean[s.id] = y
                out.ppgClean.append(SlotSeries(slot: s.id, points: zip(s.t, y).map { TimedValue(t: $0, value: $1) }))
            }
        }
        func blank(_ a: Double, _ b: Double, _ gates: [Gate], _ reasons: [String]) -> Window {
            Window(start: a, end: b, state: .unavailable, gates: gates, reasons: reasons, slot: nil, slotRanking: [],
                   hrBpm: nil, confidence: 0, beatAgreement: nil,
                   provenance: Provenance(algorithm: version, slot: nil, sampleRateHz: fs, rateBasis: seg.rateBasis))
        }
        guard fs > 2.2 * Constants.bandHighHz else {
            out.windows.append(blank(seg.start, seg.end, [], ["sample rate \(fmt(fs)) Hz from the timestamps is too low for a 0.5–4 Hz band"]))
            return
        }
        guard !seg.slots.isEmpty else {
            out.windows.append(blank(seg.start, seg.end, [], ["no optical slot carried a non-zero sample"]))
            return
        }
        let n = seg.slots[0].t.count
        let wlen = Int((Constants.windowSeconds * fs).rounded())
        var previousHR: Double?
        var i0 = 0
        while i0 < n {
            let i1 = min(n, i0 + wlen)
            let t = Array(seg.slots[0].t[i0..<i1])
            let a = t[0], b = i1 < n ? seg.slots[0].t[i1] : seg.end
            if i1 - i0 < wlen {
                out.windows.append(blank(a, b, [], ["the last \(fmt(Double(i1 - i0) / fs)) s of this run is shorter than one \(Int(Constants.windowSeconds))-s window"]))
                break
            }
            let w = window(seg: seg, range: i0..<i1, start: a, end: b, clean: clean, accel: accel, offWrist: offWrist,
                           previousHR: previousHR)
            out.windows.append(w.window)
            if let hr = w.window.hrBpm, let slot = w.window.slot {
                out.hrEstimated.append(HREstimate(t: (a + b) / 2, bpm: hr, confidence: w.window.confidence,
                                                  state: w.window.state, slot: slot))
                previousHR = hr
            }
            out.ibiAccepted += w.ibis
            i0 = i1
        }
    }

    // MARK: per window

    static func window(seg: Segment, range r: Range<Int>, start a: Double, end b: Double, clean: [String: [Double]],
                       accel: Accel?, offWrist: [ClosedRange<Double>], previousHR: Double?) -> (window: Window, ibis: [IBI]) {
        let fs = seg.fsHz
        var gates: [Gate] = []
        var reasons: [String] = []
        func add(_ g: Gate, _ why: String) {
            if !gates.contains(g) { gates.append(g) }
            reasons.append("\(g.rawValue): \(why)")
        }
        func done(_ state: State, slot: String?, ranking: [SlotScore] = [], hr: Double? = nil, conf: Double = 0,
                  agreement: Double? = nil, ibis: [IBI] = []) -> (window: Window, ibis: [IBI]) {
            (Window(start: a, end: b, state: state, gates: gates, reasons: reasons, slot: slot, slotRanking: ranking,
                    hrBpm: hr, confidence: conf, beatAgreement: agreement,
                    provenance: Provenance(algorithm: version, slot: slot, sampleRateHz: fs, rateBasis: seg.rateBasis)), ibis)
        }
        if offWrist.contains(where: { $0.overlaps(a...b) }) {
            add(.noContact, "the strap reported WRIST_OFF for part of this window")
            return done(.unavailable, slot: nil)
        }
        let t = Array(seg.slots[0].t[r])
        let rel = t.map { $0 - a }
        // per-slot gates and score
        var ranking: [SlotScore] = []
        var spectra: [String: [Double]] = [:]
        var clippedSlots: [String] = []
        var deltaSlots: Set<String> = []
        for s in seg.slots {
            guard let y = clean[s.id] else { continue }
            let raw = s.x[r]
            if raw.allSatisfy({ $0 == 0 }) { continue }
            if s.adcClipped[r].filter({ $0 }).count >= Constants.adcClipMinSamples { clippedSlots.append(s.id); continue }
            if s.deltaClipped[r].contains(true) { deltaSlots.insert(s.id) }
            let p = spectrum(Array(y[r]), t: rel)
            spectra[s.id] = p
            ranking.append(SlotScore(slot: s.id, score: snr(p, peak: argmax(p))))
        }
        ranking.sort { $0.score > $1.score }
        if !clippedSlots.isEmpty {
            add(.adcClipped, "\(clippedSlots.joined(separator: ", ")) at the converter limit for ≥ \(Constants.adcClipMinSamples) samples"
                + (ranking.isEmpty ? "" : " (slot left out, others used)"))
        }
        guard let best = ranking.first, let pBest = spectra[best.slot] else {
            if clippedSlots.isEmpty { reasons.append("no optical slot carried a non-zero sample in this window") }
            return done(.unavailable, slot: nil)
        }
        if deltaSlots.contains(best.slot) {
            add(.deltaClipped, "an R26 difference hit ±\(Constants.deltaClipLimit): the waveform after it is lossy")
        }
        // motion
        var p = pBest
        let freqs = grid
        if let acc = accel {
            let idx = acc.t.indices.filter { acc.t[$0] >= a && acc.t[$0] < b }
            if idx.count >= 10 {
                let m = idx.map { acc.mag[$0] }
                let mean = m.reduce(0, +) / Double(m.count)
                let sdG = (m.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(m.count)).squareRoot() / Constants.countsPerG
                var overlap = false
                if sdG >= Constants.motionFloorG {
                    let pa = spectrum(m.map { $0 - mean }, t: idx.map { acc.t[$0] - a })
                    let ka = argmax(pa)
                    let share = bandPower(pa, around: ka) / max(pa.reduce(0, +), .leastNonzeroMagnitude)
                    let kp = argmax(pBest)
                    let fa = freqs[ka], fp = freqs[kp]
                    if share >= Constants.motionPeakShare
                        && [fa, 2 * fa, fa / 2].contains(where: { abs($0 - fp) <= Constants.peakHalfWidthHz }) {
                        overlap = true
                    }
                    // spectral subtraction (TROIKA-style): both spectra normalised to their peak, accel removed
                    if overlap || sdG > Constants.motionSDg {
                        let pm = pBest.max() ?? 1, am = pa.max() ?? 1
                        p = zip(pBest, pa).map { max(0, $0 / pm - $1 / am) }
                    }
                    if overlap {
                        add(.motion, "the accelerometer's \(fmt(fa * 60)) per min swing matches the optical peak "
                            + "(\(fmt(fp * 60)) per min); that peak was removed, the next cardiac candidate used")
                    }
                }
                if sdG > Constants.motionSDg && !overlap {
                    add(.motion, "accelerometer SD \(fmt(sdG)) g over \(Constants.motionSDg) g")
                }
            }
        } else {
            reasons.append("no accelerometer for this window: motion not checked")
        }
        // rate
        var k = argmax(p)
        let snrValue = snr(p, peak: k)
        if snrValue < Constants.minSNR || (p.max() ?? 0) <= 0 {
            add(.lowSNR, "cardiac peak \(fmt(snrValue)) of the rest of the band, under \(Constants.minSNR)")
            return done(.unavailable, slot: best.slot, ranking: ranking)
        }
        let half = nearestIndex(freqs[k] / 2)
        if freqs[k] / 2 >= Constants.hrRange.lowerBound / 60, let h = half, localPeak(p, near: h) >= Constants.fundamentalRatio * p[k] {
            k = localPeakIndex(p, near: h)
        }
        let rivals = peaks(p).filter { j in
            abs(freqs[j] - freqs[k]) > 2 * Constants.peakHalfWidthHz
                && abs(freqs[j] - 2 * freqs[k]) > Constants.peakHalfWidthHz
                && abs(freqs[j] - freqs[k] / 2) > Constants.peakHalfWidthHz
                && p[j] >= Constants.ambiguityRatio * p[k]
        }
        if let rival = rivals.max(by: { p[$0] < p[$1] }) {
            if let prev = previousHR {
                let pick = [k, rival].min { abs(freqs[$0] * 60 - prev) < abs(freqs[$1] * 60 - prev) }!
                add(.rateAmbiguity, "two candidates \(fmt(freqs[k] * 60)) and \(fmt(freqs[rival] * 60)) bpm; "
                    + "kept the one nearer the previous window (\(fmt(prev)) bpm)")
                k = pick
            } else {
                add(.rateAmbiguity, "two candidates \(fmt(freqs[k] * 60)) and \(fmt(freqs[rival] * 60)) bpm and no "
                    + "previous window to choose by")
                return done(.unavailable, slot: best.slot, ranking: ranking)
            }
        }
        let f = refine(p, k)
        let hr = 60 * f
        // beats on the chosen slot, peaks up (orientation by skewness, Elgendi 2016)
        guard let yAll = clean[best.slot] else { return done(.unavailable, slot: best.slot, ranking: ranking) }
        var y = Array(yAll[r])
        if skewness(y) < 0 { y = y.map { -$0 } }
        let beatsA = ALG005.beats(y, fs: fs).map { refineIndex(y, $0) }
        let beatsB = msptd(y, fs: fs).map { refineIndex(y, $0) }
        let matched = match(beatsA, beatsB, tolerance: Constants.beatMatchSeconds * fs)
        let agreement = max(beatsA.count, beatsB.count) == 0 ? 0 : Double(matched.count) / Double(max(beatsA.count, beatsB.count))
        if agreement < Constants.minAgreement {
            add(.peakDisagreement, "the two beat detectors agree on \(Int((agreement * 100).rounded())) % of beats, "
                + "under \(Int(Constants.minAgreement * 100)) %: beat timing withheld")
        }
        // ADC_CLIPPED on a slot that was left out does not touch the slot used
        let soft = gates.contains { $0 != .adcClipped }
        var conf = snrValue / (1 + snrValue)
        if soft { conf *= Constants.reducedConfidence }
        var ibis: [IBI] = []
        if !soft {
            let period = 1 / f
            for j in matched.indices.dropFirst() {
                let dt = (matched[j] - matched[j - 1]) / fs
                guard Constants.ibiPeriodRange.contains(dt / period) else { continue }
                ibis.append(IBI(t: a + matched[j] / fs, ms: dt * 1000, slot: best.slot))
            }
        } else {
            reasons.append("intervals withheld: a soft gate is set in this window")
        }
        return done(soft ? .reduced : .measured, slot: best.slot, ranking: ranking, hr: hr, conf: conf,
                    agreement: agreement, ibis: ibis)
    }

    // MARK: filtering

    /// 2nd-order Butterworth biquad (Q = 1/√2), Audio EQ Cookbook coefficients normalised by a0.
    struct Biquad {
        var b0, b1, b2, a1, a2: Double

        static func make(lowPass: Bool, fc: Double, fs: Double) -> Biquad {
            let w = 2 * Double.pi * fc / fs
            let alpha = sin(w) / (2 * (1 / 2.0.squareRoot()))
            let c = cos(w)
            let a0 = 1 + alpha
            if lowPass {
                return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
            }
            return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }

        /// Direct form II transposed.
        func run(_ x: [Double]) -> [Double] {
            var z1 = 0.0, z2 = 0.0
            return x.map { v in
                let y = b0 * v + z1
                z1 = b1 * v - a1 * y + z2
                z2 = b2 * v - a2 * y
                return y
            }
        }
    }

    /// Zero-phase 0.5–4 Hz band-pass: mean removed, odd reflection padding (up to 4 s each side), high-pass then
    /// low-pass forward, the same backward, padding cut.
    public static func bandPass(_ x: [Double], fs: Double) -> [Double] {
        guard x.count >= 3 else { return x.map { _ in 0 } }
        let mean = x.reduce(0, +) / Double(x.count)
        let c = x.map { $0 - mean }
        let pad = min(c.count - 1, Int(2 * fs / Constants.bandLowHz))
        let head = (1...max(1, pad)).reversed().map { 2 * c[0] - c[min($0, c.count - 1)] }
        let tail = (1...max(1, pad)).map { 2 * c[c.count - 1] - c[max(0, c.count - 1 - $0)] }
        let padded = (pad > 0 ? head : []) + c + (pad > 0 ? tail : [])
        let hp = Biquad.make(lowPass: false, fc: Constants.bandLowHz, fs: fs)
        let lp = Biquad.make(lowPass: true, fc: Constants.bandHighHz, fs: fs)
        let forward = lp.run(hp.run(padded))
        let backward = Array(lp.run(hp.run(forward.reversed())).reversed())
        return Array(backward[pad..<(pad + c.count)])
    }

    // MARK: spectra

    /// Frequencies searched: the heart-rate range on a 0.02 Hz grid.
    static let grid: [Double] = {
        let lo = Constants.hrRange.lowerBound / 60, hi = Constants.hrRange.upperBound / 60
        return Array(stride(from: lo, through: hi + 1e-9, by: Constants.spectralStepHz))
    }()

    /// Hann-weighted power at each grid frequency, using each sample's own time (no assumed spacing).
    static func spectrum(_ x: [Double], t: [Double]) -> [Double] {
        let n = x.count
        guard n > 1 else { return grid.map { _ in 0 } }
        let mean = x.reduce(0, +) / Double(n)
        let w = (0..<n).map { (x[$0] - mean) * (0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1))) }
        return grid.map { f in
            var re = 0.0, im = 0.0
            let om = 2 * Double.pi * f
            for i in 0..<n {
                re += w[i] * cos(om * t[i])
                im -= w[i] * sin(om * t[i])
            }
            return re * re + im * im
        }
    }

    static func argmax(_ p: [Double]) -> Int {
        p.indices.max { p[$0] < p[$1] } ?? 0
    }

    static func bandPower(_ p: [Double], around k: Int) -> Double {
        let h = Int((Constants.peakHalfWidthHz / Constants.spectralStepHz).rounded())
        return p[max(0, k - h)...min(p.count - 1, k + h)].reduce(0, +)
    }

    static func nearestIndex(_ f: Double) -> Int? {
        let k = Int(((f - grid[0]) / Constants.spectralStepHz).rounded())
        return grid.indices.contains(k) ? k : nil
    }

    /// Peak (+ 2nd harmonic when on the grid) band power over the rest.
    static func snr(_ p: [Double], peak k: Int) -> Double {
        let total = p.reduce(0, +)
        guard total > 0 else { return 0 }
        var sig = bandPower(p, around: k)
        if let h = nearestIndex(2 * grid[k]) {        // 2f − f ≥ 0.5 Hz: the two bands never overlap
            sig += bandPower(p, around: h)
        }
        return sig / max(total - sig, total * 1e-6)
    }

    static func peaks(_ p: [Double]) -> [Int] {
        guard p.count >= 3 else { return [] }
        return (1..<(p.count - 1)).filter { p[$0] > p[$0 - 1] && p[$0] >= p[$0 + 1] }
    }

    static func localPeakIndex(_ p: [Double], near k: Int) -> Int {
        let h = Int((Constants.peakHalfWidthHz / Constants.spectralStepHz).rounded())
        let lo = max(0, k - h), hi = min(p.count - 1, k + h)
        return (lo...hi).max { p[$0] < p[$1] } ?? k
    }

    static func localPeak(_ p: [Double], near k: Int) -> Double {
        p[localPeakIndex(p, near: k)]
    }

    /// Parabolic interpolation of the peak frequency.
    static func refine(_ p: [Double], _ k: Int) -> Double {
        guard k > 0, k < p.count - 1 else { return grid[k] }
        let den = p[k - 1] - 2 * p[k] + p[k + 1]
        let d = den != 0 ? 0.5 * (p[k - 1] - p[k + 1]) / den : 0
        return grid[k] + max(-0.5, min(0.5, d)) * Constants.spectralStepHz
    }

    // MARK: beats

    /// MSPTD peaks (Bishop & Ercole 2018): local-maxima scalogram over scales 1…L, the scale with the most maxima λ,
    /// peaks = maxima at every scale up to λ. Scales capped at half the slowest heart period (MSPTDfast-style).
    static func msptd(_ x: [Double], fs: Double) -> [Int] {
        let n = x.count
        guard n >= 5 else { return [] }
        let y = SignalMath.linearDetrend(t: (0..<n).map(Double.init), y: x)
        let lMax = min(Int(ceil(Double(n) / 2)) - 1, Int(ceil(fs * 60 / Constants.hrRange.lowerBound / 2)))
        guard lMax >= 1 else { return [] }
        func isMax(_ i: Int, _ k: Int) -> Bool { i - k >= 0 && i + k < n && y[i] > y[i - k] && y[i] > y[i + k] }
        var gamma = [Int](repeating: 0, count: lMax + 1)
        for k in 1...lMax { for i in k..<(n - k) where isMax(i, k) { gamma[k] += 1 } }
        let lambda = (1...lMax).max { gamma[$0] < gamma[$1] || (gamma[$0] == gamma[$1] && $0 > $1) } ?? 1
        return (0..<n).filter { i in (1...lambda).allSatisfy { isMax(i, $0) } }
    }

    /// Fractional sample index of a peak (parabola through its three samples).
    static func refineIndex(_ y: [Double], _ i: Int) -> Double {
        guard i > 0, i < y.count - 1 else { return Double(i) }
        let den = y[i - 1] - 2 * y[i] + y[i + 1]
        return Double(i) + (den != 0 ? max(-0.5, min(0.5, 0.5 * (y[i - 1] - y[i + 1]) / den)) : 0)
    }

    /// Beats both detectors found (greedy, in time order), as the mean of the two positions.
    static func match(_ a: [Double], _ b: [Double], tolerance: Double) -> [Double] {
        var out: [Double] = []
        var j = 0
        for v in a {
            while j < b.count && b[j] < v - tolerance { j += 1 }
            if j < b.count && abs(b[j] - v) <= tolerance {
                out.append((v + b[j]) / 2)
                j += 1
            }
        }
        return out
    }

    static func skewness(_ x: [Double]) -> Double {
        let n = Double(x.count)
        guard n > 2 else { return 0 }
        let m = x.reduce(0, +) / n
        var m2 = 0.0, m3 = 0.0
        for v in x { m2 += (v - m) * (v - m); m3 += (v - m) * (v - m) * (v - m) }
        m2 /= n
        m3 /= n
        return m2 > 0 ? m3 / pow(m2, 1.5) : 0
    }

    static func fmt(_ v: Double) -> String {
        String(format: v.magnitude >= 10 ? "%.0f" : "%.2f", v)
    }

    // MARK: night metric (primary pulse HR)

    public struct Night: Sendable, Equatable {
        public var hr: Double
        public var windowsUsed: Int
        public var windowsMeasured: Int
        public var windowsTotal: Int
        public var ibis: Int
    }

    /// Median of the window heart rates (measured + reduced) inside the sleep period, from the v26 PPG.
    public static func night(_ blocks: [PPGBlock], start: Int64, end: Int64) -> Computed<Night> {
        let inside = blocks.filter { $0.ts >= start && $0.ts < end }
        guard !inside.isEmpty else {
            return .missing("no v26 PPG records in the sleep period (the strap writes them on some nights only)")
        }
        let o = analyse(ppg: inside)
        let hrs = o.hrEstimated.map(\.bpm)
        guard !hrs.isEmpty else {
            var counts: [String: Int] = [:]
            for w in o.windows { for g in w.gates { counts[g.rawValue, default: 0] += 1 } }
            let why = counts.isEmpty ? "every run shorter than one 8-s window"
                : counts.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            return .missing("\(o.windows.count) PPG windows, none with a usable pulse (\(why))")
        }
        return .success(Night(hr: SignalMath.median(hrs), windowsUsed: hrs.count,
                              windowsMeasured: o.hrEstimated.filter { $0.state == .measured }.count,
                              windowsTotal: o.windows.count, ibis: o.ibiAccepted.count))
    }

    /// The same night median from the raw R20 records (D-HRV-WALK-1: ALG-144 reads R20 where the v26 PPG is not there).
    public static func night(r20: [R20Record], start: Int64, end: Int64) -> Computed<Night> {
        let inside = r20.filter { $0.ts >= start && $0.ts < end }
        guard !inside.isEmpty else { return .missing("no raw optical (R20) in the sleep period") }
        let o = analyse(r20: inside)
        let hrs = o.hrEstimated.map(\.bpm)
        guard !hrs.isEmpty else { return .missing("\(o.windows.count) R20 windows, none with a usable pulse") }
        return .success(Night(hr: SignalMath.median(hrs), windowsUsed: hrs.count,
                              windowsMeasured: o.hrEstimated.filter { $0.state == .measured }.count,
                              windowsTotal: o.windows.count, ibis: o.ibiAccepted.count))
    }

    public static let hrSpec = MetricSpec(
        key: .ppgHr, unit: "bpm", group: nil, variant: variant,
        method: "ALG-144@1 v26 PPG band-pass 0.5-4 Hz zero-phase, gated 8-s windows, spectral HR, median of windows",
        tier: .research, source: "v26 ppg", window: "night", producer: .ours, citation: citation,
        paramsVersion: "win8s snr0.4 amb0.8 agree0.8 rate=timestamps (engineering starting values)")

    public static func metrics(_ n: Computed<Night>, at: Date) -> [Metric] {
        let note = n.value.map {
            "\($0.windowsUsed) of \($0.windowsTotal) 8-s windows usable (\($0.windowsMeasured) with no quality gate); "
                + "\($0.ibis) accepted pulse intervals; primary pulse HR (ALG-108 kept as a variant); decoded, untested"
        }
        return [hrSpec.metric(n.map(\.hr), at: at, note: note)]
    }
}
