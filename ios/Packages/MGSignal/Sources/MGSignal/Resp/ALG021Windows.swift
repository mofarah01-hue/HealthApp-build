import Foundation
import MGDomain

/// ALG-021:windows v1 (wave 4, 2026-10-11, #25) — the strap's own SpO₂ byte (R18 frame byte 82 = inner 74) summarised
/// the way noop's per-device promotion gate summarises it, so the phone's nightly value and the PC's gate
/// (app/pclab/mglab/alg/spo2_gate.py) are the same number. Ported from ryanbr/noop @ e580175
/// Tools/linux-capture/validate_spo2_candidate.py: `detect_duty_cycle` L543-608, `in_duty_window` / `window_index`
/// L611-620, `duty_windows_in` L623-635, `night_window_coverage` L638-656, `night_mean_at_offset` L659-696.
///
/// Only records the band marks asleep (byte 81 high nibble = 2) count, only bytes 70–100, only inside the strap's own
/// repeating window — measured from the records (period, phase, length), never assumed — and the night is the mean of
/// the per-window means (one 30-s firing is one measurement). Nonzero bytes outside 70–100 (0x80, 0xA0, 0x20 …; bit 7
/// may be a flag, CAPABILITIES "Optical, SpO₂ and R22") are kept raw, by value, in `flags`. Still a RAW STRAP VALUE:
/// unit "count", never % (rule 4) — the phone shows a % only after the PC's gate passed for this strap (MGContext
/// `SpO2Gate`). Python reference: app/pclab/mglab/ref/resp.py `spo2_duty`, `spo2_windows_night`; goldens
/// app/shared/golden/resp/ALG-021W.json. Decoded, untested on Mo's strap.
public enum ALG021Windows {
    public static let citation = "noop validate_spo2_candidate.py L543-696 @e580175 (ALG-021:windows)"
    public static let variant = "ALG-021:windows"
    public static let asleep = 2
    static let continuousFraction = 0.5
    static let minDutyWindows = 3
    public static let minWindowCoverage = 0.5

    public enum Mode: String, Sendable {
        case absent = "absent"
        case continuous = "continuous"
        case dutyCycled = "duty_cycled"
        case irregular = "irregular"
    }

    /// The byte's on/off schedule measured from the records (noop `detect_duty_cycle`).
    public struct Duty: Sendable, Equatable {
        public var mode: Mode
        public var records: Int
        public var nonzero: Int
        public var recordIntervalS: Double
        public var periodS: Int64?
        public var phaseS: Int64?
        public var windowLenS: Int64?
        public var windowsObserved: Int
        public var windowLenStable: Bool?
        public var phaseJitterS: Int64?

        public var isCycled: Bool { mode == .dutyCycled }

        /// (u − phase) mod period < length — a positive modulo (Swift's % keeps the dividend's sign).
        public func inWindow(_ u: Int64) -> Bool {
            guard isCycled, let p = periodS, let ph = phaseS, let w = windowLenS else { return false }
            return ALG021Windows.mod(u - ph, p) < w
        }

        /// ⌊(u − phase) / period⌋.
        public func windowIndex(_ u: Int64) -> Int64 {
            guard let p = periodS, let ph = phaseS else { return 0 }
            return ALG021Windows.floorDiv(u - ph, p)
        }

        /// The windows whose START falls in [start, end) (noop `duty_windows_in`).
        public func windows(start: Int64, end: Int64) -> [Int64] {
            guard isCycled, let p = periodS, let ph = phaseS, end > start, (end - start) / p <= 100_000 else { return [] }
            var out: [Int64] = []
            var s = start + ALG021Windows.mod(ph - start, p)
            while s < end {
                out.append(s)
                s += p
            }
            return out
        }
    }

    public struct Night: Sendable, Equatable {
        /// Mean of the per-window means (raw count; per-sample mean when the byte is not duty-cycled).
        public var mean: Double
        /// Lowest per-window mean (ours; lowest sample when not duty-cycled).
        public var lowest: Double
        public var readings: Int
        public var windowsWithReadings: Int?
        public var windowsSampled: Int?
        public var windowsExpected: Int?
        public var coverage: Double?
        public var duty: Duty
        /// Nonzero bytes outside 70–100 in the night, by value (raw; never in the mean).
        public var flags: [(value: Int, count: Int)]

        public static func == (a: Night, b: Night) -> Bool {
            a.mean == b.mean && a.lowest == b.lowest && a.readings == b.readings
                && a.windowsWithReadings == b.windowsWithReadings && a.windowsSampled == b.windowsSampled
                && a.windowsExpected == b.windowsExpected && a.coverage == b.coverage && a.duty == b.duty
                && a.flags.map(\.value) == b.flags.map(\.value) && a.flags.map(\.count) == b.flags.map(\.count)
        }
    }

