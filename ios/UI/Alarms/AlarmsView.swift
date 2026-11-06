import SwiftUI
import MGContext
import MGDesign
import MGDomain

// The alarm page (added 2026-10-11): Fajr wake, normal wake (shared with Tonight's smart wake), one-/two-day and
// week-long changes, custom alarms, timers, calendar & reminders buzz, the strap's own alarm and its log. Pure rendering
// of `AlarmsState`; every change is a `UIIntent` (`.alarms(_:)` or the existing smart-wake intents). Reached from
// Settings › Alarms and from the alarm chip on Today.
//
// T106: each section lives in its own View struct (AlarmsSections.swift), so `AlarmsView.body` is a short list of small
// types instead of one huge nested generic (stack overflow in `swift_getGenericMetadata` on the Alarms tab).

struct AlarmsScreen: View {
    @ObservedObject var model: AlarmsModel
    let send: (UIIntent) -> Void

    init(model: AlarmsModel, send: @escaping (UIIntent) -> Void) {
        self.model = model
        self.send = send
    }

    var body: some View {
        if let s = model.state {
            AlarmsView(state: s, send: send)
        } else {
            RootLoading(text: "Reading the alarms…", giveUpAfter: 10)
        }
    }
}

/// Which editor sheet is open (presentation only; values change through intents).
enum AlarmsSheet: Identifiable {
    case normalTime(weekday: Int)
    case custom(CustomAlarm?)
    case change
    case pillars
    // (the old "timer" sheet is retired: timers live in UI/Timers/TimersSection.swift, TimersPanel)

    var id: String {
        switch self {
        case .normalTime(let d): return "normal:\(d)"
        case .custom(let a): return "custom:" + (a?.id.uuidString ?? "new")
        case .change: return "change"
        case .pillars: return "pillars"
        }
    }
}

struct AlarmsView: View {
    let state: AlarmsState
    let send: (UIIntent) -> Void
    let timersState: TimersState?
    let sendTimer: (TimersAction) -> Void

    init(state: AlarmsState, timersState: TimersState? = nil,
         sendTimer: @escaping (TimersAction) -> Void = { _ in }, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.timersState = timersState
        self.sendTimer = sendTimer
        self.send = send
    }
    @State private var sheet: AlarmsSheet?

    private func edit(_ e: AlarmsEdit) { send(.alarms(.edit(e))) }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                AlarmsHeaderView(next: state.next, iphoneLine: state.iphoneLine)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                if state.sample {
                    LogHint("Sample data is on: nothing is written to the strap. The iPhone alarms still ring.")
                        .padding(.vertical, 6)
                }
                AlarmsSilenceRow(send: send)
                if let r = state.ringing {
                    AlarmsRingingCard(ringing: r, send: send)
                }
                Group {
                    AlarmsStrapSection(strapSlot: state.strapSlot, strapSlotOn: state.settings.strapSlotOn,
                                       upcoming: state.upcoming, skipped: state.skipped,
                                       edit: edit, send: send)
                    AlarmsFajrSection(fajr: state.settings.fajr, fajrToday: state.fajrToday, fajrNotes: state.fajrNotes,
                                      location: state.location, match: state.match, matchMethod: state.matchMethod,
                                      edit: edit, send: send, openPillars: { sheet = .pillars })
                    AlarmsNormalSection(normalOn: state.normalOn, normalNotes: state.normalNotes,
                                        normalWeekly: state.normalWeekly, normalWindowMinutes: state.normalWindowMinutes,
                                        normal: state.settings.normal, edit: edit, send: send,
                                        openNormalTime: { sheet = .normalTime(weekday: $0) })
                    AlarmsChangesSection(overrides: state.overrides, send: send, openChange: { sheet = .change })
                }
                Group {
                    AlarmsCustomSection(custom: state.custom, send: send,
                                         openCustom: { sheet = .custom($0) })
                    if let timersState {
                        TimersSection(state: timersState, send: sendTimer,
                                      silence: { send(.alarms(.silence)) }, openStart: {})
                    } else {
                        TimersPanel(silence: { send(.alarms(.silence)) })
                    }
                    AlarmsCalendarSection(calendar: state.settings.calendar, calendarAccess: state.calendarAccess,
                                          remindersAccess: state.remindersAccess, calendars: state.calendars,
                                          reminderLists: state.reminderLists, edit: edit, send: send)
                    AlarmsNotificationsSection(notifications: state.settings.notifications, edit: edit)
                    AlarmsLogSection(log: state.log)
                    AlarmsReliabilitySection(reliability: state.reliability)
                }
            }
            .padding(.bottom, 48)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .sheet(item: $sheet) { current in
            sheetContent(current)
        }
    }

    @ViewBuilder private func sheetContent(_ sh: AlarmsSheet) -> some View {
        switch sh {
        case .normalTime(let d):
            AlarmsWakeEditor(weekday: d, current: state.normalWeekly, canEdit: true, send: send)
        case .custom(let a):
            AlarmsCustomEditor(alarm: a, send: send)
        case .change:
            AlarmsChangeEditor(custom: state.custom, send: send)
        case .pillars:
            AlarmsPillarsEditor(send: send)
        }
    }

    static func customDetail(_ a: CustomAlarm) -> String {
        [customTime(a), customScheduleDetail(a)].joined(separator: " · ")
    }

    static func customTime(_ a: CustomAlarm) -> String {
        ClockText.hm(hour: a.minutes / 60, minute: a.minutes % 60)
    }

    static func customScheduleDetail(_ a: CustomAlarm) -> String {
        let days = a.weekdays.isEmpty ? (a.day ?? "once")
            : SettingsWeekday.order.filter { a.weekdays.contains($0) }.compactMap { SettingsWeekday.short[$0] }
                .joined(separator: " ")
        var parts = [days, "\(a.pulses) pulses"]
        if a.repeatUntilMoving { parts.append("again until moving") }
        parts.append(a.phoneBackstop ? "iPhone backstop" : "no iPhone backstop")
        return parts.joined(separator: " · ")
    }
}

/// A row with a −/+ stepper; `onChange` gets the new value (the state decides what shows next).
struct AlarmsStepperRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    let onChange: (Int) -> Void

    init(_ title: String, value: Int, range: ClosedRange<Int>, step: Int, unit: String, onChange: @escaping (Int) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.onChange = onChange
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        Stepper(value: Binding(get: { value }, set: { onChange($0) }), in: range, step: step) {
            HStack {
                Text(title)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                Spacer(minLength: 8)
                Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink.color)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: MGSpace.rowMinHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true) }
    }
}
