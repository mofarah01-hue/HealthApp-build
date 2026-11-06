import Foundation

// SwiftSignalCore's HRV methods (WP-08). WP-09 adds sampleEntropy / respFromRR / ppgSkewnessSQI / ppgBeats in its own
// extension files (see Core/SignalCore.swift).
extension SwiftSignalCore {
    /// ALG-004 A (Lipponen & Tarvainen 2019); see `ALG004.correct`.
    public func correctArtefacts(rrMs: [Double]) -> ArtefactResult {
        ALG004.correct(rrMs: rrMs).result
    }

    /// ALG-010 v1 — Task Force 1996; see `ALG010.time`.
    public func hrvTime(rrMs: [Double]) -> HRVTime? {
        ALG010.time(rrMs: rrMs).value
    }

    /// ALG-011 v1 — Lomb–Scargle LF .04–.15, HF .15–.40; see `ALG011.freq`.
    public func hrvFreq(rrMs: [Double]) -> HRVFreq? {
        ALG011.freq(rrMs: rrMs).value
    }
}