    static func mod(_ a: Int64, _ m: Int64) -> Int64 {
        let r = a % m
        return r < 0 ? r + m : r
    }

    static func floorDiv(_ a: Int64, _ m: Int64) -> Int64 {
        let q = a / m
        return (a % m != 0 && (a < 0) != (m < 0)) ? q - 1 : q
    }

    /// noop `detect_duty_cycle`: nothing about the schedule is hard-coded.
    public static func duty(ts: [Int64], bytes: [Int?]) -> Duty {
        let n = min(ts.count, bytes.count)
        let stampsAll = Array(Set(ts.prefix(n))).sorted()
        var deltas: [Double] = []
        for i in stampsAll.indices.dropFirst() where stampsAll[i] > stampsAll[i - 1] {
            deltas.append(Double(stampsAll[i] - stampsAll[i - 1]))
        }
        let interval = deltas.isEmpty ? 1.0 : SignalMath.median(deltas)
        let tol = max(2.0 * interval, 2.0)
        var nonzero: [Int64] = []
        for i in 0..<n {
            if let b = bytes[i], b != 0 { nonzero.append(ts[i]) }
        }
        var d = Duty(mode: .absent, records: n, nonzero: nonzero.count, recordIntervalS: interval, periodS: nil,
                     phaseS: nil, windowLenS: nil, windowsObserved: 0, windowLenStable: nil, phaseJitterS: nil)
        guard !nonzero.isEmpty else { return d }
        if Double(nonzero.count) / Double(n) >= continuousFraction {
            d.mode = .continuous
            return d
        }
        let stamps = Array(Set(nonzero)).sorted()
        var runs: [[Int64]] = [[stamps[0]]]
        for i in stamps.indices.dropFirst() {
            if Double(stamps[i] - stamps[i - 1]) <= tol {
                runs[runs.count - 1].append(stamps[i])
            } else {
                runs.append([stamps[i]])
            }
        }
        let spans = runs.map { Double($0.last! - $0.first! + 1) }
        let starts = runs.map { $0.first! }
        d.windowsObserved = runs.count
        let wlen = Int64(SignalMath.median(spans))          // Python int(): toward zero, values are positive
        d.windowLenS = wlen
        d.windowLenStable = Set(spans).count == 1
        guard starts.count >= minDutyWindows else {
            d.mode = .irregular
            return d
        }
        var gaps: [Double] = []
        for i in starts.indices.dropFirst() { gaps.append(Double(starts[i] - starts[i - 1])) }
        let period = Int64(SignalMath.median(gaps))
        guard period > wlen else {
            d.mode = .irregular
            return d
        }
        func circ(_ a: Int64, _ b: Int64) -> Int64 {
            let x = abs(a - b) % period
            return min(x, period - x)
        }
        let phases = starts.map { mod($0, period) }
        var phase = phases[0]
        var best = phases.reduce(Int64(0)) { $0 + circ(phase, $1) }
        for p in phases.dropFirst() {                       // circular medoid; the first of equals wins (Python min)
            let cost = phases.reduce(Int64(0)) { $0 + circ(p, $1) }
            if cost < best {
                phase = p
                best = cost
            }
        }
        let jitter = phases.map { circ($0, phase) }.max() ?? 0
        d.periodS = period
        d.phaseS = phase
        d.phaseJitterS = jitter
        d.mode = Double(jitter) <= max(tol, 1) ? .dutyCycled : .irregular
        return d
    }

