import Foundation
import MGDomain

/// ALG-172 v1 — PPG perfusion index from still, quality-gated raw-PPG bursts: the input of the perfusion trend (ALG-170).
/// ENHANCED tier only (needs the strap's raw PPG bursts, which Mo switches on; no burst, no value, never a base-tier guess).
/// Python reference: pclab/mglab/ref/trends.py `burst_pi`, `burst_still`, `night_pi`; goldens shared/golden/trends/ALG-172.json.
///
/// Perfusion index = pulsatile (AC) over steady (DC) part of the light signal, in % (definition checked 2026-10-17; the finger
/// version is the pulse-oximetry convention). Here per 8-s window: AC = 95th minus 5th percentile of the pulse after a 1.5-s
/// moving-average high-pass, DC = mean of the raw counts; the window must show a pulse rate of 42-210 /min and an index of
/// 0.001-20 %; a burst (≥ 20 s, 25 Hz, every second still: R18 activity class 0) = median of ≥ 2 windows; a night = median of
/// ≥ 3 bursts. Raw counts are uncalibrated and wrist amplitude depends on strap pressure, posture and sensor height, so this is
/// only ever compared with Mo's own earlier nights. Backing: THEORY (the index is standard; sympathetic vasoconstriction lowers
/// finger pulse amplitude — Betta et al., Sleep Med 2020, search snippet only; a 2026 wrist-band sleep study reports night-to-night
/// variability in vasoconstriction parameters, nine finger cross-checks). No wrist validation against a sympathetic reference was
/// found, so the card says so.
public enum ALG172 {
    public static let id = "ALG-172"
    public static let citation = "Perfusion index = AC/DC (pulse-oximetry convention); gating and thresholds ours; no wrist validation"
    public static let minBurstSeconds = 20
    public static let windowSeconds = 8
    public static let highPassSeconds = 1.5
    public static let minWindows = 2
    public static let minBursts = 3
    public static let rateHz: ClosedRange<Double> = 0.7...3.5
    public static let piPercent: ClosedRange<Double> = 0.001...20.0
    public static let stillMin = 0.9
    public static let seriesName = "perfusion_index"

    public static func burstStill(classes: [Int?], seconds: Int) -> Bool {
        let known = classes.compactMap { $0 }
        return Double(known.count) >= stillMin * Double(seconds) && known.allSatisfy { $0 == 0 }
    }

    public static func burstPI(_ samples: [Double], fs: Double = 25) -> Computed<(pi: Double, windows: Int)> {
        let n = samples.count
        if Double(n) < Double(minBurstSeconds) * fs {
            return .missing("burst of \(String(format: "%.0f", Double(n) / fs)) s, at least \(minBurstSeconds) s needed")
        }
        let hp = ALG108.highPass(samples, window: max(3, Int(highPassSeconds * fs + 0.5)))
        let win = Int(Double(windowSeconds) * fs)
        var vals: [Double] = []
        for k in 0..<(n / win) {
            let raw = Array(samples[(k * win)..<((k + 1) * win)])
            let seg = Array(hp[(k * win)..<((k + 1) * win)])
            let dc = SignalMath.mean(raw)
            if !(dc > 0) { continue }
            var ups = 0
            for i in 1..<win where seg[i - 1] < 0 && seg[i] >= 0 { ups += 1 }
            if !rateHz.contains(Double(ups) / Double(windowSeconds)) { continue }
            let pi = 100.0 * (SignalMath.quantile(seg, 0.95) - SignalMath.quantile(seg, 0.05)) / dc
            if piPercent.contains(pi) { vals.append(pi) }
        }
        if vals.count < minWindows { return .missing("\(vals.count) clean 8-s windows, \(minWindows) needed") }
        return .success((SignalMath.median(vals), vals.count))
    }

    public static func nightPI(_ bursts: [Double]) -> Computed<(pi: Double, bursts: Int)> {
        if bursts.count < minBursts { return .missing("\(bursts.count) clean still bursts, \(minBursts) needed") }
        return .success((SignalMath.median(bursts), bursts.count))
    }

    /// The night's index from the v26 PPG bursts of [start, end) and the R18 seconds (activity class) of the same span.
    public static func night(_ blocks: [PPGBlock], rows: [R18Second], start: Int64, end: Int64) -> Computed<(pi: Double, bursts: Int)> {
        let inside = blocks.filter { $0.ts >= start && $0.ts < end }
        guard !inside.isEmpty else { return .missing("no raw PPG bursts in the span (switch the raw pulse on in Settings)") }
        var cls: [Int64: Int] = [:]
        for r in rows { if let c = r.activityClass { cls[r.ts] = c } }
        var vals: [Double] = []
        for b in ALG108.bursts(inside) where b.rateHz == 25 {
            let classes = (0..<b.seconds).map { cls[b.start + Int64($0)] }
            guard burstStill(classes: classes, seconds: b.seconds), case .success(let r) = burstPI(b.samples) else { continue }
            vals.append(r.pi)
        }
        return nightPI(vals)
    }

    static func series(_ r: Computed<(pi: Double, bursts: Int)>, start: Int64, span: Int64) -> [Series] {
        guard case .success(let v) = r else { return [] }
        return [PipelineOutput.carry(seriesName, variant: id, start: start, stepS: span, value: v.pi, n: v.bursts, unit: "pct",
                                     tier: .research)]
    }
}
