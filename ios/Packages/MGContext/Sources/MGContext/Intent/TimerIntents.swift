import Foundation

/// Every tap on the Timers section, and the Siri / Shortcuts "start a timer" intent, is one of these. It is NOT a
/// `UIIntent` case (that enum is switched exhaustively in AppModel+Intents); the timers controller applies it itself.
public enum TimersAction: Equatable, Sendable {
    /// `stop`: "x buzzes" (1-8, default 4) or "double tap to stop" (D-029a).
    case start(minutes: Int, stop: TimerStop, label: String)
    case cancel(UUID)
    case extend(UUID, minutes: Int)
    case setPulses(UUID, Int)
    /// Stop a ringing double-tap timer from the phone.
    case stop(UUID)
    /// Remove a finished or cancelled row (a running one is cancelled).
    case clear(UUID)
}

extension TimersBook {
    /// Applies the action and returns the one-line notice for Mo (12-hour times), or nil when there is nothing to say.
    @discardableResult
    public mutating func apply(_ action: TimersAction, now: Date, calendar: Calendar) -> String? {
        switch action {
        case let .start(minutes, stop, label):
            guard let t = start(minutes: minutes, stop: stop, label: label, now: now) else {
                return running.count >= Self.maxRunning
                    ? "Already \(Self.maxRunning) timers running."
                    : "A timer can be 1 minute to 12 hours."
            }
            let buzz: String
            switch t.stop {
            case .doubleTap: buzz = "the strap buzzes until you double-tap it"
            case .buzzes: buzz = "the strap buzzes \(t.pulses) \(t.pulses == 1 ? "pulse" : "pulses")"
            }
            return "Timer set for \(MGFormat.time(t.endsAt, calendar: calendar)): the iPhone alerts and \(buzz)."
        case let .cancel(id):
            cancel(id, now: now)
            return nil
        case let .extend(id, minutes):
            extend(id, minutes: minutes, now: now)
            guard let t = timer(id), t.state == .running else { return nil }
            return "Timer now ends at \(MGFormat.time(t.endsAt, calendar: calendar))."
        case let .setPulses(id, n):
            setPulses(id, n)
            return nil
        case let .stop(id):
            stopRinging(id, now: now)
            return nil
        case let .clear(id):
            clear(id, now: now)
            return nil
        }
    }
}
