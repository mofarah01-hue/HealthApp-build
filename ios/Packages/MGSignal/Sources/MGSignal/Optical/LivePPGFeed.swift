import Foundation

/// T10005 (Mo, Oct 17 2026): the Live raw-PPG graph was choppy (it jumped once or twice a second, when a whole new
/// one-second R20 record arrived) and the phone got hot (every block redrawn and re-detrended at each update). This is the
/// buffer behind the smooth graph: the app feeds each new record's samples in as they arrive; the view asks, at a steady
/// 10-15 frames a second, for "the last N seconds as they should look right now". Samples sit on one continuous
/// timeline at the record's own sample rate and the graph plays that timeline `delay` seconds late, so a late or
/// bunched Bluetooth packet is absorbed instead of showing as a jump.
///
/// Also holds the "cleaned (ours)" trace: the zero-phase 0.5-4 Hz band-pass (ALG-144's `bandPass`, Butterworth biquads) of
/// ONE chosen block's slot, computed on a background queue (never on the main thread) at most once per new record and
/// shown only up to `now - delay`, where the filter's end effect has long passed. Raw counts, no unit; our own filter,
/// decoded, untested. Nothing here is sent to the strap and nothing is stored.
///
/// Time is a plain `Double` (seconds, any fixed origin) passed in by the caller, so tests can drive it.
public final class LivePPGFeed: @unchecked Sendable {
    /// The one buffer the app feeds and the Live view reads.
    public static let shared = LivePPGFeed()

    /// One drawn sample: `t` seconds from the left edge of the window, `v` the value (raw counts, slow baseline removed).
    public struct Point: Equatable, Sendable {
        public var t: Double
        public var v: Double
        public init(t: Double, v: Double) {
            self.t = t
            self.v = v
        }
    }

    /// The graph shows the timeline this many seconds behind real time.
    public static let delay = 1.5
    /// Seconds of samples kept per channel.
    public static let retainSeconds = 12.0
    /// Seconds of the chosen channel the cleaned trace is computed from.
    public static let cleanSeconds = 10.0
    /// A record arriving more than this many seconds after the timeline's end (data was missing), or more than
    /// `maxAhead` before it (packets bunched up beyond the delay), restarts that channel's timeline.
    public static let resyncGap = 2.0
    public static let maxAhead = 4.0
    /// The 19-bit ADC ceiling: a clipped sample is a gap in the trace, not a reading (same value as LiveWaves).
    public static let clippedCount: Int32 = 524_287
    /// The slow-baseline removal: a one-pole high-pass with this time constant (seconds). Sample by sample, so a sample's
    /// drawn value never changes after it is stored (a per-frame straight-line detrend made the trace wobble).
    public static let baselineSeconds = 1.5

    /// R8j (audit 7.1): a fixed-size ring of Doubles. Appending is O(1) and never moves the other samples (the old
    /// `removeFirst` copied the whole array on every record, with the lock held).
    struct Ring {
        private var buf: [Double]
        private var head = 0
        private(set) var count = 0
        let capacity: Int

        init(capacity: Int) {
            self.capacity = max(1, capacity)
            buf = [Double](repeating: 0, count: self.capacity)
        }

        /// Adds `x`; true when the oldest sample was overwritten to make room.
        @discardableResult
        mutating func append(_ x: Double) -> Bool {
            if count < capacity {
                buf[(head + count) % capacity] = x
                count += 1
                return false
            }
            buf[head] = x
            head = (head + 1) % capacity
            return true
        }

        /// Sample `i` counted from the oldest (0 ..< count).
        subscript(i: Int) -> Double { buf[(head + i) % capacity] }

        /// The newest `n` samples (or all), oldest first.
        func tail(_ n: Int) -> [Double] {
            let from = max(0, count - n)
            return (from..<count).map { self[$0] }
        }
    }

    struct Channel {
        var rateHz: Double
        /// Time of `shown[0]`.
        var start: Double
        /// Raw counts with the slow baseline taken off; NaN = clipped.
        var shown: Ring
        /// Raw counts as received; NaN = clipped. Source for the cleaned trace.
        var raw: Ring
        var baseline: Double?

        init(rateHz: Double, start: Double) {
            self.rateHz = rateHz
            self.start = start
            let cap = Int(LivePPGFeed.retainSeconds * rateHz)
            shown = Ring(capacity: cap)
            raw = Ring(capacity: cap)
        }

        var end: Double { start + Double(raw.count) / rateHz }

        mutating func push(raw x: Double, shown y: Double) {
            raw.append(x)
            if shown.append(y) { start += 1 / rateHz }
        }
    }

    struct Clean {
        var sourceID: Int
        var rateHz: Double
        var start: Double
        var values: [Double]
    }

    private let lock = NSLock()
    private var channels: [Int: Channel] = [:]
    private var clean: Clean?
    private var cleanBusy = false
    private let queue = DispatchQueue(label: "LivePPGFeed.clean", qos: .utility)

    public init() {}

    /// Forgets everything (switch turned off, strap disconnected).
    public func reset() {
        lock.lock()
        channels = [:]
        clean = nil
        lock.unlock()
    }

