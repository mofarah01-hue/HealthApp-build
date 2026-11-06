import Foundation

/// 0.5.8.1 "Raw night" (2026-10-15, Mo): the morning check for a phone that was locked all night with raw optical (R20) and
/// raw motion (R21, 100 Hz) switched on. A tiny per-minute tally, not the frames: which minutes saw at least one R20 / R21
/// frame, plus when the strap link went down and came back. The summary is one line for Settings › Usage.
///
/// A gap is two frame-minutes more than `gapMinutes` apart; a stream that is still wanted and silent for more than that up
/// to now counts as a gap too (the stream that died and never came back). A switch that is off at the check shows no
/// trailing gap.
public struct RawNightCounter: Codable, Equatable, Sendable {
    public static let gapMinutes = 2
    /// Minutes older than this are dropped on every note (a night plus the evening before).
    public static let keepSeconds: TimeInterval = 24 * 3600
    /// The summary covers this long back from now.
    public static let windowSeconds: TimeInterval = 14 * 3600

    public struct LinkEvent: Codable, Equatable, Sendable {
        public var at: Date
        public var up: Bool
        public init(at: Date, up: Bool) { self.at = at; self.up = up }
    }

    /// Unix minutes (seconds / 60) with at least one frame, ascending, no duplicates.
    public var r20: [Int64] = []
    public var r21: [Int64] = []
    public var link: [LinkEvent] = []

    public init() {}

    /// Returns true when the tally changed (a new minute), so the caller saves at most once a minute per stream.
    @discardableResult public mutating func noteR20(at: Date) -> Bool { Self.add(&r20, at) }
    @discardableResult public mutating func noteR21(at: Date) -> Bool { Self.add(&r21, at) }

    /// The strap link went down / came up. Repeats of the same direction are ignored.
    @discardableResult public mutating func noteLink(up: Bool, at: Date) -> Bool {
        if let last = link.last, last.up == up { return false }
        if link.isEmpty && up { return false }       // the first connection after launch is not a reconnect
        link.append(LinkEvent(at: at, up: up))
        let cutoff = at.addingTimeInterval(-Self.keepSeconds)
        link.removeAll { $0.at < cutoff }
        return true
    }

    private static func add(_ minutes: inout [Int64], _ at: Date) -> Bool {
        let m = Int64((at.timeIntervalSince1970 / 60).rounded(.down))
        if let last = minutes.last, m <= last { return false }      // one minute, one tick; a clock step back is ignored
        minutes.append(m)
        let cutoff = m - Int64(keepSeconds / 60)
        if let first = minutes.first, first < cutoff { minutes.removeAll { $0 < cutoff } }
        return true
    }

    public struct Gap: Equatable, Sendable {
        public var start: Date
        public var minutes: Int
    }

    /// Gaps of one stream inside [from, now]. `wanted`: add the open gap from the last frame to now.
    static func gaps(_ minutes: [Int64], from: Date, now: Date, wanted: Bool) -> [Gap] {
        let lo = Int64(from.timeIntervalSince1970 / 60), hi = Int64(now.timeIntervalSince1970 / 60)
        let inside = minutes.filter { $0 >= lo && $0 <= hi }
        guard let first = inside.first else { return [] }
        var out: [Gap] = []
        var prev = first
        for m in inside.dropFirst() {
            if m - prev > Int64(gapMinutes) {
                out.append(Gap(start: Date(timeIntervalSince1970: TimeInterval((prev + 1) * 60)), minutes: Int(m - prev - 1)))
            }
            prev = m
        }
        if wanted, hi - prev > Int64(gapMinutes) {
            out.append(Gap(start: Date(timeIntervalSince1970: TimeInterval((prev + 1) * 60)), minutes: Int(hi - prev)))
        }
        return out
    }

    /// "Raw night: R20 412 min, R21 410 min, 2 gaps (R20 1:12 AM 4 min, …), 1 reconnect". nil when nothing was counted.
    public func summary(now: Date, calendar: Calendar, r20Wanted: Bool, r21Wanted: Bool) -> String? {
        let from = now.addingTimeInterval(-Self.windowSeconds)
        let lo = Int64(from.timeIntervalSince1970 / 60), hi = Int64(now.timeIntervalSince1970 / 60)
        let n20 = r20.filter { $0 >= lo && $0 <= hi }.count
        let n21 = r21.filter { $0 >= lo && $0 <= hi }.count
        let downs = link.filter { !$0.up && $0.at >= from }
        let reconnects = zip(link, link.dropFirst()).filter { !$0.0.up && $0.1.up && $0.1.at >= from }.count
        guard n20 + n21 > 0 || !downs.isEmpty else { return nil }
        let all = (Self.gaps(r20, from: from, now: now, wanted: r20Wanted).map { ("R20", $0) }
                   + Self.gaps(r21, from: from, now: now, wanted: r21Wanted).map { ("R21", $0) })
            .sorted { $0.1.start < $1.1.start }
        let shown = all.prefix(4).map { "\($0.0) \(Clock12.hm($0.1.start, calendar: calendar)) \($0.1.minutes) min" }
        var gapText = "\(all.count) gap\(all.count == 1 ? "" : "s")"
        if !shown.isEmpty { gapText += " (" + shown.joined(separator: ", ") + (all.count > 4 ? ", …" : "") + ")" }
        var text = "Raw night: R20 \(n20) min, R21 \(n21) min, \(gapText), \(reconnects) reconnect\(reconnects == 1 ? "" : "s")"
        if !downs.isEmpty {
            text += " (down " + downs.prefix(4).map { Clock12.hm($0.at, calendar: calendar) }.joined(separator: ", ")
                + (downs.count > 4 ? ", …" : "") + ")"
        }
        return text
    }
}
