import Foundation

/// Nov 5 2026 (audit apple-health-background-sync, fix 1): `enableBackgroundDelivery`'s completion was `{ _, _ in }`, so a
/// refused enable (missing entitlement, a type iOS will not deliver in the background) was invisible. Each result is kept
/// here, per type, and shown in the debug channel's `health_sync` block. Pure Swift; the HealthKit layer feeds it.
public final class HealthBackgroundDeliveryLog: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public var at: Date
        public var enabled: Bool
        /// nil when it worked.
        public var error: String?

        public init(at: Date, enabled: Bool, error: String?) {
            self.at = at
            self.enabled = enabled
            self.error = error
        }
    }

    /// This process's log (the observers are registered once per launch).
    public static let shared = HealthBackgroundDeliveryLog()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// `success` and `error` are the two values of `enableBackgroundDelivery`'s completion. A later result for the same type
    /// replaces the earlier one. `success == false` with no error still counts as a failure.
    public func record(typeID: String, success: Bool, error: Error?, at: Date = Date()) {
        let ok = success && error == nil
        let text = error.map { "\($0)" } ?? (ok ? nil : "iOS answered \"not enabled\" without an error")
        lock.lock()
        entries[typeID] = Entry(at: at, enabled: ok, error: text)
        lock.unlock()
    }

    public var all: [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// "HKQuantityTypeIdentifierHeartRate" -> "HeartRate" (the debug block's key).
    public static func shortName(_ id: String) -> String {
        for p in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKDataTypeIdentifier", "HKWorkoutTypeIdentifier"]
        where id.hasPrefix(p) { return String(id.dropFirst(p.count)) }
        return id
    }

    /// (types where iOS said yes, types it refused), refused ones with the reason; both sorted by name.
    public func summary() -> (enabled: [String], refused: [String: String]) {
        let snapshot = all
        let enabled = snapshot.filter { $0.value.enabled }.keys.map(Self.shortName).sorted()
        var refused: [String: String] = [:]
        for (id, e) in snapshot where !e.enabled { refused[Self.shortName(id)] = e.error ?? "refused" }
        return (enabled, refused)
    }
}
