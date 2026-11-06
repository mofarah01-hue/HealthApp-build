import Foundation
import MGDomain

// Sleep family (WP-10), retrospective: shared inputs, the hypnogram alphabet and the motion grid every sleep
// algorithm reads. Python reference (VERIFIED on the PC): app/pclab/mglab/ref/sleep.py; goldens
// app/shared/golden/sleep/ (python app/pclab/golden/gen_sleep.py --check). WRITTEN, NOT COMPILED (2026-10-11).

/// Per-second strap rows for a span (columns of MGDomain `R18Second`). Rows may be in any order; each `ts` once.
public struct SleepSeconds: Sendable, Equatable {
    public var ts: [Int64]
    public var hr: [Double?]
    public var gx: [Double?]
    public var gy: [Double?]
    public var gz: [Double?]
    /// R18 byte 81 high nibble, (b >> 4) & 3: 0 wake / 1 still / 2 asleep / 3 up (noop docs/PROTOCOL_SENSORS.md).
    public var sleepState: [Int?]
    /// R18 activity class @63: 0 still / 1 walk / 2 run (noop HistoricalStreams.swift).
    public var activityClass: [Int?]
    /// P200: false = HR-CLEAN dropped this second (spike, out of range, bad optical quality); the HR minute / epoch means skip it.
    /// Angles and activity are untouched: a dropped HR second is still a worn second.
    public var hrKeep: [Bool]

    public init(ts: [Int64], hr: [Double?], gx: [Double?], gy: [Double?], gz: [Double?], sleepState: [Int?],
                activityClass: [Int?], hrKeep: [Bool]? = nil) {
        self.hrKeep = hrKeep ?? [Bool](repeating: true, count: ts.count)
        self.ts = ts
        self.hr = hr
        self.gx = gx
        self.gy = gy
        self.gz = gz
        self.sleepState = sleepState
        self.activityClass = activityClass
    }

    /// From stored R18 rows (MGStore `StreamReads`).
    /// P200: `.hampel` (default) marks spike / out-of-range / bad-quality HR seconds in `hrKeep` (no motion gate: ALG-120
    /// reads HR rising with movement as a wake sign); `.raw` keeps every second, the previous method.
    public init(r18: [R18Second], hrCleaning: HRClean.Method = .hampel) {
        let keep: [Bool]? = hrCleaning == .raw ? nil
            : HRClean.mask(ts: r18.map(\.ts), bpm: r18.map(\.hr), quality: r18.map(\.quality)).keep
        self.init(ts: r18.map(\.ts), hr: r18.map(\.hr), gx: r18.map(\.gx), gy: r18.map(\.gy), gz: r18.map(\.gz),
                  sleepState: r18.map(\.sleepState), activityClass: r18.map(\.activityClass), hrKeep: keep)
    }

    public var count: Int { ts.count }
}

/// ALG-004 A corrected beats: end times (unix s, ascending) and R-R (ms). WP-22 runs ALG-004 once per night:
/// `SleepBeats(ALG004.correct(rrMs: rr, times: BeatClock.times(points: sorted)))`.
public struct SleepBeats: Sendable, Equatable {
    public var times: [Double]
    public var rrMs: [Double]

    public init(times: [Double], rrMs: [Double]) {
        self.times = times
        self.rrMs = rrMs
    }

    public init(_ corrected: ALG004.Corrected) {
        self.init(times: corrected.times, rrMs: corrected.rrMs)
    }

    public static let empty = SleepBeats(times: [], rrMs: [])
}

/// A [start, end) interval in unix seconds (a night window to exclude, a sleep, an observed stretch).
public struct SleepInterval: Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// The hypnogram alphabet, one character per 30-s epoch (shared with WP-11's live stager). Epochs are clock-aligned:
/// epoch start = floor(t / 30) · 30 unix s.
public enum SleepStageCode: String, Sendable, CaseIterable {
    case wake = "W"
    case light = "L"
    case deep = "D"
    case rem = "R"
    /// Asleep, stage unknown (no usable R-R / HR, or a sleep/wake-only member such as the strap flag).
    case asleep = "S"
    /// No data (strap off, no record).
    case noData = "."

    var byte: UInt8 { rawValue.utf8.first! }
    var isAsleep: Bool { self == .light || self == .deep || self == .rem || self == .asleep }
}

