import Foundation
import MGDomain

/// Strap sleep-state flag passthrough — the G-STAGE member "strap" (variant `strap`, producer `.strap`).
/// R18 byte 81 high nibble, (b >> 4) & 3 = 0 wake / 1 still / 2 asleep / 3 up (noop docs/PROTOCOL_SENSORS.md "Motion /
/// rest state"; WhoopProtocol Interpreter.swift @81, as MGBLE RecordMapper stores it). It is the BAND's state, not a
/// sleep stage, and noop says the non-zero codes are not fully validated — so it is carried verbatim, never mapped to
/// light / deep / REM. Python: `mglab.ref.sleep.strap_flag`.
public enum SleepStrapFlag {
    public static let citation = "noop docs/PROTOCOL_SENSORS.md byte 81; WhoopProtocol Interpreter.swift @81"

    /// Which signal decides where the strap night starts and ends (D-SLEEP-LOW-5, Nov 5 2026). A PipelineSettings value, like
    /// `HRClean.Method`: the old method stays selectable.
    public enum NightMethod: String, Sendable, CaseIterable {
        /// strap-flag@1 (the method until Nov 5 2026): only the strap's code-2 epochs are asleep; codes 0, 1 and 3 are wake.
        case strapFlag = "strap-flag@1"
        /// motion-window@1: the ALG-030 motion rest window is the night; the strap flag vouches for it (>= 30 min of code 2
        /// inside) and trims it (code 0 inside the window stays wake, so a lie-in the band calls awake is not counted);
        /// codes 1 (still) and 3 (up) inside the window count as asleep. OpenStrap `band_offset.dart`: the band state "lags
        /// onset", "mid-night UP runs of 16-28 min that return to SLEEP are normal", corroboration only.
        case motionWindow = "motion-window@1"
    }

    /// Minimum strap code-2 time inside the rest window for the strap to vouch for it.
    static let vouchEpochs = 60

    /// `hyp` (the strap hypnogram or the fused one) re-drawn for `.motionWindow`: inside the rest window an epoch the strap
    /// calls 1, 2 or 3 is asleep (an unstaged `S` when `hyp` had it as wake), code 0 and a gap stay as `hyp` has them (wake /
    /// no data); outside the window every asleep epoch becomes wake. nil when the strap does not vouch for the window
    /// (fewer than 30 min of code 2 inside it): the caller keeps the strap-flag night.
    public static func motionWindowHypnogram(_ hyp: SleepHypnogram, strap: Epochs, window: ALG030.RestWindow) -> SleepHypnogram? {
        let strapCodes = Array(strap.codes.utf8)
        func code(at t: Int64) -> UInt8 {
            let i = Int((t - strap.epoch0) / 30)
            return t >= strap.epoch0 && i < strapCodes.count ? strapCodes[i] : SleepStageCode.noData.byte
        }
        var vouched = 0
        var t = (window.restStart + 29) / 30 * 30
        while t < window.restEnd {
            if code(at: t) == UInt8(ascii: "2") { vouched += 1 }
            t += 30
        }
        guard vouched >= vouchEpochs else { return nil }
        var out = Array(hyp.codes.utf8)
        for i in out.indices {
            let ts = hyp.epoch0 + Int64(i) * 30
            let c = out[i]
            let asleep = SleepStageCode(rawValue: String(UnicodeScalar(c)))?.isAsleep ?? false
            if ts >= window.restStart && ts < window.restEnd {
                let s = code(at: ts)
                if !asleep, s == UInt8(ascii: "1") || s == UInt8(ascii: "2") || s == UInt8(ascii: "3") {
                    out[i] = SleepStageCode.asleep.byte
                }
            } else if asleep {
                out[i] = SleepStageCode.wake.byte
            }
        }
        return SleepHypnogram(epoch0: hyp.epoch0, codes: String(decoding: out, as: UTF8.self))
    }

    public struct Epochs: Sendable, Equatable {
        public var epoch0: Int64
        /// One character per 30-s epoch: "0"…"3" the strap's code, "." no sample in that epoch.
        public var codes: String
        /// Minutes per code: keys "0", "1", "2", "3", ".".
        public var minutes: [String: Double]
        /// For ALG-150: 2 → S (asleep, unstaged), 0 / 1 / 3 → W, '.' kept.
        public var hypnogram: SleepHypnogram

        public init(epoch0: Int64, codes: String, minutes: [String: Double], hypnogram: SleepHypnogram) {
            self.epoch0 = epoch0
            self.codes = codes
            self.minutes = minutes
            self.hypnogram = hypnogram
        }
    }

    /// Each 30-s epoch takes the code of its LAST sample (noop SleepStager.sessionEpochSleepState) with NO
    /// carry-forward (unlike noop): an epoch without a sample is '.'. Codes outside 0–3 count as no sample.
    public static func epochs(ts: [Int64], sleepState: [Int?], spanStart: Double, spanEnd: Double) -> Computed<Epochs> {
        let e0 = SleepMath.floorTo(spanStart, 30)
        let e1 = SleepMath.ceilTo(spanEnd, 30)
        let n = Int((e1 - e0) / 30)
        guard n > 0 else { return .missing("empty span") }
        var lastT = [Int64?](repeating: nil, count: n)
        var code = [UInt8](repeating: SleepStageCode.noData.byte, count: n)
        for (t, s) in zip(ts, sleepState) {
            guard t >= e0, t < e1, let s, (0...3).contains(s) else { continue }
            let e = Int((t - e0) / 30)
            if lastT[e] == nil || t >= lastT[e]! {
                lastT[e] = t
                code[e] = UInt8(ascii: "0") + UInt8(s)
            }
        }
        let dot = SleepStageCode.noData.byte
        guard code.contains(where: { $0 != dot }) else {
            return .missing("no strap sleep-state samples in the span (WHOOP 4.0, or records without byte 81)")
        }
        var minutes: [String: Double] = [:]
        for k in ["0", "1", "2", "3", "."] {
            let b = k.utf8.first!
            minutes[k] = Double(code.filter { $0 == b }.count * 30) / 60.0
        }
        let hyp = code.map { c -> UInt8 in
            if c == UInt8(ascii: "2") { return SleepStageCode.asleep.byte }
            if c == dot { return dot }
            return SleepStageCode.wake.byte
        }
        return .success(Epochs(epoch0: e0, codes: String(decoding: code, as: UTF8.self), minutes: minutes,
                               hypnogram: SleepHypnogram(epoch0: e0, codes: String(decoding: hyp, as: UTF8.self))))
    }
}
