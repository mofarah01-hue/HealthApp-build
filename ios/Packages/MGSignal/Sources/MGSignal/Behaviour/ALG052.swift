import Foundation
import MGDomain

/// ALG-052 v4 — the afternoon dip, read off ALG-051's curve (the UMP already carries the five circadian harmonics,
/// Ramakrishnan 2016 Table 2 eq. 3; "lowest predicted PVT impairment" = highest alertness score).
///
/// The peak-focus window and the second wind (ALG-052 v1–v3) were REMOVED 2026-10-17 (Mo, D-HRV-WALK-1: "Focus window /
/// second wind REMOVE"): no paper defines either on the UMP curve, and the research (audit/RESEARCH-HRV-STRESS.md
/// section 6) found the time-of-day "synchrony effect" contested. Their metrics, rows, dial band and tests are gone.
///
/// Dip rule — OURS, flagged (no paper defines a "dip" on the UMP curve): between 12:00 and 18:00 local (UX §12 "early
/// afternoon"), the deepest local low of the score whose prominence (the lower of the two highs around it, minus the
/// low) is ≥ 5 points; its window is where the score is below low + prominence/2 (half-prominence width). None found =
/// "Clear afternoon." Only caffeine logged so far counts: a later drink changes the forecast at the next compute.
public enum ALG052 {
    public static let citation = ALG051.citation
    public static let inertiaSeconds = 3600.0     // dip search starts 1 h after waking
    public static let dipFromH = 12
    public static let dipToH = 18
    public static let dipMinProminence = 5.0

    public struct Window: Sendable, Equatable {
        public var start: Date
        public var end: Date
        /// The lowest score inside the dip.
        public var score: Double

        public init(start: Date, end: Date, score: Double) {
            self.start = start
            self.end = end
            self.score = score
        }
    }

    /// The afternoon dip, or nil when the afternoon has no low of 5 points or more.
    public static func dip(_ f: ALG051.Forecast, timeZone: TimeZone) -> Window? {
        let first = f.wake.addingTimeInterval(inertiaSeconds)
        let pm = f.samples.filter { s in
            let h = ALG051.clockHour(s.at.timeIntervalSince1970, timeZone)
            return s.at >= first && h >= Double(dipFromH) && h <= Double(dipToH)
        }
        guard pm.count >= 3 else { return nil }
        let v = pm.map(\.rawScore)
        var best: (i: Int, prominence: Double)?
        for i in 1..<(v.count - 1) where v[i] <= v[i - 1] && v[i] < v[i + 1] {
            let leftHigh = v[...i].max()!
            let rightHigh = v[i...].max()!
            let prom = min(leftHigh, rightHigh) - v[i]
            if best == nil || prom > best!.prominence { best = (i, prom) }
        }
        guard let b = best, b.prominence >= dipMinProminence else { return nil }
        let level = v[b.i] + b.prominence / 2
        var l = b.i
        while l > 0 && v[l - 1] <= level { l -= 1 }
        var r = b.i
        while r < v.count - 1 && v[r + 1] <= level { r += 1 }
        return Window(start: pm[l].at, end: pm[r].at, score: v[b.i])
    }
}
