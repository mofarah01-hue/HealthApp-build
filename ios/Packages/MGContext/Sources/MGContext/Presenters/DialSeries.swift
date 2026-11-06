import Foundation
import MGDomain

// The Sundial's day as a 5-minute time series (round 8, T10023, audit UI-SCRUB-A §5 step 5).
//
// 288 buckets of 5 minutes over the dial's one fixed 24 h window (`DialScrubIndex.windowStart`), so a finger on the dial
// can be told what the day looked like at that time: heart rate, cumulative strain, stress, caffeine in the body and
// the flags (asleep / awake, workout, a note logged). Built once per state change by `DialPresenter.make`, off the main
// thread with the rest of the screen; `DialScrubIndex` turns it into the lines on the time-scrub card.
//
// ONLY values that already exist go in:
// * heart rate: the stored `hr_5min` series DayPipeline writes (mean beat rate of each clean 5-minute window, phone);
// * caffeine in the body: the dial's own curve (ALG-060, phone);
// * the flags: the dial's own arcs (stages, naps, awake time, workouts, strap-off gaps) and logged notes;
// * strain and stress: the stored series named `strainName` / `stressName` IF a later round starts writing them.
//   Today nothing does: strain is one number per day (ALG-036) and stress a day score, so the channels stay empty and
//   say why. Nothing here estimates or interpolates a value that is not stored.
// Each channel carries its source word (strap data / ours on phone / ours on PC / Apple / WHOOP history).

/// Where a value on the time-scrub card came from (the data-source terms: strap data, ours, WHOOP cloud history, Apple).
public enum DialDataSource: String, Sendable, CaseIterable {
    case strap = "strap data"
    case phone = "ours on phone"
    case pc = "ours on PC"
    case apple = "Apple"
    case whoopHistory = "WHOOP history"

    public var word: String { rawValue }

    static func of(_ c: ComputedOn?) -> DialDataSource {
        switch c {
        case .strap?: return .strap
        case .pc?: return .pc
        case .phone?, nil: return .phone
        }
    }

    static func of(_ e: EventSource) -> DialDataSource {
        switch e {
        case .healthkit: return .apple
        case .import: return .whoopHistory
        case .pc: return .pc
        case .strap, .detected: return .strap
        default: return .phone
        }
    }
}

public struct DialSeries: Equatable, Sendable {
    public static let step: TimeInterval = 300
    public static let count = 288

    /// Stored series names the dial reads (the snapshot's `dialSeries` holds only these).
    public static let hrName = "hr_5min"
    /// Not written by anything yet (strain is one number per day); read when a later round stores it.
    public static let strainName = "strain_cumulative_5min"
    /// Not written by anything yet (stress is a day score).
    public static let stressName = "stress_5min"
    public static let wantedNames: Set<String> = [hrName, strainName, stressName]

    /// One numbered channel: a value per bucket, nil where nothing is stored.
    public struct Channel: Equatable, Sendable {
        public var label: String
        public var unit: String
        public var values: [Double?]
        public var source: DialDataSource?
        /// Why the whole channel is empty (no series at all); also the reason shown for a blank bucket when the
        /// channel does have data elsewhere (`blankInSeries`).
        public var whyNone: String
        public var blankInSeries: String

        public var hasAny: Bool { values.contains { $0 != nil } }

        public init(label: String, unit: String, values: [Double?], source: DialDataSource?, whyNone: String,
                    blankInSeries: String) {
            self.label = label
            self.unit = unit
            self.values = values
            self.source = source
            self.whyNone = whyNone
            self.blankInSeries = blankInSeries
        }
    }

    /// Bit flags per bucket (`flags`).
    public static let asleep: UInt8 = 1
    public static let awake: UInt8 = 2
    public static let workout: UInt8 = 4
    public static let note: UInt8 = 8

    /// First instant of bucket 0: the dial window's start.
    public var start: Date
    public var hr: Channel
    public var strain: Channel
    public var stress: Channel
    public var caffeine: Channel
    public var flags: [UInt8]
    public var sleepSource: DialDataSource
    public var workoutSource: DialDataSource
    public var noteSource: DialDataSource

    public init(start: Date, hr: Channel, strain: Channel, stress: Channel, caffeine: Channel, flags: [UInt8],
                sleepSource: DialDataSource, workoutSource: DialDataSource, noteSource: DialDataSource) {
        self.start = start
        self.hr = hr
        self.strain = strain
        self.stress = stress
        self.caffeine = caffeine
        self.flags = flags
        self.sleepSource = sleepSource
        self.workoutSource = workoutSource
        self.noteSource = noteSource
    }

    /// The bucket a time falls in, or nil outside the 24 h.
    public func bucket(of t: Date) -> Int? {
        let j = Int((t.timeIntervalSince(start) / Self.step).rounded(.down))
        return (0..<Self.count).contains(j) ? j : nil
    }

    // MARK: Build

