import Foundation
import MGDomain

// WP-24 — the App Group `pending-intents.jsonl` (ARCHITECTURE §4.11; noop's PendingIntents pattern,
// noop:StrandiOS/System/NOOPAppIntents.swift L8-58, here as a file of contract events instead of a UserDefaults array).
// Writers: the App Intents below (in the app process) and, later, WP-27's widgets / Control Center (their own process).
// Reader: the app, which drains it on launch, on foreground, on BLE wake and right after an intent appends.
//
// Extension-safe on purpose (Foundation + MGDomain only) so WP-27 can compile this file into the widget target.
//
// Durability: a line is written (and fsynced) before the intent answers; it leaves the file only after the app has
// stored it (or rejected it, in which case it moves to `pending-intents.rejected.jsonl` with the reason — never
// silently lost). Re-draining a line after a crash is harmless: the event keeps its id, and MGStore.upsertEvent with
// the same id and content changes nothing.

/// Where the request came from.
enum IntentsSurface: String, Codable, Sendable, CaseIterable {
    case shortcut = "shortcut"
    case widget = "widget"
    case control = "control"

    /// Contract `eventBase.source` (Control Center controls are WidgetKit: "widget").
    var eventSource: EventSource { self == .shortcut ? .shortcut : .widget }

    /// Contract vape `trigger`.
    var vapeTrigger: SubstanceFields.Vape.Trigger {
        switch self {
        case .shortcut: return .shortcut
        case .widget: return .widget
        case .control: return .control
        }
    }
}

/// What a line asks the app to do.
enum IntentsRequest: Equatable, Sendable {
    /// Store this event (fixed id, revision 1) — vape hit, drink start, medication, symptom, sleepiness, note.
    case event(EventRecord)
    /// Close the open caffeine drink at this time (the app finds it: `IntentsEvents.finishing`).
    case finishDrink(at: Date)
    /// Start a nap timer that began at `at` (the app owns the timer; a nap event needs its end, contract napEvent).
    case startNap(minutes: Int, at: Date)
    case syncNow

    var kindName: String {
        switch self {
        case .event: return "event"
        case .finishDrink: return "finish_drink"
        case .startNap: return "start_nap"
        case .syncNow: return "sync_now"
        }
    }
}

/// One line of pending-intents.jsonl: `{"v":1,"id":…,"created_at":…,"surface":…,"kind":…,"event"|"at"|"minutes":…}`.
struct IntentsPendingLine: Codable, Equatable, Sendable {
    static let version = 1

    var id: UUID
    var createdAt: Date
    var surface: IntentsSurface
    var request: IntentsRequest

    init(id: UUID = UUID(), createdAt: Date, surface: IntentsSurface, request: IntentsRequest) {
        self.id = id
        self.createdAt = createdAt
        self.surface = surface
        self.request = request
    }

    enum CodingKeys: String, CodingKey {
        case v = "v"
        case id = "id"
        case createdAt = "created_at"
        case surface = "surface"
        case kind = "kind"
        case event = "event"
        case at = "at"
        case minutes = "minutes"
    }

    struct BadLine: Error, CustomStringConvertible {
        var description: String
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == IntentsPendingLine.version else { throw BadLine(description: "unknown line version \(v)") }
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        surface = try c.decode(IntentsSurface.self, forKey: .surface)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "event":
            request = .event(try c.decode(EventRecord.self, forKey: .event))
        case "finish_drink":
            request = .finishDrink(at: try c.decode(Date.self, forKey: .at))
        case "start_nap":
            request = .startNap(minutes: try c.decode(Int.self, forKey: .minutes), at: try c.decode(Date.self, forKey: .at))
        case "sync_now":
            request = .syncNow
        default:
            throw BadLine(description: "unknown request kind \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(IntentsPendingLine.version, forKey: .v)
        // Lowercase, like EventRecord ids (MGDomain), so the PC and Python read one spelling.
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(surface, forKey: .surface)
        try c.encode(request.kindName, forKey: .kind)
        switch request {
        case .event(let e): try c.encode(e, forKey: .event)
        case .finishDrink(let at): try c.encode(at, forKey: .at)
        case .startNap(let minutes, let at):
            try c.encode(minutes, forKey: .minutes)
            try c.encode(at, forKey: .at)
        case .syncNow: break
        }
    }
}

/// Where the queue lives.
struct IntentsQueueLocation: Equatable, Sendable {
    var directory: URL
    /// true = the App Group container (widgets can write it); false = the app's own Application Support (the App
    /// Group isn't provisioned in this signature: in-app intents still work, widgets would not).
    var shared: Bool
    var problem: String?
}

enum IntentsAppGroup {
    /// The App Group this signature really has. AltStore / SideStore rename groups when re-signing and list the
    /// provisioned ones in `ALTAppGroups`; plain Xcode builds have only `AppGroupIdentifier` (project.yml).
    /// Logic ported from ryanbr/noop @ e580175 StrandiOSShared/WidgetSnapshot.swift L114-133 `resolveSuiteName`
    /// (PolyForm Noncommercial 1.0.0. Required Notice: Copyright 2026 NoopApp.), without noop's hard-coded fallback.
    static func groupIdentifier(info: [String: Any]) -> String? {
        let configured = (info["AppGroupIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let alt = ((info["ALTAppGroups"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("group.") }
        if let configured, !configured.isEmpty,
           let provisioned = alt.first(where: { $0 == configured || $0.hasPrefix(configured + ".") }) {
            return provisioned
        }
        if alt.count == 1 { return alt[0] }
        if let configured, !configured.isEmpty, !configured.contains("$(") { return configured }
        return nil
    }

    static func location(info: [String: Any] = Bundle.main.infoDictionary ?? [:],
                         fileManager: FileManager = .default) -> IntentsQueueLocation? {
        if let group = groupIdentifier(info: info),
           let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) {
            let dir = container.appendingPathComponent("MG", isDirectory: true)
            if (try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                return IntentsQueueLocation(directory: dir, shared: true, problem: nil)
            }
        }
        guard let support = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true) else { return nil }
        let dir = support.appendingPathComponent("MG/intents", isDirectory: true)
        guard (try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return IntentsQueueLocation(directory: dir, shared: false,
                                    problem: "App Group not provisioned in this signature: widgets can't log")
    }
}

/// The file itself. Every access is coordinated (NSFileCoordinator), because the widget process may append while
/// the app drains.
final class IntentsQueue: @unchecked Sendable {
    static let fileName = "pending-intents.jsonl"
    static let rejectedName = "pending-intents.rejected.jsonl"

