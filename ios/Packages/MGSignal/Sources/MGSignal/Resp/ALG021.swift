import Foundation
import MGDomain

/// ALG-021 v1 — the strap's own SpO₂ byte (R18 frame byte 82 = inner 74), passed through as a RAW STRAP VALUE.
/// Tri-mode (whoop-rs whoop-protocol/src/records/gen5.rs v18 @d11d8ef; FINDINGS.md §2): 70–100 is a reading, bit-7
/// values (≥ 128) are saturation sentinels, values under 70 are diagnostic codes (0 = no reading). The strap fires a
/// 30-s window every 20 min while asleep. Decoded, NOT validated against an oximeter: unit "count", label "strap value,
/// not yet checked", never shown as % (BRIEF: raw counts are not units; registry spo2_strap_* "raw byte, no %").
/// Python reference: app/pclab/mglab/ref/resp.py `spo2_byte_mode`, `spo2_night`; goldens
/// app/shared/golden/resp/ALG-021.json.
public enum ALG021 {
    public static let citation = "whoop-rs gen5.rs v18 spo2 tri-mode @d11d8ef; DX23876/noop validate_spo2_candidate.py"
    public static let readingRange: ClosedRange<Int> = 70...100
    public static let sentinelMin = 128
    /// Readings closer than this belong to one burst.
    public static let burstGapSeconds: Int64 = 60
    public static let label = "strap value, not yet checked"

    public enum Mode: String, Sendable, CaseIterable {
        /// 70–100: the strap's value (raw, not a percentage).
        case reading = "reading"
        /// ≥ 128 (bit 7): saturation sentinel.
        case sentinel = "sentinel"
        /// < 70: diagnostic code (0 = no reading).
        case code = "code"
        /// 101–127: none of the three documented modes.
        case unclassified = "unclassified"
        /// No byte in the record.
        case absent = "none"
    }

    /// ALG-021 v1 tri-mode decode of one byte.
    public static func mode(_ byte: Int?) -> Mode {
        guard let v = byte else { return .absent }
        if readingRange.contains(v) { return .reading }
        if v >= sentinelMin { return .sentinel }
        if v < readingRange.lowerBound { return .code }
        return .unclassified
    }

    public struct Night: Sendable, Equatable {
        /// Mean of the reading bytes (raw count).
        public var mean: Double
        /// Lowest reading byte (raw count).
        public var lowest: Double
        public var readings: Int
        public var bursts: Int
        public var modes: [Mode: Int]
        public var label: String

        public init(mean: Double, lowest: Double, readings: Int, bursts: Int, modes: [Mode: Int],
                    label: String = ALG021.label) {
            self.mean = mean
            self.lowest = lowest
            self.readings = readings
            self.bursts = bursts
            self.modes = modes
            self.label = label
        }
    }

    /// ALG-021 v1 night summary over [start, end) (the sleep window): mean and lowest of the reading bytes, counts of
    /// every mode, bursts = runs of readings less than 60 s apart. Missing with no reading.
    public static func night(ts: [Int64], bytes: [Int?], start: Int64, end: Int64) -> Computed<Night> {
        var modes: [Mode: Int] = [:]
        for m in Mode.allCases { modes[m] = 0 }
        var reads: [(Int64, Int)] = []
        for i in 0..<min(ts.count, bytes.count) where ts[i] >= start && ts[i] < end {
            let m = mode(bytes[i])
            modes[m, default: 0] += 1
            if m == .reading, let b = bytes[i] { reads.append((ts[i], b)) }
        }
        guard !reads.isEmpty else {
            return .missing("no strap SpO2 readings in the window (the strap measures only asleep, 30 s every 20 min)")
        }
        reads.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        var bursts = 1
        for i in 1..<reads.count where reads[i].0 - reads[i - 1].0 >= burstGapSeconds { bursts += 1 }
        let vals = reads.map { Double($0.1) }
        return .success(Night(mean: SignalMath.mean(vals), lowest: vals.min()!, readings: vals.count, bursts: bursts,
                              modes: modes))
    }

    /// The same from R18 records.
    public static func night(r18: [R18Second], start: Int64, end: Int64) -> Computed<Night> {
        night(ts: r18.map(\.ts), bytes: r18.map(\.spo2Byte), start: start, end: end)
    }

    public static let meanSpec = MetricSpec(
        key: .spo2StrapMean, unit: "count", group: "G-SPO2", variant: "ALG-021", method: "ALG-021@1 strap-byte-mean",
        tier: .strap, source: "r18", window: "night", producer: .strap, citation: citation,
        paramsVersion: "reading70-100 sentinel>=128 code<70")
    public static let minSpec = MetricSpec(
        key: .spo2StrapMin, unit: "count", group: "G-SPO2", variant: "ALG-021", method: "ALG-021@1 strap-byte-lowest",
        tier: .strap, source: "r18", window: "night", producer: .strap, citation: citation,
        paramsVersion: "reading70-100 sentinel>=128 code<70")

    /// `spo2_strap_mean` and `spo2_strap_min` — raw strap counts with the "not yet checked" label in the note.
    public static func metrics(_ n: Computed<Night>, at: Date) -> [Metric] {
        let note = "\(label); raw byte, not %"
        return [meanSpec.metric(n.map(\.mean), at: at, note: note), minSpec.metric(n.map(\.lowest), at: at, note: note)]
    }
}
