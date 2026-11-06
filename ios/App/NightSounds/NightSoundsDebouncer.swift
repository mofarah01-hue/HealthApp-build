import Foundation
import MGDomain

// De-bounce + event construction for night sounds (WP-26, ALG-024). Pure Foundation + MGDomain: no audio, no clock,
// no threads. The Python mirror in the WP-26 scratchpad follows this file statement for statement.
//
// WRITTEN, NOT COMPILED.

/// One sound episode: consecutive analysis windows that scored for the same class.
struct NightSoundEpisode: Equatable, Sendable {
    var cls: NightSoundClass
    /// Start of the first window that scored. Resolution is one analysis window (about 1.5 s), not the exact sound.
    var start: Date
    /// End of the last window that scored.
    var end: Date
    /// Highest confidence over the episode's windows (becomes `AudioFields.confidence`).
    var peak: Double
    /// Apple label of the highest-confidence window.
    var label: String
    var hits: Int
}

/// Turns a stream of classifier windows into episodes.
///
/// Per window: (1) episodes whose silence reached `mergeGapSeconds` before this window began are closed;
/// (2) each class either scores a hit or not: a closed class needs `on`, an open one only `off` (hysteresis);
/// transient classes (cough, sigh) are independent, sustained ones (snore, groan-like, breathing event) compete and
/// only the highest-scoring one counts (a snore also scores a little as a groan; without this every snore bout would
/// double-count as a groan); (3) hits open or extend episodes; an episode that would pass `maxEpisodeSeconds` is cut.
/// An episode is emitted when it closes, if it collected at least `minHits` windows.
struct NightSoundsDebouncer {
    private struct Open {
        var start: Date
        var lastHitEnd: Date
        var peak: Double
        var peakLabel: String
        var hits: Int
    }

    private let thresholds: [NightSoundClass: NightSoundThreshold]
    private var openByClass: [NightSoundClass: Open] = [:]
    private(set) var lastWindowEnd: Date?

    init(thresholds: [NightSoundClass: NightSoundThreshold]) {
        self.thresholds = thresholds
    }

    /// True while any class has an episode open.
    var hasOpenEpisode: Bool { !openByClass.isEmpty }

    mutating func ingest(start: Date, end: Date, scores: [NightSoundClass: NightSoundClassScore]) -> [NightSoundEpisode] {
        var out: [NightSoundEpisode] = []
        if let last = lastWindowEnd { lastWindowEnd = max(last, end) } else { lastWindowEnd = end }

        // 1. silence long enough before this window: close.
        for cls in NightSoundClass.allCases {
            guard let th = thresholds[cls], let o = openByClass[cls] else { continue }
            if start.timeIntervalSince(o.lastHitEnd) >= th.mergeGapSeconds {
                if let ep = finish(cls, o) { out.append(ep) }
                openByClass[cls] = nil
            }
        }

        // 2. which classes score a hit in this window.
        let hits = hitClasses(scores)

        // 3. open / extend / cut.
        for cls in NightSoundClass.allCases {
            guard let th = thresholds[cls], hits.contains(cls), let score = scores[cls] else { continue }
            if var o = openByClass[cls] {
                if end.timeIntervalSince(o.start) > th.maxEpisodeSeconds {
                    if let ep = finish(cls, o) { out.append(ep) }
                    openByClass[cls] = Open(start: start, lastHitEnd: end, peak: score.confidence,
                                     peakLabel: score.label, hits: 1)
                } else {
                    o.lastHitEnd = max(o.lastHitEnd, end)
                    o.hits += 1
                    if score.confidence > o.peak {
                        o.peak = score.confidence
                        o.peakLabel = score.label
                    }
                    openByClass[cls] = o
                }
            } else {
                openByClass[cls] = Open(start: start, lastHitEnd: end, peak: score.confidence,
                                 peakLabel: score.label, hits: 1)
            }
        }
        return sorted(out)
    }

    /// Closes every open episode (listening stopped, interrupted or the route changed).
    mutating func flush() -> [NightSoundEpisode] {
        var out: [NightSoundEpisode] = []
        for cls in NightSoundClass.allCases {
            guard let o = openByClass[cls] else { continue }
            if let ep = finish(cls, o) { out.append(ep) }
            openByClass[cls] = nil
        }
        return sorted(out)
    }

    private func hitClasses(_ scores: [NightSoundClass: NightSoundClassScore]) -> Set<NightSoundClass> {
        var hits = Set<NightSoundClass>()
        // Transient classes: independent.
        for cls in [NightSoundClass.cough, NightSoundClass.sigh] {
            if let s = scores[cls], isHit(cls, s) { hits.insert(cls) }
        }
        // Sustained classes: the highest confidence among those that pass their own threshold wins; a tie goes to
        // the earlier one in this priority order.
        var best: (cls: NightSoundClass, confidence: Double)?
        for cls in [NightSoundClass.snore, NightSoundClass.groanLike, NightSoundClass.breathingEvent] {
            guard let s = scores[cls], isHit(cls, s) else { continue }
            if best == nil || s.confidence > best!.confidence { best = (cls, s.confidence) }
        }
        if let b = best { hits.insert(b.cls) }
        return hits
    }

    private func isHit(_ cls: NightSoundClass, _ score: NightSoundClassScore) -> Bool {
        guard let th = thresholds[cls] else { return false }
        let needed = openByClass[cls] != nil ? th.off : th.on
        return score.confidence >= needed
    }

    private func finish(_ cls: NightSoundClass, _ o: Open) -> NightSoundEpisode? {
        guard let th = thresholds[cls], o.hits >= th.minHits else { return nil }
        return NightSoundEpisode(cls: cls, start: o.start, end: o.lastHitEnd, peak: o.peak, label: o.peakLabel, hits: o.hits)
    }

    private func sorted(_ eps: [NightSoundEpisode]) -> [NightSoundEpisode] {
        let order = NightSoundClass.allCases
        return eps.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            return (order.firstIndex(of: a.cls) ?? 0) < (order.firstIndex(of: b.cls) ?? 0)
        }
    }
}

/// Episode -> contract `audio` event (APP-043; contract `audioEvent`: kind, end, confidence, detector,
/// strap_corroboration). `at` is the start; no audio and no file path ever goes into an event.
enum NightSoundsEventFactory {
    static let origin = Origin(app: "MG", device: "iPhone")

    /// nil for classes that never emit (ordinary breathing, other).
    static func event(for ep: NightSoundEpisode, loggedAt: Date, strapCorroboration: String? = nil) -> EventRecord? {
        guard ep.cls.emitsEvents, let kind = ep.cls.kind else { return nil }
        let research = ep.cls.isResearch
        let note = research
            ? "RESEARCH: groan-like sound from Apple's general classifier (label: \(ep.label)); not a validated detector"
            : "label: \(ep.label)"
        let fields = AudioFields(
            kind: kind,
            end: ep.end,
            confidence: min(max(ep.peak, 0), 1),
            detector: research ? NightSoundsDetector.appleResearch : NightSoundsDetector.apple,
            strapCorroboration: strapCorroboration)
        return EventRecord(type: .audio, at: ep.start, loggedAt: loggedAt, source: .detected, origin: origin,
                           note: note, payload: .audio(fields))
    }
}
