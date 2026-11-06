import Foundation
import MGDomain
import WhoopProtocol

/// WHOOP 4.0 live raw frames (packet type 43, started by command 63): the IMU frame (payload 1917) and the optical frame
/// (payload 1921). WHOOP4-WIRE 6. DECODED, UNTESTED on a real 4.0: no golden capture of either frame is in this repository, so the
/// tests build frames from the documented offsets (they catch offset / sign / length mix-ups, not a wrong document).
///
/// Source for every number: ryanbr/noop docs/PROTOCOL_SENSORS.md "WHOOP 4 realtime raw layouts (type 43)" (live, read 2026-11-05) and
/// docs/research/WHOOP4-INVENTORY-2026-11-05.md §3-§4. Offsets are absolute in the complete 4.0 frame
/// (`AA | len u16 | crc8 | type seq cmd payload | crc32`), so frame length = payload length + 11 ("validated payload length, which
/// equals declared length minus 7").
///   Common prefix: unix seconds u32 LE at 15, subseconds u16 LE at 19 (noop: "documented for this version").
///   1,917 payload (IMU): accelerometer X/Y/Z = 100 x i16 LE from 89 / 289 / 489; gyroscope from 692 / 892 / 1092. Scales "commonly
///     applied", not confirmed: accelerometer 1/4096 g, gyroscope 2000/32768 deg/s. The counts are kept RAW here, as for the 5/MG R21;
///     the scales are constants below for whoever draws them.
///   1,921 payload (optical): an optical header at 21-41, then ONE signed 24-bit little-endian AC-coupled waveform from 42 with
///     stride 4, "up to 419 samples". Byte 3 of each stride is not understood and is kept ("must be retained"). Which LED each
///     sample is: unknown (noop: "did not expose four interleaved wavelength channels").
enum Whoop4RawDecode {
    static let imuPayload = 1917
    static let opticalPayload = 1921
    static let framePadding = 11            // frame length - payload length
    static let tsOffset = 15
    static let fractionOffset = 19
    static let accelColumns = [89, 289, 489]
    static let gyroColumns = [692, 892, 1092]
    static let samplesPerAxis = 100
    static let opticalHeaderRange = 21..<42
    static let opticalStart = 42
    static let opticalStride = 4
    static let opticalMaxSamples = 419

    /// "Commonly applied" scales (noop PROTOCOL_SENSORS), not confirmed device parameters.
    static let accelGPerCount = 1.0 / 4096.0
    static let gyroDegPerSecPerCount = 2000.0 / 32768.0

    /// A live WHOOP 4.0 frame is packet type 43 with an intact CRC8 / CRC32 and one of the two documented payload lengths.
    static func payloadLength(_ frame: [UInt8]) -> Int? {
        guard frame.count > framePadding, frame[0] == 0xAA, frame[4] == 43 else { return nil }
        let n = frame.count - framePadding
        guard n == imuPayload || n == opticalPayload, verifyFrame(frame, family: .whoop4).ok else { return nil }
        return n
    }

    /// The strap's own unix seconds when they are plausible (within a minute of the phone), else the phone's second: a 4.0 whose
    /// clock is wrong must not date motion rows wrongly (the same rule as the live beats).
    static func stamp(_ frame: [UInt8], receivedAt: Date) -> (ts: Int64, fraction: Int) {
        let strap = Int64(le32(frame, tsOffset))
        let phone = Int64(receivedAt.timeIntervalSince1970)
        if abs(strap - phone) <= 60 { return (strap, u16(frame, fractionOffset)) }
        return (phone, 0)
    }

    /// 100 samples per axis, raw counts; nil unless this is an intact 1,917-payload frame.
    static func motionSecond(_ frame: [UInt8], receivedAt: Date, source: String = "live") -> MotionSecond? {
        guard payloadLength(frame) == imuPayload else { return nil }
        var columns: [[Int16]] = []
        for base in accelColumns + gyroColumns { columns.append((0..<samplesPerAxis).map { i16(frame, base + 2 * $0) }) }
        let s = stamp(frame, receivedAt: receivedAt)
        return MotionSecond(ts: s.ts, fraction: s.fraction, accelCount: samplesPerAxis, gyroCount: samplesPerAxis, source: source,
                            packed: MotionPack.encode(columns))
    }

    /// One optical frame: nil unless this is an intact 1,921-payload frame.
    static func optical(_ frame: [UInt8], receivedAt: Date) -> Whoop4OpticalFrame? {
        guard payloadLength(frame) == opticalPayload else { return nil }
        var samples: [Int32] = []
        var aux: [UInt8] = []
        for i in 0..<opticalMaxSamples {
            let o = opticalStart + i * opticalStride
            guard o + 3 < frame.count - 4 else { break }
            let raw = Int32(frame[o]) | Int32(frame[o + 1]) << 8 | Int32(frame[o + 2]) << 16
            samples.append(raw >= 0x80_0000 ? raw - 0x100_0000 : raw)   // signed 24-bit
            aux.append(frame[o + 3])
        }
        // "Up to 419 samples" and no count field is documented: a run of all-zero strides at the end is padding, not signal.
        while let last = samples.last, last == 0, aux.last == 0 {
            samples.removeLast()
            aux.removeLast()
        }
        let s = stamp(frame, receivedAt: receivedAt)
        return Whoop4OpticalFrame(strapSeconds: s.ts, header: Array(frame[opticalHeaderRange]), samples: samples, strideByte3: aux)
    }

    private static func u16(_ f: [UInt8], _ o: Int) -> Int { Int(f[o]) | Int(f[o + 1]) << 8 }
    private static func le32(_ f: [UInt8], _ o: Int) -> UInt32 {
        UInt32(f[o]) | UInt32(f[o + 1]) << 8 | UInt32(f[o + 2]) << 16 | UInt32(f[o + 3]) << 24
    }
    private static func i16(_ f: [UInt8], _ o: Int) -> Int16 { Int16(bitPattern: UInt16(f[o]) | UInt16(f[o + 1]) << 8) }
}

/// One live optical frame of a WHOOP 4.0 (type 43, payload 1921): raw signed 24-bit counts, no unit, LED unknown.
public struct Whoop4OpticalFrame: Equatable, Sendable {
    /// Strap seconds when plausible, else the phone's second at arrival.
    public var strapSeconds: Int64
    /// The 21 header bytes at frame 21-41, unmapped, kept.
    public var header: [UInt8]
    /// Signed 24-bit samples, oldest first, up to 419 (trailing all-zero strides trimmed).
    public var samples: [Int32]
    /// Byte 3 of every stride, not understood, kept (same count as `samples`).
    public var strideByte3: [UInt8]

    public init(strapSeconds: Int64, header: [UInt8], samples: [Int32], strideByte3: [UInt8]) {
        self.strapSeconds = strapSeconds
        self.header = header
        self.samples = samples
        self.strideByte3 = strideByte3
    }
}

/// What the 4.0's raw stream (63) is doing, for Settings and Live (the 4.0 counterpart of `RawMotionStatus` / `RawOpticalStatus`).
public struct Whoop4RawStatus: Equatable, Sendable {
    /// The app wants the stream (a raw switch is on and it may run now).
    public var wanted = false
    /// 63 [01] was acknowledged on this connection and no OFF since.
    public var on = false
    public var imuFrames = 0
    public var opticalFrames = 0
    public var lastImuAt: Date?
    public var lastOpticalAt: Date?
    /// Why it is not streaming although wanted (a refusal, waiting for a history download), or nil.
    public var stoppedReason: String?

    public init() {}
}
