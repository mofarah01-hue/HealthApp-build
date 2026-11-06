import Foundation

// MARK: - Fajr and sunrise for the Fajr wake (added 2026-10-11)
//
// PORTED (re-typed, not linked) from batoulapps/adhan-swift 1.5.0, MIT licence, notice below —
// https://github.com/batoulapps/adhan-swift/tree/1.5.0 :
//   Sources/Astronomy/Astronomical.swift    every function the Fajr / sunrise path calls (mean solar longitude …
//                                           correctedHourAngle, julianDay, daysSinceSolstice,
//                                           seasonAdjustedMorningTwilight);
//   Sources/Astronomy/SolarCoordinates.swift  init(julianDay:);
//   Sources/Astronomy/SolarTime.swift       init (transit, sunrise, sunset) and timeForSolarAngle;
//   Sources/Models/CalculationMethod.swift  the Fajr angles, the sunrise / Fajr method adjustments, Singapore's rounding;
//   Sources/Models/CalculationParameters.swift  nightPortions (Fajr side); HighLatitudeRule.swift recommended(for:);
//   Sources/Extensions/DateUtilities.swift  roundedMinute, settingHour; MathUtilities.swift normalizedToScale;
//   Sources/Units/Angle.swift;
//   Sources/PrayerTimes.swift               init L46-112 (Fajr from the twilight angle, the Moonsighting high-latitude
//                                           case, the "safe Fajr" night-portion check) and L163-169 (offsets, rounding).
// Only Fajr and sunrise are kept: the alarm needs nothing else. Known answers: adhan's own test data
// (Tests/Resources/Times/*.json; AdhanTests testPrayerTimes / testMoonsightingMethod / testEgyptian /
// testExtremeLocation) in MGContextTests/Alarms/PrayerTimesTests.swift.
//
// adhan-swift — Copyright © 2018 Batoul Apps. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

/// The standard calculation methods (adhan-swift `CalculationMethod`). Mo's default is ISNA 15° (`northAmerica`): on
/// 2026-10-11 the Pillars app showed Fajr 05:42 and sunrise 06:50 at ~34°N — the symmetric 68 min Fajr→sunrise and
/// Maghrib→Isha fit 15°. "Match Pillars" (`PrayerTimesCalculator.matchMethod`) confirms it at his location.
public enum PrayerMethod: String, Codable, CaseIterable, Sendable {
    case northAmerica
    case muslimWorldLeague
    case egyptian
    case karachi
    case ummAlQura
    case dubai
    case moonsightingCommittee
    case kuwait
    case qatar
    case singapore
    case tehran
    case turkey

    public var title: String {
        switch self {
        case .northAmerica: return "ISNA (15°)"
        case .muslimWorldLeague: return "Muslim World League (18°)"
        case .egyptian: return "Egyptian (19.5°)"
        case .karachi: return "Karachi (18°)"
        case .ummAlQura: return "Umm al-Qura (18.5°)"
        case .dubai: return "Dubai (18.2°)"
        case .moonsightingCommittee: return "Moonsighting Committee (18°, seasonal)"
        case .kuwait: return "Kuwait (18°)"
        case .qatar: return "Qatar (18°)"
        case .singapore: return "Singapore (20°)"
        case .tehran: return "Tehran (17.7°)"
        case .turkey: return "Diyanet, Turkey (18°)"
        }
    }

    /// adhan CalculationMethod.params `fajrAngle`.
    var fajrAngle: Double {
        switch self {
        case .northAmerica: return 15
        case .muslimWorldLeague, .karachi, .moonsightingCommittee, .kuwait, .qatar, .turkey: return 18
        case .egyptian: return 19.5
        case .ummAlQura: return 18.5
        case .dubai: return 18.2
        case .singapore: return 20
        case .tehran: return 17.7
        }
    }

    /// adhan CalculationMethod.params `methodAdjustments` (minutes), the two this port uses.
    var fajrAdjustment: Int { 0 }
    var sunriseAdjustment: Int {
        switch self {
        case .dubai: return -3
        case .turkey: return -7
        default: return 0
        }
    }

    /// adhan `Rounding`: Singapore rounds up, every other method to the nearest minute.
    var roundsUp: Bool { self == .singapore }
}

/// adhan `HighLatitudeRule` (the Fajr side of `nightPortions`).
public enum PrayerHighLatitudeRule: String, Codable, CaseIterable, Sendable {
    case middleOfTheNight, seventhOfTheNight, twilightAngle

