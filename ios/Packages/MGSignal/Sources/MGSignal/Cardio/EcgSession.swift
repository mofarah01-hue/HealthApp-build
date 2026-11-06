import Foundation
import MGDomain

/// Live ECG card, P9821 (Mo C13, 2026-10-15): the timed session (5 s lead-in, 60 s recording), a display filter and a live
/// heart rate. Display only: ALG-014 still runs on the unfiltered samples for the saved HR; raw samples are always kept.

/// Display filter for the "filtered" view: 0.5-40 Hz zero-phase band-pass (2nd-order Butterworth high-pass and low-pass,
/// run forward and back; the ECG monitoring band of AHA/ACC 2007, Kligfield et al. Circulation 115:1306) and a powerline
/// notch (50 or 60 Hz). The low-pass corner is 40 Hz, or 0.45 x the rate when the rate is below 82 Hz (a 40 Hz corner is
/// invalid there); a usable rate is never silently passed through unfiltered. The strap's rate is MEASURED (~100 Hz), so
/// a 60 Hz mains tone folds to |60 - 100| = 40 Hz; the notch is placed where the tone lands for the measured rate (an
/// alias), and skipped when that is outside 0.5 Hz...Nyquist.
public enum EcgFilter {
    public static let low = 0.5
    public static let high = 40.0

    /// Where mains at `mains` Hz appears when sampled at `fs` (folded below Nyquist).
    public static func aliasedMains(mains: Double, fs: Double) -> Double {
        abs(mains - fs * (mains / fs).rounded())
    }

    /// RBJ-cookbook notch biquad at `f0`, quality `q`.
    static func notch(f0: Double, q: Double, fs: Double) -> ALG014.Biquad {
        let w = 2 * Double.pi * f0 / fs
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return ALG014.Biquad(b0: 1 / a0, b1: -2 * cos(w) / a0, b2: 1 / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
    }

    /// Filtered copy of `x` (same length); `x` returned unchanged only when shorter than 1 s or `fs` is below 40 Hz.
    /// Both ends are padded with 2 s of odd reflection and trimmed after, so the newest samples (the live graph's right
    /// edge) are as settled as the middle.
    public static func display(_ x: [Double], fs: Double, mains: Double = 60) -> [Double] {
        guard fs >= 40, x.count > Int(fs) else { return x }
        let pad = min(x.count - 1, Int(2 * fs))
        // odd reflection about the mean of the 5 end samples (a single end sample carries the mains tone's phase as an offset)
        let a = x.prefix(5).reduce(0, +) / 5, z = x.suffix(5).reduce(0, +) / 5
        let head = (1...pad).map { 2 * a - x[$0] }.reversed()
        let tail = (1...pad).map { 2 * z - x[x.count - 1 - $0] }
        var y = ALG014.filtfilt(highpass: low, lowpass: min(high, 0.45 * fs), fs: fs, Array(head) + x + tail)
        let f = aliasedMains(mains: mains, fs: fs)
        if f > low, f < fs / 2 * 0.98 {
            let n = notch(f0: f, q: 30, fs: fs)
            y = ALG014.run(n, y)
            y.reverse()
            y = ALG014.run(n, y)
            y.reverse()
        }
        return Array(y[pad..<(pad + x.count)])
    }
}

/// Is a run of R-peaks a heartbeat? Mirrors the PC's `beat_problem` (pclab/mglab/ecg_session.py). Peak detection alone
/// reads ~105 beats/min from white noise and 60 from periodic movement spikes (Codex review 2026-10-15).
public enum EcgBeatQuality {
    /// nil when the beats look like ECG, else the reason the heart rate stays blank.
    public static func problem(x: [Double], peaks: [Int], fs: Double) -> String? {
        guard peaks.count >= 3 else { return "too few beats" }
        let rr = zip(peaks.dropFirst(), peaks).map { Double($0 - $1) / fs }
        let med = SignalMath.median(rr)
        if SignalMath.median(rr.map { abs($0 - med) }) / med > 0.2 { return "beat spacing is irregular (noise or movement)" }
        let half = Int((0.25 * fs).rounded())
        var wide = 0
        for q in peaks {
            let base = SignalMath.median(Array(x[max(0, q - half)...min(x.count - 1, q + half)]))
            let h = (max(0, q - 3)...min(x.count - 1, q + 3)).map { abs(x[$0] - base) }.max() ?? 0
            let n = (max(0, q - 5)...min(x.count - 1, q + 5)).filter { abs(x[$0] - base) >= 0.5 * h }.count
            if h > 0, n >= 3 { wide += 1 }
        }
        if Double(wide) < 0.6 * Double(peaks.count) { return "the pulses are too narrow to be heartbeats (movement?)" }
        let bpm = 60 / med
        return bpm >= 30 && bpm <= 220 ? nil : "rate outside 30-220 beats/min"
    }
}

/// One session's timing and kept samples. Pure: the app feeds it packets with the phone's receive time.
/// Timeline from `startedAt` (the moment Start was pressed and the strap asked): lead-in `leadIn` s (finger settles; the
/// front end's settling zeros fall here; nothing kept), then `duration` s recording. A packet arrives after its samples:
/// the last sample is at `receivedAt`, the others `1/nominalRate` apart before it. Samples before the recording start are
/// trimmed off the first packet, and the last packet is trimmed so exactly `duration x nominalRate` samples are kept (a
/// kept packet's `sampleCount` is set to what was kept; the raw frames stay in `raw_frame`, untouched). The recorder is
/// `isFull` at that count; late packets are taken until `finishDeadline`. A break in the packet sequence is a gap: the
/// live heart rate and the rate estimate use only the run after the last gap.
public struct EcgSessionRecorder: Equatable, Sendable {
    public enum Phase: String, Sendable { case leadIn, recording, done }

