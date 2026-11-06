import Foundation
import MGContext

// R7 / T23: the file behind `LaunchPreview` (MGContext): the front page's text as of the last finished refresh, read once
// at launch (a few hundred bytes, before anything else) and rewritten off the main actor when its text changes.
// It holds no raw data and is never sent anywhere.

enum LaunchPreviewFile {
    static var url: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("MG", isDirectory: true).appendingPathComponent("launch-preview.json")
    }

    /// nil when there is no file, it can't be read, or it is too old to show.
    static func load(now: Date) -> LaunchPreview? {
        guard let url, let data = try? Data(contentsOf: url), let p = LaunchPreview.decode(data), p.isFresh(at: now) else {
            return nil
        }
        return p
    }

    static func save(_ preview: LaunchPreview) {
        guard let url, let data = preview.encoded() else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
