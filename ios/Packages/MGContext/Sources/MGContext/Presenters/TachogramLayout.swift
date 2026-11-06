import Foundation

/// T21: what the beat-to-beat graph draws. The x-axis is the fixed 60 s ending at `end` ("now", or the end of the stored
/// stretch); the line breaks wherever the clean beats are more than `gap` apart; the y-axis comes from the clean beats only
/// and moves in `step` ms steps, so it does not jump on every beat. The view only draws this.
public struct TachogramLayout: Equatable, Sendable {
    public struct Beat: Equatable, Sendable {
        public var at: Date
        public var rrMs: Double
        /// Beats of one run are joined by the line; a new run starts after a gap.
        public var run: Int
    }

    public static let window: TimeInterval = 60
    /// Clean beats further apart than this are not joined (a pause, or several beats in a row left out).
    public static let gap: TimeInterval = 3
    public static let step = 50.0

    public var line: [Beat]
    public var rings: [Beat]
    public var xDomain: ClosedRange<Date>
    public var yDomain: ClosedRange<Double>

    /// Bug 23 (M-044): what the y-axis is. Each dot is the time between two heartbeats (R-R interval) in milliseconds:
    /// 1000 ms = 60 bpm, 750 ms = 80 bpm.
    public static let axisLabel = "R-R interval (ms)"
    public static let axisHint = "time between beats in ms · 1000 ms = 60 bpm"

    /// Bug 23 (M-045): why the chart has no line, one specific reason instead of one message for every case. nil when
    /// the line can be drawn (two or more clean beats). `liveBlank` = the Live tab's own blank reason (strap off the
    /// wrist, not connected), which comes first.
    public func emptyReason(liveBlank: String?) -> String? {
        guard line.count < 2 else { return nil }
        if let liveBlank, !liveBlank.isEmpty { return liveBlank }
        let total = line.count + rings.count
        if total == 0 {
            return "No beats from the strap in the last 60 s. Beat-to-beat intervals arrive only while the strap streams "
                + "heart rate; check the stream is on."
        }
        let clean = line.count
        if rings.count > 0, rings.count * 2 >= total {
            return "\(total) beat\(total == 1 ? "" : "s") in the last 60 s, \(rings.count) flagged as artefacts by ALG-004 "
                + "(usually movement or a loose strap) and left out; \(clean) clean. The line needs 2 clean beats in a row."
        }
        return "Only \(clean) clean beat\(clean == 1 ? "" : "s") in the last 60 s (\(rings.count) left out by ALG-004). "
            + "The line starts after two beats pass the artefact check."
    }

    public static func make(_ points: [TachogramPoint], end: Date) -> TachogramLayout {
        let from = end.addingTimeInterval(-window)
        var line: [Beat] = [], rings: [Beat] = []
        var run = 0
        for p in points.sorted(by: { $0.at < $1.at }) where p.rrMs.isFinite && p.at >= from && p.at <= end {
            if p.artefact { rings.append(Beat(at: p.at, rrMs: p.rrMs, run: run)); continue }
            if let prev = line.last, p.at.timeIntervalSince(prev.at) > gap { run += 1 }
            line.append(Beat(at: p.at, rrMs: p.rrMs, run: run))
        }
        var y = 0.0...1.0
        if let lo = line.map(\.rrMs).min(), let hi = line.map(\.rrMs).max() {
            let pad = max(40, (hi - lo) * 0.25)
            y = ((lo - pad) / step).rounded(.down) * step ... ((hi + pad) / step).rounded(.up) * step
        }
        return TachogramLayout(line: line, rings: rings, xDomain: from...end, yDomain: y)
    }
}
