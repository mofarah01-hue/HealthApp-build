import AVFoundation
import Foundation
import MGDomain
import SoundAnalysis

// NightSoundsListener (WP-26): AVAudioEngine microphone tap -> SNAudioStreamAnalyzer with Apple's built-in sound
// classifier (SNClassifySoundRequest, classifierIdentifier .version1, ALG-024) -> NightSoundsPipeline -> `audio` events.
//
// Follows Apple's sample "Classifying Sounds in an Audio Stream": install a tap on the input node, hand each buffer to
// the analyzer from a serial queue (never the audio thread), read SNClassificationResult in a SNResultsObserving.
//
// PRIVACY: nothing here writes audio. Buffers go to the analyzer and are dropped; samples are copied into memory only
// when the pipeline asks for them (keepClips on, see NightSoundsClips.swift).
//
// THREADING: every mutable property below is confined to `workQueue`. Public entry points use `workQueue.sync`
// (so never call them from inside a callback of this class); callbacks (tap, observer, notifications) only ever use
// `workQueue.async`.
//
// BACKGROUND (UNVERIFIED ON DEVICE - risk 1 in the WP-26 report): UIBackgroundModes already has `audio`. iOS
// normally lets an app KEEP recording once the session is active, but may refuse to START a microphone session from
// the background (AVAudioSession error 561145187, "!rec"). `start()` therefore reports the failure; the controller
// retries when the app next becomes active and says "Open the app to start listening" in the Tonight toggle.
//
// API names (AVAudioApplication, SNClassifySoundRequest.knownClassifications) are written from memory of the iOS 17
// SDK. WRITTEN, NOT COMPILED.

enum NightSoundsError: Error, Equatable, CustomStringConvertible {
    case microphoneNotGranted
    case noInputAvailable
    case audioSession(String)
    case engine(String)
    case analysis(String)

    var description: String {
        switch self {
        case .microphoneNotGranted: return "microphone access is off"
        case .noInputAvailable: return "no microphone input"
        case .audioSession(let m): return "audio session: \(m)"
        case .engine(let m): return "audio engine: \(m)"
        case .analysis(let m): return "sound analysis: \(m)"
        }
    }
}

enum NightSoundsListenerStatus: Equatable, Sendable {
    case running
    /// Phone call, Siri, alarm...: paused, will resume by itself when iOS allows.
    case interrupted
    case stopped
    case failed(String)
}

/// The seam the controller drives (a fake in tests).
protocol NightSoundsListening: AnyObject {
    var onEvent: (@Sendable (EventRecord) -> Void)? { get set }
    var onStatus: (@Sendable (NightSoundsListenerStatus) -> Void)? { get set }
    /// True while the engine is actually running (false while interrupted).
    var isRunning: Bool { get }
    /// Which of our labels exist on this device's classifier; nil until the first successful start.
    var labelCoverage: NightSoundLabelCoverage? { get }
    /// "Make sure it is running": idempotent; also re-starts after an interruption that did not resume.
    func start() throws
    /// Flushes open episodes into events, then stops the engine and releases the audio session.
    func stop()
}

enum NightSoundsPermissionCheck {
    static func current() -> NightSoundsPermission {
        let p = AVAudioApplication.shared.recordPermission
        if p == .granted { return .granted }
        if p == .denied { return .denied }
        return .undetermined
    }

    /// Shows the system prompt the first time (the app must be in the foreground).
    static func request() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in c.resume(returning: granted) }
        }
    }
}

final class NightSoundsListener: NightSoundsListening, @unchecked Sendable {
    var onEvent: (@Sendable (EventRecord) -> Void)?
    var onStatus: (@Sendable (NightSoundsListenerStatus) -> Void)?

    private let config: NightSoundsConfig
    private let clock: MGDomain.Clock
    private let clipStore: NightSoundsClipStore?
    private let workQueue = DispatchQueue(label: "app.mg.nightsounds.work", qos: .utility)

