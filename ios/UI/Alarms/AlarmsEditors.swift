import SwiftUI
import MGContext
import MGDesign
import MGDomain

// The alarm page's editor sheets (added 2026-10-11). Each sends ONE intent on Save and closes (SettingsSheetFrame).

/// A wall-clock time picker (12 h with AM/PM) and its minutes after midnight.
private func minutes(of date: Date, _ cal: Calendar) -> Int {
    let c = cal.dateComponents([.hour, .minute], from: date)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

private func date(minutes m: Int, _ cal: Calendar) -> Date {
    cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
}

/// A 12-hour AM/PM wheel time picker (T151: it was en_GB, which shows 24-hour time).
struct AlarmsTimeWheel: View {
    @Binding var time: Date

    var body: some View {
        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
            .labelsHidden()
            .environment(\.locale, AlarmTimeLocale.picker)
            .frame(maxWidth: .infinity, maxHeight: 130)
    }
}

// MARK: - Match Pillars

struct AlarmsPillarsEditor: View {
    let send: (UIIntent) -> Void
    @Environment(\.calendar) private var calendar
    @State private var time = Calendar.current.date(bySettingHour: 5, minute: 42, second: 0, of: Date()) ?? Date()

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsSheetFrame(title: "Match Pillars", saveTitle: "Match", canSave: true, reason: nil,
                           onSave: { send(.alarms(.matchPillars(fajrMinutes: minutes(of: time, calendar)))) }) {
            LogFormLabel("Today's Fajr as Pillars shows it")
            AlarmsTimeWheel(time: $time)
            LogHint("Every standard method is worked out for today at your saved location; the one within 2 min is "
                    + "offered. Use the phone's location first.")
        }
    }
}

// MARK: - Timer
// Retired (T153, 2026-10-12): the timer sheet is `TimersStartEditor` in UI/Timers/TimersSection.swift.

// MARK: - Custom alarm

struct AlarmsCustomEditor: View {
    let existing: CustomAlarm?
    let send: (UIIntent) -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var time: Date
    @State private var days: Set<Int>
    @State private var onceDay: Date
    @State private var pulses: Int
    @State private var repeatUntilMoving: Bool
    @State private var phoneBackstop: Bool

    init(alarm: CustomAlarm?, send: @escaping (UIIntent) -> Void) {
        existing = alarm
        self.send = send
        let cal = Calendar.current
        _label = State(initialValue: alarm?.label ?? "")
        _time = State(initialValue: date(minutes: alarm?.minutes ?? 7 * 60, cal))
        _days = State(initialValue: alarm?.weekdays ?? [])
        let once = alarm?.day.flatMap(LocalDay.init(iso:))?.start(in: cal.timeZone).addingTimeInterval(43_200)
        _onceDay = State(initialValue: once ?? cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        _pulses = State(initialValue: alarm?.pulses ?? 4)
        _repeatUntilMoving = State(initialValue: alarm?.repeatUntilMoving ?? false)
        _phoneBackstop = State(initialValue: alarm?.phoneBackstop ?? true)
    }

    var body: some View {
        SettingsSheetFrame(title: existing == nil ? "New alarm" : "Alarm", canSave: true, reason: nil, onSave: save) {
            TextField("Name", text: $label)
                .textFieldStyle(.roundedBorder)
                .formSubmit()                  // r9v (K1)
            AlarmsTimeWheel(time: $time)
            LogFormLabel("Days (none = once)")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(SettingsWeekday.order, id: \.self) { d in
                    Chip(SettingsWeekday.short[d] ?? "", selected: days.contains(d)) {
                        if days.contains(d) { days.remove(d) } else { days.insert(d) }
                    }
                }
            }
            if days.isEmpty {
                // A past day (an alarm that already fired) must not fall outside the range, or the picker fights it.
                DatePicker("Once on", selection: $onceDay, in: min(Date(), onceDay)..., displayedComponents: .date)
                    .environment(\.locale, AlarmTimeLocale.picker)
            }
            Stepper("\(pulses) pulses", value: $pulses, in: 1...8)
            Toggle("Again until I'm moving (a wake alarm)", isOn: $repeatUntilMoving)
            Toggle("iPhone alarm as backstop", isOn: $phoneBackstop)
            if existing != nil {
                MGButton("Delete this alarm", style: .ghost) {
                    // T152: close the sheet too; before, it stayed open and the delete looked refused.
                    if let a = existing { send(.alarms(.deleteCustom(a.id))) }
                    dismiss()
                }
            }
        }
    }

