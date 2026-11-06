import Foundation
import CoreMotion

/// Background accelerometer: CMSensorRecorder keeps 50 Hz accelerometer data for up to 3 days, which the app fetches
/// whenever it runs (launch, foreground, background refresh). Apple: developer.apple.com/documentation/coremotion/cmsensorrecorder
/// Forum reports (threads 827920, 765258) show it is re-armed on every wake in practice, so we do the same.
@MainActor
final class BackgroundAccel: ObservableObject {
    static let shared = BackgroundAccel()

    @Published private(set) var status = "—"
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "bg.enabled"); if enabled { arm() } }
    }

    private let recorder = CMSensorRecorder()
    private let armHours: Double = 12
    /// One file per slice; CMSensorRecorder answers slowly for long ranges.
    private let sliceSeconds: Double = 3600
    private var fetching = false

    private var lastFetched: Date {
        get {
            let t = UserDefaults.standard.double(forKey: "bg.lastFetched")
            return t > 0 ? Date(timeIntervalSince1970: t) : Date().addingTimeInterval(-3 * 86400)
        }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "bg.lastFetched") }
    }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "bg.enabled")
    }

    func arm() {
        guard enabled else { status = "Off"; return }
        guard CMSensorRecorder.isAccelerometerRecordingAvailable() else { status = "Not available on this Watch"; return }
        recorder.recordAccelerometer(forDuration: armHours * 3600)
        status = "Recording (re-armed \(Self.time.string(from: Date())))"
    }

    /// Fetches everything since the last fetch, in one-hour slices, leaving the last 3 minutes (the recorder makes
    /// data available with a delay). Runs off the main thread; returns the number of files written.
    func fetch() async -> Int {
        guard enabled, !fetching else { return 0 }
        fetching = true
        defer { fetching = false }
        arm()
        let until = Date().addingTimeInterval(-180)
        var from = max(lastFetched, Date().addingTimeInterval(-3 * 86400 + 60))
        var files = 0
        while from < until {
            let to = min(from.addingTimeInterval(sliceSeconds), until)
            let (buf, err) = await Task.detached(priority: .utility) { [recorder] () -> (RecordBuffer, String?) in
                var buf = RecordBuffer()
                guard let list = recorder.accelerometerData(from: from, to: to) else { return (buf, nil) }
                for case let d as CMRecordedAccelerometerData in list {
                    buf.append(t: d.startDate.timeIntervalSince1970,
                               [Float(d.acceleration.x), Float(d.acceleration.y), Float(d.acceleration.z)])
                }
                return (buf, nil)
            }.value
            if let err { status = err; break }
            if buf.count > 0 {
                let id = "b" + Recorder.idFormatter.string(from: from).dropFirst()
                do {
                    try MGWFile.write(stream: .bgaccel, sessionID: String(id), chunk: 0, buffer: buf,
                                      extra: ["range_from": from.timeIntervalSince1970, "range_to": to.timeIntervalSince1970,
                                              "rate_hz_nominal": 50])
                    files += 1
                } catch {
                    status = "Write failed: \(error.localizedDescription)"
                    break
                }
            }
            lastFetched = to
            from = to
        }
        status = "Fetched to \(Self.time.string(from: lastFetched)), \(files) file(s)"
        if files > 0 { PhoneLink.shared.sendOutbox() }
        return files
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d h:mm a"
        return f
    }()
}

/// CMSensorDataList is NSFastEnumeration only; this lets Swift `for case let` walk it.
extension CMSensorDataList: @retroactive Sequence {
    public func makeIterator() -> NSFastEnumerationIterator { NSFastEnumerationIterator(self) }
}
