import Foundation
import MGDomain

// Proposed by WP-18 (Log tab + Settings); added by WP-06 with main's OK, 2026-10-11.

/// Settings edits that carry a value (UX §14). The app validates, stores and re-publishes `SettingsState`.
public enum SettingEdit: Equatable, Sendable {
    /// One Profile row, by `LabeledValue.id` in `SettingsState.profile`
    /// ("birth_date" = YYYY-MM-DD, "sex" = male / female / other, "height_cm", "weight_kg", "hr_max", "hr_rest").
    /// `text` is what Mo typed; nil or empty clears the field. The app parses it; a text it can't parse is refused with a reason.
    case profileField(id: String, text: String?)
    /// Settings › Profile › "Use values from Apple Health (via your PC)" (tracker #90, 2026-10-11): GET /v1/profile,
    /// then only the EMPTY fields are filled (MGContext ProfileFill); what Mo typed is kept.
    case profileFromPC
    /// Sleep-need override in minutes; nil removes the override.
    case needOverride(minutes: Int?)
    /// Daily calorie burn goal for the Sundial ring; nil removes the goal.
    case calorieGoalKcal(Double?)
    /// Add (new id) or replace (same id) a medication / supplement schedule.
    case saveSchedule(MedSchedule)
    case removeSchedule(id: String)
    /// Add (new name) or replace (same name) a drink preset.
    case saveDrinkPreset(DrinkPreset)
    case removeDrinkPreset(name: String)
    /// T9746: add (new id) or replace (same id) an entry of Mo's Medications / Supplements list.
    case savePresetEntry(list: PresetListKind, entry: PresetEntry)
    /// T9746: add or replace an entry of Mo's Drinks list (full details).
    case saveDrinkEntry(DrinkEntry)
    case removePresetEntry(list: PresetListKind, id: String)
    /// Six Fitzpatrick quiz scores (1...6 each); nil clears the saved result.
    case skinTypeQuiz(answers: [Int]?)
    /// Hand-entered rough place; all nil clears it. The app validates and rounds coordinates to one decimal.
    case vitaminDLocation(name: String?, latitude: Double?, longitude: Double?)
    /// T9841 (R-099): skip (or stop skipping) one kind of notification; `kind` is a `NotifyKind` raw value
    /// (`NotificationSkips.all`). An alarm kind is refused.
    case notificationSkip(kind: String, skip: Bool)
    /// T9841 (R-097): the smart-wake mode (`SmartWakeModes.all` ids), the time-gate clock time (minutes after midnight,
    /// nil = not set) and the minimum rest share in percent (50...100). The app validates and clamps.
    case smartWake(mode: String, gateMinutes: Int?, restPercent: Int)
}
