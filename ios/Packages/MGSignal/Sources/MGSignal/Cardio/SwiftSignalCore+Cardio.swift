import Foundation

// SwiftSignalCore's cardio methods (WP-09; the protocol is declared by WP-08 in Core/SignalCore.swift). Each returns
// the plain value or nil; the ALG namespaces carry the reason (Computed<T>, R6).
extension SwiftSignalCore {
    /// ALG-013 / APP-233 v1 — sample entropy (Richman & Moorman 2000); `r` is ABSOLUTE in the units of `rrMs`
    /// (pass 0.2 × SD for the HRV convention). See `ALG013.sampleEntropy`.
    public func sampleEntropy(rrMs: [Double], m: Int, r: Double) -> Double? {
        ALG013.sampleEntropy(rrMs, m: m, r: r).value
    }

    /// ALG-005 v1 — skewness SQI (Elgendi 2016) of one PPG window, systolic peaks up. See `ALG005.skewnessSQI`.
    public func ppgSkewnessSQI(_ x: [Double], fs: Double) -> Double? {
        ALG005.skewnessSQI(x, fs: fs).value
    }

    /// ALG-005 / ALG-015 / ALG-108 v1 — systolic peak indices (Elgendi 2013). See `ALG005.beats`.
    public func ppgBeats(_ x: [Double], fs: Double) -> [Int] {
        ALG005.beats(x, fs: fs)
    }
}
