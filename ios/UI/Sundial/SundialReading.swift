import Foundation
import CoreGraphics
import MGContext

// What sits where on the Sundial (UX-SPEC §3.3 layers, §10 gestures; owner WP-12):
// - (the scrub words moved to MGContext `DialScrubIndex`, round 8),
// - taps on rings, arcs and marks → the `DialTarget` whose detail sheet opens (0.6); with no sheet, the 0.5.3 tap
//   (UX §10: night arc → Night · bedtime / wake window → Tonight · workout arc → Workout ·
//   caffeine → Log › Caffeine · vape dots → Log › Vape),
// - the direct labels each layer carries on the dial (UX §1.2: never colour alone — radius, mark shape AND a label).
// Everything here only names and places what DialState already holds; it computes no metric.

/// Tap zones by radius from the centre in design units, inside → out (ui-pitch DESIGN-TOKENS §6): hub < 50 (nothing),
/// inner rings 50–92, caffeine 92–106, track 106–123.5, rim marks 123.5–152, nothing beyond.
enum SundialTapZone: CaseIterable {
    case rings, caffeine, track, rim

    var outer: CGFloat {
        switch self {
        case .rings: return SundialDesign.wellRadius
        case .caffeine: return 106
        case .track: return 123.5
        case .rim: return 152
        }
    }

    static func at(radius r: CGFloat, hub: CGFloat = SundialDesign.hubRadius) -> SundialTapZone? {
        guard r >= hub else { return nil }
        return allCases.first { r < $0.outer }
    }
}

enum SundialReading {
    // The scrub words live in MGContext's `DialScrubIndex` (one provider, one wording, one tolerance; round 8).

    // MARK: Taps (UX §10)

    /// Point marks on the face (rim marks, plan ticks, caffeine dots) count as tapped within this many seconds
    /// (36 min ≈ 44 pt of arc at the rim).
    static let tapTolerance: TimeInterval = 36 * 60

    /// What a tap at `location` lands on: the zone under the finger, then the zone one out, then one in; nil when
    /// none of them has anything at that angle (or the tap is on the hub or beyond the rim marks).
    static func tapTarget(at location: CGPoint, metrics: SundialMetrics, state: DialState,
                          index: DialScrubIndex) -> DialTarget? {
        let (hour, points) = SundialGeometry.hourAndRadius(at: location, center: metrics.center)
        let r = points / metrics.scale
        guard let zone = SundialTapZone.at(radius: r, hub: CGFloat(metrics.zone.hubRadius)),
              let i = SundialTapZone.allCases.firstIndex(of: zone) else { return nil }
        let zones = SundialTapZone.allCases
        // The hour means one date for the life of the index (no nearest-to-now guessing).
        let t = index.date(hour: hour)
        for k in [i, i + 1, i - 1] where zones.indices.contains(k) {
            if zones[k] == .rings, let ring = ringTarget(radius: r, state: state, zone: metrics.zone) { return ring }
            if let hit = target(in: zones[k], at: t, state: state) { return hit }
        }
        return nil
    }

    /// The ring whose band (centre ± step / 2) holds `r`. Within half a ring step past either end of the ring zone the
    /// end ring is taken (a fat finger); further out or in it is not a ring tap (audit #11: a tap at radius 100, where
    /// nothing is drawn, used to open Strain).
    static func ringTarget(radius r: CGFloat, state: DialState, zone: DialRingZone = .standard) -> DialTarget? {
        guard !state.rings.isEmpty else { return nil }
        let step = SundialDesign.ringStep(count: state.rings.count, zone: zone)
        let innerEdge = SundialDesign.ringZoneOuter - step * CGFloat(state.rings.count)
        guard r <= SundialDesign.ringZoneOuter + step / 2, r >= innerEdge - step / 2 else { return nil }
        let i = Int(((SundialDesign.ringZoneOuter - r) / step).rounded(.down))
        return .ring(state.rings[min(max(i, 0), state.rings.count - 1)].kind)
    }

    /// What a tap at `location` means to the magnify state machine (round 8, T10023): a ring, anything else with its
    /// own sheet (mark, arc, plan tick, caffeine curve), or nothing / the hub.
    static func tapSpot(at location: CGPoint, metrics: SundialMetrics, state: DialState,
                        index: DialScrubIndex) -> DialMagnify.Spot {
        switch tapTarget(at: location, metrics: metrics, state: state, index: index) {
        case .ring(let kind)?: return .ring(kind)
        case let target?: return .thing(target)
        case nil: return .blank
        }
    }