    /// Adds the next `samples` of channel `id` (block x 2 + slot), which arrived at `arrivedAt` and were sampled at
    /// `rateHz`. Pure arithmetic on a few dozen numbers: cheap enough for the main thread.
    public func append(id: Int, samples: [Int32], rateHz: Double, arrivedAt: Double) {
        guard rateHz > 0, rateHz.isFinite, arrivedAt.isFinite, !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let duration = Double(samples.count) / rateHz
        var ch = channels.removeValue(forKey: id) ?? Channel(rateHz: rateHz, start: arrivedAt - duration)
        if ch.rateHz != rateHz || ch.raw.count == 0 {
            ch = Channel(rateHz: rateHz, start: arrivedAt - duration)
        } else {
            let lag = arrivedAt - ch.end                      // > 0: samples are missing; < 0: ahead of real time
            if lag > Self.resyncGap || -lag > Self.maxAhead {
                ch = Channel(rateHz: rateHz, start: arrivedAt - duration)
            }
        }
        let alpha = 1 - exp(-1 / (rateHz * Self.baselineSeconds))
        for s in samples {
            if s == Self.clippedCount {
                ch.push(raw: .nan, shown: .nan)
                continue
            }
            let x = Double(s)
            let base = ch.baseline.map { $0 + alpha * (x - $0) } ?? x
            ch.baseline = base
            ch.push(raw: x, shown: x - base)
        }
        channels[id] = ch
    }

    /// The ids that hold samples now.
    public func ids() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return channels.keys.sorted()
    }

    /// How many samples channel `id` holds now (never more than `retainSeconds` x rate).
    func storedCount(id: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return channels[id]?.raw.count ?? 0
    }

    /// The sample rate of channel `id`, if it has samples.
    public func rateHz(id: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return channels[id]?.rateHz
    }

    /// The last `seconds` of channel `id` as they should look at `now`: the timeline up to `now - delay`, `t` counted from
    /// the window's left edge (so the right edge is `t == seconds`). Clipped samples are left out. Empty when there is
    /// nothing in that stretch.
    public func window(id: Int, now: Double, seconds: Double) -> [Point] {
        lock.lock()
        defer { lock.unlock() }
        guard let ch = channels[id] else { return [] }
        return Self.slice(count: ch.shown.count, start: ch.start, rateHz: ch.rateHz, now: now, seconds: seconds) { ch.shown[$0] }
    }

    /// The same for the cleaned trace.
    public func cleanWindow(now: Double, seconds: Double) -> [Point] {
        lock.lock()
        defer { lock.unlock() }
        guard let c = clean else { return [] }
        return Self.slice(count: c.values.count, start: c.start, rateHz: c.rateHz, now: now, seconds: seconds) { c.values[$0] }
    }

    /// Which channel the cleaned trace was made from, if there is one.
    public func cleanSourceID() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return clean?.sourceID
    }

    static func slice(count: Int, start: Double, rateHz: Double, now: Double, seconds: Double,
                      value: (Int) -> Double) -> [Point] {
        let right = now - delay
        let left = right - seconds
        guard count > 0, seconds > 0 else { return [] }
        let first = max(0, Int(((left - start) * rateHz).rounded(.up)))
        let last = min(count - 1, Int(((right - start) * rateHz).rounded(.down)))
        guard first <= last else { return [] }
        var out: [Point] = []
        out.reserveCapacity(last - first + 1)
        for i in first...last {
            let v = value(i)
            if v.isFinite { out.append(Point(t: start + Double(i) / rateHz - left, v: v)) }
        }
        return out
    }

    // MARK: cleaned trace

    /// Starts a background run of the cleaned trace for channel `id` unless one is already running. At most one run is
    /// ever queued, so a slow device skips records instead of piling work up.
    public func requestClean(id: Int) {
        lock.lock()
        if cleanBusy {
            lock.unlock()
            return
        }
        cleanBusy = true
        lock.unlock()
        queue.async { [weak self] in
            self?.computeClean(id: id)
            self?.finishClean()
        }
    }

    private func finishClean() {
        lock.lock()
        cleanBusy = false
        lock.unlock()
    }

    /// The cleaned trace of channel `id`, now (synchronous: what the background run does; tests call it directly). Needs
    /// at least 4 seconds of samples; a clipped stretch is bridged by holding the last reading so the filter sees an
    /// unbroken signal.
    public func computeClean(id: Int) {
        lock.lock()
        let snap = channels[id]
        lock.unlock()
        guard let ch = snap else { return }
        let want = Int(Self.cleanSeconds * ch.rateHz)
        let from = max(0, ch.raw.count - want)
        var x = ch.raw.tail(want)
        guard Double(x.count) >= 4 * ch.rateHz else { return }
        var held = x.first(where: { $0.isFinite }) ?? 0
        for i in x.indices {
            if x[i].isFinite { held = x[i] } else { x[i] = held }
        }
        let y = ALG144.bandPass(x, fs: ch.rateHz)
        let c = Clean(sourceID: id, rateHz: ch.rateHz, start: ch.start + Double(from) / ch.rateHz, values: y)
        lock.lock()
        clean = c
        lock.unlock()
    }

    /// The block whose slot A the cleaned trace is made from: blocks 0 and 1 are the green ones when live PPG is on (Mo,
    /// Oct 17 2026; which block is which wavelength is still not established, T20), so the lowest of them that is lit
    /// (LED-drive bytes not all zero), carries samples and is not mostly clipped. nil = neither qualifies.
    public static func cleanBlock(heads: [Int: [UInt8]], slotA: [Int: [Int32]]) -> Int? {
        for block in [0, 1] {
            guard let head = heads[block], head.count >= 7,
                  [head[2], head[3], head[5], head[6]].contains(where: { $0 != 0 }),
                  let a = slotA[block], !a.isEmpty, a.contains(where: { $0 != 0 }) else { continue }
            let clipped = Double(a.filter { $0 == clippedCount }.count) / Double(a.count)
            if clipped <= OpticalPulse.saturatedShare { return block }
        }
        return nil
    }
}
