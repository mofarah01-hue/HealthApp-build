import Foundation

// The Sundial's one scrub provider (round 8, T10021 / T10023; audit UI-SCRUB-A §1 #5, #12, #13).
//
// A finger on the dial means an hour of the day. This file turns that hour into ONE clock time and ONE sentence, for
// every way the finger can get there (outer ring, centre, VoiceOver), so the same minute always reads the same:
// "3:48 AM · Deep 3:40–4:05 AM · MedA 20 mg 7:15 AM". It replaces the old pair `DialScrub.reading` (capital names,
// 10 min) and `SundialReading.scrubText` (lower case, 12 min, nearest-to-now date guessing).
//
// * One fixed 24 h window per state: it starts at the earlier of midnight and the start of last night's stages, and
//   is 24 h long (never so early that the hand falls outside it). Each dial hour maps to one date inside it, once;
//   nothing is guessed from "nearest to now", so the date cannot flip near the hour opposite the hand.
// * One tolerance (`tolerance`, 10 min) for point marks.
// * 1440 one-minute buckets built once per state (the caller builds the index when the state changes, off the main
//   thread if it wants); a finger move is one array read plus one 12-hour time format.
// Nothing here computes a metric; it names what DialState already holds. Times are 12-hour AM/PM in the calendar's
// zone (MGFormat). A walk has no kind of its own on the dial yet, so it reads as the workout arc it is drawn as.
//
// Known limit: the window is 24 elapsed hours, so on the two days a year the clocks change, the part of the dial after
// the change reads one hour off (the old code had the same gap).

public struct DialScrubIndex: Sendable {
    /// A mark counts as "at" a time within this many seconds (one tolerance for the whole dial).
    public static let tolerance: TimeInterval = 10 * 60
    /// The caffeine curve counts as "at" a time within this many seconds of its nearest sample (10 min apart).
    static let curveTolerance: TimeInterval = 6 * 60

    /// One thing at the probed time.
    public struct Item: Equatable, Sendable {
        /// Stable across the finger's small moves inside the same thing; a change fires the haptic tick.
        public let id: String
        public let text: String
    }

    public struct Reading: Equatable, Sendable {
        /// The time under the finger.
        public let at: Date
        /// Changes only when the finger crosses into a different thing (the haptic trigger).
        public let id: String
        /// "3:52 AM · Deep 3:40–4:05 AM · MedA 20 mg 7:15 AM"; never empty.
        public let text: String
        public let items: [Item]
        /// Round 8 (T10023): the day's numbers and flags at this time, each with its source word or a reason when blank
        /// (heart rate, strain, stress, caffeine in you, asleep / awake, workout, note). Empty when the state has no series.
        public let series: [SeriesLine]
    }

