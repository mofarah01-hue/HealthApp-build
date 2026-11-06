import Foundation

/// What the Timers section draws, made from the book (pure, so the wording is tested).
public struct TimersState: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var detail: String
        public var endsAt: Date
        public var running: Bool
        public var pulses: Int
        public var stop: TimerStop
        /// A double-tap timer buzzing now (the page shows Stop).
        public var ringing: Bool
        /// Running timers only: "armed on strap at 3:05 PM" (read back from the strap) or "not armed on strap: <why>".
        /// The iPhone alert is the backstop either way.
        public var strapStatus: String?
    }

    /// Running timers first (soonest end first), then the recent finished / cancelled ones (newest first).
    public var rows: [Row]
    /// One line when something Mo should know failed (phone alert off, strap buzz missed) for the newest such timer.
    public var problem: String?

    public static let presets = [5, 10, 15, 20, 30, 45, 60]

    public static func make(_ book: TimersBook, now: Date, calendar: Calendar) -> TimersState {
        let live = book.timers.filter { $0.state == .running }.sorted { $0.endsAt < $1.endsAt }
        let done = book.timers.filter { $0.state != .running }
            .sorted { ($0.finishedAt ?? $0.cancelledAt ?? $0.endsAt) > ($1.finishedAt ?? $1.cancelledAt ?? $1.endsAt) }
        var problem: String?
        func row(_ t: StrapTimer) -> Row {
            let name = t.label.isEmpty ? MGFormat.duration(t.duration) : t.label
            let pulses = "\(t.pulses) \(t.pulses == 1 ? "pulse" : "pulses")"
            let detail: String
            switch t.state {
            case .running:
                detail = "ends \(MGFormat.time(t.endsAt, calendar: calendar)) · strap "
                    + (t.stop == .doubleTap ? "buzzes until double-tapped" : pulses)
            case .finished:
                switch t.buzz {
                case .sent: detail = "ended \(MGFormat.time(t.endsAt, calendar: calendar)) · strap buzzed \(pulses)"
                case .ringing:
                    detail = "ended \(MGFormat.time(t.endsAt, calendar: calendar)) · strap buzzing, double-tap it to stop"
                case .stopped:
                    detail = "ended \(MGFormat.time(t.endsAt, calendar: calendar)) · stopped"
                        + (t.stoppedAt.map { " at \(MGFormat.time($0, calendar: calendar))" } ?? "")
                case .missed: detail = "ended \(MGFormat.time(t.endsAt, calendar: calendar)) · strap not buzzed"
                default: detail = "ended \(MGFormat.time(t.endsAt, calendar: calendar))"
                }
            case .cancelled:
                detail = "cancelled"
            }
            if problem == nil {
                if let n = t.phoneNote, t.state == .running { problem = "iPhone alert not set: \(n)." }
                else if t.buzz == .missed, let n = t.buzzNote { problem = "Strap not buzzed: \(n)." }
            }
            var strapStatus: String?
            if t.state == .running {
                if t.strapVerifiedAt != nil, let armed = t.strapArmedFor, armed == t.endsAt {
                    // The ALARM time (what the strap will fire at), not when it was read back (review fix 8).
                    strapStatus = "armed on strap at \(MGFormat.time(armed, calendar: calendar))"
                } else if let n = t.strapNote {
                    strapStatus = n.hasPrefix("not armed on strap") ? n : "not armed on strap: \(n)"
                } else if t.strapPendingFor != nil {
                    strapStatus = "arming on strap…"
                } else {
                    strapStatus = "not armed on strap: waiting for the strap — the iPhone alert is the backup"
                }
            }
            return Row(id: t.id, title: name, detail: detail, endsAt: t.endsAt, running: t.state == .running,
                       pulses: t.pulses, stop: t.stop, ringing: t.buzz == .ringing, strapStatus: strapStatus)
        }
        let rows = (live + done).map(row)
        return TimersState(rows: rows, problem: problem)
    }
}
