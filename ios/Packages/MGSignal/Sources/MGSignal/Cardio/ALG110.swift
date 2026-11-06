import Foundation
import MGDomain

/// ALG-110 v1 — skin-temperature deviation from the personal baseline, reported at BOTH disputed raw scales.
/// The strap's register (R18 byte 73 / inner 65) is a raw count: /100 per noop PROTOCOL_SENSORS.md, /128 per
/// Samirad-code/noop-whoop from AS6221 behaviour (FINDINGS.md: disputed, "claimed"). Nothing here is degrees
/// (BRIEF: raw counts are not units); units are `raw_div_100` and `raw_div_128`. The ambient-corrected variant (Fitbit
/// US 11737675 approach) needs an ambient reading and is not built. Python reference: app/pclab/mglab/ref/cardio.py
/// `skin_temp_night`, `skin_temp_deviation`; goldens app/shared/golden/cardio/ALG-110.json.
public enum ALG110 {
    public static let citation = "OpenStrap tempIllness (robust z); ALG-075 robust z; FINDINGS.md R18 scale dispute"
    /// 5–45 °C under either scale (/100 → 500–4500, /128 → 640–5760): the union (whoop-rs gen5.rs keeps raw/100 in
    /// 5..45 °C).
    public static let validRaw: ClosedRange<Double> = 500.0...5760.0
    public static let scale100 = 100.0
    public static let scale128 = 128.0
    /// 5 min of 1 Hz samples in the window (ours).
    public static let minSamples = 300
    public static let baselineNights = 28
    /// UX 12 "Learning your normal" (as ALG-101).
    public static let minNights = 14
    /// ALG-075 robust z = (x − median) / (1.4826 · MAD).
    public static let madK = 1.4826

    public struct Night: Sendable, Equatable {
        public var rawMedian: Double
        public var samples: Int

        public init(rawMedian: Double, samples: Int) {
            self.rawMedian = rawMedian
            self.samples = samples
        }
    }

    /// ALG-110 v1 night value: median raw register over [start, end) of samples inside 500–5760 raw. Missing with
    /// fewer than 300 valid samples.
    public static func night(ts: [Int64], raw: [Int?], start: Int64, end: Int64) -> Computed<Night> {
        var vals: [Double] = []
        for i in 0..<min(ts.count, raw.count) where ts[i] >= start && ts[i] < end {
            if let r = raw[i], validRaw.contains(Double(r)) { vals.append(Double(r)) }
        }
        guard vals.count >= minSamples else {
            return .missing("needs \(minSamples) on-wrist skin-temperature samples (have \(vals.count))")
        }
        return .success(Night(rawMedian: SignalMath.median(vals), samples: vals.count))
    }

    /// T9746: a PAST night's raw median rebuilt from its stored seconds, over the seconds the strap's own flag called
    /// asleep (R18 byte 81 nibble 2) inside `start ..< end`, so a night that was never run through the pipeline can still
    /// join the baseline (MS-21 needs 14 nights). Same validity range and minimum as `night`. nil with the reason that
    /// `night` gives when there are too few asleep samples.
    public static func nightWhileStrapAsleep(r18: [R18Second], start: Int64, end: Int64) -> Computed<Night> {
        let asleep = r18.filter { $0.sleepState == 2 }
        return night(ts: asleep.map(\.ts), raw: asleep.map(\.skinTempRaw), start: start, end: end)
    }

    /// The same from R18 records.
    public static func night(r18: [R18Second], start: Int64, end: Int64) -> Computed<Night> {
        night(ts: r18.map(\.ts), raw: r18.map(\.skinTempRaw), start: start, end: end)
    }

    public struct Deviation: Sendable, Equatable {
        public var devRaw: Double
        public var devDiv100: Double
        public var devDiv128: Double
        /// Scale-free, so the same at /100 and /128; missing when the baseline has no spread (MAD 0).
        public var robustZ: Computed<Double>
        public var baselineMedianRaw: Double
        public var nights: Int

        public init(devRaw: Double, devDiv100: Double, devDiv128: Double, robustZ: Computed<Double>,
                    baselineMedianRaw: Double, nights: Int) {
            self.devRaw = devRaw
            self.devDiv100 = devDiv100
            self.devDiv128 = devDiv128
            self.robustZ = robustZ
            self.baselineMedianRaw = baselineMedianRaw
            self.nights = nights
        }
    }

    /// ALG-110 v1 — tonight's raw median against the previous ≤ 28 nights that have one (needs 14). `nightRaw` oldest →
    /// newest, last = tonight, nil = no value that night. dev_raw = tonight − baseline median, reported /100 and /128.
    public static func deviation(nightRaw: [Double?]) -> Computed<Deviation> {
        guard let last = nightRaw.last else { return .missing("no nights") }
        guard let today = last, today.isFinite else { return .missing("no skin temperature tonight") }
        let base = nightRaw.dropLast().suffix(baselineNights).compactMap { $0 }.filter(\.isFinite)
        guard base.count >= minNights else {
            return .missing("Learning your normal: \(base.count) of \(minNights) nights so far")
        }
        let med = SignalMath.median(base)
        let mad = SignalMath.median(base.map { abs($0 - med) })
        let dev = today - med
        let z: Computed<Double> = mad > 0 ? .success(dev / (madK * mad)) : .missing("baseline has no spread (MAD 0)")
        return .success(Deviation(devRaw: dev, devDiv100: dev / scale100, devDiv128: dev / scale128, robustZ: z,
                                  baselineMedianRaw: med, nights: base.count))
    }

    public static let spec100 = MetricSpec(
        key: .skinTempDev, unit: "raw_div_100", group: "G-TEMP", variant: "ALG-110:100",
        method: "ALG-110@1 raw-median-vs-28n-median /100", tier: .relative, source: "r18", window: "night",
        citation: citation, paramsVersion: "valid500-5760 min300 base28 min14")
    public static let spec128 = MetricSpec(
        key: .skinTempDev, unit: "raw_div_128", group: "G-TEMP", variant: "ALG-110:128",
        method: "ALG-110@1 raw-median-vs-28n-median /128", tier: .relative, source: "r18", window: "night",
        citation: citation, paramsVersion: "valid500-5760 min300 base28 min14")

    /// D-POP-PRIOR (r9t): the baseline is ONLY his own nights. A raw count has no published population value (the register is
    /// uncalibrated, /100 vs /128 disputed), so there is no population number to start from: before `minNights` nights
    /// the deviation is blank with 'Learning your normal', then it shows as 'yours (N nights)' (`PersonalBasis`).
    /// Both members of G-TEMP (blank with the reason when missing). The note carries the robust z (scale-free).
    public static func metrics(_ d: Computed<Deviation>, at: Date) -> [Metric] {
        let note = d.value.map { dv in
            "raw counts, not degrees C; robust z " + (dv.robustZ.value.map { String(format: "%.2f", $0) }
                                                      ?? (dv.robustZ.missingReason ?? "n/a"))
                + "; " + PersonalBasis.nightsWords(dv.nights)
                + "; skin temperature is decoded, untested (raw / 100 read as degrees C)"
        }
        return [spec100.metric(d.map(\.devDiv100), at: at, note: note),
                spec128.metric(d.map(\.devDiv128), at: at, note: note)]
    }
}
