import Foundation

/// R6 (ARCHITECTURE.md §0): a value that could not be computed, and why. Never a default that looks like data.
/// Python mirror: `mglab.ref.Missing`.
public struct Missing: Error, Hashable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// What every algorithm in MGSignal returns when input can be missing: `.success(value)` or
/// `.failure(Missing(reason))`.
public typealias Computed<T> = Result<T, Missing>

extension Result where Failure == Missing {
    /// The value, or nil when missing.
    public var value: Success? {
        if case .success(let v) = self { return v }
        return nil
    }

    /// Why the value is missing, or nil when there is one.
    public var missingReason: String? {
        if case .failure(let m) = self { return m.reason }
        return nil
    }

    /// Shorthand for `.failure(Missing(reason))`.
    public static func missing(_ reason: String) -> Result<Success, Missing> {
        .failure(Missing(reason))
    }
}
