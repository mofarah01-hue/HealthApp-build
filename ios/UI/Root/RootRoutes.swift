import Foundation
import MGContext
import MGDomain

// WP-23a — navigation values for RootView (UX §3.1): pushed screens per tab (NavigationStack), the sheets and the
// full-screen covers. Names carry the `Root` prefix: every UI folder compiles into the one MGApp module (BRIEF WP-19 row).
//
// WRITTEN, NOT COMPILED.

/// A pushed screen. The tab bar stays visible under every push (UX §3.1); only sheets and covers hide it.
enum RootRoute: Hashable {
    /// T10022: the system and its connections. From the gear on Today and the first row of Preferences.
    case settings
    /// T10022: you and how the app looks and behaves. From the "M" on Today and the first row of Settings.
    case preferences
    /// Night (UX §8.2); nil = last night.
    case night(LocalDay?)
    /// Workout detail (WP-29); nil = the latest workout.
    case workout(UUID?)
    case metric(key: String, variant: String?)
    case group(String)
    case compare(String)
    case matrix
    /// Settings › Apple Health: the Shortcuts bridge (2026-10-11).
    case appleHealth
    /// Settings › Alarms, or Today's alarm chip: Mo's strap alarms (2026-10-11).
    case alarms
    /// Today's "N models not running ›" and Settings › Model status (2026-10-11).
    case modelStatus
    /// Settings › Usage: storage and compute on the phone and the PC (tracker #40, 2026-10-11).
    case usage
    /// Settings › Places: saved places that tag workouts (tracker #41, 2026-10-11).
    case places
    /// Settings › Front page: Today's cards and the dial's layers (tracker #34, 2026-10-11).
    case frontPage
    /// Settings › Command test: send any strap command by number and mark the result (T87, 2026-10-13).
    case commandTest
    /// Strap & sync › Device (WHOOP 4.0 selected) and the Live tab: the 4.0's raw once-a-second history fields (0.6.0.12).
    case whoop4Raw
    /// Settings › Ring lab (0.6.0.5).
    case ringLab
    /// Settings › Screen Time: Family Controls thresholds and Apple's report view (Mac build, Nov 2026).
    case screenTime
    /// "Your ages" from an age metric (W10, 2026-10-11).
    case ages
    /// Live › research: record inspector, capture session, raw retention (W10, #91).
    case research(String)
}

/// The one sheet on screen (UX §5: never a blocking modal on open; sheets only from a tap).
enum RootSheet: Identifiable, Equatable {
    case tonight
    case strapSync
    case pairing
    /// The strap clock's standing consent (D6), shown when Mo pairs the strap.
    case strapConsent
    case receipt(Receipt)
    /// Nov 6 2026: "Process now" on the sleep card.
    case processNow

    var id: String {
        switch self {
        case .tonight: return "tonight"
        case .strapSync: return "strapSync"
        case .pairing: return "pairing"
        case .strapConsent: return "strapConsent"
        case .processNow: return "processNow"
        case .receipt(let r): return "receipt:\(r.hashValue)"
        }
    }
}

/// Full-screen flows (UX §6: Breathe / HRV check cover the tab bar).
enum RootCover: String, Identifiable {
    case breathe
    case hrvCheck
    /// The 3-minute reaction test (PVT-B, ALG-050; 2026-10-11).
    case reactionTest
    /// The guided MG ECG reading (APP-033; wave W8, 2026-10-11).
    case ecg

    var id: String { rawValue }
}
