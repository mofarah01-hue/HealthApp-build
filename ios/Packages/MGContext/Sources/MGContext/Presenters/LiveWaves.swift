import Foundation
import MGDomain

/// T146 (Mo 2026-10-12: "eventually wave forms too in the live tab with the hr graph"): one row per extra stream under the
/// Live tab's heart-rate graph - raw PPG (every block and slot as the strap sends them), 100 Hz motion, ECG. Each row carries its
/// own switch (the same intent the Strap & sync switch sends), the wave when the switch is on and data arrives, otherwise
/// the plain reason. All choices are made here; the view only draws.
public struct LiveWaveRow: Equatable, Sendable, Identifiable {
    /// "ppg" · "motion" · "ecg".
    public var id: String
    /// "Raw PPG (R20)" · "100 Hz motion" · "ECG (research)".
    public var title: String
    /// What the axis is: "last 5 s, ends now · raw counts, no unit · ...".
    public var note: String
    /// The stream's switch, beside the wave: tapping sends its intent (on <-> off).
    public var toggle: ToggleState
    /// Waves to draw, oldest sample first; empty = nothing to draw (see `reason`).
    public var waves: [OpticalWave]
    /// Why nothing is drawn (switch off, waiting for the strap, not captured yet); nil while a wave draws.
    public var reason: String?
    /// A status line under the wave (motion: "Raw motion · streaming · 312 s").
    public var detail: String?
    /// Buttons that belong to the row (motion: Record 2 / 10 / 30 min).
    public var actions: [ActionState]

    public init(id: String, title: String, note: String, toggle: ToggleState, waves: [OpticalWave] = [],
                reason: String? = nil, detail: String? = nil, actions: [ActionState] = []) {
        self.id = id
        self.title = title
        self.note = note
        self.toggle = toggle
        self.waves = waves
        self.reason = reason
        self.detail = detail
        self.actions = actions
    }
}

/// R8j: which raw PPG ids the app's `LivePPGFeed` holds samples for. MGContext cannot see MGSignal, so the UI installs a
/// closure once (`LiveFeedBridge.install()`); nothing installed = no ids = every wave keeps its samples (the old behaviour).
public final class LiveFeedProbe: @unchecked Sendable {
    public static let shared = LiveFeedProbe()
    private let lock = NSLock()
    private var provider: (@Sendable () -> Set<Int>)?

    public init() {}

    public func install(_ provider: (@Sendable () -> Set<Int>)?) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    public func ids() -> Set<Int> {
        lock.lock()
        let p = provider
        lock.unlock()
        return p?() ?? []
    }
}

public enum LiveWaves {
    /// A wave is drawn with at most this many points.
    static let maxPoints = 250

    /// R9f: the 100 Hz motion channel lives in the UI's own feed (same type as the raw PPG one, different object). In the
    /// ids `LiveFeedProbe` reports, motion channel `n` is `motionIDBase + n`, so it cannot be mistaken for a PPG block.
    public static let motionIDBase = 1000

    /// WHOOP4-WIRE 6: the WHOOP 4.0's single optical waveform in the raw PPG row and its `LivePPGFeed`. 40 cannot be a block x 2 + slot
    /// id (blocks 0-4 give 0-9), so it is never mistaken for an R20 wave.
    public static let whoop4OpticalID = 40
    public static let whoop4OpticalLabel = "WHOOP 4.0 optical · raw counts, decoded, untested, LED unknown"

    /// T22: the ADC's full-scale value; a sample at it is clipped, not a reading.
    static let clippedCount: Int32 = 524_287

