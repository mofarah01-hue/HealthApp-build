import Foundation
import MGContext
import MGDomain

/// The one place Settings builds the intents WP-06 added for WP-18 (`UIIntent.editSetting`, `.exportRange`, and the
/// `SettingEdit` enum in MGContext/Intent/EntryIntents.swift). If main renames one, this is the only file to change.
enum SettingsIntents {
    /// One Profile row by `LabeledValue.id`; nil text clears it. The app parses and validates.
    static func profile(id: String, text: String?) -> UIIntent { .editSetting(.profileField(id: id, text: text)) }

    /// Tracker #90: fill the empty profile fields from the PC's Apple Health values.
    static let profileFromPC: UIIntent = .editSetting(.profileFromPC)

    /// Sleep-need override in minutes; nil removes the override.
    static func needOverride(minutes: Int?) -> UIIntent { .editSetting(.needOverride(minutes: minutes)) }

    static func saveSchedule(_ schedule: MedSchedule) -> UIIntent { .editSetting(.saveSchedule(schedule)) }
    static func removeSchedule(id: String) -> UIIntent { .editSetting(.removeSchedule(id: id)) }

    /// Replaces a preset of the same name.
    static func savePreset(_ preset: DrinkPreset) -> UIIntent { .editSetting(.saveDrinkPreset(preset)) }
    static func removePreset(name: String) -> UIIntent { .editSetting(.removeDrinkPreset(name: name)) }

    static func skinType(answers: [Int]?) -> UIIntent { .editSetting(.skinTypeQuiz(answers: answers)) }
    static func vitaminDLocation(name: String?, latitude: Double?, longitude: Double?) -> UIIntent {
        .editSetting(.vitaminDLocation(name: name, latitude: latitude, longitude: longitude))
    }

    static func exportRange(from: LocalDay, to: LocalDay) -> UIIntent { .exportRange(from: from, to: to) }

    /// ARCHITECTURE §4.12 / main's rule (g): in SAMPLE mode only the Sample-data switch works.
    static let sampleReason = "Sample data is on, so settings can't be changed. Switch it off in Settings › Sample data."
}
