import Foundation

/// One version of the app (app/docs/CHANGELOG.md, generated into `ReleaseNotes`).
public struct ReleaseNote: Equatable, Sendable {
    public let version: String
    public let name: String
    /// "Sun Oct 11, 2026, 10:29 PM", or "next, …" for a version planned but not built.
    public let when: String
    /// "202610112228", "—" (not recorded) or "stamped at build".
    public let build: String
    /// What CHANGELOG says about the install ("INSTALLED over the air", "NOT INSTALLED").
    public let install: String
    public let changes: [String]

    public init(version: String, name: String, when: String, build: String, install: String, changes: [String]) {
        self.version = version
        self.name = name
        self.when = when
        self.build = build
        self.install = install
        self.changes = changes
    }

    public var isPlanned: Bool { when.hasPrefix("next") }
}

/// Settings › About and its What's new screen (Mo, 2026-10-11 11:05 PM: "we need version names with what changed,
/// what was done, what's the newest build"). The installed version comes from the running app's Info.plist
/// (CFBundleShortVersionString, HAReleaseName, CFBundleVersion), never from the changelog.
public enum AboutPresenter {
    /// The placeholder CFBundleVersion in ios/xtool/Info.plist; ota_build.sh stamps a real yyyymmddHHMM over it.
    static let unstampedBuild = "1"

    /// "0.5.0" → "0.5", "0.3.1" stays, "1.0.0" → "1.0".
    public static func shortVersion(_ v: String) -> String {
        let parts = v.split(separator: ".")
        if parts.count == 3, parts[2] == "0" { return parts[0] + "." + parts[1] }
        return v
    }

    /// "HealthApp 0.5 'Your data, filled' · build 202610112345". The name falls back to the changelog's entry for the
    /// same version; a build that was never stamped says so instead of "build 1".
    public static func line(info: [String: Any]?, notes: [ReleaseNote] = ReleaseNotes.all) -> String {
        let app = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? "HealthApp"
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "\(app) (version unknown)" }
        let name = (info?["HAReleaseName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? note(for: version, in: notes)?.name
        let build = info?["CFBundleVersion"] as? String
        var s = "\(app) \(shortVersion(version))"
        if let name { s += " '\(name)'" }
        if let build, build != unstampedBuild, !build.isEmpty {
            s += " · build \(build)"
        } else {
            s += " · build not stamped"
        }
        return s
    }

    static func note(for version: String, in notes: [ReleaseNote]) -> ReleaseNote? {
        notes.first { shortVersion($0.version) == shortVersion(version) }
    }

    /// What's new: every version, newest first; the one this phone runs is marked "on this phone".
    public static func whatsNew(info: [String: Any]?, notes: [ReleaseNote] = ReleaseNotes.all) -> InfoScreenState {
        let installed = (info?["CFBundleShortVersionString"] as? String).map(shortVersion)
        let sections = notes.map { n -> InfoScreenState.Section in
            let here = installed == shortVersion(n.version)
            let note = here ? "on this phone" : (n.isPlanned ? "next" : n.install.lowercased())
            var meta = [n.isPlanned ? "Not built yet." : n.when]
            if n.build != "—", !n.isPlanned { meta.append("Build \(n.build)") }
            let head = InfoScreenState.Row(id: "\(n.version)-when", title: meta.joined(separator: " · "))
            let rows = n.changes.enumerated().map { i, c in InfoScreenState.Row(id: "\(n.version)-\(i)", title: c) }
            return InfoScreenState.Section(id: n.version, title: "\(shortVersion(n.version)) '\(n.name)'", note: note,
                                           rows: [head] + rows)
        }
        return InfoScreenState(sample: false, kicker: "Settings › About", title: "What's new",
                               summary: "Newest first. This phone: " + line(info: info, notes: notes) + ".",
                               sections: sections)
    }
}
