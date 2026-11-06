import Foundation

/// What Settings › Command test shows (T87). Built by `CommandTestPresenter`; held by `CommandTestSession`.
public struct CommandTestState: Equatable, Sendable {
    public struct Command: Equatable, Identifiable, Sendable {
        public var number: Int
        public var name: String
        public var on: Bool
        /// Information only: shows "can disable the strap". Never blocks the toggle.
        public var canDisableStrap: Bool
        /// r8h C1: the newest log entry for this command has been sent from this page (the Send button's "last result").
        public var wasSent: Bool = false
        /// The result mark Mo gave that newest entry, if any.
        public var lastMark: CommandTestMark?
        public var id: Int { number }
    }

    public struct Entry: Equatable, Identifiable, Sendable {
        public var id: Int64
        /// "REBOOT_STRAP (29) · payload 01 02 · 9:24 PM"
        public var text: String
        public var mark: CommandTestMark?
    }

    public var commands: [Command]
    public var payload: String
    /// Set while the payload field is not whole bytes of hex; the toggles then send nothing.
    public var payloadProblem: String?
    /// Newest first.
    public var log: [Entry]
    /// Why the last toggle did not send, or a log problem.
    public var notice: String?
    /// The "Raw optical (PPG)" section at the top (P9726).
    public var ppg = RawPPGState()
    /// r8h C1: the command being sent right now; every Send button is disabled while it is set.
    public var sending: Int?

    public static let empty = CommandTestState(commands: [], payload: "", payloadProblem: nil, log: [], notice: nil)
}
