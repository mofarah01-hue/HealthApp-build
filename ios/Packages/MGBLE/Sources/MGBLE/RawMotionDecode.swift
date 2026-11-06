import Foundation
import MGDomain
import WhoopProtocol

/// R21 (raw six-axis IMU, layout 21) → `MotionSecond`, raw counts only. Added 2026-10-11 19:50 PT (wave W8).
///
/// Layout: noop docs/PROTOCOL_SENSORS.md L390-417 @ e580175 (live) — 1,244 bytes, CRC32 at 1240 over [8,1240); layout 21
/// at byte 9; u32 unix seconds @15 (L396, L432-434) and u16 fraction @19; accelerometer valid count u16 @24 and columns
/// x/y/z at 28+2i / 228+2i / 428+2i; gyroscope count u16 @630 and columns at 640+2i / 840+2i / 1040+2i; each count is
/// bounds-checked against 100 and only that group's valid values are read; the two counts need not be equal (L413-417).
/// Carried by live packet 43 (after 81 + 106) and banked packet 47 (L432-433). WhoopProtocol's `Whoop5RawImu` decodes the
/// same buffer but only when BOTH counts are exactly 100 and applies scales; this keeps partial buffers and stays in counts.
/// Checked against noop's real capture (Whoop5RawImuTests `realFrameBytes`, fw 50.40.1.0) in MGBLETests/RawMotionTests:
/// VERIFIED against that golden for a full buffer; partial-count buffers are DECODED, untested on hardware.
enum RawMotionDecode {
    static let frameLength = 1244
    static let layout: UInt8 = 21
    static let capacity = 100
    static let accelCountOffset = 24
    static let accelColumns = [28, 228, 428]
    static let gyroCountOffset = 630
    static let gyroColumns = [640, 840, 1040]
    static let tsOffset = 15
    static let fractionOffset = 19

    /// nil unless the frame is an intact 1,244-byte layout-21 record of packet type 43 or 47 with both counts ≤ 100.
    static func motionSecond(_ frame: [UInt8], source: String) -> MotionSecond? {
        guard frame.count == frameLength, frame[8] == 43 || frame[8] == 47, frame[9] == layout,
              verifyFrame(frame, family: .whoop5).ok else { return nil }
        let a = u16(frame, accelCountOffset)
        let g = u16(frame, gyroCountOffset)
        guard a <= capacity, g <= capacity else { return nil }
        var columns: [[Int16]] = []
        for base in accelColumns { columns.append((0..<a).map { i16(frame, base + 2 * $0) }) }
        for base in gyroColumns { columns.append((0..<g).map { i16(frame, base + 2 * $0) }) }
        let ts = UInt32(frame[tsOffset]) | (UInt32(frame[tsOffset + 1]) << 8) | (UInt32(frame[tsOffset + 2]) << 16)
            | (UInt32(frame[tsOffset + 3]) << 24)
        return MotionSecond(ts: Int64(ts), fraction: u16(frame, fractionOffset), accelCount: a, gyroCount: g,
                            source: source, packed: MotionPack.encode(columns))
    }

    /// True for any layout-21 frame shape (used by the fail-safe before the CRC is checked).
    static func looksLikeR21(_ frame: [UInt8]) -> Bool {
        frame.count == frameLength && frame[9] == layout
    }

    private static func u16(_ f: [UInt8], _ o: Int) -> Int { Int(f[o]) | (Int(f[o + 1]) << 8) }
    private static func i16(_ f: [UInt8], _ o: Int) -> Int16 { Int16(bitPattern: UInt16(f[o]) | (UInt16(f[o + 1]) << 8)) }
}
