import Foundation

/// R9f (T146): the last finished ECG reading's trace, kept in memory so the Live tab's ECG row can draw it (an ECG reading is
/// timed and its wave otherwise lives only on the guided ECG screen). The app stores it when a reading is saved; the Live
/// presenter reads it. At most `maxPoints` raw-count samples (the reading is already decimated for drawing); nothing is
/// written to disk here (the reading itself is saved by the ECG flow as before). The lock makes it callable from any actor.
public final class LiveECGMemory: @unchecked Sendable {
    public static let shared = LiveECGMemory()

    public struct Reading: Equatable, Sendable {
        public var at: Date
        public var seconds: Int
        /// Raw counts, no voltage scale (decoded, untested).
        public var samples: [Double]
        /// The display filter (0.5-40 Hz band-pass + powerline notch, zero-phase) was applied; the saved samples stay raw.
        public var filtered: Bool

        public init(at: Date, seconds: Int, samples: [Double], filtered: Bool) {
            self.at = at
            self.seconds = seconds
            self.samples = samples
            self.filtered = filtered
        }
    }

    public static let maxPoints = 600

    private let lock = NSLock()
    private var reading: Reading?

    public init() {}

    /// Keeps `samples` (finite values only, thinned to `maxPoints` by min-max buckets so R-peaks survive). Fewer than 2
    /// usable samples clears it.
    public func set(at: Date, seconds: Int, samples: [Double], filtered: Bool) {
        let kept = LiveWaves.downsample(samples, max: Self.maxPoints)
        lock.lock()
        defer { lock.unlock() }
        reading = kept.count >= 2 ? Reading(at: at, seconds: seconds, samples: kept, filtered: filtered) : nil
    }

    public func last() -> Reading? {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    public func clear() {
        lock.lock()
        reading = nil
        lock.unlock()
    }
}
