import Foundation

/// UX-SPEC §2 phase arithmetic. Pure functions; `now` and the calendar always come from the caller.
///
/// Ported from the Python reference run on the build PC (scratchpad wp06/phase_ref.py, 53 known-answer checks passed).
/// How it can fail, and what guards each case:
/// - Midnight crossing: after 00:00 the wake day is still yesterday's until the next wake → W is the most recent
///   anchor at or before `now`, never "today at the median time" (which would put 00:40 or 03:00 in Morning).
/// - Short day (W + 8 h > B − 4 h): every boundary is clamped into [W, B − 1 h], so late afternoon (and in extreme days
///   sundown) is skipped instead of running backwards.
/// - Missing wake: 14-day median, else the latest-wake setting, else 07:00, all marked `wakeAssumed`. A detected wake
///   goes stale only when the usual wake time has passed more than 12 h after it (an early riser keeps theirs).
/// - Missing or stale bedtime: a model bedtime outside (W, W + 24 h], or more than 6 h of clock time from the usual
///   onset (23:00 when unknown; T9710), is ignored → median onset → 23:00.
/// - DST: phase offsets are elapsed time (W + 5 h is five real hours); times of day are placed with the calendar, and a
///   time inside the spring-forward gap resolves to the first valid instant after it.
/// - Clock skew: a detected wake in the future is ignored until it arrives.
public enum PhaseClock {
    /// Final wake fallback when nothing else is known. Not in UX §2; approved by main (BRIEF, 2026-10-11).
    /// UI copy must say "wake assumed 07:00".
    public static let fallbackWake = TimeOfDay(hour: 7, minute: 0)
    /// UX §2: "No bedtime … else 23:00".
    public static let fallbackBedtime = TimeOfDay(hour: 23, minute: 0)
    /// A detected wake stays today's until the usual wake time comes round more than this long after it.
    public static let staleWakeAfter: TimeInterval = 12 * 3600

    static let hour: TimeInterval = 3600

    // MARK: Time-of-day placement

