import Foundation

// Live HRV tile (0.6.0.12, Mo Nov 5 2026: "live RMSSD flashes a number from a few beats, then vanishes"). Plain data shared by
// MGSignal (which works the windows out) and MGContext (which words them). No maths here.

/// Why a 5-minute window is not an "ideal" one (the grey number's reason on the Live tile).
public enum LiveHRVWhy: Equatable, Sendable {
    /// A workout or movement was running in the window.
    case motion
    /// Fewer clean successive intervals than the minimum (`have`, `need`).
    case tooFewBeats(have: Int, need: Int)
    /// A silence longer than the gap limit inside the window (longest, seconds) left too little of it covered.
    case gaps(longest: Double)
    /// Too much of the window's time is not covered by clean beats (percent covered).
    case coverage(percent: Int)
    /// The beats overlap in time (coverage above 110 %): a duplicate or interleaved stream, so nothing is trusted.
    case duplicates
    /// No beats at all in the window.
    case noBeats

    /// One plain-words line for the tile ("too few clean beats (have 12, need 20)").
    public var text: String {
        switch self {
        case .motion: return "movement or a workout in the last 5 minutes"
        case let .tooFewBeats(have, need): return "too few clean beats (have \(have), need \(need))"
        case let .gaps(longest): return "gaps in the beats (longest \(Int(longest.rounded())) s)"
        case let .coverage(percent): return "only \(percent) % of the last 5 minutes has clean beats"
        case .duplicates: return "the beats overlap (a duplicate or mixed-up stream)"
        case .noBeats: return "no beats in the last 5 minutes"
        }
    }
}

/// One 5-minute window of live R-R, judged. `ideal` = it met every rule; only ideal windows count toward the tile's average.
public struct LiveHRVWindow: Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// RMSSD in ms over the clean successive intervals; set for an ideal window, and (grey, provisional) for a window with at
    /// least three clean pairs that missed a rule. nil = nothing computable.
    public var rmssd: Double?
    /// Mean of the clean intervals, ms (for the autonomic-load heart rate); same availability as `rmssd`.
    public var meanRR: Double?
    /// Clean successive pairs behind `rmssd`.
    public var cleanPairs: Int
    /// Clean beat time over the window length, 0...1.
    public var coverage: Double
    public var ideal: Bool
    public var why: LiveHRVWhy?

    public init(start: Date, end: Date, rmssd: Double? = nil, meanRR: Double? = nil, cleanPairs: Int = 0,
                coverage: Double = 0, ideal: Bool = false, why: LiveHRVWhy? = nil) {
        self.start = start
        self.end = end
        self.rmssd = rmssd
        self.meanRR = meanRR
        self.cleanPairs = cleanPairs
        self.coverage = coverage
        self.ideal = ideal
        self.why = why
    }
}

/// What the Live tab gets: the window ending now, and today's finished 5-minute windows (oldest first).
public struct LiveHRVReading: Equatable, Sendable {
    public var latest: LiveHRVWindow
    public var today: [LiveHRVWindow]
    /// "live" (the beats on the phone now) or "stored" (the last stored stretch, shown when nothing streams yet).
    public var source: String

    public init(latest: LiveHRVWindow, today: [LiveHRVWindow], source: String = "live") {
        self.latest = latest
        self.today = today
        self.source = source
    }

    /// Today's ideal windows.
    public var cleanWindows: [LiveHRVWindow] { today.filter { $0.ideal && $0.rmssd != nil } }
}