    /// T22: raw PPG ready to scale - clipped samples dropped, then the best-fit straight line (the slow drift) taken off, so the
    /// y-axis spans the pulse and not the drift. Display only; the stored counts are untouched.
    static func detrended(_ raw: [Int32]) -> [Double] {
        let kept = raw.enumerated().filter { $0.element != clippedCount }.map { (x: Double($0.offset), y: Double($0.element)) }
        guard kept.count >= 10 else { return kept.map(\.y) }      // too short to tell drift from pulse
        let n = Double(kept.count)
        let mx = kept.map(\.x).reduce(0, +) / n, my = kept.map(\.y).reduce(0, +) / n
        let sxx = kept.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) }
        let slope = sxx > 0 ? kept.reduce(0) { $0 + ($1.x - mx) * ($1.y - my) } / sxx : 0
        return kept.map { $0.y - (my + slope * ($0.x - mx)) }
    }

    /// At most `max` finite samples, oldest first, always ending with the newest one (the right edge is "now").
    /// R8j (audit 7.5): min-max buckets - each bucket keeps its lowest and highest sample, in time order - so a one-sample
    /// pulse peak or an ECG R-peak survives (taking every Nth sample dropped them).
    static func downsample(_ values: [Double], max limit: Int = maxPoints) -> [Double] {
        let finite = values.filter(\.isFinite)
        guard limit > 0, finite.count > limit else { return finite }
        return minMaxIndices(finite, limit: limit).map { finite[$0] }
    }

    /// The positions (ascending, at most `limit`, always including the last) of `values` (all finite) to keep: the lowest and
    /// highest of each bucket, in time order. Fewer than `limit` values: all positions.
    public static func minMaxIndices(_ values: [Double], limit: Int) -> [Int] {
        let n = values.count
        guard n > 0, limit > 0 else { return [] }
        guard n > limit else { return Array(0..<n) }
        let buckets = (limit - 1) / 2                      // two points per bucket + the newest sample = at most `limit`
        guard buckets >= 1 else { return [n - 1] }
        var keep: [Int] = []
        keep.reserveCapacity(buckets * 2 + 1)
        var lo = 0, hi = 0, current = 0
        func flush() {
            if lo == hi { keep.append(lo) } else { keep.append(Swift.min(lo, hi)); keep.append(Swift.max(lo, hi)) }
        }
        for i in 0..<n {
            let b = i * buckets / n
            if i == 0 || b != current {
                if i != 0 { flush() }
                current = b
                lo = i
                hi = i
            } else {
                if values[i] < values[lo] { lo = i }
                if values[i] > values[hi] { hi = i }
            }
        }
        flush()
        if keep.last != n - 1 { keep.append(n - 1) }
        return keep
    }

    /// R8j (audit 7.3, L8): when the smooth view draws a wave from `LivePPGFeed`, the row state carries only its id and label
    /// (no samples), so a new record does not change `LiveState`. Waves the feed does not hold yet keep their samples as the
    /// fallback drawing.
    static func thin(_ waves: [OpticalWave], feedIDs: Set<Int>) -> [OpticalWave] {
        waves.map { feedIDs.contains($0.id) ? OpticalWave(id: $0.id, label: $0.label, samples: []) : $0 }
    }

    /// The three rows, always in this order. `toggles` are the Live tab's stream switches (raw optical, raw motion, ECG).
    static func rows(_ s: PresenterSnapshot, toggles: [ToggleState], optical: [OpticalWave], motion: LiveMotionState?,
                     opticalNote: String?, feedIDs: Set<Int> = LiveFeedProbe.shared.ids()) -> [LiveWaveRow] {
        func toggle(_ id: String, _ title: String) -> ToggleState? {
            guard var t = toggles.first(where: { $0.id == id }) else { return nil }
            t.title = title
            return t
        }
        var out: [LiveWaveRow] = []

        let on4 = s.inputs.strap.device == "WHOOP 4.0"      // WHOOP4-WIRE 6: the 4.0's raw stream is one waveform, not R20 blocks
        if let t = toggle("rawOptical", on4 ? "Raw PPG (WHOOP 4.0)" : "Raw PPG (R20)") {
            var row = LiveWaveRow(
                id: "ppg", title: t.title,
                note: on4 ? "last 5 s, ends now · raw counts, no unit · one waveform, which LED it is stays unknown (decoded, untested)"
                    : "last 5 s, ends now · raw counts, no unit · every block, both slots, labelled by the stored LED-drive bytes (decoded, untested)",
                toggle: t)
            if !t.enabled {
                row.reason = t.disabledReason ?? "Unavailable."
            } else if !t.isOn {
                row.reason = opticalNote ?? "Off. Tap the switch to start it."
            } else if !optical.isEmpty {
                row.waves = thin(optical.map { OpticalWave(id: $0.id, label: $0.label, samples: downsample($0.samples)) },
                                 feedIDs: feedIDs)
            } else {
                row.reason = opticalNote ?? "Waiting for the strap to send it."
            }
            out.append(row)
        }

        if let t = toggle("rawMotion", "100 Hz motion") {
            var row = LiveWaveRow(
                id: "motion", title: t.title,
                note: "last seconds, ends now · accelerometer size, raw counts, no unit", toggle: t)
            if !t.enabled {
                row.reason = t.disabledReason ?? "Unavailable."
            } else if let m = motion {
                // Also while a Record session runs with the switch off: the status line says so.
                let trace = downsample(m.trace)
                if trace.count > 1 {
                    // R9f (T146): drawn like the raw PPG - from the motion feed once it holds the channel (ids only in the
                    // state), from these samples until then.
                    let motionFeed = Set(feedIDs.filter { $0 >= motionIDBase }.map { $0 - motionIDBase })
                    row.waves = thin([OpticalWave(id: 0, label: "Motion size (R21) · slow baseline removed", samples: trace)],
                                     feedIDs: motionFeed)
                } else {
                    row.reason = "Waiting for the strap to send it."
                }
                row.detail = m.line
                row.actions = m.actions
            } else {
                row.reason = "Off. Tap the switch to start it."
            }
            out.append(row)
        }

        if let t = toggle("ecg", "ECG (research)") {
            var row = LiveWaveRow(id: "ecg", title: t.title, note: "research tier · wrist ECG, finger on the sensor",
                                  toggle: t)
            if !t.enabled {
                row.reason = t.disabledReason ?? "Unavailable."
            } else if let last = LiveECGMemory.shared.last() {
                // R9f (T146): the last finished reading, drawn on its own time axis (start to end of the reading).
                let label = "Last reading, \(s.hm(last.at)) · \(last.seconds) s · "
                    + (last.filtered ? "display filter 0.5-40 Hz" : "unfiltered")
                    + " · raw counts, no voltage scale, decoded, untested"
                row.waves = [OpticalWave(id: 0, label: label, samples: last.samples)]
                row.detail = "Display only"
                    + (last.filtered ? ": band-pass 0.5-40 Hz with a powerline notch, zero-phase; the saved samples stay raw. " : ". ")
                    + "Start ECG reading for a new one."
            } else if !t.isOn {
                row.reason = "Off. Tap the switch to allow ECG readings."
            } else {
                // No data path: an ECG reading is timed and its samples live on the guided ECG screen only.
                row.reason = "Not captured yet in Live: ECG is a timed reading you start with ECG reading; "
                    + "its wave shows on that screen."
            }
            out.append(row)
        }
        return out
    }
}

