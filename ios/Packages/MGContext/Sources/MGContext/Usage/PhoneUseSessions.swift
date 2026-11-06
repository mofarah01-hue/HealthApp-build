import Foundation
import MGDomain
import CryptoKit

/// C11 / T9818 (Mo, Oct 15 2026: "how long am I on my phone and at what times"): phone-use sessions built from the
/// protected-data notifications (unlock = protectedDataDidBecomeAvailable, lock = ...WillBecomeUnavailable). An ESTIMATE:
/// it is the unlocked time the app SAW; it may be over (phone left unlocked and idle, a lock notice delivered late) or
/// under (nothing is seen while the app process is suspended or not running). Pure: every time is passed in.
/// The whole log is replayed from scratch each time, so duplicate or out-of-order records cannot leave a session open.
/// Rules (a blank has a reason, nothing is invented):
///  - unlock while already unlocked, or lock with no unlock before it: ignored (the start / end is unknown);
///  - a session still open (no lock yet) is reported as `openSince`, never as a finished session;
///  - GAP, never counted: a session whose end is unknowable goes to `gaps`:
///    * the process restarted while it was open (`launch` mark),
///    * the app was suspended (`suspended` mark) and the lock came later than `suspendGrace` after it, or a later
///      `observed` check found the phone locked (missed lock) or unlocked after a suspension,
///    * the session is longer than `maxSession` (implausible: a missed lock);
///  - a session crossing local midnight is cut into one piece per day, so every piece belongs to one local day.
public enum PhoneUseSessions {
    /// A lifecycle record next to the unlock / lock ones. `observed`: at a lifecycle change the app read
    /// `isProtectedDataAvailable`; `unlocked` is that reading.
    public enum Mark: String, Codable, Equatable, Sendable { case launch, suspended, observed, heartbeat }

    public struct Transition: Codable, Equatable, Sendable {
        public var at: Date
        public var unlocked: Bool
        public var mark: Mark?
        public init(at: Date, unlocked: Bool, mark: Mark? = nil) { self.at = at; self.unlocked = unlocked; self.mark = mark }
        public static func launch(_ at: Date) -> Transition { .init(at: at, unlocked: false, mark: .launch) }
        public static func suspended(_ at: Date) -> Transition { .init(at: at, unlocked: false, mark: .suspended) }
        /// Written every `heartbeatEvery` while the process runs, with the `isProtectedDataAvailable` reading. A hole
        /// longer than `heartbeatGap` between two records of an open session means iOS had the app stopped.
        public static func heartbeat(_ at: Date, unlocked: Bool) -> Transition { .init(at: at, unlocked: unlocked, mark: .heartbeat) }
        public static func observed(_ at: Date, unlocked: Bool) -> Transition { .init(at: at, unlocked: unlocked, mark: .observed) }
    }