    /// adhan HighLatitudeRule.recommended(for:): above 48° the seventh of the night, else the middle.
    public static func recommended(latitude: Double) -> PrayerHighLatitudeRule {
        latitude > 48 ? .seventhOfTheNight : .middleOfTheNight
    }
}

public struct PrayerCoordinates: Codable, Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// A latitude/longitude a phone could report (not the 0,0 a failed fix gives).
    public var isPlausible: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && !(latitude == 0 && longitude == 0)
    }
}

/// Fajr and sunrise as absolute instants (show them with the local time zone).
public struct FajrSunrise: Equatable, Sendable {
    public let fajr: Date
    public let sunrise: Date
    public let method: PrayerMethod
}

public enum PrayerTimesCalculator {
    /// Fajr and sunrise for the civil date `year-month-day` at `coordinates` (adhan computes at 0h UTC of that date and
    /// returns UTC instants — the same convention as adhan's own tests, which pass the local date). nil when the sun
    /// does not rise that day or Fajr cannot be found (polar night/day), as adhan's PrayerTimes init returns nil.
    /// `fajrAdjustMinutes`: Mo's own fine-tune on top of the method (adhan `adjustments.fajr`).
    public static func fajrSunrise(year: Int, month: Int, day: Int, coordinates c: PrayerCoordinates,
                                   method: PrayerMethod, highLatitudeRule: PrayerHighLatitudeRule? = nil,
                                   fajrAdjustMinutes: Int = 0) -> FajrSunrise? {
        let cal = Self.utc
        var date = DateComponents()
        date.year = year
        date.month = month
        date.day = day
        guard let prayerDate = cal.date(from: date),
              let tomorrowDate = cal.date(byAdding: .day, value: 1, to: prayerDate),
              let dayOfYear = cal.ordinality(of: .day, in: .year, for: prayerDate) else { return nil }
        let tomorrow = cal.dateComponents([.year, .month, .day], from: tomorrowDate)
        guard let solarTime = AdhanSolarTime(date: date, coordinates: c),
              let tomorrowSolarTime = AdhanSolarTime(date: tomorrow, coordinates: c),
              let sunriseDate = cal.date(from: solarTime.sunrise),
              let sunsetDate = cal.date(from: solarTime.sunset),
              let tomorrowSunrise = cal.date(from: tomorrowSolarTime.sunrise) else { return nil }
        let night = tomorrowSunrise.timeIntervalSince(sunsetDate)
        var fajr: Date? = solarTime.timeForSolarAngle(SolarAngle(-method.fajrAngle), afterTransit: false)
            .flatMap { cal.date(from: $0) }
        // special case for moonsighting committee above latitude 55 (adhan PrayerTimes.swift L93-97)
        if method == .moonsightingCommittee && c.latitude >= 55 {
            fajr = sunriseDate.addingTimeInterval(-(night / 7))
        }
        let safeFajr: Date
        if method == .moonsightingCommittee {
            safeFajr = AdhanAstronomical.seasonAdjustedMorningTwilight(latitude: c.latitude, day: dayOfYear, year: year,
                                                                       sunrise: sunriseDate)
        } else {
            let rule = highLatitudeRule ?? .recommended(latitude: c.latitude)
            let portion: Double
            switch rule {
            case .middleOfTheNight: portion = 1.0 / 2.0
            case .seventhOfTheNight: portion = 1.0 / 7.0
            case .twilightAngle: portion = method.fajrAngle / 60
            }
            safeFajr = sunriseDate.addingTimeInterval(-(portion * night))
        }
        if fajr == nil || fajr! < safeFajr { fajr = safeFajr }
        guard let f = fajr else { return nil }
        let fajrOut = Self.roundedMinute(f.addingTimeInterval(TimeInterval((fajrAdjustMinutes + method.fajrAdjustment) * 60)),
                                         up: method.roundsUp)
        let sunriseOut = Self.roundedMinute(sunriseDate.addingTimeInterval(TimeInterval(method.sunriseAdjustment * 60)),
                                            up: method.roundsUp)
        return FajrSunrise(fajr: fajrOut, sunrise: sunriseOut, method: method)
    }

