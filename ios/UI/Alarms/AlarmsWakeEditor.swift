import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// "Must be up by" for the Alarms page (T151). A copy of Settings' wake editor with the 12-hour AM/PM wheel; the
/// Settings one (SettingsEditors.swift, not owned by the alarms work) still uses en_GB (24-hour).
struct AlarmsWakeEditor: View {
    let weekday: Int
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(weekday: Int, current: [WeekdayWake], canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.weekday = weekday
        self.canEdit = canEdit
        self.send = send
        _days = State(initialValue: [weekday])
        let existing = current.first(where: { $0.weekday == weekday })?.time
        let base = Calendar.current.date(bySettingHour: existing?.hour ?? 7, minute: existing?.minute ?? 0, second: 0,
                                         of: Date()) ?? Date()
        _time = State(initialValue: base)
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @State private var days: Set<Int>
    @State private var time: Date

    var body: some View {
        SettingsSheetFrame(title: "Must be up by", canSave: canEdit && !days.isEmpty,
                           reason: canEdit ? "Pick at least one day." : SettingsIntents.sampleReason,
                           onSave: save) {
            LogFormLabel("Days")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(SettingsWeekday.order, id: \.self) { day in
                    Chip(SettingsWeekday.short[day] ?? "", selected: days.contains(day)) {
                        if days.contains(day) {
                            if days.count > 1 { _ = days.remove(day) }
                        } else {
                            _ = days.insert(day)
                        }
                    }
                }
            }
            AlarmsTimeWheel(time: $time)
            LogHint("Smart wake rings by this time. A blank day means no wake plan that morning.")
            MGButton("Clear these days", style: .ghost) {
                for day in days.sorted() { send(.setLatestWake(weekday: day, time: nil)) }
                dismiss()
            }
            .disabled(!canEdit)
            .opacity(canEdit ? 1 : 0.4)
        }
    }

    private func save() {
        guard canEdit else { return }
        let c = calendar.dateComponents([.hour, .minute], from: time)
        let value = TimeOfDay(hour: c.hour ?? 7, minute: c.minute ?? 0)
        for day in days.sorted() { send(.setLatestWake(weekday: day, time: value)) }
    }
}
