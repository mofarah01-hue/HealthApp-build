import Foundation
import MGDomain
import WidgetKit

// WP-27 — where the widgets get their data: the app's snapshot + the lines still waiting in the queue, both in the
// App Group folder (ARCHITECTURE §4.11, §9.2). One provider serves the Home Screen and Lock Screen widgets.

struct QuickLogEntry: TimelineEntry {
    let date: Date
    let state: QuickLogState
}

/// The file reads. Everything that can go wrong maps to a state the widget shows in words; nothing is swallowed into a
/// plausible number (BRIEF "no fake numbers").
enum QuickLogSource {
    static func load() -> QuickLogLoad {
        guard let location = IntentsAppGroup.location(), location.shared else { return .noSharedStorage }
        let snapshot: WidgetSnapshot
        do {
            // nil = the app has never published; a throw = unreadable or a newer version than this build reads.
            guard let found = try WidgetSnapshotFile.read(from: location.directory) else { return .openMG }
            snapshot = found
        } catch {
            return .openMG
        }
        do {
            let waiting = try IntentsQueue(directory: location.directory).read()
            return .ready(QuickLogLoaded(snapshot: snapshot, pending: waiting.lines.map { $0.line }, pendingReadable: true))
        } catch {
            // The count is then "at least the stored count": the widget shows it with a "+".
            return .ready(QuickLogLoaded(snapshot: snapshot, pending: [], pendingReadable: false))
        }
    }
}

struct QuickLogProvider: TimelineProvider {
    typealias Entry = QuickLogEntry

    /// Gallery stand-in: the system draws it redacted (grey blocks), so no value in it is readable.
    func placeholder(in context: Context) -> QuickLogEntry {
        QuickLogEntry(date: Date(), state: .ready(.placeholder))
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickLogEntry) -> Void) {
        let now = Date()
        let state = QuickLogBuild.state(QuickLogSource.load(), at: now, calendar: .current)
        completion(QuickLogEntry(date: now, state: state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickLogEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        let load = QuickLogSource.load()

        var lastVapeAt: Date?
        var specials: [Date] = []
        if case .ready(let loaded) = load {
            let model = QuickLogBuild.model(loaded, at: now, calendar: calendar)
            lastVapeAt = model.lastVapeAt
            specials = loaded.snapshot.themeChanges.map { $0.at }
            if let due = model.med.nextDue { specials.append(due) }
        }

        let dates = QuickLogTimeline.entryDates(now: now, lastVapeAt: lastVapeAt, specials: specials, calendar: calendar)
        let entries = dates.map { QuickLogEntry(date: $0, state: QuickLogBuild.state(load, at: $0, calendar: calendar)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(QuickLogTimeline.horizon))))
    }
}