    /// For the morning of the local calendar day containing `day` (in `calendar`'s time zone).
    public static func fajrSunrise(localDay day: Date, calendar: Calendar, coordinates: PrayerCoordinates,
                                   method: PrayerMethod, fajrAdjustMinutes: Int = 0) -> FajrSunrise? {
        let comps = calendar.dateComponents([.year, .month, .day], from: day)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return fajrSunrise(year: y, month: m, day: d, coordinates: coordinates, method: method,
                           fajrAdjustMinutes: fajrAdjustMinutes)
    }

    // MARK: Match Pillars

    public struct MethodFit: Equatable, Sendable {
        public let method: PrayerMethod
        public let fajr: Date
        /// computed − typed, in minutes (negative = the method's Fajr is earlier than what Mo typed).
        public let minutesOff: Double
    }

    public struct MethodMatch: Equatable, Sendable {
        /// Every method that gives a Fajr that day, closest first.
        public let fits: [MethodFit]
        /// The closest method within the tolerance (ISNA wins a tie), or nil when none is that close.
        public let best: MethodFit?
        public let toleranceMinutes: Double
    }

    /// "Match Pillars": Mo types today's Fajr as Pillars shows it (minutes after local midnight); every standard method
    /// is computed for today at his location and the closest within `toleranceMinutes` (default 2) is picked. A tie goes
    /// to ISNA, then to the order of `PrayerMethod.allCases`.
    public static func matchMethod(typedFajrMinutes: Int, localDay day: Date, calendar: Calendar,
                                   coordinates: PrayerCoordinates, toleranceMinutes: Double = 2) -> MethodMatch? {
        guard (0..<(24 * 60)).contains(typedFajrMinutes),
              let midnight = calendar.dateInterval(of: .day, for: day)?.start,
              let typed = calendar.date(byAdding: .minute, value: typedFajrMinutes, to: midnight) else { return nil }
        var fits: [MethodFit] = []
        for m in PrayerMethod.allCases {
            guard let t = fajrSunrise(localDay: day, calendar: calendar, coordinates: coordinates, method: m) else { continue }
            fits.append(MethodFit(method: m, fajr: t.fajr, minutesOff: t.fajr.timeIntervalSince(typed) / 60))
        }
        let order = Dictionary(uniqueKeysWithValues: PrayerMethod.allCases.enumerated().map { ($1, $0) })
        fits.sort { a, b in
            abs(a.minutesOff) != abs(b.minutesOff) ? abs(a.minutesOff) < abs(b.minutesOff)
                : order[a.method]! < order[b.method]!
        }
        let best = fits.first.flatMap { abs($0.minutesOff) <= toleranceMinutes ? $0 : nil }
        return MethodMatch(fits: fits, best: best, toleranceMinutes: toleranceMinutes)
    }

    // MARK: Internals (adhan DateUtilities)

    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// adhan `Date.roundedMinute(rounding:)` (.nearest / .up).
    static func roundedMinute(_ date: Date, up: Bool) -> Date {
        var c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let minute = Double(c.minute ?? 0)
        let second = Double(c.second ?? 0)
        c.minute = Int(minute + (up ? ceil(second / 60) : (second / 60).rounded()))
        c.second = 0
        return utc.date(from: c) ?? date
    }
}

// MARK: - adhan-swift astronomy (internal; names prefixed so they never meet SwiftUI's `Angle`)

private func adhanNormalized(_ value: Double, _ max: Double) -> Double {
    value - (max * floor(value / max))
}

/// adhan `Angle`.
struct SolarAngle {
    var degrees: Double

    init(_ value: Double) { degrees = value }
    init(radians: Double) { degrees = (radians * 180.0) / .pi }

    var radians: Double { (degrees * .pi) / 180.0 }

    func unwound() -> SolarAngle { SolarAngle(adhanNormalized(degrees, 360)) }

    func quadrantShifted() -> SolarAngle {
        if degrees >= -180 && degrees <= 180 { return self }
        return SolarAngle(degrees - (360 * (degrees / 360).rounded()))
    }

    static func + (l: SolarAngle, r: SolarAngle) -> SolarAngle { SolarAngle(l.degrees + r.degrees) }
    static func - (l: SolarAngle, r: SolarAngle) -> SolarAngle { SolarAngle(l.degrees - r.degrees) }
    static func * (l: SolarAngle, r: SolarAngle) -> SolarAngle { SolarAngle(l.degrees * r.degrees) }
    static func / (l: SolarAngle, r: SolarAngle) -> SolarAngle { SolarAngle(l.degrees / r.degrees) }
}

