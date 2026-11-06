import Foundation

// MARK: - Notification buzz by app and person (T53; added 2026-10-12)
//
// iOS lets an app see only its own notifications, so this covers what OUR app posts (source id "mg.<NotifyKind>"), what
// Personal OS sends (it opens `mgapp://buzz?app=personal-os&person=…`), plus Calendar and Reminders (CalendarBuzz.swift).
// Each buzz is the one-shot haptic (command 19, 1-8 pulses) and costs strap battery (T107), so the whole thing is OFF
// until Mo switches it on, an app buzzes only if he picked it, and the same app+person is held for a cooldown.
// Nothing about the message (title, body) is read or kept: only the app id and the person's name.

public struct NotificationBuzzSettings: Codable, Equatable, Sendable {
    public var on: Bool = false
    /// App id → pulses (1-8). 0 = never.
    public var apps: [String: Int] = [:]
    /// Person (lower-case) → pulses. Beats the app rule. 0 = never buzz for this person.
    public var people: [String: Int] = [:]
    /// No buzz during quiet hours (the "do not disturb" approximation: the app cannot read the Focus state).
    public var skipQuietHours: Bool = true
    /// The same app+person buzzes at most once per this many seconds.
    public var cooldownSeconds: Int = 60

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationBuzzSettings()
        on = c.tolerant(.on, d.on)
        apps = c.tolerant(.apps, d.apps)
        people = c.tolerant(.people, d.people)
        skipQuietHours = c.tolerant(.skipQuietHours, d.skipQuietHours)
        cooldownSeconds = c.tolerant(.cooldownSeconds, d.cooldownSeconds)
    }
}

public enum NotificationBuzzPlanner {
    static func normal(_ person: String?) -> String? {
        let p = person?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return p?.isEmpty == false ? p : nil
    }

    /// Key of the cooldown ledger (`lastBuzz`).
    public static func key(source: String, person: String?) -> String { source + "|" + (normal(person) ?? "") }

    /// Pulses to buzz for this notification, or nil for no buzz.
    public static func pulses(source: String, person: String?, settings s: NotificationBuzzSettings, now: Date,
                              inQuiet: Bool, lastBuzz: [String: Date]) -> Int? {
        guard s.on, !(inQuiet && s.skipQuietHours) else { return nil }
        if let last = lastBuzz[key(source: source, person: person)], now.timeIntervalSince(last) < TimeInterval(s.cooldownSeconds) {
            return nil
        }
        let n = normal(person).flatMap { s.people[$0] } ?? s.apps[source]
        guard let n, n > 0 else { return nil }
        return min(n, 8)
    }
}