    /// `time` on the calendar date of `day`. A time inside a DST gap resolves to the first valid instant after it.
    public static func instant(_ time: TimeOfDay, onDayOf day: Date, calendar: Calendar) -> Date {
        var c = calendar.dateComponents([.era, .year, .month, .day], from: day)
        c.hour = time.hour
        c.minute = time.minute
        c.second = time.second
        if let d = calendar.date(from: c) { return d }
        return calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(time.secondsIntoDay))
    }

    /// The most recent occurrence of `time` at or before `date`.
    public static func lastOccurrence(of time: TimeOfDay, atOrBefore date: Date, calendar: Calendar) -> Date {
        let sameDay = instant(time, onDayOf: date, calendar: calendar)
        if sameDay <= date { return sameDay }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: date) ?? date.addingTimeInterval(-24 * hour)
        return instant(time, onDayOf: yesterday, calendar: calendar)
    }

    /// The first occurrence of `time` strictly after `date`.
    public static func firstOccurrence(of time: TimeOfDay, after date: Date, calendar: Calendar) -> Date {
        let sameDay = instant(time, onDayOf: date, calendar: calendar)
        if sameDay > date { return sameDay }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(24 * hour)
        return instant(time, onDayOf: tomorrow, calendar: calendar)
    }

    // MARK: Anchors

    /// The time of day used when no wake is detected: 14-day median, else the latest-wake setting, else 07:00.
    public static func usualWake(medianWake14: Date?, latestWakeSetting: DateComponents?, calendar: Calendar) -> TimeOfDay {
        if let m = medianWake14 { return TimeOfDay(of: m, calendar: calendar) }
        if let s = latestWakeSetting, let t = TimeOfDay(s) { return t }
        return fallbackWake
    }

    /// W, B and L for the wake day containing `now` (UX §2).
    ///
    /// - Parameters:
    ///   - detectedWake: the most recent main-sleep wake from ALG-030 (naps never reset it). May be yesterday's.
    ///   - medianWake14: any instant whose time of day is the 14-day median wake (only the time of day is used).
    ///   - latestWakeSetting: hour and minute of "must be up by" for the coming morning (caller resolves the weekday).
    ///   - recommendedBedtime: ALG-115's bedtime for tonight; ignored unless it falls in (W, W + 24 h].
    ///   - medianOnset14: any instant whose time of day is the 14-day median sleep onset.
    public static func anchors(now: Date, calendar: Calendar, detectedWake: Date?, medianWake14: Date?,
                               latestWakeSetting: DateComponents?, recommendedBedtime: Date?,
                               medianOnset14: Date?) -> PhaseAnchors {
        let usual = usualWake(medianWake14: medianWake14, latestWakeSetting: latestWakeSetting, calendar: calendar)
        let usualLast = lastOccurrence(of: usual, atOrBefore: now, calendar: calendar)

        let wake: Date
        let assumed: Bool
        if let d = detectedWake, d <= now, !(usualLast.timeIntervalSince(d) > staleWakeAfter) {
            wake = d
            assumed = false
        } else {
            wake = usualLast
            assumed = true
        }

        let bedtime: Date
        let source: BedtimeSource
        let usualOnset = medianOnset14.map { TimeOfDay(of: $0, calendar: calendar) } ?? fallbackBedtime
        if let r = recommendedBedtime, r > wake, r <= wake.addingTimeInterval(24 * hour),
           inSleepWindow(r, usualOnset: usualOnset, calendar: calendar)
            || scheduledSleepFits(r, latestWakeSetting: latestWakeSetting, calendar: calendar) {
            bedtime = r
            source = .model
        } else if let m = medianOnset14 {
            bedtime = firstOccurrence(of: TimeOfDay(of: m, calendar: calendar), after: wake, calendar: calendar)
            source = .usual
        } else {
            bedtime = firstOccurrence(of: fallbackBedtime, after: wake, calendar: calendar)
            source = .fallback2300
        }

        let latest = latestWakeSetting.flatMap { TimeOfDay($0) }.map {
            firstOccurrence(of: $0, after: bedtime, calendar: calendar)
        }
        return PhaseAnchors(wake: wake, wakeAssumed: assumed, bedtime: bedtime, bedtimeSource: source, latestWake: latest)
    }

    /// T9710 (2026-10-14): a model bedtime more than this far (either way, round the clock) from the usual onset is not
    /// tonight's. Mo's Today said "Bed by 11:36 AM" at 9:11 AM: ALG-115 had anchored on an odd last wake, and the only
    /// check here was (W, W + 24 h]. Someone who truly sleeps by day has a daytime usual onset, so theirs still passes;
    /// an explicit wake schedule with a plausible (<= 11 h) sleep before it also passes (first day after a schedule change).
    public static let sleepWindowHalfWidth: TimeInterval = 6 * 3600

    /// T9728: an explicit "must be up by" can authorize a bedtime away from the trailing onset median (first daytime
    /// sleep after a schedule change), but only when the time asleep before that wake is a plausible one (at most 11 h).
    static func scheduledSleepFits(_ bed: Date, latestWakeSetting: DateComponents?, calendar: Calendar) -> Bool {
        guard let t = latestWakeSetting.flatMap({ TimeOfDay($0) }) else { return false }
        let next = firstOccurrence(of: t, after: bed, calendar: calendar)
        return next.timeIntervalSince(bed) <= 11 * hour
    }

    /// True when `bed`'s time of day is within `sleepWindowHalfWidth` of `usualOnset` (circular, so 23:00 vs 01:00 is 2 h).
    public static func inSleepWindow(_ bed: Date, usualOnset: TimeOfDay, calendar: Calendar) -> Bool {
        let t = TimeOfDay(of: bed, calendar: calendar).secondsIntoDay
        var d = abs(t - usualOnset.secondsIntoDay) % 86_400
        d = min(d, 86_400 - d)
        return TimeInterval(d) <= sleepWindowHalfWidth
    }

    // MARK: Boundaries

    /// UX §2 table plus its clamps. Example W 06:52, B 22:30 → 11:52, 14:52, 18:30, 21:30, 23:30.
    public static func boundaries(_ a: PhaseAnchors) -> PhaseBoundaries {
        let w = a.wake
        let b = a.bedtime
        let night = max(b.addingTimeInterval(-1 * hour), w)
        let early = clamp(w.addingTimeInterval(5 * hour), w, night)
        let late = clamp(w.addingTimeInterval(8 * hour), early, night)
        // Short day: sundown starts at W + 8 h but never later than B − 1 h; late afternoon is then empty.
        let sundown = clamp(b.addingTimeInterval(-4 * hour), late, night)
        let lateNight = max(b.addingTimeInterval(1 * hour), night)
        let golden: Date? = late < sundown ? max(late, sundown.addingTimeInterval(-1 * hour)) : nil
        return PhaseBoundaries(wake: w, earlyAfternoon: early, lateAfternoon: late, sundown: sundown, night: night,
                               lateNight: lateNight, goldenStart: golden)
    }

    static func clamp(_ x: Date, _ lo: Date, _ hi: Date) -> Date { max(lo, min(x, hi)) }

    // MARK: Theme and just-woke

    /// "Follow the day" theme (UX §1.1): cream → golden for the last 60 min of late afternoon → emerald from sundown →
    /// emerald low in late night.
    public static func dayTheme(at now: Date, phase: DayPhase, boundaries: PhaseBoundaries) -> ThemeName {
        switch phase {
        case .morning, .earlyAfternoon:
            return .cream
        case .lateAfternoon:
            if let g = boundaries.goldenStart, now >= g { return .creamGolden }
            return .cream
        case .sundown, .night:
            return .emerald
        case .lateNight:
            return .emeraldLow
        }
    }

    public static func theme(at now: Date, phase: DayPhase, boundaries: PhaseBoundaries,
                             preference: ThemePreference) -> ThemeName {
        switch preference {
        case .followDay: return dayTheme(at: now, phase: phase, boundaries: boundaries)
        case .cream: return .cream
        case .emerald: return .emeraldLow
        case .followSystem(let dark): return dark ? .emerald : .cream
        }
    }

    /// Just woke: W → W + 60 min, held open while the morning check-in is unanswered, never past W + 3 h, only in Morning.
    public static func isJustWoke(now: Date, phase: DayPhase, wake: Date, checkinAnswered: Bool) -> Bool {
        guard phase == .morning, now >= wake else { return false }
        if now < wake.addingTimeInterval(1 * hour) { return true }
        return !checkinAnswered && now < wake.addingTimeInterval(3 * hour)
    }

    /// When the just-woke context ends, if it is on now.
    public static func justWokeEnds(wake: Date, checkinAnswered: Bool) -> Date {
        wake.addingTimeInterval((checkinAnswered ? 1 : 3) * hour)
    }

    /// The earliest instant after `now` at which W changes (Late night ends): the next usual wake that would make the
    /// current detection stale, or a future detected wake arriving.
    public static func nextAnchorChange(now: Date, calendar: Calendar, anchors: PhaseAnchors, detectedWake: Date?,
                                        medianWake14: Date?, latestWakeSetting: DateComponents?) -> Date {
        let usual = usualWake(medianWake14: medianWake14, latestWakeSetting: latestWakeSetting, calendar: calendar)
        var next = firstOccurrence(of: usual, after: now, calendar: calendar)
        if !anchors.wakeAssumed, !(next.timeIntervalSince(anchors.wake) > staleWakeAfter) {
            next = firstOccurrence(of: usual, after: next, calendar: calendar)
        }
        if let d = detectedWake, d > now, d < next { next = d }
        return next
    }
}