/// A hypnogram: `epoch0` = start of the first 30-s epoch (unix s), `codes` = one `SleepStageCode` character per epoch.
public struct SleepHypnogram: Sendable, Equatable {
    public static let epochSeconds: Int64 = 30

    public var epoch0: Int64
    public var codes: String

    public init(epoch0: Int64, codes: String) {
        self.epoch0 = epoch0
        self.codes = codes
    }

    /// Runs of one code as [start, end) unix seconds, for the Night chart (`StageSegment`) and the dial.
    public func runs() -> [SleepStageRun] {
        let b = Array(codes.utf8)
        var out: [SleepStageRun] = []
        var k = 0
        while k < b.count {
            var j = k
            while j + 1 < b.count && b[j + 1] == b[k] { j += 1 }
            if let c = SleepStageCode(rawValue: String(UnicodeScalar(b[k]))) {
                out.append(SleepStageRun(code: c, start: epoch0 + Int64(k) * Self.epochSeconds,
                                         end: epoch0 + Int64(j + 1) * Self.epochSeconds))
            }
            k = j + 1
        }
        return out
    }
}

public struct SleepStageRun: Sendable, Equatable {
    public var code: SleepStageCode
    public var start: Int64
    public var end: Int64

    public init(code: SleepStageCode, start: Int64, end: Int64) {
        self.code = code
        self.start = start
        self.end = end
    }
}

/// The grids every sleep function reads (Python `motion_grid`). Origin t0 = floor(first ts / 60) · 60, end =
/// ceil((last ts + 1) / 60) · 60, so each minute holds twelve 5-s epochs and two 30-s epochs.
///   z[k]     mean z-angle (van Hees 2015) of the worn seconds in 5-s epoch k (≥ 3 of them), else nil
///   d[k]     |z[k] − z[k−1]| when both exist (d[0] = nil)
///   act[j]   minute activity, degrees ("ours v1"): Σ of the minute's 12 d values × 12 / n_valid, when ≥ 10 valid
///   hrMin[j] mean on-skin HR of minute j (≥ 30 s); hr30[e] of 30-s epoch e (≥ 15 s)
/// A second is "worn" when HR > 0 and a non-zero gravity vector was decoded (OpenStrap van_hees.dart: absent gravity
/// stored as (0,0,0) is not a measurement; HR ≤ 0 = off skin as in ALG-012).
public struct SleepMotionGrid: Sendable, Equatable {
    public static let angleEpochSeconds: Int64 = 5
    public static let minuteSeconds: Int64 = 60
    static let angleMinWorn = 3
    static let minuteMinValidDeltas = 10
    static let minuteMinHR = 30
    static let epochMinHR = 15

    public var t0: Int64
    public var z: [Double?]
    public var d: [Double?]
    public var act: [Double?]
    public var hrMin: [Double?]
    public var hr30: [Double?]
    public var rows: Int

    public init(t0: Int64, z: [Double?], d: [Double?], act: [Double?], hrMin: [Double?], hr30: [Double?], rows: Int) {
        self.t0 = t0
        self.z = z
        self.d = d
        self.act = act
        self.hrMin = hrMin
        self.hr30 = hr30
        self.rows = rows
    }

    public var n5: Int { z.count }

    /// van Hees 2015 z-angle (arm elevation vs gravity), degrees.
    public static func zAngle(x: Double, y: Double, z: Double) -> Double {
        atan2(z, (x * x + y * y).squareRoot()) * 180.0 / Double.pi
    }

    static func worn(_ hr: Double?, _ gx: Double?, _ gy: Double?, _ gz: Double?) -> Bool {
        guard let h = hr, h > 0, let x = gx, let y = gy, let z = gz else { return false }
        return !(x == 0 && y == 0 && z == 0)
    }