/// adhan `Astronomical` (the functions the Fajr / sunrise path uses; equations from Meeus, Astronomical Algorithms).
enum AdhanAstronomical {
    static func meanSolarLongitude(julianCentury T: Double) -> SolarAngle {
        let L0 = 280.4664567 + (36000.76983 * T) + (0.0003032 * pow(T, 2))
        return SolarAngle(L0).unwound()
    }

    static func meanLunarLongitude(julianCentury T: Double) -> SolarAngle {
        SolarAngle(218.3165 + (481267.8813 * T)).unwound()
    }

    static func ascendingLunarNodeLongitude(julianCentury T: Double) -> SolarAngle {
        let omega = 125.04452 - (1934.136261 * T) + (0.0020708 * pow(T, 2)) + (pow(T, 3) / 450000)
        return SolarAngle(omega).unwound()
    }

    static func meanSolarAnomaly(julianCentury T: Double) -> SolarAngle {
        SolarAngle(357.52911 + (35999.05029 * T) - (0.0001537 * pow(T, 2))).unwound()
    }

    static func solarEquationOfTheCenter(julianCentury T: Double, meanAnomaly M: SolarAngle) -> SolarAngle {
        let Mrad = M.radians
        let term1 = (1.914602 - (0.004817 * T) - (0.000014 * pow(T, 2))) * sin(Mrad)
        let term2 = (0.019993 - (0.000101 * T)) * sin(2 * Mrad)
        let term3 = 0.000289 * sin(3 * Mrad)
        return SolarAngle(term1 + term2 + term3)
    }

    static func apparentSolarLongitude(julianCentury T: Double, meanLongitude L0: SolarAngle) -> SolarAngle {
        let longitude = L0 + solarEquationOfTheCenter(julianCentury: T, meanAnomaly: meanSolarAnomaly(julianCentury: T))
        let omega = SolarAngle(125.04 - (1934.136 * T))
        return SolarAngle(longitude.degrees - 0.00569 - (0.00478 * sin(omega.radians))).unwound()
    }

    static func meanObliquityOfTheEcliptic(julianCentury T: Double) -> SolarAngle {
        SolarAngle(23.439291 - (0.013004167 * T) - (0.0000001639 * pow(T, 2)) + (0.0000005036 * pow(T, 3)))
    }

    static func apparentObliquityOfTheEcliptic(julianCentury T: Double, meanObliquityOfTheEcliptic e0: SolarAngle)
        -> SolarAngle {
        let O = 125.04 - (1934.136 * T)
        return SolarAngle(e0.degrees + (0.00256 * cos(SolarAngle(O).radians)))
    }

    static func meanSiderealTime(julianCentury T: Double) -> SolarAngle {
        let JD = (T * 36525) + 2451545.0
        let theta = 280.46061837 + (360.98564736629 * (JD - 2451545)) + (0.000387933 * pow(T, 2)) - (pow(T, 3) / 38710000)
        return SolarAngle(theta).unwound()
    }

    static func nutationInLongitude(solarLongitude L0: SolarAngle, lunarLongitude Lp: SolarAngle,
                                    ascendingNode omega: SolarAngle) -> Double {
        let term1 = (-17.2 / 3600) * sin(omega.radians)
        let term2 = (1.32 / 3600) * sin(2 * L0.radians)
        let term3 = (0.23 / 3600) * sin(2 * Lp.radians)
        let term4 = (0.21 / 3600) * sin(2 * omega.radians)
        return term1 - term2 - term3 + term4
    }

    static func nutationInObliquity(solarLongitude L0: SolarAngle, lunarLongitude Lp: SolarAngle,
                                    ascendingNode omega: SolarAngle) -> Double {
        let term1 = (9.2 / 3600) * cos(omega.radians)
        let term2 = (0.57 / 3600) * cos(2 * L0.radians)
        let term3 = (0.10 / 3600) * cos(2 * Lp.radians)
        let term4 = (0.09 / 3600) * cos(2 * omega.radians)
        return term1 + term2 + term3 - term4
    }

    static func altitudeOfCelestialBody(observerLatitude phi: SolarAngle, declination delta: SolarAngle,
                                        localHourAngle H: SolarAngle) -> SolarAngle {
        let term1 = sin(phi.radians) * sin(delta.radians)
        let term2 = cos(phi.radians) * cos(delta.radians) * cos(H.radians)
        return SolarAngle(radians: asin(term1 + term2))
    }

