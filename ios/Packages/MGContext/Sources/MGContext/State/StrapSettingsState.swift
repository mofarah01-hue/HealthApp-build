import Foundation
import MGDomain

/// Strap & sync sheet (UX §14): strap, history, write log, unlock, broadcast, PC Lab, Apple Health.
/// One line of the sync panel.
public struct SyncPanelRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var value: String
    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// The sync panel in Strap & sync (P9734): a headline, the rows for each half, the banner, and two buttons.
public struct SyncPanelState: Equatable, Sendable {
    /// "PC not receiving since 2:21 AM"; nil = nothing stuck.
    public var banner: String?
    /// Always visible, panel closed: "Online · 0 waiting" / "Offline · 3 drops (412 KB) waiting · next try 2:21 AM".
    public var headline: String
    public var strapToPhone: [SyncPanelRow]
    public var phoneToPC: [SyncPanelRow]
    public var syncNow: ActionState
    public var reset: ActionState
    public init(banner: String?, headline: String, strapToPhone: [SyncPanelRow], phoneToPC: [SyncPanelRow],
                syncNow: ActionState, reset: ActionState) {
        self.banner = banner
        self.headline = headline
        self.strapToPhone = strapToPhone
        self.phoneToPC = phoneToPC
        self.syncNow = syncNow
        self.reset = reset
    }
}

public struct StrapSyncState: Equatable, Sendable {
    public var sample: Bool
    /// Bond, battery, firmware, wear location, last record.
    public var strapRows: [LabeledValue]
    public var changeWearLocation: ActionState
    /// "Pair strap" / "Connect strap" / "Looking for your strap…"; nil once connected. Added 2026-10-11: the sheet
    /// had no way to start the link.
    public var connect: ActionState?
    /// "up to date" / "62 % · 3 h 10 of 5 h".
    public var historyLine: String
    public var historyProgress: Double?
    /// "last chunk acked 09:40 after it was stored".
    public var lastAckLine: String?
    /// "clock set ×1 today ›".
    public var writeLogLine: String
    /// R22 research stream (2026-10-11): "Turn on R22" — one write, enable_r22_packets = '1', behind the confirm sheet.
    public var unlock: ActionState
    /// "on ('1') · read 09:40" / "off ('2') · read 09:40" / "not read yet".
    public var unlockStatus: String
    /// Writes the value saved before the R22 write back (confirm sheet too).
    public var restoreR22: ActionState?
    /// After the write: "R22 records arriving …" / "waiting for …" / "R22 enabled but no R22 records yet — …".
    public var r22WatchLine: String?
    /// "Phone cleanup 09:40: removed …" — only PC-confirmed data older than 30 days; nil before the first one.
    public var cleanupLine: String?
    /// "Raw optical (uses strap battery)". STALE (marked at the W10 merge, 2026-10-11 11:20 PM): this said "off by
    /// default"; since W11 (9:43 PM, Mo: "Default on") it is on by default.
    public var rawOptical: ToggleState?
    /// "streaming · 312 records · last 09:40" / "off" / "stopped by the watchdog: …".
    public var rawOpticalLine: String?
    /// Wave 4 (#65): "At night too, in the background" (was "Nights only, in the background" until the W10 merge) under
    /// the raw optical switch, and its plain lines (schedule, what runs, the measured battery cost).
    public var rawOpticalNights: ToggleState?
    public var rawOpticalNightLines: [String] = []
    /// T124: "In workouts too, in the background" (the periodic and still-wrist windows are set through the same intent).
    public var rawOpticalWorkout: ToggleState?
    /// T124: current "every X" schedule, worded for the picker button ("Off" / "Every 10 min" / …).
    public var rawOpticalEveryLabel: String = "Off"
    /// T124: the picker's rows (one per preset); each already carries the current `rawOpticalInWorkout` /
    /// `rawOpticalWhenStill` in its intent, so picking one cannot disturb the other two settings.
    public var rawOpticalEveryOptions: [ActionState] = []
    /// T124: "When the wrist is still" (RawOpticalWindows.isStill), alongside the workout toggle.
    public var rawOpticalWhenStill: ToggleState?
    /// "ECG (MG)" and "Raw motion (100 Hz)" (wave W8, 2026-10-11; set after init). STALE (marked at the W10 merge,
    /// 11:20 PM): this said "each off by default"; since W11 (9:43 PM) both are on by default.
    public var ecgMotion: EcgMotionSection?
    /// "Hand the strap back to WHOOP" (wave W12b, #103) and the last hand-back's summary (set after init).
    public var handBack: ToggleState?
    /// 0.6.0.3 Ring live: the "Input device" picker (set after init).
    public var inputDevice: InputDeviceSection?
    public var handBackLines: [String] = []
    /// r9q: Strap & sync › automatic raw streams (set after init).
    public var autoRaw: AutoRawSection?
    /// 0.6.0.12: "Read WHOOP 5.0 heart-rate broadcast" (set after init).
    public var hrRead: HRReadSection?
    /// "MG" or "WHOOP 4.0": the chosen device, for the sheet title (set after init).
    public var deviceName = "MG"
    public var broadcast: ToggleState
    public var pcState: SyncState
    /// P9734: the expandable sync panel (strap to phone, phone to PC) with "Sync now" and "Reset"; nil = hidden.
    public var syncPanel: SyncPanelState?
    /// "PC Lab not set up — everything runs on the phone." / "PC got 3 h · 412 KB · 09:40".
    public var pcLine: String
    public var unsyncedLine: String?
    public var pair: ActionState
    /// Granted types, last read; or "Apple Health isn't available in this build".
    public var healthLines: [String]
    /// Strap settings (117/118/128 snapshot, added 2026-10-11): "read 09:40 · 25 keys · fw 50.42.1.0", or why none.
    public var settingsLine: String
    /// One row per key of the newest snapshot, in the strap's own order.
    public var settingsRows: [StrapSettingRow]
    /// "Read strap settings" (reads only; nothing is written).
    public var readSettings: ActionState

