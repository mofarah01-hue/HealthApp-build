import Foundation
import MGDomain

/// What the app knows about the Shortcuts bridge, in plain values (the app builds it; MGContext does not know MGHealth).
public struct AppleHealthInput: Sendable {
    public struct Send: Sendable {
        public var id: String
        public var at: Date
        public var shortcut: String
        public var what: String
        /// ShortcutOutcome.Kind raw value, or "pending".
        public var result: String
        public var detail: String?
        public var auto: Bool

        public init(id: String, at: Date, shortcut: String, what: String, result: String, detail: String?, auto: Bool) {
            self.id = id
            self.at = at
            self.shortcut = shortcut
            self.what = what
            self.result = result
            self.detail = detail
            self.auto = auto
        }
    }

    public struct Import: Sendable {
        public var id: String
        public var at: Date
        public var bytes: Int
        /// "waiting", "stored", "duplicate", "failed".
        public var status: String
        public var detail: String?

        public init(id: String, at: Date, bytes: Int, status: String, detail: String?) {
            self.id = id
            self.at = at
            self.bytes = bytes
            self.status = status
            self.detail = detail
        }
    }

    public enum Token: Equatable, Sendable {
        case notPaired
        case loading
        case ready(token: String, endpoint: String)
        case failed(String)
    }

    public struct GuideText: Sendable {
        public var id: String
        public var title: String
        public var purpose: String
        public var steps: [String]
        public var isShortcut: Bool
        /// Offer "Run it now" (runs the Shortcut with no input).
        public var runnable: Bool

        public init(id: String, title: String, purpose: String, steps: [String], isShortcut: Bool, runnable: Bool) {
            self.id = id
            self.title = title
            self.purpose = purpose
            self.steps = steps
            self.isShortcut = isShortcut
            self.runnable = runnable
        }
    }

    public var now: Date
    public var calendar: Calendar
    public var sample: Bool
    public var inShortcut: String
    public var outShortcut: String
    public var todayLines: [String]
    public var todaySkipped: [String]
    /// Why there is nothing to send (no values yet, all logged already); nil when there is something.
    public var nothingToSend: String?
    public var autoSend: Bool
    public var pending: (shortcut: String, since: Date)?
    public var banner: AppleHealthState.Banner?
    public var token: Token
    public var sends: [Send]
    public var imports: [Import]
    public var guides: [GuideText]
    public var expanded: Set<String>

    public init(now: Date, calendar: Calendar, sample: Bool, inShortcut: String, outShortcut: String,
                todayLines: [String], todaySkipped: [String], nothingToSend: String?, autoSend: Bool,
                pending: (shortcut: String, since: Date)?, banner: AppleHealthState.Banner?, token: Token,
                sends: [Send], imports: [Import], guides: [GuideText], expanded: Set<String>) {
        self.now = now
        self.calendar = calendar
        self.sample = sample
        self.inShortcut = inShortcut
        self.outShortcut = outShortcut
        self.todayLines = todayLines
        self.todaySkipped = todaySkipped
        self.nothingToSend = nothingToSend
        self.autoSend = autoSend
        self.pending = pending
        self.banner = banner
        self.token = token
        self.sends = sends
        self.imports = imports
        self.guides = guides
        self.expanded = expanded
    }
}

/// Settings › Apple Health (2026-10-11). Pure: formatting, enabled states and their reasons.
public enum AppleHealthPresenter {
    static let sampleReason = "Sample data is on: nothing goes to Apple Health or the PC. Switch it off in Settings › Sample data."