    static func approximateTransit(longitude L: SolarAngle, siderealTime theta0: SolarAngle,
                                   rightAscension alpha2: SolarAngle) -> Double {
        let Lw = L * SolarAngle(-1)
        let m0 = adhanNormalized(((alpha2 + Lw - theta0) / SolarAngle(360)).degrees, 1)
        // Near the date line the normalisation can land on the wrong calendar date (adhan 1.5.0 fix).
        let expectedTransit = adhanNormalized((12.0 - L.degrees / 15.0) / 24.0, 1)
        if m0 - expectedTransit > 0.5 { return m0 - 1.0 }
        if expectedTransit - m0 > 0.5 { return m0 + 1.0 }
        return m0
    }

    static func correctedTransit(approximateTransit m0: Double, longitude L: SolarAngle, siderealTime theta0: SolarAngle,
                                 rightAscension alpha2: SolarAngle, previousRightAscension alpha1: SolarAngle,
                                 nextRightAscension alpha3: SolarAngle) -> Double {
        let Lw = L * SolarAngle(-1)
        let theta = SolarAngle(theta0.degrees + (360.985647 * m0)).unwound()
        let alpha = interpolateAngles(value: alpha2, previousValue: alpha1, nextValue: alpha3, factor: m0).unwound()
        let H = (theta - Lw - alpha).quadrantShifted()
        let dm = H / SolarAngle(-360)
        return (m0 + dm.degrees) * 24
    }

    static func correctedHourAngle(approximateTransit m0: Double, angle h0: SolarAngle, coordinates: PrayerCoordinates,
                                   afterTransit: Bool, siderealTime theta0: SolarAngle, rightAscension alpha2: SolarAngle,
                                   previousRightAscension alpha1: SolarAngle, nextRightAscension alpha3: SolarAngle,
                                   declination delta2: SolarAngle, previousDeclination delta1: SolarAngle,
                                   nextDeclination delta3: SolarAngle) -> Double {
        let latitude = SolarAngle(coordinates.latitude)
        let Lw = SolarAngle(coordinates.longitude) * SolarAngle(-1)
        let term1 = sin(h0.radians) - (sin(latitude.radians) * sin(delta2.radians))
        let term2 = cos(latitude.radians) * cos(delta2.radians)
        let H0 = SolarAngle(radians: acos(term1 / term2))
        let m = afterTransit ? m0 + (H0.degrees / 360) : m0 - (H0.degrees / 360)
        let theta = SolarAngle(theta0.degrees + (360.985647 * m)).unwound()
        let alpha = interpolateAngles(value: alpha2, previousValue: alpha1, nextValue: alpha3, factor: m).unwound()
        let delta = SolarAngle(interpolate(value: delta2.degrees, previousValue: delta1.degrees,
                                           nextValue: delta3.degrees, factor: m))
        let H = (theta - Lw - alpha)
        let h = altitudeOfCelestialBody(observerLatitude: latitude, declination: delta, localHourAngle: H)
        let term3 = (h - h0).degrees
        let term4 = 360 * cos(delta.radians) * cos(latitude.radians) * sin(H.radians)
        let dm = term3 / term4
        return (m + dm) * 24
    }

    static func interpolate(value y2: Double, previousValue y1: Double, nextValue y3: Double, factor n: Double) -> Double {
        let a = y2 - y1
        let b = y3 - y2
        let c = b - a
        return y2 + ((n / 2) * (a + b + (n * c)))
    }

    static func interpolateAngles(value y2: SolarAngle, previousValue y1: SolarAngle, nextValue y3: SolarAngle,
                                  factor n: Double) -> SolarAngle {
        let a = (y2 - y1).unwound()
        let b = (y3 - y2).unwound()
        let c = b - a
        return SolarAngle(y2.degrees + ((n / 2) * (a.degrees + b.degrees + (n * c.degrees))))
    }

