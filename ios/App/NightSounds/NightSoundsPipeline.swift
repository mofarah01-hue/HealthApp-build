import Foundation
import MGDomain

// Classifier windows -> episodes -> `audio` events (+ optional clips). No audio framework here: the listener hands in
// plain numbers, so the whole chain runs in unit tests without a microphone. Not thread-safe: the owner
// (NightSoundsListener) confines it to one serial queue.
//
// WRITTEN, NOT COMPILED.

final class NightSoundsPipeline {
    private let config: NightSoundsConfig
    private let clock: MGDomain.Clock
    private let clipStore: NightSoundsClipStore?
    private let emit: (EventRecord) -> Void
    private var debouncer: NightSoundsDebouncer
    /// Exists only when keepClips is on AND a clip store was given. nil = no audio is ever copied out of the analyser.
    private var ring: NightSoundsRingBuffer?

    private(set) var windowsSeen = 0
    private(set) var eventsEmitted = 0
    private(set) var clipsSaved = 0
    private(set) var lastClipError: String?

    init(config: NightSoundsConfig, clock: MGDomain.Clock, clipStore: NightSoundsClipStore?,
         emit: @escaping (EventRecord) -> Void) {
        self.config = config
        self.clock = clock
        self.clipStore = clipStore
        self.emit = emit
        self.debouncer = NightSoundsDebouncer(thresholds: config.thresholds)
        if config.keepClips && clipStore != nil {
            self.ring = NightSoundsRingBuffer(capacitySeconds: config.clipRingSeconds)
        }
    }

    /// True when raw samples are being copied into memory for clips (keepClips on). The listener checks this before
    /// touching the audio buffer at all.
    var wantsAudio: Bool { ring != nil }

    /// One classifier window. `raw` = Apple label -> confidence (any subset of the labels; unknown labels are ignored).
    func ingest(start: Date, end: Date, raw: [String: Double]) {
        windowsSeen += 1
        let scores = config.labelMap.classScores(raw)
        for ep in debouncer.ingest(start: start, end: end, scores: scores) { handle(ep) }
    }

    func appendAudio(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, firstSampleAt: Date) {
        guard ring != nil else { return }
        ring!.append(samples, sampleRate: sampleRate, firstSampleAt: firstSampleAt)
    }

    /// Close every open episode (stop, interruption, route change).
    func flush() {
        for ep in debouncer.flush() { handle(ep) }
    }

    /// After an engine restart the sample clock starts over.
    func audioClockRestarted() {
        ring?.reset()
    }

    private func handle(_ ep: NightSoundEpisode) {
        guard let event = NightSoundsEventFactory.event(for: ep, loggedAt: clock.now) else { return }
        eventsEmitted += 1
        emit(event)
        saveClip(for: ep, eventID: event.id)
    }

    private func saveClip(for ep: NightSoundEpisode, eventID: UUID) {
        guard config.keepClips, let store = clipStore, ring != nil, clipsSaved < config.maxClipsPerSession else { return }
        // Pre-roll before the start, post-roll after the end; a long episode keeps its last `clipMaxSeconds`.
        let to = ep.end.addingTimeInterval(config.clipPostRollSeconds)
        let from = max(ep.start.addingTimeInterval(-config.clipPreRollSeconds), to.addingTimeInterval(-config.clipMaxSeconds))
        guard let snap = ring!.snapshot(from: from, to: to) else { return }
        do {
            try store.save(eventID: eventID, samples: snap.samples, sampleRate: ring!.sampleRate)
            clipsSaved += 1
        } catch {
            lastClipError = String(describing: error)
        }
    }
}
