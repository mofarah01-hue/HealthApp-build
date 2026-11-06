import Foundation
import MGDomain

// WP-15 Day family: shared pieces. Python reference: app/pclab/mglab/ref/day.py (REF_VERSION "1"); goldens:
// app/shared/golden/day/. Every function here mirrors its Python twin line for line; a change in one goes into the other.
// WRITTEN, NOT COMPILED (no Swift toolchain on the build PC).

/// A closed span of unix seconds: a detected or logged workout, a saved workout, a hard-effort window.
public struct DayWindow: Sendable, Hashable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// Day numbers and ages. A "day number" is whole days since 1970-01-01 of a calendar date; only differences matter, so
/// callers may use any consistent integer day index (e.g. `LocalDay.days(to:)`) for the `days:` arguments of
/// `ALG075.cusumChangePoints` and `ALG036.illnessCUSUM`.
public enum DayCalendar {
    /// Gregorian mean year in days, for fractional ages (Tanaka and Nes are continuous in age).
    public static let daysPerYear = 365.2425

    private static let epoch: LocalDay = LocalDay(iso: "1970-01-01")!

    /// Day number of a real `YYYY-MM-DD` date, else Missing. Python: `days_from_iso`.
    public static func dayNumber(iso: String) -> Computed<Int> {
        guard let d = LocalDay(iso: iso) else { return .missing("date is not a real YYYY-MM-DD calendar day") }
        return .success(epoch.days(to: d))
    }

    public static func dayNumber(_ day: LocalDay) -> Int {
        epoch.days(to: day)
    }

    /// Age in fractional years on a day = whole days between the dates / 365.2425. Python: `age_years`.
    public static func ageYears(birthISO: String, onISO: String) -> Computed<Double> {
        guard let b = LocalDay(iso: birthISO) else { return .missing("birth date is not a real YYYY-MM-DD calendar day") }
        guard let n = LocalDay(iso: onISO) else { return .missing("day is not a real YYYY-MM-DD calendar day") }
        return ageYears(birth: b, on: n)
    }

    public static func ageYears(birth: LocalDay, on day: LocalDay) -> Computed<Double> {
        let days = birth.days(to: day)
        if days < 0 { return .missing("birth date is after the day") }
        return .success(Double(days) / daysPerYear)
    }
}

/// Internal helpers shared by the Day files. Not public: other families have their own.
enum DayKit {
    /// The two published-equation sexes. `Profile.Sex.other` and nil have no equation (R6: no averaged constants).
    enum Sex: Sendable {
        case male
        case female
    }

    static func sex(_ s: Profile.Sex?) -> Computed<Sex> {
        switch s {
        case .some(.male): return .success(.male)
        case .some(.female): return .success(.female)
        case .some(.other): return .missing("the published equations exist for male and female only")
        case .none: return .missing("sex is not set in the profile")
        }
    }

    static func finite(_ x: Double?) -> Bool {
        guard let x else { return false }
        return x.isFinite
    }

    /// Round half away from zero for x >= 0 (Python reference `_r0`).
    static func r0(_ x: Double) -> Int {
        Int((x + 0.5).rounded(.down))
    }

    /// Floor division for the minute buckets (Python `//`).
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Run a body that throws `Missing`; turn the throw into the failure case.
    static func compute<T>(_ body: () throws -> T) -> Computed<T> {
        do {
            return .success(try body())
        } catch let m as Missing {
            return .failure(m)
        } catch {
            return .failure(Missing("\(error)"))
        }
    }

    static func require(_ ok: Bool, _ reason: String) throws {
        if !ok { throw Missing(reason) }
    }

    /// Resting HR and HRmax must be finite with 0 < rhr < hrmax.
    static func requireAnchors(rhr: Double?, hrmax: Double?) throws -> (rhr: Double, hrmax: Double) {
        guard let rhr, let hrmax, rhr.isFinite, hrmax.isFinite else { throw Missing("needs resting heart rate and HRmax") }
        if !(0 < rhr && rhr < hrmax) { throw Missing("resting heart rate must be above 0 and below HRmax") }
        return (rhr, hrmax)
    }

    /// Samples with a finite value, sorted by (ts, original index) so equal timestamps keep input order.
    static func validPairs(ts: [Int], vals: [Double]) -> (ts: [Int], vals: [Double]) {
        let n = min(ts.count, vals.count)
        var idx = (0..<n).filter { vals[$0].isFinite }
        idx.sort { ts[$0] != ts[$1] ? ts[$0] < ts[$1] : $0 < $1 }
        return (idx.map { ts[$0] }, idx.map { vals[$0] })
    }

    static func mean(_ x: [Double]) -> Double { SignalMath.mean(x) }
    static func median(_ x: [Double]) -> Double { SignalMath.median(x) }
    static func sampleSD(_ x: [Double]) -> Double { SignalMath.sampleSD(x) }

    /// Banister weights (Morton, Fitz-Clarke & Banister 1990): y(x) = c e^(b x).
    static func banister(_ sex: Sex) -> (c: Double, b: Double) {
        switch sex {
        case .male: return (0.64, 1.92)
        case .female: return (0.86, 1.67)
        }
    }

    /// Seconds each sorted sample stands for: the gap to the next sample capped at the stream's median step (a hole is
    /// never counted as effort); the last sample gets the median step. Python: `sample_durations`.
    static func sampleDurations(_ ts: [Int]) -> [Double] {
        let n = ts.count
        if n == 0 { return [] }
        if n == 1 { return [1.0] }
        var steps: [Double] = []
        for i in 0..<(n - 1) where ts[i + 1] > ts[i] { steps.append(Double(ts[i + 1] - ts[i])) }
        let cadence = steps.isEmpty ? 1.0 : median(steps)
        var out: [Double] = []
        out.reserveCapacity(n)
        for i in 0..<(n - 1) {
            let g = Double(ts[i + 1] - ts[i])
            out.append(g > 0 ? min(g, cadence) : cadence)
        }
        out.append(cadence)
        return out
    }
}