    public static let leadInSeconds = 5.0
    public static let recordSeconds = 60.0
    /// The strap's rate (measured ~100 Hz, ALG-014); used only to place samples in time inside a packet and to size 60 s.
    public static let nominalRate = 100.0
    /// How long after the nominal end a late packet (bursty delivery) is still taken before the session finishes anyway.
    public static let finishGrace = 3.0
    /// Seconds of filtered signal the live heart rate looks at.
    public static let liveWindow = 8.0

    public let startedAt: Double
    public let leadIn: Double
    public let duration: Double
    public private(set) var packets: [EcgTracePacket] = []
    public private(set) var samples: [Int16] = []
    /// Packets with nothing in the window (lead-in, after the cap or the deadline), for the receipt.
    public private(set) var discarded = 0
    /// Sample indexes where a lost or out-of-order packet broke the stream.
    public private(set) var gaps: [Int] = []
    // The current unbroken run, for the rate: arrivals, and samples delivered after the run's first packet (untrimmed).
    private var runFirst: Double?
    private var runLast = 0.0
    private var runDelivered = 0
    private var runPackets = 0
    private var runStartSample = 0
    private var lastSequence: UInt32?

    public init(startedAt: Double, leadIn: Double = leadInSeconds, duration: Double = recordSeconds) {
        self.startedAt = startedAt
        self.leadIn = leadIn
        self.duration = duration
    }

    public var recordingStart: Double { startedAt + leadIn }
    public var recordingEnd: Double { startedAt + leadIn + duration }
    public var finishDeadline: Double { recordingEnd + Self.finishGrace }
    public var capacity: Int { Int((duration * Self.nominalRate).rounded()) }
    public var isFull: Bool { samples.count >= capacity }

    public func phase(at now: Double) -> Phase {
        now < recordingStart ? .leadIn : (now < recordingEnd ? .recording : .done)
    }

