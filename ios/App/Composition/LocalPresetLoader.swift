import Foundation
import MGContext

// T9973 / T9746 — where the user's own starting lists come from. Personal medication and drink names are not written in
// source, tests or docs; they live in a JSON file that is NOT in the repo (`ios/local/local-presets.json`, git-ignored).
// Format and rules: `LocalPresetFile` (MGContext). The app reads, in this order:
//   1. Application Support/local-presets.json  (copy the file onto the phone; wins when both exist)
//   2. the app bundle's local-presets.json     (a build that found ios/local/local-presets.json packs it, project.yml)
// A missing or unreadable file is "no seed": nothing is shown wrongly and nothing is marked as seeded.

enum LocalPresetLoader {
    /// The product names the user logs the ALG-143 compound under (file key "medicationAliases" -> "lisdexamfetamine");
    /// read once, empty without the file.
    static let lisdexAliases: [String] = load()?.aliases(for: "lisdexamfetamine") ?? []

    static func load(bundle: Bundle = .main, fileManager: FileManager = .default) -> LocalPresetFile? {
        for url in candidates(bundle: bundle, fileManager: fileManager) {
            guard let data = try? Data(contentsOf: url), let file = LocalPresetFile.decode(data) else { continue }
            return file
        }
        return nil
    }

    static func candidates(bundle: Bundle, fileManager: FileManager) -> [URL] {
        var out: [URL] = []
        if let support = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                              create: false) {
            out.append(support.appendingPathComponent(LocalPresetFile.fileName))
        }
        if let bundled = bundle.url(forResource: "local-presets", withExtension: "json") { out.append(bundled) }
        return out
    }
}
