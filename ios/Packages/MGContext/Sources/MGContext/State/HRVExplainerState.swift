import Foundation
import MGDomain

/// The card that opens when Mo taps the RMSSD tile or the autonomic-load tile on Live (0.6.0.12): what the number is, how often
/// it really changes, today's 5-minute windows, the 7-night lnRMSSD mean against his normal band, and what a change that matters
/// looks like. Words and numbers only; the view draws them.
public struct HRVExplainerState: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable { case rmssd, load }

    /// One 5-minute window of today for the chart: solid when it met the rules, faded when it did not.
    public struct Point: Equatable, Sendable, Identifiable {
        public var id: Date { end }
        public var end: Date
        /// RMSSD in ms (nil = nothing computable, drawn as a faded tick at the axis).
        public var rmssd: Double?
        public var clean: Bool
        /// The window's reason when faded ("too few clean beats (have 7, need 20)").
        public var why: String?

        public init(end: Date, rmssd: Double?, clean: Bool, why: String?) {
            self.end = end
            self.rmssd = rmssd
            self.clean = clean
            self.why = why
        }
    }

    /// Where the 7-night mean stands against the normal band.
    public enum Standing: String, Equatable, Sendable { case below, inside, above, learning }

    public var kind: Kind
    public var id: String { kind.rawValue }
    public var title: String
    public var what: String
    public var howOften: String
    /// Today's finished 5-minute windows, oldest first.
    public var points: [Point]
    /// One line under the chart: how many windows, how many clean, what solid and faded mean.
    public var chartNote: String
    /// "7-night average: RMSSD about 44 ms (ln 3.78), from 6 of the last 7 nights."; or why there is none.
    public var weekLine: String
    /// "Your normal: 38 to 47 ms ..." or "Learning your normal: 9 of 14 nights so far."
    public var bandLine: String
    public var standing: Standing
    /// The band in ms (low, high) when known, for the view's band mark.
    public var bandMs: [Double]?
    public var changeLine: String
    public var footnote: String

    public init(kind: Kind, title: String, what: String, howOften: String, points: [Point], chartNote: String, weekLine: String,
                bandLine: String, standing: Standing, bandMs: [Double]?, changeLine: String, footnote: String) {
        self.kind = kind
        self.title = title
        self.what = what
        self.howOften = howOften
        self.points = points
        self.chartNote = chartNote
        self.weekLine = weekLine
        self.bandLine = bandLine
        self.standing = standing
        self.bandMs = bandMs
        self.changeLine = changeLine
        self.footnote = footnote
    }
}
