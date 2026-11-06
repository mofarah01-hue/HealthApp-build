import Foundation
import MGDomain

/// ALG-123 daytime BODY AROUSAL 0–3 (T31, variant "ALG-123:daytime"; shown as "Body arousal", replaces "stress": Mo,
/// D-HRV-WALK-1, Oct 17 2026). It says how far your heart rate and HRV sit from your own usual for that hour while you
/// are still — physiological arousal (caffeine, a hard conversation, a heavy meal, illness, heat and excitement all
/// raise it), never mood and never a "stress level". The same idea as WHOOP's Stress Monitor, not its numbers
/// (WHOOP's formula is unpublished). The usual is your own still-window HR / lnRMSSD for the same hour over 14 days.
/// Each still 5-min waking window is scored as the ALG-054 load (mean z of HR up and
/// lnRMSSD down against your own 14-day baseline of the same hour, blended with the published population value by
/// days / (days + 14) (D-POP-PRIOR, R9m: "population" on day one, "yours (N days)" after)) and mapped like noop's
/// logistic (the removed ALG-123:daily): 3 / (1 + e^−load), so 1.5 = your usual, 0 calm,
/// 3 high. The day's value is the mean of its scored windows (≥ 3). Motion-aware: the R-R it reads are the still ones
/// (`ALG054.stillPoints`) and a window inside a workout is not scored. T110: a window while the strap is flagged off the
/// wrist (a stored "off" wear event not yet followed by an "on") or with an HR outside 30–220 bpm is not scored, so a
/// stuck flag yields no stress rather than a wrong one. Ours (v0): the 14 days, the 1 / 2 band edges and the logistic are
/// defaults, not fitted.
public enum ALG123Daytime {
    public static let citation = "ours (T31); ALG-054 load through the logistic 3 / (1 + e^−load); "
        + "HRV-vs-baseline arousal reading: Task Force 1996 (Circulation 93:1043), Shaffer & Ginsberg 2017 (Front Public Health 5:258)"
    public static let baselineDays = 14
    /// Band edges on the 0–3 score: below `lowBelow` low, below `highFrom` medium, else high.
    public static let lowBelow = 1.0
    public static let highFrom = 2.0
    /// The bpm range a scored window's mean HR must sit in (off the wrist the strap reads 0).
    public static let hrRange: ClosedRange<Double> = 30...220

    public struct Window: Sendable, Equatable {
        public var start: Int64
        public var score: Double
    }

    public struct Day: Sendable, Equatable {
        public var score: Double
        public var windows: [Window]
        public var peak: Window
        /// Windows left unscored because the strap was flagged off the wrist.
        public var skippedOffWrist: Int
    }

    public static func score(load: Double) -> Double { min(max(3.0 / (1.0 + exp(-load)), 0.0), 3.0) }

    public static func band(_ score: Double) -> String { score < lowBelow ? "low" : score < highFrom ? "medium" : "high" }

    /// [off, on) spans (unix s) from the stored wear events: an "off" opens one, the next "on" closes it, and an "off"
    /// never followed by an "on" stays open until `until`.
    public static func offWristSpans(_ events: [EventRecord], until end: Int64) -> [(Int64, Int64)] {
        var wear: [(Int64, WearFields.State)] = []
        for e in events where !e.removed {
            if case .wear(let f) = e.payload { wear.append((Int64(e.at.timeIntervalSince1970), f.state)) }
        }
        wear.sort { $0.0 < $1.0 }
        var spans: [(Int64, Int64)] = []
        var open: Int64?
        for (t, state) in wear {
            if state == .off {
                open = open ?? t
            } else if let o = open {
                spans.append((o, t))
                open = nil
            }
        }
        if let o = open, o < end { spans.append((o, end)) }
        return spans
    }

    /// `exercise` is true for a window start inside a workout; `hourOf` maps a window start to the local hour;
    /// `inDaytime` (T32) is false for a window start outside the daytime window, which is not scored.
    public static func day(_ set: HRVWindowSet, hourOf: (Int64) -> Int, exercise: (Int64) -> Bool,
                           baseline: ALG054.Baseline, offWrist: [(Int64, Int64)],
                           inDaytime: (Int64) -> Bool = { _ in true }) -> Computed<Day> {
        var starts: [Int64] = []
        var samples: [ALG054.Sample] = []
        var skipped = 0
        for w in set.cleanWindows {
            guard inDaytime(w.start), let t = w.time, hrRange.contains(60_000.0 / t.meanRR) else { continue }
            if offWrist.contains(where: { w.start < $0.1 && w.start + Int64(HRVWindows.windowSeconds) > $0.0 }) {
                skipped += 1
                continue
            }
            starts.append(w.start)
            samples.append(ALG054.Sample(hour: hourOf(w.start), hr: 60_000.0 / t.meanRR, lnRmssd: t.lnRmssd,
                                         exercise: exercise(w.start)))
        }
        let loads = ALG054.windowLoads(samples, baseline: baseline)
        var windows: [Window] = []
        for (start, load) in zip(starts, loads) {
            if let load { windows.append(Window(start: start, score: score(load: load))) }
        }
        guard windows.count >= ALG054.dayMinWindows, let peak = windows.max(by: { $0.score < $1.score }) else {
            let why = skipped > 0 ? "; \(skipped) while the strap was flagged off your wrist" : ""
            return .missing("needs \(ALG054.dayMinWindows) still windows with a body-arousal score (have \(windows.count))\(why)")
        }
        return .success(Day(score: SignalMath.mean(windows.map(\.score)), windows: windows, peak: peak,
                            skippedOffWrist: skipped))
    }

    public static let spec = MetricSpec(
        key: .stress, unit: "score_0_3", group: "G-STRESS", variant: "ALG-123:daytime", method: "ALG-123@1 daytime-stress",
        tier: .estimate, source: "rr,hr,r18", window: "day", citation: citation,
        paramsVersion: "base14d hour-slots-or-earlier-calm-today logistic3 still-only offwrist-gated")
}
