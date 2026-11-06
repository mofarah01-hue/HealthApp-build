import Foundation

// Raw motion (R21, 100 Hz six-axis IMU) and the MG ECG trace (R17 filtered ECG) as stored records. Added 2026-10-11
// 19:50 PT (wave W8, CLAUDE.md rule 5 as changed 12:35 PT). Layout sources (live, ryanbr/noop @ e580175):
// docs/PROTOCOL_SENSORS.md L390-428 (R21: 1,244 bytes; u32 unix seconds @15, u16 fraction @19 in 1/32768 s quantised to
// 1/100 s (L432-438); accel count @24, columns x/y/z @28/228/428; gyro count @630, columns @640/840/1040; counts ≤ 100,
// independent) and docs/PROTOCOL_ECG.md L169-195 (R17: 240 bytes, ≤ 100 signed i16 samples, physical scale and rate
// unresolved). Values stay RAW COUNTS here: no g, no deg/s, no volts. Scales are applied, with their source and a check,
// only where a number is computed (MGSignal RawMotion).

/// One strap second of raw six-axis IMU, stored compactly: one row per second, never one per sample (noop
/// docs/RAW_DATA_CAPTURE.md L70-75 gives the same reason for its segment files).
public struct MotionSecond: Codable, Hashable, Sendable {
    /// Strap unix seconds (frame @15).
    public var ts: Int64
    /// Fraction word (frame @19), 1/32768 s; 0…32440 for a valid clock reading (PROTOCOL_SENSORS.md L432-438).
    public var fraction: Int
    /// Valid accelerometer / gyroscope samples (frame @24 / @630), each 0…100 and independent.
    public var accelCount: Int
    public var gyroCount: Int
    /// "live" (packet 43 while the raw-motion switch is on) or "history" (banked packet 47).
    public var source: String
    /// `MotionPack.encode` of [ax, ay, az] (accelCount each) then [gx, gy, gz] (gyroCount each), raw i16 counts.
    public var packed: Data

    public init(ts: Int64, fraction: Int, accelCount: Int, gyroCount: Int, source: String, packed: Data) {
        self.ts = ts
        self.fraction = fraction
        self.accelCount = accelCount
        self.gyroCount = gyroCount
        self.source = source
        self.packed = packed
    }

    public init(ts: Int64, fraction: Int, source: String, columns: [[Int16]]) {
        self.init(ts: ts, fraction: fraction, accelCount: columns.first?.count ?? 0,
                  gyroCount: columns.count > 3 ? columns[3].count : 0, source: source,
                  packed: MotionPack.encode(columns))
    }

    /// The six raw columns, or nil when `packed` does not decode to exactly the stored counts.
    public var columns: [[Int16]]? {
        MotionPack.decode(packed, counts: [accelCount, accelCount, accelCount, gyroCount, gyroCount, gyroCount])
    }
}

/// One second's accelerometer magnitude summary, in raw counts, kept beside the packed samples so day and week reads stay
/// cheap. `enmoLSB` = mean of max(0, |a| − 4,096) with noop's convention 4,096 counts = 1 g (Whoop5RawImu.swift L51); it
/// becomes mg only after MGSignal RawMotion's gravity check on still seconds.
public struct MotionAccelSummary: Codable, Hashable, Sendable {
    public var ts: Int64
    public var n: Int
    public var meanMagLSB: Double
    public var sdMagLSB: Double
    public var enmoLSB: Double

    public init(ts: Int64, n: Int, meanMagLSB: Double, sdMagLSB: Double, enmoLSB: Double) {
        self.ts = ts
        self.n = n
        self.meanMagLSB = meanMagLSB
        self.sdMagLSB = sdMagLSB
        self.enmoLSB = enmoLSB
    }

    public static let countsPerG = 4096.0
}

extension MotionSecond {
    /// |a| per accelerometer sample, in counts.
    public static func magnitudes(_ c: [[Int16]]) -> [Double] {
        guard c.count >= 3 else { return [] }
        let n = min(c[0].count, c[1].count, c[2].count)
        return (0..<n).map { i in
            let x = Double(c[0][i]), y = Double(c[1][i]), z = Double(c[2][i])
            return (x * x + y * y + z * z).squareRoot()
        }
    }

    /// nil when the row does not decode or holds no accelerometer sample.
    public var accelSummary: MotionAccelSummary? {
        guard let c = columns else { return nil }
        let m = Self.magnitudes(c)
        guard !m.isEmpty else { return nil }
        let mean = m.reduce(0, +) / Double(m.count)
        let sd = (m.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(m.count)).squareRoot()
        let enmo = m.reduce(0) { $0 + max(0, $1 - MotionAccelSummary.countsPerG) } / Double(m.count)
        return MotionAccelSummary(ts: ts, n: m.count, meanMagLSB: mean, sdMagLSB: sd, enmoLSB: enmo)
    }
}