/// R8j (audit 7.1): the y range of a live plot, smoothed so the trace does not "breathe" as the window slides. It grows to
/// cover a new peak at once and shrinks back slowly (an exponential fall with time constant `tau` seconds). One value per
/// plot, kept by the view in a reference box; pure arithmetic, so it is tested without a screen.
public struct PeakHoldRange: Equatable, Sendable {
    public private(set) var lo = 0.0
    public private(set) var hi = 1.0
    private var lastAt: Double?
    public var tau: Double

    public init(tau: Double = 2.5) { self.tau = tau }

    /// Feeds this frame's data range at `now` (seconds, any origin) and returns the smoothed range, padded 10 %. A
    /// non-finite or empty range leaves the last one. A clock that goes backwards, or a pause longer than `maxGap`, restarts.
    public mutating func update(dataLo: Double, dataHi: Double, now: Double, maxGap: Double = 3) -> ClosedRange<Double> {
        guard dataLo.isFinite, dataHi.isFinite, dataHi >= dataLo, now.isFinite else { return padded() }
        if let last = lastAt, now >= last, now - last <= maxGap {
            let k = 1 - exp(-(now - last) / Swift.max(tau, 0.001))
            hi = dataHi >= hi ? dataHi : hi + (dataHi - hi) * k
            lo = dataLo <= lo ? dataLo : lo + (dataLo - lo) * k
        } else {
            lo = dataLo
            hi = dataHi
        }
        lastAt = now
        return padded()
    }

    private func padded() -> ClosedRange<Double> {
        let pad = hi > lo ? (hi - lo) * 0.1 : 1
        return (lo - pad)...(hi + pad)
    }
}

extension LiveWaves {
    /// R8j (audit 7.1): at most two points per pixel column - the lowest and highest value of the samples that land in that
    /// column, in time order - so a one-sample peak survives however narrow the plot. `t` is increasing, `span` the time
    /// the full width covers. Fewer samples than two per column pass through unchanged.
    public static func minMaxColumns(t: [Double], v: [Double], span: Double, columns: Int) -> [(t: Double, v: Double)] {
        let n = Swift.min(t.count, v.count)
        guard n > 0 else { return [] }
        guard columns > 0, span > 0, n > columns * 2 else { return (0..<n).map { (t[$0], v[$0]) } }
        var out: [(t: Double, v: Double)] = []
        out.reserveCapacity(columns * 2)
        var lo = 0, hi = 0, current = -1
        func flush() {
            guard current >= 0 else { return }
            if lo == hi { out.append((t[lo], v[lo])) } else {
                out.append((t[Swift.min(lo, hi)], v[Swift.min(lo, hi)]))
                out.append((t[Swift.max(lo, hi)], v[Swift.max(lo, hi)]))
            }
        }
        for i in 0..<n {
            let c = Swift.min(columns - 1, Swift.max(0, Int(t[i] / span * Double(columns))))
            if c != current {
                flush()
                current = c
                lo = i
                hi = i
            } else {
                if v[i] < v[lo] { lo = i }
                if v[i] > v[hi] { hi = i }
            }
        }
        flush()
        return out
    }
}
