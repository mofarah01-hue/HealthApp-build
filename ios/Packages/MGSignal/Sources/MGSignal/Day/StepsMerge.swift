import Foundation
import MGDomain

/// ALG-040:merged v2 — the day's steps from the phone where it was carried, from the strap in the minutes it was not
/// (D-LOAD-WALK-1 items 5 and 12, D-LOAD-WALK-2, Mo 2026-10-17: "iPhone steps where the phone was carried; the 100 Hz motion
/// model fills the gaps, e.g. soccer without the phone"). Pure functions, no I/O.
///
/// Grain: ONE MINUTE of the local day. Apple Health's step samples (usually hourly sums on this app, sometimes finer) are the
/// phone's "windows". For each window:
///  - the phone's steps are spread evenly over its minutes, EXCEPT
///  - when the strap counted at least `minFillPerHour` x (window hours) steps in the window and the phone has fewer than
///    `missRatio` of that, the phone was not carried (or not for most of the window): the strap's per-minute counts REPLACE
///    the phone's for that window.
/// Minutes inside no phone window (the phone recorded nothing there) take the strap's count when it is at least
/// `gapMinSteps` in that minute. A minute is never the sum of the two, so nothing is counted twice. The floor, the ratio and the
/// gap gate are ours (no published rule for combining a phone with a wrist counter); labelled so.
///
/// The strap's minutes come from, in this order (D-ALG-TIERS): the 100 Hz wrist walking model (ENHANCED tier, minutes where
/// raw motion was on) else the calibrated R18 step counter (BASE tier: ticks / ticks-per-step). The wrist model is a peak
/// detector on the band-passed acceleration magnitude (`WristWalking`), the single-parameter peak-detection family that
/// Marcotte et al. 2024 (Analytical validation of wrist-worn accelerometer step-count methods, open-source methods compared on
/// structured and free-living data) found to have the least bias in structured walking; the machine-learning alternative,
/// Small et al. 2023-24 (OxWearables `stepcount`, UK Biobank wrist data; 12.5 % MAPE free-living), needs a neural network and is
/// not ported. Minutes where the strap was worn away from the wrist (`WearPolicy`) contribute nothing from the strap.
/// The note names the mix: how many steps and minutes came from each source.
public enum StepsMerge {
    public static let method = "ALG-040:merged@2 phone-first, 100 Hz wrist model or strap counter fills the minutes the phone missed"
    public static let paramsVersion = "minute window-floor100/h ratio0.5 gap5/min"
    public static let minFillPerHour = 100.0
    public static let missRatio = 0.5
    public static let gapMinSteps = 5.0
    public static let minutesPerDay = 1440
    /// A minute counts as covered by the 100 Hz motion when it holds this many full raw-motion seconds.
    public static let coveredSeconds = 30

    public enum Kind: String, Sendable, Equatable {
        /// 100 Hz wrist walking model (ENHANCED tier).
        case wrist100Hz
        /// R18 step counter, ticks / ticks-per-step (BASE tier).
        case counter

        public var label: String { self == .wrist100Hz ? "100 Hz wrist walking model" : "strap step counter" }
    }

    public struct StrapMinute: Sendable, Equatable {
        public var steps: Double
        public var kind: Kind

        public init(steps: Double, kind: Kind) {
            self.steps = steps
            self.kind = kind
        }
    }

    public struct Sample: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var steps: Double