    public init(sample: Bool, strapRows: [LabeledValue], changeWearLocation: ActionState, historyLine: String,
                historyProgress: Double?, lastAckLine: String?, writeLogLine: String, unlock: ActionState,
                unlockStatus: String, broadcast: ToggleState, pcState: SyncState, pcLine: String,
                unsyncedLine: String?, pair: ActionState, healthLines: [String], connect: ActionState? = nil,
                settingsLine: String = "Not read yet.", settingsRows: [StrapSettingRow] = [],
                readSettings: ActionState = ActionState(id: "readSettings", title: "Read strap settings",
                                                        intent: nil, enabled: false,
                                                        disabledReason: "Not available here."),
                restoreR22: ActionState? = nil, rawOptical: ToggleState? = nil, rawOpticalLine: String? = nil,
                r22WatchLine: String? = nil, cleanupLine: String? = nil) {
        self.sample = sample
        self.strapRows = strapRows
        self.changeWearLocation = changeWearLocation
        self.historyLine = historyLine
        self.historyProgress = historyProgress
        self.lastAckLine = lastAckLine
        self.writeLogLine = writeLogLine
        self.unlock = unlock
        self.unlockStatus = unlockStatus
        self.broadcast = broadcast
        self.pcState = pcState
        self.pcLine = pcLine
        self.unsyncedLine = unsyncedLine
        self.pair = pair
        self.healthLines = healthLines
        self.connect = connect
        self.settingsLine = settingsLine
        self.settingsRows = settingsRows
        self.readSettings = readSettings
        self.restoreR22 = restoreR22
        self.rawOptical = rawOptical
        self.rawOpticalLine = rawOpticalLine
        self.r22WatchLine = r22WatchLine
        self.cleanupLine = cleanupLine
    }
}

/// One strap feature flag as read (GET_FF_VALUE 128): the key, the value text, and why there is no value.
public struct StrapSettingRow: Equatable, Sendable, Identifiable {
    public var key: String
    /// "1", "2", "0" … or "—" when no value was accepted.
    public var value: String
    /// nil when the value was accepted; else "FAILURE", "key not echoed", "no reply" …
    public var note: String?

    public init(key: String, value: String, note: String?) {
        self.key = key
        self.value = value
        self.note = note
    }

    public var id: String { key }
}

/// Settings (UX §14), pushed from "M".
public struct SettingsState: Equatable, Sendable {
    public var sample: Bool
    public var profile: [LabeledValue]
    /// "Must be up by" per weekday; blank until Mo fills it (BRIEF default 3).
    public var latestWake: [WeekdayWake]
    /// 10…45, default 30.
    public var wakeWindowMinutes: Int
    public var needOverride: DisplayValue?
    public var schedules: [ScheduleRow]
    public var drinkPresets: [DrinkPreset]
    /// Widget, Action Button, double-tap action ("Double-tap logs a vape hit").
    public var quickLogSurfaces: [ToggleState]
    /// Quiet hours, daily cap — PLACEHOLDERS until Mo sets the notification policy (contract TODO).
    public var notificationRows: [LabeledValue]
    public var notificationToggles: [ToggleState]
    public var notificationsArePlaceholders: Bool
    public var theme: ThemeSetting
    public var researchRowsShown: Bool
    /// T142: the "Working on:" strip is hidden. Set after construction so the many inits stay as they are.
    public var hideWorkingBars: Bool = false
    /// "MG" or "WHOOP 4.0": the chosen device, for the Strap & sync row (set after init).
    public var deviceName = "MG"
    /// T9972: Settings > About line naming the PC's primary map in force ("Algorithm map 6d884b22 from the PC: ...").
    public var primaryMapLine: String = ""
    /// r8h T5: "online" / "offline" / "not paired" / "pairing…" / "error"; "" = unknown (not shown).
    public var pcStatusWord: String = ""
    public var droppedMethodsCount: Int
    /// Off by default; on = every screen shows the SAMPLE banner.
    public var sampleData: Bool
    public var privacyLines: [String]
    public var export: ActionState
    /// Tracker #42 (2026-10-11): injuries (Log › More › Health record, kind injury) with dates and status, and body
    /// composition (InBody / DEXA / tape) with their typed numbers, newest first. Read only while Settings is open.
    public var injuries: [LabeledValue] = []
    public var bodyComposition: [LabeledValue] = []
    /// Inputs for the sunlight vitamin D estimate, entered without location services.
    public var fitzpatrickSkinType: Int?
    public var vitaminDLocation: VitaminDRoughLocation?

