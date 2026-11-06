import AVFoundation
import Foundation

// "Keep clips" (WP-26, PLAN 4.10): short clips kept ON THE PHONE ONLY, and ONLY when the switch is on
// (`NightSoundsConfig.keepClips`, default false), so Mo can confirm what was heard.
//
// This is the only file in the package that can put audio on disk (AVAudioFile below); the WP-26 check script fails
// if another NightSounds file contains an audio-write call. Properties that keep it on the phone:
//   * the ring buffer below holds raw samples in MEMORY and exists only when keepClips is on;
//   * clips go to Application Support/NightSounds/clips (never Documents, which the Files app can share),
//     excluded from iCloud / device backup, file protection "until first unlock" (the phone is locked overnight, so
//     `.complete` would make the write fail);
//   * the event never references the clip (no `attachments`, no path), so the sync export - which is built from the
//     store's events and streams - cannot include it. The Night screen finds a clip by event id through
//     `NightSoundsFileClipStore.clipURL(for:)`.
//
// WRITTEN, NOT COMPILED.

/// Mono Float32 ring buffer in memory. Samples are addressed by wall-clock time through one origin date that is reset
/// when the sample rate changes or a gap longer than half a second appears (engine restart).
struct NightSoundsRingBuffer {
    let capacitySeconds: Double
    private(set) var sampleRate: Double = 0
    private var storage: [Float] = []
    private var capacity = 0
    private var total = 0
    private var origin: Date?

    init(capacitySeconds: Double) {
        self.capacitySeconds = capacitySeconds
    }

    var isEmpty: Bool { total == 0 }

    mutating func reset() {
        storage = []
        capacity = 0
        total = 0
        origin = nil
        sampleRate = 0
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>, sampleRate rate: Double, firstSampleAt: Date) {
        guard rate > 0, samples.count > 0 else { return }
        if origin == nil || rate != sampleRate {
            sampleRate = rate
            capacity = max(1, Int(rate * capacitySeconds))
            storage = [Float](repeating: 0, count: capacity)
            total = 0
            origin = firstSampleAt
        } else if let o = origin {
            let expected = o.addingTimeInterval(Double(total) / rate)
            if abs(firstSampleAt.timeIntervalSince(expected)) > 0.5 {
                total = 0
                origin = firstSampleAt
            }
        }
        for s in samples {
            storage[total % capacity] = s
            total += 1
        }
    }

    /// The samples between `from` and `to`, clipped to what the ring still holds. nil if none of it is held.
    /// `start` is the wall-clock time of the first returned sample.
    func snapshot(from: Date, to: Date) -> (samples: [Float], start: Date)? {
        guard let o = origin, sampleRate > 0, total > 0, capacity > 0 else { return nil }
        let oldest = max(total - capacity, 0)
        var i0 = Int((from.timeIntervalSince(o) * sampleRate).rounded(.down))
        var i1 = Int((to.timeIntervalSince(o) * sampleRate).rounded(.up))
        i0 = max(i0, oldest)
        i1 = min(i1, total)
        guard i1 > i0 else { return nil }
        var out: [Float] = []
        out.reserveCapacity(i1 - i0)
        for i in i0..<i1 { out.append(storage[i % capacity]) }
        return (out, o.addingTimeInterval(Double(i0) / sampleRate))
    }
}

/// Where kept clips go. Only called when `keepClips` is on.
protocol NightSoundsClipStore: Sendable {
    /// Writes one mono clip named after the event id and returns where it went (local only).
    @discardableResult
    func save(eventID: UUID, samples: [Float], sampleRate: Double) throws -> URL
}

enum NightSoundsClipError: Error {
    case cannotCreateFile
    case cannotCreateBuffer
}

/// Clips as 16-bit mono CAF files in a backup-excluded folder. Never synced (see the file header).
final class NightSoundsFileClipStore: NightSoundsClipStore, @unchecked Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Application Support/NightSounds/clips.
    static func standard() -> NightSoundsFileClipStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return NightSoundsFileClipStore(directory: base.appendingPathComponent("NightSounds", isDirectory: true)
            .appendingPathComponent("clips", isDirectory: true))
    }

    func clipURL(for eventID: UUID) -> URL? {
        let url = fileURL(for: eventID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func fileURL(for eventID: UUID) -> URL {
        directory.appendingPathComponent("\(eventID.uuidString.lowercased()).caf")
    }

    @discardableResult
    func save(eventID: UUID, samples: [Float], sampleRate: Double) throws -> URL {
        guard !samples.isEmpty, sampleRate > 0 else { throw NightSoundsClipError.cannotCreateBuffer }
        try prepareDirectory()
        let url = fileURL(for: eventID)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw NightSoundsClipError.cannotCreateFile
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw NightSoundsClipError.cannotCreateBuffer
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }
        try file.write(from: buffer)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        return url
    }

    /// Removes clips last written before `date`. Never called by this package: Settings (a user action or a retention
    /// setting Mo chooses) decides. Returns how many files were removed.
    @discardableResult
    func purge(olderThan date: Date) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return 0
        }
        var removed = 0
        for url in urls where url.pathExtension == "caf" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let m = modified, m < date, (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    private func prepareDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }
}