        public init(start: Double, end: Double, steps: Double) {
            self.start = start
            self.end = end
            self.steps = steps
        }
    }

    public struct Fill: Sendable, Equatable {
        public var minute: Int
        public var steps: Double
        public var kind: Kind
    }

    public struct Result: Sendable, Equatable {
        public var total: Double
        public var phoneSteps: Double
        public var phoneMinutes: Int
        /// The minutes the strap supplied.
        public var fills: [Fill]
        public var phoneSource: String?
        /// Minutes where the strap had steps but was not on the wrist, so they were left out.
        public var strapOffMinutes: [Int]
        /// Days of his own data the counter's ticks-per-step rests on (D-POP-PRIOR label); nil when the counter was not used.
        public var calibrationDays: Int?

        public func steps(_ k: Kind) -> Double { fills.filter { $0.kind == k }.reduce(0) { $0 + $1.steps } }
        public func minutes(_ k: Kind) -> [Int] { fills.filter { $0.kind == k }.map(\.minute) }
        public var strapSteps: Double { fills.reduce(0) { $0 + $1.steps } }
    }

    /// `phone`: the chosen Health source's samples. `strap`: minute index -> the strap's steps in that minute and where they came
    /// from. `strapOff`: minutes where the strap's steps do not count (worn away from the wrist). `origin` = local midnight.
    /// Missing (not 0) when neither source has any steps at all.
    public static func merge(phone: [Sample], phoneSource: String?, strap: [Int: StrapMinute], strapOff: Set<Int> = [],
                             origin: Double, calibrationDays: Int? = nil) -> Computed<Result> {
        let usable = strap.filter { !strapOff.contains($0.key) && $0.value.steps > 0 && (0..<minutesPerDay).contains($0.key) }
        let wins: [(m0: Int, m1: Int, steps: Double)] = phone.compactMap { s in
            guard s.steps.isFinite, s.steps > 0 else { return nil }
            let m0 = Int(((s.start - origin) / 60).rounded(.down))
            let m1 = max(m0, Int(((s.end - origin) / 60).rounded(.up)) - 1)
            guard m1 >= 0, m0 < minutesPerDay else { return nil }
            return (max(m0, 0), min(m1, minutesPerDay - 1), s.steps)
        }.sorted { $0.m0 < $1.m0 }
        if wins.isEmpty && usable.isEmpty {
            return .missing("no Apple Health steps for this day and no strap steps to fill with"
                + (strap.isEmpty ? "" : " (the strap's steps were off: it was not on the wrist)"))
        }
        var phoneMin = [Double](repeating: 0, count: minutesPerDay)
        var claimed = [Bool](repeating: false, count: minutesPerDay)
        var fills: [Fill] = []
        for w in wins {
            let n = w.m1 - w.m0 + 1
            let minutes = (w.m0...w.m1).filter { !claimed[$0] }
            if minutes.isEmpty { continue }
            let strapSum = minutes.reduce(0.0) { $0 + (usable[$1]?.steps ?? 0) }
            let floor = minFillPerHour * Double(n) / 60
            for m in minutes { claimed[m] = true }
            if strapSum >= floor && w.steps < missRatio * strapSum {
                for m in minutes { if let u = usable[m] { fills.append(Fill(minute: m, steps: u.steps, kind: u.kind)) } }
            } else {
                for m in minutes { phoneMin[m] = w.steps / Double(n) }
            }
        }
        for (m, u) in usable.sorted(by: { $0.key < $1.key }) where !claimed[m] && u.steps >= gapMinSteps {
            fills.append(Fill(minute: m, steps: u.steps, kind: u.kind))
        }
        let off = strap.filter { strapOff.contains($0.key) && $0.value.steps > 0 }.keys.sorted()
        let phoneSteps = phoneMin.reduce(0, +)
        let r = Result(total: phoneSteps + fills.reduce(0) { $0 + $1.steps }, phoneSteps: phoneSteps,
                       phoneMinutes: phoneMin.filter { $0 > 0 }.count, fills: fills.sorted { $0.minute < $1.minute },
                       phoneSource: phoneSource, strapOffMinutes: off, calibrationDays: calibrationDays)
        return .success(r)
    }

    /// "2:10 PM" for minute index 850 (Mo reads 12-hour clocks).
    static func clock(_ minute: Int) -> String {
        let t = ((minute % 1440) + 1440) % 1440
        let h = t / 60, m = t % 60
        return "\(h % 12 == 0 ? 12 : h % 12):\(m < 10 ? "0" : "")\(m) \(h < 12 ? "AM" : "PM")"
    }

    /// Runs of consecutive minutes as "2:10 PM to 2:40 PM" (a run's end is the minute after its last), comma separated; more than
    /// `limit` runs are cut with the count.
    static func ranges(_ minutes: [Int], limit: Int = 6) -> String {
        let ms = Set(minutes).sorted()
        var runs: [String] = []
        var i = 0
        while i < ms.count {
            var j = i
            while j + 1 < ms.count && ms[j + 1] == ms[j] + 1 { j += 1 }
            runs.append("\(clock(ms[i])) to \(clock(ms[j] + 1))")
            i = j + 1
        }
        if runs.count > limit { return runs.prefix(limit).joined(separator: ", ") + " and \(runs.count - limit) more" }
        return runs.joined(separator: ", ")
    }

    static func grouped(_ v: Double) -> String {
        let n = Int(v.rounded())
        var out = ""
        for (i, c) in String(abs(n)).reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    /// The source mix in words, shown beside the number.
    public static func note(_ r: Result) -> String {
        let src = r.phoneSource.map { " (\($0))" } ?? ""
        var parts = ["phone\(src) \(grouped(r.phoneSteps)) steps over \(r.phoneMinutes) min"]
        for k in [Kind.wrist100Hz, .counter] where !r.minutes(k).isEmpty {
            // D-POP-PRIOR: the counter's ticks-per-step is only ever his own (no published value for this counter), say so.
            let basis = (k == .counter) ? r.calibrationDays.map { " (ticks per step: yours, \($0) days; no population value exists)" } ?? "" : ""
            parts.append("\(k.label) \(grouped(r.steps(k))) steps in \(r.minutes(k).count) min the phone missed\(basis): "
                + ranges(r.minutes(k)))
        }
        if r.fills.isEmpty { parts.append("the strap filled no minute") }
        if !r.strapOffMinutes.isEmpty {
            parts.append("strap steps off at \(ranges(r.strapOffMinutes)) (not worn on the wrist)")
        }
        return parts.joined(separator: "; ") + ". Per minute: the phone's count unless the strap counted at least "
            + "\(Int(minFillPerHour)) per hour of its window and the phone under half of that, then the strap's replaces it (never "
            + "added); minutes the phone recorded nothing take the strap's when it is at least \(Int(gapMinSteps)). "
            + "Ours, not validated against a reference count."
    }

    /// Sums of per-minute sample steps: each sample spread over the minutes it overlaps in proportion to the time (a sample
    /// inside one minute goes whole to it). Used for the strap's bouts; minutes outside 0..<1440 dropped.
    public static func spread(_ spans: [(start: Double, end: Double, steps: Double)], origin: Double) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for s in spans where s.steps.isFinite && s.steps > 0 {
            let len = s.end - s.start
            var m = Int(((s.start - origin) / 60).rounded(.down))
            if len <= 0 {
                if (0..<minutesPerDay).contains(m) { out[m, default: 0] += s.steps }
                continue
            }
            while true {
                let a = max(s.start, origin + Double(m) * 60)
                let b = min(s.end, origin + Double(m + 1) * 60)
                if b > a, (0..<minutesPerDay).contains(m) { out[m, default: 0] += s.steps * (b - a) / len }
                if origin + Double(m + 1) * 60 >= s.end || m > minutesPerDay { break }
                m += 1
            }
        }
        return out
    }

    /// Minute indexes overlapped by any span.
    public static func minutes(overlapping spans: [ClosedRange<Double>], origin: Double) -> Set<Int> {
        var out = Set<Int>()
        for s in spans where s.upperBound > s.lowerBound {
            let first = max(0, Int(((s.lowerBound - origin) / 60).rounded(.down)))
            let last = min(minutesPerDay - 1, Int(((s.upperBound - origin) / 60).rounded(.up)) - 1)
            if last >= first { for m in first...last { out.insert(m) } }
        }
        return out
    }
}