    /// What one time layer holds at `t`.
    static func target(in zone: SundialTapZone, at t: Date, state: DialState) -> DialTarget? {
        switch zone {
        case .rings:
            return nil
        case .caffeine:
            let near = state.caffeineCurve.contains { $0.opacity > 0.01 && abs($0.at.timeIntervalSince(t)) <= tapTolerance }
            return near ? .caffeine : nil
        case .track:
            for arc in state.arcs where arc.start <= t && t < arc.end {
                switch arc.kind {
                case .deep, .light, .rem, .awake, .unstaged: return .sleep
                case .plannedSleep: return .tonight
                case .workout: return .workout(start: arc.start)
                case .nap, .napUnconfirmed: return .nap(start: arc.start)
                case .strapOff: return .strapOff(start: arc.start)
                case .awakeElapsed: continue
                }
            }
            let ticks = state.ticks.map { ($0, distance(t, from: $0.at, to: $0.end ?? $0.at)) }
                .filter { $0.1 <= tapTolerance }
            guard let tick = ticks.min(by: { $0.1 < $1.1 })?.0 else { return nil }
            switch tick.kind {
            case .bedtime, .smartWakeWindow: return .tonight
            case .caffeineCutoff: return .caffeine
            case .wakeMarker: return .sleep
            }
        case .rim:
            let hits = state.rimEvents.map { e in
                (e, distance(t, from: e.at, to: e.kind == .caffeine ? max(e.end ?? e.at, e.at) : e.at))
            }
            guard let e = hits.filter({ $0.1 <= tapTolerance }).min(by: { $0.1 < $1.1 })?.0 else { return nil }
            return .mark(e.kind, at: e.at)
        }
    }

    /// The 0.5.3 tap for a target, used when the state has no detail sheet for it (UX §10 destinations).
    static func legacyIntent(for target: DialTarget, state: DialState) -> UIIntent? {
        switch target {
        case .ring, .nap, .strapOff: return nil
        case .mark(let kind, _): return rimIntent(kind)
        case .sleep: return .openNight(nil)
        case .tonight: return .openTonight
        case .caffeine: return .openLogItem(.caffeine)
        case .workout: return .openWorkout(id: nil)
        }
    }

    // MARK: VoiceOver actions (the dial is one element; these open the same sheets as the taps)

    static func accessibilityActions(_ state: DialState) -> [(title: String, target: DialTarget)] {
        var out: [(title: String, target: DialTarget)] = state.rings.map {
            (title: "\($0.title) details", target: DialTarget.ring($0.kind))
        }
        if state.legendItems.isEmpty {
            // Until the key has its items: one action per mark kind on the rim, opening its newest mark.
            for kind in RimEvent.Kind.allCases {
                guard let e = state.rimEvents.filter({ $0.kind == kind }).max(by: { $0.at < $1.at }) else { continue }
                out.append(("\(kindTitle(kind)) details", .mark(kind, at: e.at)))
            }
        } else {
            out += state.legendItems.map { (title: $0.text, target: $0.target) }
        }
        let stageKinds: Set<DialArc.Kind> = [.deep, .light, .rem, .awake, .unstaged]
        if state.arcs.contains(where: { stageKinds.contains($0.kind) }) { out.append(("Sleep details", .sleep)) }
        if state.nightArc == .tonight || state.ticks.contains(where: { $0.kind == .bedtime }) {
            out.append(("Tonight details", .tonight))
        }
        if !state.caffeineCurve.isEmpty || state.ticks.contains(where: { $0.kind == .caffeineCutoff }) {
            out.append(("Caffeine details", .caffeine))
        }
        if let w = state.arcs.filter({ $0.kind == .workout }).max(by: { $0.start < $1.start }) {
            out.append(("Workout details", .workout(start: w.start)))
        }
        return out
    }

    // MARK: Names

    static func kindTitle(_ kind: RimEvent.Kind) -> String {
        switch kind {
        case .vape: return "Vape"
        case .medication: return "Medication"
        case .caffeine: return "Drink"
        case .food: return "Food"
        case .supplement: return "Supplements"
        }
    }

    static func rimIntent(_ kind: RimEvent.Kind) -> UIIntent {
        switch kind {
        case .vape: return .openLogItem(.vape)
        case .medication: return .openLogItem(.medication)
        case .caffeine: return .openLogItem(.caffeine)
        case .food: return .openLogItem(.food)
        case .supplement: return .openLogItem(.supplements)
        }
    }

    /// 0 inside [start, end], else seconds to the nearer end.
    static func distance(_ t: Date, from start: Date, to end: Date) -> TimeInterval {
        if t < start { return start.timeIntervalSince(t) }
        if t > end { return t.timeIntervalSince(end) }
        return 0
    }
}

// MARK: - Direct labels (UX §1.2 "a direct label", §3.3)

/// A short label drawn on the label ring next to its layer.
struct SundialLabel: Equatable {
    let text: String
    let tone: InkTone
    let center: CGPoint
    /// Drawn on the night layer, so it turns the page with the night arc.
    let night: Bool
}