    // Confined to workQueue.
    private var pipeline: NightSoundsPipeline?
    private var engine: AVAudioEngine?
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: NightSoundsResultsObserver?
    private var wantRunning = false
    /// Bumped on every engine (re)start, so a straggling result of an old analyzer can't be timed against a new anchor.
    private var runID = 0
    private var framesSeen: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var anchorDate: Date?
    private var tokens: [NSObjectProtocol] = []
    private var coverage: NightSoundLabelCoverage?

    init(config: NightSoundsConfig = NightSoundsConfig(), clock: MGDomain.Clock = SystemClock(),
         clipStore: NightSoundsClipStore? = nil) {
        self.config = config
        self.clock = clock
        // keepClips needs a store; with none, nothing is ever copied out of the analyser.
        self.clipStore = clipStore
    }

    var isRunning: Bool { workQueue.sync { engine?.isRunning ?? false } }
    var labelCoverage: NightSoundLabelCoverage? { workQueue.sync { coverage } }

    // MARK: Start / stop

    func start() throws {
        try workQueue.sync {
            wantRunning = true
            if engine != nil { return }
            guard NightSoundsPermissionCheck.current() == .granted else {
                wantRunning = false
                throw NightSoundsError.microphoneNotGranted
            }
            if pipeline == nil {
                pipeline = NightSoundsPipeline(config: config, clock: clock, clipStore: clipStore) { [weak self] event in
                    self?.onEvent?(event)
                }
            }
            do {
                try startAudioLocked()
            } catch {
                wantRunning = false
                throw error
            }
            installObserversLocked()
            onStatus?(.running)
        }
    }

    func stop() {
        workQueue.sync {
            wantRunning = false
            removeObserversLocked()
            teardownAudioLocked()
            pipeline?.flush()
            pipeline = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            onStatus?(.stopped)
        }
    }

    // MARK: Audio chain (workQueue only)

