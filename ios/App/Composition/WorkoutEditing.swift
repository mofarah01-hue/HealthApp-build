import Foundation
import MGContext
import MGDomain

// WP-23a — `.editWorkout(id:edit:)` (BRIEF WP-29 row): every edit is a NEW revision of the workoutEvent (the store bumps
// `revision`; nothing is deleted). setType → `activity_type_user` (the detector's `activity_type_auto` is kept);
// setPlace → eventBase `location.label` (saved place id / lat / lon kept); setNote → `note`; setTimes trims the workout
// and clips its windows; a split happens only strictly inside a window; a merge keeps the earlier window's kind.
// Pure: the caller loads the event and stores the result.
//
// WRITTEN, NOT COMPILED.

enum WorkoutEditing {
    enum Failure: Error, Equatable {
        case notAWorkout
        case refused(String)

        var message: String {
            switch self {
            case .notAWorkout: return "That entry isn't a workout."
            case .refused(let why): return why
            }
        }
    }

    static func apply(_ edit: WorkoutEdit, to event: EventRecord) -> Result<EventRecord, Failure> {
        guard case .workout(var f) = event.payload else { return .failure(.notAWorkout) }
        var e = event
        switch edit {
        case .setType(let type):
            f.activityTypeUser = clean(type)
        case .setPlace(let place):
            var loc = e.location ?? EventLocation()
            loc.label = clean(place)
            e.location = (loc.label == nil && loc.savedPlaceId == nil && loc.lat == nil && loc.lon == nil) ? nil : loc
        case .setNote(let note):
            e.note = clean(note)
        case .setWearLocation(let place):
            e.wearLocation = (place == .unknown) ? nil : place
        case .setTimes(let start, let end):
            guard start < end else { return .failure(.refused("The end must be after the start.")) }
            e.at = start
            f.end = end
            f.windows = clip(f.windows, start: start, end: end)
        case .setRPE(let rpe):
            if let rpe, !(rpe.isFinite && rpe >= 0 && rpe <= 10) { return .failure(.refused("The rating is 0 to 10.")) }
            f.sessionRpe = rpe
        case .setWeights(let pre, let post):
            for w in [pre, post].compactMap({ $0 }) where !(w.isFinite && w >= 30 && w <= 250) {
                return .failure(.refused("A body weight between 30 and 250 kg."))
            }
            f.weightPreKg = pre
            f.weightPostKg = post
        case .setWindowKind(let windowId, let kind):
            guard var ws = f.windows?.sorted(by: { $0.start < $1.start }), let i = index(of: windowId, in: ws) else {
                return .failure(.refused("That window is no longer there."))
            }
            ws[i].kind = kind
            f.windows = ws
        case .splitWindow(let windowId, let at):
            guard var ws = f.windows?.sorted(by: { $0.start < $1.start }), let i = index(of: windowId, in: ws) else {
                return .failure(.refused("That window is no longer there."))
            }
            let w = ws[i]
            guard w.start < at, at < w.end else {
                return .failure(.refused("Split inside the window, between its start and its end."))
            }
            var first = w
            first.end = at
            var second = w
            second.start = at
            second.label = nil
            second.setIndex = nil
            ws.replaceSubrange(i...i, with: [first, second])
            f.windows = ws
        case .mergeWithNext(let windowId):
            guard var ws = f.windows?.sorted(by: { $0.start < $1.start }), let i = index(of: windowId, in: ws), i + 1 < ws.count else {
                return .failure(.refused("There is no next window to merge with."))
            }
            var merged = ws[i]
            merged.end = max(ws[i].end, ws[i + 1].end)
            ws.replaceSubrange(i...(i + 1), with: [merged])
            f.windows = ws
        }
        e.payload = .workout(f)
        return .success(e)
    }

    /// Windows sorted by start; the one whose `WorkoutDetailWindow.makeID(kind:start:)` is `id`.
    private static func index(of id: String, in windows: [WorkoutFields.Window]) -> Int? {
        windows.firstIndex { WorkoutDetailWindow.makeID(kind: $0.kind, start: $0.start) == id }
    }

    /// Clips every window to [start, end]; windows left empty are dropped. nil stays nil.
    static func clip(_ windows: [WorkoutFields.Window]?, start: Date, end: Date) -> [WorkoutFields.Window]? {
        guard let windows else { return nil }
        let out = windows.sorted { $0.start < $1.start }.compactMap { w -> WorkoutFields.Window? in
            var c = w
            c.start = max(w.start, start)
            c.end = min(w.end, end)
            return c.start < c.end ? c : nil
        }
        return out.isEmpty ? nil : out
    }

    private static func clean(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: Live workout windows (UX §6 Workout mode: warm-up / work / rest; [Next window])

    /// The kind after `kind` when Mo taps [Next window]: warm-up → work → rest → work → … (UX §6).
    static func nextKind(after kind: WorkoutFields.Window.Kind?) -> WorkoutFields.Window.Kind {
        switch kind {
        case nil: return .warmup
        case .warmup?, .rest?, .cooldown?: return .work
        case .work?, .interval?, .set?: return .rest
        }
    }

    /// Closes the open window at `now` and opens the next one.
    static func nextWindow(_ w: inout LiveSessions.Workout, now: Date) {
        var kind: WorkoutFields.Window.Kind? = nil
        if var last = w.windows.last {
            kind = last.kind
            last.end = now
            w.windows[w.windows.count - 1] = last
        } else if now > w.start {
            // The time before the first tap was the warm-up.
            w.windows.append(WorkoutFields.Window(start: w.start, end: now, kind: .warmup))
            kind = .warmup
        }
        let next = nextKind(after: kind)
        // An open window's end is `now` until it is closed; `manualWorkout` fixes the last one at the end.
        w.windows.append(WorkoutFields.Window(start: now, end: now, kind: next))
    }
}
