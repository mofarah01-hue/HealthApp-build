import Foundation

/// T9737 (2026-10-14): Today stayed blank after an install and nothing said why: the compute coordinator's log lived
/// only in memory, so a run frozen by iOS (or hung) left no trace. The app now appends every run start, per-day start /
/// end / result, abandon and "the previous process died mid-run" to a small file (`MG/compute-log.txt`, one event per
/// line: `epoch|kind|text`) and Settings › Usage shows the newest lines. This is the pure part: line format, trimming,
/// the unfinished-run check and the Usage section.
public enum ComputeLogUsage {
    /// Lines kept in the file (older ones are dropped; the file stays small).
    public static let keep = 300
    /// Lines shown in Usage.
    public static let shown = 40

    public enum Kind: String, Sendable {
        case runStart = "run-start"
        case runEnd = "run-end"
        case runAbandoned = "run-abandoned"
        case dayStart = "day-start"
        case dayEnd = "day-end"
        case note = "note"
        /// Written at launch when the file's last run never ended.
        case processDied = "process-died"
        case launch = "launch"
    }

    public struct Entry: Equatable, Sendable {
        public var at: Date
        public var kind: String
        public var text: String

        public init(at: Date, kind: String, text: String) {
            self.at = at
            self.kind = kind
            self.text = text
        }
    }

    public static func line(at: Date, kind: Kind, text: String) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/")
        return "\(Int(at.timeIntervalSince1970))|\(kind.rawValue)|\(clean)"
    }

    public static func parse(_ line: String) -> Entry? {
        let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let t = Double(parts[0]) else { return nil }
        return Entry(at: Date(timeIntervalSince1970: t), kind: parts[1], text: parts[2])
    }

    /// Appends one line and keeps the newest `keep`.
    public static func appending(_ new: String, to lines: [String], keep: Int = ComputeLogUsage.keep) -> [String] {
        var out = lines
        out.append(new)
        if out.count > keep { out.removeFirst(out.count - keep) }
        return out
    }

    /// The text of the newest `run-start` that no later `run-end` / `run-abandoned` / `process-died` closed; nil when the
    /// last run ended (or there was none). At launch a non-nil answer means the previous process died inside a run.
    public static func unfinishedRun(_ lines: [String]) -> Entry? {
        var open: Entry?
        for l in lines {
            guard let e = parse(l) else { continue }
            switch e.kind {
            case Kind.runStart.rawValue: open = e
            case Kind.runEnd.rawValue, Kind.runAbandoned.rawValue, Kind.processDied.rawValue: open = nil
            default: break
            }
        }
        return open
    }

    /// Settings › Usage › "Compute log": newest first, times 12-hour in the phone's zone. Blank file says so.
    public static func section(lines: [String], calendar: Calendar) -> UsageState.Section {
        let entries = lines.compactMap(parse)
        let note = "Every compute run: when it started, each day's start, end and result, a run dropped as stuck, and a run "
            + "that a closed or frozen app never finished. Kept in a small file on this phone (last \(keep) lines)."
        guard !entries.isEmpty else {
            return UsageState.Section(id: "computeLog", title: "Compute log", note: note, rows: [
                UsageState.Row(id: "clog.none", title: "No compute run logged yet",
                               value: "this build has not run a compute yet", detail: nil)])
        }
        let rows = entries.suffix(shown).reversed().enumerated().map { i, e -> UsageState.Row in
            let day = MGFormat.shortDate(e.at, calendar: calendar)
            return UsageState.Row(id: "clog.\(i)", title: "\(day) \(MGFormat.time(e.at, calendar: calendar))",
                                  value: label(e.kind), detail: e.text.isEmpty ? nil : e.text)
        }
        return UsageState.Section(id: "computeLog", title: "Compute log", note: note, rows: Array(rows))
    }

    static func label(_ kind: String) -> String {
        switch kind {
        case Kind.runStart.rawValue: return "run started"
        case Kind.runEnd.rawValue: return "run ended"
        case Kind.runAbandoned.rawValue: return "run dropped as stuck"
        case Kind.dayStart.rawValue: return "day started"
        case Kind.dayEnd.rawValue: return "day finished"
        case Kind.processDied.rawValue: return "app closed mid-run"
        case Kind.launch.rawValue: return "app launched"
        default: return "note"
        }
    }
}