    let fileURL: URL
    let rejectedURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(IntentsQueue.fileName)
        rejectedURL = directory.appendingPathComponent(IntentsQueue.rejectedName)
    }

    /// The queue at the resolved location; nil when not even Application Support is writable.
    static let shared: IntentsQueue? = IntentsAppGroup.location().map { IntentsQueue(directory: $0.directory) }

    struct Snapshot: Sendable {
        /// Decoded lines in file order, each with its exact text (to remove exactly that line later).
        var lines: [(line: IntentsPendingLine, raw: String)]
        /// Lines that did not decode, with why.
        var unreadable: [(raw: String, reason: String)]
    }

    /// Appends one line and syncs it to disk before returning.
    func append(_ line: IntentsPendingLine) throws {
        var data = try MGJSON.encoder().encode(line)
        data.append(0x0A)
        try coordinateWrite(fileURL) { url in
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else {
                    throw IntentsQueue.IOError(description: "could not create \(url.lastPathComponent)")
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
    }

    func read() throws -> Snapshot {
        var text = ""
        try coordinateRead(fileURL) { url in
            if let data = FileManager.default.contents(atPath: url.path) { text = String(decoding: data, as: UTF8.self) }
        }
        var snap = Snapshot(lines: [], unreadable: [])
        let decoder = MGJSON.decoder()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            do {
                let line = try decoder.decode(IntentsPendingLine.self, from: Data(raw.utf8))
                snap.lines.append((line: line, raw: raw))
            } catch {
                snap.unreadable.append((raw: raw, reason: String(describing: error)))
            }
        }
        return snap
    }

    /// Removes the handled lines (by exact text) and appends the rejected ones to the rejected file with their reason.
    /// Lines appended since `read()` are kept: the file is re-read inside the same coordinated write.
    func finish(removing handled: Set<String>, rejected: [(raw: String, reason: String)]) throws {
        if !rejected.isEmpty {
            var out = Data()
            let encoder = MGJSON.encoder()
            for r in rejected {
                var line = try encoder.encode(IntentsRejectedLine(reason: r.reason, line: r.raw))
                line.append(0x0A)
                out.append(line)
            }
            try coordinateWrite(rejectedURL) { url in
                let fm = FileManager.default
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: out)
                try handle.synchronize()
            }
        }
        guard !handled.isEmpty else { return }
        try coordinateWrite(fileURL) { url in
            guard let data = FileManager.default.contents(atPath: url.path) else { return }
            let keep = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                .filter { !handled.contains($0) }
            let body = keep.isEmpty ? "" : keep.joined(separator: "\n") + "\n"
            try Data(body.utf8).write(to: url, options: .atomic)
        }
    }

    struct IOError: Error, CustomStringConvertible { var description: String }

    private func coordinateWrite(_ url: URL, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { u in
            do { try body(u) } catch { bodyError = error }
        }
        if let e = coordError ?? bodyError { throw e }
    }

    private func coordinateRead(_ url: URL, _ body: (URL) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do { try body(u) } catch { bodyError = error }
        }
        if let e = coordError ?? bodyError { throw e }
    }
}

/// A line the app refused, kept for Mo to see (`pending-intents.rejected.jsonl`).
struct IntentsRejectedLine: Codable, Equatable, Sendable {
    var reason: String
    var line: String
}