    static func julianDay(year: Int, month: Int, day: Int, hours: Double = 0) -> Double {
        // Integer casts truncate on purpose (adhan).
        let Y: Int = month > 2 ? year : year - 1
        let M: Int = month > 2 ? month : month + 12
        let D: Double = Double(day) + (hours / 24)
        let A: Int = Y / 100
        let B: Int = 2 - A + (A / 4)
        let i0: Int = Int(365.25 * (Double(Y) + 4716))
        let i1: Int = Int(30.6001 * (Double(M) + 1))
        return Double(i0) + Double(i1) + D + Double(B) - 1524.5
    }

    static func julianDay(dateComponents c: DateComponents) -> Double {
        julianDay(year: c.year ?? 1, month: c.month ?? 1, day: c.day ?? 1,
                  hours: Double(c.hour ?? 0) + (Double(c.minute ?? 0) / 60))
    }

    static func julianCentury(julianDay JD: Double) -> Double { (JD - 2451545.0) / 36525 }

    static func isLeapYear(_ year: Int) -> Bool {
        if year % 4 != 0 { return false }
        if year % 100 == 0 && year % 400 != 0 { return false }
        return true
    }

    /// Moonsighting Committee's observed twilight (adhan seasonAdjustedMorningTwilight).
    static func seasonAdjustedMorningTwilight(latitude: Double, day: Int, year: Int, sunrise: Date) -> Date {
        let a: Double = 75 + ((28.65 / 55.0) * fabs(latitude))
        let b: Double = 75 + ((19.44 / 55.0) * fabs(latitude))
        let c: Double = 75 + ((32.74 / 55.0) * fabs(latitude))
        let d: Double = 75 + ((48.10 / 55.0) * fabs(latitude))
        let dyy = Double(daysSinceSolstice(dayOfYear: day, year: year, latitude: latitude))
        let adjustment: Double
        if dyy < 91 {
            adjustment = a + (b - a) / 91.0 * dyy
        } else if dyy < 137 {
            adjustment = b + (c - b) / 46.0 * (dyy - 91)
        } else if dyy < 183 {
            adjustment = c + (d - c) / 46.0 * (dyy - 137)
        } else if dyy < 229 {
            adjustment = d + (c - d) / 46.0 * (dyy - 183)
        } else if dyy < 275 {
            adjustment = c + (b - c) / 46.0 * (dyy - 229)
        } else {
            adjustment = b + (a - b) / 91.0 * (dyy - 275)
        }
        return sunrise.addingTimeInterval(round(adjustment * -60.0))
    }

    static func daysSinceSolstice(dayOfYear: Int, year: Int, latitude: Double) -> Int {
        let northernOffset = 10
        let southernOffset = isLeapYear(year) ? 173 : 172
        let daysInYear = isLeapYear(year) ? 366 : 365
        if latitude >= 0 {
            var d = dayOfYear + northernOffset
            if d >= daysInYear { d -= daysInYear }
            return d
        }
        var d = dayOfYear - southernOffset
        if d < 0 { d += daysInYear }
        return d
    }
}

/// adhan `SolarCoordinates`.
struct AdhanSolarCoordinates {
    let declination: SolarAngle
    let rightAscension: SolarAngle
    let apparentSiderealTime: SolarAngle

    init(julianDay: Double) {
        let T = AdhanAstronomical.julianCentury(julianDay: julianDay)
        let L0 = AdhanAstronomical.meanSolarLongitude(julianCentury: T)
        let Lp = AdhanAstronomical.meanLunarLongitude(julianCentury: T)
        let omega = AdhanAstronomical.ascendingLunarNodeLongitude(julianCentury: T)
        let lambda = AdhanAstronomical.apparentSolarLongitude(julianCentury: T, meanLongitude: L0).radians
        let theta0 = AdhanAstronomical.meanSiderealTime(julianCentury: T)
        let dPsi = AdhanAstronomical.nutationInLongitude(solarLongitude: L0, lunarLongitude: Lp, ascendingNode: omega)
        let dEps = AdhanAstronomical.nutationInObliquity(solarLongitude: L0, lunarLongitude: Lp, ascendingNode: omega)
        let e0 = AdhanAstronomical.meanObliquityOfTheEcliptic(julianCentury: T)
        let eApp = AdhanAstronomical.apparentObliquityOfTheEcliptic(julianCentury: T, meanObliquityOfTheEcliptic: e0).radians
        declination = SolarAngle(radians: asin(sin(eApp) * sin(lambda)))
        rightAscension = SolarAngle(radians: atan2(cos(eApp) * sin(lambda), cos(lambda))).unwound()
        apparentSiderealTime = SolarAngle(theta0.degrees + (((dPsi * 3600) * cos(SolarAngle(e0.degrees + dEps).radians)) / 3600))
    }
}

