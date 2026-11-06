#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

private enum AlarmsPreviewData {
    static let alarmID = UUID(uuidString: "00000000-0000-0000-0000-000000000532")!
    static let timerID = UUID(uuidString: "00000000-0000-0000-0000-000000000955")!

    static var alarms: AlarmsState {
        let alarm = CustomAlarm(id: alarmID, label: "Morning", minutes: 5 * 60 + 32,
                                weekdays: Set([2, 3, 4, 5, 6]), pulses: 4)
        var settings = AlarmsSettings()
        settings.fajr.on = true
        settings.fajr.weekdays = Set(1...7)
        settings.custom = [alarm]
        return AlarmsState(
            sample: true, settings: settings, normalOn: true,
            normalWeekly: (1...7).map { WeekdayWake(weekday: $0, time: TimeOfDay(hour: 7, minute: 10)) },
            normalWindowMinutes: 30, ringing: nil, next: "Next: Fajr · 5:32 AM",
            strapSlot: "Fajr · 5:32 AM", fajrToday: "Today · 5:32–5:47 AM",
            fajrNotes: ["Fajr is on every day."], normalNotes: [],
            upcoming: [AlarmsState.Row(id: "fajr", title: "Fajr", detail: "Today · 5:32 AM")], skipped: [],
            location: "Sample city", match: nil, matchMethod: nil, overrides: [], custom: [alarm],
            timers: [AlarmsState.Row(id: "timer", title: "Tea timer", detail: "ends 9:55 AM")], log: [],
            calendarAccess: "allowed", remindersAccess: "allowed", calendars: [], reminderLists: [],
            reliability: ["The iPhone is the alarm backstop."])
    }

    static var timers: TimersState {
        let timer = StrapTimer(id: timerID, label: "Tea timer", startedAt: SampleDay.at(9, 40),
                               endsAt: SampleDay.at(9, 55), pulses: 4)
        return TimersState.make(TimersBook(timers: [timer]), now: SampleDay.at(9, 42), calendar: SampleDay.calendar)
    }
}

#Preview("Alarms · Fajr + timer") {
    NavigationStack {
        AlarmsView(state: AlarmsPreviewData.alarms, timersState: AlarmsPreviewData.timers,
                   sendTimer: { print("Timer action:", $0) }, send: { print("Alarm intent:", $0) })
    }
    .mgTheme(.cream)
}
#endif