    /// One line of the time-scrub card. `value` nil = blank, and `reason` says why (never an invented number).
    public struct SeriesLine: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let value: String?
        /// "strap data" / "ours on phone" / "ours on PC" / "Apple" / "WHOOP history"; nil when blank.
        public let source: String?
        public let reason: String?
    }

    /// First minute of the window (whole minute).
    public let windowStart: Date
    public var windowEnd: Date { windowStart.addingTimeInterval(86_400) }
    public let now: Date
    private let calendar: Calendar
    /// Wall-clock minute of the day of `windowStart` (0 ..< 1440).
    private let startMinute: Int
    private let dayStart: Date
    /// Distinct item lists; `bucket[k]` is the list at `windowStart + k minutes`.
    private let segments: [[Item]]
    private let bucket: [Int]
    /// 288 five-minute lines (`DialSeries` order); `seriesStart` is bucket 0. Empty when the state has no series.
    private let seriesLines: [[SeriesLine]]
    private let seriesStart: Date?

    // MARK: Build

    public init(state: DialState, calendar: Calendar) {
        let ws = Self.windowStart(for: state, calendar: calendar)
        self.windowStart = ws
        self.now = state.now
        self.calendar = calendar
        let c = calendar.dateComponents([.hour, .minute], from: ws)
        self.startMinute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        self.dayStart = calendar.startOfDay(for: state.now)

        let cands = Self.candidates(state: state, calendar: calendar)
        let curve = Self.curveSamples(state: state, calendar: calendar)
        var segments: [[Item]] = []
        var seen: [String: Int] = [:]
        var bucket = [Int](repeating: 0, count: 1440)
        for k in 0..<1440 {
            let t = ws.addingTimeInterval(Double(k) * 60)
            let items = Self.items(at: t, now: state.now, candidates: cands, curve: curve)
            let key = items.map { $0.id + "§" + $0.text }.joined(separator: "¦")
            if let i = seen[key] {
                bucket[k] = i
            } else {
                seen[key] = segments.count
                bucket[k] = segments.count
                segments.append(items)
            }
        }
        self.segments = segments
        self.bucket = bucket
        self.seriesStart = state.series?.start
        self.seriesLines = state.series.map { Self.lines(for: $0, now: state.now) } ?? []
    }

    /// The window start (see the header). Public so tests and callers can name it.
    public static func windowStart(for s: DialState, calendar: Calendar) -> Date {
        let midnight = calendar.startOfDay(for: s.now)
        let stageKinds: Set<DialArc.Kind> = [.deep, .light, .rem, .awake, .unstaged]
        var start = midnight
        if let n = s.arcs.filter({ stageKinds.contains($0.kind) }).map(\.start).min(), n < start { start = n }
        // The window must hold the hand: never start more than 23 h 59 min before now.
        let floorStart = s.now.addingTimeInterval(-(86_400 - 60))
        if start < floorStart { start = floorStart }

        // Tonight's plan can run past the end of the window (bed 11 PM, wake 7 AM tomorrow): slide the start forward
        // so the plan's far end is on the dial, but never past the earliest thing already recorded or the hand.
        var planEnds: [Date] = s.arcs.filter { $0.kind == .plannedSleep }.map(\.end)
        for tick in s.ticks where tick.kind == .smartWakeWindow || tick.kind == .bedtime {
            planEnds.append(tick.end ?? tick.at)
        }
        if let planEnd = planEnds.max(), planEnd > start.addingTimeInterval(86_400) {
            var recorded: [Date] = s.arcs.filter { $0.kind != .plannedSleep }.map(\.start)
            recorded += s.rimEvents.map(\.at)
            let upper = min(s.now, recorded.filter { $0 >= start }.min() ?? s.now)
            let wanted = planEnd.addingTimeInterval(-86_400)
            start = min(max(start, wanted), max(start, upper))
        }
        return Date(timeIntervalSinceReferenceDate: (start.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    // MARK: Read

    /// The window date a dial hour means: the same answer for the whole life of this index.
    public func date(hour: Double) -> Date {
        windowStart.addingTimeInterval(Double(offset(hour: hour)) * 60)
    }

    /// The reading for a finger at dial `hour` (0 ..< 24, wrapped). Never empty text: with nothing there it says so,
    /// and whether that time is already past or still to come.
    public func reading(hour: Double) -> Reading {
        let k = offset(hour: hour)
        let date = windowStart.addingTimeInterval(Double(k) * 60)
        let found = segments[bucket[k]]
        var head = MGFormat.time(date, calendar: calendar)
        let dayStep = calendar.dateComponents([.day], from: dayStart, to: calendar.startOfDay(for: date)).day ?? 0
        if dayStep < 0 { head = "yesterday " + head }
        if dayStep > 0 { head = "tomorrow " + head }
        if found.isEmpty {
            return Reading(at: date, id: "empty", text: head + (date > now ? " · nothing planned" : " · nothing recorded"),
                           items: [], series: lines(at: date))
        }
        let shown = found.prefix(3).map(\.text)
        let more = found.count > 3 ? ["+\(found.count - 3) more"] : []
        return Reading(at: date, id: found.map(\.id).joined(separator: "|"),
                       text: ([head] + shown + more).joined(separator: " · "), items: found, series: lines(at: date))
    }

    /// The series lines of the 5-minute bucket holding `t`; blank lines (with the reason) outside the stored window.
    private func lines(at t: Date) -> [SeriesLine] {
        guard let start = seriesStart, seriesLines.count == DialSeries.count else { return [] }
        let j = Int((t.timeIntervalSince(start) / DialSeries.step).rounded(.down))
        guard (0..<DialSeries.count).contains(j) else { return [] }
        return seriesLines[j]
    }

    private func offset(hour: Double) -> Int {
        let h = Self.positiveMod(hour.isFinite ? hour : 0, 24)
        let minute = Int((h * 60).rounded()) % 1440
        return ((minute - startMinute) % 1440 + 1440) % 1440
    }

    // MARK: Series lines

    /// All 288 buckets' lines, built once with the index.
    static func lines(for series: DialSeries, now: Date) -> [[SeriesLine]] {
        (0..<DialSeries.count).map { j in
            let at = series.start.addingTimeInterval(Double(j) * DialSeries.step)
            let future = at > now
            var out: [SeriesLine] = []
            func number(_ id: String, _ c: DialSeries.Channel, decimals: Int) {
                if let v = c.values.indices.contains(j) ? c.values[j] : nil {
                    let unit = c.unit.isEmpty ? "" : " " + c.unit
                    out.append(SeriesLine(id: id, label: c.label,
                                          value: MGFormat.number(v, decimals: decimals) + unit + (future ? " (predicted)" : ""),
                                          source: c.source?.word, reason: nil))
                } else {
                    let why = !c.hasAny ? c.whyNone : (future ? "Still to come." : c.blankInSeries)
                    out.append(SeriesLine(id: id, label: c.label, value: nil, source: nil, reason: why))
                }
            }
            number("hr", series.hr, decimals: 0)
            number("strain", series.strain, decimals: 1)
            number("stress", series.stress, decimals: 1)
            number("caffeine", series.caffeine, decimals: 0)
            let f: UInt8 = series.flags.indices.contains(j) ? series.flags[j] : 0
            if f & DialSeries.asleep != 0 {
                out.append(SeriesLine(id: "sleep", label: "Sleep", value: "Asleep", source: series.sleepSource.word, reason: nil))
            } else if f & DialSeries.awake != 0 {
                out.append(SeriesLine(id: "sleep", label: "Sleep", value: "Awake", source: series.sleepSource.word, reason: nil))
            } else {
                out.append(SeriesLine(id: "sleep", label: "Sleep", value: nil, source: nil,
                                      reason: future ? "Still to come." : "No sleep or wake record for this time."))
            }
            if f & DialSeries.workout != 0 {
                out.append(SeriesLine(id: "workout", label: "Workout", value: "Yes", source: series.workoutSource.word, reason: nil))
            }
            if f & DialSeries.note != 0 {
                out.append(SeriesLine(id: "note", label: "Note", value: "Logged", source: series.noteSource.word, reason: nil))
            }
            return out
        }
    }

    // MARK: What is at a time

    /// Something with a time span on the dial. Matches a probed time `t` when `t` is inside it (arcs: half open) or
    /// within `tol` seconds of it; `distance` orders the marks.
    struct Candidate {
        let id: String
        let order: Int
        let start: Date
        let end: Date
        let halfOpen: Bool
        let tol: TimeInterval
        let text: String
        /// Text and id once the probed time is after `now` (arcs, focus); nil = same either way.
        let future: (id: String, text: String)?
    }

    struct CurveSample {
        let at: Date
        let text: String
        let futureText: String
    }

    static func candidates(state s: DialState, calendar: Calendar) -> [Candidate] {
        var out: [Candidate] = []
        let time = { (d: Date) in MGFormat.time(d, calendar: calendar) }

        // Stage / nap / workout / strap-off windows (adjacent arcs of one kind read as one window).
        let wins = windows(of: s.arcs)
        for (i, arc) in s.arcs.enumerated() where arc.kind != .awakeElapsed {
            let w = wins[i]
            let base = "\(arcName(arc.kind)) \(MGFormat.timeRange(w.start, w.end, calendar: calendar))"
            let id = "arc:\(arc.kind.rawValue):\(Int(w.start.timeIntervalSince1970))"
            let pastPredicted = arc.pale && arc.kind != .plannedSleep
            let futurePredicted = arc.kind != .plannedSleep
            out.append(Candidate(id: pastPredicted ? id + ":p" : id, order: 0, start: arc.start, end: arc.end,
                                 halfOpen: true, tol: 0, text: base + (pastPredicted ? " (predicted)" : ""),
                                 future: (futurePredicted ? id + ":p" : id, base + (futurePredicted ? " (predicted)" : ""))))
        }

        for tick in s.ticks {
            let at = Int(tick.at.timeIntervalSince1970)
            switch tick.kind {
            case .smartWakeWindow:
                let end = tick.end ?? tick.at
                let range = tick.end.map { MGFormat.timeRange(tick.at, $0, calendar: calendar) } ?? time(tick.at)
                out.append(Candidate(id: "tick:smartwake:\(at)", order: 1, start: tick.at, end: end, halfOpen: false,
                                     tol: tick.end == nil ? tolerance : 0, text: "Smart-wake window \(range)", future: nil))
            case .bedtime:
                out.append(Candidate(id: "tick:bedtime:\(at)", order: 1, start: tick.at, end: tick.at, halfOpen: false,
                                     tol: tolerance, text: "Bedtime \(time(tick.at))" + (tick.hollow ? " (missed)" : ""),
                                     future: nil))
            case .caffeineCutoff:
                out.append(Candidate(id: "tick:cutoff:\(at)", order: 1, start: tick.at, end: tick.at, halfOpen: false,
                                     tol: tolerance, text: "Caffeine cut-off \(time(tick.at))", future: nil))
            case .wakeMarker:
                out.append(Candidate(id: "tick:woke:\(at)", order: 1, start: tick.at, end: tick.at, halfOpen: false,
                                     tol: tolerance, text: "Woke \(time(tick.at))", future: nil))
            }
        }

        for e in s.rimEvents {
            let end = e.kind == .caffeine ? max(e.end ?? e.at, e.at) : e.at
            let when = end > e.at ? MGFormat.timeRange(e.at, end, calendar: calendar) : time(e.at)
            let id = "mark:\(e.kind.rawValue):\(e.eventID ?? String(Int(e.at.timeIntervalSince1970)))"
            out.append(Candidate(id: id, order: 4, start: e.at, end: end, halfOpen: false, tol: tolerance,
                                 text: "\(rimName(e)) \(when)", future: nil))
        }
        return out
    }

    static func curveSamples(state s: DialState, calendar: Calendar) -> [CurveSample] {
        s.caffeineCurve.filter { $0.mg.isFinite && $0.mg >= 1 }.map {
            let base = "Caffeine ≈ \(MGFormat.number($0.mg, decimals: 0)) mg in you"
            return CurveSample(at: $0.at, text: base + ($0.at > s.now ? " (predicted)" : ""),
                               futureText: base + " (predicted)")
        }
    }

    static func items(at t: Date, now: Date, candidates: [Candidate], curve: [CurveSample]) -> [Item] {
        let future = t > now
        var hits: [(order: Int, distance: TimeInterval, item: Item)] = []
        for c in candidates {
            let d: TimeInterval
            if c.halfOpen {
                guard c.start <= t && t < c.end else { continue }
                d = 0
            } else {
                d = distance(t, from: c.start, to: c.end)
                guard d <= c.tol else { continue }
            }
            if future, let f = c.future {
                hits.append((c.order, d, Item(id: f.id, text: f.text)))
            } else {
                hits.append((c.order, d, Item(id: c.id, text: c.text)))
            }
        }
        // Caffeine in body: the nearest curve sample (every 10 min).
        var best: (CurveSample, TimeInterval)?
        for p in curve {
            let d = abs(p.at.timeIntervalSince(t))
            if best == nil || d < best!.1 { best = (p, d) }
        }
        if let (p, d) = best, d <= curveTolerance {
            hits.append((3, d, Item(id: "caffeine", text: future ? p.futureText : p.text)))
        }
        return hits
            .sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                if a.distance != b.distance { return a.distance < b.distance }
                return a.item.id < b.item.id
            }
            .map(\.item)
    }

    /// Each arc's window: the arc grown over directly adjacent arcs of the same kind and predicted-ness (stage runs
    /// the model split). Built once, by sorting, not by the old repeated scans.
    static func windows(of arcs: [DialArc]) -> [(start: Date, end: Date)] {
        var out = arcs.map { (start: $0.start, end: $0.end) }
        var groups: [String: [Int]] = [:]
        for (i, a) in arcs.enumerated() { groups["\(a.kind.rawValue)|\(a.pale)", default: []].append(i) }
        for (_, idx) in groups {
            let sorted = idx.sorted { arcs[$0].start < arcs[$1].start }
            var run: [Int] = []
            var runStart = Date.distantPast, runEnd = Date.distantPast
            func flush() {
                for i in run { out[i] = (runStart, runEnd) }
                run = []
            }
            for i in sorted {
                let a = arcs[i]
                if run.isEmpty {
                    runStart = a.start; runEnd = a.end
                } else if a.start <= runEnd.addingTimeInterval(60) {
                    runEnd = max(runEnd, a.end)
                } else {
                    flush()
                    runStart = a.start; runEnd = a.end
                }
                run.append(i)
            }
            flush()
        }
        return out
    }

    /// 0 inside [start, end], else seconds to the nearer end.
    static func distance(_ t: Date, from start: Date, to end: Date) -> TimeInterval {
        if t < start { return start.timeIntervalSince(t) }
        if t > end { return t.timeIntervalSince(end) }
        return 0
    }

    // MARK: Names

    static func arcName(_ kind: DialArc.Kind) -> String {
        switch kind {
        case .deep: return "Deep"
        case .light: return "Light"
        case .rem: return "REM"
        case .awake: return "Awake in the night"
        case .unstaged: return "Asleep (stage unknown)"
        case .plannedSleep: return "Asleep (predicted)"
        case .nap: return "Nap"
        case .napUnconfirmed: return "Nap? (not confirmed yet)"
        case .workout: return "Workout"
        case .strapOff: return "Strap off, nothing recorded"
        case .awakeElapsed: return "Awake"
        }
    }

    static func rimName(_ e: RimEvent) -> String {
        switch e.kind {
        case .vape: return e.hollow ? "Vape hit (detected, not confirmed)" : "Vape hit"
        case .medication: return e.label ?? "Medication"
        case .caffeine: return e.label ?? "Caffeine"
        case .food: return e.label ?? "Food"
        case .supplement: return e.label ?? "Supplements"
        }
    }

    static func positiveMod(_ x: Double, _ m: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }
}