    /// Whole seconds until recording starts (lead-in) or until it ends (recording); 0 when done.
    public func secondsLeft(at now: Double) -> Int {
        switch phase(at: now) {
        case .leadIn: return Int((recordingStart - now).rounded(.up))
        case .recording: return Int((recordingEnd - now).rounded(.up))
        case .done: return 0
        }
    }

    /// Keep the part of the packet that falls in the recording window. Returns whether any sample was kept.
    @discardableResult
    public mutating func accept(_ packet: EcgTracePacket, samples s: [Int16]) -> Bool {
        let n = s.count
        let first = packet.receivedAt - Double(max(n - 1, 0)) / Self.nominalRate    // time of the packet's first sample
        var lo = 0
        if first < recordingStart { lo = Int(((recordingStart - first) * Self.nominalRate - 1e-6).rounded(.up)) }
        guard !isFull, packet.receivedAt < finishDeadline, lo < n else { discarded += 1; return false }
        let kept = Array(s[lo..<min(n, lo + capacity - samples.count)])
        if let last = lastSequence, packet.sequence != last &+ 1 {      // lost or out-of-order: a new run
            gaps.append(samples.count)
            runFirst = nil; runDelivered = 0; runPackets = 0; runStartSample = samples.count
        }
        lastSequence = packet.sequence
        if runFirst == nil { runFirst = packet.receivedAt } else { runDelivered += n }
        runLast = packet.receivedAt
        runPackets += 1
        var p = packet
        p.sampleCount = kept.count
        packets.append(p)
        samples += kept
        return true
    }

    /// Sample rate (Hz) from arrival times over the current unbroken run (ALG-014's rule: samples delivered after the
    /// first packet over the arrival span), nil until 5 packets and while outside 70-130 Hz.
    public var measuredRate: Double? {
        guard runPackets >= 5, let f = runFirst, runLast > f else { return nil }
        let hz = Double(runDelivered) / (runLast - f)
        return ALG014.rateRange.contains(hz) ? hz : nil
    }

    /// Electrode contact from the strap's own flag on the last packet; nil before any packet.
    public var contact: Bool? { packets.last?.presence }

    /// Heart rate from the last `liveWindow` s of the current unbroken run: Pan-Tompkins on the unfiltered samples
    /// (ALG-014's detector), median R-R, shown only when the beats look like a heartbeat (EcgBeatQuality) and the strap
    /// does not report "no contact". Blank with a reason otherwise.
    public func liveHeartRate() -> Computed<Int> {
        guard let fs = measuredRate else { return .missing("measuring the sample rate…") }
        if contact == false { return .missing("no finger contact reported by the strap") }
        let n = Int(Self.liveWindow * fs)
        guard samples.count - runStartSample >= n else { return .missing("needs \(Int(Self.liveWindow)) s of signal") }
        let x = samples.suffix(n).map(Double.init)
        let peaks = ALG014.detect(x, fs: fs)
        var rr: [Double] = []
        for i in 1..<max(peaks.count, 1) {
            let d = Double(peaks[i] - peaks[i - 1]) / fs
            if d >= 0.3 && d <= 2.0 { rr.append(d) }
        }
        guard peaks.count >= 3, rr.count >= 2 else { return .missing("too few clear beats yet") }
        if let why = EcgBeatQuality.problem(x: x, peaks: peaks, fs: fs) { return .missing("not a clear ECG: \(why)") }
        let bpm: Double = 60 / SignalMath.median(rr)
        return .success(Int(bpm.rounded()))
    }

    /// The last `seconds` of samples for drawing: filtered (display filter) or raw; raw counts either way. The filter
    /// runs on a short window (the shown span plus 2 s), not the whole session.
    public func trace(seconds: Double, filtered: Bool) -> [Double] {
        let fs = measuredRate ?? Self.nominalRate
        let all = samples.suffix(Int((seconds + (filtered ? 2 : 0)) * fs)).map(Double.init)
        let y = filtered ? EcgFilter.display(all, fs: fs) : all
        return Array(y.suffix(Int(seconds * fs)))
    }
}
