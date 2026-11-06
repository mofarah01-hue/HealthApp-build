import Foundation
import MGDomain

// Night sounds (WP-26): cough / snore / sigh / breathing-related / groan-like events heard by the iPhone microphone.
// Sources: APP-043, ALG-024 (Apple SoundAnalysis as the detector; its label list "gets read on the device"),
// ALG-025 (a groan only counts as catathrenia-LIKE with a strap breathing pause + steady SpO2), PLAN 4.10 and 8.
//
// PRIVACY (PLAN 8, BRIEF "Hard rules"): audio is processed on the phone and never synced. Others in the room get
// recorded too, so only labels are kept: this package emits `audio` events (labels, start, end, confidence) and nothing
// else. Audio touches the disk only when `NightSoundsConfig.keepClips` is true (default false) and then only through
// NightSoundsClipStore, which writes to a folder that is excluded from backup and is never referenced by an event
// (no `attachments`), so the sync export cannot see it.
//
// This file is pure Foundation + MGDomain (no AVFoundation, no SoundAnalysis) so the same logic is mirrored line for
// line in the Python check (scratchpad wp26) and unit-tested without a microphone.
//
// WRITTEN, NOT COMPILED (BRIEF decision 4).

/// What a window of audio sounded like, after mapping Apple's labels.
enum NightSoundClass: String, CaseIterable, Sendable {
    case cough = "cough"
    case snore = "snore"
    case sigh = "sigh"
    /// RESEARCH: Apple's general classifier is the only evidence; no validated groan / catathrenia detector exists
    /// (ALG-024). Never a diagnosis (ALG-025).
    case groanLike = "groan_like"
    /// Breathing-related one-offs (gasp, pant, wheeze). Emitted as contract kind `other` (the contract has no
    /// breathing kind); the Apple label is kept in the event note.
    case breathingEvent = "breathing_event"
    /// Ordinary breathing. Context only: a whole night of it would be an event flood, so it is never emitted.
    case breathing = "breathing"
    /// Everything else Apple can hear (speech, TV, traffic, throat clearing...). Never emitted.
    case other = "other"

    /// Sustained sounds compete inside one window (winner takes all, see NightSoundsDebouncer); transient ones don't.
    var isSustained: Bool {
        switch self {
        case .snore, .groanLike, .breathingEvent: return true
        case .cough, .sigh, .breathing, .other: return false
        }
    }

    var emitsEvents: Bool {
        switch self {
        case .cough, .snore, .sigh, .groanLike, .breathingEvent: return true
        case .breathing, .other: return false
        }
    }

    var isResearch: Bool { self == .groanLike }

    /// Contract `audioEvent.kind` (MGDomain `AudioFields.Kind`).
    var kind: AudioFields.Kind? {
        switch self {
        case .cough: return .cough
        case .snore: return .snore
        case .sigh: return .sigh
        case .groanLike: return .groan
        case .breathingEvent: return .other
        case .breathing, .other: return nil
        }
    }
}

struct NightSoundClassScore: Equatable, Sendable {
    /// 0...1, the highest confidence among the class's Apple labels in this window.
    var confidence: Double
    /// The Apple label that gave it (normalised), kept in the event note.
    var label: String
}

/// What the device's classifier can actually recognise, so the UI can say "no groan label on this iOS".
struct NightSoundLabelCoverage: Equatable, Sendable {
    /// Per class: which of our candidate labels exist in `SNClassifySoundRequest.knownClassifications`.
    var present: [NightSoundClass: [String]]
    /// Emitting classes with no label on this device: they can never fire.
    var missing: [NightSoundClass]
    var knownCount: Int
}

/// Apple label -> class (ALG-024).
///
/// WHAT THE DEVICE CAN HEAR (checked 2026-10-11 against a third-party listing of the 303 `.version1` identifiers,
/// zenn.dev/shu223/articles/soundanalysis-builtin - NOT Apple's own page, and not yet read on the device):
///   present  cough, snoring, gasp, sigh, breathing (also sneeze, hiccup, burp, crying_sobbing: not mapped)
///   absent   groan, grunt, moan, pant, wheeze, throat_clearing, sniff
/// So with the built-in classifier the groan-like class CANNOT fire and "breathing event" is gasp only. The
/// candidates for those classes stay listed so a personal / newer classifier (ALG-024 "small personal classifier")
/// that does have them works unchanged, and `coverage(known:)` tells the UI the truth on the device: first-run
/// `SNClassifySoundRequest.knownClassifications` decides, not this comment. A label that exists but isn't listed
/// here is treated as `other` (silently ignored).
struct NightSoundLabelMap: Sendable {
    var labels: [NightSoundClass: [String]]

    static let `default` = NightSoundLabelMap(labels: [
        .cough: ["cough"],
        .snore: ["snoring", "snore"],
        .sigh: ["sigh"],
        .groanLike: ["groan", "grunt", "moan", "wail_moan"],
        .breathingEvent: ["gasp", "pant", "wheeze"],
        .breathing: ["breathing"],
    ])

    /// Lowercase, spaces and hyphens -> underscore. Apple's identifiers are already in this form; this only guards
    /// against a future OS changing the style.
    static func normalise(_ label: String) -> String {
        label.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
    }

