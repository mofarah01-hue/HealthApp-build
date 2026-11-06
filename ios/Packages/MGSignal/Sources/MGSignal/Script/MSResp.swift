import Foundation

// Swift port of Mo's master script — PART 3, respiratory rate (WP-17). See MSLoad.swift for the rules of these ports.

extension ScriptGuard {
    /// Inputs for which the script raises or returns a number from nothing: non-finite or non-positive intervals (the
    /// time axis would not increase), fewer than two intervals, or a flat series (no spectral peak exists).
    static func respInput(_ ibiMs: [Double]) -> Missing? {
        if let m = allFinite("ibiMs", ibiMs) { return m }
        if ibiMs.count < 2 { return Missing("needs at least 2 R-R intervals (have \(ibiMs.count))") }
        if ibiMs.contains(where: { $0 <= 0 }) { return Missing("R-R intervals must be greater than 0 ms") }
        if Set(ibiMs).count < 2 { return Missing("the R-R series has no variation, so its spectrum has no peak") }
        return nil
    }
}

/// MS-07 `resp_rate_kratky` — codename Kratky-Lab. Respiratory rate from respiratory sinus arrhythmia: R-R intervals
/// (ms) → beat times from their running sum → a uniform 4 Hz grid by linear interpolation (FIX F2) → first difference,
/// minus its 5-point moving average → squared FFT magnitude → the strongest bin between 0.15 and 0.40 Hz (EXACT RSA
/// band, exclusive) → ×60 = breaths per minute. Fed with R-R already corrected by ALG-004 A (ARCHITECTURE §8.2).
///
/// Port notes: the script returns its −1.0 sentinel when no bin lies in the band; the port returns `Missing`. It
/// also returns `Missing` where the script raises (fewer than 5 differences after resampling, i.e. under about 2
/// seconds of R-R) and for a flat series (the script would report the first bin of the band, a number from nothing).
/// numpy.fft.rfft is re-created by `ScriptFFT` (Bluestein over radix-2); the strongest bin is chosen by first
/// maximum, as `np.argmax` does.
public enum MS07 {
    public static let id = "MS-07"
    public static let function = "resp_rate_kratky"
    public static let codename = "Kratky-Lab"

    public static func respRateKratky(ibiMs: [Double]) -> Computed<Double> {
        if let m = ScriptGuard.respInput(ibiMs) { return .failure(m) }
        let ibiS = ibiMs.map { $0 / 1000.0 }
        let t = ScriptNumpy.cumsum(ibiS)
        let tu = ScriptNumpy.arange(t.first!, t.last!, 0.25)
        let y = ScriptNumpy.interp(tu, t, ibiS)
        var x = ScriptNumpy.diff(y)
        if x.count < 5 { return .missing("under 2 seconds of R-R: too few samples for the spectrum") }
        let smooth = ScriptNumpy.convolveSame(x, [Double](repeating: 1.0 / 5.0, count: 5))
        for i in x.indices { x[i] -= smooth[i] }
        let val = 1.0 / (Double(x.count) * 0.25)
        let power = ScriptFFT.rfftPower(x)
        let inBand = power.indices.filter { Double($0) * val > 0.15 && Double($0) * val < 0.40 }
        guard let first = inBand.first else { return .missing("no frequency bin between 0.15 and 0.40 Hz") }
        let peak = inBand.reduce(first) { power[$1] > power[$0] ? $1 : $0 }
        return .success(60.0 * (Double(peak) * val))
    }
}
