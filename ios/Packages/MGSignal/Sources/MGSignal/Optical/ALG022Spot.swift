import Foundation
import MGDomain

/// ALG-022:spot v2 (wave 4, #77, 2026-10-11; curve changed R9m 2026-10-17) — EXPERIMENTAL SpO₂ estimate from ~60 s of
/// live raw optical (R20, 108 on, behind the raw-optical switch). Ratio of ratios on two R20 blocks taken as red and IR:
///   R = (AC_red / DC_red) / (AC_ir / DC_ir),  SpO₂ ≈ −45.060·R² + 30.354·R + 94.845
/// The curve is the quadratic in Maxim Integrated's reference algorithm for its MAX30102 pulse-oximeter sensor
/// (`maxim_heart_rate_and_oxygen_saturation`, the vendor's published example code; the app note "Guidelines for SpO2
/// Measurement Using the Maxim MAX32664 Sensor Hub" explains that such coefficients are empirical and must be refitted for
/// other LEDs and optics). It is a published curve for another sensor, NOT calibrated to WHOOP's LEDs, and no WHOOP
/// calibration curve is public (CAPABILITIES "Optical, SpO₂ and R22"). v1 used the generic line 110 − 25·R that whoop-rs
/// carries for WHOOP 4 and withholds there (`spo2.rs` L10-135 @d11d8ef). Which blocks are red
/// and IR is NOT established on this firmware: the caller passes the pair and says where it came from (the PC's LED
/// experiment, else OpenStrap's unproven claim 1 = red, 3 = IR). So this is an experimental estimate, research tier,
/// never a measurement, until the LED experiment confirms the channels and it agrees with WHOOP (pc.spo2-gate).
/// Python reference: app/pclab/mglab/ref/resp.py `spo2_from_ratio`, `spo2_night_windows`; goldens
/// app/shared/golden/resp/ALG-022.json.
///
/// Per block: slot A of every record in time order (sampleCount samples per 1-s record, so the rate is sampleCount Hz);
/// DC = mean; AC = RMS of the signal minus its own 1-s moving average (the pulsatile part; the same filter on both
/// channels, so its gain cancels in R). Guards: ≥ 30 s of records with both blocks populated (≥ 80 % of records), DC > 0,
/// R in 0.3–2.0, result in 70–100; anything else is blank with the reason.
public enum ALG022Spot {
    public static let citation = "ratio of ratios; SpO2 = -45.060 R^2 + 30.354 R + 94.845 (Maxim Integrated MAX30102 reference "
        + "algorithm, empirical, another sensor's LEDs, not WHOOP-calibrated); was 110 - 25 R (whoop-rs spo2.rs @d11d8ef)"
    /// The curve's coefficients (Maxim Integrated, MAX30102 example code, `maxim_heart_rate_and_oxygen_saturation`).
    public static let curveA = -45.060
    public static let curveB = 30.354
    public static let curveC = 94.845

    /// SpO₂ in % for a ratio of ratios, from the cited curve (no clamping here; the callers guard the range).
    public static func spo2(ratio r: Double) -> Double { (curveA * r + curveB) * r + curveC }
    public static let variant = "ALG-022:spot"
    public static let minSeconds = 30
    public static let minPopulatedShare = 0.8
    public static let rRange: ClosedRange<Double> = 0.3...2.0
    public static let resultRange: ClosedRange<Double> = 70...100

    public struct Estimate: Sendable, Equatable {
        public var spo2: Double
        public var ratio: Double
        public var seconds: Int
        public var redBlock: Int
        public var irBlock: Int
    }

