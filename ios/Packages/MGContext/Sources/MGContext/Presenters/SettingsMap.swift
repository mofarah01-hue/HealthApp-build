import Foundation

/// T10022 (round 8, r8p; UI-SCRUB-B section 7): two screens, two names. **Preferences** is you and how the app looks and
/// behaves (opened by the "M" circle on Today); **Settings** is the system and its connections (opened by the gear, and by
/// the first row of Preferences). This file is the one place that says which item lives on which screen, so a screen cannot
/// lose an item or draw it twice: both views draw `clusters(on:)` and nothing else, and the copy that sends Mo somewhere
/// ("Settings › Usage", "Preferences › Profile") is `reference(_:)`.
public enum SettingsScreenName: String, Sendable, CaseIterable {
    case preferences = "Preferences"
    case settings = "Settings"

    /// The other screen; the first row of each screen links to it.
    public var other: SettingsScreenName { self == .preferences ? .settings : .preferences }
}

/// Everything the old single Settings screen held, by the name it had there (31 items).
public enum SettingsItem: String, Sendable, CaseIterable, Identifiable {
    // You
    case profile, sunVitaminD, records
    /// Latest wake time per weekday, the smart-wake window and the sleep need (one section).
    case sleepWake
    case medications, drinkPresets, presetLists
    // Look
    case frontPage, theme, topBar, workingOn, quickLog, notifications, researchRows
    // Connections
    case pcLab, strapSync, decodeLab, appleHealth, shortcuts, places, alarms, usage, modelStatus, commandTest, ringLab
    /// Screen Time (Family Controls); listed on every build, says so when the build cannot do it (Mac build, Nov 2026).
    case screenTime
    // Data, lab, about
    case privacy, export, sampleData, methods, tests, about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profile: return "Profile"
        case .sunVitaminD: return "Sun vitamin D"
        case .records: return "Records"
        case .sleepWake: return "Sleep & wake"
        case .medications: return "Medications & supplements"
        case .drinkPresets: return "Drink presets"
        case .presetLists: return "Preset lists"
        case .frontPage: return "Front page"
        case .theme: return "Theme"
        case .topBar: return "Top bar"
        case .workingOn: return "Working on"
        case .quickLog: return "Quick-log surfaces"
        case .notifications: return "Notifications"
        case .researchRows: return "Show research rows"
        case .pcLab: return "PC Lab"
        case .strapSync: return "Strap & sync"
        case .decodeLab: return "Decode lab"
        case .appleHealth: return "Apple Health"
        case .shortcuts: return "Shortcuts"
        case .places: return "Places"
        case .alarms: return "Alarms"
        case .usage: return "Usage"
        case .modelStatus: return "Model status"
        case .commandTest: return "Command test"
        case .ringLab: return "Ring lab"
        case .screenTime: return "Screen Time"
        case .privacy: return "Privacy"
        case .export: return "Export"
        case .sampleData: return "Sample data"
        case .methods: return "Methods"
        case .tests: return "Tests"
        case .about: return "About"
        }
    }

    /// Where it lives now.
    public var screen: SettingsScreenName {
        switch self {
        case .profile, .sunVitaminD, .records, .sleepWake, .medications, .drinkPresets, .presetLists,
             .frontPage, .theme, .topBar, .workingOn, .quickLog, .notifications, .researchRows:
            return .preferences
        case .pcLab, .strapSync, .decodeLab, .appleHealth, .shortcuts, .places, .alarms, .usage, .modelStatus,
             .commandTest, .ringLab, .screenTime, .privacy, .export, .sampleData, .methods, .tests, .about:
            return .settings
        }
    }
}

/// One drawn block: a section of its own, or the single "More screens" list (S7: five header-plus-one-row sections became
/// one list).
public enum SettingsBlock: Equatable, Sendable, Identifiable {
    case item(SettingsItem)
    case moreScreens([SettingsItem])

    public var id: String {
        switch self {
        case .item(let i): return i.id
        case .moreScreens: return "moreScreens"
        }
    }

    public var items: [SettingsItem] {
        switch self {
        case .item(let i): return [i]
        case .moreScreens(let list): return list
        }
    }
}

/// A heading with its blocks; the index chip and the heading under it use the same `label` (R8e S2).
public struct SettingsClusterSpec: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var blocks: [SettingsBlock]
}

public enum SettingsMap {
    public static func clusters(on screen: SettingsScreenName) -> [SettingsClusterSpec] {
        switch screen {
        case .preferences:
            return [
                SettingsClusterSpec(id: "you", label: "YOU", blocks: [
                    .item(.profile), .item(.sunVitaminD), .item(.records), .item(.sleepWake), .item(.medications),
                    .item(.drinkPresets), .item(.presetLists)]),
                SettingsClusterSpec(id: "look", label: "LOOK", blocks: [
                    .item(.frontPage), .item(.theme), .item(.topBar), .item(.workingOn), .item(.quickLog),
                    .item(.notifications), .item(.researchRows)]),
            ]
        case .settings:
            return [
                // Nov 6 2026 (one settings page): the strap's page is the DEVICE section here, first; the Today strap chip opens
                // Settings scrolled to it. It used to be a row of "More screens" that opened a second screen.
                SettingsClusterSpec(id: "device", label: "DEVICE", blocks: [.item(.strapSync)]),
                SettingsClusterSpec(id: "connections", label: "CONNECTIONS", blocks: [
                    .item(.pcLab),
                    .moreScreens([.alarms, .places, .usage, .appleHealth, .shortcuts, .decodeLab,
                                  .modelStatus, .commandTest, .ringLab, .screenTime])]),

                SettingsClusterSpec(id: "data", label: "DATA", blocks: [
                    .item(.privacy), .item(.export), .item(.sampleData)]),
                SettingsClusterSpec(id: "lab", label: "LAB", blocks: [.item(.methods), .item(.tests)]),
                SettingsClusterSpec(id: "about", label: "ABOUT", blocks: [.item(.about)]),
            ]
        }
    }

    /// Every item a screen draws, in order.
    public static func items(on screen: SettingsScreenName) -> [SettingsItem] {
        clusters(on: screen).flatMap { $0.blocks.flatMap(\.items) }
    }

    /// How copy points at an item: "Settings › Usage", "Preferences › Profile".
    public static func reference(_ item: SettingsItem) -> String {
        item.screen.rawValue + " › " + item.title
    }

    /// The first row of each screen: "Preferences ›" on Settings, "Settings ›" on Preferences.
    public static func crossLinkTitle(on screen: SettingsScreenName) -> String {
        screen.other.rawValue + " ›"
    }

    public static func crossLinkDetail(on screen: SettingsScreenName) -> String {
        screen == .settings
            ? "You and how the app looks: profile, sleep and wake, medications, theme, front page, notifications."
            : "Connections and the system: PC Lab, strap, Apple Health, alarms, usage, export, tests, About."
    }
}

/// S8 (r9v): the old 1.5 MB-a-day guess was never measured and is gone; the real size is reported after the export
/// (`ExportFolderDocument.byteCount`, shown in the "Exported ..." notice).
public enum ExportEstimate {
    /// `ExportBuilder` refuses more than this many days at once.
    public static let maxDays = 366
}
