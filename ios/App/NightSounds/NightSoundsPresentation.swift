import Foundation
import MGContext
import MGDomain

// Pure helpers WP-23's presenters use to show night sounds (WP-26): the Tonight "Listen tonight" ToggleState, the
// Night "Sounds" lane (UX 8.2) and the counts (APP-043: "cough, snore counts"). They read events and session times
// and build MGContext value types; they touch no audio.
//
// WRITTEN, NOT COMPILED.

enum NightSoundsFormat {
    /// "9:24 PM" in the calendar's time zone (12-hour, MGDomain ClockText; W10 — it was 24-hour "HH:mm").
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        ClockText.hm(date, timeZone: calendar.timeZone)
    }
}

extension NightSoundsStatus {
    /// One plain sentence for the Tonight toggle's detail line.
    func sentence(calendar: Calendar = .current) -> String {
        switch self {
        case .off: return "Off"
        case .waiting(let until): return "Starts at \(NightSoundsFormat.clock(until, calendar: calendar))"
        case .listening(let since): return "Listening since \(NightSoundsFormat.clock(since, calendar: calendar))"
        case .pausedAwake(let since):
            return "Paused: strap says awake since \(NightSoundsFormat.clock(since, calendar: calendar))"
        case .needsMicrophone: return "Microphone access is off"
        case .needsForeground: return "Open the app to start listening"
        case .lowBattery: return "Stopped: phone battery low"
        case .finished: return "Done for tonight"
        case .failed(let message): return "Couldn't listen: \(message)"
        }
    }
}

enum NightSoundsToggleFactory {
    static let id = "ns"
    static let title = "Listen tonight"

    /// True only when the device's classifier is KNOWN to have a groan-type label (coverage comes from the first
    /// start; before that it is unknown, and Apple's built-in list is believed to have none - see NightSoundLabelMap).
    static func groanAvailable(_ coverage: NightSoundLabelCoverage?) -> Bool {
        guard let c = coverage else { return false }
        return c.present[.groanLike] != nil
    }

    /// Groan-like is research (no validated detector); the row never promises it unless the labels exist.
    static func idleDetail(coverage: NightSoundLabelCoverage?) -> String {
        let what = groanAvailable(coverage) ? "cough, snore, sigh, groan (research)" : "cough, snore, sigh"
        return "\(what) · audio stays on the phone"
    }

    /// One plain line for Settings › Research / the Night lane caption; nil when groan labels exist.
    static func groanNote(coverage: NightSoundLabelCoverage?) -> String? {
        if groanAvailable(coverage) { return nil }
        return "Groan-like sounds: Apple's built-in classifier has no groan label, so none are logged until a personal classifier is trained (ALG-024)."
    }

    /// `intent` carries the NEW value (BRIEF toggle rule). A denied microphone disables the row with its reason:
    /// iOS never asks twice, so a tap could do nothing.
    static func toggle(isOn: Bool, status: NightSoundsStatus, permission: NightSoundsPermission,
                       coverage: NightSoundLabelCoverage? = nil, calendar: Calendar = .current) -> ToggleState {
        let denied = permission == .denied
        let detail = isOn ? "\(status.sentence(calendar: calendar)) · audio stays on the phone"
                          : idleDetail(coverage: coverage)
        return ToggleState(
            id: id, title: title, detail: detail, isOn: isOn,
            enabled: !denied || isOn,
            disabledReason: denied && !isOn ? "Microphone access is off. Turn it on in iOS Settings › MG › Microphone." : nil,
            intent: .setNightSounds(!isOn))
    }
}

struct NightSoundsCounts: Equatable, Sendable {
    /// Cough BOUTS (coughs closer than a couple of seconds merge), not single coughs.
    var cough = 0
    var snoreBouts = 0
    var snoreSeconds: TimeInterval = 0
    /// RESEARCH.
    var groanLike = 0
    var sigh = 0
    var breathingSounds = 0

    init() {}
}

enum NightSoundsSummary {
    static func counts(events: [EventRecord]) -> NightSoundsCounts {
        var c = NightSoundsCounts()
        for e in events where !e.removed {
            guard case .audio(let f) = e.payload else { continue }
            switch f.kind {
            case .cough: c.cough += 1
            case .snore:
                c.snoreBouts += 1
                c.snoreSeconds += max(0, f.end.timeIntervalSince(e.at))
            case .groan: c.groanLike += 1
            case .sigh: c.sigh += 1
            case .other: c.breathingSounds += 1
            case .breathHold: break
            }
        }
        return c
    }
}

/// The Night screen's "Sounds" lane (id "sounds", UX 8.2).
enum NightSoundsLane {
    static let id = "sounds"
    static let title = "Sounds"
    static let notListeningReason = "Not listening last night — switch on in Tonight"

    static func label(for fields: AudioFields) -> String {
        switch fields.kind {
        case .cough: return "cough"
        case .snore: return "snore"
        case .sigh: return "sigh"
        case .groan: return NightSoundsDetector.isResearch(detector: fields.detector) ? "groan (research)" : "groan"
        case .breathHold: return "breath-hold"
        case .other: return "breathing sound"
        }
    }

    /// `from`...`to` is the night. No session in it -> blank with the "not listening" reason; sessions but no events ->
    /// blank with "Listened HH:mm–HH:mm, nothing heard".
    static func make(events: [EventRecord], sessions: [NightSoundsSession], from: Date, to: Date,
                     calendar: Calendar = .current) -> NightLane {
        let listened = sessions.filter { $0.overlaps(from: from, to: to) }
        guard !listened.isEmpty else {
            return NightLane(id: id, title: title, marks: [], blankReason: notListeningReason)
        }
        var marks: [LaneMark] = []
        for e in events where !e.removed && e.at >= from && e.at < to {
            guard case .audio(let f) = e.payload else { continue }
            marks.append(LaneMark(at: e.at, end: f.end, value: nil, label: label(for: f)))
        }
        marks.sort { $0.at < $1.at }
        guard marks.isEmpty else { return NightLane(id: id, title: title, marks: marks, blankReason: nil) }
        let first = max(listened.map { $0.start }.min() ?? from, from)
        let last = min(listened.map { $0.effectiveEnd }.max() ?? to, to)
        let reason = "Listened \(NightSoundsFormat.clock(first, calendar: calendar))–"
            + "\(NightSoundsFormat.clock(last, calendar: calendar)), nothing heard."
        return NightLane(id: id, title: title, marks: [], blankReason: reason)
    }
}