    private func startAudioLocked() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // playAndRecord + mixWithOthers: white noise / a podcast keep playing. No allowBluetooth: a night with
            // earbuds in must not move the input to their microphone. Nothing is played by this app.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
            try session.setActive(true)
        } catch {
            throw NightSoundsError.audioSession(error.localizedDescription)
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NightSoundsError.noInputAvailable }

        let request: SNClassifySoundRequest
        do {
            request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        } catch {
            throw NightSoundsError.analysis(error.localizedDescription)
        }
        request.overlapFactor = config.overlapFactor
        coverage = config.labelMap.coverage(known: request.knownClassifications)

        runID += 1
        let run = runID
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = NightSoundsResultsObserver(candidates: config.labelMap.candidateLabels,
                                                  onWindow: { [weak self] start, duration, scores in
            self?.workQueue.async {
                guard self?.runID == run else { return }
                self?.ingestWindowLocked(start: start, duration: duration, scores: scores)
            }
        }, onFailure: { [weak self] error in
            self?.workQueue.async {
                guard self?.runID == run else { return }
                self?.handleFailureLocked(error)
            }
        })
        do {
            try analyzer.add(request, withObserver: observer)
        } catch {
            throw NightSoundsError.analysis(error.localizedDescription)
        }

        framesSeen = 0
        anchorDate = nil
        sampleRate = format.sampleRate
        pipeline?.audioClockRestarted()

        input.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, _ in
            // Audio thread: hand off at once.
            self?.workQueue.async { self?.processBufferLocked(buffer) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw NightSoundsError.engine(error.localizedDescription)
        }
        self.engine = engine
        self.analyzer = analyzer
        self.observer = observer
    }

    /// Stops the engine and analyzer; episodes still open are closed into events first.
    private func teardownAudioLocked() {
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        analyzer?.completeAnalysis()
        analyzer?.removeAllRequests()
        analyzer = nil
        observer = nil
        engine = nil
        pipeline?.flush()
    }

    private func processBufferLocked(_ buffer: AVAudioPCMBuffer) {
        guard let analyzer = analyzer, sampleRate > 0 else { return }
        let frames = AVAudioFramePosition(buffer.frameLength)
        guard frames > 0 else { return }
        if anchorDate == nil {
            // First buffer of this run: its last sample is "now".
            anchorDate = clock.now.addingTimeInterval(-Double(frames) / sampleRate)
        }
        let position = framesSeen
        framesSeen += frames
        analyzer.analyze(buffer, atAudioFramePosition: position)

        if let pipeline = pipeline, pipeline.wantsAudio, let anchor = anchorDate,
           let channel = buffer.floatChannelData?[0] {
            let first = anchor.addingTimeInterval(Double(position) / sampleRate)
            pipeline.appendAudio(UnsafeBufferPointer<Float>(start: UnsafePointer(channel), count: Int(buffer.frameLength)),
                                 sampleRate: sampleRate, firstSampleAt: first)
        }
    }

    private func ingestWindowLocked(start: TimeInterval, duration: TimeInterval, scores: [String: Double]) {
        guard let anchor = anchorDate, let pipeline = pipeline, start.isFinite, duration.isFinite else { return }
        pipeline.ingest(start: anchor.addingTimeInterval(start),
                        end: anchor.addingTimeInterval(start + duration), raw: scores)
    }

    private func handleFailureLocked(_ error: Error) {
        guard engine != nil else { return }
        teardownAudioLocked()
        onStatus?(.failed(String(describing: NightSoundsError.analysis(error.localizedDescription))))
    }

    // MARK: Interruptions, route changes (workQueue only)

    private func installObserversLocked() {
        removeObserversLocked()
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) {
            [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            self?.workQueue.async {
                switch type {
                case .began:
                    self?.pauseLocked()
                case .ended:
                    if shouldResume { self?.resumeLocked() }
                @unknown default:
                    break
                }
            }
        })
        tokens.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) {
            [weak self] _ in
            self?.workQueue.async { self?.restartLocked() }
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) {
            [weak self] _ in
            self?.workQueue.async { self?.restartLocked() }
        })
    }

    private func removeObserversLocked() {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        tokens = []
    }

    private func pauseLocked() {
        guard wantRunning, engine != nil else { return }
        teardownAudioLocked()
        onStatus?(.interrupted)
    }

    private func resumeLocked() {
        guard wantRunning, engine == nil else { return }
        do {
            try startAudioLocked()
            onStatus?(.running)
        } catch {
            onStatus?(.failed(String(describing: error)))
        }
    }

    private func restartLocked() {
        guard wantRunning else { return }
        if engine != nil { teardownAudioLocked() }
        resumeLocked()
    }
}

/// SoundAnalysis delivers results on its own queue; this keeps only the labels we look at and the window times.
private final class NightSoundsResultsObserver: NSObject, SNResultsObserving {
    private let candidates: Set<String>
    private let onWindow: (TimeInterval, TimeInterval, [String: Double]) -> Void
    private let onFailure: (Error) -> Void

    init(candidates: Set<String>,
         onWindow: @escaping (TimeInterval, TimeInterval, [String: Double]) -> Void,
         onFailure: @escaping (Error) -> Void) {
        self.candidates = candidates
        self.onWindow = onWindow
        self.onFailure = onFailure
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        var scores: [String: Double] = [:]
        for c in result.classifications {
            let id = NightSoundLabelMap.normalise(c.identifier)
            if candidates.contains(id) { scores[id] = c.confidence }
        }
        // timeRange is in the analyzer's frame positions over the sample rate, i.e. seconds since our position 0.
        onWindow(result.timeRange.start.seconds, result.timeRange.duration.seconds, scores)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onFailure(error)
    }

    func requestDidComplete(_ request: SNRequest) {}
}
