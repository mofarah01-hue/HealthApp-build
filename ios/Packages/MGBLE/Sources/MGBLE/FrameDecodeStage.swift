import Foundation
import MGDomain
import WhoopProtocol

/// One reassembled frame plus everything that is expensive to work out about it, computed OFF the main actor
/// (audit 2026-10-17 top-25 #6): the CRC of a type-43 frame, its R20 decode, and the mean of a raw-IMU buffer.
struct DecodedFrame: Sendable {
    let bytes: [UInt8]
    /// When the notification that completed this frame arrived (the link's clock).
    let at: Date
    /// Type-43 frames only: the frame's CRC32 verified. nil for every other type.
    var crcOK: Bool?
    /// A CRC-good live R20 record (type 43, layout 20).
    var r20: R20Record?
    /// A CRC-good 1244-byte raw-IMU buffer reduced to one motion second (the freshness gate is applied on the main actor).
    var motion: StrapMotionSecond?
}

/// The frames of one notification, in order.
struct DecodedBatch: Sendable {
    var frames: [DecodedFrame]
}

/// Reassembly + per-frame decode on a serial background task, handing results back in arrival order.
///
/// `StrapLink` is main-actor; before this stage every notification was reassembled, CRC-checked and decoded on the main
/// thread (a 2,140-byte R20 record a second with raw optical on). Now `submit` is a cheap, ordered, non-blocking yield
/// (one AsyncStream = one FIFO), the work happens on one background task, and `output` is consumed by one main-actor
/// loop, so order is preserved end to end. The pipeline is bounded: past `capacity` notifications in flight (submitted,
/// not yet applied by the main actor) a new notification is refused and counted in `droppedCount` — it never blocks.
final class FrameDecodeStage: Sendable {
    enum Input: Sendable {
        case data(channel: String, bytes: [UInt8], at: Date)
        case reset
    }

    static let defaultCapacity = 4096

    let output: AsyncStream<DecodedBatch>
    private let input: AsyncStream<Input>.Continuation
    private let gauge: Gauge
    private let capacity: Int

    /// In-flight count and drop counter. A lock, not an actor: `submit` runs on the main actor and must not suspend.
    private final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight = 0
        private var dropped = 0
        func tryAdd(capacity: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard inFlight < capacity else { dropped += 1; return false }
            inFlight += 1
            return true
        }
        func release() {
            lock.lock(); defer { lock.unlock() }
            if inFlight > 0 { inFlight -= 1 }
        }
        var droppedCount: Int { lock.lock(); defer { lock.unlock() }; return dropped }
        var pending: Int { lock.lock(); defer { lock.unlock() }; return inFlight }
    }

    init(capacity: Int = FrameDecodeStage.defaultCapacity) {
        self.capacity = capacity
        let (inStream, inCont) = AsyncStream<Input>.makeStream(bufferingPolicy: .unbounded)
        let (outStream, outCont) = AsyncStream<DecodedBatch>.makeStream(bufferingPolicy: .unbounded)
        input = inCont
        output = outStream
        gauge = Gauge()
        let gauge = self.gauge
        // Holds only the two stream ends: when the stage is released, `deinit` finishes the input and both loops end.
        Task.detached(priority: .userInitiated) {
            var reassemblers: [String: Reassembler] = [:]
            for await item in inStream {
                switch item {
                case .reset:
                    reassemblers.removeAll()
                case .data(let channel, let bytes, let at):
                    let reassembler: Reassembler
                    if let r = reassemblers[channel] {
                        reassembler = r
                    } else {
                        // One reassembler per characteristic, so fragments of two channels can never interleave into
                        // one frame (noop keeps one shared reassembler; per-channel is the stricter form).
                        reassembler = Reassembler(family: .whoop5)
                        reassemblers[channel] = reassembler
                    }
                    let frames = reassembler.feed(bytes).map { Self.decode($0, at: at) }
                    if frames.isEmpty { gauge.release() } else { outCont.yield(DecodedBatch(frames: frames)) }
                }
            }
            outCont.finish()
        }
    }

    deinit { input.finish() }

    /// Queues one notification. False = refused because the pipeline is full (counted in `droppedCount`).
    @discardableResult
    func submit(channel: String, bytes: [UInt8], at: Date) -> Bool {
        guard gauge.tryAdd(capacity: capacity) else { return false }
        input.yield(.data(channel: channel, bytes: bytes, at: at))
        return true
    }

    /// Forget half-received frames (the link dropped). Ordered after everything already submitted.
    func reset() { input.yield(.reset) }

    /// The main actor has applied one batch.
    func applied() { gauge.release() }

    var droppedCount: Int { gauge.droppedCount }
    var inFlight: Int { gauge.pending }

    /// The expensive per-frame work. Pure: same bytes, same result (also what the tests call directly).
    static func decode(_ frame: [UInt8], at: Date) -> DecodedFrame {
        var d = DecodedFrame(bytes: frame, at: at)
        guard frame.count > 10 else { return d }
        var verified: Bool?
        if frame[8] == 43 {
            let ok = verifyFrame(frame, family: .whoop5).ok
            d.crcOK = ok
            verified = ok
            if ok, RecordMapper.version20(frame) { d.r20 = RecordMapper.r20Record(frame, source: "live") }
        }
        if frame.count == Whoop5RawImu.bufferLength {
            let ok = verified ?? verifyFrame(frame, family: .whoop5).ok
            if ok, let imu = Whoop5RawImu.decode(frame), !imu.samples.isEmpty {
                let n = Double(imu.samples.count)
                d.motion = StrapMotionSecond(ts: Int64(imu.baseTs),
                                             gx: imu.samples.reduce(0.0) { $0 + $1.ax } / n,
                                             gy: imu.samples.reduce(0.0) { $0 + $1.ay } / n,
                                             gz: imu.samples.reduce(0.0) { $0 + $1.az } / n)
            }
        }
        return d
    }
}

/// Main-actor bookkeeping for the decode stage and the throttled raw-optical publish (one stored value on `StrapLink`).
struct LiveDecodeState {
    /// Raw-optical numbers as they accumulate frame by frame. NOT published; `publishRawOptical` copies them into the
    /// `@Published rawOptical` in one assignment, at most once per `opticalPublishInterval`.
    var optical = RawOpticalStatus()
    var opticalPublishedAt: Date?
    var opticalTrailing: Task<Void, Never>?
    /// How many times `rawOptical` actually changed (tests read this; Combine is not available on the Linux harness).
    var opticalPublishes = 0
    /// CRC-bad type-43 frames on this app run (counted and logged; they are not decoded).
    var crcBadFrames = 0
    var droppedLogged = 0
    static let opticalPublishInterval: TimeInterval = 1
}
