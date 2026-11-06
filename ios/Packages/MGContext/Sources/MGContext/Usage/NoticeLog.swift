import Foundation

/// R9f (UI-SCRUB-B N4): the last few one-line notices the app showed ("Heart-rate broadcast on: ...", a failure reason). The
/// notice capsule times out after 5 s and shows two lines, so a long reason was lost; Settings › Usage › Recent messages lists
/// the newest `keep` in full. In memory only (a notice is a moment, not a record); the lock makes it callable from any actor.
public final class NoticeLog: @unchecked Sendable {
    public static let shared = NoticeLog()

    public struct Entry: Equatable, Sendable {
        public var at: Date
        public var text: String

        public init(at: Date, text: String) {
            self.at = at
            self.text = text
        }
    }

    /// Notices kept.
    public static let keep = 5
    /// A longer notice is cut here (with an ellipsis) so one runaway message cannot grow the list.
    public static let maxLength = 600

    private let lock = NSLock()
    private var entries: [Entry] = []

    public init() {}

    /// Adds a notice. Blank text is ignored; the same text twice in a row is kept once (the time moves to the newer).
    public func add(_ text: String, at: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clipped = trimmed.count > Self.maxLength ? String(trimmed.prefix(Self.maxLength - 1)) + "…" : trimmed
        lock.lock()
        defer { lock.unlock() }
        if entries.last?.text == clipped { entries.removeLast() }
        entries.append(Entry(at: at, text: clipped))
        if entries.count > Self.keep { entries.removeFirst(entries.count - Self.keep) }
    }

    /// Newest first.
    public func recent() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.reversed()
    }

    /// For tests.
    public func clear() {
        lock.lock()
        entries = []
        lock.unlock()
    }
}