    public struct Session: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var seconds: Double { end.timeIntervalSince(start) }
        public init(start: Date, end: Date) { self.start = start; self.end = end }
    }

    /// Time the phone may have been in use but the app cannot measure. Never counted.
    public struct Gap: Equatable, Sendable {
        public enum Reason: String, Sendable { case processRestart, suspension, missedLock, implausiblyLong }
        public var start: Date
        public var end: Date
        public var reason: Reason
    }

    public struct Built: Equatable, Sendable {
        public var sessions: [Session]
        public var openSince: Date?
        public var gaps: [Gap]
        public init(sessions: [Session], openSince: Date?, gaps: [Gap] = []) {
            self.sessions = sessions; self.openSince = openSince; self.gaps = gaps
        }
    }

    /// A session longer than this is a missed lock, not use.
    public static let maxSession: TimeInterval = 4 * 3600
    /// After a `suspended` mark, a lock later than this is not trusted (the notice may have been queued).
    public static let suspendGrace: TimeInterval = 120
    /// How often the running app writes a heartbeat.
    public static let heartbeatEvery: TimeInterval = 30
    /// Suspension is detected from a hole this long in the records of an open session (not from the app leaving the
    /// screen: the app keeps running in the background through Bluetooth, and phone use outside the app must count).
    /// Once the log holds any heartbeat, the time up to the last record is counted and the hole is a gap.
    public static let heartbeatGap: TimeInterval = 150

    /// Append a heartbeat without growing the log without bound: of three consecutive heartbeats whose outer two are within
    /// `heartbeatGap`, the middle one carries no information and is dropped.
    public static func appendHeartbeat(_ log: [Transition], _ hb: Transition) -> [Transition] {
        var l = log
        if l.count >= 2, l[l.count - 1].mark == .heartbeat, l[l.count - 2].mark == .heartbeat,
           l[l.count - 1].unlocked == hb.unlocked, l[l.count - 2].unlocked == hb.unlocked,
           hb.at >= l[l.count - 1].at, l[l.count - 1].at >= l[l.count - 2].at,
           hb.at.timeIntervalSince(l[l.count - 2].at) <= heartbeatGap { l.removeLast() }
        l.append(hb)
        return l
    }

    static func sortedStable(_ t: [Transition]) -> [Transition] {
        t.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    /// `transitions` need not be sorted; equal times keep their order.
    public static func build(_ transitions: [Transition], calendar: Calendar) -> Built {
        var out: [Session] = [], gaps: [Gap] = []
        var open: Date?, suspendedAt: Date?, lastSeen: Date?
        var beats = false          // the log has heartbeats: holes in an open session are suspension
        func gap(_ r: Gap.Reason, until e: Date) {
            if let s = open, e > s { gaps.append(Gap(start: s, end: e, reason: r)) }
            open = nil; suspendedAt = nil
        }
        for t in sortedStable(transitions) {
            if t.mark == .heartbeat { beats = true }
            if beats, let s = open, let l = lastSeen, t.at.timeIntervalSince(l) > heartbeatGap {
                // The app was not running between `l` (last sign of life) and now: count what it saw, gap the rest.
                if l > s {
                    if l.timeIntervalSince(s) > maxSession { gaps.append(Gap(start: s, end: l, reason: .implausiblyLong)) }
                    else { out.append(contentsOf: split(Session(start: s, end: l), calendar: calendar)) }
                }
                gaps.append(Gap(start: l, end: t.at, reason: t.mark == .launch ? .processRestart : .suspension))
                open = nil; suspendedAt = nil
            }
            defer { lastSeen = open == nil ? nil : t.at }
            switch t.mark {
            case .launch:
                gap(.processRestart, until: t.at)                 // killed while open: the end is unknown
            case .suspended:
                if open != nil, suspendedAt == nil { suspendedAt = t.at }
            case .observed, .heartbeat:
                if open != nil {
                    if !t.unlocked { gap(.missedLock, until: t.at) }
                    else if suspendedAt != nil { gap(.suspension, until: t.at); open = t.at }
                } else if t.unlocked { open = t.at; suspendedAt = nil }
            case nil:
                if t.unlocked {
                    if open == nil { open = t.at; suspendedAt = nil }
                } else if let s = open {
                    if t.at <= s { open = nil; suspendedAt = nil }             // zero or negative length: nothing to show
                    else if let sp = suspendedAt, t.at.timeIntervalSince(sp) > suspendGrace { gap(.suspension, until: t.at) }
                    else if t.at.timeIntervalSince(s) > maxSession { gap(.implausiblyLong, until: t.at) }
                    else { out.append(contentsOf: split(Session(start: s, end: t.at), calendar: calendar)); open = nil; suspendedAt = nil }
                }
            }
        }
        return Built(sessions: out, openSince: open, gaps: gaps)
    }

    /// Retention for the local log: drop everything before `cutoff`, except the unlock that opened a run still open
    /// then (so no session is cut in two and no lone lock is left).
    public static func compact(_ transitions: [Transition], before cutoff: Date) -> [Transition] {
        let sorted = sortedStable(transitions)
        var openIndex: Int?
        for (i, t) in sorted.enumerated() where t.at < cutoff {
            switch t.mark {
            case .launch: openIndex = nil
            case .suspended: break
            case .observed, .heartbeat: if !t.unlocked { openIndex = nil } else if openIndex == nil { openIndex = i }
            case nil: if t.unlocked { if openIndex == nil { openIndex = i } } else { openIndex = nil }
            }
        }
        let firstKept = sorted.firstIndex { $0.at >= cutoff } ?? sorted.count
        guard let o = openIndex else { return Array(sorted[firstKept...]) }
        return [sorted[o]] + Array(sorted[firstKept...])
    }

    /// One piece per local calendar day.
    static func split(_ s: Session, calendar: Calendar) -> [Session] {
        var pieces: [Session] = []
        var a = s.start
        while true {
            guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: a)),
                  next < s.end else { pieces.append(Session(start: a, end: s.end)); return pieces }
            pieces.append(Session(start: a, end: next))
            a = next
        }
    }

    // MARK: Day summary

    public struct Day: Equatable, Sendable {
        public var minutes: Double
        /// Minutes of use in each real clock hour of the local day, in order: 23 (spring forward), 24 or 25 (fall back).
        public var hourly: [Double]
        public var hourStarts: [Date]
        public var count: Int
        public var longest: Session?
    }

    /// Chronological hour intervals from `d0` to `d1` (23 / 24 / 25 of them on a Pacific day).
    static func hours(from d0: Date, to d1: Date) -> [DateInterval] {
        var out: [DateInterval] = []
        var h = d0
        while h < d1 { let e = min(h.addingTimeInterval(3600), d1); out.append(DateInterval(start: h, end: e)); h = e }
        return out
    }

    /// An open session older than `maxSession` is a missed lock: not counted, not shown as "unlocked now".
    public static func plausibleOpen(_ built: Built, now: Date) -> Date? {
        guard let o = built.openSince, o <= now, now.timeIntervalSince(o) <= maxSession else { return nil }
        return o
    }

    /// Sessions' overlap with the local day containing `day`. An open session counts up to `now` (when `now` is on that day).
    public static func summary(_ built: Built, day: Date, now: Date, calendar: Calendar) -> Day {
        let d0 = calendar.startOfDay(for: day)
        let d1 = calendar.date(byAdding: .day, value: 1, to: d0) ?? d0.addingTimeInterval(86_400)
        let bins = hours(from: d0, to: d1)
        var all = built.sessions
        if let o = plausibleOpen(built, now: now), now > o { all.append(contentsOf: split(Session(start: o, end: now), calendar: calendar)) }
        var hourly = Array(repeating: 0.0, count: bins.count)
        var count = 0
        var longest: Session?
        for s in all {
            let a = max(s.start, d0), b = min(s.end, d1)
            guard b > a else { continue }
            count += 1
            if longest == nil || b.timeIntervalSince(a) > longest!.seconds { longest = Session(start: a, end: b) }
            for (i, h) in bins.enumerated() {
                let lo = max(a, h.start), hi = min(b, h.end)
                if hi > lo { hourly[i] += hi.timeIntervalSince(lo) / 60 }
            }
        }
        return Day(minutes: hourly.reduce(0, +), hourly: hourly, hourStarts: bins.map(\.start), count: count, longest: longest)
    }

    // MARK: Events (synced to the PC like other events; contract screen_time, kind "use", route "lock_unlock")

    /// Same session -> same id, so a re-run or a re-sync never duplicates it (the store upserts by id). A SHA-256 of the
    /// route and the start's full-precision timestamp: different starts do not share an id except by hash collision.
    static func eventID(start: Date) -> UUID {
        let route = ScreenTimeFields.Route.lockUnlock.rawValue
        let key = "phoneuse|\(route)|\(start.timeIntervalSince1970.bitPattern)"
        var h = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        h[6] = (h[6] & 0x0F) | 0x80    // version 8 (custom)
        h[8] = (h[8] & 0x3F) | 0x80    // RFC 4122 variant
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }

    public static func event(_ s: Session) -> EventRecord {
        EventRecord(id: eventID(start: s.start), type: .screenTime, at: s.start, loggedAt: nil, source: .detected,
                    note: "phone use (estimate): unlocked time seen by the app; may be over or under",
                    payload: .screenTime(ScreenTimeFields(end: s.end, kind: .use, route: .lockUnlock)))
    }

    // MARK: Settings > Usage section

    public static func section(_ built: Built, now: Date, calendar: Calendar) -> UsageState.Section {
        let day = summary(built, day: now, now: now, calendar: calendar)
        let note = "Unlocked time seen by the app; may be over or under. It is unlock to lock as iOS reports them while this app runs: a phone left unlocked and idle or a late lock notice adds time, and time while iOS has the app stopped is missing. Stretches the app cannot vouch for are left out, not counted."
        guard day.count > 0 else {
            return UsageState.Section(id: "phoneuse", title: "Phone use today (estimate)", note: note, rows: [
                UsageState.Row(id: "phoneuse.total", title: "Unlocked time seen by the app", value: "no unlock seen today",
                               detail: "Nothing recorded since midnight (Pacific): the app may not have been running.")])
        }
        let strip = Self.strip(day.hourly)
        let d0 = calendar.startOfDay(for: now)
        let todayGaps = built.gaps.filter { $0.end > d0 }.count
        let gapText = todayGaps > 0 ? " · \(todayGaps) stretch\(todayGaps == 1 ? "" : "es") not counted (app stopped or a lock missed)" : ""
        var rows = [
            UsageState.Row(id: "phoneuse.total", title: "Unlocked time seen by the app (estimate)", value: UsageMath.seconds(day.minutes * 60),
                           detail: "\(day.count) session\(day.count == 1 ? "" : "s")" + (PhoneUseSessions.plausibleOpen(built, now: now) != nil ? " · unlocked now" : "") + gapText),
            UsageState.Row(id: "phoneuse.strip", title: "By hour, midnight to midnight", value: strip,
                           detail: "One mark per clock hour from 12 AM (\(day.hourly.count) today); taller = more minutes of use in that hour."),
        ]
        if let l = day.longest {
            rows.append(UsageState.Row(id: "phoneuse.longest", title: "Longest session",
                                       value: MGFormat.timeRange(l.start, l.end, calendar: calendar), detail: UsageMath.seconds(l.seconds)))
        }
        return UsageState.Section(id: "phoneuse", title: "Phone use today (estimate)", note: note, rows: rows)
    }

    static func strip(_ hourly: [Double]) -> String {
        let marks = Array("▁▂▃▄▅▆▇█")
        return String(hourly.map { m -> Character in
            guard m > 0 else { return "·" }
            let i = Int((m / 60 * Double(marks.count)).rounded(.up)) - 1
            return marks[max(0, min(marks.count - 1, i))]
        })
    }
}
