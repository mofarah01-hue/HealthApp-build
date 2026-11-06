import Foundation
import WatchKit

/// One `.mgw` file = one stream chunk. Layout (../FORMAT.md):
///   "MGW1\n" + header JSON (one line) + "\n" + payload, payload = raw DEFLATE of fixed-size little-endian records.
/// The PC importer (pclab/mglab/import_watch.py) reads it; neither side guesses a field it was not told.
enum MGWStream: String {
    case hr          // f64 t, f32 bpm
    case accel       // f64 t, f32 x, y, z (g)                 batched, during a recording
    case motion      // f64 t, 13 x f32 (see fields)           batched device motion, during a recording
    case bgaccel     // f64 t, f32 x, y, z (g)                 CMSensorRecorder, background 50 Hz
    case session     // no records: start / end / rates in the header

    var record: String {
        switch self {
        case .hr: return "<df"
        case .accel, .bgaccel: return "<dfff"
        case .motion: return "<d13f"
        case .session: return ""
        }
    }
    var fields: [String] {
        switch self {
        case .hr: return ["t", "bpm"]
        case .accel, .bgaccel: return ["t", "x", "y", "z"]
        case .motion: return ["t", "ua_x", "ua_y", "ua_z", "rot_x", "rot_y", "rot_z",
                              "q_w", "q_x", "q_y", "q_z", "grav_x", "grav_y", "grav_z"]
        case .session: return []
        }
    }
    var units: [String] {
        switch self {
        case .hr: return ["unix_s", "bpm"]
        case .accel, .bgaccel: return ["unix_s", "g", "g", "g"]
        case .motion: return ["unix_s", "g", "g", "g", "rad/s", "rad/s", "rad/s", "1", "1", "1", "1", "g", "g", "g"]
        case .session: return []
        }
    }
}

/// Little-endian record buffer.
struct RecordBuffer {
    private(set) var data = Data()
    private(set) var count = 0
    private(set) var t0: Double?
    private(set) var t1: Double?

    mutating func append(t: Double, _ values: [Float]) {
        var bits = t.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        for v in values {
            var b = v.bitPattern.littleEndian
            withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
        }
        count += 1
        if t0 == nil { t0 = t }
        t1 = t
    }
}

enum Device {
    /// "Watch7,5" style hardware id (sysctl hw.machine).
    static var machine: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
    static var info: [String: String] {
        let d = WKInterfaceDevice.current()
        return [
            "machine": machine,
            "system": "\(d.systemName) \(d.systemVersion)",
            "vendor_id": d.identifierForVendor?.uuidString ?? "",
            "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + " ("
                + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")",
        ]
    }
}

enum MGWFile {
    static var outbox: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("outbox")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Writes one chunk to the outbox and returns its URL. `extra` lands in the header as-is (rates, workout ids).
    @discardableResult
    static func write(stream: MGWStream, sessionID: String, chunk: Int, buffer: RecordBuffer,
                      extra: [String: Any] = [:]) throws -> URL {
        let packed = buffer.data.isEmpty ? Data() : try (buffer.data as NSData).compressed(using: .zlib) as Data
        var header: [String: Any] = [
            "format": "mgw/1", "stream": stream.rawValue, "record": stream.record, "fields": stream.fields,
            "units": stream.units, "session_id": sessionID, "chunk": chunk, "count": buffer.count,
            "t0": buffer.t0 ?? NSNull(), "t1": buffer.t1 ?? NSNull(), "payload": "deflate-raw",
            "payload_raw_bytes": buffer.data.count, "written_at": Date().timeIntervalSince1970,
            "device": Device.info,
        ]
        for (k, v) in extra { header[k] = v }
        var file = Data("MGW1\n".utf8)
        file.append(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        file.append(Data("\n".utf8))
        file.append(packed)
        let name = "\(sessionID)_\(stream.rawValue)_\(String(format: "%05d", chunk)).mgw"
        let url = outbox.appendingPathComponent(name)
        try file.write(to: url, options: .atomic)
        return url
    }
}
