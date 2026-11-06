import Foundation
import MGDomain

/// Wave 4 (2026-10-11) — the strap's own per-second optical signal-quality fields (R18 `R18Quality`: saturation bits,
/// pSNR dB, log-variance; OpenStrap protocol gen5_records.dart L339-358, L388-430 @6e8c570) summarised over the sleep
/// period: share of seconds with a saturated photodiode, median pSNR (mean of the two detectors when both report),
/// median log-variance. Decoded, untested: research tier, variant "strap" (the band's own numbers, passed through).
public enum R18QualityNight {
    public static let citation = "OpenStrap gen5_records.dart L339-358, L388-430 @6e8c570 (R18 quality fields)"

    public struct Night: Sendable, Equatable {
        public var seconds: Int
        public var saturatedShare: Double
        public var psnrMedian: Double?
        public var logVarMedian: Double?
        /// True when `saturatedShare` came from raw optical (R20) converter-limit counting because the night's R18
        /// records carry no quality bits (B-2 / b-15, Oct 14 2026). pSNR and log-variance are then blank.
        public var fromRawOptical: Bool = false
    }

    /// Why the saturated row is blank when neither source exists. Names both inputs so Mo can see which one is missing.
    public static let nothingReason = "no optical signal-quality fields in this night's R18 (stored before wave 4, or not a 5.0 / MG) and no raw optical (R20) stored for the night (PPG research switch was off)"

    /// B-2 fallback: share of R20 records (1 s each) in [start, end) where any slot sat at the 20-bit converter limit for
    /// at least `ALG144.Constants.adcClipMinSamples` samples (the same ADC_CLIPPED test as ALG-144). Not the strap's
    /// own saturation bit (that needs > 20 of 25 samples pinned per photodiode): an estimate from decoded, untested counts.
    static func rawSaturation(_ r20: [R20Record], start: Int64, end: Int64) -> Night? {
        let recs = r20.filter { $0.ts >= start && $0.ts < end && !$0.blocks.isEmpty }
        guard !recs.isEmpty else { return nil }
        let k = ALG144.Constants.self
        func clipped(_ r: R20Record) -> Bool {
            r.blocks.contains { b in
                [b.slotA, b.slotB].contains { slot in
                    slot.filter { $0 >= k.adcMax || $0 <= k.adcMin }.count >= k.adcClipMinSamples
                }
            }
        }
        let n = recs.filter(clipped).count
        return Night(seconds: recs.count, saturatedShare: Double(n) / Double(recs.count), psnrMedian: nil, logVarMedian: nil,
                     fromRawOptical: true)
    }

    /// The night's quality summary: the strap's own fields when present, else the raw-optical converter-limit count,
    /// else a blank that names what is missing.
    public static func night(r18: [R18Second], r20: [R20Record], start: Int64, end: Int64) -> Computed<Night> {
        let own = night(r18: r18, start: start, end: end)
        if own.value != nil { return own }
        if let raw = rawSaturation(r20, start: start, end: end) { return .success(raw) }
        return .missing(nothingReason)
    }

    public static func night(r18: [R18Second], start: Int64, end: Int64) -> Computed<Night> {
        let q = r18.filter { $0.ts >= start && $0.ts < end }.compactMap(\.quality)
        guard !q.isEmpty else {
            return .missing("no optical signal-quality fields in this night's R18 (stored before wave 4, or not a 5.0 / MG)")
        }
        let sat = Double(q.filter(\.saturated).count) / Double(q.count)
        let psnr: [Double] = q.compactMap { x in
            switch (x.psnrA, x.psnrB) {
            case let (a?, b?): return Double(a + b) / 2
            case let (a?, nil): return Double(a)
            case let (nil, b?): return Double(b)
            default: return nil
            }
        }
        let lv = q.compactMap(\.logVariance)
        return .success(Night(seconds: q.count, saturatedShare: sat, psnrMedian: psnr.isEmpty ? nil : SignalMath.median(psnr),
                              logVarMedian: lv.isEmpty ? nil : SignalMath.median(lv)))
    }

    static func spec(_ key: MetricKey, _ unit: String, _ what: String) -> MetricSpec {
        MetricSpec(key: key, unit: unit, group: nil, variant: "strap", method: "R18 quality@1 \(what)", tier: .research,
                   source: "r18", window: "night", producer: .strap, citation: citation, paramsVersion: "decoded-untested")
    }

    public static let saturatedSpec = spec(.opticalSaturatedPct, "%", "share of asleep seconds with a saturated photodiode")
    public static let psnrSpec = spec(.opticalPsnr, "db", "median pSNR of the selected HR source")
    public static let logVarSpec = spec(.opticalLogvar, "unitless", "median log-variance quality (lower = quieter)")

    public static func metrics(_ n: Computed<Night>, at: Date) -> [Metric] {
        let note = n.value.map {
            $0.fromRawOptical
                ? "estimate from \($0.seconds) raw optical seconds (R20) with a slot at the converter limit for 3+ samples; the strap's own saturation bit was not stored; decoded, untested"
                : "\($0.seconds) asleep seconds with the fields; the band's own numbers, decoded, untested"
        }
        func opt(_ v: KeyPath<Night, Double?>, _ why: String) -> Computed<Double> {
            n.flatMap { x in
                x[keyPath: v].map { .success($0) }
                    ?? .missing(x.fromRawOptical ? "the strap's own pSNR / log-variance were not stored for this night (only raw optical was)" : why)
            }
        }
        return [saturatedSpec.metric(n.map { $0.saturatedShare * 100 }, at: at, note: note),
                psnrSpec.metric(opt(\.psnrMedian, "every second reported pSNR unavailable (−128)"), at: at, note: note),
                logVarSpec.metric(opt(\.logVarMedian, "no log-variance value set"), at: at, note: note)]
    }
}