    private func save() {
        let once = LocalDay(date: onceDay, calendar: calendar).iso
        let a = CustomAlarm(id: existing?.id ?? UUID(), label: label.trimmingCharacters(in: .whitespaces),
                            minutes: minutes(of: time, calendar), weekdays: days, day: days.isEmpty ? once : nil,
                            on: existing?.on ?? true, pulses: pulses, repeatUntilMoving: repeatUntilMoving,
                            phoneBackstop: phoneBackstop)
        send(.alarms(.saveCustom(a)))
    }
}

// MARK: - A one-day / two-day / week-long change

struct AlarmsChangeEditor: View {
    let custom: [CustomAlarm]
    let send: (UIIntent) -> Void
    @Environment(\.calendar) private var calendar

    private enum What: Hashable {
        case off, on, time, window
    }

    @State private var target: AlarmTarget = .fajr
    @State private var days = 1
    @State private var tomorrow = true
    @State private var what: What = .off
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var beforeFajr = 10
    @State private var beforeSunrise = 15

    init(custom: [CustomAlarm], send: @escaping (UIIntent) -> Void) {
        self.custom = custom
        self.send = send
    }

    var body: some View {
        SettingsSheetFrame(title: "Change", saveTitle: "Add", canSave: true, reason: nil, onSave: save) {
            LogFormLabel("Which alarm")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                Chip("Fajr wake", selected: target == .fajr) { target = .fajr; if what == .time { what = .off } }
                Chip("Wake", selected: target == .normal) { target = .normal; if what == .window { what = .off } }
                ForEach(custom) { a in
                    Chip(a.label.isEmpty ? "Alarm" : a.label, selected: target == .custom(a.id)) {
                        target = .custom(a.id)
                        if what == .window { what = .off }
                    }
                }
            }
            LogFormLabel("For")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                Chip("1 day", selected: days == 1) { days = 1 }
                Chip("2 days", selected: days == 2) { days = 2 }
                Chip("A week", selected: days == 7) { days = 7 }
                Chip("from today", selected: !tomorrow) { tomorrow = false }
                Chip("from tomorrow", selected: tomorrow) { tomorrow = true }
            }
            LogFormLabel("Change")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                Chip("Off", selected: what == .off) { what = .off }
                Chip("On", selected: what == .on) { what = .on }
                if target == .fajr {
                    Chip("Other window", selected: what == .window) { what = .window }
                } else {
                    Chip("Other time", selected: what == .time) { what = .time }
                }
            }
            if what == .time { AlarmsTimeWheel(time: $time) }
            if what == .window {
                Stepper("Opens \(beforeFajr) min before Fajr", value: $beforeFajr, in: 0...120, step: 5)
                Stepper("Latest \(beforeSunrise) min before sunrise", value: $beforeSunrise, in: 0...120, step: 5)
            }
            LogHint("A change beats the weekly days; the newest change wins where two overlap.")
        }
    }

    private func save() {
        let action: OverrideAction
        switch what {
        case .off: action = .off
        case .on: action = .on
        case .time: action = .time(minutes: minutes(of: time, calendar))
        case .window: action = .fajrWindow(beforeFajr: beforeFajr, beforeSunrise: beforeSunrise)
        }
        send(.alarms(.addOverride(target: target, startsTomorrow: tomorrow, days: days, action: action)))
    }
}