/// Lossless packing of i16 columns: per column, the first value then successive differences, each zig-zag mapped and
/// written as an unsigned LEB128 varint. A resting wrist moves a few counts per 10 ms, so most samples take one byte
/// instead of two; any i16 sequence round-trips exactly (MGDomainTests MotionPackTests).
public enum MotionPack {
    public static func encode(_ columns: [[Int16]]) -> Data {
        var out = Data()
        out.reserveCapacity(columns.reduce(0) { $0 + $1.count } * 2)
        for column in columns {
            var previous: Int32 = 0
            for value in column {
                let v = Int32(value)
                let delta = v - previous
                previous = v
                var z = UInt32(bitPattern: (delta << 1) ^ (delta >> 31))
                while z >= 0x80 {
                    out.append(UInt8(z & 0x7F) | 0x80)
                    z >>= 7
                }
                out.append(UInt8(z))
            }
        }
        return out
    }

    /// nil when the bytes run out early, a varint is longer than 5 bytes, a value leaves the i16 range, or bytes are
    /// left over — a damaged row is reported, never padded.
    public static func decode(_ data: Data, counts: [Int]) -> [[Int16]]? {
        let bytes = [UInt8](data)
        var pos = 0
        var out: [[Int16]] = []
        out.reserveCapacity(counts.count)
        for n in counts {
            guard n >= 0 else { return nil }
            var column: [Int16] = []
            column.reserveCapacity(n)
            var previous: Int32 = 0
            for _ in 0..<n {
                var z: UInt32 = 0
                var shift: UInt32 = 0
                while true {
                    guard pos < bytes.count, shift <= 28 else { return nil }
                    let b = bytes[pos]
                    pos += 1
                    z |= UInt32(b & 0x7F) << shift
                    if b & 0x80 == 0 { break }
                    shift += 7
                }
                let delta = Int32(bitPattern: (z >> 1) ^ (0 &- (z & 1)))
                let v = previous &+ delta
                guard let value = Int16(exactly: v) else { return nil }
                column.append(value)
                previous = v
            }
            out.append(column)
        }
        return pos == bytes.count ? out : nil
    }
}

/// One R17 filtered-ECG packet as it arrived, kept with the phone's receive time so ECG, live optical (R20) and raw motion
/// share one clock; the strap's own time words are kept raw (their units are not established for ECG, PROTOCOL_ECG.md
/// L120-123).
public struct EcgTracePacket: Codable, Hashable, Sendable {
    /// Phone unix seconds when the frame arrived.
    public var receivedAt: Double
    /// Record sequence (frame @11), main and additional time words (@15, @19), raw.
    public var sequence: UInt32
    public var strapWord: UInt32
    public var strapSubword: UInt16
    /// Declared sample count (@32), ≤ 100.
    public var sampleCount: Int
    /// Packed status @21…@31 as named by noop (Whoop5Ecg.swift LabradorR17), raw bytes: quality, flags (bit 3 presence),
    /// classifier result and state, progress, unreadable mask, average and live HR.
    public var quality: Int
    public var flags: Int
    public var resultCode: Int
    public var classifierState: Int
    public var progress: Int
    public var unreadable: Int
    public var averageHR: Int
    public var liveHR: Int

    public init(receivedAt: Double, sequence: UInt32, strapWord: UInt32, strapSubword: UInt16, sampleCount: Int,
                quality: Int, flags: Int, resultCode: Int, classifierState: Int, progress: Int, unreadable: Int,
                averageHR: Int, liveHR: Int) {
        self.receivedAt = receivedAt
        self.sequence = sequence
        self.strapWord = strapWord
        self.strapSubword = strapSubword
        self.sampleCount = sampleCount
        self.quality = quality
        self.flags = flags
        self.resultCode = resultCode
        self.classifierState = classifierState
        self.progress = progress
        self.unreadable = unreadable
        self.averageHR = averageHR
        self.liveHR = liveHR
    }

    /// Bit 3 of the flags byte: electrode presence as the strap debounced it (noop EcgLabradorFlags.presence).
    public var presence: Bool { flags & 0x08 != 0 }
}

/// A saved ECG reading's samples (the `ecg` event carries `samples_ref` = "ecg_trace:<event id>"). Samples are the R17
/// filtered values in arrival order, signed raw counts: no voltage scale is established (PROTOCOL_ECG.md L186-195).
public struct EcgTrace: Codable, Hashable, Sendable {
    public var eventId: UUID
    public var strapId: StrapID?
    public var samples: [Int16]
    public var packets: [EcgTracePacket]

    public init(eventId: UUID, strapId: StrapID?, samples: [Int16], packets: [EcgTracePacket]) {
        self.eventId = eventId
        self.strapId = strapId
        self.samples = samples
        self.packets = packets
    }

    public static func ref(_ eventId: UUID) -> String { "ecg_trace:\(eventId.uuidString)" }

    /// Little-endian i16 bytes of `samples` (the stored blob).
    public var sampleBytes: Data {
        var d = Data(capacity: samples.count * 2)
        for s in samples {
            let u = UInt16(bitPattern: s)
            d.append(UInt8(u & 0xFF))
            d.append(UInt8(u >> 8))
        }
        return d
    }

    public static func samples(from bytes: Data) -> [Int16]? {
        guard bytes.count % 2 == 0 else { return nil }
        let b = [UInt8](bytes)
        return stride(from: 0, to: b.count, by: 2).map { Int16(bitPattern: UInt16(b[$0]) | (UInt16(b[$0 + 1]) << 8)) }
    }
}
