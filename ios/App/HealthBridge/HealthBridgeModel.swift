import Combine
import Foundation
import MGContext
import MGHealth

// The Shortcuts bridge's own state (Settings › Apple Health, 2026-10-11). Kept apart from AppModel's snapshot so the
// bridge adds no stored property to the shared settings documents: one kv document `healthBridge.v1` in MGStore
// (send log, import log, which values are already in Health, the run waiting for a callback, the auto-send switch).

/// One Shortcut run: what was sent, when, and how it ended (`result` = ShortcutOutcome.Kind raw value or "pending").
struct HealthSendRecord: Codable, Equatable {
    var id: UUID
    var at: Date
    var shortcut: String
    var day: String?
    var what: String
    /// `mgapp:<metric>:<day>` keys the run carried; marked as logged when Shortcuts says ok.
    var keys: [String]
    var result: String
    var detail: String?
    var resultAt: Date?
    var auto: Bool
    /// The callback's raw parameters as iOS sent them ("error · errorCode=4 · errorDomain=… · errorMessage=(none)"),
    /// kept for every run (2026-10-11: iOS 26.5+ changed what x-callback reports).
    var raw: String? = nil
}

/// A `healthapp://import?data=…` link: kept until the PC has it (`status` waiting → stored / duplicate / failed /
/// rejected). The body is dropped once the PC answered for good.
struct HealthImportRecord: Codable, Equatable {
    var id: UUID
    var at: Date
    var bytes: Int
    var sha8: String
    var body: Data?
    var status: String
    var detail: String?
    var forwardedAt: Date?
}

/// The run the app is waiting for a callback from (x-success / x-error / x-cancel).
struct HealthPendingRun: Codable, Equatable {
    var sendId: UUID
    var shortcut: String
    var startedAt: Date
    var keys: [String]
}

struct HealthBridgeDoc: Codable, Equatable {
    static let key = "healthBridge.v1"
    static let keep = 60

    var autoSend = false
    var sends: [HealthSendRecord] = []
    var imports: [HealthImportRecord] = []
    /// External key → when Shortcuts reported the run that carried it as done.
    var sentKeys: [String: Date] = [:]
    var pending: HealthPendingRun?
    /// The wake day the automatic send last ran for (once a day, whatever the outcome).
    var lastAutoDay: String?
    /// A wake day whose automatic send waits for the app to be in front (iOS opens Shortcuts only from there).
    var autoWaiting: String?

    mutating func trim() {
        if sends.count > Self.keep { sends.removeFirst(sends.count - Self.keep) }
        if imports.count > Self.keep {
            // Never drop an import the PC does not have yet.
            let drop = imports.count - Self.keep
            var dropped = 0
            imports.removeAll { r in
                guard dropped < drop, r.body == nil else { return false }
                dropped += 1
                return true
            }
        }
        if sentKeys.count > 200 {
            for (k, _) in sentKeys.sorted(by: { $0.value < $1.value }).prefix(sentKeys.count - 200) { sentKeys[k] = nil }
        }
    }
}

@MainActor
final class HealthBridgeModel: ObservableObject {
    @Published var state: AppleHealthState?
    var doc = HealthBridgeDoc()
    /// The one read of the stored log; every entry point awaits it before touching `doc` (a save before it finished
    /// would replace the stored log).
    var loadTask: Task<Void, Never>?
    var token: AppleHealthInput.Token = .notPaired
    var expanded: Set<String> = []
    var banner: AppleHealthState.Banner?
    var noReplyTask: Task<Void, Never>?
    var forwarding = false

    init() {}
}
