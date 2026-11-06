import Foundation
import MGDomain

/// ALG-022:night v1 (R9m, 2026-10-17, D-HRV-WALK-1 + D-ALG-TIERS) — the ENHANCED tier of overnight SpO₂: when raw optical
/// (R20) ran during the night, the ratio of ratios on the red and IR blocks (ALG-022:spot's maths and cited curve) over
/// each 30-second window of the sleep period; the night value is the MEDIAN of the windows' estimates (needs 3). The base
/// tier is the strap's own SpO₂ byte (ALG-021), which stays on screen when raw optical was off. Window length 30 s = the
/// strap's own SpO₂ window (a 30-s window every 20 min while asleep, CAPABILITIES "Optical, SpO₂ and R22", and
/// `SpO2BurstSchedule`). A window needs 24 of its 30 records (80 %) with both blocks populated, and passes the same guards
/// as the spot reading (DC > 0, R in 0.3–2.0, result 70–100), else it is left out.
/// Labelled an ESTIMATE — not checked against WHOOP (CLAUDE.md rule 4, Mo 2026-10-12 "D2 D3 D4 yes"): the curve is another
/// sensor's, the red / IR block identity is assumed until the PC's LED experiment confirms it, and nothing here has been
/// compared with an oximeter. Python reference: app/pclab/mglab/ref/resp.py `spo2_from_ratio`, `spo2_night_windows`;
/// goldens app/shared/golden/resp/ALG-022.json.
public enum ALG022Night {
    public static let variant = "ALG-022:night"
    public static let method = "ALG-022:night@1 median of 30-s red/IR windows, Maxim quadratic"
    public static let windowSeconds: Int64 = 30
    /// A window needs this many of its records (80 % of 30 s).
    public static let minWindowRecords = 24
    public static let minWindows = 3
    public static let label = "estimate — not checked against WHOOP"

    public struct Night: Sendable, Equatable {
        /// Median of the windows' SpO₂ estimates, %.
        public var median: Double
        /// Lowest single-window estimate, % (noisy: one window; shown in the note only).
        public var lowest: Double
        public var windows: Int
        /// Windows that had records but failed a guard.
        public var rejected: Int
        public var redBlock: Int
        public var irBlock: Int
    }

    /// Records in [start, end) cut into 30-s windows anchored at `start`; each window estimated like the spot reading.
    public static func night(_ records: [R20Record], red: Int, ir: Int, start: Int64, end: Int64) -> Computed<Night> {
        var byWindow: [Int64: [R20Record]] = [:]
        for r in records where r.ts >= start && r.ts < end { byWindow[(r.ts - start) / windowSeconds, default: []].append(r) }
        guard !byWindow.isEmpty else {
            return .missing("no raw optical (R20) records in the sleep period: the strap's SpO₂ byte is the base reading")
        }
        var estimates: [Double] = []
        var rejected = 0
        for k in byWindow.keys.sorted() {
            let recs = byWindow[k]!
            guard recs.count >= minWindowRecords else { continue }
            if let e = ALG022Spot.estimate(records: recs, red: red, ir: ir, minSeconds: minWindowRecords).value {
                estimates.append(e.spo2)
            } else {
                rejected += 1
            }
        }
        return aggregate(estimates, rejected: rejected, red: red, ir: ir)
    }

    /// The night from the windows' SpO₂ estimates: their median, needing `minWindows`.
    public static func aggregate(_ estimates: [Double], rejected: Int, red: Int, ir: Int) -> Computed<Night> {
        guard estimates.count >= minWindows else {
            return .missing("\(estimates.count) usable 30-s red/IR windows (\(rejected) failed a check); at least "
                            + "\(minWindows) are needed")
        }
        return .success(Night(median: SignalMath.median(estimates), lowest: estimates.min()!, windows: estimates.count,
                              rejected: rejected, redBlock: red, irBlock: ir))
    }

    public static let spec = MetricSpec(
        key: .spo2Pct, unit: "%", group: "G-SPO2", variant: variant, method: method, tier: .estimate, source: "r20 night",
        window: "night", producer: .ours, citation: ALG022Spot.citation, paramsVersion: "maxim-quad win30s min24rec min3win")

    /// `spo2_pct` ALG-022:night, with the label and the channel basis in the note.
    public static func metric(_ n: Computed<Night>, basis: String, at: Date) -> Metric {
        let note = "\(LEDIdentity.confirmed ? label : LEDIdentity.researchLabel); red / IR from raw optical, channels: \(basis)"
            + (n.value.map { "; \($0.windows) windows of 30 s, lowest window \(String(format: "%.0f", $0.lowest)) %" } ?? "")
        return spec.metric(n.map(\.median), at: at, note: note)
    }
}
