import Foundation

// WP-24 — background task identifiers, read from Info.plist `BGTaskSchedulerPermittedIdentifiers`
// (ARCHITECTURE §4.11 table; project.yml lists `$(PRODUCT_BUNDLE_IDENTIFIER).sync / .compute / .rawupload / .healthread`).
//
// NEVER built from `Bundle.main.bundleIdentifier` (BRIEF clarification, WP-25 row): Sideloadly / AltStore rewrite the
// bundle id when re-signing but leave the permitted list as built, and `BGTaskScheduler.register` refuses an id that
// is not on that list — every background task would go inert with no visible error (noop #2514 / #2553,
// StrandTests/BackgroundTaskIdentityTests.swift). Taking the ids from the list itself always registers what iOS permits.

enum BackgroundTaskRole: String, Sendable, CaseIterable {
    /// BGAppRefreshTask, every ≥ 60 min: sync with a 25 s budget (§5.7).
    case sync = "sync"
    /// BGProcessingTask on external power: recompute (WP-23's ComputeCoordinator).
    case compute = "compute"
    /// BGProcessingTask with network, any power: a long window for raw drops. CHANGED 2026-10-11 (#74): it used to
    /// say "on external power + network: raw drops (D11, Wi-Fi + charging)"; raw now goes on any connection outside
    /// Low Data Mode, with every sync too.
    case rawUpload = "rawupload"
    /// BGAppRefreshTask: Apple Health read (MGHealth, hourly).
    case healthRead = "healthread"

    /// The id ends in this.
    var suffix: String { "." + rawValue }
    var isProcessing: Bool { self == .compute || self == .rawUpload }
}

struct BackgroundTaskIDs: Equatable, Sendable {
    static let infoPlistKey = "BGTaskSchedulerPermittedIdentifiers"

    /// role → the exact permitted identifier.
    var ids: [BackgroundTaskRole: String]
    /// Plain sentences for the diagnostics screen and the log ("no id ends in .sync — hourly sync will not run").
    var problems: [String]

    func id(for role: BackgroundTaskRole) -> String? { ids[role] }

    /// Picks, for each role, the permitted id that ends in ".<role>". Several → the first, reported. None → reported.
    static func resolve(permitted: [String]) -> BackgroundTaskIDs {
        var ids: [BackgroundTaskRole: String] = [:]
        var problems: [String] = []
        for role in BackgroundTaskRole.allCases {
            let matches = permitted.filter { $0.hasSuffix(role.suffix) && $0.count > role.suffix.count }
            guard let first = matches.first else {
                problems.append("Info.plist permits no background task id ending in \(role.suffix): "
                                + "\(BackgroundTaskIDs.consequence(role)) will not run")
                continue
            }
            if matches.count > 1 {
                problems.append("\(matches.count) permitted ids end in \(role.suffix); using \(first)")
            }
            if first.contains("$(") {
                problems.append("\(first) still holds an unexpanded build variable")
            }
            ids[role] = first
        }
        return BackgroundTaskIDs(ids: ids, problems: problems)
    }

    static func fromInfoDictionary(_ info: [String: Any]) -> BackgroundTaskIDs {
        guard let list = info[infoPlistKey] as? [String] else {
            return BackgroundTaskIDs(ids: [:], problems: ["Info.plist has no \(infoPlistKey): no background task will run"])
        }
        return resolve(permitted: list)
    }

    static func fromMainBundle() -> BackgroundTaskIDs { fromInfoDictionary(Bundle.main.infoDictionary ?? [:]) }

    private static func consequence(_ role: BackgroundTaskRole) -> String {
        switch role {
        case .sync: return "the hourly background sync"
        case .compute: return "recomputing on charge"
        case .rawUpload: return "the long background raw upload"
        case .healthRead: return "the background Apple Health read"
        }
    }
}
