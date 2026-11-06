import Foundation
import MGContext
import MGDomain
import MGStore
import SwiftUI
import UniformTypeIdentifiers

// WP-23a — Settings › Export (APP-114, ARCHITECTURE §4.12): the PC Lab layout for a date range — `days/<date>/summary.json`,
// `events.jsonl`, `series.json` (the same bytes as a day drop: MGStore `dayBundle`) and `days/<date>/streams/<kind>.csv`
// (MGStore `streamCSV`, uncompressed; the sync upload deflates them) — handed to the system exporter as one folder, plus `kv/kv.json` (the key-value area, KeyValueExport; bug 31).
//
// WRITTEN, NOT COMPILED.

enum ExportBuilder {
    static func build(store: MGStore, from: LocalDay, to: LocalDay, calendar: Calendar) async throws -> FileWrapper {
        var dayFolders: [String: FileWrapper] = [:]
        var day = from
        while day <= to {
            let bundle = try await store.dayBundle(day)
            let start = Int64(day.start(in: calendar.timeZone).timeIntervalSince1970)
            let end = Int64(day.adding(days: 1).start(in: calendar.timeZone).timeIntervalSince1970) - 1
            var streams: [String: FileWrapper] = [:]
            for kind in StreamKind.allCases {
                let csv = try await store.streamCSV(kind, from: start, to: end)
                streams["\(kind.rawValue).csv"] = FileWrapper(regularFileWithContents: csv)
            }
            let folder = FileWrapper(directoryWithFileWrappers: [
                "summary.json": FileWrapper(regularFileWithContents: bundle.summary),
                "events.jsonl": FileWrapper(regularFileWithContents: bundle.events),
                "series.json": FileWrapper(regularFileWithContents: bundle.series),
                "streams": FileWrapper(directoryWithFileWrappers: streams),
            ])
            dayFolders[day.iso] = folder
            day = day.adding(days: 1)
        }
        // Bug 31 (2026-10-14): the phone's key-value area (profile and the like) as kv/kv.json, sizes included.
        let kv = try KeyValueExport.data(try await store.allKeyValues())
        return FileWrapper(directoryWithFileWrappers: [
            "days": FileWrapper(directoryWithFileWrappers: dayFolders),
            "kv": FileWrapper(directoryWithFileWrappers: ["kv.json": FileWrapper(regularFileWithContents: kv)]),
        ])
    }
}

/// The folder for `.fileExporter`. Export only: it is never read back.
struct ExportFolderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    static var writableContentTypes: [UTType] { [.folder] }

    var name: String
    var folder: FileWrapper

    init(name: String, folder: FileWrapper) {
        self.name = name
        self.folder = folder
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { folder }

    /// r9v (S8): the real size of the files this export writes: the sum of every file's bytes in the folder.
    var byteCount: Int { Self.bytes(of: folder) }

    private static func bytes(of wrapper: FileWrapper) -> Int {
        if wrapper.isRegularFile { return wrapper.regularFileContents?.count ?? 0 }
        return (wrapper.fileWrappers ?? [:]).values.reduce(0) { $0 + bytes(of: $1) }
    }
}