    public static func make(_ i: AppleHealthInput) -> AppleHealthState {
        let send: ActionState
        if i.sample {
            send = ActionState(id: "send", title: "Send today to Health", intent: .appleHealth(.sendToday),
                               enabled: false, disabledReason: sampleReason)
        } else if let p = i.pending {
            send = ActionState(id: "send", title: "Send today to Health", intent: .appleHealth(.sendToday),
                               enabled: false, disabledReason: "Waiting for “\(p.shortcut)” to finish.")
        } else if let why = i.nothingToSend {
            send = ActionState(id: "send", title: "Send today to Health", intent: .appleHealth(.sendToday),
                               enabled: false, disabledReason: why)
        } else {
            send = ActionState(id: "send", title: "Send today to Health", intent: .appleHealth(.sendToday))
        }
        let auto = ToggleState(id: "autoSend", title: "Send automatically after the morning compute",
                               detail: "Opens Shortcuts once a day, the first time the app is open after last night's "
                                   + "values are ready.",
                               isOn: i.autoSend, enabled: !i.sample, disabledReason: i.sample ? sampleReason : nil,
                               intent: .appleHealth(.setAutoSend(!i.autoSend)))

        var tokenLine: String
        var endpoint: String?
        var canCopy = false
        switch i.token {
        case .notPaired:
            tokenLine = "Pair with your PC Lab first (Settings › PC Lab): the token comes from the PC."
        case .loading:
            tokenLine = "Asking the PC Lab for the token…"
        case .ready(let token, let url):
            tokenLine = "Token " + masked(token)
            endpoint = url
            canCopy = true
        case .failed(let why):
            tokenLine = "Couldn't get the token: \(why)"
        }
        let refresh = ActionState(id: "refreshToken", title: "Get token again", intent: .appleHealth(.refreshToken),
                                  enabled: i.token != .notPaired && i.token != .loading,
                                  disabledReason: i.token == .notPaired ? "Pair with your PC Lab first." : nil)
        // Always tappable (Mo 2026-10-11): a run still waiting for a reply is closed as "no reply" when a new one starts;
        // in SAMPLE mode the tap says why nothing goes to the PC.
        let runOut = ActionState(id: "runOut", title: "Run “\(i.outShortcut)” now",
                                 intent: .appleHealth(.runShortcut(i.outShortcut)))
        let testIn = ActionState(id: "testIn", title: "Test “\(i.inShortcut)” (sends nothing)",
                                 intent: .appleHealth(.testInShortcut))
        let waiting = i.imports.filter { $0.status == "waiting" || $0.status == "failed" }.count
        let forward: ActionState? = waiting == 0 ? nil
            : ActionState(id: "forward", title: "Send \(waiting) waiting import\(waiting == 1 ? "" : "s") to the PC",
                          intent: .appleHealth(.forwardImports), enabled: !i.sample,
                          disabledReason: i.sample ? sampleReason : nil)

        let sends = i.sends.reversed().prefix(20).map { s -> AppleHealthState.LogRow in
            let problem = !["ok", "pending", "unconfirmed"].contains(s.result)
            return AppleHealthState.LogRow(id: s.id, when: when(s.at, i), title: (s.auto ? "Auto · " : "") + s.what,
                                           detail: s.detail, status: status(s.result), isProblem: problem)
        }
        let imports = i.imports.reversed().prefix(20).map { m -> AppleHealthState.LogRow in
            AppleHealthState.LogRow(id: m.id, when: when(m.at, i), title: "Import link · " + bytes(m.bytes),
                                    detail: m.detail, status: m.status, isProblem: m.status == "failed")
        }
        let guides = i.guides.map { g -> AppleHealthState.Guide in
            let run = g.runnable
                ? ActionState(id: "run:" + g.id, title: "Run it now", intent: .appleHealth(.runShortcut(g.title)))
                : nil
            return AppleHealthState.Guide(id: g.id, title: g.title, purpose: g.purpose, steps: g.steps,
                                          expanded: i.expanded.contains(g.id), isShortcut: g.isShortcut, run: run)
        }
        let pending = i.pending.map { "Waiting for Shortcuts to finish “\($0.shortcut)” (since \(MGFormat.time($0.since, calendar: i.calendar)))…" }
        return AppleHealthState(sample: i.sample, banner: i.banner, pending: pending, todayLines: i.todayLines,
                                todaySkipped: i.todaySkipped, send: send, autoSend: auto, tokenLine: tokenLine,
                                endpointLine: endpoint, canCopyToken: canCopy, refreshToken: refresh, runOut: runOut,
                                forward: forward, sends: Array(sends), imports: Array(imports), guides: guides,
                                testIn: testIn)
    }

    /// "mgs_…k3Qx": enough to recognise it, not enough to use it from a screenshot.
    static func masked(_ token: String) -> String {
        guard token.count > 8 else { return "…" }
        return String(token.prefix(4)) + "…" + String(token.suffix(4))
    }

    static func status(_ kind: String) -> String {
        switch kind {
        case "ok": return "done"
        case "pending": return "waiting"
        case "notFound": return "shortcut not found"
        case "failed": return "error"
        case "cancelled": return "cancelled"
        case "noReply": return "no reply"
        case "couldNotOpen": return "Shortcuts didn't open"
        case "unconfirmed": return "ran · unconfirmed (iOS sent no result)"
        default: return kind
        }
    }

    static func when(_ d: Date, _ i: AppleHealthInput) -> String {
        let t = MGFormat.time(d, calendar: i.calendar)
        if i.calendar.isDate(d, inSameDayAs: i.now) { return t }
        if let y = i.calendar.date(byAdding: .day, value: -1, to: i.now), i.calendar.isDate(d, inSameDayAs: y) {
            return "yesterday " + t
        }
        return MGFormat.shortDate(d, calendar: i.calendar) + " " + t
    }

    static func bytes(_ n: Int) -> String {
        n < 1000 ? "\(n) B" : n < 1_000_000 ? "\(Int((Double(n) / 1000).rounded())) KB" : String(format: "%.1f MB", Double(n) / 1e6)
    }
}
