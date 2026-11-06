import Foundation

// SwiftSignalCore's respiration method (WP-09; the protocol is declared by WP-08 in Core/SignalCore.swift).
extension SwiftSignalCore {
    /// ALG-121 v1 — RSA: Lomb–Scargle peak of R-R in the HF band 0.15–0.40 Hz; nil when withheld (see
    /// `ALG121.estimate` for the reasons).
    public func respFromRR(rrMs: [Double]) -> RespEstimate? {
        ALG121.estimate(rrMs: rrMs).value
    }
}