    /// The night [start, end): see the type's comment. `duty` defaults to the schedule measured over the records given.
    public static func night(ts: [Int64], bytes: [Int?], sleepState: [Int?], start: Int64, end: Int64,
                             duty given: Duty? = nil) -> Computed<Night> {
        let duty = given ?? self.duty(ts: ts, bytes: bytes)
        let cycled = duty.isCycled
        var perWindow: [Int64: [Double]] = [:]
        var readings = 0
        var lowestSample = Double.infinity
        var sampleSum = 0.0
        var flags: [Int: Int] = [:]
        var sampled = Set<Int64>()
        let n = min(ts.count, bytes.count, sleepState.count)
        for i in 0..<n {
            let t = ts[i]
            guard t >= start, t < end else { continue }
            if cycled, duty.inWindow(t) { sampled.insert(duty.windowIndex(t)) }
            if let b = bytes[i], b != 0, !ALG021.readingRange.contains(b) { flags[b, default: 0] += 1 }
            guard sleepState[i] == asleep, let b = bytes[i], ALG021.readingRange.contains(b) else { continue }
            if cycled {
                guard duty.inWindow(t) else { continue }
                perWindow[duty.windowIndex(t), default: []].append(Double(b))
            }
            readings += 1
            sampleSum += Double(b)
            lowestSample = min(lowestSample, Double(b))
        }
        let expected = Set(duty.windows(start: start, end: end).map { duty.windowIndex($0) })
        let covered = expected.isEmpty ? nil : sampled.intersection(expected).count
        let coverage = covered.map { Double($0) / Double(expected.count) }
        guard readings > 0 else {
            return .missing("no in-band strap SpO₂ byte while the band said asleep" + (cycled ? " inside its windows" : "")
                            + " (duty cycle: \(duty.mode.rawValue))")
        }
        let mean: Double
        let lowest: Double
        if cycled {
            let wmeans = perWindow.keys.sorted().map { SignalMath.mean(perWindow[$0]!) }
            mean = SignalMath.mean(wmeans)
            lowest = wmeans.min()!
        } else {
            mean = sampleSum / Double(readings)
            lowest = lowestSample
        }
        return .success(Night(mean: mean, lowest: lowest, readings: readings,
                              windowsWithReadings: cycled ? perWindow.count : nil, windowsSampled: covered,
                              windowsExpected: expected.isEmpty ? nil : expected.count, coverage: coverage, duty: duty,
                              flags: flags.keys.sorted().map { ($0, flags[$0]!) }))
    }

    /// The same from R18 records. `dutySpan` rows (the whole search span) measure the schedule; the night is [start, end).
    public static func night(r18: [R18Second], dutySpan: [R18Second]? = nil, start: Int64, end: Int64) -> Computed<Night> {
        let span = dutySpan ?? r18
        let d = duty(ts: span.map(\.ts), bytes: span.map(\.spo2Byte))
        return night(ts: r18.map(\.ts), bytes: r18.map(\.spo2Byte), sleepState: r18.map(\.sleepState), start: start,
                     end: end, duty: d)
    }

    public static let meanSpec = MetricSpec(
        key: .spo2StrapMean, unit: "count", group: "G-SPO2", variant: variant,
        method: "ALG-021:windows@1 mean of per-window means, asleep, in the strap's window", tier: .strap,
        source: "r18", window: "night", producer: .strap, citation: citation,
        paramsVersion: "asleep=2 inband70-100 continuous>=0.5 minwindows3")
    public static let minSpec = MetricSpec(
        key: .spo2StrapMin, unit: "count", group: "G-SPO2", variant: variant,
        method: "ALG-021:windows@1 lowest per-window mean", tier: .strap, source: "r18", window: "night",
        producer: .strap, citation: citation, paramsVersion: "asleep=2 inband70-100 continuous>=0.5 minwindows3")

    /// "0x80 ×3, 0xA0 ×1" — the raw flag bytes of a night.
    public static func flagText(_ flags: [(value: Int, count: Int)]) -> String {
        flags.map { String(format: "0x%02X", $0.value) + " ×\($0.count)" }.joined(separator: ", ")
    }

    /// `spo2_strap_mean` / `spo2_strap_min` variant ALG-021:windows — raw counts. The note says how much of the night's
    /// schedule was sampled and which flag bytes appeared; the coverage field is the window coverage.
    public static func metrics(_ n: Computed<Night>, at: Date) -> [Metric] {
        var note = "\(ALG021.label); raw byte, not %"
        var coverage: Double?
        if let v = n.value {
            var parts: [String] = []
            if let s = v.windowsSampled, let e = v.windowsExpected {
                parts.append("\(s) of \(e) strap windows sampled")
                if let c = v.coverage, c < minWindowCoverage { parts.append("low coverage: the mean means little") }
            } else {
                parts.append("no repeating window detected (\(v.duty.mode.rawValue)): every asleep in-band byte counts")
            }
            if let w = v.windowsWithReadings { parts.append("\(w) windows with readings") }
            if let p = v.duty.periodS, let ph = v.duty.phaseS, let l = v.duty.windowLenS {
                parts.append("window \(l) s at unix % \(p) = \(ph)")
            }
            if !v.flags.isEmpty { parts.append("flag bytes kept raw: " + flagText(v.flags)) }
            note += "; " + parts.joined(separator: "; ")
            coverage = v.coverage
        }
        return [meanSpec.metric(n.map(\.mean), at: at, coverage: coverage, note: note),
                minSpec.metric(n.map(\.lowest), at: at, coverage: coverage, note: note)]
    }
}
