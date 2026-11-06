import Foundation
import HealthKit
import CoreMotion

/// "Record" mode: an HKWorkoutSession (keeps the app alive and the heart-rate sensor running) plus
/// CMBatchedSensorManager accelerometer and device motion, which only deliver during an active workout.
/// Apple: developer.apple.com/documentation/coremotion/cmbatchedsensormanager (watchOS 10+).
@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    @Published private(set) var running = false
    @Published private(set) var status = "Ready"
    @Published private(set) var bpm: Double?
    @Published private(set) var accelCount = 0
    @Published private(set) var motionCount = 0
    @Published private(set) var accelHz: Int?        // what the Watch reports, never assumed
    @Published private(set) var motionHz: Int?
    @Published private(set) var startedAt: Date?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let batched = CMBatchedSensorManager()
    private var tasks: [Task<Void, Never>] = []
    private var sessionID = ""
    private var accel = RecordBuffer(), motion = RecordBuffer()
    private var accelChunk = 0, motionChunk = 0
    private var errors: [String] = []
    /// Flush a stream to a file at this many records (~30 s at 800 Hz accel), so memory stays small.
    private let flushAt = 24_000

    func requestAuthorization() async {
        let hr = HKQuantityType(.heartRate)
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hr])
        } catch {
            status = "Health permission: \(error.localizedDescription)"
        }
    }

    func start() async {
        guard !running else { return }
        await requestAuthorization()
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            b.delegate = self
            session = s; builder = b
            let now = Date()
            s.startActivity(with: now)
            try await b.beginCollection(at: now)
            sessionID = Self.idFormatter.string(from: now)
            startedAt = now
            accel = RecordBuffer(); motion = RecordBuffer()
            accelChunk = 0; motionChunk = 0; accelCount = 0; motionCount = 0; errors = []
            running = true
            status = "Recording"
            startMotion()
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard running, let s = session, let b = builder, let t0 = startedAt else { return }
        running = false
        status = "Saving…"
        tasks.forEach { $0.cancel() }
        tasks = []
        batched.stopAccelerometerUpdates()
        batched.stopDeviceMotionUpdates()
        let end = Date()
        s.end()
        var workoutUUID: String?
        do {
            try await b.endCollection(at: end)
            workoutUUID = try await b.finishWorkout()?.uuid.uuidString
        } catch {
            errors.append("finishWorkout: \(error.localizedDescription)")
        }
        flush(.accel, final: true)
        flush(.motion, final: true)
        let hrCount = await writeHeartRate(from: t0, to: end)
        let extra: [String: Any] = [
            "start": t0.timeIntervalSince1970, "end": end.timeIntervalSince1970,
            "accel_hz_reported": accelHz ?? NSNull(), "motion_hz_reported": motionHz ?? NSNull(),
            "accel_records": accelCount, "motion_records": motionCount, "hr_records": hrCount,
            "accel_chunks": accelChunk, "motion_chunks": motionChunk,
            "workout_uuid": workoutUUID ?? NSNull(), "errors": errors,
            "batched_supported": ["accel": CMBatchedSensorManager.isAccelerometerSupported,
                                  "motion": CMBatchedSensorManager.isDeviceMotionSupported],
        ]
        do {
            try MGWFile.write(stream: .session, sessionID: sessionID, chunk: 0, buffer: RecordBuffer(), extra: extra)
        } catch {
            errors.append("session file: \(error.localizedDescription)")
        }
        session = nil; builder = nil
        status = errors.isEmpty ? "Saved \(sessionID)" : "Saved with \(errors.count) problem(s)"
        PhoneLink.shared.sendOutbox()
    }

    // MARK: motion

    private func startMotion() {
        if CMBatchedSensorManager.isAccelerometerSupported {
            accelHz = batched.accelerometerDataFrequency
            tasks.append(Task { [weak self] in
                guard let self else { return }
                do {
                    for try await batch in self.batched.accelerometerUpdates() {
                        let offset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
                        for d in batch {
                            self.accel.append(t: d.timestamp + offset,
                                              [Float(d.acceleration.x), Float(d.acceleration.y), Float(d.acceleration.z)])
                        }
                        self.accelCount += batch.count
                        if self.accel.count >= self.flushAt { self.flush(.accel, final: false) }
                    }
                } catch {
                    self.errors.append("accel: \(error.localizedDescription)")
                }
            })
        } else {
            errors.append("batched accelerometer not supported on this Watch")
        }
        if CMBatchedSensorManager.isDeviceMotionSupported {
            motionHz = batched.deviceMotionDataFrequency
            tasks.append(Task { [weak self] in
                guard let self else { return }
                do {
                    for try await batch in self.batched.deviceMotionUpdates() {
                        let offset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
                        for m in batch {
                            let q = m.attitude.quaternion
                            self.motion.append(t: m.timestamp + offset, [
                                Float(m.userAcceleration.x), Float(m.userAcceleration.y), Float(m.userAcceleration.z),
                                Float(m.rotationRate.x), Float(m.rotationRate.y), Float(m.rotationRate.z),
                                Float(q.w), Float(q.x), Float(q.y), Float(q.z),
                                Float(m.gravity.x), Float(m.gravity.y), Float(m.gravity.z)])
                        }
                        self.motionCount += batch.count
                        if self.motion.count >= self.flushAt / 4 { self.flush(.motion, final: false) }
                    }
                } catch {
                    self.errors.append("motion: \(error.localizedDescription)")
                }
            })
        } else {
            errors.append("batched device motion not supported on this Watch")
        }
    }

    private func flush(_ stream: MGWStream, final: Bool) {
        let buf = stream == .accel ? accel : motion
        guard buf.count > 0 else { return }
        let chunk = stream == .accel ? accelChunk : motionChunk
        let hz = stream == .accel ? accelHz : motionHz
        do {
            try MGWFile.write(stream: stream, sessionID: sessionID, chunk: chunk, buffer: buf,
                              extra: ["rate_hz_reported": hz ?? NSNull(), "final": final])
        } catch {
            errors.append("\(stream.rawValue) chunk \(chunk): \(error.localizedDescription)")
        }
        if stream == .accel { accel = RecordBuffer(); accelChunk += 1 } else { motion = RecordBuffer(); motionChunk += 1 }
    }

    // MARK: heart rate

    /// The heart-rate samples Health stored for the recording (what the Watch actually measured, with their times),
    /// rather than the live statistics shown on screen.
    private func writeHeartRate(from t0: Date, to t1: Date) async -> Int {
        let type = HKQuantityType(.heartRate)
        let pred = HKQuery.predicateForSamples(withStart: t0, end: t1, options: [])
        let desc = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: pred)],
                                           sortDescriptors: [SortDescriptor(\.startDate)])
        do {
            let samples = try await desc.result(for: store)
            var buf = RecordBuffer()
            let unit = HKUnit.count().unitDivided(by: .minute())
            for s in samples {
                buf.append(t: s.startDate.timeIntervalSince1970, [Float(s.quantity.doubleValue(for: unit))])
            }
            let sources = Set(samples.map { $0.sourceRevision.source.bundleIdentifier })
            try MGWFile.write(stream: .hr, sessionID: sessionID, chunk: 0, buffer: buf,
                              extra: ["hk_sources": Array(sources).sorted()])
            return buf.count
        } catch {
            errors.append("heart rate: \(error.localizedDescription)")
            return 0
        }
    }

    static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "'w'yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}

extension Recorder: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hr = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hr),
              let q = workoutBuilder.statistics(for: hr)?.mostRecentQuantity() else { return }
        let v = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        Task { @MainActor in self.bpm = v }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
