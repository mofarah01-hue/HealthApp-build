import Foundation
import MGDomain

/// T9821 (Mo, Oct 17 2026): the finished 60 s ECG reading broken down in plain words: heart rate, R-R spread, signal quality,
/// electrode contact, rhythm class. Part of ALG-014's result (same R-peaks, same research tier). Display words only; nothing is
/// stored by this file. Not a diagnosis: a wrist strap's ECG at ~100 Hz is not validated against a clinical ECG here.
///
/// The rhythm class looks only at how even the beat spacing is. Its limits are ENGINEERING STARTING VALUES (not published
/// thresholds, not tuned on a reference ECG): spread = median absolute deviation of the R-R intervals over their median.
/// "Irregular" cannot separate an uneven rhythm from noise or movement, and the app says so. Atrial fibrillation is NOT detected.
public enum EcgBreakdown {
    public static let regularBelow = 0.05
    public static let variableBelow = 0.12
    public static let minBeatsForClass = 20

    public struct Row: Equatable, Sendable {
        public var label: String
        public var value: String
        public var note: String?
        public init(label: String, value: String, note: String? = nil) {
            self.label = label
            self.value = value
            self.note = note
        }
    }

    /// Rows for the result screen, in order: heart rate, R-R spread, signal quality, contact, rhythm.
    public static func rows(samples: [Int16], packets: [EcgTracePacket], result: Computed<ALG014.Result>) -> [Row] {
        let contact = contactRow(packets)
        guard case .success(let r) = result else {
            let why = result.missingReason ?? "no heart rate"
            return [Row(label: "Heart rate", value: "—", note: why),
                    Row(label: "R-R spread", value: "—", note: "needs a heart rate first"),
                    Row(label: "Signal quality", value: strapQuality(packets), note: nil),
                    contact,
                    Row(label: "Rhythm", value: "not classified", note: why)]
        }
        let x = settled(samples, packets).map(Double.init)       // the same samples ALG014.heartRate found the peaks in
        let problem = EcgBeatQuality.problem(x: x, peaks: r.peaks, fs: r.rateHz)
        let rr = r.rrSeconds
        let med = SignalMath.median(rr)
        let mad = SignalMath.median(rr.map { abs($0 - med) })
        let sd = standardDeviation(rr)
        let pct = med > 0 ? mad / med : 0
        var out: [Row] = []
        out.append(Row(label: "Heart rate", value: "\(Int((60 / med).rounded())) bpm",
                       note: "median of \(rr.count) R-R intervals, \(r.beats) beats"))
        out.append(Row(label: "R-R spread",
                       value: "\(Int((sd * 1000).rounded())) ms SD · \(Int((mad * 1000).rounded())) ms MAD (\(percent(pct)))",
                       note: "how much the time between beats varies; SD is the usual figure, MAD ignores single odd beats"))
        out.append(Row(label: "Signal quality",
                       value: problem == nil ? "beats look like a heartbeat" : "doubtful: \(problem!)",
                       note: strapQuality(packets) + " · research check on our R-peaks"))
        out.append(contact)
        out.append(rhythmRow(rrCount: rr.count, spread: pct, problem: problem))
        return out
    }

    /// The class from the spread alone (testable on its own).
    public static func rhythmRow(rrCount: Int, spread: Double, problem: String?) -> Row {
        let caveat = "Research, decoded, untested. Not a diagnosis, and atrial fibrillation is not detected here."
        if let problem { return Row(label: "Rhythm", value: "not classified", note: "signal not clear enough: \(problem). " + caveat) }
        guard rrCount >= minBeatsForClass else {
            return Row(label: "Rhythm", value: "not classified", note: "only \(rrCount) intervals; \(minBeatsForClass) needed. " + caveat)
        }
        if spread < regularBelow { return Row(label: "Rhythm", value: "regular", note: "even beat spacing. " + caveat) }
        if spread < variableBelow {
            return Row(label: "Rhythm", value: "variable",
                       note: "beat spacing varies a little; breathing alone does this. " + caveat)
        }
        return Row(label: "Rhythm", value: "irregular spacing",
                   note: "beat spacing is uneven. This can be an uneven rhythm, noise or movement; the app cannot tell which. "
                       + "Repeat the reading still; talk to a clinician if it keeps showing. " + caveat)
    }

    /// `samples` without the leading packets that are all zeros (the front end settling), exactly as `ALG014.heartRate` skips them.
    static func settled(_ samples: [Int16], _ packets: [EcgTracePacket]) -> ArraySlice<Int16> {
        var start = 0
        var skip = 0
        for p in packets {
            let end = min(samples.count, skip + p.sampleCount)
            if skip < end, samples[skip..<end].allSatisfy({ $0 == 0 }) { skip = end; start = end } else { break }
        }
        return samples[start...]
    }

    static func contactRow(_ packets: [EcgTracePacket]) -> Row {
        guard !packets.isEmpty else { return Row(label: "Contact", value: "no records") }
        let yes = packets.filter(\.presence).count
        let value = yes == packets.count ? "finger contact in every record"
            : yes == 0 ? "the strap never reported finger contact"
            : "finger contact in \(yes) of \(packets.count) records"
        return Row(label: "Contact", value: value, note: "the strap's own electrode flag")
    }

    /// The strap's raw quality byte, median over the records. Its scale and meaning are not established.
    static func strapQuality(_ packets: [EcgTracePacket]) -> String {
        guard !packets.isEmpty else { return "strap quality code: none" }
        let q = SignalMath.median(packets.map { Double($0.quality) })
        return "strap quality code \(Int(q.rounded())) (raw byte, meaning not established)"
    }

    static func standardDeviation(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = x.reduce(0, +) / Double(x.count)
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)).squareRoot()
    }

    static func percent(_ f: Double) -> String { String(format: "%.1f %%", f * 100) }
}
