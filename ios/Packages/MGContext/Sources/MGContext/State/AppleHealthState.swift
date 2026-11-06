import Foundation

/// Settings › Apple Health (the Shortcuts bridge, 2026-10-11). Built by `AppleHealthPresenter` from `AppleHealthInput`.
public struct AppleHealthState: Equatable, Sendable {
    public static let automationGuideId = "automation"

    /// The last Shortcut outcome worth reading ("Shortcut “HealthApp → Health” not found — build it (steps)").
    public struct Banner: Equatable, Sendable {
        public var text: String
        /// The guide the "Steps" button opens; nil = no button.
        public var stepsFor: String?
        public var isProblem: Bool

        public init(text: String, stepsFor: String?, isProblem: Bool) {
            self.text = text
            self.stepsFor = stepsFor
            self.isProblem = isProblem
        }
    }

    /// One line of the send log or the import log.
    public struct LogRow: Equatable, Sendable, Identifiable {
        public var id: String
        public var when: String
        public var title: String
        public var detail: String?
        public var status: String
        public var isProblem: Bool

        public init(id: String, when: String, title: String, detail: String?, status: String, isProblem: Bool) {
            self.id = id
            self.when = when
            self.title = title
            self.detail = detail
            self.status = status
            self.isProblem = isProblem
        }
    }

    /// Build steps for one Shortcut (or the daily automation).
    public struct Guide: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var purpose: String
        public var steps: [String]
        public var expanded: Bool
        /// The title is a Shortcut name: show "Copy name".
        public var isShortcut: Bool
        /// "Run it now" (to test the Shortcut once built); nil when the page has its own button for it.
        public var run: ActionState?

        public init(id: String, title: String, purpose: String, steps: [String], expanded: Bool, isShortcut: Bool,
                    run: ActionState? = nil) {
            self.id = id
            self.title = title
            self.purpose = purpose
            self.steps = steps
            self.expanded = expanded
            self.isShortcut = isShortcut
            self.run = run
        }
    }

    public var sample: Bool
    public var banner: Banner?
    /// "Waiting for Shortcuts to finish “HealthApp → Health” (since 07:12)…".
    public var pending: String?
    /// What "Send today" would log, one line per value.
    public var todayLines: [String]
    /// Values that exist but are not sent, with the reason.
    public var todaySkipped: [String]
    public var send: ActionState
    /// "Test ‘HealthApp → Health’ (sends nothing)": always tappable (2026-10-11).
    public var testIn: ActionState?
    public var autoSend: ToggleState
    public var tokenLine: String
    public var endpointLine: String?
    public var canCopyToken: Bool
    public var refreshToken: ActionState
    public var runOut: ActionState
    public var forward: ActionState?
    public var sends: [LogRow]
    public var imports: [LogRow]
    public var guides: [Guide]
    /// T9739: "Apple Health: last read <time>, last reached the PC <time>, N samples queued" (the automatic in-app read);
    /// nil when this build reads no Health (no HealthKit).
    public var autoLine: String?
    /// P9817: one line per Health type, e.g. "Blood Oxygen: no data returned ..." or "Heart Rate: 14 samples, last 9:05 AM".
    public var autoTypeLines: [String]?

    public init(sample: Bool, banner: Banner?, pending: String?, todayLines: [String], todaySkipped: [String],
                send: ActionState, autoSend: ToggleState, tokenLine: String, endpointLine: String?, canCopyToken: Bool,
                refreshToken: ActionState, runOut: ActionState, forward: ActionState?, sends: [LogRow],
                imports: [LogRow], guides: [Guide], testIn: ActionState? = nil) {
        self.sample = sample
        self.banner = banner
        self.pending = pending
        self.todayLines = todayLines
        self.todaySkipped = todaySkipped
        self.send = send
        self.autoSend = autoSend
        self.tokenLine = tokenLine
        self.endpointLine = endpointLine
        self.canCopyToken = canCopyToken
        self.refreshToken = refreshToken
        self.runOut = runOut
        self.forward = forward
        self.sends = sends
        self.imports = imports
        self.guides = guides
        self.testIn = testIn
    }
}
