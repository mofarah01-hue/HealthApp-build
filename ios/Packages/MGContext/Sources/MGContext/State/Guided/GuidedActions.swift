import Foundation
import MGDomain

// Payloads of two UIIntent cases added for WP-29 with main's OK (2026-10-11):
//   case guided(GuidedAction)                       — Breathe / HRV check flows (APP-024, APP-025)
//   case editWorkout(id: UUID, edit: WorkoutEdit)   — Workout detail edits (APP-051, APP-058)
// Views send them; WP-23's handlers do the work. Opening the flows keeps the existing intents:
// `.startBreathe`, `.startHRVCheck(minutes:)` (also "again with n minutes"), `.openWorkout(id:)`.

/// What Mo does inside a guided flow (Breathe pacer, HRV spot check).
public enum GuidedAction: Equatable, Sendable {
    /// Breathe ready screen → start the pacer at this rate for this long. Default 6 /min, 5 min
    /// (ALG-104 resonance breathing, McCraty & Zayas 2014; UX §4.1 Night row "Breathe (pacer, 5 min)").
    case beginBreathe(perMinute: Double, minutes: Int)
    /// Stop now and show the result from what was collected; too little data → the result is blank with the reason.
    case endNow
    /// Close the flow. From ready or result: nothing more happens. While running: discarded, nothing saved.
    case close
}

/// One edit on a workout (Workout detail, UX §14). Every edit is a new revision of the workoutEvent (contract v0.5
/// `revision`); nothing is deleted. The detector's own type and window stay kept beside Mo's (APP-058, ALG-041).
public enum WorkoutEdit: Equatable, Sendable {
    /// Mo's activity label → contract `activity_type_user`; overrides `activity_type_auto` on screen, both kept.
    /// nil clears Mo's label (the auto type shows again).
    case setType(String?)
    /// Where it happened ("gym", "home", "outdoors") → contract eventBase `location.label`
    /// (main, 2026-10-11: no new field). nil clears the label.
    case setPlace(String?)
    /// Free text → eventBase `note`; nil or empty clears it.
    case setNote(String?)
    /// Where the strap was worn for this workout (wrist / bicep, left / right) → eventBase `wear_location`; nil clears it (the
    /// algorithms then read the wear timeline). D-LOAD-WALK-1 item 12: strap-derived steps are off while it is a bicep
    /// (`WearPolicy`).
    case setWearLocation(WearLocation?)
    /// Trim the whole workout. Mo's confirmed window is the detector's label (ALG-041 / ALG-047).
    case setTimes(start: Date, end: Date)
    /// warm-up / work / rest / interval / cool-down / set (contract workoutEvent.windows.kind).
    /// `windowId` = `WorkoutWindowRow.id` convention "kind:epochSeconds".
    case setWindowKind(windowId: String, kind: WorkoutFields.Window.Kind)
    /// Split one window in two at `at` (strictly inside the window; the handler refuses otherwise, with a reason).
    case splitWindow(windowId: String, at: Date)
    /// Merge a window with the one after it (the earlier window's kind is kept).
    case mergeWithNext(windowId: String)
    /// r9p (D-LOAD-WALK-2): the CR-10 rating of the whole session, 0 to 10 (contract `session_rpe`); nil clears it.
    case setRPE(Double?)
    /// r9p: body weight just before / just after (kg) for the sweat-loss estimate (contract `weight_pre_kg` / `weight_post_kg`);
    /// a nil side is cleared.
    case setWeights(pre: Double?, post: Double?)
}
