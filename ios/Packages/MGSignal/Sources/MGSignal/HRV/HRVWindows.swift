import Foundation
import MGDomain

/// One clock-aligned 5-min window of corrected R-R (start = floor(t / 300) · 300, unix s).
public struct HRVWindow: Sendable, Equatable {
    public var start: Int64
    public var beats: Int
    /// Σ corrected R-R / 300 s, capped at 1.
    public var coverage: Double
    /// Flagged share of this window's corrected intervals.
    public var artefactFraction: Double
    /// coverage ≥ 0.8, ≥ 30 beats and ≤ 5 % flagged (ALG-004 B). Only clean windows carry the values below.
    public var clean: Bool
    public var time: HRVTime?
    public var freq: HRVFreq?
    public var baevsky: ALG123.Baevsky?

    public init(start: Int64, beats: Int, coverage: Double, artefactFraction: Double, clean: Bool,
                time: HRVTime? = nil, freq: HRVFreq? = nil, baevsky: ALG123.Baevsky? = nil) {
        self.start = start
        self.beats = beats
        self.coverage = coverage
        self.artefactFraction = artefactFraction
        self.clean = clean
        self.time = time
        self.freq = freq
        self.baevsky = baevsky
    }
}

/// A span of R-R (a night, a day, a live stretch) cut into 5-min windows after ALG-004 A ran on the whole span.
public struct HRVWindowSet: Sendable, Equatable {
    public var windows: [HRVWindow]
    /// ALG-004 A corrected fraction over the whole span (input intervals).
    public var artefactFraction: Double
    /// R-R points that went in.
    public var beatsIn: Int

    public init(windows: [HRVWindow], artefactFraction: Double, beatsIn: Int) {
        self.windows = windows
        self.artefactFraction = artefactFraction
        self.beatsIn = beatsIn
    }

    public var cleanWindows: [HRVWindow] { windows.filter(\.clean) }
}

/// ALG-004 B + the per-window HRV every nightly / daily value is a median of. Python reference:
/// app/pclab/mglab/ref/hrv.py `analyse_windows`; golden fns "windows", "nightly", "nightly_freq", "window_median_si".
public enum HRVWindows {
    public static let windowSeconds = 300.0
    public static let minCoverage = 0.8
    public static let minBeats = 30
    /// A nightly / daily median needs this many clean windows (15 min).
    public static let minCleanWindows = 3

    /// R-R points (any order; caller removes duplicate sources) → beat clock → ALG-004 A on the whole span →
    /// windows. Time domain and Lomb–Scargle go through `core` (Rust when linked); Baevsky SI is Swift only.
    public static func analyse(points: [RRPoint], core: any SignalCore = Signal.core) -> HRVWindowSet {
        let sorted = BeatClock.sorted(points)
        let times = BeatClock.times(points: sorted)
        let art = ALG004.correct(rrMs: sorted.map(\.rrMs), times: times)

        var order: [Int64] = []
        var byWindow: [Int64: [Int]] = [:]
        for (i, t) in art.times.enumerated() {
            let w = Int64((t / windowSeconds).rounded(.down))
            if byWindow[w] == nil {
                byWindow[w] = []
                order.append(w)
            }
            byWindow[w]!.append(i)
        }
        var windows: [HRVWindow] = []
        for w in order.sorted() {
            let idx = byWindow[w] ?? []
            let r = idx.map { art.rrMs[$0] }
            let flagged = idx.filter { art.flags[$0] != ArtefactFlag.ok.rawValue }.count
            var sum = 0.0
            for v in r { sum += v }
            let coverage = min(1.0, sum / 1000.0 / windowSeconds)
            let afrac = Double(flagged) / Double(r.count)
            let clean = coverage >= minCoverage && r.count >= minBeats && afrac <= ALG004.windowMaxArtefactFraction
            var win = HRVWindow(start: w * Int64(windowSeconds), beats: r.count, coverage: coverage,
                                artefactFraction: afrac, clean: clean)
            if clean {
                win.time = core.hrvTime(rrMs: r)
                win.freq = core.hrvFreq(rrMs: r)
                win.baevsky = ALG123.baevsky(rrMs: r).value
            }
            windows.append(win)
        }
        return HRVWindowSet(windows: windows, artefactFraction: art.correctedFraction, beatsIn: sorted.count)
    }

    static func notEnough(_ have: Int) -> Missing {
        Missing("needs \(minCleanWindows) clean 5-min windows (have \(have)): too short, too many artefacts or too "
                + "little R-R coverage")
    }

    /// Median of `values` when there are at least `minCleanWindows` of them.
    static func medianOrMissing(_ values: [Double]) -> Computed<Double> {
        values.count >= minCleanWindows ? .success(SignalMath.median(values)) : .failure(notEnough(values.count))
    }
}
