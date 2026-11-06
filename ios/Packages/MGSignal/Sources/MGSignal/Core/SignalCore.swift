import Foundation

// The hot, array-in signal functions that the Rust core may replace (ARCHITECTURE.md 4.6, frozen; 7.3 C ABI).
// WP-08 declares them here. Conformance is split by owner, all in this one module:
//   HRV/SwiftSignalCore+HRV.swift (WP-08): correctArtefacts, hrvTime, hrvFreq
//   WP-09, in its own `extension SwiftSignalCore` files: sampleEntropy, ppgSkewnessSQI, ppgBeats (Cardio/),
//   respFromRR (Resp/).
// Until WP-09's extensions exist the target does not satisfy the protocol — by design, instead of stubs that would
// return fake "missing" values (approved by main, 2026-10-11).

/// Which implementation produced a value (logged in parity mode, §7.4).
public enum SignalImplementation: String, Sendable {
    case swift = "swift"
    case rust = "rust"
}

/// ALG-004 A output. `flags` is aligned with the OUTPUT `rrMs` (same count): what produced each interval —
/// `ArtefactFlag` 0 ok, 1 ectopic, 2 missed, 3 extra, 4 long/short. `correctedFraction` = (corrections applied +
/// invalid values removed) / input intervals. Every correction preserves the total duration of the series.
public struct ArtefactResult: Sendable, Equatable {
    public var rrMs: [Double]
    public var flags: [UInt8]
    public var correctedFraction: Double

    public init(rrMs: [Double], flags: [UInt8], correctedFraction: Double) {
        self.rrMs = rrMs
        self.flags = flags
        self.correctedFraction = correctedFraction
    }
}

/// ALG-010 time domain + Poincaré on one R-R series (ms; pnn50 in %; lnRmssd = ln of RMSSD in ms).
public struct HRVTime: Sendable, Equatable {
    public var meanRR: Double
    public var sdnn: Double
    public var rmssd: Double
    public var pnn50: Double
    public var lnRmssd: Double
    public var sd1: Double
    public var sd2: Double
    public var n: Int

    public init(meanRR: Double, sdnn: Double, rmssd: Double, pnn50: Double, lnRmssd: Double, sd1: Double, sd2: Double,
                n: Int) {
        self.meanRR = meanRR
        self.sdnn = sdnn
        self.rmssd = rmssd
        self.pnn50 = pnn50
        self.lnRmssd = lnRmssd
        self.sd1 = sd1
        self.sd2 = sd2
        self.n = n
    }
}

/// ALG-011 Lomb–Scargle band powers in ms²: LF 0.04–0.15 Hz, HF 0.15–0.40 Hz, total 0.001–0.40 Hz.
public struct HRVFreq: Sendable, Equatable {
    public var lf: Double
    public var hf: Double
    public var lfHf: Double
    public var total: Double

    public init(lf: Double, hf: Double, lfHf: Double, total: Double) {
        self.lf = lf
        self.hf = hf
        self.lfHf = lfHf
        self.total = total
    }
}

/// ALG-121 breathing rate from R-R (WP-09 fills it).
public struct RespEstimate: Sendable, Equatable {
    public var brPerMin: Double
    public var peakPower: Double
    public var quality: Double

    public init(brPerMin: Double, peakPower: Double, quality: Double) {
        self.brPerMin = brPerMin
        self.peakPower = peakPower
        self.quality = quality
    }
}

/// The functions Rust may replace (§4.6, §7). nil = too little or unusable input; the ALG namespaces wrap these with
/// a reason (`Computed<T>`, R6).
public protocol SignalCore: Sendable {
    var implementation: SignalImplementation { get }
    /// ALG-004 A (Lipponen & Tarvainen 2019).
    func correctArtefacts(rrMs: [Double]) -> ArtefactResult
    /// ALG-010.
    func hrvTime(rrMs: [Double]) -> HRVTime?
    /// ALG-011 Lomb–Scargle, LF .04–.15, HF .15–.40.
    func hrvFreq(rrMs: [Double]) -> HRVFreq?
    /// ALG-013 / APP-233 (WP-09).
    func sampleEntropy(rrMs: [Double], m: Int, r: Double) -> Double?
    /// ALG-121 RSA: Lomb–Scargle peak of R-R in the HF band 0.15–0.40 Hz (WP-09).
    func respFromRR(rrMs: [Double]) -> RespEstimate?
    /// ALG-005 (WP-09).
    func ppgSkewnessSQI(_ x: [Double], fs: Double) -> Double?
    /// Peak indices, ALG-015 / ALG-108 (WP-09).
    func ppgBeats(_ x: [Double], fs: Double) -> [Int]
}

/// The Swift implementation (default). Method bodies live in extensions next to each algorithm family.
public struct SwiftSignalCore: SignalCore {
    public init() {}
    public var implementation: SignalImplementation { .swift }
}

/// The core every pipeline calls. Set once by the composition root (§7.4): `RustSignalCore(fallback:)` when the
/// MGCoreRust package is linked, else this default.
public enum Signal {
    public static var core: any SignalCore = SwiftSignalCore()
}