/// adhan `SolarTime` (transit, sunrise, sunset, and the time the sun reaches an angle).
struct AdhanSolarTime {
    let date: DateComponents
    let observer: PrayerCoordinates
    let solar: AdhanSolarCoordinates
    let transit: DateComponents
    let sunrise: DateComponents
    let sunset: DateComponents
    private let prevSolar: AdhanSolarCoordinates
    private let nextSolar: AdhanSolarCoordinates
    private let approxTransit: Double

    init?(date input: DateComponents, coordinates: PrayerCoordinates) {
        var date = input                       // calculations need to occur at 0h0m UTC
        date.hour = 0
        date.minute = 0
        let julianDay = AdhanAstronomical.julianDay(dateComponents: date)
        let prevSolar = AdhanSolarCoordinates(julianDay: julianDay - 1)
        let solar = AdhanSolarCoordinates(julianDay: julianDay)
        let nextSolar = AdhanSolarCoordinates(julianDay: julianDay + 1)
        let longitude = SolarAngle(coordinates.longitude)
        let m0 = AdhanAstronomical.approximateTransit(longitude: longitude, siderealTime: solar.apparentSiderealTime,
                                                      rightAscension: solar.rightAscension)
        let solarAltitude = SolarAngle(-50.0 / 60.0)
        self.date = date
        self.observer = coordinates
        self.solar = solar
        self.prevSolar = prevSolar
        self.nextSolar = nextSolar
        self.approxTransit = m0
        let transitTime = AdhanAstronomical.correctedTransit(
            approximateTransit: m0, longitude: longitude, siderealTime: solar.apparentSiderealTime,
            rightAscension: solar.rightAscension, previousRightAscension: prevSolar.rightAscension,
            nextRightAscension: nextSolar.rightAscension)
        let sunriseTime = AdhanAstronomical.correctedHourAngle(
            approximateTransit: m0, angle: solarAltitude, coordinates: coordinates, afterTransit: false,
            siderealTime: solar.apparentSiderealTime, rightAscension: solar.rightAscension,
            previousRightAscension: prevSolar.rightAscension, nextRightAscension: nextSolar.rightAscension,
            declination: solar.declination, previousDeclination: prevSolar.declination,
            nextDeclination: nextSolar.declination)
        let sunsetTime = AdhanAstronomical.correctedHourAngle(
            approximateTransit: m0, angle: solarAltitude, coordinates: coordinates, afterTransit: true,
            siderealTime: solar.apparentSiderealTime, rightAscension: solar.rightAscension,
            previousRightAscension: prevSolar.rightAscension, nextRightAscension: nextSolar.rightAscension,
            declination: solar.declination, previousDeclination: prevSolar.declination,
            nextDeclination: nextSolar.declination)
        guard let transitDate = Self.settingHour(date, transitTime), let sunriseDate = Self.settingHour(date, sunriseTime),
              let sunsetDate = Self.settingHour(date, sunsetTime) else { return nil }
        transit = transitDate
        sunrise = sunriseDate
        sunset = sunsetDate
    }

    func timeForSolarAngle(_ angle: SolarAngle, afterTransit: Bool) -> DateComponents? {
        let hours = AdhanAstronomical.correctedHourAngle(
            approximateTransit: approxTransit, angle: angle, coordinates: observer, afterTransit: afterTransit,
            siderealTime: solar.apparentSiderealTime, rightAscension: solar.rightAscension,
            previousRightAscension: prevSolar.rightAscension, nextRightAscension: nextSolar.rightAscension,
            declination: solar.declination, previousDeclination: prevSolar.declination,
            nextDeclination: nextSolar.declination)
        return Self.settingHour(date, hours)
    }

    /// adhan `DateComponents.settingHour(_:)`: nil for NaN / infinite (the sun never reaches the angle).
    static func settingHour(_ base: DateComponents, _ value: Double) -> DateComponents? {
        guard value.isNormal else { return nil }
        let hours = floor(value)
        let minutes = floor((value - hours) * 60)
        let seconds = floor((value - (hours + minutes / 60)) * 60 * 60)
        var c = base
        c.hour = Int(hours)
        c.minute = Int(minutes)
        c.second = Int(seconds)
        return c
    }
}