    /// T9746: Mo's Medications / Supplements / Drinks lists (editable in Settings).
    public var presetLists = PresetLists()

    /// T9841: one "Skip: ..." switch per notification kind (Settings › Notifications).
    public var notificationSkips: [ToggleState] = []

    /// T9841: the smart-wake mode (`SmartWakeModes` id), the time gate and the minimum rest share.
    public var smartWakeMode = SmartWakeModes.defaultID
    public var smartWakeGateMinutes: Int?
    public var smartWakeRestPercent = SmartWakeModes.defaultRestPercent

    func withSmartWake(mode: String, gateMinutes: Int?, restPercent: Int) -> SettingsState {
        var c = self
        c.smartWakeMode = SmartWakeModes.isValid(mode) ? mode : SmartWakeModes.defaultID
        c.smartWakeGateMinutes = gateMinutes
        c.smartWakeRestPercent = min(max(restPercent, SmartWakeModes.restPercentRange.lowerBound),
                                     SmartWakeModes.restPercentRange.upperBound)
        return c
    }

    func withNotificationSkips(_ skipped: Set<String>) -> SettingsState {
        var c = self
        c.notificationSkips = NotificationSkips.toggles(skipped: skipped)
        return c
    }

    func withPresetLists(_ lists: PresetLists) -> SettingsState {
        var c = self
        c.presetLists = lists
        return c
    }

    func withPrimaryMapLine(_ line: String) -> SettingsState {
        var c = self
        c.primaryMapLine = line
        return c
    }

    /// r8h T5: the PC Lab row shows where the PC stands ("online" / "offline" / "not paired").
    func withPCStatus(_ state: SyncState) -> SettingsState {
        var c = self
        switch state {
        case .notSetUp: c.pcStatusWord = "not paired"
        case .pairing: c.pcStatusWord = "pairing…"
        case .offline: c.pcStatusWord = "offline"
        case .online: c.pcStatusWord = "online"
        case .error: c.pcStatusWord = "error"
        }
        return c
    }

    func withHideWorkingBars(_ on: Bool) -> SettingsState {
        var c = self
        c.hideWorkingBars = on
        return c
    }

    func withProfileRecords(_ s: PresenterSnapshot) -> SettingsState {
        var c = self
        c.injuries = ProfileRecords.injuries(s)
        c.bodyComposition = (ProfileRecords.tapeEstimate(s).map { [$0] } ?? []) + ProfileRecords.bodyComposition(s)
        return c
    }

    public init(sample: Bool, profile: [LabeledValue], latestWake: [WeekdayWake], wakeWindowMinutes: Int,
                needOverride: DisplayValue?, schedules: [ScheduleRow], drinkPresets: [DrinkPreset],
                quickLogSurfaces: [ToggleState], notificationRows: [LabeledValue], notificationToggles: [ToggleState],
                notificationsArePlaceholders: Bool,
                theme: ThemeSetting, researchRowsShown: Bool, droppedMethodsCount: Int, sampleData: Bool,
                privacyLines: [String], export: ActionState, fitzpatrickSkinType: Int? = nil,
                vitaminDLocation: VitaminDRoughLocation? = nil) {
        self.sample = sample
        self.profile = profile
        self.latestWake = latestWake
        self.wakeWindowMinutes = wakeWindowMinutes
        self.needOverride = needOverride
        self.schedules = schedules
        self.drinkPresets = drinkPresets
        self.quickLogSurfaces = quickLogSurfaces
        self.notificationRows = notificationRows
        self.notificationToggles = notificationToggles
        self.notificationsArePlaceholders = notificationsArePlaceholders
        self.theme = theme
        self.researchRowsShown = researchRowsShown
        self.droppedMethodsCount = droppedMethodsCount
        self.sampleData = sampleData
        self.privacyLines = privacyLines
        self.export = export
        self.fitzpatrickSkinType = fitzpatrickSkinType
        self.vitaminDLocation = vitaminDLocation
    }
}

public struct ScheduleRow: Equatable, Sendable, Identifiable {
    public var id: String
    /// "MedA 20 mg".
    public var title: String
    /// "daily · 07:15".
    public var detail: String
    public var isSupplement: Bool
    /// The schedule itself, so the editor opens with every field (dose, days, purpose, dates; tracker #42, 2026-10-11 —
    /// before, it rebuilt the schedule from `title` / `detail` and lost dose and days on an edit).
    public var schedule: MedSchedule?

    public init(id: String, title: String, detail: String, isSupplement: Bool, schedule: MedSchedule? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isSupplement = isSupplement
        self.schedule = schedule
    }
}

public struct DrinkPreset: Equatable, Sendable, Identifiable {
    public var name: String
    public var caffeineMg: Double

    public init(name: String, caffeineMg: Double) {
        self.name = name
        self.caffeineMg = caffeineMg
    }

    public var id: String { name }
}