    public static func build(_ s: SleepSeconds) -> SleepMotionGrid {
        let n = s.ts.count
        guard n > 0, let tFirst = s.ts.min(), let tLast = s.ts.max() else {
            return SleepMotionGrid(t0: 0, z: [], d: [], act: [], hrMin: [], hr30: [], rows: 0)
        }
        let t0 = SleepMath.floorDiv(tFirst, minuteSeconds) * minuteSeconds
        let tEnd = -SleepMath.floorDiv(-(tLast + 1), minuteSeconds) * minuteSeconds
        let n5 = Int((tEnd - t0) / angleEpochSeconds)
        let nMin = Int((tEnd - t0) / minuteSeconds)
        let n30 = Int((tEnd - t0) / 30)
        var zs = [Double](repeating: 0, count: n5)
        var zc = [Int](repeating: 0, count: n5)
        var hmS = [Double](repeating: 0, count: nMin)
        var hmC = [Int](repeating: 0, count: nMin)
        var h30S = [Double](repeating: 0, count: n30)
        var h30C = [Int](repeating: 0, count: n30)
        for i in 0..<n {
            let off = s.ts[i] - t0
            if let h = s.hr[i], h > 0, s.hrKeep[i] {
                hmS[Int(off / minuteSeconds)] += h
                hmC[Int(off / minuteSeconds)] += 1
                h30S[Int(off / 30)] += h
                h30C[Int(off / 30)] += 1
            }
            if worn(s.hr[i], s.gx[i], s.gy[i], s.gz[i]) {
                let k = Int(off / angleEpochSeconds)
                zs[k] += zAngle(x: s.gx[i]!, y: s.gy[i]!, z: s.gz[i]!)
                zc[k] += 1
            }
        }
        let z: [Double?] = (0..<n5).map { zc[$0] >= angleMinWorn ? zs[$0] / Double(zc[$0]) : nil }
        var d = [Double?](repeating: nil, count: n5)
        if n5 > 1 {
            for k in 1..<n5 {
                if let a = z[k], let b = z[k - 1] { d[k] = Swift.abs(a - b) }
            }
        }
        let per = Int(minuteSeconds / angleEpochSeconds)
        var act: [Double?] = []
        act.reserveCapacity(nMin)
        for j in 0..<nMin {
            var sum = 0.0
            var nv = 0
            for k in (j * per)..<((j + 1) * per) {
                if let v = d[k] {
                    sum += v
                    nv += 1
                }
            }
            act.append(nv >= minuteMinValidDeltas ? sum * Double(per) / Double(nv) : nil)
        }
        let hrMin: [Double?] = (0..<nMin).map { hmC[$0] >= minuteMinHR ? hmS[$0] / Double(hmC[$0]) : nil }
        let hr30: [Double?] = (0..<n30).map { h30C[$0] >= epochMinHR ? h30S[$0] / Double(h30C[$0]) : nil }
        return SleepMotionGrid(t0: t0, z: z, d: d, act: act, hrMin: hrMin, hr30: hr30, rows: n)
    }
}

/// Small integer / run helpers for the sleep family (Python floor division, maximal runs).
enum SleepMath {
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
    }

    static func floorMod(_ a: Int64, _ b: Int64) -> Int64 {
        a - floorDiv(a, b) * b
    }

    /// floor(x / step) · step for a Double instant (Python `math.floor(x / step) * step`).
    static func floorTo(_ x: Double, _ step: Int64) -> Int64 {
        Int64((x / Double(step)).rounded(.down)) * step
    }

    static func ceilTo(_ x: Double, _ step: Int64) -> Int64 {
        Int64((x / Double(step)).rounded(.up)) * step
    }

    /// Maximal runs of true as (first, last) inclusive.
    static func runs(_ flags: [Bool]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var k = 0
        while k < flags.count {
            if !flags[k] {
                k += 1
                continue
            }
            var j = k
            while j + 1 < flags.count && flags[j + 1] { j += 1 }
            out.append((k, j))
            k = j + 1
        }
        return out
    }

    /// Maximal runs of equal bytes as (byte, first, last).
    static func byteRuns(_ s: [UInt8]) -> [(UInt8, Int, Int)] {
        var out: [(UInt8, Int, Int)] = []
        var k = 0
        while k < s.count {
            var j = k
            while j + 1 < s.count && s[j + 1] == s[k] { j += 1 }
            out.append((s[k], k, j))
            k = j + 1
        }
        return out
    }

    static func overlaps(_ a: Double, _ b: Double, _ windows: [SleepInterval]) -> Bool {
        windows.contains { a < $0.end && $0.start < b }
    }
}
