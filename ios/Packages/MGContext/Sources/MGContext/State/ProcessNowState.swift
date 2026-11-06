import Foundation
import MGDomain

// "Process now" sheet (Mo, Nov 6 2026: "a process button ... on that sleep card ... to force it to process now"; approved
// mock-up section 2). Four steps, each with its own detail; a failure says what was kept and what is still safe on the strap.
// Pure state and words; the app drives it from the wake chain's steps.

public struct ProcessNowState: Equatable, Sendable {
    public enum StepID: String, CaseIterable, Sendable { case connect, download, compute, send }
    public enum Status: String, Equatable, Sendable { case waiting, running, done, failed }

    public struct Step: Equatable, Sendable, Identifiable {
        public var id: StepID
        public var title: String
        public var detail: String?
        public var status: Status
    }

    public var steps: [Step]
    /// True from "Process now" until the last step ends (the sheet may be closed; it keeps going).
    public var running: Bool
    /// Set when a step failed: the plain-words body of "Couldn't finish".
    public var failure: String?
    /// "Showing Apple Health (WHOOP) for now · 6 h 38" while a fallback night is on the card; nil when none.
    public var fallbackLine: String?

    public init(deviceName: String = "strap") {
        steps = [
            Step(id: .connect, title: "Connect to \(deviceName == "strap" ? "your strap" : deviceName)", detail: nil, status: .waiting),
            Step(id: .download, title: "Download from the strap", detail: nil, status: .waiting),
            Step(id: .compute, title: "Work out sleep", detail: "stages, wake-ups, HRV", status: .waiting),
            Step(id: .send, title: "Send to the PC", detail: nil, status: .waiting),
        ]
        running = false
        failure = nil
        fallbackLine = nil
    }

    public var title: String { failure == nil ? "Processing last night" : "Couldn't finish" }

    public mutating func begin(_ id: StepID, detail: String? = nil) {
        running = true
        set(id) { $0.status = .running; if let detail { $0.detail = detail } }
    }

    public mutating func update(_ id: StepID, detail: String) { set(id) { $0.detail = detail } }

    public mutating func finish(_ id: StepID, ok: Bool, detail: String?) {
        set(id) { $0.status = ok ? .done : .failed; if let detail { $0.detail = detail } }
    }

    /// The run is over: `failure` nil = all done. The first failed step names the failure.
    public mutating func end(failure text: String?) {
        running = false
        failure = text
    }

    /// "The strap stopped answering at 63% (3:12 AM). What's downloaded is saved, and the rest is safe on the strap."
    public static func downloadFailure(reason: String, progress: String?) -> String {
        var t = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if let progress, !progress.isEmpty { t += " (\(progress))" }
        if !t.hasSuffix(".") { t += "." }
        return t + " What's downloaded is saved, and the rest is safe on the strap."
    }

    /// "63% · up to 3:12 AM · 214 chunks saved" from the strap's own progress.
    public static func downloadDetail(_ h: HistoryProgress, hm: (Date) -> String) -> String {
        var parts: [String] = []
        if let f = h.fraction { parts.append("\(Int((f * 100).rounded(.down)))%") }
        if let n = h.newestTs { parts.append("up to \(hm(Date(timeIntervalSince1970: TimeInterval(n))))") }
        parts.append("\(h.chunksStored) chunk\(h.chunksStored == 1 ? "" : "s") saved")
        return parts.joined(separator: " · ")
    }

    /// "Showing Apple Health (on phone) · WHOOP via Apple Health for now · 6 h 38" while the card shows a fallback night.
    public static func fallbackLine(_ card: SleepCardState) -> String? {
        guard card.phase == .fallback, let d = card.durationText else { return nil }
        let who = card.pill.replacingOccurrences(of: " · fallback", with: "")
        return "Showing \(who) for now · \(d)"
    }

    private mutating func set(_ id: StepID, _ change: (inout Step) -> Void) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        change(&steps[i])
    }
}