enum SundialLabels {
    /// Design units per character of the 8-unit mono label font (0.6 em), and its line height.
    static let charWidth: CGFloat = 4.9
    static let lineHeight: CGFloat = 10

    /// One label per layer present, at the middle of its first span, greedily by priority; a label that would overlap
    /// the hub or a placed label is left out (its layer still has its own radius and mark, and the scrub names it).
    static func place(state: DialState, metrics m: SundialMetrics, calendar: Calendar) -> [SundialLabel] {
        // 0.6: the label ring lies over the inner rings, so with any ring on the key under the dial names the layers.
        guard state.rings.isEmpty else { return [] }
        struct Candidate { let text: String; let tone: InkTone; let hour: Double; let night: Bool }
        var candidates: [Candidate] = []
        func mid(_ start: Date, _ end: Date) -> Double {
            SundialGeometry.hourOfDay(start, calendar: calendar)
                + SundialGeometry.sweepHours(from: start, to: end, calendar: calendar) / 2
        }
        func span(_ kinds: Set<DialArc.Kind>) -> (Date, Date)? {
            let arcs = state.arcs.filter { kinds.contains($0.kind) }
            guard let s = arcs.map(\.start).min(), let e = arcs.map(\.end).max(), e > s else { return nil }
            return (s, e)
        }

        if let (s, e) = span([.deep, .light, .rem, .awake, .unstaged]) {
            candidates.append(Candidate(text: "last night", tone: .sleep, hour: mid(s, e), night: true))
        }
        if let (s, e) = span([.plannedSleep]) {
            candidates.append(Candidate(text: "tonight", tone: .sleep, hour: mid(s, e), night: true))
        }
        if let a = state.arcs.first(where: { $0.kind == .napUnconfirmed }) {
            candidates.append(Candidate(text: "nap?", tone: .sleep, hour: mid(a.start, a.end), night: false))
        } else if let a = state.arcs.first(where: { $0.kind == .nap }) {
            candidates.append(Candidate(text: "nap", tone: .sleep, hour: mid(a.start, a.end), night: false))
        }
        if let a = state.arcs.first(where: { $0.kind == .workout }) {
            candidates.append(Candidate(text: "workout", tone: .body, hour: mid(a.start, a.end), night: false))
        }
        if let a = state.arcs.first(where: { $0.kind == .strapOff }) {
            candidates.append(Candidate(text: "strap off", tone: .mute, hour: mid(a.start, a.end), night: false))
        }
        if let w = state.ticks.first(where: { $0.kind == .smartWakeWindow }) {
            candidates.append(Candidate(text: "wake", tone: .sleep, hour: mid(w.at, w.end ?? w.at), night: true))
        }
        if let peak = state.caffeineCurve.filter({ $0.opacity > 0.05 }).max(by: { $0.mg < $1.mg }) {
            candidates.append(Candidate(text: "caffeine", tone: .caffeine,
                                        hour: SundialGeometry.hourOfDay(peak.at, calendar: calendar), night: false))
        }
        if let b = state.ticks.first(where: { $0.kind == .bedtime }) {
            candidates.append(Candidate(text: "bed", tone: .sleep, hour: SundialGeometry.hourOfDay(b.at, calendar: calendar),
                                        night: false))
        }
        if let c = state.ticks.first(where: { $0.kind == .caffeineCutoff }) {
            candidates.append(Candidate(text: "cut-off", tone: .caffeine,
                                        hour: SundialGeometry.hourOfDay(c.at, calendar: calendar), night: false))
        }
        if let w = state.ticks.first(where: { $0.kind == .wakeMarker }) {
            candidates.append(Candidate(text: "woke", tone: .sleep, hour: SundialGeometry.hourOfDay(w.at, calendar: calendar),
                                        night: false))
        }

        let hub = CGRect(x: m.center.x - m.units(SundialDesign.hubHalfWidth),
                         y: m.center.y - m.units(SundialDesign.hubHalfHeight),
                         width: m.units(2 * SundialDesign.hubHalfWidth), height: m.units(2 * SundialDesign.hubHalfHeight))
        var placed: [CGRect] = []
        var out: [SundialLabel] = []
        for c in candidates {
            let p = m.point(hour: c.hour, offset: SundialDesign.labelOffset)
            let w = m.units(CGFloat(c.text.count) * charWidth + 4), h = m.units(lineHeight)
            let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
            guard !rect.intersects(hub), !placed.contains(where: { $0.intersects(rect) }) else { continue }
            placed.append(rect)
            out.append(SundialLabel(text: c.text, tone: c.tone, center: p, night: c.night))
        }
        return out
    }
}
