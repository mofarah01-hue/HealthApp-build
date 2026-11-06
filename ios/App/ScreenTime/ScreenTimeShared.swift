import Foundation

// Screen Time (Mac build, Nov 2026): the one file the app and the Activity Monitor extension both compile (Foundation only,
// no FamilyControls, no MGDomain: an extension has a small memory budget). The extension appends what iOS tells it
// (a threshold passed, a schedule started or ended) to a JSON-lines file in the App Group container; the app reads it,
// turns thresholds into `screen_time` events (AppModel+ScreenTime) and shows them. The extension never reads anything back.
//
// Nothing here is a usage total: iOS tells the extension only that a threshold was crossed.

enum ScreenTimeShared {
    static let fileName = "screen-time-events.jsonl"
    /// Records older than this are dropped when the extension appends (the extension is the only writer).
    static let keepDays = 30.0

    struct Record: Codable, Equatable {
        /// "threshold", "interval_start" or "interval_end".
        var kind: String
        /// The schedule the callback came from ("day", "evening", "night").
        var activity: String
        /// The event name for a threshold ("st.evening.60"); nil for interval marks.
        var event: String?
        var at: Date
    }

    /// `AppGroupIdentifier` in this bundle's Info.plist (project.yml sets the same id on the app and both extensions).
    static func groupIdentifier(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String? {
        let id = (info["AppGroupIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id, !id.isEmpty, !id.contains("$(") else { return nil }
        return id
    }

    /// nil = the App Group is not provisioned in this signature (the app says so on the Screen Time page).
    static func fileURL(fileManager: FileManager = .default) -> URL? {
        guard let group = groupIdentifier(),
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let dir = container.appendingPathComponent("MG", isDirectory: true)
        guard (try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return dir.appendingPathComponent(fileName)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func parse(_ data: Data) -> [Record] {
        let dec = decoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? dec.decode(Record.self, from: Data($0)) }
    }

    /// Every record in the file, oldest first. A line that does not decode is skipped (never fatal).
    static func readAll() -> [Record] {
        guard let url = fileURL() else { return [] }
        var out: [Record] = []
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            if let data = try? Data(contentsOf: u) { out = parse(data) }
        }
        return out
    }

    /// Extension side: add one record, drop the ones past `keepDays`. Returns false when it could not be written.
    @discardableResult
    static func append(_ record: Record, now: Date = Date()) -> Bool {
        guard let url = fileURL() else { return false }
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &err) { u in
            let cutoff = now.addingTimeInterval(-keepDays * 86_400)
            var records = ((try? Data(contentsOf: u)).map(parse) ?? []).filter { $0.at >= cutoff }
            records.append(record)
            let enc = encoder()
            var out = Data()
            for r in records {
                if let line = try? enc.encode(r) { out.append(line); out.append(UInt8(ascii: "\n")) }
            }
            ok = (try? out.write(to: u, options: .atomic)) != nil
        }
        return ok && err == nil
    }
}