    /// The series for a built dial. `dial` is final apart from this field, so its window start, arcs and caffeine curve
    /// are the ones the scrub index will use.
    public static func make(_ s: PresenterSnapshot, dial: DialState) -> DialSeries {
        let start = DialScrubIndex.windowStart(for: dial, calendar: s.calendar)
        let stored = s.dialSeries

        func channel(_ name: String, label: String, whyNone: String, blank: String) -> Channel {
            let mine = stored.filter { $0.name == name }
            return Channel(label: label, unit: mine.first?.unit ?? "", values: fill(mine, start: start),
                           source: mine.isEmpty ? nil : DialDataSource.of(mine.first?.computedOn),
                           whyNone: whyNone, blankInSeries: blank)
        }
        let hr = channel(hrName, label: "Heart rate",
                         whyNone: "No 5-minute heart-rate series is stored for these days yet.",
                         blank: "No clean 5-minute heart-rate window is stored for this time.")
        let strain = channel(strainName, label: "Strain so far",
                             whyNone: "Strain is one score per day, so there is no strain by time of day to show.",
                             blank: "No strain value is stored for this time.")
        let stress = channel(stressName, label: "Body arousal",
                             whyNone: "Body arousal is a day score and has no times yet.",
                             blank: "No body-arousal value is stored for this time.")

        // Caffeine in the body: the dial's own curve, every 10 min, so each sample covers the two buckets around it.
        var caf = [Double?](repeating: nil, count: count)
        let curve = dial.caffeineCurve.filter { $0.mg.isFinite && $0.mg >= 1 }
        if !curve.isEmpty {
            for j in 0..<count {
                let mid = start.addingTimeInterval(Double(j) * step + step / 2)
                var best: (mg: Double, d: TimeInterval)?
                for p in curve {
                    let d = abs(p.at.timeIntervalSince(mid))
                    if best == nil || d < best!.d { best = (p.mg, d) }
                }
                if let b = best, b.d <= DialScrubIndex.curveTolerance { caf[j] = b.mg }
            }
        }
        let caffeine = Channel(label: "Caffeine in you", unit: "mg", values: caf, source: .phone,
                               whyNone: "No caffeine logged in the last hours.",
                               blankInSeries: "No caffeine in you at this time.")

        // Flags from the dial's own arcs and the logged events.
        var flags = [UInt8](repeating: 0, count: count)
        let asleepKinds: Set<DialArc.Kind> = [.deep, .light, .rem, .unstaged, .nap]
        for j in 0..<count {
            let b0 = start.addingTimeInterval(Double(j) * step)
            let mid = b0.addingTimeInterval(step / 2)
            var f: UInt8 = 0
            var strapOff = false
            for a in dial.arcs where a.start <= mid && mid < a.end {
                if asleepKinds.contains(a.kind), !a.pale { f |= asleep }
                if a.kind == .awake { f |= awake }
                if a.kind == .awakeElapsed, mid <= dial.now { f |= awake }
                if a.kind == .workout { f |= workout }
                if a.kind == .strapOff { strapOff = true }
            }
            if f & asleep != 0 { f &= ~awake }
            if strapOff { f &= ~(asleep | awake) }
            flags[j] = f
        }
        var noteSrc: DialDataSource = .phone
        var workoutSrc: DialDataSource = .phone
        for e in s.events where !e.removed {
            if let n = e.note, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let j = bucketIndex(e.at, start) {
                flags[j] |= note
                noteSrc = DialDataSource.of(e.source)
            }
            if e.type == .workout { workoutSrc = DialDataSource.of(e.source) }
        }
        return DialSeries(start: start, hr: hr, strain: strain, stress: stress, caffeine: caffeine, flags: flags,
                          sleepSource: sleepSource(s), workoutSource: workoutSrc, noteSource: noteSrc)
    }

    private static func bucketIndex(_ t: Date, _ start: Date) -> Int? {
        let j = Int((t.timeIntervalSince(start) / step).rounded(.down))
        return (0..<count).contains(j) ? j : nil
    }

    /// Stored series onto the 288 buckets. A bucket holding several samples (a finer series) takes their mean; a
    /// sample outside the window is dropped.
    static func fill(_ series: [Series], start: Date) -> [Double?] {
        var sum = [Double](repeating: 0, count: count)
        var n = [Int](repeating: 0, count: count)
        for x in series where x.stepS > 0 {
            for (i, v) in x.values.enumerated() {
                guard let v, v.isFinite else { continue }
                let t = x.start.addingTimeInterval(Double(i) * x.stepS)
                guard let j = bucketIndex(t, start) else { continue }
                sum[j] += v
                n[j] += 1
            }
        }
        return (0..<count).map { n[$0] > 0 ? sum[$0] / Double(n[$0]) : nil }
    }

    /// Who made the stages the dial draws: the same pick as `DialPresenter.stageRuns` (a PC stager first, then the
    /// read variant, then the best-ranked one); the strap's own flag is "strap data", the rest are ours on the phone.
    static func sleepSource(_ s: PresenterSnapshot) -> DialDataSource {
        let hyp = DialPresenter.hypnograms(s)
        // D-SLEEP-PRIORITY-1: the source the one sleep resolver chose (a PC bar only under a PC total).
        if case .pc(let v) = s.sleepFill().stages {
            if let x = hyp.first(where: { $0.variant == v }), !DialPresenter.runs(x.series).isEmpty { return .pc }
        }
        let read = s.readVariant(group: "G-STAGE")
        let ours = hyp.filter { !PresenterSnapshot.pcSleepVariants.contains($0.variant ?? "") }
        var pick = ours.first { $0.variant == read && !DialPresenter.runs($0.series).isEmpty }
        if pick == nil {
            pick = ours.sorted { GroupCatalogue.rank("G-STAGE", $0.variant) < GroupCatalogue.rank("G-STAGE", $1.variant) }
                .first { !DialPresenter.runs($0.series).isEmpty }
        }
        guard let p = pick else { return .phone }
        return p.variant == "strap" ? .strap : .phone
    }
}