    /// Every label we look at; the observer keeps only these (about 12 of ~300), the rest are dropped at once.
    var candidateLabels: Set<String> {
        var s = Set<String>()
        for list in labels.values { for l in list { s.insert(NightSoundLabelMap.normalise(l)) } }
        return s
    }

    /// Per class, the highest confidence among its labels in this window (ties: the label listed first).
    /// Classes with no label in `raw` are absent. Non-finite confidences are ignored; the rest are clamped to 0...1.
    func classScores(_ raw: [String: Double]) -> [NightSoundClass: NightSoundClassScore] {
        var normalised: [String: Double] = [:]
        for (k, v) in raw where v.isFinite {
            let key = NightSoundLabelMap.normalise(k)
            let c = min(max(v, 0), 1)
            normalised[key] = max(normalised[key] ?? 0, c)
        }
        var out: [NightSoundClass: NightSoundClassScore] = [:]
        for cls in NightSoundClass.allCases {
            guard let list = labels[cls] else { continue }
            var best: NightSoundClassScore?
            for l in list {
                let key = NightSoundLabelMap.normalise(l)
                guard let c = normalised[key] else { continue }
                if best == nil || c > best!.confidence { best = NightSoundClassScore(confidence: c, label: key) }
            }
            if let b = best { out[cls] = b }
        }
        return out
    }

    func coverage(known: [String]) -> NightSoundLabelCoverage {
        let knownSet = Set(known.map(NightSoundLabelMap.normalise))
        var present: [NightSoundClass: [String]] = [:]
        var missing: [NightSoundClass] = []
        for cls in NightSoundClass.allCases {
            guard let list = labels[cls] else { continue }
            let found = list.map(NightSoundLabelMap.normalise).filter { knownSet.contains($0) }
            if !found.isEmpty { present[cls] = found } else if cls.emitsEvents { missing.append(cls) }
        }
        return NightSoundLabelCoverage(present: present, missing: missing, knownCount: knownSet.count)
    }
}

/// Hysteresis + de-bounce numbers for one class. PLACEHOLDER: chosen without on-device tuning; tune against real
/// nights (the Night lane and the kept clips exist for exactly that).
struct NightSoundThreshold: Equatable, Sendable {
    /// A window at or above this opens an episode.
    var on: Double
    /// While an episode is open, a window at or above this keeps it open (hysteresis: off < on).
    var off: Double
    /// Windows needed before an episode counts (windows overlap 50 %, so 3 hits is roughly 3 s of sound).
    var minHits: Int
    /// Silence at least this long ends an episode; a hit after it starts a new one.
    var mergeGapSeconds: Double
    /// An episode that reaches this length is cut and a new one starts, so a crash loses at most this much.
    var maxEpisodeSeconds: Double
}

struct NightSoundsConfig: Sendable {
    /// PLACEHOLDER numbers (see NightSoundThreshold). Counts are BOUTS, not single coughs: coughs less than
    /// `mergeGapSeconds` apart merge into one event, and overlapping analysis windows cannot count single coughs.
    var thresholds: [NightSoundClass: NightSoundThreshold] = [
        .cough: NightSoundThreshold(on: 0.60, off: 0.40, minHits: 1, mergeGapSeconds: 2, maxEpisodeSeconds: 60),
        .snore: NightSoundThreshold(on: 0.50, off: 0.30, minHits: 3, mergeGapSeconds: 15, maxEpisodeSeconds: 600),
        .sigh: NightSoundThreshold(on: 0.60, off: 0.40, minHits: 1, mergeGapSeconds: 2, maxEpisodeSeconds: 10),
        .groanLike: NightSoundThreshold(on: 0.50, off: 0.30, minHits: 2, mergeGapSeconds: 3, maxEpisodeSeconds: 60),
        .breathingEvent: NightSoundThreshold(on: 0.70, off: 0.50, minHits: 1, mergeGapSeconds: 2, maxEpisodeSeconds: 30),
    ]
    /// SNClassifySoundRequest.overlapFactor (0..<1); 0.5 is Apple's default.
    var overlapFactor: Double = 0.5
    var labelMap: NightSoundLabelMap = .default

    /// "Keep clips" switch. DEFAULT OFF. Off means audio is never copied out of the analyser and never written.
    var keepClips: Bool = false
    var clipPreRollSeconds: Double = 1.5
    var clipPostRollSeconds: Double = 0.5
    var clipMaxSeconds: Double = 15
    /// Seconds of audio held in memory while `keepClips` is on (long enough for an episode plus its merge gap).
    var clipRingSeconds: Double = 60
    /// Disk guard: at most this many clips per listening session.
    var maxClipsPerSession: Int = 40
}

/// Strings written into `AudioFields.detector` (contract example: "apple-soundanalysis@1, personal-groan@2").
enum NightSoundsDetector {
    static let apple = "apple-soundanalysis@1"
    /// Groan-like events: same classifier, but flagged. Anything reading events checks `isResearch(detector:)`.
    static let appleResearch = "apple-soundanalysis@1+research"

    static func isResearch(detector: String?) -> Bool { detector?.hasSuffix("+research") == true }
}