    /// DC and AC of one block's slot A over the records (nil when the block is dark in too many of them).
    static func acdc(_ recs: [R20Record], block: Int) -> (dc: Double, ac: Double, populated: Int)? {
        var x: [Double] = []
        var rate = 0
        var populated = 0
        for r in recs.sorted(by: { $0.ts < $1.ts }) {
            guard block < r.blocks.count else { continue }
            let a = r.blocks[block].slotA
            guard !a.isEmpty, a.contains(where: { $0 != 0 }) else { continue }
            populated += 1
            rate = max(rate, a.count)
            x += a.map(Double.init)
        }
        guard rate > 1, x.count > 2 * rate else { return nil }
        let dc = SignalMath.mean(x)
        var sum = 0.0
        var acc = 0.0
        var window: [Double] = []
        for v in x {                                  // running 1-s mean (rate samples), centred once full
            window.append(v)
            sum += v
            if window.count > rate { sum -= window.removeFirst() }
            if window.count == rate {
                let mid = window[rate / 2]
                acc += (mid - sum / Double(rate)) * (mid - sum / Double(rate))
            }
        }
        let n = max(1, x.count - rate + 1)
        return (dc, (acc / Double(n)).squareRoot(), populated)
    }

    public static func estimate(records: [R20Record], red: Int, ir: Int, minSeconds: Int = ALG022Spot.minSeconds) -> Computed<Estimate> {
        guard records.count >= minSeconds else {
            return .missing("\(records.count) s of raw optical; at least \(minSeconds) s are needed")
        }
        guard let r = acdc(records, block: red), let i = acdc(records, block: ir) else {
            return .missing("block \(red) or \(ir) carried no samples: no red / IR pair to compare")
        }
        let need = Int((Double(records.count) * minPopulatedShare).rounded(.up))
        guard r.populated >= need, i.populated >= need else {
            return .missing("block \(red) populated in \(r.populated), block \(ir) in \(i.populated) of \(records.count) "
                            + "records (needs \(need))")
        }
        switch fromACDC(acRed: r.ac, dcRed: r.dc, acIr: i.ac, dcIr: i.dc) {
        case .failure(let why): return .failure(why)
        case .success(let p):
            return .success(Estimate(spo2: p.spo2, ratio: p.ratio, seconds: records.count, redBlock: red, irBlock: ir))
        }
    }

    /// The ratio of ratios and the SpO₂ from one red / IR pair of AC and DC levels, with the guards: both DC levels positive,
    /// IR AC positive, R in 0.3–2.0, result 70–100; anything else is blank with the reason.
    public static func fromACDC(acRed: Double, dcRed: Double, acIr: Double, dcIr: Double) -> Computed<(spo2: Double, ratio: Double)> {
        guard dcRed > 0, dcIr > 0 else { return .missing("a channel's DC level is not positive: no ratio to take") }
        guard acIr > 0 else { return .missing("no pulsatile signal on the IR block") }
        let ratio = (acRed / dcRed) / (acIr / dcIr)
        guard rRange.contains(ratio) else {
            return .missing("ratio of ratios \(String(format: "%.2f", ratio)) is outside 0.3–2.0: not a usable pulse")
        }
        let v = spo2(ratio: ratio)
        guard resultRange.contains(v) else { return .missing("estimate \(String(format: "%.1f", v)) is outside 70–100") }
        return .success((v, ratio))
    }

    public static let spec = MetricSpec(
        key: .spo2Pct, unit: "%", group: "G-SPO2", variant: variant,
        method: "ALG-022:spot@2 ratio of ratios on live R20, Maxim quadratic", tier: .research, source: "r20 live",
        window: "instant", producer: .ours, citation: citation, paramsVersion: "maxim-quad min30s pop0.8 R0.3-2.0")

    /// The metric, labelled an experimental estimate with its channel assumption (`basis`).
    public static func metric(_ e: Computed<Estimate>, basis: String, at: Date) -> Metric {
        let note = "experimental estimate — channels: \(basis); not checked against WHOOP"
            + (e.value.map { "; R = \(String(format: "%.3f", $0.ratio)) over \($0.seconds) s" } ?? "")
        return spec.metric(e.map(\.spo2), at: at, note: note)
    }
}
